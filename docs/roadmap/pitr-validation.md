# Draft: PITR validation

## Objective

Prove PostgreSQL 18.3-compatible continuous-archive recovery for pgrust:
base backup plus an unbroken WAL archive can restore to an LSN, timestamp,
transaction ID, named restore point, or timeline.

## Reference behavior

- PostgreSQL: `src/backend/access/transam/xlogrecovery.c`, `timeline.c`,
  `xlogarchive.c`, and the continuous-archiving/PITR documentation.
- pgrust: `crates/backend/access/transam/xlogrecovery`, `timeline`,
  `xlogarchive`, `transam_xlog`, and `crates/backend/postmaster/startup`.

## Approach

1. Make recovery configuration, `recovery.signal`, archive retrieval, timeline
   selection, and recovery targets follow PostgreSQL 18.3 behavior exactly.
2. Establish a deterministic test fixture: base backup, writes before and
   after named restore points, WAL archival, restore, and target verification.
3. Differentially execute every fixture with PostgreSQL and pgrust; compare
   SQL results, recovery logs, timeline history, and data-directory artifacts
   after masking permitted volatile fields.
4. Add crash/restart and missing/corrupt-WAL negative controls.

## Acceptance tests

- Targets: time, XID, LSN, name, immediate, and latest.
- Inclusive/exclusive target semantics and timeline fork traversal.
- Interrupted recovery restarts from the correct durable point.
- A restored cluster accepts normal writes and performs a clean restart.

## Non-goals

Streaming standby replication or a particular backup product integration;
pgBackRest is covered by its own interoperability plan.
