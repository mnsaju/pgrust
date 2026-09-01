use std::{
    collections::BTreeMap,
    io::{self, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
    thread,
};

use crate::{
    config::{Config, Database, PoolMode},
    protocol::{
        begin_backend_session, discard_until_ready, read_frame, read_startup,
        relay_flush_responses, relay_until_ready, send_pooled_startup, write_frame,
        BackendParameters, Startup,
    },
};

type Pool = Arc<Mutex<Vec<BackendConnection>>>;
type Pools = Arc<Mutex<BTreeMap<PoolKey, Pool>>>;

#[derive(Debug)]
struct BackendConnection {
    stream: TcpStream,
    parameters: BackendParameters,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct PoolKey {
    database: String,
    user: String,
}

pub fn run(config: Config) -> io::Result<()> {
    let listener = TcpListener::bind((config.listen_addr.as_str(), config.listen_port))?;
    let config = Arc::new(config);
    let pools = Arc::new(Mutex::new(BTreeMap::new()));
    for incoming in listener.incoming() {
        let client = incoming?;
        let config = Arc::clone(&config);
        let pools = Arc::clone(&pools);
        thread::spawn(move || {
            if let Err(error) = handle_client(client, &config, &pools) {
                eprintln!("pgrust-pgbouncer client error: {error}");
            }
        });
    }
    Ok(())
}

fn handle_client(mut client: TcpStream, config: &Config, pools: &Pools) -> io::Result<()> {
    let startup = read_startup(&mut client)?;
    if startup
        .parameters
        .get("database")
        .is_some_and(|name| name == "pgbouncer")
    {
        return handle_admin(&mut client, config, &startup);
    }
    let (key, database) = resolve_database(config, &startup)?;
    if config.pool_mode != PoolMode::Session {
        return send_error(
            &mut client,
            "08P01",
            "transaction and statement pooling are not implemented yet",
        );
    }

    let pool_size = database.pool_size.unwrap_or(config.default_pool_size);
    let mut backend = match take_backend(pools, &key)? {
        Some(backend) => {
            send_pooled_startup(&mut client, &backend.parameters)?;
            backend
        }
        None => connect_backend(&database, &mut client, &startup)?,
    };

    loop {
        let frame = match read_frame(&mut client) {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                release_backend(
                    pools,
                    key,
                    backend,
                    config.server_reset_query.as_deref(),
                    pool_size,
                )?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if frame.tag == b'X' {
            release_backend(
                pools,
                key,
                backend,
                config.server_reset_query.as_deref(),
                pool_size,
            )?;
            return Ok(());
        }
        backend.stream.write_all(&frame.raw)?;
        backend.stream.flush()?;
        match frame.tag {
            b'Q' | b'S' => relay_until_ready(&mut backend.stream, &mut client)?,
            b'H' => relay_flush_responses(&mut backend.stream, &mut client)?,
            _ => relay_extended_cycle(&mut client, &mut backend.stream)?,
        }
    }
}

fn handle_admin(client: &mut TcpStream, config: &Config, startup: &Startup) -> io::Result<()> {
    let user = startup.parameters.get("user").ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "startup packet is missing user")
    })?;
    if !config.admin_users.contains(user) {
        return send_error(client, "42501", "admin access is not permitted");
    }
    send_pooled_startup(client, &BackendParameters::admin())?;
    loop {
        let frame = read_frame(client)?;
        if frame.tag == b'X' {
            return Ok(());
        }
        if frame.tag != b'Q' {
            return send_error(
                client,
                "08P01",
                "admin console supports simple queries only",
            );
        }
        let query = simple_query(&frame)?;
        match query.to_ascii_uppercase().as_str() {
            "SHOW VERSION" => send_admin_row(client, "version", "pgrust-pgbouncer")?,
            "SHOW HELP" => send_admin_row(client, "command", "SHOW VERSION")?,
            "PAUSE" | "RESUME" | "RELOAD" => send_command_complete(client, "SHOW")?,
            _ => send_error(client, "0A000", "admin command is not implemented")?,
        }
    }
}

fn resolve_database(config: &Config, startup: &Startup) -> io::Result<(PoolKey, Database)> {
    let user = startup.parameters.get("user").ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "startup packet is missing user")
    })?;
    let requested = startup.parameters.get("database").unwrap_or(user);
    let database = config
        .databases
        .get(requested)
        .or_else(|| config.databases.get("*"))
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("database {requested:?} is not configured"),
            )
        })?;
    Ok((
        PoolKey {
            database: requested.to_string(),
            user: user.to_string(),
        },
        database.clone(),
    ))
}

fn connect_backend(
    database: &Database,
    client: &mut TcpStream,
    startup: &Startup,
) -> io::Result<BackendConnection> {
    let mut backend = TcpStream::connect((database.host.as_str(), database.port))?;
    let parameters = begin_backend_session(client, &mut backend, startup)?;
    Ok(BackendConnection {
        stream: backend,
        parameters,
    })
}

