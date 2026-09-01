# pgrust-pgbouncer

This directory contains the Rust PgBouncer reimplementation and its live
PostgreSQL-wire compatibility tests. The binary accepts the normal
`pgbouncer.ini` positional argument and currently implements TCP listeners,
the `[databases]` mapping, `pool_mode = session`, backend startup forwarding,
simple-query and extended-protocol forwarding, and reset-before-reuse.

The implementation is built from PgBouncer's documented behavior and its
public test suite; no PgBouncer C or Python source is vendored here.

The broader upstream suite includes TLS, SCRAM/MD5/LDAP authentication,
administrative commands, cancellation, COPY, timeout and pool limits, DNS
failover, replication, online restart, and peering. These remain tracked
implementation work and must not be represented as passing until their Rust
ports run successfully against pgrust.
