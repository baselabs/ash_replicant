# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir 1.20.3** and **Erlang/OTP 29** support; exact checkout releases come only
  from `.tool-versions`. Every CI
  install uses setup-beam's `version-file: .tool-versions` and `version-type: strict`,
  then refuses unless installed Elixir and the full OTP release match that file.
- Ash `>= 3.37.3 and < 4.0.0-0`; selector-free development uses this public range
- Replicant `>= 1.6.0 and < 2.0.0-0` from Hex; the lock is 1.6.0.
- Postgrex `~> 0.23` from Hex; the lock is 0.23.0.
  No sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design work and is never release evidence.
- AshCloak `>= 0.4.0 and < 1.0.0-0` from Hex; the current lock is 0.4.0 (the
  CVE-2026-81319 / CVE-2026-81322 security floor — every earlier release is
  vulnerable and the requirement refuses to resolve to one).
- **PostgreSQL** with `wal_level=logical` for the live integration gate; the
  integration suite runs against a live Postgres with a logical replication slot
  and publication. CI runs the checked BaseLabs platform engine plus declared
  upstream compatibility lanes and `decoder-old-majors` sources (with the plugin substrate —
  `test/support/pg_old.dockerfile`, the commit-pinned pglogical 2.4.8 +
  wal2json build). Each CI job owns its disposable PostgreSQL and supplies
  `ASH_REPLICANT_TEST_URL` and, for the plugin lane, `ASH_REPLICANT_PGOLD_URL`.
  The support matrix is pgoutput on PG12 and 15–18, pglogical/wal2json on
  PG9.6 and 12; derive the live major rather than assuming it from this doc.

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
The `fresh-consumer` qualification job builds the candidate tarball and runs the full
consumer against its own logical-WAL platform engine: fresh dependency resolution, both
audits, compilation with warnings as errors, docs, migrations, and the live CDC smoke.
The `deps.audit --path` call runs from the repository's dev environment, where
`mix_audit` is declared; Hex's audit runs inside the consumer. The post-publish job
uses the same script with `--from-hex VERSION` for the exact published release.

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
The final `qualified` check reads the run's complete job inventory and requires
all eleven expected proofs to finish successfully. `main` moves only on that
commit's `qualified` check; a push to `main`, a tag, or a release starts no run.
If qualification fails, fix forward in the next commit.

Job timeouts follow infra's binding CI requirements linked below. Each job's
comment identifies its slowest measured green run and duration. Publish has no
green run yet and uses `90 # no green run yet` until infra measures one.

