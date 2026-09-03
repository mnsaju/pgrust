//! pg_cron's own GUCs. Matches real pg_cron's most-used settings; does NOT
//! expose `cron.use_background_workers` (its toggle between background-worker
//! and same-connection job execution) — this implementation always uses
//! background workers, so that knob would have nothing to switch.

guc_tables::session_guc_string!(
    CRON_DATABASE_NAME,
    cron_database_name_string,
    set_cron_database_name_string,
    Some("postgres")
);

guc_tables::session_guc_int!(
    CRON_MAX_RUNNING_JOBS,
    cron_max_running_jobs,
    set_cron_max_running_jobs,
    32
);

guc_tables::session_guc_bool!(CRON_LOG_RUN, cron_log_run, set_cron_log_run, true);

guc_tables::session_guc_bool!(
    CRON_LOG_STATEMENT,
    cron_log_statement,
    set_cron_log_statement,
    true
);

/// `cron.database_name` with its boot default resolved — the launcher's
/// connect target is never allowed to be genuinely unset.
pub fn cron_database_name() -> String {
    cron_database_name_string().unwrap_or_else(|| "postgres".to_string())
}
