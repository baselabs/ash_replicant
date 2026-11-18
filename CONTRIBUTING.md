# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir 1.20.3** and **Erlang/OTP 29** support; exact checkout releases come only
  from `.tool-versions` (run `asdf install` from the repository root). Every CI
  install uses setup-beam's `version-file: .tool-versions` and `version-type: strict`,
  then refuses unless installed Elixir and the full OTP release match that file.
- Ash `>= 3.37.3 and < 4.0.0-0`; selector-free development uses this public range
- Replicant `>= 1.4.0 and < 2.0.0-0` from Hex; the lock is 1.5.1.
  No sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design work and is never release evidence.
- AshCloak `>= 0.4.0 and < 1.0.0-0` from Hex; the current lock is 0.4.0 (the
  CVE-2026-81319 / CVE-2026-81322 security floor — every earlier release is
  vulnerable and the requirement refuses to resolve to one).
- **PostgreSQL** with `wal_level=logical` for the live integration gate; the
  integration suite runs against a live Postgres with a logical replication slot
  and publication. CI runs pinned PostgreSQL 16, 17, and 18 cells plus the
  `decoder-old-majors` cells (PostgreSQL 12 and 9.6 with the plugin substrate —
  `test/support/pg_old.dockerfile`, the commit-pinned pglogical 2.4.8 +
  wal2json build); the local gate runs whatever instance
  `ASH_REPLICANT_TEST_URL` points at (derive the live version with
  `SELECT version();` — never assume it from this doc). The support matrix:
  pgoutput on PG12 and 15–18, pglogical/wal2json on PG9.6 and 12; locally
  the decoder lane runs against a cluster-hosted old-major source via
  `ASH_REPLICANT_PGOLD_URL` (skipped when unset)

## Getting Started

```bash
git clone https://github.com/baselabs/ash_replicant.git
cd ash_replicant
asdf install
scripts/with-release-runtime.sh scripts/assert-runtime-version.sh
scripts/with-release-runtime.sh mix deps.get --check-locked
env -u ASH_REPLICANT_TEST_URL \
  scripts/with-release-runtime.sh scripts/run-structural-tests.sh \
    --allow-excluded --exclude integration
```

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Run the database-free and static checks before opening a PR —
   `scripts/prepush.sh` compiles first, then runs the remaining independent
   checks and prints a pass/fail table. It exits non-zero if any check fails
   and adds the live-database lane when `ASH_REPLICANT_TEST_URL` is set:

```bash
scripts/prepush.sh

# — or, gate by gate —
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
For a fresh consumer's throwaway database in the cluster's `ephemeral`
namespace, set `ASH_REPLICANT_CONSUMER_TEST_URL` to that run's endpoint; the
main test database still uses `ASH_REPLICANT_TEST_URL` from `.env`.

The last command is the data-boundary guard-mutation gate (ADR-0003): it
removes one production guard or reorders one notifier guard after its first
effect at a time in an isolated temporary copy of the project, and requires
the named no-database focused test to go red for the property-specific reason.
It compiles the project once per mutant, so a full run is long; cells run
in parallel shard workspaces by default (`--jobs`, 1 = the legacy serial
path) and the LOCAL developer battery always runs the full matrix.
Run it in a QUIESCENT tree — the shards snapshot the live tree and copy
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
The final `qualified` check reads the run's complete job inventory and requires
all ten expected proofs to finish successfully. `main` moves only on that
commit's `qualified` check; a push to `main`, a tag, or a release starts no run.
If qualification fails, fix forward in the next commit.

Job timeouts follow infra's binding CI requirements linked below. Each job's
comment identifies its slowest measured green run and duration. Publish has no
green run yet and uses `90 # no green run yet` until infra measures one.

Infra's binding requirements live in [What infra requires of every product](https://github.com/baselabs/infra/blob/main/baselabs/docs/ci.md#what-infra-requires-of-every-product).
Read that section from infra's default branch as directed in `AGENTS.md`.


### Ash-bump grep procedure (B6 old-contract clause)

