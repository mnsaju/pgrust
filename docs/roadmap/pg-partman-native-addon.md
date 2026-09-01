# Draft: pg_partman native add-in

## Objective

Provide pg_partman-compatible management for PostgreSQL declarative
time- and number-based partitions, including retention and optional automatic
maintenance.

## Reference behavior

- Upstream pg_partman: `src/pg_partman_bgw.c`, `sql/pg_partman.sql`, and the
  `doc/` maintenance/migration specifications.
- PostgreSQL partition DDL: `src/backend/commands/tablecmds.c` and partition
  pruning: `src/backend/partitioning/`.
- pgrust's partition DDL, planner, and postmaster-thread ports.

## Approach

1. Implement the versioned SQL catalog and `partman` schema over pgrust's
   declarative partitioning—not the retired trigger-based model.
2. Add time and integer range maintenance first: pre-create children,
   apply retention, and preserve ownership/privileges/default partitions.
3. Offer the background worker only after `run_maintenance` is fully usable
   manually; it runs as a managed postmaster thread with explicit database and
   role configuration.
4. Add migration helpers and subpartitioning only after DDL, transaction, WAL,
   and crash-recovery tests are stable.

## Acceptance tests

- Differential `create_parent`/`run_maintenance` SQL cases for time and ID
  ranges, retention, default partitions, and restart recovery.
- Compare generated child DDL, permissions, query plans, and query results
  against PostgreSQL 18 plus pinned pg_partman.
- Concurrent inserts during partition creation/retention and WAL-replay tests.

## Non-goals

The deprecated trigger partitioning model, automatic migration of every legacy
schema, or loading the upstream extension through a C ABI.
