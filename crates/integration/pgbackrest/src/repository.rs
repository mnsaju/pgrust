use std::{
    collections::BTreeSet,
    error::Error,
    ffi::OsStr,
    fmt,
    fs::{self, File},
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::fs::PermissionsExt,
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
                // A crash between the segment copy and the checksum-sidecar
                // write below leaves the segment intact but the sidecar
                // missing or stale. The natural operator/archiver response
                // (retry) must repair that here, or the archive is
                // permanently unreadable despite every retry reporting
                // success (PGRA-003).
                let sidecar = checksum_path(&destination);
                let sidecar_matches = fs::read_to_string(&sidecar)
                    .map(|contents| contents.trim() == checksum)
                    .unwrap_or(false);
                if !sidecar_matches {
                    write_atomic(&sidecar, format!("{checksum}\n").as_bytes())?;
                }
                return Ok(());
            }
            return Err(RepositoryError::new(format!(
                "archive file {name} already exists with a different checksum"
            )));
        }
        let copied = copy_atomic(source, &destination)?;
        write_atomic(
            &checksum_path(&destination),
            format!("{}\n", copied.checksum).as_bytes(),
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
        copy_atomic(&source, destination.as_ref())?;
        Ok(())
    }

    pub fn backup_full(&self) -> Result<BackupInfo, RepositoryError> {
        self.ensure_stanza()?;
        if !self.config.pg_path.is_dir() {
            return Err(RepositoryError::new(format!(
                "pg1-path {} is not a directory",
                self.config.pg_path.display()
            )));
        }
        // A file-level copy of a running cluster is not a consistent backup:
        // there is no online-backup protocol here (no backup_label, no WAL
        // start/stop range), so recovery from it is not possible (PGRA-001).
        // Refuse rather than silently produce a backup that reports success
        // and cannot be restored. postmaster.pid is PostgreSQL's own
        // liveness marker and is removed on every clean shutdown.
        if self.config.pg_path.join("postmaster.pid").exists() {
            return Err(RepositoryError::new(
                "pg1-path appears to be an active PostgreSQL data directory                  (postmaster.pid is present); only backups of a stopped                  cluster are supported. Stop the server before running                  backup, or use a future online-backup implementation.",
            ));
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
        let backup_data = backup.join("data");
        let entries = read_manifest(&backup.join("manifest"))?;
        let destination = destination.as_ref();
        ensure_empty_destination(destination)?;
        // The manifest records only files, so a directory that was empty in
        // the source data directory (pg_commit_ts, pg_twophase, pg_notify,
        // and every other SLRU/runtime directory PostgreSQL expects to open
        // at startup regardless of whether the feature it backs is in use)
        // has no manifest entry and would never otherwise be created.
        // Mirror the backup's actual directory structure directly, rather
        // than hardcoding PostgreSQL's list of always-required directories
        // — this is both correct today and self-maintaining as that list
        // changes across PostgreSQL versions (PGRA-006).
        for dir in list_dirs(&backup_data)? {
            fs::create_dir_all(destination.join(dir))?;
        }
        for entry in &entries {
            let source = backup_data.join(&entry.path);
            let target = destination.join(&entry.path);
            let copied = copy_atomic(&source, &target)?;
            if copied.checksum != entry.checksum {
                return Err(RepositoryError::new(format!(
                    "backup file {} is corrupt",
                    entry.path.display()
                )));
            }
        }
        // PostgreSQL refuses to start unless PGDATA is exactly u=rwx or
        // u=rwx,g=rx; tighten it now that every file is in place (PGRA-006).
        fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;
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
            let primary_ok = fs::read(&primary)
                .is_ok_and(|contents| self.info_pair_is_valid(&contents));
            let copy_ok =
                fs::read(&copy).is_ok_and(|contents| self.info_pair_is_valid(&contents));
            // Primary-or-fallback: the redundant copy exists so that a crash
            // between the two writes in write_info_pair leaves the stanza
            // usable, not bricked (PGRA-005). Only fail if BOTH are
            // missing, unreadable, or do not belong to this stanza.
            if !primary_ok && !copy_ok {
                return Err(RepositoryError::new(format!(
                    "stanza is not initialized, or both metadata copies in {} are                      missing or unreadable; run stanza-create first",
                    root.display()
                )));
            }
        }
        Ok(())
    }

    /// A metadata file belongs to this stanza and this format version. Used
    /// to decide, independently for the primary and the redundant copy,
    /// whether each one is fit to rely on (PGRA-005) — deliberately not a
    /// byte-for-byte comparison of the two, since backup.info legitimately
    /// grows new `backup=` lines over time and a one-generation-old copy is
    /// an expected transient state, not corruption.
    fn info_pair_is_valid(&self, contents: &[u8]) -> bool {
        let Ok(text) = std::str::from_utf8(contents) else {
            return false;
        };
        let has_format = text.lines().any(|line| line == format!("format={FORMAT_VERSION}"));
        let has_stanza = text
            .lines()
            .any(|line| line == format!("stanza={}", self.config.stanza));
        has_format && has_stanza
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
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(&temporary, path)?;
    // A rename is only durable once the directory entry itself is synced;
    // without this an "atomic, durable" publish can still lose the file on
    // power loss even though its bytes were fsynced (PGRA-004).
    fsync_dir(parent)?;
    Ok(())
}

