# Draft: pgBackRest interoperability

## Objective

Support pgBackRest as an external backup and WAL-archive tool with a pgrust
cluster, without embedding pgBackRest or reimplementing its repository format.

## Reference behavior

- PostgreSQL backup/WAL contract: `src/backend/access/transam/xlog.c`,
  `xlogarchive.c`, and `src/backend/backup/basebackup.c`.
- pgrust ports: `transam_xlog`, `xlogarchive`, `pgarch`, and `basebackup`.
- pgBackRest command paths: `src/command/backup`, `src/command/archive`, and
  `src/command/restore` in the pgBackRest repository.

## Approach

1. Verify the PostgreSQL control-file, system-identifier, WAL segment, and
   backup protocol contracts consumed by pgBackRest.
2. Exercise `archive_command = 'pgbackrest ... archive-push %p'` and
   `restore_command = 'pgbackrest ... archive-get %f %p'` against pgrust.
3. Support full, differential, and incremental backup where the corresponding
   server-side backup/WAL-summary prerequisites are live.
4. Publish one reference configuration for local repositories and one for an
   object-store repository; neither may weaken fsync, archive, or checksum
   behavior.

## Acceptance tests

- `stanza-create`, backup, `check`, `info`, restore, and verify against pgrust.
- Archive-push idempotency and a corrupted/mismatched-WAL negative test.
- Restore on a clean host followed by PostgreSQL 18.3 and pgrust cross-boot
  checks wherever their on-disk formats are claimed compatible.

## Non-goals

Vendoring pgBackRest, inventing a backup repository format, or declaring
production backup support before restore and corruption testing passes.
