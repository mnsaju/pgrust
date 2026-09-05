# TAP driver image: the pgrust image plus the Perl the upstream TAP suites need
# and the two-entry shim bindir that makes pg_ctl start pgrust instead of C.
#
# Built by regress/run-recovery-tap-docker.sh; not part of the shipped image.
ARG BASE=pgrust:pinned
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive

# prove(1) + Test::More come from perl core; IPC::Run does not, and
# PostgreSQL::Test::Utils fails to load without it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        perl libipc-run-perl; \
    rm -rf /var/lib/apt/lists/*; \
    perl -MIPC::Run -e 'print "IPC::Run ok\n"'; \
    prove --version >/dev/null

# The shim bindir: EXACTLY two entries. See regress/tap/postgres-shim for why
# adding a third (initdb especially) breaks the resolution split.
COPY postgres-shim /opt/pgrust-tapbin/postgres
RUN set -eux; \
    cp /usr/lib/postgresql/18/bin/pg_ctl /opt/pgrust-tapbin/pg_ctl; \
    chmod +x /opt/pgrust-tapbin/postgres /opt/pgrust-tapbin/pg_ctl; \
    test "$(ls /opt/pgrust-tapbin | sort | tr '\n' ' ')" = "pg_ctl postgres "; \
    # The shim must satisfy pg_ctl's exact-strcmp version check, or every
    # cluster start dies with "not the same version as pg_ctl". Prove it here,
    # at build time, rather than discovering it inside a test run.
    want="$(/usr/lib/postgresql/18/bin/pg_ctl --version | sed 's/^pg_ctl /postgres /')"; \
    got="$(/opt/pgrust-tapbin/postgres --version)"; \
    [ "$want" = "$got" ] || { echo "shim -V mismatch: want [$want] got [$got]" >&2; exit 1; }; \
    echo "shim version handshake ok: $got"

ENV PATH=/opt/pgrust-tapbin:/usr/lib/postgresql/18/bin:/usr/local/bin:/usr/bin:/bin
