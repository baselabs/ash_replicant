# 25. The diagnosis surface is read-only, an adapter, and never guesses

Date: 2026-09-28 (authored on documentation reconciliation; the decision
shipped in 1.0.0, roadmap O01)

## Status

Status: Accepted. Supersedes: none (realizes the read-only readiness view
that ADR-0019 announced in one future-tense line).

## Context

Operators must be able to ask "is this pipeline's source, slot, checkpoint,
contract, retention, and runtime ready?" — often on a production database —
without any risk of the diagnostic itself writing, locking, or blocking
delivery. A diagnosis surface also drifts fastest when it re-implements the
rules activation runs: a doctor that disagrees with the runtime it diagnoses
is worse than no doctor, because operators act on it.

## Decision

1. `mix ash_replicant.preflight` / `mix ash_replicant.doctor` (and their
   in-process twins `AshReplicant.preflight/1` / `AshReplicant.doctor/1`)
   diagnose through `AshReplicant.Doctor`, and the no-writes guarantee rests
   on THREE independent legs:
   - `Doctor.Probe.admit!/1` refuses any statement that is not provably
     read-only (leading `SELECT`, no separator, no write verb, no row lock,
     no session-escaping function);
   - the probe connection carries `default_transaction_read_only=on`, so
     PostgreSQL itself refuses what admission missed;
   - the destination read uses the checkpoint's `:read` action with
     `authorize?: false` and NEVER a lock.
   Adding a statement means adding it to `Probe.statements/1`, which the
   non-vacuity test admits and the live gate executes.
2. The doctor is an ADAPTER over the rules activation already runs —
   `Coverage`, `Identity.classify_stored_contract/3`,
   `Destination.manifest/1`, `Pipeline.start_options/3` — never a
   re-implementation. Where a rule is private and short-circuiting, the
   public delegate exposes the SAME body
   (`Coverage.replica_identity_check/2`, `Coverage.probe_identity_check/2`),
   never a copy.
3. Results are one canonical `%Doctor.Check{}` with a closed reason
   vocabulary. `detail` is a fail-closed ALLOWLIST of reasons whose
   `%Error{}.shape` is a catalog identifier, so an identity-class shape
   (which embeds the source database) can never reach operator output.
4. Anything unjudgeable is `:skipped` with the reason it could not be judged —
   never `:pass`.

## Consequences

- A diagnosis cannot write, lock, or block delivery even if a statement is
  misclassified; two independent legs must fail together before a write
  reaches the server, and the third leg reads without locks.
- Diagnosis fidelity is bounded by activation fidelity: new checks come from
  new activation rules (or delegates to them), which keeps the doctor from
  contradicting the runtime.
- `:skipped` is an honest per-check unknown: skipped checks stay visible in the
  report's per-check results, while the aggregate verdict (`Doctor.Report`)
  stays green unless a check fails or warns — so operators must read the
  per-check results, not just the exit code.
