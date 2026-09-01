use std::{
    collections::BTreeMap,
    io,
    sync::{Arc, Mutex as StdMutex},
    time::Duration,
};

use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream},
    sync::Mutex,
    time::Instant,
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
type Pools = Arc<StdMutex<BTreeMap<PoolKey, Pool>>>;

struct BackendConnection {
    stream: TcpStream,
    parameters: BackendParameters,
    returned_at: Instant,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct PoolKey {
    database: String,
    user: String,
}

pub async fn run(config: Config) -> io::Result<()> {
    let listener = TcpListener::bind((config.listen_addr.as_str(), config.listen_port)).await?;
    let config = Arc::new(config);
    let pools: Pools = Arc::new(StdMutex::new(BTreeMap::new()));

    let idle_timeout = config.server_idle_timeout;
    let reaper_pools = Arc::clone(&pools);
    tokio::spawn(async move {
        reap_idle_connections(reaper_pools, idle_timeout).await;
    });

    loop {
        let (client, _) = listener.accept().await?;
        let config = Arc::clone(&config);
        let pools = Arc::clone(&pools);
        tokio::spawn(async move {
            if let Err(error) = handle_client(client, &config, &pools).await {
                eprintln!("pgrust-pgbouncer client error: {error}");
            }
        });
    }
}

async fn reap_idle_connections(pools: Pools, idle_timeout: Duration) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        interval.tick().await;
        let snapshot: Vec<Pool> = {
            let map = match pools.lock() {
                Ok(map) => map,
                Err(_) => continue,
            };
            map.values().cloned().collect()
        };
        let now = Instant::now();
        for pool in snapshot {
            let mut connections = pool.lock().await;
            connections.retain(|backend| now.duration_since(backend.returned_at) < idle_timeout);
        }
    }
}

async fn handle_client(mut client: TcpStream, config: &Config, pools: &Pools) -> io::Result<()> {
    let startup = read_startup(&mut client).await?;
    if startup
        .parameters
        .get("database")
        .is_some_and(|name| name == "pgbouncer")
    {
        return handle_admin(&mut client, config, &startup).await;
    }
    let (key, database) = resolve_database(config, &startup)?;
    if config.pool_mode != PoolMode::Session {
        return send_error(
            &mut client,
            "08P01",
            "transaction and statement pooling are not implemented yet",
        )
        .await;
    }

    let pool_size = database.pool_size.unwrap_or(config.default_pool_size);
    let idle_timeout = config.server_idle_timeout;
    let mut backend = match take_backend(pools, &key, idle_timeout).await? {
        Some(backend) => {
            send_pooled_startup(&mut client, &backend.parameters).await?;
            backend
        }
        None => connect_backend(&database, &mut client, &startup).await?,
    };

    loop {
        let frame = match read_frame(&mut client).await {
            Ok(frame) => frame,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                release_backend(pools, key, backend, config.server_reset_query.as_deref(), pool_size)
                    .await?;
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if frame.tag == b'X' {
            release_backend(pools, key, backend, config.server_reset_query.as_deref(), pool_size)
                .await?;
            return Ok(());
        }
        backend.stream.write_all(&frame.raw).await?;
        backend.stream.flush().await?;
        match frame.tag {
            b'Q' | b'S' => relay_until_ready(&mut backend.stream, &mut client).await?,
            b'H' => relay_flush_responses(&mut backend.stream, &mut client).await?,
            _ => relay_extended_cycle(&mut client, &mut backend.stream).await?,
        }
    }
}

async fn handle_admin(
    client: &mut TcpStream,
    config: &Config,
    startup: &Startup,
) -> io::Result<()> {
    let user = startup.parameters.get("user").ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "startup packet is missing user")
    })?;
    if !config.admin_users.contains(user) {
        return send_error(client, "42501", "admin access is not permitted").await;
    }
    send_pooled_startup(client, &BackendParameters::admin()).await?;
    loop {
        let frame = read_frame(client).await?;
        if frame.tag == b'X' {
            return Ok(());
        }
        if frame.tag != b'Q' {
            return send_error(
                client,
                "08P01",
                "admin console supports simple queries only",
            )
            .await;
        }
        let query = simple_query(&frame)?;
        match query.to_ascii_uppercase().as_str() {
            "SHOW VERSION" => send_admin_row(client, "version", "pgrust-pgbouncer").await?,
            "SHOW HELP" => send_admin_row(client, "command", "SHOW VERSION").await?,
            "PAUSE" | "RESUME" | "RELOAD" => send_command_complete(client, "SHOW").await?,
            _ => send_error(client, "0A000", "admin command is not implemented").await?,
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

async fn connect_backend(
    database: &Database,
    client: &mut TcpStream,
    startup: &Startup,
) -> io::Result<BackendConnection> {
    let mut backend = TcpStream::connect((database.host.as_str(), database.port)).await?;
    let parameters = begin_backend_session(client, &mut backend, startup).await?;
    Ok(BackendConnection {
        stream: backend,
        parameters,
        returned_at: Instant::now(),
    })
}

async fn relay_extended_cycle(
    client: &mut TcpStream,
    backend: &mut TcpStream,
) -> io::Result<()> {
    loop {
        let frame = read_frame(client).await?;
        if frame.tag == b'X' {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "client terminated in an extended-protocol cycle",
            ));
        }
        backend.write_all(&frame.raw).await?;
        backend.flush().await?;
        match frame.tag {
            b'S' => return relay_until_ready(backend, client).await,
            b'H' => relay_flush_responses(backend, client).await?,
            _ => {}
        }
    }
}

