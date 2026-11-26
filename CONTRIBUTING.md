# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir 1.20.3** and **Erlang/OTP 29** support; exact checkout releases come only
  from `.tool-versions`. Every CI
  install uses setup-beam's `version-file: .tool-versions` and `version-type: strict`,
  then refuses unless installed Elixir and the full OTP release match that file.
- Ash `>= 3.38.1 and < 4.0.0-0`; selector-free development uses this public range
- Replicant `>= 1.6.0 and < 2.0.0-0` from Hex; the lock is 1.6.0.
- Postgrex `~> 0.23` from Hex; the lock is 0.23.0.
  No sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design work and is never release evidence.
- DBConnection `>= 2.10.3 and < 3.0.0-0` from Hex. The lock is 2.10.3.
- AshCloak `>= 0.4.0 and < 1.0.0-0` from Hex; the current lock is 0.4.0 (the
  CVE-2026-81319 / CVE-2026-81322 security floor — every earlier release is
  vulnerable and the requirement refuses to resolve to one).
- **PostgreSQL** with `wal_level=logical` for the live integration gate; the
  integration suite runs against a live Postgres with a logical replication slot
  and publication. CI runs the checked BaseLabs platform engine plus declared
  upstream compatibility lanes. The `decoder-sources` jobs use
  `ASH_REPLICANT_DECODER_SOURCE_URL` for the separate source and
  `ASH_REPLICANT_TEST_URL` for the destination. Sources 15–19 run
  pgoutput and commit-pinned pglogical. The deprecated 9.6 and 12 sources
  retain pglogical and wal2json in 1.x, and 12 also runs pgoutput.
  Supported AshPostgres destinations are PostgreSQL 16–18. [ADR-0027](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0027-postgresql-server-support.md).

## Getting Started

```bash
git clone https://github.com/baselabs/ash_replicant.git
cd ash_replicant
```

All builds and tests run in GitHub CI on GitHub-hosted runners. Nothing compiles or tests
on the owner's Mac or the build box. Follow `AGENTS.md` under "Build and test": qualify a
covering-test commit on a topic `kci/` ref, read that run once, then create a fresh landing
head and use the landing tool. Never send the landing SHA to a `kci/` ref beforehand.

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Commit and qualify the covering checks through the CI-only route above. The commands
   below describe the CI gates; they do not authorize a local build or test.
   The retired local `scripts/prepush.sh` route is not qualification; CI runs its
   collector self-tests and every gate directly:

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

An uncontrolled background error fails the structural runner even when all
assertions pass. Failure output includes only source file locations from the
checked-out project or dependencies, exception classes, and authored test names;
raw messages remain in the runner's private capture.

Database migration and its dependent live checks run only after successful
database creation and migration. The other checks continue after a failure.
Each CI job owns its PostgreSQL container. A fresh consumer creates and removes its own
throwaway database on that server; it never borrows another project's machine or service.
The `fresh-consumer` qualification job downloads the qualified tarball and runs the full
consumer against its own logical-WAL platform engine: fresh dependency resolution, both
audits, compilation with warnings as errors, docs, migrations, and the live CDC smoke.
The `deps.audit --path` call runs from the repository's dev environment, where
`mix_audit` is declared; Hex's audit runs inside the consumer. Publication verifies the
served package and docs against those qualified bytes.

The last command is the data-boundary guard-mutation gate (ADR-0003): it
removes one production guard or reorders one notifier guard after its first
effect at a time in an isolated temporary copy of the project, and requires
the named no-database focused test to go red for the property-specific reason.
It compiles the project once per mutant, so a full run is long; cells run
in parallel shard workspaces by default (`--jobs`, 1 = the serial path).
The runner requires a QUIESCENT tree — the shards snapshot the live tree and copy
the live `_build` as their warm cache, so a concurrent `mix compile`,
`mix format`, or open editor save in the same checkout fails the run with
`live_tree_mutated` or `baseline` classes that say more about the
concurrency than about the guards.
CI's no-database job scopes it to the candidate diff: it fetches `main`,
then passes `--diff-base FETCH_HEAD`. Only the
cells whose guard file or named test changed run. The scoping fails safe to
the FULL matrix — a diff touching the evidence machinery
(the runner's `FULL_MATRIX_PREFIXES`/`FULL_MATRIX_FILES` set: `scripts/`,
`config/`, `test/support/`, `priv/`, `.github/`, `mix.exs`, `mix.lock`,
`.tool-versions`, the test helper) or an unavailable base runs everything.
Every `--diff-base` path still runs the runner's own self-test battery first. Its `--self-test` mode runs only the runner's
fixture/sentinel battery (including the path-scoping scenarios), and
`--cells <prefix>` runs a subset while iterating on one guard family.
The runner deletes inherited Mix build/dependency path overrides and handles
SIGINT/SIGTERM by stopping the active child process group before scratch cleanup.

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`.

The proof jobs live in `.github/workflows/qualification.yml`, called only by
`.github/workflows/ci.yml`. Every executable job runs on GitHub-hosted
`ubuntu-24.04`. Qualification runs once per `kci/<commit>` push, with no path
or tag filters. No workflow runs repository code from a pull request. A fork's
change is qualified when a maintainer lands it through a `kci/<commit>` branch.
The BEAM-equipped `postgres-lanes` job derives the expected proofs once and exposes
them through the reusable workflow's `checks` output. The runtime-free `qualified`
job reads that output as `EXPECTED_CHECKS`, compares it with the run's complete job
inventory, and requires every expected proof to finish successfully. `main` moves
only on that commit's `qualified` check; a push to `main`, a tag, or a release starts no run.
If qualification fails, fix forward in the next commit.

Job timeouts follow infra's binding CI requirements linked below. Each job's
comment identifies its slowest measured green run and duration. Publish has no
green run yet and uses `90 # no green run yet` until infra measures one.