The frozen host action contract is pinned by `test/ash_replicant/action_contract_freeze_test.exs`
(the D8 table, asserted against live reflection) and the suppression/admission suites. Ash is a
floor-pinned dependency (`>= 3.37.3 and < 4.0.0-0`); when bumping the lock, run the old-contract
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
  scripts/with-release-runtime.sh scripts/test-release-guards.sh
  scripts/with-release-runtime.sh scripts/test-release-contract.sh
  ```

  These live-suite and migration-drift commands are mandatory parts of the
  pre-PR release battery, in addition to the checks in step 3.

  CI fetches the exact-floor cell from `locks/exact-floors.lock`, the
  latest-compatible cell from `locks/latest-compatible.lock`, and current-lock
  cells from `mix.lock`. It copies the selected committed lock to `mix.lock`
  before `mix deps.get --check-locked`; no qualification step resolves unlocked
  dependencies. Version assertions check the committed versions against their
  requirements; newest-release comparisons run only in the drift report.
  Upstream code enters qualification through a reviewed lock refresh.

  Live release guards run once in the no-database job, separately from the
  dependency-sensitive checker tests that also run in every compatibility cell.
  Every GitHub REST lookup uses `gh api`; the live-guard and publish-refusal
  steps receive `GH_TOKEN: ${{ github.token }}` only in their step environment,
  with job `permissions: contents: read`. The qualification verdict uses its
  own job token through the same client. Missing tokens, transport failures,
  and HTTP errors refuse; only HTTP 404 proves an absent release. Contributors
  running live guards or post-release verification supply `GH_TOKEN` in their
  environment, never as a command argument or in a file.

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
An upstream release cannot change that qualification result by itself.

`drift-report.yml` runs daily at 06:23 UTC or by `workflow_dispatch`, on the
default branch only. Its first step refuses every other ref. Five independent
`--newest` assertions compare `locks/latest-compatible.lock` with the newest
non-retired stable Ash, Replicant, AshOnetime, AshPostgres, and Spark releases
within their requirements. The report then removes the runner's copied lock,
resolves fresh within `mix.exs` requirements, prints every resolved version
against the committed compatibility lock, runs `mix hex.audit` and
`mix deps.audit`, compiles with warnings as errors, and runs the full live suite
and explicit integration discovery against the same pinned PostgreSQL 16
substrate as qualification. Each report check runs even if an earlier report
check fails, after ref and runtime admission succeed.

Under infra's [dependency requirements](https://github.com/baselabs/infra/blob/main/baselabs/docs/ci.md#what-infra-requires-of-every-product),
this is the only workflow allowed to resolve the repository fresh. It holds only
`contents: read`, has no secret or environment, reads and writes no cache, and
has no `qualified` job. It reports upstream behavior and decides nothing;
admitting dependencies still requires a reviewed, committed lock refresh and
qualification. Qualification mutation-tests the report's contract; a `kci/`
push cannot exercise the report itself because its ref refusal is deliberate.

## Shipping a release

Steps 1 to 3 make the version commit, which any contributor or agent lands
like every other commit. Steps 4 to 8 belong to the maintainers' release
operator alone. An agent's work ends with the qualified commit on `main`;
agents never tag, release, publish, or handle publish credentials.

Follow these steps in order:

1. `scripts/bump-version.sh NEW_VERSION` — bumps the six version-bearing
   anchors (mix.exs, CHANGELOG fold + fresh `[Unreleased]`, README, notebook,
   CHARTER stamp) and prints the steps below.
2. Commit the bump with named paths. A contributor may run
   `scripts/prepush.sh` on the bumped tree first, on their own machine.
3. Land the bump commit through `kci/<commit>` qualification. `main` moves
   only on that commit's `qualified` check. The qualified release head is the
   battery of record; the operator's tag, release, and publish bind to it.
4. An owner dispatches `Publish to Hex` on `main` after the version
   commit's `qualified` run is green. Publishing runs only through this
   workflow on a GitHub-hosted runner, never from a workstation. Its first
   step refuses every other ref. An anonymous Hex read must first prove that
   `ash_replicant` already exists. A missing package name refuses publication;
   first publication is the owner's decision. Before upload it also refuses an
   existing local tag, remote tag, GitHub release, or Hex release. A failed lookup
   refuses publication, and only a clean HTTP 404 proves an absent version. The GitHub
   lookup uses `gh api -i` with the job's read-only token scoped to that
   refusal step. The
   `HEX_API_KEY` secret belongs only to the protected `publish` environment,
   whose deployment branch policy must admit only `main`; only the upload
   step receives it. Keyless steps fetch locked dependencies, build docs, and
   build and inspect both archives, clearing all three dependency selectors for
   the package build. The upload runs `mix run --no-mix-exs` with Hex 2.7.0's API,
   from the runner's temporary directory with the script's absolute path,
   loading no project and uploading those exact files. It reads both archives and
   rechecks package existence and version absence before either upload.
5. After the Hex read-back, tag that same qualified version commit:
   `git tag vNEW_VERSION <sha> && git push origin vNEW_VERSION`.
6. `gh release create vNEW_VERSION --verify-tag --target <sha>` with the
   tag's commit SHA as `<sha>`. Check that the release's `target_commitish`
   equals that SHA. If it names a branch, PATCH it
   (`gh api -X PATCH repos/baselabs/ash_replicant/releases/<id> -f
   target_commitish=<sha>`).
7. `scripts/verify-release.sh NEW_VERSION vNEW_VERSION` — requires a clean
   tree and HEAD equal to the tag. Checks the served Hex checksum against a
   fresh selector-free build, `has_docs: true`, HexDocs HTTP 200, and the
   GitHub release's `target_commitish` against the tag's commit.
8. `scripts/test-fresh-consumer.sh --from-hex NEW_VERSION` — resolves the
   published package, compiles, generates and runs migrations, builds docs,
   and drives the default CDC path against `ASH_REPLICANT_TEST_URL`.
   Before publication, `prepush.sh`'s live lane runs this check from the local
   tarball when `ASH_REPLICANT_TEST_URL` is set.

`verify-release.sh VERSION TAG --check` checks local preconditions only;
it does not verify public release state. The publish workflow's package
inspection compares the unpacked files with `scripts/release-package-files.txt`;
review an allowlist change whenever the package gains or drops a file.
`bump-version.sh VERSION --check` validates the next bump's anchors without writing files.

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
