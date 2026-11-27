# ADR-0027 — pglogical built against digest-pinned official PostgreSQL
# images for all supported source majors.
#
# The base is mandatory: scripts/ci/postgres-lanes.sh supplies the declared
# image@digest from .github/postgres-lanes.json to the workflow's BASE build arg.
# An absent or empty BASE cannot resolve FROM and fails the build.
#
# The build context is the repo root. Plugin sources are pinned by commit (not a
# moving branch) so a rebuild reproduces the same bytes. The final image copies
# only staged plugin files, never apt-installed server libraries. PGDG's archive
# retains the exact server headers after the live suite drops that patch build.

ARG BASE
FROM ${BASE} AS build

RUN set -eux; \
    case "$PG_MAJOR" in \
    15|16|17|18|19) \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates; \
      sed -E 's#https?://apt\.postgresql\.org#https://apt-archive.postgresql.org#; s#-pgdg main.*$#-pgdg-archive main#' \
        /etc/apt/sources.list.d/pgdg.list > /etc/apt/sources.list.d/pgdg-archive.list; \
      grep -q 'https://apt-archive.postgresql.org' /etc/apt/sources.list.d/pgdg-archive.list; \
      apt-get update; \
      apt-get install -y --no-install-recommends build-essential git \
        libkrb5-dev libselinux1-dev libxslt1-dev libpam0g-dev zlib1g-dev libedit-dev \
        libzstd-dev liblz4-dev libnuma-dev \
        "postgresql-server-dev-$PG_MAJOR=$PG_VERSION"; \
      ;; \
    *) echo "unsupported plugin source major" >&2; exit 1 ;; \
    esac

# pglogical 2.4.8 (output plugin `pglogical_output`) — OBSERVED protocol facts in
# replicant's ADR-0009, "Plugin-fact verification".
RUN set -eux; \
    git clone --quiet https://github.com/2ndQuadrant/pglogical.git /tmp/pglogical; \
    cd /tmp/pglogical; \
    git checkout --quiet 9a0e182745885ad0152ea387988c95a483396a81; \
    make -j"$(nproc)" PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config \
      LDFLAGS_EX="-L/usr/lib/postgresql/$PG_MAJOR/lib"; \
    make install DESTDIR=/plugins PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config \
      LDFLAGS_EX="-L/usr/lib/postgresql/$PG_MAJOR/lib"

FROM ${BASE}
COPY --from=build /plugins/ /