fn relay_extended_cycle(client: &mut TcpStream, backend: &mut TcpStream) -> io::Result<()> {
    loop {
        let frame = read_frame(client)?;
        if frame.tag == b'X' {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "client terminated in an extended-protocol cycle",
            ));
        }
        backend.write_all(&frame.raw)?;
        backend.flush()?;
        match frame.tag {
            b'S' => return relay_until_ready(backend, client),
            b'H' => relay_flush_responses(backend, client)?,
            _ => {}
        }
    }
}

fn take_backend(pools: &Pools, key: &PoolKey) -> io::Result<Option<BackendConnection>> {
    let pool = pool_for(pools, key)?;
    let mut connections = pool
        .lock()
        .map_err(|_| io::Error::other("per-database connection-pool lock is poisoned"))?;
    while let Some(mut backend) = connections.pop() {
        if backend_is_healthy(&mut backend.stream)? {
            return Ok(Some(backend));
        }
    }
    Ok(None)
}

fn release_backend(
    pools: &Pools,
    key: PoolKey,
    mut backend: BackendConnection,
    reset_query: Option<&str>,
    max_pool_size: usize,
) -> io::Result<()> {
    if let Some(reset_query) = reset_query {
        discard_until_ready(&mut backend.stream, reset_query)?;
    }
    let pool = pool_for(pools, &key)?;
    let mut connections = pool
        .lock()
        .map_err(|_| io::Error::other("per-database connection-pool lock is poisoned"))?;
    if connections.len() < max_pool_size {
        connections.push(backend);
    }
    Ok(())
}

fn pool_for(pools: &Pools, key: &PoolKey) -> io::Result<Pool> {
    let mut pools = pools
        .lock()
        .map_err(|_| io::Error::other("connection-pool map lock is poisoned"))?;
    Ok(Arc::clone(
        pools
            .entry(key.clone())
            .or_insert_with(|| Arc::new(Mutex::new(Vec::new()))),
    ))
}

fn backend_is_healthy(backend: &mut TcpStream) -> io::Result<bool> {
    backend.set_nonblocking(true)?;
    let mut byte = [0; 1];
    let health = match backend.peek(&mut byte) {
        Ok(0) | Ok(_) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(true),
        Err(error) => Err(error),
    };
    let restore = backend.set_nonblocking(false);
    match (health, restore) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Ok(healthy), Ok(())) => Ok(healthy),
    }
}

fn send_error(client: &mut TcpStream, code: &str, message: &str) -> io::Result<()> {
    let mut payload = Vec::with_capacity(code.len() + message.len() + 7);
    payload.extend_from_slice(b"SERROR\0C");
    payload.extend_from_slice(code.as_bytes());
    payload.extend_from_slice(b"\0M");
    payload.extend_from_slice(message.as_bytes());
    payload.extend_from_slice(b"\0\0");
    write_frame(client, b'E', &payload)?;
    write_frame(client, b'Z', b"I")?;
    client.flush()
}

fn simple_query(frame: &crate::protocol::Frame) -> io::Result<&str> {
    let payload = frame.raw.get(5..).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "simple-query frame has no payload",
        )
    })?;
    let query = payload.strip_suffix(&[0]).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "simple-query frame is not null terminated",
        )
    })?;
    std::str::from_utf8(query)
        .map(str::trim)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn send_admin_row(client: &mut TcpStream, column: &str, value: &str) -> io::Result<()> {
    let mut description = Vec::with_capacity(column.len() + 19);
    description.extend_from_slice(&1_i16.to_be_bytes());
    description.extend_from_slice(column.as_bytes());
    description.push(0);
    description.extend_from_slice(&0_i32.to_be_bytes());
    description.extend_from_slice(&0_i16.to_be_bytes());
    description.extend_from_slice(&25_i32.to_be_bytes());
    description.extend_from_slice(&(-1_i16).to_be_bytes());
    description.extend_from_slice(&(-1_i32).to_be_bytes());
    description.extend_from_slice(&0_i16.to_be_bytes());
    write_frame(client, b'T', &description)?;

    let mut row = Vec::with_capacity(value.len() + 6);
    row.extend_from_slice(&1_i16.to_be_bytes());
    row.extend_from_slice(&(value.len() as i32).to_be_bytes());
    row.extend_from_slice(value.as_bytes());
    write_frame(client, b'D', &row)?;
    send_command_complete(client, "SHOW")
}

fn send_command_complete(client: &mut TcpStream, tag: &str) -> io::Result<()> {
    let mut payload = tag.as_bytes().to_vec();
    payload.push(0);
    write_frame(client, b'C', &payload)?;
    write_frame(client, b'Z', b"I")?;
    client.flush()
}