The infrastructure maintainers' CI requirements bind every workflow and release script here;
maintainers read them as directed in `AGENTS.md`.


### Ash-bump grep procedure (B6 old-contract clause)

The frozen host action contract is pinned by `test/ash_replicant/action_contract_freeze_test.exs`
(the D8 table, asserted against live reflection) and the suppression/admission suites. Ash is a
floor-pinned dependency (`>= 3.38.1 and < 4.0.0-0`); when bumping the lock, run the old-contract
grep BEFORE trusting green
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
grep -n "bulk_create" deps/ash/lib/ash/actions/create/bulk.ex | grep -i index | head

# 4. AshOnetime replay semantics (the discriminator's whole premise):
#    a replayed claim must skip the body and replay the stored response.
grep -n "replay" deps/ash_onetime/lib/ash_onetime/change.ex | head
```

Any drift found in the greps is a contract change: update the freeze table's cells and the
affected tests in the same change, and record the Ash version contract delta in the ADR
(`docs/adr/0010`) amendment.

## Ash conventions

- This is an Ash **sink adapter** — a `Spark.Dsl.Extension` implementing the
  `Replicant.Sink` behavior. Learn from the sibling `ash_postgres` and the
  broader Ash extension ecosystem.
- Read `AGENTS.md` before touching multitenancy, sensitive-data, or action-execution
  code — its Critical Rules are binding.
- TDD: write the test first. Unit tests live in `test/`; integration tests (marked
  with `@moduletag :integration`) live in `test/integration/` and require a live
  Postgres. Integration tests run whenever `ASH_REPLICANT_TEST_URL` is set (it gates the
  suite); unit tests run without it. The URL supplies host/port/user, but the **database is
  always forced to a dedicated `ash_replicant_test`** (isolated from any sibling suite sharing
  the instance — see `config/test.exs`). A shared server works too: the URL's role needs only
  `LOGIN REPLICATION CREATEDB` (no superuser) and ownership of `ash_replicant_test`, and a
  password in the URL is honored everywhere, including the dynamic-destination fixtures.
  One-time provision, then run:

  ```bash
  export ASH_REPLICANT_TEST_URL="postgres://postgres:postgres@127.0.0.1:5432/postgres" # the CI lane's throwaway endpoint (.github/actions/postgres); point at YOUR logical-replication PostgreSQL (the database name is forced anyway)
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

  Each negative workflow fixture in `scripts/test_release_contract.exs` must
  still parse as YAML: the self-test parses every mutated workflow before it
  runs the checker, so a mutation that breaks YAML fails the self-test instead
  of proving the checker rejects the change. Insert an extra step as a whole
  step, never inside another step's `with:` mapping.

  CI fetches the exact-floor cell from `locks/exact-floors.lock`, the
  latest-compatible cell from `locks/latest-compatible.lock`, and current-lock
  cells from `mix.lock`. It copies the selected committed lock to `mix.lock`
  before `mix deps.get --check-locked`. The fresh tarball consumer starts without
  a lock and resolves its own dependencies; other qualification projects fetch locked.
  Version assertions check the committed versions against their requirements; newest-release comparisons run only in the drift report.
  Upstream code enters qualification through a reviewed lock refresh.

  `test/fixtures/release_checker` is recorded checker data, never fetched or
  executed as an Elixir project. Its `recorded.lock` has no project metadata or
  advisory ignore. Version assertions select it explicitly with
  `scripts/assert-dependency-version.sh --lock PATH`; the default lock is the
  repository root's `mix.lock`, independent of the working directory.
  Recorded Hex responses are replayed against that data without fetching dependencies.
  The upgrade fixture is copied to a temporary directory, inherits `mix.lock`
  exactly as the live upgrade test does, and runs a locked fetch and both audits
  before cleanup. It shares the root's reasoned no-fixed-release Cloak AES-CTR
  exception and GCM-only source guard. Its repo initialization requires the real
  database URL only when the repo is used; metadata audits require no live database
  or placeholder endpoint. Root `mix deps.audit` also invokes `mix hex.audit`
  through the repository alias, so every executable Elixir project receives both feeds.

  The full release battery is intentionally not represented by `mix quality`;
  that alias covers format, Credo, and Dialyzer only.

