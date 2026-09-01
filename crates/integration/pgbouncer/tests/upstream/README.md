# Upstream PgBouncer tests with a pgrust Docker backend

This test-only adapter reuses PgBouncer's Python suite while replacing its C
PostgreSQL fixture with a disposable pgrust Docker container. Build an image
from this checkout first, then run the upstream suite from its own checkout:

```sh
docker buildx build --load -t pgrust:pgbouncer .
git -C /tmp/pgbouncer-upstream pull --ff-only
cd /tmp/pgbouncer-upstream
uv sync
export PATH="/usr/lib/postgresql/18/bin:$PATH"
export BOUNCER_EXE="/absolute/path/to/pgrust/target/release/pgrust-pgbouncer"
export PGRUST_IMAGE=pgrust:pgbouncer
PYTHONPATH="/absolute/path/to/pgrust/crates/integration/pgbouncer/tests/upstream" \
  uv run pytest -p pgrust_docker test/test_admin.py::test_show_version
```

Use the same command with additional test selectors as Rust pooler features
are implemented. The adapter uses `POSTGRES_HOST_AUTH_METHOD=trust`; upstream
tests that mutate HBA, require TLS, or require password authentication are
expected to remain disabled until the Rust pooler and adapter support them.
