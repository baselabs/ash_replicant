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
   floor, the checked-in lock, and the newest compatible Ash 3 release. They
   run the full suite and run `test/integration/` explicitly.
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
6. `scripts/assert-release-contract.sh` loads the workflow through the same
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

Every new gate needs a red-capable probe against the exact checked-in command or
script used by CI. A separately implemented “test of the idea” is not evidence
for the production gate.

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
- Gate implementations: `.github/workflows/ci.yml`,
  `scripts/run-structural-tests.sh`, `scripts/assert-exunit-output.sh`,
  `scripts/assert-dependency-version.sh`, and
  `scripts/assert-release-contract.sh` with its decoded-YAML validator and
  mutation battery.
- Local red probes: DataCase/no-Repo, missing integration tag, fabricated ExUnit
  results, assertion and background-process failures, nonmatching dependency
  requirements, workflow mutations, stale runtime documentation, and
  migration-resource drift.
