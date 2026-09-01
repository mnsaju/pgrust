# Draft: pg_cron native add-in

## Objective

Provide PostgreSQL-compatible `cron` SQL scheduling through a pgrust-native
crate and worker thread, rather than attempting to load the upstream C shared
library through an unavailable extension ABI.

## Reference behavior

- Upstream pg_cron: `src/pg_cron.c`, `src/task.c`, `src/entry.c`, and
  `sql/pg_cron.sql`.
- PostgreSQL worker/latch behavior: `src/backend/postmaster/bgworker.c` and
  `src/backend/storage/ipc/latch.c`.
- pgrust equivalents: `postmaster`, `pgsync`, `latch`, and scheduler/runtime
  crates.

## Approach

1. Ship the `cron` schema, catalog tables, SQL API, and compatibility GUCs as
   a built-in add-in with versioned SQL migrations.
2. Implement the scheduler as a managed pgrust postmaster thread with durable
   job state, wakeups, crash restart, and transaction-safe job execution.
3. Match pg_cron's cron parser, named-job replacement, one-active-run rule,
   and job-run history before adding pgrust-only scheduling enhancements.
4. Integrate scheduling priority with pgrust QoS only after compatibility mode
   is proven; it must never starve foreground database work.

## Acceptance tests

- Differential SQL tests for `cron.schedule`, `schedule_in_database`,
  `alter_job`, and `unschedule`.
- Minute, second, month-end, timezone, restart, and retry cases.
- Concurrent execution, job cancellation, permissions, and recovery tests.

## Non-goals

Loading the upstream C extension, remote-host job execution, or distributed
scheduling semantics in the first version.
