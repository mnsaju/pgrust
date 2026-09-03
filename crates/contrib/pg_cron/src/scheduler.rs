//! The scheduler: a static launcher worker (registered once, at
//! `shared_preload_libraries` time) that wakes every second, reads
//! `cron.job` from the configured database, and for each due, not-already-
//! running job dynamically launches a worker to execute it — mirrors
//! `crates/backend/replication/launcher/src/lib.rs`'s
//! `ApplyLauncherMain`/`logicalrep_worker_launch` shape (a long-lived
//! launcher scanning a catalog table and filling slots in a `Mutex`-guarded
//! pool before calling `RegisterDynamicBackgroundWorker`), adapted for cron
//! jobs instead of subscriptions.
//!
//! Unlike `LogicalRepCtx`, the slot pool here needs no shmem-init-time
//! pre-sizing step: it grows lazily up to `cron.max_running_jobs`, which is
//! sufficient because pgRust's workers are threads sharing one address
//! space — there is no separate shared-memory segment to size in advance.
#![allow(non_snake_case)]

use std::cell::Cell;

use pgsync::Mutex;

use bgworker::{BackgroundWorker, BgWorkerStartTime, BGW_EXTRALEN, BGW_NEVER_RESTART};
use elog::{elog as log_report, ereport};
use init_small::globals as g;
use mcx::{Mcx, MemoryContext};
use types_core::TimestampTz;
use types_error::{PgResult, LOG, WARNING};
use types_storage::waiteventset::{WL_EXIT_ON_PM_DEATH, WL_LATCH_SET, WL_TIMEOUT};

use crate::gucs;
use crate::schedule::{self, BrokenDownTime, CronSchedule};

const SRC: &str = "crates/contrib/pg_cron/src/scheduler.rs";
const NAPTIME_MS: i64 = 1000;
// Postgres epoch (2000-01-01) minus Unix epoch (1970-01-01), in seconds.
const PG_EPOCH_OFFSET_SECS: i64 = 946_684_800;

fn loc(line: i32, func: &'static str) -> types_error::ErrorLocation {
    types_error::ErrorLocation::new(SRC, line, func)
}

fn wait_event() -> u32 {
    thread_local! {
        static ID: Cell<u32> = const { Cell::new(0) };
    }
    ID.with(|cell| {
        let v = cell.get();
        if v != 0 {
            return v;
        }
        let id = waitevent::custom::WaitEventExtensionNew("PgCronMain")
            .unwrap_or(waitevent::PG_WAIT_EXTENSION);
        cell.set(id);
        id
    })
}

pub(crate) struct CronSlot {
    pub(crate) in_use: bool,
    pub(crate) jobid: i64,
    pub(crate) command: String,
    pub(crate) database: String,
    pub(crate) username: String,
}

struct CronCtx {
    slots: Vec<CronSlot>,
}

pgsync::process_global! {
    static CTX: Mutex<CronCtx> = Mutex::new(CronCtx { slots: Vec::new() });
}

