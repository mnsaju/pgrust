use std::{env, process::ExitCode};

use pgbouncer_compat::{run, Config};

fn main() -> ExitCode {
    let mut path = None;
    for argument in env::args_os().skip(1) {
        match argument.to_str() {
            Some("--version") => {
                println!("pgrust-pgbouncer");
                return ExitCode::SUCCESS;
            }
            Some("-h" | "--help") => {
                println!("usage: pgrust-pgbouncer [--quiet] <config-file>");
                return ExitCode::SUCCESS;
            }
            Some("-q" | "--quiet") => {}
            _ if path.is_none() => path = Some(argument),
            _ => {}
        }
    }
    let Some(path) = path else {
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
