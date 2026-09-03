//! pg_cron-equivalent native add-in (docs/roadmap/pg-cron-native-addon.md).
//! The `cron` schema/tables/SQL API live in `extension/pg_cron--1.0.sql` —
//! this crate is only the scheduler: a static launcher worker plus, per due
//! job, a dynamically-launched worker that runs it via SPI. See
//! `scheduler.rs` for the launcher/worker loop and `schedule.rs` for the
//! cron-expression parser.

pub mod gucs;
pub mod schedule;
pub mod scheduler;

#[cfg(test)]
mod tests;

use guc_tables::GucVarAccessors;

const LIBRARY: &str = "pg_cron";

pub fn init_seams() {
    guc_tables::vars::cron_database_name.install(GucVarAccessors {
        get: gucs::cron_database_name_string,
        set: gucs::set_cron_database_name_string,
    });
    guc_tables::vars::cron_max_running_jobs
        .install(GucVarAccessors { get: gucs::cron_max_running_jobs, set: gucs::set_cron_max_running_jobs });
    guc_tables::vars::cron_log_run
        .install(GucVarAccessors { get: gucs::cron_log_run, set: gucs::set_cron_log_run });
    guc_tables::vars::cron_log_statement
        .install(GucVarAccessors { get: gucs::cron_log_statement, set: gucs::set_cron_log_statement });

    dfmgr::register_builtin_library(dfmgr::BuiltinLibraryEntry {
        name: LIBRARY,
        lookup: |_| None,
        pg_init: Some(pg_init),
    });
}

/// `_PG_init` (pg_cron.c): registers the static launcher worker. Real
/// pg_cron does this unconditionally in `_PG_init`, but that only ever runs
/// under `shared_preload_libraries` in the first place for a statically
/// registered worker (`RegisterBackgroundWorker` itself refuses outside
/// that window) — the guard mirrors `pg_stat_statements::pg_init`'s.
fn pg_init() -> types_error::PgResult<()> {
    if !miscinit::process_shared_preload_libraries_in_progress() {
        return Ok(());
    }
    scheduler::PgCronLauncherRegister();
    Ok(())
}
