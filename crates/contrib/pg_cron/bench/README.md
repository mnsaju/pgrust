# pg_cron parser microbench

```
cd crates/contrib/pg_cron/bench/rig
cargo run --release
```

Standalone workspace (like `tidstore`'s and `dshash`'s `bench/rig`), so it
builds independently of the main repo's `Cargo.lock`. Needs `libre2-dev`
installed (release-profile builds refuse a Spencer-only regex engine) —
same requirement as building the main `postgres` binary in release mode.

Measures `schedule::parse`/`schedule::is_due` (`Instant::now()`, best of 7
reps, ns/op), plus a "simulated launcher tick" number: `PgCronLauncherMain`
(`../src/scheduler.rs`) calls `parse` on every row in `cron.job` on every
~1-second tick, unconditionally, before the once-a-minute `is_due` gate — so
this is the number that answers "how many scheduled jobs can one launcher
carry without its scan cycle eating into the tick interval."

No C reference and no baseline comparison, unlike the tidstore/dshash rigs:
there's no line-for-line-ported C implementation to verify parity against,
and pg_cron's architecture (in-process threaded scheduler) isn't comparable
to upstream C pg_cron's (separate-process background worker) the way a
ported data structure is. This is a regression-tracking tool for pgrust's
own numbers over time, not a competitive benchmark — there is no pass/fail
threshold.

Last measured (this repo's dev container, informational only): ~380 ns/op
to parse one schedule, ~6 ns/op to evaluate `is_due` once parsed, and a
full scan-tick cost that scales linearly at ~355 ns/job — so even 10,000
scheduled jobs cost well under 4 ms per tick, negligible against the
1-second cadence. In other words: the missing parse-caching this comment
points at is not worth fixing as a performance issue at any realistic job
count.
