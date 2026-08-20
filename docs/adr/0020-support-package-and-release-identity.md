# 20. Support and release claims bind to one fetched artifact

Date: 2026-08-19

## Status

Status: Proposed for the 1.0.0 release line (roadmap D1, D6, D8-D9, and E1-E2).

## Context

The current package is 0.4.0, its Elixir requirement is patch-minor narrow, CI
primarily proves PostgreSQL 16, and workspace tests cannot prove that the Hex
tarball contains installers, migrations, operations docs, or the fixed Replicant
release. Publication makes package bytes effectively immutable, so a stable-major
claim must bind support, documentation, provenance, and consumer evidence to the
same artifact.

## Decision

1. The 1.0 support contract names only live-proven combinations. PostgreSQL
   15-18 are required release lanes; version-gated failover claims apply only
   where PostgreSQL exposes and the matrix proves them. PG15 follows its
   published warning/EOL policy; PG19 is a non-blocking canary until explicit
   support. AshReplicant cannot claim a major the fetched Replicant transport
   does not own and prove.
2. Elixir 1.20.3 remains the floor. Minimum and latest-compatible Elixir/OTP and
   dependency cells run; the public Elixir range widens beyond the patch-minor
   constraint only after a green 1.21 RC/final lane. Ash 4 remains excluded until
   an official RC triggers a separate compatibility decision.
3. Igniter is an optional dependency and the canonical install/upgrade surface.
   Deterministic manual instructions remain supported. Golden fresh-install and
   every-published-upgrade/rollback fixtures must converge from the unpacked
   candidate.
4. The public module/function/type/DSL/error/default/telemetry inventory is
   frozen for 1.0. Internal modules, generated config, persistent-term keys, and
   test seams are explicitly excluded and swept in real consumers.
5. One release commit produces one canonical tarball manifest, checksum, SBOM,
   license report, docs source reference, and GitHub attestation. The same bytes
   pass matrix, fault, performance, security, package, fresh-consumer, and
   Navyler acceptance before separately authorized publication.
6. Post-publication verification refetches Hex metadata and tarball, checks the
   checksum/content/docs source, and compiles a clean consumer. Replace/revert,
   retirement, tag, GitHub release, and Hex publish remain explicit operator
   actions with tested recovery instructions.

## Consequences

- A sibling checkout or green workspace cannot satisfy the Replicant floor or
  package acceptance.
- Support expands additively after proof and contracts only through the declared
  lifecycle/deprecation policy.
- OpenTelemetry SDK and unstable semantic-convention names do not enter the core
  dependency or public readiness contract.

## Required proof before acceptance

- Exact floor/latest BEAM/dependency cells; PG15-18 live cells and PG19 canary;
  unpack/install/upgrade/rollback; package-content mutation gates; SBOM/license/
  secret/advisory checks; attestation verification; fresh tarball consumer;
  Navyler RC; and post-publish checksum/content fetch.
