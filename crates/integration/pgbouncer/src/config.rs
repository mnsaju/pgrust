use std::{
    collections::{BTreeMap, BTreeSet},
    error::Error,
    fmt, fs, io,
    path::Path,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub listen_addr: String,
    pub listen_port: u16,
    pub pool_mode: PoolMode,
    pub server_reset_query: Option<String>,
    pub admin_users: BTreeSet<String>,
    pub databases: BTreeMap<String, Database>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Database {
    pub host: String,
    pub port: u16,
    pub dbname: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PoolMode {
    Session,
    Transaction,
    Statement,
}

#[derive(Debug)]
pub struct ConfigError {
    message: String,
}

impl ConfigError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(formatter)
    }
}

impl Error for ConfigError {}

impl Config {
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let text = fs::read_to_string(path).map_err(|error| {
            ConfigError::new(format!("could not read {}: {error}", path.display()))
        })?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Self, ConfigError> {
        let mut config = Self {
            listen_addr: "127.0.0.1".to_string(),
            listen_port: 6432,
            pool_mode: PoolMode::Session,
            server_reset_query: Some("DISCARD ALL".to_string()),
            admin_users: BTreeSet::new(),
            databases: BTreeMap::new(),
        };
        let mut section = "";
        for (index, raw_line) in text.lines().enumerate() {
            let line_number = index + 1;
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                section = &line[1..line.len() - 1];
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                return Err(ConfigError::new(format!(
                    "line {line_number}: expected key = value"
                )));
            };
            let key = key.trim();
            let value = value.trim();
            match section {
                "databases" => {
                    config
                        .databases
                        .insert(key.to_string(), parse_database(value, line_number)?);
                }
                "pgbouncer" => match key {
                    "listen_addr" => config.listen_addr = value.to_string(),
                    "listen_port" => config.listen_port = parse_port(value, line_number)?,
                    "pool_mode" => config.pool_mode = parse_pool_mode(value, line_number)?,
                    "server_reset_query" => {
                        config.server_reset_query = (!value.is_empty()).then(|| value.to_string())
                    }
                    "admin_users" => {
                        config.admin_users = value
                            .split(',')
                            .map(str::trim)
                            .filter(|user| !user.is_empty())
                            .map(str::to_string)
                            .collect();
                    }
                    _ => {}
                },
                _ => {}
            }
        }
        if config.databases.is_empty() {
            return Err(ConfigError::new(
                "[databases] must contain at least one database",
            ));
        }
        Ok(config)
    }
}

fn parse_database(value: &str, line_number: usize) -> Result<Database, ConfigError> {
    let mut values = BTreeMap::new();
    for item in value.split_whitespace() {
        let Some((key, value)) = item.split_once('=') else {
            return Err(ConfigError::new(format!(
                "line {line_number}: invalid database option {item:?}"
            )));
        };
        values.insert(key, value);
    }
    let host = required_database_value(&values, "host", line_number)?;
    let port = parse_port(
        required_database_value(&values, "port", line_number)?,
        line_number,
    )?;
    let dbname = values
        .get("dbname")
        .copied()
        .unwrap_or("postgres")
        .to_string();
    Ok(Database {
        host: host.to_string(),
        port,
        dbname,
    })
}

fn required_database_value<'a>(
    values: &'a BTreeMap<&str, &str>,
    key: &str,
    line_number: usize,
) -> Result<&'a str, ConfigError> {
    values
        .get(key)
        .copied()
        .ok_or_else(|| ConfigError::new(format!("line {line_number}: database is missing {key}")))
}

fn parse_port(value: &str, line_number: usize) -> Result<u16, ConfigError> {
    value
        .parse()
        .map_err(|_| ConfigError::new(format!("line {line_number}: invalid TCP port {value:?}")))
}

fn parse_pool_mode(value: &str, line_number: usize) -> Result<PoolMode, ConfigError> {
    match value {
        "session" => Ok(PoolMode::Session),
        "transaction" => Ok(PoolMode::Transaction),
        "statement" => Ok(PoolMode::Statement),
        _ => Err(ConfigError::new(format!(
            "line {line_number}: unsupported pool_mode {value:?}"
        ))),
    }
}

impl From<io::Error> for ConfigError {
    fn from(error: io::Error) -> Self {
        Self::new(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{Config, Database, PoolMode};

    #[test]
    fn parses_session_pool() {
        let config = Config::parse(
            "[databases]\npostgres = host=127.0.0.1 port=5432 dbname=postgres\n\n[pgbouncer]\nlisten_addr = 127.0.0.1\nlisten_port = 6433\npool_mode = session\nserver_reset_query = DISCARD ALL\n",
        )
        .expect("configuration parses");
        assert_eq!(config.listen_port, 6433);
        assert_eq!(config.pool_mode, PoolMode::Session);
        assert_eq!(
            config.databases.get("postgres"),
            Some(&Database {
                host: "127.0.0.1".to_string(),
                port: 5432,
                dbname: "postgres".to_string(),
            })
        );
    }
}
