# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir 1.20.3** and **Erlang/OTP 29** (run `asdf install` from the repository root)
- Ash `>= 3.31.3 and < 4.0.0-0`; selector-free development uses this public range
- Replicant `>= 1.2.3 and < 2.0.0-0` from Hex; the release-candidate lock is 1.2.3.
  No sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design work and is never release evidence.
- **PostgreSQL** with `wal_level=logical` for the live integration gate; the
  integration suite runs against a live Postgres with a logical replication slot
  and publication. CI pins PostgreSQL 16; the local gate runs whatever instance
  `ASH_REPLICANT_TEST_URL` points at (derive the live version with
  `SELECT version();` — never assume it from this doc), and the support
  matrix is PG15–18

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
scripts/with-release-runtime.sh scripts/run-mutation-gates.py
```

The last command is the data-boundary guard-mutation gate (ADR-0003): it
removes one production guard or reorders one notifier guard after its first
effect at a time in an isolated temporary copy of the project, and requires
the named no-database focused test to go red for the property-specific reason.
It compiles the project once per mutant, so expect
a long serial run; CI executes it once in the no-database job. Its
`--self-test` mode runs only the runner's own fixture/sentinel battery, and
`--cells <prefix>` runs a subset while iterating on one guard family.

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`.


### Ash-bump grep procedure (B6 old-contract clause)

The frozen host action contract is pinned by `test/ash_replicant/action_contract_freeze_test.exs`
(the D8 table, asserted against live reflection) and the suppression/admission suites. Ash is a
pinned dependency (`~> 3.31`); when bumping it, run the old-contract grep BEFORE trusting green
tests — a behavior change inside Ash can silently invalidate a pinned fact while the pin still
passes against the NEW behavior:

```bash
# 1. The dispatch-suppression contract (impl.ex documents it): confirm Ash still
#    bundles-and-discards under return_notifications?: true and defaults notify?: false.
grep -rn "return_notifications" deps/ash/lib/ash/actions/ | head
grep -rn "notify?" deps/ash/lib/ash/actions/destroy/bulk.ex | head

# 2. The notifier pre-load gate (U3/D2): implements_load? + load/2 must still run
#    ungated on the pre-load path (only dispatch is suppressed).
grep -n "implements_load?" deps/ash/lib/ash/notifier/notifier.ex
grep -n "need_notifications?" deps/ash/lib/ash/actions/create/bulk.ex | head

# 3. The bulk_create ordinal context (materialize_bulk_ordinal reads
#    changeset.context[:bulk_create][:index]): confirm the key shape survived.
grep -rn "bulk_create" deps/ash/lib/ash/changeset/changeset.ex | grep -i index | head

# 4. AshOnetime replay semantics (the discriminator's whole premise):
#    a replayed claim must skip the body and replay the stored response.
grep -n "replay" deps/ash_onetime/lib/ash_onetime/change.ex | head
```

Any drift found in the greps is a contract change: update the freeze table's cells and the
affected tests in the same change, and record the Ash version contract delta in the ADR
(`docs/adr/0010`) amendment.

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
  export ASH_REPLICANT_TEST_URL="postgres://postgres@localhost:5599/postgres" # example — point at YOUR logical-replication Postgres (host/port are machine-local; the database name is forced anyway)
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

  CI also resolves the exact Replicant 1.2.3 floor independently of the current
  1.2.3 lock. To reproduce that selector in an isolated instrument worktree:

  ```bash
  ASH_REPLICANT_REPLICANT_VERSION=1.2.3 \
    scripts/with-release-runtime.sh mix deps.unlock replicant
  ASH_REPLICANT_REPLICANT_VERSION=1.2.3 \
    scripts/with-release-runtime.sh mix deps.get
  ASH_REPLICANT_REPLICANT_VERSION=1.2.3 \
    scripts/with-release-runtime.sh \
      scripts/assert-dependency-version.sh replicant '== 1.2.3'
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
