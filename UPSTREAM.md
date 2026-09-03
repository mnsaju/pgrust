# PostgreSQL upstream-delta ledger

PGRust is based on PostgreSQL 18.3 (`PG_VERSION_NUM = 180003`, catalog version
`202506291`).  The source-branch point is recorded as PostgreSQL 18.3, rather
than an invented upstream git SHA.  PostgreSQL 18.4 and 18.6 must therefore be
triaged explicitly; 18.5 was withdrawn.

This ledger is the required review record for changes from `REL_18_STABLE`.
Each upstream fix must have one disposition: `ported`, `not-applicable`,
`already-present`, or `tracked`; a disposition includes the PGRust paths,
tests, owner, and next review date.  `RENAME-MAP.md` is used to map renamed
surfaces before declaring an item not applicable.

## Initial triage

| Upstream fix | Release | Disposition | PGRust mapping and verification | Owner / next review |
|---|---:|---|---|---|
| `f581fa729d8e108fef853c3156267b1f753d0210` — register visibility-map pages changed by heap WAL | 18.6 | ported | `crates/backend/access/heap/heapam/src/dml.rs`, `wal.rs`, `heapam_xlog/src/lib.rs`, and `visibilitymap/src/lib.rs`; unit coverage asserts the heap and VM block registration for multi-insert. | storage / before next release |
| CVE-2026-6478 — MD5 response comparison | 18.4 | ported | `crates/backend/libpq/crypt/src/lib.rs`; tests cover matching, mismatching, and unequal-length inputs. | security / before next release |
| `d560e730e` — missing SSI conflict on an initially empty btree endpoint | 18.6 | tracked | Find the translated `_bt_endpoint` / predicate-lock path and port the upstream regression before a production release. | concurrency / weekly |
| Remaining 18.4 and 18.6 changelog items | 18.4/18.6 | tracked | Inventory is seeded by `review/opus/evidence/pg-bug-archaeology.md`.  Add one row per upstream commit or explicitly mark it inapplicable/already-present. | release engineering / weekly |

## Operating procedure

1. At least weekly, fetch `REL_18_STABLE`, enumerate commits since the recorded
   release baseline, and add a row or update its disposition.
2. For each `ported` row, link the PGRust test that demonstrates the upstream
   invariant.  No port is complete without a focused regression test.
3. Before cutting a release, require zero untriaged security, data-integrity,
   recovery, MVCC, or wrong-result changes.  Remaining `tracked` items require
   an explicit risk acceptance in the release notes.
4. Record the exact upstream branch-point SHA once it is recovered from the
   import history; do not use PGRust's own commit SHA as a substitute.