fn with_ctx<R>(f: impl FnOnce(&mut CronCtx) -> R) -> R {
    let mut guard = CTX.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

#[derive(Clone)]
struct CronJobRow {
    jobid: i64,
    schedule: String,
    command: String,
    database: String,
    username: String,
    active: bool,
}

// PgCronLauncherRegister (pg_cron.c _PG_init's RegisterBackgroundWorker
// call): static registration, mirrors ApplyLauncherRegister.
pub fn PgCronLauncherRegister() {
    let bgw = BackgroundWorker {
        bgw_name: "pg_cron scheduler".to_string(),
        bgw_type: "pg_cron scheduler".to_string(),
        bgw_flags: bgworker::BGWORKER_SHMEM_ACCESS | bgworker::BGWORKER_BACKEND_DATABASE_CONNECTION,
        bgw_start_time: BgWorkerStartTime::RecoveryFinished,
        bgw_restart_time: 1,
        bgw_main: launcher_bgw_main,
        bgw_main_arg: 0,
        bgw_extra: [0; BGW_EXTRALEN],
        bgw_notify_pid: 0,
    };
    bgworker::RegisterBackgroundWorker(&bgw);
}

fn launcher_bgw_main(main_arg: u64) -> PgResult<()> {
    PgCronLauncherMain(main_arg)
}

// PgCronLauncherMain (pg_cron.c PgCronLauncherMain / entry.c's scan loop).
pub fn PgCronLauncherMain(_main_arg: u64) -> PgResult<()> {
    use procsignal::ThreadSignalHandler::{Fallible, Simple};

    let _ = log_report(LOG, "pg_cron scheduler started".to_string());

    procsignal::pqsignal_thread(
        procsignal::signums::SIGHUP,
        Simple(interrupt::SignalHandlerForConfigReload),
    );
    procsignal::pqsignal_thread(procsignal::signums::SIGTERM, Fallible(postgres::die));
    bgworker::BackgroundWorkerUnblockSignals();

    let database = gucs::cron_database_name();
    bgworker::BackgroundWorkerInitializeConnection(Some(&database), None, 0)?;

    let mut last_minute: Option<i64> = None;
    let mut reboot_fired = false;
    // (jobid, last-fired Unix-epoch-second) for "<N> seconds" schedules
    // only — standard cron fields need no per-job memory, since the
    // minute-boundary gate below already ensures each is evaluated at most
    // once per minute.
    let mut seconds_last_fired: Vec<(i64, i64)> = Vec::new();
    // Consecutive failures reading cron.job: e.g. the extension has not
    // been `CREATE EXTENSION`'d into this database yet, or (observed in
    // practice) a brief catalog-visibility lag for a handful of cycles
    // right after it was. Logged once, then throttled, and NEVER
    // propagated as a fatal error — this loop must survive cron.job being
    // unreadable for a while, the same way real pg_cron's launcher does
    // not exit just because the extension isn't installed yet. Letting it
    // propagate here previously crashed the whole bgworker on every such
    // cycle, and the postmaster's bgw_restart_time=1 turned that into a
    // multi-second crash-restart loop instead of a quiet retry.
    let mut consecutive_read_failures: u32 = 0;

    loop {
        postgres_seams::check_for_interrupts::call()?;

        let jobs = {
            let cx = MemoryContext::new("pg_cron job list");
            xact::StartTransactionCommand()?;
            let read = snapmgr::GetTransactionSnapshot()
                .and_then(|snap| snapmgr::PushActiveSnapshot(&snap))
                .and_then(|()| read_cron_jobs(cx.mcx()));
            match read {
                Ok(jobs) => {
                    snapmgr::PopActiveSnapshot()?;
                    xact::CommitTransactionCommand()?;
                    consecutive_read_failures = 0;
                    jobs
                }
                Err(e) => {
                    let _ = xact::AbortCurrentTransaction();
                    consecutive_read_failures += 1;
                    if consecutive_read_failures == 1 || consecutive_read_failures % 30 == 0 {
                        let _ = log_report(
                            WARNING,
                            format!("pg_cron: could not read cron.job, will retry: {e}"),
                        );
                    }
                    Vec::new()
                }
            }
        };

        let now_epoch = unix_epoch_seconds();
        let now_minute = now_epoch.div_euclid(60);
        let minute_changed = last_minute != Some(now_minute);
        let now_tm = broken_down_time(now_epoch);

        for job in &jobs {
            if !job.active {
                continue;
            }
            let schedule = match schedule::parse(&job.schedule) {
                Ok(s) => s,
                Err(e) => {
                    let _ = log_report(
                        WARNING,
                        format!(
                            "pg_cron: job {} has an invalid schedule \"{}\": {e}",
                            job.jobid, job.schedule
                        ),
                    );
                    continue;
                }
            };

            let due = match &schedule {
                CronSchedule::Fields { .. } => {
                    minute_changed && schedule::is_due(&schedule, now_tm)
                }
                CronSchedule::Seconds(interval) => {
                    let last = seconds_last_fired
                        .iter()
                        .find(|(id, _)| *id == job.jobid)
                        .map(|(_, t)| *t)
                        .unwrap_or(0);
                    if now_epoch - last >= i64::from(*interval) {
                        if let Some(entry) = seconds_last_fired
                            .iter_mut()
                            .find(|(id, _)| *id == job.jobid)
                        {
                            entry.1 = now_epoch;
                        } else {
                            seconds_last_fired.push((job.jobid, now_epoch));
                        }
                        true
                    } else {
                        false
                    }
                }
                CronSchedule::Reboot => !reboot_fired,
            };

            if due && !job_already_running(job.jobid) {
                launch_job_worker(job);
            }
        }

        if minute_changed {
            last_minute = Some(now_minute);
        }
        reboot_fired = true;

        let rc = latch::WaitLatch(
            g::MyLatch(),
            WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
            NAPTIME_MS,
            wait_event(),
        )?;
        if rc & WL_LATCH_SET != 0 {
            if let Some(l) = g::MyLatch() {
                latch::ResetLatch(l);
            }
            postgres_seams::check_for_interrupts::call()?;
        }
        if interrupt::ConfigReloadPending() {
            interrupt::SetConfigReloadPending(false);
            guc_file::ProcessConfigFile(types_guc::GucContext::PGC_SIGHUP)?;
        }
    }
}

fn job_already_running(jobid: i64) -> bool {
    with_ctx(|ctx| ctx.slots.iter().any(|s| s.in_use && s.jobid == jobid))
}

/// Pure slot-pool decision for `launch_job_worker`, split out so the
/// one-active-run-per-job / `cron.max_running_jobs` logic can be unit
/// tested against plain `CronSlot` vectors, without a live bgworker/SPI
/// stack backing `CTX`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SlotDecision {
    AlreadyRunning,
    PoolFull,
    Reuse(usize),
    Append,
}

