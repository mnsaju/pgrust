# pgrust-pgbouncer

This directory contains the Rust PgBouncer reimplementation and its live
PostgreSQL-wire compatibility tests. The binary accepts the normal
`pgbouncer.ini` positional argument and currently implements TCP listeners,
the `[databases]` mapping, `pool_mode = session`, backend startup forwarding,
simple-query and extended-protocol forwarding, reset-before-reuse, bounded
per-database pools (`default_pool_size` or a database `pool_size` override),
and stale-idle-connection detection before reuse. Reused clients receive the
actual backend `ParameterStatus` values captured during the initial startup.

The initial implementation uses one operating-system thread per client. This
is intentional for the first compatibility slice and will be replaced with an
async reactor before connection counts are expected to scale substantially.
Cancellation routing is not implemented yet, so the pooler deliberately does
not send a virtual `BackendKeyData` message to clients.

The implementation is built from PgBouncer's documented behavior and its
public test suite; no PgBouncer C or Python source is vendored here.

The broader upstream suite includes TLS, SCRAM/MD5/LDAP authentication,
administrative commands, cancellation, COPY, timeout and pool limits, DNS
failover, replication, online restart, and peering. These remain tracked
implementation work and must not be represented as passing until their Rust
ports run successfully against pgrust.

## Test runner

Run the native Rust suite from the repository root with:

```sh
crates/integration/pgbouncer/tests/run-all.sh
```

To build pgrust as the Docker backend and run the full upstream PgBouncer
pytest suite as well, install `docker`, `uv`, and PostgreSQL `psql`, then run:

```sh
crates/integration/pgbouncer/tests/run-all.sh --upstream
```

The upstream suite is intentionally exhaustive: unsupported compatibility
areas will report failures until their Rust implementations are complete. Pass
one or more pytest selectors after `--upstream` to run a focused subset, for
example `test/test_admin.py::test_show_version`.

The ignored `session_reset` contract remains separately environment-gated
because it needs local PostgreSQL client/bootstrap tools. The Docker-backed
upstream mode is the path for validating pgrust as the backend image.
