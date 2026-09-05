# pgBouncer compatibility driver: the REAL C pgbouncer, plus psql, in a
# container that connects to a pgrust server over the network.
#
# Deliberately NOT the fork's `pgrust-pgbouncer` Rust reimplementation. The
# question this lane answers is "does the pooler operators actually deploy work
# in front of pgrust?", and only the genuine binary can answer it -- a port
# would be testing our own code. See PLAN-production-readiness.md, lane B7.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

ENV DEBIAN_FRONTEND=noninteractive

# psql comes from PGDG at the same version the rest of the harness is pinned to
# (18.3), so client-side rendering matches the other tiers. pgbouncer comes
# from Debian: it is the package a Debian/Ubuntu operator installs.
ARG PG_PKG_VERSION=18.3-1.pgdg12+1
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates gnupg wget; \
    install -d /usr/share/postgresql-common/pgdg; \
    wget -qO /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-client-18=${PG_PKG_VERSION}" pgbouncer; \
    rm -rf /var/lib/apt/lists/*; \
    # Record what we are actually testing with -- the pooler version is part of
    # any compatibility claim made from this lane.
    { echo "pgbouncer=$(pgbouncer --version 2>&1 | head -1)"; \
      echo "psql=$(psql --version)"; } > /opt/pgbouncer-manifest.txt; \
    cat /opt/pgbouncer-manifest.txt
