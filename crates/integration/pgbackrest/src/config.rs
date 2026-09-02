use std::{
    collections::BTreeMap,
    error::Error,
    fmt, fs,
    num::NonZeroUsize,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub repo_path: PathBuf,
    pub pg_path: PathBuf,
    pub stanza: String,
    pub compress: bool,
    pub process_max: usize,
    pub retention_full: Option<u32>,
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
        let compress = match values.get("compress") {
            None => true,
            Some(&"y") => true,
            Some(&"n") => false,
            Some(other) => {
                return Err(ConfigError::new(format!(
                    "option compress must be 'y' or 'n', found '{other}'"
                )))
            }
        };
        let process_max = match values.get("process-max") {
            None => default_process_max(),
            Some(value) => value.parse::<NonZeroUsize>().map_err(|_| {
                ConfigError::new(format!(
                    "option process-max must be a positive integer, found '{value}'"
                ))
            })?.get(),
        };
        let retention_full = match values.get("repo1-retention-full") {
            None => None,
            Some(value) => Some(value.parse::<u32>().map_err(|_| {
                ConfigError::new(format!(
                    "option repo1-retention-full must be a positive integer, found '{value}'"
                ))
            })?),
        };
        Ok(Self {
            repo_path: PathBuf::from(repo_path),
            pg_path: PathBuf::from(pg_path),
            stanza,
            compress,
            process_max,
            retention_full,
        })
    }
}

fn default_process_max() -> usize {
    std::thread::available_parallelism()
        .map(NonZeroUsize::get)
        .unwrap_or(1)
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

    #[test]
    fn parses_phase1_hardening_options() {
        let config = Config::parse(
            "[global]\nrepo1-path=/repo\npg1-path=/pg\ncompress=n\nprocess-max=8\n\
             repo1-retention-full=3\n",
            "demo",
        )
        .expect("config parses");
        assert!(!config.compress);
        assert_eq!(config.process_max, 8);
        assert_eq!(config.retention_full, Some(3));
    }

    #[test]
    fn phase1_hardening_options_default_sensibly() {
        let config = Config::parse("[global]\nrepo1-path=/repo\npg1-path=/pg\n", "demo")
            .expect("config parses");
        assert!(config.compress, "compression defaults on");
        assert!(config.process_max >= 1);
        assert_eq!(
            config.retention_full, None,
            "unset retention keeps every backup"
        );
    }

    #[test]
    fn rejects_an_invalid_compress_value() {
        assert!(Config::parse(
            "[global]\nrepo1-path=/repo\npg1-path=/pg\ncompress=maybe\n",
            "demo"
        )
        .is_err());
    }

    #[test]
    fn rejects_a_non_numeric_process_max() {
        assert!(Config::parse(
            "[global]\nrepo1-path=/repo\npg1-path=/pg\nprocess-max=zero\n",
            "demo"
        )
        .is_err());
    }
}
