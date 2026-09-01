# pgrust-pgbackrest

`pgrust-pgbackrest` is a Rust-only implementation of the local-repository
backup and WAL-archive contracts used by pgBackRest. It is informed by the
public pgBackRest command implementation and test contracts, especially
`stanza-create`, `archive-push`, `archive-get`, `backup`, `restore`, `check`,
and `info`; no pgBackRest C source is vendored.

The initial compatibility slice implements:

- duplicated stanza metadata (`*.info` and `*.info.copy`);
- atomic, SHA-256-verified and idempotent WAL archive push/get;
- atomic full backups with deterministic manifests;
- corruption detection, restore to an empty destination, `check`, `verify`,
  and `info`.

Example configuration:

```ini
[global]
repo1-path=/var/lib/pgrust-backrest
pg1-path=/var/lib/postgresql/data
```

```sh
pgrust-pgbackrest --config=/etc/pgrust-backrest.conf --stanza=demo stanza-create
pgrust-pgbackrest --config=/etc/pgrust-backrest.conf --stanza=demo archive-push /path/to/000000010000000000000001
pgrust-pgbackrest --config=/etc/pgrust-backrest.conf --stanza=demo backup --type=full
pgrust-pgbackrest --config=/etc/pgrust-backrest.conf --stanza=demo check
```

This is not yet a drop-in pgBackRest replacement. Differential/incremental
backups, encryption, compression, remote/S3/Azure/GCS repositories, async
spooling, retention/expire, PostgreSQL online backup protocol integration,
tablespace symlinks, and PITR orchestration remain future Rust work. Do not
use it for production recovery until end-to-end pgrust restore and corruption
testing is complete.
