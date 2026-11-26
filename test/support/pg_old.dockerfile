# ADR-0027 — pglogical built against digest-pinned official PostgreSQL
# images. The deprecated 9.6 and 12 rows also build wal2json and retain the
# wal2json 2.4 option-rejection fixture under its own plugin name.
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

# The 9.6 image rides Debian stretch (archived upstream; PGDG's stretch archive has
# no arm64 suite at all). The Debian archive's stretch/updates carries
# postgresql-server-dev-9.6 for arm64; installing it needs the base image's PGDG
# libpq5 downgraded to Debian's matching build (--allow-downgrades pins the trio).
RUN set -eux; \
    case "$PG_MAJOR" in 9.6) \
      printf 'deb http://archive.debian.org/debian stretch main\ndeb http://archive.debian.org/debian-security stretch/updates main\n' > /etc/apt/sources.list; \
      rm -f /etc/apt/sources.list.d/*.list; \
      apt-get update -o Acquire::Check-Valid-Until=false; \
      apt-get install -y --no-install-recommends --allow-downgrades \
        "libpq5=9.6.24-0+deb9u1" "libpq-dev=9.6.24-0+deb9u1" \
        "postgresql-server-dev-9.6=9.6.24-0+deb9u1" \
        build-essential git ca-certificates libkrb5-dev libselinux1-dev \
        libxslt1-dev libpam0g-dev zlib1g-dev libssl-dev libedit-dev; \
      ;; \
    12|15|16|17|18|19) \
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

# wal2json, the wal2json_2_6 tag @ 75629c2 (≥ 2.6: numeric-data-types-as-string;
# the same commit replicant's own dockerfile pins for every pre-15 major), and
# wal2json_2_4 (36fbee6cbb7e4bc1bf9ee4f55842ab51393e3ac0) as `wal2json2_4` (the option-rejection halt's live lever).
ARG WITH_WAL2JSON
RUN set -eux; \
    case "$PG_MAJOR:$WITH_WAL2JSON" in \
      9.6:true|12:true) ;; \
      15:false|16:false|17:false|18:false|19:false) exit 0 ;; \
      *) echo "invalid wal2json build profile" >&2; exit 1 ;; \
    esac; \
    git clone --quiet https://github.com/eulerto/wal2json.git /tmp/wal2json; \
    cd /tmp/wal2json; \
    git checkout --quiet 75629c2e1e81a12350cc9d63782fc53252185d8d; \
    make -j"$(nproc)" PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config; \
    make install DESTDIR=/plugins PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config; \
    mv /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json.so /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json_head.so; \
    git checkout --quiet 36fbee6cbb7e4bc1bf9ee4f55842ab51393e3ac0; \
    make -j"$(nproc)" PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config; \
    make install DESTDIR=/plugins PG_CONFIG=/usr/lib/postgresql/$PG_MAJOR/bin/pg_config; \
    mv /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json.so /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json2_4.so; \
    mv /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json_head.so /plugins/usr/lib/postgresql/$PG_MAJOR/lib/wal2json.so

FROM ${BASE}
COPY --from=build /plugins/ /