## Compatibility locks

Qualification fetches only the committed, reviewed locks: `mix.lock`,
`locks/exact-floors.lock`, and `locks/latest-compatible.lock`. Its version
assertions check compatibility without asking which upstream release is newest.
New upstream releases do not change those lock-version assertions.

`drift-report.yml` runs daily at 06:23 UTC or by `workflow_dispatch`, on the
default branch only. Its first step refuses every other ref. Five independent
`--newest` assertions compare `locks/latest-compatible.lock` with the newest
non-retired stable Ash, Replicant, AshOnetime, AshPostgres, and Spark releases
within their requirements. The report then removes the runner's copied lock,
resolves fresh within `mix.exs` requirements, prints every resolved version
against the committed compatibility lock, runs `mix hex.audit` and
`mix deps.audit`, compiles with warnings as errors, and runs the full live suite
and explicit integration discovery against the same checked platform engine
as qualification. Each report check runs even if an earlier report
check fails, after ref and runtime admission succeed.

Under the infrastructure dependency requirements,
this is the only workflow allowed to resolve the repository fresh. It holds only
`contents: read`, has no secret or environment, reads and writes no cache, and
has no `qualified` job. It reports upstream behavior and decides nothing;
admitting dependencies still requires a reviewed, committed lock refresh and
qualification. Qualification mutation-tests the report's contract; a `kci/`
push cannot exercise the report itself because its ref refusal is deliberate.

## Shipping a release

Contributors prepare the version commit and qualify it via the CI route in
`AGENTS.md` under "Build and test". Infra owns dispatch, registry access, tags
and GitHub releases.

1. Run `scripts/bump-version.sh NEW_VERSION` to update the version and stamp
   the changelog. Keep the version's section nonempty and the sections above it
   empty. Update `.github/hex-packages.json` when shipped files or dependency
   requirements change. Land the release commit through the landing tool.
2. Qualification builds and inspects the package and docs through the pinned
   shared Hex action. It retains `package.tar`, `docs.tar.gz` and `qualified.json`
   in `hex-hexpm-ash_replicant` for seven days. The live consumer checks the
   package tarball from that same artifact with fresh resolution, audits,
   migrations and CDC delivery against PostgreSQL.
3. Give infra the version, full landed commit and successful qualification run.
   Infra dispatches `publish.yml` on the default branch with that SHA as
   `release_commit`. Both the actor and the rerun actor must be authorized.
   The `upload` job checks exact-commit qualification, archive and changelog
   identity, tags, the existing public package and private OTP-app version
   collisions. It uses a short-lived package-scoped Hex token for any needed
   uploads. The owner decides first publication of a new package name.
4. The `read-back` job reopens the same artifact, checks both served archives
   byte for byte and verifies that docs provenance names the release commit.
   Its `release-assets` artifact retains the package, served docs and their
   SHA-256 checksums for seven days. Retry after approval with the same qualified
   archives. Infra tags that commit as `baselabs_ash_replicant-v<version>` and
   creates the GitHub release with notes from the packaged changelog.

Consumers verify the permanent [GitHub release](https://github.com/baselabs/ash_replicant/releases).

```bash
gh release download baselabs_ash_replicant-vX.Y.Z --repo baselabs/ash_replicant \
  --pattern 'ash_replicant-*' --pattern SHA256SUMS
sha256sum --check SHA256SUMS
curl --fail --silent --show-error https://repo.hex.pm/tarballs/ash_replicant-X.Y.Z.tar -o hex.tar
cmp ash_replicant-X.Y.Z.tar hex.tar
curl --fail --silent --show-error https://repo.hex.pm/docs/ash_replicant-X.Y.Z.tar.gz -o hex-docs.tar.gz
cmp ash_replicant-X.Y.Z-docs.tar.gz hex-docs.tar.gz
tar -xOf hex-docs.tar.gz release.json
rm hex.tar hex-docs.tar.gz
```

Check that `release.json` names `ash_replicant`, `X.Y.Z`, and the tag's full commit.
For historical releases, use the asset names and tag listed on their release page.

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
