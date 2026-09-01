use std::{env, path::PathBuf, process::ExitCode};

use pgbackrest_compat::{Config, Repository};

fn main() -> ExitCode {
    let mut config_path = None;
    let mut stanza = None;
    let mut command = None;
    let mut arguments = Vec::new();
    for argument in env::args().skip(1) {
        if let Some(value) = argument.strip_prefix("--config=") {
            config_path = Some(PathBuf::from(value));
        } else if let Some(value) = argument.strip_prefix("--stanza=") {
            stanza = Some(value.to_string());
        } else if matches!(argument.as_str(), "-h" | "--help") {
            print_help();
            return ExitCode::SUCCESS;
        } else if command.is_none() && !argument.starts_with('-') {
            command = Some(argument);
        } else {
            arguments.push(argument);
        }
    }
    let Some(command) = command else {
        print_help();
        return ExitCode::from(2);
    };
    let Some(config_path) = config_path else {
        eprintln!("pgrust-pgbackrest: --config=PATH is required");
        return ExitCode::from(2);
    };
    let Some(stanza) = stanza else {
        eprintln!("pgrust-pgbackrest: --stanza=NAME is required");
        return ExitCode::from(2);
    };
    let repository = match Config::from_file(config_path, stanza) {
        Ok(config) => Repository::new(config),
        Err(error) => {
            eprintln!("pgrust-pgbackrest: {error}");
            return ExitCode::from(2);
        }
    };
    let result = match command.as_str() {
        "stanza-create" => repository.stanza_create(),
        "archive-push" => one_argument(&arguments, "archive-push source path")
            .and_then(|path| repository.archive_push(path)),
        "archive-get" => two_arguments(&arguments, "archive-get WAL destination")
            .and_then(|(name, destination)| repository.archive_get(name, destination)),
        "backup" => {
            if arguments
                .iter()
                .any(|argument| argument == "--type=diff" || argument == "--type=incr")
            {
                Err(pgbackrest_compat::RepositoryError::new(
                    "only full backups are implemented",
                ))
            } else {
                repository.backup_full().map(|info| {
                    println!(
                        "backup {}: {} files, {} bytes",
                        info.label, info.files, info.bytes
                    )
                })
            }
        }
        "restore" => match arguments.as_slice() {
            [destination] => repository
                .restore(None, destination)
                .map(|info| println!("restored {}", info.label)),
            [label, destination] => repository
                .restore(Some(label), destination)
                .map(|info| println!("restored {}", info.label)),
            _ => Err(pgbackrest_compat::RepositoryError::new(
                "restore requires DESTINATION or LABEL DESTINATION",
            )),
        },
        "check" | "verify" => repository.check(),
        "info" => repository.info().map(|backups| {
            for backup in backups {
                println!(
                    "{}: {} files, {} bytes",
                    backup.label, backup.files, backup.bytes
                );
            }
        }),
        _ => Err(pgbackrest_compat::RepositoryError::new(
            "unsupported command",
        )),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pgrust-pgbackrest: {error}");
            ExitCode::FAILURE
        }
    }
}

fn one_argument<'a>(
    arguments: &'a [String],
    usage: &str,
) -> Result<&'a str, pgbackrest_compat::RepositoryError> {
    match arguments {
        [argument] => Ok(argument),
        _ => Err(pgbackrest_compat::RepositoryError::new(format!(
            "{usage} requires exactly one argument"
        ))),
    }
}

fn two_arguments<'a>(
    arguments: &'a [String],
    usage: &str,
) -> Result<(&'a str, &'a str), pgbackrest_compat::RepositoryError> {
    match arguments {
        [first, second] => Ok((first, second)),
        _ => Err(pgbackrest_compat::RepositoryError::new(format!(
            "{usage} requires exactly two arguments"
        ))),
    }
}

fn print_help() {
    println!("usage: pgrust-pgbackrest --config=PATH --stanza=NAME COMMAND [ARGUMENTS]");
    println!(
        "commands: stanza-create, archive-push, archive-get, backup, restore, check, verify, info"
    );
}
