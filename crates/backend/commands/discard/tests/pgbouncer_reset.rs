//! Live PgBouncer compatibility contract for pgrust's `DISCARD ALL` path.
//!
//! PgBouncer runs `server_reset_query` when a server is released from a
//! session pool.  Transaction pooling deliberately does not run that query by
//! default, because clients must not depend on session state there.  Keep this
//! test focused on the session-pool contract.

use std::{
    env,
    fs,
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Output},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const POSTGRES_USER: &str = "postgres";
const DATABASE: &str = "postgres";

struct Process {
    child: Child,
}

impl Process {
    fn start(command: &mut Command, label: &str) -> Self {
        let child = command
            .spawn()
            .unwrap_or_else(|error| panic!("could not start {label}: {error}"));
        Self { child }
    }

    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Harness {
    workdir: PathBuf,
    psql: String,
    pgrust_port: u16,
    pgbouncer_port: u16,
    pgrust: Process,
    pgbouncer: Process,
}

impl Harness {
    fn start() -> Self {
        let pgrust_bin = required_env("PGRUST_BIN");
        let initdb = env::var("INITDB").unwrap_or_else(|_| "initdb".to_string());
        let psql = env::var("PSQL").unwrap_or_else(|_| "psql".to_string());
        let pgbouncer_bin =
            env::var("PGBOUNCER").unwrap_or_else(|_| "pgbouncer".to_string());
        for name in ["PGRUST_PGSHAREDIR", "PGRUST_TZDIR"] {
            let _ = required_env(name);
        }

        let workdir = new_workdir();
        let data = workdir.join("data");
        run_success(
            Command::new(&initdb)
                .arg("-D")
                .arg(&data)
                .args(["--no-locale", "--encoding=UTF8", "-U", POSTGRES_USER]),
            "initdb",
        );
        // This test owns the data directory and uses local loopback clients;
        // trust avoids coupling the PgBouncer reset contract to a password
        // provisioning path.
        fs::write(
            data.join("pg_hba.conf"),
            "local all all trust\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\n",
        )
        .expect("could not write isolated pg_hba.conf");

        let pgrust_port = unused_port();
        let pgbouncer_port = unused_port();
        let pgrust_log = workdir.join("pgrust.log");
        let mut pgrust_command = Command::new(pgrust_bin);
        pgrust_command
            .arg("-D")
            .arg(&data)
            .arg("-p")
            .arg(pgrust_port.to_string())
            .args([
                "-c",
                "listen_addresses=127.0.0.1",
                "-c",
                "io_method=sync",
                "-c",
                "max_stack_depth=60000",
            ])
            .stdout(fs::File::create(&pgrust_log).expect("could not create pgrust log"))
            .stderr(
                fs::File::options()
                    .append(true)
                    .open(&pgrust_log)
                    .expect("could not open pgrust log"),
            );
        let pgrust = Process::start(&mut pgrust_command, "pgrust");
        wait_for(&psql, pgrust_port, "pgrust", &workdir);

        let auth_file = workdir.join("users.txt");
        fs::write(&auth_file, "\"postgres\" \"\"\n")
            .expect("could not write PgBouncer auth file");
        let config = workdir.join("pgbouncer.ini");
        fs::write(
            &config,
            format!(
                concat!(
                    "[databases]\n",
                    "{DATABASE} = host=127.0.0.1 port={pgrust_port} dbname={DATABASE}\n\n",
                    "[pgbouncer]\n",
                    "listen_addr = 127.0.0.1\n",
                    "listen_port = {pgbouncer_port}\n",
                    "auth_type = trust\n",
                    "auth_file = {}\n",
                    "pool_mode = session\n",
                    "server_reset_query = DISCARD ALL\n",
                    "pidfile = {}\n",
                    "logfile = {}\n",
                ),
                auth_file.display(),
                workdir.join("pgbouncer.pid").display(),
                workdir.join("pgbouncer.log").display(),
            ),
        )
        .expect("could not write PgBouncer configuration");
        let mut pgbouncer_command = Command::new(pgbouncer_bin);
        pgbouncer_command
            .arg(&config)
            .stdout(
                fs::File::create(workdir.join("pgbouncer.stdout"))
                    .expect("could not create PgBouncer stdout log"),
            )
            .stderr(
                fs::File::options()
                    .append(true)
                    .open(workdir.join("pgbouncer.stdout"))
                    .expect("could not open PgBouncer stdout log"),
            );
        let pgbouncer = Process::start(&mut pgbouncer_command, "PgBouncer");
        wait_for(&psql, pgbouncer_port, "PgBouncer", &workdir);

        Self {
            workdir,
            psql,
            pgrust_port,
            pgbouncer_port,
            pgrust,
            pgbouncer,
        }
    }

