# pgBackRest lane image: the pgrust server plus the REAL C pgbackrest.
#
# pgbackrest is not a network client -- it reads PGDATA directly and its
# archive_command runs on the database host -- so unlike the pgbouncer lane it
# cannot live entirely in a separate driver container. It is installed
# alongside the server, which is how operators actually deploy it. The
# verification half (restore into a fresh cluster and boot it) still runs in a
# separately spawned container, so nothing is verified by the thing under test.
ARG BASE=pgrust:pinned
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

# pgbackrest comes from PGDG, NOT from Debian. Debian bookworm ships 2.45,
# which predates PostgreSQL 18 entirely: it rejects the cluster before ever
# reaching pgrust-specific behaviour, with
#   WARN: unable to check pg1: [VersionNotSupportedError] unexpected control
#         version = 1800 and catalog version = 202506291
#   ERROR: [056]: unable to find primary cluster - cannot proceed
# That is a tool-version limit, not a pgrust defect, and recording it as one
# would be exactly the mistake this project keeps paying for. Pinned, like
# every other oracle in the harness.
ARG PGBACKREST_VERSION=2.59.1-1.pgdg12+1
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates gnupg wget; \
    install -d /usr/share/postgresql-common/pgdg; \
    wget -qO /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    pgbackrest version; \
    install -d -o postgres -g postgres /var/lib/pgbackrest /var/log/pgbackrest \
        /etc/pgbackrest /etc/pgbackrest/conf.d
