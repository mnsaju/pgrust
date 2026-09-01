use std::{
    collections::BTreeSet,
    error::Error,
    ffi::OsStr,
    fmt,
    fs::{self, File},
    io::{self, BufRead, BufReader, Read, Write},
    path::{Component, Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use pg_sha2::PgSha256Ctx;

use crate::config::{valid_component, Config};

const FORMAT_VERSION: &str = "1";

#[derive(Debug)]
pub struct RepositoryError(String);

impl RepositoryError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for RepositoryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

impl Error for RepositoryError {}

impl From<io::Error> for RepositoryError {
    fn from(error: io::Error) -> Self {
        Self::new(error.to_string())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BackupInfo {
    pub label: String,
    pub files: usize,
    pub bytes: u64,
}

#[derive(Clone, Debug)]
pub struct Repository {
    config: Config,
}

impl Repository {
    pub fn new(config: Config) -> Self {
        Self { config }
    }

    pub fn stanza_create(&self) -> Result<(), RepositoryError> {
        let archive = self.archive_root();
        let backup = self.backup_root();
        let archive_info = self.info_contents("archive");
        let backup_info = self.info_contents("backup");
        if archive.exists() || backup.exists() {
            let archive_valid = info_pair_matches(&archive, "archive.info", &archive_info)?;
            let backup_valid = info_pair_matches(&backup, "backup.info", &backup_info)?;
            if archive_valid && backup_valid {
                return Ok(());
            }
            if archive_valid
                || backup_valid
                || directory_is_nonempty(&archive)?
                || directory_is_nonempty(&backup)?
            {
                return Err(RepositoryError::new(
                    "stanza metadata is incomplete, mismatched, or repository directories are not empty",
                ));
            }
        }
        fs::create_dir_all(&archive)?;
        fs::create_dir_all(&backup)?;
        write_info_pair(&archive, "archive.info", &archive_info)?;
        write_info_pair(&backup, "backup.info", &backup_info)?;
        Ok(())
    }

    pub fn archive_push(&self, source: impl AsRef<Path>) -> Result<(), RepositoryError> {
        self.ensure_stanza()?;
        let source = source.as_ref();
        let name = file_name(source)?;
        if !valid_component(name) {
            return Err(RepositoryError::new("archive file name is not safe"));
        }
        let destination = self
            .archive_root()
            .join("wal")
            .join(wal_prefix(name))
            .join(name);
        let checksum = checksum_file(source)?;
        if destination.exists() {
            if checksum_file(&destination)? == checksum {
                return Ok(());
            }
            return Err(RepositoryError::new(format!(
                "archive file {name} already exists with a different checksum"
            )));
        }
        copy_atomic(source, &destination)?;
        write_atomic(
            &checksum_path(&destination),
            format!("{checksum}\n").as_bytes(),
        )
    }

    pub fn archive_get(
        &self,
        archive_name: &str,
        destination: impl AsRef<Path>,
    ) -> Result<(), RepositoryError> {
        self.ensure_stanza()?;
        if !valid_component(archive_name) {
            return Err(RepositoryError::new("archive file name is not safe"));
        }
        let source = self
            .archive_root()
            .join("wal")
            .join(wal_prefix(archive_name))
            .join(archive_name);
        if !source.is_file() {
            return Err(RepositoryError::new(format!(
                "archive file {archive_name} was not found"
            )));
        }
        let expected = fs::read_to_string(checksum_path(&source)).map_err(|_| {
            RepositoryError::new(format!(
                "archive file {archive_name} has no checksum metadata"
            ))
        })?;
        if checksum_file(&source)? != expected.trim() {
            return Err(RepositoryError::new(format!(
                "archive file {archive_name} is corrupt"
            )));
        }
        copy_atomic(&source, destination.as_ref())
    }

    pub fn backup_full(&self) -> Result<BackupInfo, RepositoryError> {
        self.ensure_stanza()?;
        if !self.config.pg_path.is_dir() {
            return Err(RepositoryError::new(format!(
                "pg1-path {} is not a directory",
                self.config.pg_path.display()
            )));
        }
        let label = self.next_backup_label()?;
        let partial = self.backup_root().join(format!(".{label}.partial"));
        let final_path = self.backup_root().join(&label);
        if partial.exists() || final_path.exists() {
            return Err(RepositoryError::new(format!(
                "backup label {label} is already in use"
            )));
        }
        fs::create_dir_all(partial.join("data"))?;
        let mut entries = Vec::new();
        copy_tree(
            &self.config.pg_path,
            &partial.join("data"),
            Path::new(""),
            &mut entries,
        )?;
        entries.sort();
        write_manifest(&partial.join("manifest"), &entries)?;
        fs::rename(&partial, &final_path)?;
        let info = BackupInfo {
            label: label.clone(),
            files: entries.len(),
            bytes: entries.iter().map(|entry| entry.size).sum(),
        };
        self.write_backup_catalog(&self.backup_labels()?)?;
        Ok(info)
    }

    pub fn restore(
        &self,
        label: Option<&str>,
        destination: impl AsRef<Path>,
    ) -> Result<BackupInfo, RepositoryError> {
        self.ensure_stanza()?;
        let labels = self.backup_labels()?;
        let label = match label {
            Some(label) if labels.contains(label) => label.to_string(),
            Some(label) => {
                return Err(RepositoryError::new(format!(
                    "backup {label} was not found"
                )))
            }
            None => labels
                .into_iter()
                .last()
                .ok_or_else(|| RepositoryError::new("no backups are available"))?,
        };
        let backup = self.backup_root().join(&label);
        let entries = read_manifest(&backup.join("manifest"))?;
        let destination = destination.as_ref();
        ensure_empty_destination(destination)?;
        for entry in &entries {
            let source = backup.join("data").join(&entry.path);
            let target = destination.join(&entry.path);
            if checksum_file(&source)? != entry.checksum {
                return Err(RepositoryError::new(format!(
                    "backup file {} is corrupt",
                    entry.path.display()
                )));
            }
            copy_atomic(&source, &target)?;
        }
        Ok(BackupInfo {
            label,
            files: entries.len(),
            bytes: entries.iter().map(|entry| entry.size).sum(),
        })
    }

    pub fn check(&self) -> Result<(), RepositoryError> {
        self.ensure_stanza()?;
        for label in self.backup_labels()? {
            let backup = self.backup_root().join(&label);
            for entry in read_manifest(&backup.join("manifest"))? {
                let path = backup.join("data").join(&entry.path);
                if !path.is_file()
                    || fs::metadata(&path)?.len() != entry.size
                    || checksum_file(&path)? != entry.checksum
                {
                    return Err(RepositoryError::new(format!(
                        "backup {label} file {} is corrupt",
                        entry.path.display()
                    )));
                }
            }
        }
        Ok(())
    }

    pub fn info(&self) -> Result<Vec<BackupInfo>, RepositoryError> {
        self.ensure_stanza()?;
        self.backup_labels()?
            .into_iter()
            .map(|label| {
                let entries = read_manifest(&self.backup_root().join(&label).join("manifest"))?;
                Ok(BackupInfo {
                    label,
                    files: entries.len(),
                    bytes: entries.iter().map(|entry| entry.size).sum(),
                })
            })
            .collect()
    }

    fn ensure_stanza(&self) -> Result<(), RepositoryError> {
        for (root, name) in [
            (self.archive_root(), "archive.info"),
            (self.backup_root(), "backup.info"),
        ] {
            let primary = root.join(name);
            let copy = primary.with_extension("info.copy");
            if !primary.is_file() || !copy.is_file() {
                return Err(RepositoryError::new(
                    "stanza is not initialized; run stanza-create first",
                ));
            }
            if fs::read(&primary)? != fs::read(&copy)? {
                return Err(RepositoryError::new(format!(
                    "metadata copies disagree in {}",
                    root.display()
                )));
            }
        }
        Ok(())
    }

    fn archive_root(&self) -> PathBuf {
        self.config
            .repo_path
            .join("archive")
            .join(&self.config.stanza)
    }

    fn backup_root(&self) -> PathBuf {
        self.config
            .repo_path
            .join("backup")
            .join(&self.config.stanza)
    }

    fn info_contents(&self, kind: &str) -> String {
        format!(
            "format={FORMAT_VERSION}\nstanza={}\nkind={kind}\n",
            self.config.stanza
        )
    }

    fn backup_labels(&self) -> Result<BTreeSet<String>, RepositoryError> {
        let mut labels = BTreeSet::new();
        let root = self.backup_root();
        for entry in fs::read_dir(&root)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if entry.file_type()?.is_dir() && name.starts_with("full-") {
                labels.insert(name.into_owned());
            }
        }
        Ok(labels)
    }

    fn write_backup_catalog(&self, labels: &BTreeSet<String>) -> Result<(), RepositoryError> {
        let mut contents = self.info_contents("backup");
        for label in labels {
            contents.push_str("backup=");
            contents.push_str(label);
            contents.push('\n');
        }
        write_info_pair(&self.backup_root(), "backup.info", &contents)
    }

    fn next_backup_label(&self) -> Result<String, RepositoryError> {
        let epoch = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| RepositoryError::new("system clock is before the Unix epoch"))?
            .as_secs();
        let base = format!("full-{epoch}");
        let labels = self.backup_labels()?;
        if !labels.contains(&base) {
            return Ok(base);
        }
        for suffix in 1..u32::MAX {
            let label = format!("{base}-{suffix}");
            if !labels.contains(&label) {
                return Ok(label);
            }
        }
        Err(RepositoryError::new("could not allocate a backup label"))
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct ManifestEntry {
    path: PathBuf,
    size: u64,
    checksum: String,
}

fn write_info_pair(root: &Path, name: &str, contents: &str) -> Result<(), RepositoryError> {
    write_atomic(&root.join(name), contents.as_bytes())?;
    write_atomic(&root.join(format!("{name}.copy")), contents.as_bytes())
}

fn info_pair_matches(root: &Path, name: &str, expected: &str) -> Result<bool, RepositoryError> {
    let primary = root.join(name);
    let copy = root.join(format!("{name}.copy"));
    match (primary.exists(), copy.exists()) {
        (false, false) => Ok(false),
        (true, true) => {
            Ok(fs::read(primary)? == expected.as_bytes() && fs::read(copy)? == expected.as_bytes())
        }
        _ => Ok(false),
    }
}

fn directory_is_nonempty(path: &Path) -> Result<bool, RepositoryError> {
    Ok(path.exists() && fs::read_dir(path)?.next().is_some())
}

fn write_atomic(path: &Path, contents: &[u8]) -> Result<(), RepositoryError> {
    let parent = path
        .parent()
        .ok_or_else(|| RepositoryError::new("path has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    {
        let mut file = File::create(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(temporary, path)?;
    Ok(())
}

fn copy_atomic(source: &Path, destination: &Path) -> Result<(), RepositoryError> {
    let parent = destination
        .parent()
        .ok_or_else(|| RepositoryError::new("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = destination.with_extension(format!("tmp-{}", std::process::id()));
    let mut input = BufReader::new(File::open(source)?);
    let mut output = File::create(&temporary)?;
    io::copy(&mut input, &mut output)?;
    output.sync_all()?;
    drop(output);
    fs::rename(temporary, destination)?;
    Ok(())
}

fn copy_tree(
    source: &Path,
    destination: &Path,
    relative: &Path,
    entries: &mut Vec<ManifestEntry>,
) -> Result<(), RepositoryError> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        let child_relative = relative.join(&name);
        if relative.as_os_str().is_empty() && is_backup_excluded(&name) {
            continue;
        }
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            return Err(RepositoryError::new(format!(
                "symlink {} is not supported",
                child_relative.display()
            )));
        }
        let source_path = entry.path();
        let target_path = destination.join(&name);
        if file_type.is_dir() {
            fs::create_dir_all(&target_path)?;
            copy_tree(&source_path, &target_path, &child_relative, entries)?;
        } else if file_type.is_file() {
            copy_atomic(&source_path, &target_path)?;
            entries.push(ManifestEntry {
                path: child_relative,
                size: fs::metadata(&target_path)?.len(),
                checksum: checksum_file(&target_path)?,
            });
        } else {
            return Err(RepositoryError::new(format!(
                "unsupported file type at {}",
                child_relative.display()
            )));
        }
    }
    Ok(())
}

fn write_manifest(path: &Path, entries: &[ManifestEntry]) -> Result<(), RepositoryError> {
    let mut contents = String::new();
    for entry in entries {
        contents.push_str(&entry.path.to_string_lossy());
        contents.push('\t');
        contents.push_str(&entry.size.to_string());
        contents.push('\t');
        contents.push_str(&entry.checksum);
        contents.push('\n');
    }
    write_atomic(path, contents.as_bytes())
}

fn read_manifest(path: &Path) -> Result<Vec<ManifestEntry>, RepositoryError> {
    let file = File::open(path)?;
    let mut entries = Vec::new();
    for line in BufReader::new(file).lines() {
        let line = line?;
        let mut fields = line.split('\t');
        let path = fields
            .next()
            .ok_or_else(|| RepositoryError::new("manifest is missing a path"))?;
        let size = fields
            .next()
            .ok_or_else(|| RepositoryError::new("manifest is missing a size"))?
            .parse()
            .map_err(|_| RepositoryError::new("manifest has an invalid size"))?;
        let checksum = fields
            .next()
            .ok_or_else(|| RepositoryError::new("manifest is missing a checksum"))?;
        if fields.next().is_some() || !safe_relative_path(Path::new(path)) || checksum.len() != 64 {
            return Err(RepositoryError::new("manifest contains an invalid entry"));
        }
        entries.push(ManifestEntry {
            path: PathBuf::from(path),
            size,
            checksum: checksum.to_string(),
        });
    }
    Ok(entries)
}

fn ensure_empty_destination(path: &Path) -> Result<(), RepositoryError> {
    if path.exists() && fs::read_dir(path)?.next().is_some() {
        return Err(RepositoryError::new(format!(
            "restore destination {} is not empty",
            path.display()
        )));
    }
    fs::create_dir_all(path)?;
    Ok(())
}

fn checksum_file(path: &Path) -> Result<String, RepositoryError> {
    let mut file = File::open(path)?;
    let mut checksum = PgSha256Ctx::init_sha256();
    let mut buffer = [0; 128 * 1024];
    loop {
        let bytes = file.read(&mut buffer)?;
        if bytes == 0 {
            break;
        }
        checksum.update(&buffer[..bytes]);
    }
    Ok(hex(&checksum.final_sha256()))
}

fn checksum_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".sha256");
    PathBuf::from(value)
}

fn file_name(path: &Path) -> Result<&str, RepositoryError> {
    path.file_name()
        .and_then(OsStr::to_str)
        .ok_or_else(|| RepositoryError::new(format!("{} has no valid file name", path.display())))
}

fn wal_prefix(name: &str) -> &str {
    name.get(..16).unwrap_or("misc")
}

fn is_backup_excluded(name: &OsStr) -> bool {
    matches!(
        name.to_str(),
        Some("pg_wal" | "postmaster.pid" | "postmaster.opts")
    )
}

fn safe_relative_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push(HEX[(byte >> 4) as usize] as char);
        value.push(HEX[(byte & 0x0f) as usize] as char);
    }
    value
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    use crate::{Config, Repository};

    fn temp(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "pgrust-pgbackrest-{name}-{}-{nonce}",
            std::process::id()
        ))
    }

    fn repository(name: &str) -> (Repository, PathBuf) {
        let root = temp(name);
        let pg = root.join("pg");
        fs::create_dir_all(&pg).expect("pg directory");
        fs::write(pg.join("PG_VERSION"), "18\n").expect("version");
        let repository = Repository::new(Config {
            repo_path: root.join("repo"),
            pg_path: pg,
            stanza: "demo".to_string(),
        });
        (repository, root)
    }

    #[test]
    fn archives_are_idempotent_and_retrievable() {
        let (repository, root) = repository("archive");
        repository.stanza_create().expect("stanza");
        repository
            .stanza_create()
            .expect("idempotent stanza create");
        let source = root.join("000000010000000000000001");
        fs::write(&source, b"wal").expect("wal");
        repository.archive_push(&source).expect("push");
        repository.archive_push(&source).expect("idempotent push");
        let restored = root.join("restored-wal");
        repository
            .archive_get("000000010000000000000001", &restored)
            .expect("get");
        assert_eq!(fs::read(restored).expect("read"), b"wal");
        fs::write(
            root.join("repo/archive/demo/wal/0000000100000000/000000010000000000000001"),
            b"corrupt",
        )
        .expect("corrupt archive");
        assert!(repository
            .archive_get("000000010000000000000001", root.join("rejected"))
            .is_err());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn full_backup_restores_and_detects_corruption() {
        let (repository, root) = repository("backup");
        let pg = root.join("pg");
        fs::create_dir_all(pg.join("base")).expect("base");
        fs::create_dir_all(pg.join("pg_wal")).expect("wal");
        fs::write(pg.join("base/table"), b"table data").expect("table");
        fs::write(pg.join("pg_wal/ignored"), b"wal").expect("wal");
        repository.stanza_create().expect("stanza");
        let backup = repository.backup_full().expect("backup");
        repository.check().expect("check");
        let restored = root.join("restore");
        repository
            .restore(Some(&backup.label), &restored)
            .expect("restore");
        assert_eq!(
            fs::read(restored.join("base/table")).expect("restored file"),
            b"table data"
        );
        assert!(!restored.join("pg_wal").exists());
        fs::write(
            root.join("repo/backup/demo")
                .join(&backup.label)
                .join("data/base/table"),
            b"corrupt",
        )
        .expect("corrupt");
        assert!(repository.check().is_err());
        fs::remove_dir_all(root).expect("cleanup");
    }
}
