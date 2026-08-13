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
   strict and always owns a live sandbox. The job also observes that
   `AshReplicant.TestRepo` has no registered process.
2. The live compatibility jobs start PostgreSQL with logical replication,
   create and migrate the isolated test database, run the full suite, and run
   `test/integration/` explicitly.
3. `scripts/assert-exunit-output.sh` is the one parser used by real CI output and
   red probes. It accepts only `Result: N passed` where `N > 0`; zero tests,
   failures, skips, and exclusions all fail.
4. Migration drift is checked against `AshReplicant.Test.Domain`. The command
   preloads `AshPostgres.CustomIndex` because AshPostgres decodes snapshot keys
   as existing atoms; after that preload, unchanged snapshots pass and a
   resource-only attribute mutation raises pending-codegen failure.
5. The selector-free release job asserts the public Ash range, builds docs with
   warnings as errors, unpacks the Hex package, requires its code/docs/license
   paths, and rejects test, Forge, build, environment, and credential-shaped
   residue.

Every new gate needs a red-capable probe against the exact checked-in command or
script used by CI. A separately implemented “test of the idea” is not evidence
for the production gate.

## Consequences

- No-database and live-database failures are independently attributable.
- Removing an integration tag, deleting the integration suite, skipping cases,
  or producing zero tests cannot yield a green live job.
- Compatibility selectors cannot contaminate selector-free package evidence.
- Migration drift is caught before a release even when runtime migrations still
  apply successfully.
- CI performs more than one test invocation, intentionally: the full suite
  proves composition, while the explicit directory run proves discovery.

## Evidence

- Test split: `test/ash_replicant/checkpoint_policy_test.exs` and
  `test/integration/checkpoint_policy_test.exs`.
- Gate implementations: `.github/workflows/ci.yml`,
  `scripts/assert-exunit-output.sh`, and
  `scripts/assert-dependency-version.sh`.
- Local red probes: DataCase/no-Repo, missing integration tag, fabricated ExUnit
  results, nonmatching dependency requirement, and migration-resource drift.
