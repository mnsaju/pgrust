use std::{env, process::ExitCode};

use pgbouncer_compat::{run, Config};

fn main() -> ExitCode {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    if arguments
        .iter()
        .any(|argument| matches!(argument.to_str(), Some("--version")))
    {
        println!("pgrust-pgbouncer");
        return ExitCode::SUCCESS;
    }
    if arguments
        .iter()
        .any(|argument| matches!(argument.to_str(), Some("-h" | "--help")))
    {
        println!("usage: pgrust-pgbouncer [--quiet] <config-file>");
        return ExitCode::SUCCESS;
    }
    let path = arguments
        .into_iter()
        .find(|argument| !matches!(argument.to_str(), Some("-q" | "--quiet")));
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
