# 3. Release evidence must prove each execution substrate

Date: 2026-08-13

## Status

Accepted for the 1.0.0 release line.

## Context

The checkpoint policy test mixed three database-free resource-introspection
cases with six database enforcement cases under `AshReplicant.DataCase`.
`mix test --exclude integration` therefore started a sandbox owner for an
unstarted Repo and failed before the pure assertions ran.

The previous CI job had the inverse quiet-failure risk: one live job rejected an
`excluded` count, but it did not prove that integration files were discovered,
did not reject skipped tests, did not check migration drift, and built package
evidence under the same environment-dependent Ash selector used for
compatibility testing.

## Decision

Release evidence is separated by what it proves:

1. The no-database job has no PostgreSQL service and no
   `ASH_REPLICANT_TEST_URL`. Pure tests use `ExUnit.Case`; `DataCase` remains
   strict and always owns a live sandbox. A same-VM start-attempt marker and
   after-suite assertion prove that `AshReplicant.TestRepo` was never started.
2. The live compatibility jobs start PostgreSQL with logical replication,
   create and migrate the isolated test database, and exercise the exact Ash
   floor, the checked-in lock, and the reviewed latest-compatible lock. They
   run the full suite and run `test/integration/` explicitly. Newest-release
   queries and fresh upstream resolution belong to the separate daily or
   dispatched drift report, which supplies no qualification verdict.
3. `scripts/run-structural-tests.sh` captures raw ExUnit output without
   publishing it, rejects uncontrolled process errors, and exposes only the
   value-free structural result. `scripts/assert-exunit-output.sh` requires
   exactly one positive result: failures, skips, invalid cases, zero tests, and
   a later clean-looking summary all fail. Exclusions require the explicit
   `--allow-excluded` mode used only by the database-free run. Checked-in
   negative tests exercise assertion failures and background-process crashes
   and prove that their values are not printed.
4. Migration drift is checked against both configured domains,
   `AshReplicant.Test.Domain` and `AshReplicant.Test.HistoryDomain`. The command
   preloads `AshPostgres.CustomIndex` because AshPostgres decodes snapshot keys
   as existing atoms; after that preload, unchanged snapshots pass and a
   resource-only attribute mutation raises pending-codegen failure.
5. Every job compiles with warnings as errors before any `mix run` checker can
   reuse compiled code. Every job asserts the running Elixir/OTP identity.
   `scripts/with-release-runtime.sh` gives local commands the same coherent
   Elixir/OTP path. Third-party Actions and the PostgreSQL integration image are
   pinned to immutable digests.
6. `scripts/assert-release-contract.sh` loads the workflows through the same
   YAML decoding model GitHub Actions consumes. It traverses every semantic
   `uses` key, requires immutable third-party Action revisions, requires each
   release command as an independently executable step, and binds the exact
   compatibility matrix selector to one contiguous resolve/unlock/assert block.
   Published runtime statements must live visibly in dedicated Markdown
   sections; comments, code fences, and additive contradictions do not count.
   Independent mutation cases cover every required command and each matrix,
   documentation, and Action-pinning decision.
7. The selector-free release job asserts the public Ash range, builds docs with
   warnings as errors, unpacks the Hex package, requires its code/docs/license
   paths, and rejects test, Forge, build, environment, and credential-shaped
   residue.

8. `scripts/run-mutation-gates.py` proves the fail-closed data-boundary
   guards are observed by the no-database focused tests. Each matrix cell
   removes exactly one production guard, removes one sibling call site of a
   shared guard, or moves one notifier guard after its first effect — across
   the nine SEC01 families (tenant absence, tenant reassignment, replica
   identity, sensitive type shape, sink-action
   multitenancy bypass, dynamic destination participants, notifier load
   drift, snapshot fingerprint collisions, append identity) in an isolated
   `mktemp` copy of the tracked working tree, and requires the named focused
   selector to fail with the cell's property-specific fingerprint — never
   merely its test name. Dependencies are copied (never symlinked) and made
   read-only; every child process runs in its own session with
   `ASH_REPLICANT_TEST_URL`, `MIX_BUILD_ROOT`, `MIX_BUILD_PATH`, and
   `MIX_DEPS_PATH` deleted and the green baseline asserts zero `TestRepo`
   start attempts; SIGINT/SIGTERM teardown kills and confirms the active
   child process group before scratch cleanup; build identity is proven by strictly
   increasing source stamps plus BEAM digests (the mutant's differs from
   pristine, the restoration returns to it exactly), with `File.read!`
   source-pin cells declaring that observation mode instead. The runner's
   output is structural and value-free; its sentinel self-test drives every
   failure class (missing/duplicate anchor, duplicate cell id, inert
   replacement, stale build, restoration drift, baseline failure, vacuous
   mutant, wrong red, regressed green control, interrupt/termination with a
   live child, timeout with a live descendant, manifest error, internal error)
   and fails if an injected value-shaped
   sentinel from child output ever reaches the runner's own output. The
   matrix runs once in the no-database job and is pinned by the release
   contract. It fetches the PR base SHA or `main` and scopes the candidate diff
   with `--diff-base FETCH_HEAD`; an unavailable base or an evidence-machinery
   change runs the full matrix. The compatibility matrices keep running the
   focused tests on their own dependency builds without repeating the mutations.

