# Draft: PgBouncer compatibility

## Objective

Make pgrust a safe PgBouncer backend in session and transaction pooling modes.
PgBouncer is an external connection pooler; this is a server-compatibility
project, not an in-process extension or a query-routing implementation.

## Reference behavior

- PgBouncer's pool modes and feature matrix:
  `pgbouncer/doc/features.md`.
- PostgreSQL reset semantics: `src/backend/commands/discard.c` and
  `src/backend/utils/misc/guc.c`.
- pgrust's existing reference port: `crates/backend/commands/discard` and
  the `backend-commands-discard` row in `CATALOG.tsv`.

## Approach

1. Freeze a wire-level compatibility suite against PgBouncer's session and
   transaction pools using both PostgreSQL 18.3 and pgrust as backends.
2. Verify authentication, startup parameters, extended protocol, cancellation,
   SSL/TLS negotiation, and `DISCARD ALL`/server-reset behavior.
3. For transaction pooling, reject or document PostgreSQL session features that
   cannot be safely preserved (session `SET`, `LISTEN`, holdable cursors,
   session advisory locks, and SQL `PREPARE`).
4. Add a production configuration example that separates connection pooling
   from read-replica routing; PgBouncer must not be presented as a SQL-aware
   load balancer.

## Acceptance tests

- Byte-for-byte frontend/backend traces for simple and extended queries.
- Pool checkout reuse after `DISCARD ALL`, including prepared-statement cache
  reset and temp-object cleanup.
- Concurrent cancellation and authentication failure cases.
- PostgreSQL-vs-pgrust differential run in session and transaction modes.

## Non-goals

Implementing PgBouncer, replica/read-write routing, or statement pooling as a
production default.
