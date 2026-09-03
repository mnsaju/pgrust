# Adjudication: parallel plan-shape divergence from real PostgreSQL

## Mechanism

`crates/backend/optimizer/path/costsize/src/gucs.rs` and
`crates/backend/utils/misc/guc_tables/src/consts.rs` deliberately set
`parallel_setup_cost` and `parallel_tuple_cost` an order of magnitude below
real PostgreSQL's defaults:

| GUC | real PG default | pgrust default | why |
|---|---|---|---|
| `parallel_setup_cost` | `1000.0` | `100.0` | measured worker hand-off from pgrust's warm thread pool (`pgrust.parallel_engine=runtime`, workers already parked) is ~175µs, vs. C's fork-based ~1-2ms (`notes/ppool-lane.md:58`) |
| `parallel_tuple_cost` | `0.1` | `0.01` | measured in-process tuple transfer over a chunked `Arc` ring is ~27ns/tuple, vs. C's cross-process `shm_mq` copy |

This is not miscalibration or leftover debug values -- it is deliberate,
measured pricing that reflects pgrust's actual (cheaper) parallel-worker
economics. `costsize/src/gucs.rs` documents a known failure mode of pricing
this cheaply (a raw-row `Gather`/`Gather Merge` feeding a serial leader
aggregate getting mis-elected) and already ships a targeted fix for exactly
that case (`GL-GMLEADER-1`, `GL-Q2829-FIX-1`: a per-tuple "leader-consumption
floor", with measured before/after timings in the comment).

## Evidence

Running the vendored regression suite (`regress/run-regress-docker.sh`)
against a real pgrust server, 11 files consistently show pgrust choosing a
parallel plan (`Gather`/`Gather Merge`/`Parallel Seq Scan`/`Parallel Index
Scan`) where real PostgreSQL 18.3's `expected/*.out` shows a serial one, or
a different join/aggregate strategy, under otherwise identical settings and
statistics:

`create_index`, `incremental_sort`, `memoize`, `tidscan`, `join`, `limit`,
`partition_aggregate`, `partition_join`, `partition_prune`,
`select_distinct`, `subselect`.

In every case the *results* match -- same rows, same values -- only the
`EXPLAIN` plan shape differs.

## Verdict: accepted divergence, not a bug

Raising `parallel_setup_cost`/`parallel_tuple_cost` back to real Postgres's
defaults to make these files match byte-for-byte would mean reverting
measured, evidence-based performance tuning that this project's published
benchmark numbers (see `benchmarks/README.md`) likely depend on, purely to
satisfy a diff against a reference file that was never trying to measure
"is this plan good" in the first place -- it just records whatever real
Postgres's own cost model happened to choose once, on its own reference
hardware.

Decision (2026-09-03): leave the cost model as-is. These 11 files are
recorded here as an accepted, root-caused divergence rather than tracked as
failures to fix.
