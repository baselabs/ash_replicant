# AshReplicant — start here

Read **`AGENTS.md`** first (critical rules, workflow tiers; binding), then **`docs/CHARTER.md`**
(mission, layering, scope, the effect-once model). AshReplicant is the Ash `Replicant.Sink`
adapter for CDC mirror targets; it owns multitenancy, classification and sensitive data, and runs
through the sibling tenant-blind **`replicant`** framework. Design work reads the `../replicant`
checkout (its `AGENTS.md` holds the logical replication contract); `ash_postgres` comes from Hex.

`graphify-out/graph.json` (gitignored, rebuilt by the post-commit hook when installed) is for
orientation via `graphify query|explain|path`; it is navigation, never evidence, so verify
load-bearing claims against live code. `graphify update .` refreshes it.
