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

## graphify (code knowledge graph)

`graphify-out/graph.json` maps this repo (tree-sitter AST; rebuilt by the git post-commit hook; gitignored).

- For orientation ("where is X handled", "what connects A to B", "explain module M"), prefer `graphify query "<question>"` / `graphify explain "<Module>"` / `graphify path "<A>" "<B>"` over grep/Read fan-outs — one call returns a scoped subgraph with file:line hits.
- Graph output is NAVIGATION, never evidence. Edges reflect the last build, not the working tree, and cross-module call edges can be incomplete (Elixir: file-local only — alias-mediated calls are NOT resolved). Consumer sweeps and every load-bearing claim (review finding, plan anchor) still verify against live code: grep + file:line read.
- After large uncommitted changes, `graphify update .` refreshes the graph (AST-only, no API cost, no key).