pub(crate) fn decide_slot(slots: &[CronSlot], jobid: i64, max_running: usize) -> SlotDecision {
    if slots.iter().any(|s| s.in_use && s.jobid == jobid) {
        return SlotDecision::AlreadyRunning;
    }
    if slots.iter().filter(|s| s.in_use).count() >= max_running {
        return SlotDecision::PoolFull;
    }
    match slots.iter().position(|s| !s.in_use) {
        Some(idx) => SlotDecision::Reuse(idx),
        None => SlotDecision::Append,
    }
}

fn launch_job_worker(job: &CronJobRow) {
    let max_running = gucs::cron_max_running_jobs().max(0) as usize;
    let slot = with_ctx(|ctx| {
        let filled = CronSlot {
            in_use: true,
            jobid: job.jobid,
            command: job.command.clone(),
            database: job.database.clone(),
            username: job.username.clone(),
        };
        match decide_slot(&ctx.slots, job.jobid, max_running) {
            SlotDecision::AlreadyRunning => None,
            SlotDecision::PoolFull => Some(None),
            SlotDecision::Reuse(idx) => {
                ctx.slots[idx] = filled;
                Some(Some(idx))
            }
            SlotDecision::Append => {
                ctx.slots.push(filled);
                Some(Some(ctx.slots.len() - 1))
            }
        }
    });

    let slot = match slot {
        None => return, // already running
        Some(None) => {
            let _ = ereport(WARNING)
                .errmsg(format!(
                    "pg_cron: job {} is due but the running-job limit ({max_running}) is reached; skipping this run",
                    job.jobid
                ))
                .finish(loc(0, "launch_job_worker"));
            return;
        }
        Some(Some(idx)) => idx,
    };

    let bgw = BackgroundWorker {
        bgw_name: format!("pg_cron job {}", job.jobid),
        bgw_type: "pg_cron job".to_string(),
        bgw_flags: bgworker::BGWORKER_SHMEM_ACCESS | bgworker::BGWORKER_BACKEND_DATABASE_CONNECTION,
        bgw_start_time: BgWorkerStartTime::RecoveryFinished,
        bgw_restart_time: BGW_NEVER_RESTART,
        bgw_main: job_worker_bgw_main,
        bgw_main_arg: slot as u64,
        bgw_extra: [0; BGW_EXTRALEN],
        bgw_notify_pid: 0,
    };
    match bgworker::RegisterDynamicBackgroundWorker(bgw) {
        Ok(Some(_handle)) => {}
        Ok(None) => {
            let _ = log_report(
                WARNING,
                format!(
                    "pg_cron: out of background worker slots; could not launch job {}",
                    job.jobid
                ),
            );
            with_ctx(|ctx| ctx.slots[slot].in_use = false);
        }
        Err(e) => {
            let _ = log_report(
                WARNING,
                format!("pg_cron: failed to launch job {}: {e}", job.jobid),
            );
            with_ctx(|ctx| ctx.slots[slot].in_use = false);
        }
    }
}

