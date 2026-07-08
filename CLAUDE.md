# AshReplicant — start here

**Before any work, read these two files (this repo's context is in them, not here):**

1. **`AGENTS.md`** — the working guide: critical rules (route writes through Ash actions,
   fail-closed multitenancy, sensitive = AshCloak-encrypted-or-binary, value-free scrubbing,
   tenant-blind layering, effect-once watermark), the target sink-adapter surface, and
   the dev/test workflow. **Binding.**
2. **`docs/CHARTER.md`** — the project charter: mission, layering, scope, the decisions,
   and the resolved effect-once model. **Tracked** (only `/docs/superpowers/` lifecycle
   artifacts are gitignored / local-only).

## One-line orientation

AshReplicant is the **Ash `Replicant.Sink` adapter for CDC mirror targets** — the
"`ash_postgres` of `replicant`." It owns multitenancy / classification / sensitive-data
handling and executes through the sibling **`replicant`** CDC framework (tenant-blind,
Ash-agnostic).

## Cross-repo context (needed for the brainstorm)

This repo is not self-contained. Design work reads two sibling checkouts by path:

- **`../replicant`** — the CDC transport; see its `AGENTS.md` for the verified
  Postgres logical replication contract and effect-once watermark semantics.
- **`../ash_postgres`** — the Ash data layer Ash uses for direct Postgres access.
  AshReplicant mirrors the Ash-action path (the `tenant:` option on the Ash action,
  policies, multitenancy) without owning transport.

Run brainstorm/plan/implement sessions from a checkout where both siblings exist.
