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
        begin_backend_session, discard_until_ready, read_frame, read_startup, relay_until_ready,
        send_pooled_startup, write_frame, Startup,
    },
};

type Pools = Arc<Mutex<BTreeMap<PoolKey, Vec<TcpStream>>>>;

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
    let (key, database) = resolve_database(config, &startup)?;
    if config.pool_mode != PoolMode::Session {
        return send_error(
            &mut client,
            "08P01",
            "transaction and statement pooling are not implemented yet",
        );
    }

    let mut backend = match take_backend(pools, &key)? {
        Some(backend) => {
            send_pooled_startup(&mut client)?;
            backend
        }
        None => connect_backend(&database, &mut client, &startup)?,
    };

    loop {
        let frame = match read_frame(&mut client) {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                release_backend(pools, key, backend, config.server_reset_query.as_deref())?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if frame.tag == b'X' {
            release_backend(pools, key, backend, config.server_reset_query.as_deref())?;
            return Ok(());
        }
        backend.write_all(&frame.raw)?;
        backend.flush()?;
        if frame.tag == b'Q' || frame.tag == b'S' {
            relay_until_ready(&mut backend, &mut client)?;
        } else {
            relay_extended_cycle(&mut client, &mut backend)?;
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
) -> io::Result<TcpStream> {
    let mut backend = TcpStream::connect((database.host.as_str(), database.port))?;
    begin_backend_session(client, &mut backend, startup)?;
    Ok(backend)
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
        if frame.tag == b'S' {
            return relay_until_ready(backend, client);
        }
    }
}

fn take_backend(pools: &Pools, key: &PoolKey) -> io::Result<Option<TcpStream>> {
    let mut pools = pools
        .lock()
        .map_err(|_| io::Error::other("connection-pool lock is poisoned"))?;
    Ok(pools.get_mut(key).and_then(Vec::pop))
}

fn release_backend(
    pools: &Pools,
    key: PoolKey,
    mut backend: TcpStream,
    reset_query: Option<&str>,
) -> io::Result<()> {
    if let Some(reset_query) = reset_query {
        discard_until_ready(&mut backend, reset_query)?;
    }
    let mut pools = pools
        .lock()
        .map_err(|_| io::Error::other("connection-pool lock is poisoned"))?;
    pools.entry(key).or_default().push(backend);
    Ok(())
}

fn send_error(client: &mut TcpStream, code: &str, message: &str) -> io::Result<()> {
    let mut payload = Vec::with_capacity(code.len() + message.len() + 7);
    payload.extend_from_slice(b"SERROR\0C");
    payload.extend_from_slice(code.as_bytes());
    payload.extend_from_slice(b"\0M");
    payload.extend_from_slice(message.as_bytes());
    payload.extend_from_slice(b"\0\0");
    write_frame(client, b'E', &payload)?;
    client.flush()
}