// The per-job worker's bgw_main. Runs the job's command as its own
// transaction, then records the outcome into cron.job_run_details as a
// SEPARATE, later transaction — so a job that errors and rolls back still
// gets its failure recorded, rather than the run-details row rolling back
// along with it.
fn job_worker_bgw_main(slot_arg: u64) -> PgResult<()> {
    use procsignal::ThreadSignalHandler::Fallible;

    let slot = slot_arg as usize;
    let (jobid, command, database, username) = with_ctx(|ctx| {
        let s = &ctx.slots[slot];
        (
            s.jobid,
            s.command.clone(),
            s.database.clone(),
            s.username.clone(),
        )
    });

    procsignal::pqsignal_thread(procsignal::signums::SIGTERM, Fallible(postgres::die));
    bgworker::BackgroundWorkerUnblockSignals();
    bgworker::BackgroundWorkerInitializeConnection(Some(&database), Some(&username), 0)?;

    if gucs::cron_log_statement() {
        let _ = log_report(LOG, format!("pg_cron: running job {jobid}: {command}"));
    }

    let start = timestamp_seams::get_current_timestamp::call();
    xact::StartTransactionCommand()?;
    let outcome = snapmgr::PushActiveSnapshot(&snapmgr::GetTransactionSnapshot()?)
        .and_then(|()| run_job_command(&command));
    let message = match &outcome {
        Ok(()) => None,
        Err(e) => Some(e.to_string()),
    };
    match &outcome {
        Ok(()) => {
            let _ = snapmgr::PopActiveSnapshot();
            xact::CommitTransactionCommand()?;
        }
        Err(_) => {
            let _ = xact::AbortCurrentTransaction();
        }
    }
    let status = if outcome.is_ok() {
        "succeeded"
    } else {
        "failed"
    };
    let end = timestamp_seams::get_current_timestamp::call();

    if gucs::cron_log_run() {
        if let Err(e) = record_job_run(
            jobid,
            &database,
            &username,
            &command,
            status,
            message.as_deref(),
            start,
            end,
        ) {
            let _ = log_report(
                WARNING,
                format!("pg_cron: could not record run details for job {jobid}: {e}"),
            );
        }
    }

    with_ctx(|ctx| ctx.slots[slot].in_use = false);
    Ok(())
}

fn run_job_command(command: &str) -> PgResult<()> {
    spi::SPI_connect()?;
    let result = spi::SPI_execute(command, false, 0);
    spi::SPI_finish()?;
    result.map(|_| ())
}

fn record_job_run(
    jobid: i64,
    database: &str,
    username: &str,
    command: &str,
    status: &str,
    message: Option<&str>,
    start: TimestampTz,
    end: TimestampTz,
) -> PgResult<()> {
    xact::StartTransactionCommand()?;
    let sql = format!(
        "INSERT INTO cron.job_run_details \
         (jobid, job_pid, database, username, command, status, return_message, start_time, end_time) \
         VALUES ({jobid}, {pid}, {db}, {user}, {cmd}, {status}, {message}, \
         to_timestamp({start}::double precision / 1000000.0 + {epoch}), \
         to_timestamp({end}::double precision / 1000000.0 + {epoch}))",
        pid = g::MyProcPid(),
        db = quote_literal(database),
        user = quote_literal(username),
        cmd = quote_literal(command),
        status = quote_literal(status),
        message = message.map(quote_literal).unwrap_or_else(|| "NULL".to_string()),
        epoch = PG_EPOCH_OFFSET_SECS,
    );
    snapmgr::PushActiveSnapshot(&snapmgr::GetTransactionSnapshot()?)?;
    spi::SPI_connect()?;
    let result = spi::SPI_execute(&sql, false, 0);
    spi::SPI_finish()?;
    snapmgr::PopActiveSnapshot()?;
    result?;
    xact::CommitTransactionCommand()?;
    Ok(())
}

