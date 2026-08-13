# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir 1.20.3** and **Erlang/OTP 29** (run `asdf install` from the repository root)
- Ash `>= 3.31.3 and < 4.0.0-0`; selector-free development uses this public range
- Replicant `>= 1.0.0 and < 2.0.0-0` from Hex; the release-candidate lock is 1.1.0.
  No sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design work and is never release evidence.
- **PostgreSQL 16** for the current integration gate (with `wal_level=logical`); the
  integration suite runs against a live Postgres with a logical replication slot
  and publication

## Getting Started

```bash
git clone https://github.com/baselabs/ash_replicant.git
cd ash_replicant
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get
env -u ASH_REPLICANT_TEST_URL \
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration
```

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Run the database-free and static checks before opening a PR:

```bash
scripts/with-release-runtime.sh mix format --check-formatted
scripts/with-release-runtime.sh mix compile --warnings-as-errors
scripts/with-release-runtime.sh mix credo --strict
env -u ASH_REPLICANT_TEST_URL \
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration
scripts/with-release-runtime.sh mix deps.audit
scripts/with-release-runtime.sh mix hex.audit
scripts/with-release-runtime.sh mix dialyzer
scripts/with-release-runtime.sh mix docs --warnings-as-errors
scripts/with-release-runtime.sh mix hex.build
```

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`.

## Ash conventions

- This is an Ash **sink adapter** — a `Spark.Dsl.Extension` implementing the
  `Replicant.Sink` behaviour. Learn from the sibling `ash_postgres` and the
  broader Ash extension ecosystem.
- Read `AGENTS.md` before touching multitenancy, sensitive-data, or action-execution
  code — its Critical Rules are binding.
- TDD: write the test first. Unit tests live in `test/`; integration tests (marked
  with `@moduletag :integration`) live in `test/integration/` and require a live
  Postgres. Integration tests run whenever `ASH_REPLICANT_TEST_URL` is set (it gates the
  suite); unit tests run without it. The URL supplies host/port/user, but the **database is
  always forced to a dedicated `ash_replicant_test`** (isolated from any sibling suite sharing
  the instance — see `config/test.exs`). One-time provision, then run:

  ```bash
  export ASH_REPLICANT_TEST_URL="postgres://postgres@localhost:5599/postgres"
  MIX_ENV=test scripts/with-release-runtime.sh mix ecto.create
  MIX_ENV=test scripts/with-release-runtime.sh mix ecto.migrate
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh --include integration
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    test/integration --include integration
  ```

  Check resource snapshots against migrations with the same explicit-domain
  command used by CI:

  ```bash
  scripts/with-release-runtime.sh scripts/test-migration-drift-gate.sh
  scripts/with-release-runtime.sh scripts/test-release-checkers.sh
  scripts/with-release-runtime.sh scripts/test-release-contract.sh
  ```

  These live-suite and migration-drift commands are mandatory parts of the
  pre-PR release battery, in addition to the checks in step 3.

  CI also resolves the exact Replicant 1.0.0 floor independently of the current
  1.1.0 lock. To reproduce that selector in an isolated instrument worktree:

  ```bash
  ASH_REPLICANT_REPLICANT_VERSION=1.0.0 \
    scripts/with-release-runtime.sh mix deps.unlock replicant
  ASH_REPLICANT_REPLICANT_VERSION=1.0.0 \
    scripts/with-release-runtime.sh mix deps.get
  ASH_REPLICANT_REPLICANT_VERSION=1.0.0 \
    scripts/with-release-runtime.sh \
      scripts/assert-dependency-version.sh replicant '== 1.0.0'
  ```

  The full release battery is intentionally not represented by `mix quality`;
  that alias covers format, Credo, and Dialyzer only.

## Critical rules (binding)

From `AGENTS.md`:

1. **Route writes through Ash actions, never raw Ecto.** The resource's host
   actions run validations, changes, AshCloak hooks, and multitenancy. The sink
   uses `authorize?: false`, so policies are not re-gated.
2. **Multitenancy is fail-closed.** nil/`false`/blank tenant → error, never a base-tenant
   fallback.
3. **Sensitive = AshCloak-encrypted or binary or skip.** Verified by compile-time
   verifier.
4. **Value-free at boundaries.** No row values in errors, logs, or telemetry — ever,
   including halt paths.
5. **Tenant-blind layering.** Multitenancy lives here; `replicant` stays tenant-blind.
6. **Effect-once = one transaction + watermark dedup + atomic checkpoint.**

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
