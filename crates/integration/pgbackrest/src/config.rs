use std::{
    collections::BTreeMap,
    error::Error,
    fmt, fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub repo_path: PathBuf,
    pub pg_path: PathBuf,
    pub stanza: String,
}

#[derive(Debug)]
pub struct ConfigError(String);

impl ConfigError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

impl Error for ConfigError {}

impl Config {
    pub fn from_file(
        path: impl AsRef<Path>,
        stanza: impl Into<String>,
    ) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let text = fs::read_to_string(path).map_err(|error| {
            ConfigError::new(format!("could not read {}: {error}", path.display()))
        })?;
        Self::parse(&text, stanza)
    }

    pub fn parse(text: &str, stanza: impl Into<String>) -> Result<Self, ConfigError> {
        let mut values = BTreeMap::new();
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
            if section == "global" {
                values.insert(key.trim(), value.trim());
            }
        }
        let repo_path = values
            .get("repo1-path")
            .ok_or_else(|| ConfigError::new("[global] option repo1-path is required"))?;
        let pg_path = values
            .get("pg1-path")
            .ok_or_else(|| ConfigError::new("[global] option pg1-path is required"))?;
        let stanza = stanza.into();
        if !valid_component(&stanza) {
            return Err(ConfigError::new(
                "stanza must be a non-empty path component",
            ));
        }
        Ok(Self {
            repo_path: PathBuf::from(repo_path),
            pg_path: PathBuf::from(pg_path),
            stanza,
        })
    }
}

pub(crate) fn valid_component(value: &str) -> bool {
    !value.is_empty() && value != "." && value != ".." && !value.contains(['/', '\\', '\0'])
}

#[cfg(test)]
mod tests {
    use super::Config;

    #[test]
    fn parses_local_repository_configuration() {
        let config = Config::parse(
            "[global]\nrepo1-path=/var/lib/pgbackrest\npg1-path=/var/lib/postgresql/data\n",
            "demo",
        )
        .expect("config parses");
        assert_eq!(config.stanza, "demo");
        assert_eq!(config.repo_path.to_string_lossy(), "/var/lib/pgbackrest");
    }
}