/// Standard SQL string-literal quoting (double embedded single quotes) —
/// correct under `standard_conforming_strings = on`, PostgreSQL's default
/// since 9.1, which is what pgRust targets.
fn quote_literal(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('\'');
    for ch in text.chars() {
        if ch == '\'' {
            out.push('\'');
        }
        out.push(ch);
    }
    out.push('\'');
    out
}

fn read_cron_jobs(mcx: Mcx<'_>) -> PgResult<Vec<CronJobRow>> {
    spi::SPI_connect()?;
    let outcome = spi::SPI_execute(
        "SELECT jobid, schedule, command, database, username, active FROM cron.job",
        true,
        0,
    );
    let rows = match outcome {
        Ok(ret) if ret == spi::SPI_OK_SELECT => {
            let proc = spi::SPI_processed() as usize;
            match spi::SPI_tuptable() {
                Some(h) => spi::tuptable_with(h, |t| -> PgResult<Vec<CronJobRow>> {
                    let mut out = Vec::with_capacity(proc);
                    for i in 0..proc {
                        let tuple = &t.vals[i];
                        let jobid_text = column_text(mcx, tuple, &t.tupdesc, 1)?;
                        let jobid: i64 = jobid_text.parse().map_err(|_| bad_job_row("jobid"))?;
                        out.push(CronJobRow {
                            jobid,
                            schedule: column_text(mcx, tuple, &t.tupdesc, 2)?,
                            command: column_text(mcx, tuple, &t.tupdesc, 3)?,
                            database: column_text(mcx, tuple, &t.tupdesc, 4)?,
                            username: column_text(mcx, tuple, &t.tupdesc, 5)?,
                            active: column_text(mcx, tuple, &t.tupdesc, 6)? == "t",
                        });
                    }
                    Ok(out)
                })?,
                None => Vec::new(),
            }
        }
        Ok(_) => Vec::new(),
        Err(e) => {
            let _ = spi::SPI_finish();
            return Err(e);
        }
    };
    spi::SPI_finish()?;
    Ok(rows)
}

fn column_text(
    mcx: Mcx<'_>,
    tuple: &types_tuple::HeapTupleData<'_>,
    tupdesc: &types_tuple::TupleDescData<'_>,
    column: i32,
) -> PgResult<String> {
    let bytes = spi::SPI_getvalue(mcx, tuple, tupdesc, column)?;
    Ok(bytes
        .map(|b| String::from_utf8_lossy(b).into_owned())
        .unwrap_or_default())
}

fn bad_job_row(field: &str) -> Box<types_error::PgError> {
    types_error::PgError::error(format!(
        "pg_cron: cron.job.{field} has an unexpected format"
    ))
    .into()
}

fn unix_epoch_seconds() -> i64 {
    let now: TimestampTz = timestamp_seams::get_current_timestamp::call();
    now.div_euclid(1_000_000) + PG_EPOCH_OFFSET_SECS
}

/// UTC calendar fields for cron matching. No session timezone involved on
/// purpose — v1 evaluates every schedule in UTC (see the design doc scope
/// note); a per-job or GUC-configurable timezone is future work, not a v1
/// requirement.
fn broken_down_time(unix_seconds: i64) -> BrokenDownTime {
    let days = unix_seconds.div_euclid(86_400);
    let mut seconds_of_day = unix_seconds.rem_euclid(86_400);
    let hour = (seconds_of_day / 3600) as u32;
    seconds_of_day -= i64::from(hour) * 3600;
    let minute = (seconds_of_day / 60) as u32;

    // civil_from_days (Howard Hinnant's algorithm): days since 1970-01-01 ->
    // (year, month, day). Avoids depending on adt_datetime's PG-epoch-based
    // Julian-day helpers here, since the input is already Unix days.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let year = if month <= 2 { y + 1 } else { y };
    let _ = year; // not needed for cron matching, kept for clarity of the derivation

    // day_of_week: 1970-01-01 was a Thursday (weekday 4, 0 = Sunday).
    let day_of_week = ((days % 7 + 7 + 4) % 7) as u32;

    BrokenDownTime {
        minute,
        hour,
        day_of_month: day,
        month,
        day_of_week,
    }
}