The infrastructure maintainers' CI requirements bind every workflow and release script here;
maintainers read them as directed in `AGENTS.md`.


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
  scripts/with-release-runtime.sh scripts/test-release-guards.sh
  scripts/with-release-runtime.sh scripts/test-release-contract.sh
  ```

  These live-suite and migration-drift commands are mandatory parts of the
  pre-PR release battery, in addition to the checks in step 3.

  CI fetches the exact-floor cell from `locks/exact-floors.lock`, the
  latest-compatible cell from `locks/latest-compatible.lock`, and current-lock
  cells from `mix.lock`. It copies the selected committed lock to `mix.lock`
  before `mix deps.get --check-locked`. The fresh tarball consumer starts without
  a lock and resolves its own dependencies; other qualification projects fetch locked.
  Version assertions check the committed versions against their requirements; newest-release comparisons run only in the drift report.
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

All workflows declare `defaults: run: shell: bash`, and shell scripts use bash with
`set -euo pipefail`. A failing test, build, audit, scan, publication or compared listing fails
its check. Capture output with a standalone assignment before a comparison; never hide its
status in process substitution or another command's argument. Optional grep counts permit
status 1 (no match), while read errors fail. Only diagnostics after a known failure and
cleanup use best-effort commands.

Contributors prepare the version commit; infra owns every publication action and credential.
Agents finish at `main` through the route in `AGENTS.md` under "Build and test". All builds and
tests run on GitHub-hosted CI, never on the owner's Mac or the build box.

1. Run `scripts/bump-version.sh NEW_VERSION` to update the version-bearing anchors and
   changelog. Commit with named paths and qualify through a topic `kci/` ref. After green,
   make a final docs-only commit with a fresh SHA for the landing tool; never push that landing
   SHA to any `kci/` ref beforehand. Infra reviews workflow and release-script changes before
   landing. The landing tool alone moves `main` after its `qualified` check.
2. Infra asks an owner (`corepay` or `palermo-git`, including the triggering actor on reruns)
   to dispatch `publish.yml` on `main`, with no inputs. Its first step refuses every other
   ref; the default-branch ruleset is the qualification guarantee. No job rechecks
   qualification or downloads qualification artifacts.
3. An anonymous Hex read requires an existing `ash_replicant` package name. A missing name
   refuses: first publication is the owner's decision. A local tag, remote tag or GitHub
   release for the version refuses. GitHub REST reads use `gh api -i` with `GH_TOKEN` scoped
   to the reading step; only HTTP 404 proves absence. Lookup failures refuse.
4. Keyless steps fetch locked dependencies and build and inspect the package with all three
   dependency selectors cleared. Docs render once from an extracted source tree with locked
   ExDoc 0.40.4, Makeup Elixir 1.0.1 and warnings as errors. HTML and Markdown ship; EPUB
   embeds build time. After rendering, `release.json` records exactly `package: ash_replicant`,
   the version and the run's full `GITHUB_SHA`. Hex 2.7.0 creates a sorted, fixed-metadata archive;
   the checker inspects every visible rendered file and validates the provenance.
5. An untagged version already on Hex is a held or partial release. Its package checksum must
   equal the inspected archive and it must not be retired. Docs planning uses presence:
   readable served docs are kept whatever `has_docs` says. HTTP 404 permits upload only with
   `has_docs: false`; a 404 with `has_docs: true` refuses as metadata/repository disagreement.
   Other responses or malformed archives refuse. Infra's release rule never replaces or compares
   served docs. Hex itself permits republishing, but replacing them would bind the version's docs to a
   different commit than the one infra tags. Comparing a rebuild could refuse a held release
   whose package bytes match. A second owner dispatch finishes an approved hold or interrupted
   upload; ambiguous results require infra to inspect public state first.
6. Only the upload job belongs to environment `publish`. Only the upload step receives
   `HEX_API_KEY`, in its environment, and runs `mix run --no-mix-exs` from the runner's
   temporary directory with no `mix.exs`. It reads inspected archives, loads no project, builds
   nothing, checks package existence again and compares the served package checksum. Its docs
   check requires a readable gzip tarball; no served-docs digest is compared with a rebuild.
7. A separate keyless read-back downloads and inspects the served docs. It requires `index.html`
   and exactly the `release.json` fields above, naming this package/version and the dispatched
   commit or an ancestor in fetched, complete default-branch history. Missing provenance,
   invalid identity, unrelated commits and unavailable history refuse. Equal package bytes
   alone cannot identify docs rendered from unpackaged guides or the docs dependency lock.
   The published commit is reported as the `published_commit` job output and retained in
   `published-commit.txt`. The `release-assets` artifact carries the downloaded package and
   SERVED docs, with `SHA256SUMS` for those bytes. `RELEASE-NOTES.md` takes the release section
   from the changelog inside the served package, followed by the published commit and both
   archive digests. Publication refuses a missing, duplicated or empty release section before
   any build or upload. Temporary archives are removed even on failure.
   A published-package check needs the upload job, holds no key or environment, and exercises
   a fresh registry consumer against real PostgreSQL. Qualification consumes the candidate tarball.
8. Infra tags `v<version>` at the published commit from the served provenance, compares the
   artifact package with Hex, and creates the GitHub release from those assets. No workflow
   creates a GitHub release or runs on a tag. After infra reports read-back and the tag, this
   repository records the verified package digest in `scripts/release/published_packages.sha256`
   through normal landing. Held versions never change the ledger speculatively. A release is
   complete only when its tag, Hex package, docs and GitHub release all exist.

Consumers verify the permanent [GitHub release](https://github.com/baselabs/ash_replicant/releases)
for `v<version>`, rather than the expiring workflow artifact:

```bash
gh release download vX.Y.Z --repo baselabs/ash_replicant --pattern 'ash_replicant-*' --pattern SHA256SUMS
sha256sum --check SHA256SUMS
curl --fail --silent --show-error https://repo.hex.pm/tarballs/ash_replicant-X.Y.Z.tar -o hex.tar
cmp ash_replicant-X.Y.Z.tar hex.tar
curl --fail --silent --show-error https://repo.hex.pm/docs/ash_replicant-X.Y.Z.tar.gz -o hex-docs.tar.gz
tar -xOf hex-docs.tar.gz release.json
rm hex.tar hex-docs.tar.gz
```

Check that the served provenance names `ash_replicant`, `X.Y.Z`, and the release tag's full commit.
The asset checksum verifies the retained served docs; it does not compare a new docs build.

`scripts/verify-release.sh VERSION TAG --check` checks local tree/tag preconditions only.
Its full mode verifies public state from the exact tagged tree. The publish workflow's package
inspection compares unpacked files with `scripts/release-package-files.txt`; review the allowlist
whenever package contents change. `bump-version.sh VERSION --check` checks bump anchors without
writing files. These builds and tests follow the CI-only route above.

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
