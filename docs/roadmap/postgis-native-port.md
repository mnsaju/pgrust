# Draft: PostGIS native port

## Objective

Add a PostgreSQL-compatible geospatial surface to pgrust in staged, native
Rust crates: geometry/geography values, canonical I/O, core predicates, and
GiST indexing.

## Preconditions

PostGIS is GPL-2.0 while pgrust is AGPL-3.0. Do not copy or port PostGIS code
until maintainers complete a license and provenance review. The first code
phase must use independently implemented behavior with public SQL/API tests,
or a licensing path expressly approved by maintainers.

## Reference behavior

- PostGIS: `liblwgeom/`, `postgis/`, `postgis/gserialized_gist_2d.c`, and
  `postgis.sql.in`.
- PostgreSQL spatial index framework: `src/backend/access/gist/`.
- pgrust: `crates/backend/access/gist`, `types_*` layout crates, and the
  existing geometry scalar/box behavior in `crates/backend/utils/adt`.

## Approach

1. Define byte-stable WKB/EWKB-compatible parsing/formatting and `geometry`
   typmod/SRID semantics.
2. Port the SQL-visible core in tiers: points/boxes, geometry constructors and
   predicates, then geography and advanced processing.
3. Implement a native GiST operator class with deterministic index-image and
   plan/result differential tests.
4. Keep raster, topology, external GDAL/PROJ integration, and optional
   modules outside the first release.

## Acceptance tests

- Golden SQL/WKB vectors and invalid-input SQLSTATE parity.
- GiST build, scan, vacuum, WAL replay, and C↔pgrust data-directory tests.
- Differential predicate and index tests against a pinned PostgreSQL/PostGIS
  reference environment.

## Non-goals

Claiming `CREATE EXTENSION postgis` compatibility before the native add-in,
versioned SQL objects, and on-disk index compatibility are complete.
