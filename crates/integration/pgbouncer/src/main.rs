use std::{env, process::ExitCode};

use pgbouncer_compat::{run, Config};

fn main() -> ExitCode {
    let Some(path) = env::args_os().nth(1) else {
        eprintln!("usage: pgrust-pgbouncer <config-file>");
        return ExitCode::from(2);
    };
    let config = match Config::from_file(path) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("pgrust-pgbouncer: {error}");
            return ExitCode::from(2);
        }
    };
    if let Err(error) = run(config) {
        eprintln!("pgrust-pgbouncer: {error}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
