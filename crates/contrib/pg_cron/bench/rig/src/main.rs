// pg_cron parser/is_due microbench. No C reference here (unlike the
// tidstore/dshash rigs): there's no line-for-line-ported C implementation
// to verify parity against, so this just tracks pgrust's own numbers over
// time as a regression signal, not a comparison.
//
// Why this specific hot path: `PgCronLauncherMain`'s scan loop
// (crates/contrib/pg_cron/src/scheduler.rs) calls `schedule::parse` on
// EVERY row in `cron.job`, on EVERY ~1-second tick, unconditionally --
// before the `minute_changed` gate that limits `is_due`'s own evaluation
// to once per minute. So parse cost multiplies directly by job count and
// tick rate; `is_due` cost multiplies by job count once per minute. The
// "at N jobs" benchmark below turns that into a concrete ms-per-tick
// number.

use pg_cron::schedule::{is_due, parse, BrokenDownTime, CronSchedule};
use std::time::{Duration, Instant};

const REPS: u32 = 7;

// A representative mix of the syntax real schedules use: plain fields,
// ranges, lists, steps, name aliases, and the two non-Fields variants.
const EXPRESSIONS: &[&str] = &[
    "* * * * *",
    "30 6 * * *",
    "0 9-17 * * 1,3,5",
    "*/15 * * * *",
    "0 0 * JAN,Feb mon-Fri",
    "0 0 1,15 * 1",
    "5 seconds",
    "@reboot",
];

fn now() -> BrokenDownTime {
    BrokenDownTime { minute: 30, hour: 12, day_of_month: 15, month: 6, day_of_week: 3 }
}

fn best_of<F: FnMut() -> Duration>(mut run: F) -> Duration {
    (0..REPS).map(|_| run()).min().unwrap()
}

fn bench_parse(iters: u64) -> f64 {
    let dur = best_of(|| {
        let t0 = Instant::now();
        for i in 0..iters {
            let expr = EXPRESSIONS[(i as usize) % EXPRESSIONS.len()];
            std::hint::black_box(parse(expr).unwrap());
        }
        t0.elapsed()
    });
    dur.as_nanos() as f64 / iters as f64
}

fn bench_is_due(iters: u64) -> f64 {
    let schedules: Vec<CronSchedule> =
        EXPRESSIONS.iter().map(|e| parse(e).unwrap()).filter(|s| matches!(s, CronSchedule::Fields { .. })).collect();
    let tm = now();
    let dur = best_of(|| {
        let t0 = Instant::now();
        for i in 0..iters {
            let s = &schedules[(i as usize) % schedules.len()];
            std::hint::black_box(is_due(s, tm));
        }
        t0.elapsed()
    });
    dur.as_nanos() as f64 / iters as f64
}

// One simulated launcher tick over `n_jobs` rows: parse every job (as the
// real loop does, unconditionally) then evaluate is_due for each (as the
// real loop does, only on a minute boundary -- the more expensive of the
// two cases for this measurement).
fn bench_tick(n_jobs: usize) -> Duration {
    let job_exprs: Vec<&str> = (0..n_jobs).map(|i| EXPRESSIONS[i % EXPRESSIONS.len()]).collect();
    let tm = now();
    best_of(|| {
        let t0 = Instant::now();
        for expr in &job_exprs {
            if let Ok(s) = parse(expr) {
                std::hint::black_box(is_due(&s, tm));
            }
        }
        t0.elapsed()
    })
}

fn main() {
    println!("pg_cron parser/is_due microbench (best of {REPS} reps)\n");

    let ns = bench_parse(2_000_000);
    println!("parse:               {ns:>8.1} ns/op");

    let ns = bench_is_due(5_000_000);
    println!("is_due:              {ns:>8.1} ns/op");

    println!("\nsimulated launcher tick (parse + is_due over N jobs, one scan):");
    for n in [100usize, 1_000, 10_000] {
        let dur = bench_tick(n);
        println!(
            "  {n:>6} jobs: {:>8.3} ms/tick  ({:>6.1} ns/job)",
            dur.as_secs_f64() * 1000.0,
            dur.as_nanos() as f64 / n as f64
        );
    }
}