The proof jobs live in `.github/workflows/qualification.yml`, callable only
through `workflow_call`. `.github/workflows/ci.yml` calls them only for
`kci/**` pushes, without path or tag filters. Its final `qualified` job reads
every job of the run and requires the exact ten-check inventory, one completed
successful execution per check, plus a successful reusable-workflow result.
`main` moves only on that commit's `qualified` check. Pushes to `main`, tags,
and releases start nothing. `.github/workflows/pull-request.yml` calls the
same proofs under review check names, without secrets or a `qualified` check.
All executable jobs use GitHub-hosted `ubuntu-24.04` runners.

Every new gate needs a red-capable probe against the exact checked-in command or
script used by CI. A separately implemented “test of the idea” is not evidence
for the production gate.

## Docs presence and provenance (1.6.4)

Docs render once per job with locked dependencies and warnings as errors. The fixed-metadata
Hex archive builder and every-file inspection remain; no check compares two builds or requires
served docs to equal a rebuild. The package remains the byte identity: a mismatch or retirement
refuses publication. Infra's release rule never replaces or compares served docs. Hex itself
allows republishing, but replacing docs would bind the version to a different docs commit than
the one infra tags; comparing a rebuild could refuse a held release whose package bytes match.
Preflight and upload planning keep readable served docs whatever `has_docs` says. HTTP 404
permits upload only with `has_docs: false`; advertised docs plus a 404 refuse as metadata/repository
disagreement. Other responses or malformed archives refuse.

Equal package bytes cannot identify the docs source: `CONTRIBUTING.md` is an ExDoc extra but
is absent from the package, as is the docs toolchain lock. After rendering, every built archive
therefore carries top-level `release.json` with exactly `package`, `version` and the run's full
`GITHUB_SHA`. Keyless read-back inspects the served archive and requires `index.html`, matching
package/version provenance and a commit equal to or ancestral to the dispatched commit in fetched,
complete default-branch history. Missing provenance or history and unrelated commits refuse.
The published commit is the served provenance commit, reported as `published_commit` for infra's
tag. `release-assets` retains the served docs bytes, their checksum and `published-commit.txt`.

The real-Hex keyless self-test proves readable published docs are kept for planning and legacy
docs without provenance refuse read-back. Actual archives and real Git histories exercise field,
ancestry and retained-asset checks. Publication and keys remain infra's work.

## Consequences

- No-database and live-database failures are independently attributable.
- Removing an integration tag, deleting the integration suite, skipping cases,
  or producing zero tests cannot yield a green workflow.
- Compatibility selectors cannot contaminate selector-free package evidence.
- Migration drift is caught before a release even when runtime migrations still
  apply successfully.
- CI performs more than one test invocation, intentionally: the full suite
  proves composition, while the explicit directory run proves discovery.

## Evidence

- Test split: `test/ash_replicant/checkpoint_policy_test.exs` and
  `test/integration/checkpoint_policy_test.exs`.
- Gate implementations: `.github/workflows/qualification.yml`,
  `.github/workflows/ci.yml`, `.github/workflows/pull-request.yml`,
  `scripts/qualify.py`, `scripts/qualification-jobs.json`,
  `scripts/run-structural-tests.sh`, `scripts/assert-exunit-output.sh`,
  `scripts/assert-dependency-version.sh`, and
  `scripts/assert-release-contract.sh` with its decoded-YAML validator and
  mutation battery.
- Local red probes: DataCase/no-Repo, missing integration tag, fabricated ExUnit
  results, assertion and background-process failures, nonmatching dependency
  requirements, workflow mutations, stale runtime documentation, and
  migration-resource drift.
- Guard-mutation gates: `scripts/run-mutation-gates.py` (the per-guard/per-path
  matrix, its isolation and build-identity machinery, and the sentinel
  self-test), wired as the no-database job's final step and pinned by
  `scripts/assert_release_contract.exs` / `scripts/test_release_contract.exs`.