    fn pooled(&self, sql: &str) -> Output {
        psql(&self.psql, self.pgbouncer_port, sql)
    }

    fn direct(&self, sql: &str) -> Output {
        psql(&self.psql, self.pgrust_port, sql)
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.pgbouncer.stop();
        self.pgrust.stop();
        let _ = fs::remove_dir_all(&self.workdir);
    }
}

#[test]
#[ignore = "requires initdb, psql, PgBouncer, and PGRUST_BIN"]
fn session_pool_reset_discards_client_session_state() {
    let harness = Harness::start();
    let baseline_work_mem = output_text(harness.pooled("SHOW work_mem"), "read baseline work_mem");

    run_success(
        &mut psql_command(
            &harness.psql,
            harness.pgbouncer_port,
            concat!(
                "SET work_mem = '1MB'; ",
                "PREPARE pgbouncer_reset_plan AS SELECT 1; ",
                "CREATE TEMP TABLE pgbouncer_reset_temp (id integer); ",
                "SELECT pg_advisory_lock(424242);",
            ),
        ),
        "create session state through PgBouncer",
    );

    assert_eq!(
        output_text(harness.pooled("SHOW work_mem"), "read reset work_mem"),
        baseline_work_mem,
        "server_reset_query leaked a GUC into the next PgBouncer client",
    );
    assert!(
        !harness.pooled("EXECUTE pgbouncer_reset_plan").status.success(),
        "server_reset_query leaked a SQL prepared statement into the next PgBouncer client",
    );
    assert_eq!(
        output_text(
            harness.pooled(
                "SELECT to_regclass('pg_temp.pgbouncer_reset_temp') IS NULL",
            ),
            "check reset temporary table",
        ),
        "t",
        "server_reset_query leaked a temporary table into the next PgBouncer client",
    );
    assert_eq!(
        output_text(
            harness.direct("SELECT pg_try_advisory_lock(424242)"),
            "check reset advisory lock",
        ),
        "t",
        "server_reset_query leaked a session advisory lock",
    );
    run_success(
        &mut psql_command(
            &harness.psql,
            harness.pgrust_port,
            "SELECT pg_advisory_unlock(424242)",
        ),
        "release test advisory lock",
    );
}

fn required_env(name: &str) -> String {
    env::var(name).unwrap_or_else(|_| panic!("{name} must be set for this integration test"))
}

fn new_workdir() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock moved before Unix epoch")
        .as_nanos();
    let path = env::temp_dir().join(format!(
        "pgrust-pgbouncer-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&path).expect("could not create integration-test directory");
    path
}

fn unused_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("could not reserve a loopback port")
        .local_addr()
        .expect("reserved port has no address")
        .port()
}

fn wait_for(psql_bin: &str, port: u16, label: &str, workdir: &Path) {
    for _ in 0..100 {
        if psql(psql_bin, port, "SELECT 1").status.success() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("timed out waiting for {label} in {}", workdir.display());
}

fn psql(psql_bin: &str, port: u16, sql: &str) -> Output {
    psql_command(psql_bin, port, sql)
        .output()
        .unwrap_or_else(|error| panic!("could not run psql: {error}"))
}

fn psql_command(psql_bin: &str, port: u16, sql: &str) -> Command {
    let mut command = Command::new(psql_bin);
    command
        .args(["-X", "-A", "-t", "-q", "-h", "127.0.0.1", "-p"])
        .arg(port.to_string())
        .args([
            "-U",
            POSTGRES_USER,
            "-d",
            DATABASE,
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
        ])
        .arg(sql);
    command
}

fn run_success(command: &mut Command, operation: &str) {
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("could not run {operation}: {error}"));
    assert!(
        output.status.success(),
        "{operation} failed with {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

fn output_text(output: Output, operation: &str) -> String {
    assert!(
        output.status.success(),
        "{operation} failed with {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    String::from_utf8(output.stdout)
        .expect("psql returned non-UTF-8 output")
        .trim()
        .to_string()
}
