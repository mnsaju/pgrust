# Adjudication: `portals.sql`'s unordered-cursor `FETCH` divergence

## Mechanism

Same root cause as `ADJUDICATION-PARALLEL-PLAN-SHAPE.md`: `tenk2` is
created by `test_setup.sql` as `CREATE TABLE tenk2 AS SELECT * FROM
tenk1;`, with no `ORDER BY`. Its physical row order is whatever order that
`SELECT`'s scan of `tenk1` (10,000 rows) happened to produce -- and pgrust's
deliberately-cheap parallel-worker pricing (see the sibling adjudication)
makes it more likely to plan that scan as parallel, so the row order
`tenk2` ends up with depends on worker-completion interleaving rather than
page order alone. That interleaving is timing-dependent, so it can differ
both from real PostgreSQL's (which used a serial scan when the reference
`expected/portals.out` was captured) and, potentially, from one pgrust run
to the next.

`portals.sql` declares 9 cursors with no `ORDER BY` over `tenk2` (`foo2`,
`foo4`, `foo6`, ..., `foo18`: `DECLARE fooN SCROLL CURSOR FOR SELECT * FROM
tenk2;`) and then does positional `FETCH N in fooN;` calls against them.

## Why this can't just be `-- pgrust:rowsort`-annotated

The overlay's rowsort comparator (`scripts/rowsort_compare.py`) sorts a
statement's *entire* result block and compares it as a set -- correct for a
predicate-filtered query with no `LIMIT` (e.g. `select.sql`'s `WHERE
onek2.unique1 < 10`, which always returns the same 10 rows regardless of
scan order -- annotated and fixed alongside this adjudication). It cannot
fix a positional slice of an unordered scan: `FETCH 2 in foo2` returns
whichever 2 rows happen to be *first* in `tenk2`'s current physical order,
which is not the same 2 rows when the underlying order differs -- confirmed
against actual output: real Postgres's first two rows for one such fetch
were `unique1={8800, 1891}`; pgrust's were `unique1={5773, 1014}` --
entirely different rows, not a reordering of the same ones. Sorting each
side's 2-row block does not reconcile that.

## Verdict: accepted divergence, not a bug

Fixing this would require either matching real Postgres's exact scan order
for a 10,000-row `CREATE TABLE AS SELECT` (defeating the parallel-cost
tuning accepted in the sibling adjudication) or building substantially more
machinery than a rowsort comparator (e.g. tracking a whole cursor's
sequence of fetches against a canonicalized full-order oracle). Neither is
justified by a query pattern (unordered cursor `FETCH`) that real
applications should not rely on either.

Decision (2026-09-03): recorded as an accepted divergence, same root cause
and same disposition as the parallel plan-shape adjudication. Not fixed.