async fn take_backend(
    pools: &Pools,
    key: &PoolKey,
    idle_timeout: Duration,
) -> io::Result<Option<BackendConnection>> {
    let pool = pool_for(pools, key)?;
    let mut connections = pool.lock().await;
    let now = Instant::now();
    while let Some(backend) = connections.pop() {
        if now.duration_since(backend.returned_at) >= idle_timeout {
            continue;
        }
        if backend_is_healthy(&backend.stream) {
            return Ok(Some(backend));
        }
    }
    Ok(None)
}

async fn release_backend(
    pools: &Pools,
    key: PoolKey,
    mut backend: BackendConnection,
    reset_query: Option<&str>,
    max_pool_size: usize,
) -> io::Result<()> {
    if let Some(reset_query) = reset_query {
        discard_until_ready(&mut backend.stream, reset_query).await?;
    }
    backend.returned_at = Instant::now();
    let pool = pool_for(pools, &key)?;
    let mut connections = pool.lock().await;
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

fn backend_is_healthy(backend: &TcpStream) -> bool {
    let mut buf = [0; 1];
    match backend.try_read(&mut buf) {
        Err(ref error) if error.kind() == io::ErrorKind::WouldBlock => true,
        _ => false,
    }
}

async fn send_error(client: &mut TcpStream, code: &str, message: &str) -> io::Result<()> {
    let mut payload = Vec::with_capacity(code.len() + message.len() + 7);
    payload.extend_from_slice(b"SERROR\0C");
    payload.extend_from_slice(code.as_bytes());
    payload.extend_from_slice(b"\0M");
    payload.extend_from_slice(message.as_bytes());
    payload.extend_from_slice(b"\0\0");
    write_frame(client, b'E', &payload).await?;
    write_frame(client, b'Z', b"I").await?;
    client.flush().await
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

async fn send_admin_row(client: &mut TcpStream, column: &str, value: &str) -> io::Result<()> {
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
    write_frame(client, b'T', &description).await?;

    let mut row = Vec::with_capacity(value.len() + 6);
    row.extend_from_slice(&1_i16.to_be_bytes());
    row.extend_from_slice(&(value.len() as i32).to_be_bytes());
    row.extend_from_slice(value.as_bytes());
    write_frame(client, b'D', &row).await?;
    send_command_complete(client, "SHOW").await
}

async fn send_command_complete(client: &mut TcpStream, tag: &str) -> io::Result<()> {
    let mut payload = tag.as_bytes().to_vec();
    payload.push(0);
    write_frame(client, b'C', &payload).await?;
    write_frame(client, b'Z', b"I").await?;
    client.flush().await
}
