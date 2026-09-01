use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "pgrust-pgbackrest-cli-{}-{nonce}",
        std::process::id()
    ))
}

fn run(binary: &Path, config: &Path, arguments: &[&str]) {
    let output = Command::new(binary)
        .arg(format!("--config={}", config.display()))
        .arg("--stanza=demo")
        .args(arguments)
        .output()
        .expect("command starts");
    assert!(
        output.status.success(),
        "command {arguments:?} failed with {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

#[test]
fn cli_runs_local_archive_backup_restore_workflow() {
    let root = temp_root();
    let pg = root.join("pg");
    fs::create_dir_all(pg.join("base")).expect("base directory");
    fs::write(pg.join("PG_VERSION"), "18\n").expect("version");
    fs::write(pg.join("base/table"), "data").expect("data");
    let config = root.join("pgbackrest.conf");
    fs::write(
        &config,
        format!(
            "[global]\nrepo1-path={}\npg1-path={}\n",
            root.join("repo").display(),
            pg.display(),
        ),
    )
    .expect("config");
    let wal = root.join("000000010000000000000001");
    fs::write(&wal, "wal").expect("wal");
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_pgrust-pgbackrest"));

    run(&binary, &config, &["stanza-create"]);
    run(
        &binary,
        &config,
        &["archive-push", wal.to_str().expect("wal path")],
    );
    run(
        &binary,
        &config,
        &[
            "archive-get",
            "000000010000000000000001",
            root.join("retrieved-wal").to_str().expect("target path"),
        ],
    );
    run(&binary, &config, &["backup", "--type=full"]);
    run(
        &binary,
        &config,
        &[
            "restore",
            root.join("restore").to_str().expect("restore path"),
        ],
    );
    run(&binary, &config, &["check"]);
    assert_eq!(
        fs::read(root.join("restore/base/table")).expect("restored data"),
        b"data"
    );
    assert_eq!(
        fs::read(root.join("retrieved-wal")).expect("retrieved wal"),
        b"wal"
    );
    fs::remove_dir_all(root).expect("cleanup");
}
