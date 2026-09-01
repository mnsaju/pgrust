# PgBouncer compatibility

PgBouncer is an external PostgreSQL connection pooler. pgrust does not embed
it and does not use it for query-aware replica routing. The first supported
compatibility target is a PgBouncer **session pool** using
`server_reset_query = DISCARD ALL`. PgBouncer does not run that reset query in
transaction pools by default, because applications in that mode must not rely
on session state.

Run the integration contract with a PostgreSQL 18 client toolset, PgBouncer,
and a built pgrust server binary:

```sh
PGRUST_BIN=target/release/postgres \
PGRUST_PGSHAREDIR=/usr/share/postgresql/18 \
PGRUST_TZDIR=/usr/share/zoneinfo \
cargo test -p discard --test pgbouncer_reset -- --ignored --nocapture
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
