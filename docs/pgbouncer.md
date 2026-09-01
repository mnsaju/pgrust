# PgBouncer compatibility

`pgrust-pgbouncer` is a Rust reimplementation of the PgBouncer connection
pooler role. It runs as a separate process and is not a query-aware replica
router. Its first implemented mode is a **session pool** using
`server_reset_query = DISCARD ALL`. PgBouncer does not run that reset query in
transaction pools by default, because applications in that mode must not rely
on session state; transaction and statement pooling are not implemented yet.

Run the integration contract with a PostgreSQL 18 client toolset, PgBouncer,
and a built pgrust server binary:

```sh
PGRUST_BIN=target/release/postgres \
PGBOUNCER=target/release/pgrust-pgbouncer \
PGRUST_PGSHAREDIR=/usr/share/postgresql/18 \
PGRUST_TZDIR=/usr/share/zoneinfo \
cargo test -p pgbouncer_compat --test session_reset -- --ignored --nocapture
```

The Rust integration test starts an isolated pgrust data directory and
PgBouncer instance.
It proves that PgBouncer's reset query removes client-visible session state:

- a changed GUC;
- a SQL prepared statement;
- a temporary table; and
- a session advisory lock.

It tests the same public wire path an application uses.  Session pooling,
authentication variants, cancellation, TLS, and prepared-statement tracking
remain follow-up compatibility slices.