/// fsync a directory so a preceding `rename` into it is durable, not merely
/// atomic (PGRA-004). A rename is a directory-metadata operation; without
/// this the new name can be lost on power failure even though the file's
/// own contents were already fsynced.
fn fsync_dir(path: &Path) -> Result<(), RepositoryError> {
    File::open(path)?.sync_all()?;
    Ok(())
}

/// Result of a verified copy: the checksum and byte count are derived from
/// the bytes actually read from `source`, never from a later, separate read
/// of the destination (PGRA-002) — the manifest and archive sidecars must
/// describe what was backed up, not what a possibly-corrupted copy became.
struct CopiedFile {
    checksum: String,
    size: u64,
}

fn copy_atomic(source: &Path, destination: &Path) -> Result<CopiedFile, RepositoryError> {
    let parent = destination
        .parent()
        .ok_or_else(|| RepositoryError::new("destination has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = destination.with_extension(format!("tmp-{}", std::process::id()));
    let mut input = BufReader::new(File::open(source)?);
    let mut output = File::create(&temporary)?;
    output.set_permissions(fs::Permissions::from_mode(0o600))?;
    let mut hasher = PgSha256Ctx::init_sha256();
    let mut size: u64 = 0;
    let mut buffer = [0u8; 128 * 1024];
    loop {
        let bytes = input.read(&mut buffer)?;
        if bytes == 0 {
            break;
        }
        hasher.update(&buffer[..bytes]);
        output.write_all(&buffer[..bytes])?;
        size += bytes as u64;
    }
    output.sync_all()?;
    drop(output);
    let checksum = hex(&hasher.final_sha256());
    // Verify the bytes that landed on disk match the bytes read from
    // source, catching a short write or an I/O error that produced a
    // valid-but-wrong copy, before the copy is ever published or trusted.
    let written = checksum_file(&temporary)?;
    if written != checksum {
        let _ = fs::remove_file(&temporary);
        return Err(RepositoryError::new(format!(
            "copy of {} to {} did not verify after writing              (read checksum {checksum}, written checksum {written})",
            source.display(),
            destination.display()
        )));
    }
    fs::rename(&temporary, destination)?;
    fsync_dir(parent)?;
    Ok(CopiedFile { checksum, size })
}

/// Every directory under `root`, relative to it, in root-to-leaf order (a
/// parent always precedes its children) so callers can `create_dir_all`
/// them in a single pass. Mirrors whatever directory structure the backup
/// actually contains — see the call site in `restore` (PGRA-006).
fn list_dirs(root: &Path) -> Result<Vec<PathBuf>, RepositoryError> {
    let mut dirs = Vec::new();
    list_dirs_into(root, Path::new(""), &mut dirs)?;
    Ok(dirs)
}

fn list_dirs_into(
    root: &Path,
    relative: &Path,
    out: &mut Vec<PathBuf>,
) -> Result<(), RepositoryError> {
    for entry in fs::read_dir(root.join(relative))? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let child = relative.join(entry.file_name());
            out.push(child.clone());
            list_dirs_into(root, &child, out)?;
        }
    }
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
            let copied = copy_atomic(&source_path, &target_path)?;
            entries.push(ManifestEntry {
                path: child_relative,
                size: copied.size,
                checksum: copied.checksum,
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
    matches!(name.to_str(), Some("postmaster.pid" | "postmaster.opts"))
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
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;
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

    // PGRA-003: a crash between the segment copy and the checksum-sidecar
    // write must be repairable by the retry pg_wal's archive_command
    // performs automatically, not permanent.
    #[test]
    fn archive_push_repairs_a_missing_sidecar_on_retry() {
        let (repository, root) = repository("archive-sidecar");
        repository.stanza_create().expect("stanza");
        let source = root.join("000000010000000000000002");
        fs::write(&source, b"wal-segment").expect("wal");
        repository.archive_push(&source).expect("push");

        let sidecar = root.join(
            "repo/archive/demo/wal/0000000100000000/000000010000000000000002.sha256",
        );
        assert!(sidecar.exists(), "sidecar written on the initial push");
        fs::remove_file(&sidecar).expect("simulate the crash window");

        let restored = root.join("restored-after-crash");
        assert!(
            repository
                .archive_get("000000010000000000000002", &restored)
                .is_err(),
            "segment must be unreadable while the sidecar is missing"
        );

        // The retry PostgreSQL's archiver performs automatically.
        repository
            .archive_push(&source)
            .expect("retry must repair the sidecar, not just report success");
        assert!(sidecar.exists(), "retry must have rewritten the sidecar");

        repository
            .archive_get("000000010000000000000002", &restored)
            .expect("segment must be readable again after the repair");
        assert_eq!(fs::read(restored).expect("read"), b"wal-segment");
        fs::remove_dir_all(root).expect("cleanup");
    }

    // PGRA-002: the manifest and archive checksums must be derived from the
    // bytes read from source, never from a second, separate read of the
    // destination copy_atomic just produced.
    #[test]
    fn copy_atomic_checksum_is_derived_from_source() {
        let root = temp("copy-atomic");
        fs::create_dir_all(&root).expect("root");
        let source = root.join("source.bin");
        let content = b"the quick brown fox jumps over the lazy dog";
        fs::write(&source, content).expect("source");
        let destination = root.join("nested/destination.bin");

        let copied = copy_atomic(&source, &destination).expect("copy");

        let mut expected = pg_sha2::PgSha256Ctx::init_sha256();
        expected.update(content);
        let expected_checksum = hex(&expected.final_sha256());

        assert_eq!(copied.checksum, expected_checksum);
        assert_eq!(copied.size, content.len() as u64);
        assert_eq!(fs::read(&destination).expect("destination"), content);
        assert_eq!(
            fs::metadata(&destination).expect("metadata").permissions().mode() & 0o777,
            0o600,
            "copied files must not be group/world readable"
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    // PGRA-005: a crash between the primary and the redundant-copy write in
    // write_info_pair must leave the stanza usable via the surviving valid
    // file, not brick every later operation.
    #[test]
    fn ensure_stanza_tolerates_one_stale_metadata_copy() {
        let (repository, root) = repository("stanza-fallback");
        repository.stanza_create().expect("stanza");

        let primary = root.join("repo/archive/demo/archive.info");
        let copy = root.join("repo/archive/demo/archive.info.copy");
        let good = fs::read(&primary).expect("primary readable");

        fs::write(&copy, b"garbage").expect("corrupt the copy");
        repository
            .check()
            .expect("stanza usable when only the redundant copy is stale");

        fs::write(&primary, &good).expect("restore primary");
        fs::write(&copy, &good).expect("restore copy");
        fs::write(&primary, b"garbage").expect("corrupt the primary instead");
        repository
            .check()
            .expect("stanza usable via fallback to the redundant copy");

        fs::write(&copy, b"also garbage").expect("corrupt both copies");
        assert!(
            repository.check().is_err(),
            "must fail only when BOTH copies are unusable"
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    // PGRA-001: a file-level copy of a live cluster has no backup_label and
    // no WAL start/stop range, so it can never be restored. Refuse it
    // rather than silently producing a backup that reports success.
    #[test]
    fn backup_refuses_a_live_cluster() {
        let (repository, root) = repository("live-cluster");
        let pg = root.join("pg");
        fs::write(pg.join("postmaster.pid"), b"12345\n/pg\n").expect("liveness marker");
        repository.stanza_create().expect("stanza");
        assert!(
            repository.backup_full().is_err(),
            "must refuse to back up a cluster with postmaster.pid present"
        );
        fs::remove_file(pg.join("postmaster.pid")).expect("stop the cluster");
        assert!(
            repository.backup_full().is_ok(),
            "must proceed once postmaster.pid is gone"
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn full_backup_restores_and_detects_corruption() {
        let (repository, root) = repository("backup");
        let pg = root.join("pg");
        fs::create_dir_all(pg.join("base")).expect("base");
        fs::create_dir_all(pg.join("pg_wal")).expect("wal");
        fs::write(pg.join("base/table"), b"table data").expect("table");
        // A real stopped cluster's pg_wal holds the shutdown checkpoint's
        // WAL segment; restore cannot start without it (PGRA-001/006).
        fs::write(pg.join("pg_wal/000000010000000000000001"), b"wal").expect("wal");
        // A real cluster also has directories PostgreSQL requires to exist
        // at startup that hold no files at all when the feature they back
        // is unused (pg_commit_ts, pg_twophase, ...) or nested (pg_logical/
        // snapshots) — none of these ever appear in the manifest, which
        // records files only. Proven with a directory name PostgreSQL does
        // not itself define, so this checks the general directory-mirroring
        // property rather than pinning a hardcoded, version-specific list.
        fs::create_dir_all(pg.join("pg_commit_ts")).expect("empty top-level dir");
        fs::create_dir_all(pg.join("pg_logical/snapshots")).expect("empty nested dir");
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
        assert_eq!(
            fs::read(restored.join("pg_wal/000000010000000000000001")).expect("restored wal"),
            b"wal",
            "pg_wal must be included, or the restored cluster can never recover"
        );
        for extra in ["pg_commit_ts", "pg_logical/snapshots"] {
            assert!(
                restored.join(extra).is_dir(),
                "an empty source directory must survive restore even with \
                 no manifest entry: {extra}"
            );
        }
        assert_eq!(
            fs::metadata(&restored).expect("root metadata").permissions().mode() & 0o777,
            0o700,
            "PostgreSQL refuses to start unless PGDATA is exactly u=rwx"
        );
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
