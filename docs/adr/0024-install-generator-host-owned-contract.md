# 24. The install generator writes host-owned code and never guesses

Date: 2026-09-28 (authored on documentation reconciliation; the decision
shipped in 1.0.0, roadmap I01)

## Status

Status: Accepted.

## Context

A fresh adopter runs `mix ash_replicant.install` inside their application.
The generator is the first code this package executes on a host machine, it
runs behind an **optional** Igniter dependency (some hosts do not carry
Igniter at all), and every fact it needs — which repo, which module names,
which domain — belongs to the host, not the package. A generator that guesses
a repo, a module name, or a connection writes broken or dangerous host code
and erodes trust on first contact. The same obligations apply to the README's
"Manual installation" block: hand-copying code that silently diverges from
what the generator produces creates two installation truths.

## Decision

1. `mix ash_replicant.install` writes exactly four host modules — an Ash
   domain, the checkpoint resource, the sink, and an `AshReplicant.Pipeline`
   supervisor — then registers the domain, supervises the pipeline, imports
   AshReplicant's formatter metadata, and queues `mix ash.codegen`.
2. It writes **no** connection, publication, source-identity, or key
   material. A fresh install compiles and boots as a no-op: the generated
   pipeline supervises nothing until the operator configures it, and a
   present-but-incomplete configuration RAISES (naming keys, never values)
   rather than supervising nothing.
3. Every refusal — malformed module name, illegal slot, missing, ambiguous,
   unknown, or non-AshPostgres repo, incomplete facts, foreign target,
   unreadable binding, or a checkpoint/sink/pipeline bound to another
   identity — writes nothing and names the resolving flag or structural fact.
4. Refusal decisions live in the Igniter-free `AshReplicant.Install` planner
   (`lib/ash_replicant/install.ex`) so each one carries a unit test; the Mix
   task only gathers facts and renders.
5. The README's "Manual installation" block is tied to the installer's real
   output by tests
   (`test/ash_replicant/install_task_test.exs` asserts the block declares
   exactly what the installer generates; `test/docs_test.exs` asserts the
   block's presence) — change one and the other must change.

## Consequences

- Installation is safe by default: no secrets, no guessed identities, and a
  bootable no-op until the operator supplies facts.
- Refusals are reviewable, unit-tested decisions rather than Igniter
  runtime errors, and they hold on hosts without Igniter.
- The manual path cannot silently diverge from the generated one in the
  declarations the tie test compares — module names, `use` lines, and their
  options — without a test failing.
