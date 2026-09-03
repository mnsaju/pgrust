# vendor/postgresql

The upstream PostgreSQL regression and isolation test suites
(`src/test/regress`, `src/test/isolation`), vendored as a shallow,
sparse-checked-out git submodule pinned to the exact `REL_18_3` tag. Used
by `regress/run-regress-docker.sh` to verify pgrust against the real suite
these test files ship in — see `review/opus/findings.md`'s PGRA-017 for why
this exists (the project's "passes the PostgreSQL regression suite" claim
was previously unverifiable from this repository).

Kept shallow (`--depth 1` at the pinned tag, not full history) and sparse
(only `src/test/regress` + `src/test/isolation`, not the rest of the
PostgreSQL source tree) because only the test *data* is needed — this repo
already has its own server (the `postgres` binary built from this
workspace) and already installs PGDG's prebuilt `pg_regress` /
`pg_isolation_regress` test drivers (see `regress/Dockerfile.runner`), so
there is no need to vendor or build the C server itself.

## Setting this up from a fresh clone

`git submodule update --init` alone will NOT reproduce this (it does a
full, unshallow clone by default). Instead:

```sh
./vendor/setup.sh
```

## Refreshing to a different PostgreSQL tag

Edit `REL_TAG` in `vendor/setup.sh`, delete `vendor/postgresql/`, re-run the
script, then `git add vendor/postgresql` to record the new pinned commit.
