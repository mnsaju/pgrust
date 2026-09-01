# PgBouncer compatibility

PgBouncer is an external PostgreSQL connection pooler. pgrust does not embed
it and does not use it for query-aware replica routing. The first supported
compatibility target is a PgBouncer **transaction pool** using
`server_reset_query = DISCARD ALL`.

Run the integration contract with a PostgreSQL 18 client toolset, PgBouncer,
and a built pgrust server binary:

```sh
PGRUST_BIN=target/release/postgres \
PGRUST_PGSHAREDIR=/usr/share/postgresql/18 \
PGRUST_TZDIR=/usr/share/zoneinfo \
tools/pgbouncer-compat.sh
```

The harness starts an isolated pgrust data directory and PgBouncer instance.
It proves that PgBouncer's reset query removes client-visible session state:

- a changed GUC;
- a SQL prepared statement;
- a temporary table; and
- a session advisory lock.

It tests the same public wire path an application uses.  Session pooling,
authentication variants, cancellation, TLS, and prepared-statement tracking
remain follow-up compatibility slices.
