# Handoff — `ash_replicant` kickoff (cold-start for a fresh session)

**Date:** 2026-07-08 · **Type:** forward-looking KICKOFF (not a compaction of prior build work — `ash_replicant` has no build yet). Seeds a new session that will **design then build** `ash_replicant`, now that its gating dependency (`replicant`) is published.

---

## ⚠️ Worst open item first — DO NOT start coding a sink yet

`ash_replicant` is **100% greenfield**: no `mix.exs`, no `lib/`, and it is **not even a git repository** (bare skeleton — `.env`, `.gitignore`, `.vscode/`, empty `docs/`). Nothing has been designed or decided.

The load-bearing decision is **unspecified and must be settled in a brainstorm before any code**:

> **How does an Ash-native sink map a raw CDC change (`%Replicant.Change{schema, table, record, op, ...}`) onto an Ash resource create/update/destroy — resolving the target resource AND the tenant AND the classification — while persisting all resource writes *and* the replication checkpoint in ONE transaction so effect-once (dup = 0, loss = 0) holds?**

This is the analog of `ash_arcadic`'s "open Stage-0 decision." Sub-decisions the brainstorm must resolve (see **Open / not done**): resource resolution (table→resource), change→action mapping (incl. TOAST `unchanged` and PK upsert), the multitenancy model (tenant lives in the **Ash** layer, never pushed back into tenant-blind `replicant`), classification/`sensitive` handling, and the transactional-checkpoint mechanism that yields effect-once.

**First action is `/brainstorm-autopilot`, not `mix new` + a sink module.** Writing a sink before the resource-resolution + tenancy + effect-once model is settled is exactly the wrong move.

---

## Status

`replicant` — the tenant-blind CDC core `ash_replicant` consumes — is **published (v0.1.0) as of 2026-07-08**, which clears the ROADMAP's explicit sequencing gate (*"publish `replicant` to Hex, THEN start `ash_replicant`"*). `ash_replicant` itself is an untouched skeleton. This session did the `replicant` release; **no `ash_replicant` code was written.** The next session begins the `ash_replicant` design from zero, seeded by the context below.

---

## Done (verified) — the dependency this project consumes

**`replicant` 0.1.0 is PUBLISHED** (the thing `ash_replicant` depends on):
- **Hex:** `mix hex.info replicant` → `0.1.0 (2026-07-08)`, MIT. Add as `{:replicant, "~> 0.1"}` (or, for co-development, a path dep `{:replicant, path: "../replicant"}` — the sibling `ash_arcadic` uses `{:arcadic, path: "../arcadic"}`).
- **Docs:** https://hexdocs.pm/replicant/0.1.0 — the authoritative sink contract.
- **Source:** GitHub `baselabs/replicant` (**private**), tag `v0.1.0` → commit `6fe9d3c`. Local checkout `/Users/rp/Developer/Base/replicant` (published state; full unit 388/0 + integration 38/0 live-PG16, dialyzer 0, closeout-graded 100/100).

**The integration surface `ash_replicant` implements** — `Replicant.Sink` (every callback is `@optional`; `Config` enforces which are required per mode). Authoritative source: `replicant/lib/replicant/sink.ex` + hexdocs. Summary (verified this session, do not trust from memory — re-read the module):
- `checkpoint/0 :: {:ok, lsn | nil} | {:error, term()}` — last durably-persisted commit LSN (`nil` = never). Required in sink-owned mode.
- `handle_transaction/1 :: {:ok, lsn} | {:error, term()}` — **the core callback.** Persist the txn's changes + the checkpoint atomically; skip any `commit_lsn <= checkpoint`; upsert rows by table PK; return the LSN.
- `handle_batch/1` — deliver N transactions atomically (opt-in `batch_delivery` mode; sink-owned only).
- `handle_schema_change/2 :: :ok | {:error, term()}` — accept/decline a `%SchemaChange{}`; default halts destructive.
- `sink_kind/0 :: :state_mirror | :append_log` (default `:state_mirror`).
- `handle_snapshot/2` + `handle_snapshot_complete/1` — initial backfill (both or neither).

**Data structs delivered to the sink** (`replicant/lib/replicant/{transaction,change}.ex`):
- `%Replicant.Transaction{commit_lsn, commit_timestamp, changes}` — `changes` is ordinarily a `List`, but for a **spilled** oversized txn it is a lazy single-pass `Enumerable` valid only *during* the call (iterate with `Enum`/`Stream`; never `length`/`Enum.to_list`).
- `%Replicant.Change{op, schema, table, record, old_record, unchanged: [], columns: [], commit_lsn, ordinal}` — `op ∈ :insert | :update | :delete | :truncate | :snapshot`; `record`/`old_record` keys are **binaries** (never atoms); `unchanged` lists TOASTed columns an UPDATE didn't touch (**leave them untouched on upsert — never overwrite with a placeholder**).

**Replicant pipeline modes** (`Replicant.start_link/1` opts): `go_forward_only`, `snapshot`, `max_inflight_lag`, `checkpoint_store` (lib-owned checkpoint for non-transactional sinks), `batch_delivery` (sink-owned atomic batches), `streaming` (+ nested `spill`). **For `ash_replicant`, the natural mode is sink-owned + transactional** (Ash/AshPostgres can write rows + checkpoint in one DB transaction → a `:state_mirror` sink with effect-once), i.e. implement `checkpoint/0` + `handle_transaction/1`; do **not** use `checkpoint_store` (that mode is for sinks that *can't* transact).

**`ash_replicant` skeleton state (verified):** `/Users/rp/Developer/Base/ash_replicant/` contains only `.env` (holds `HEX_API_KEY` — gitignored, redact), `.gitignore` (gitignores `/docs/superpowers/`; mirrors `replicant`), `.vscode/`, and `docs/{handoffs,superpowers}/` (empty but for `.DS_Store`). **No `mix.exs`, no `lib/`, no `.git`.**

---

## Open / not done — the entire `ash_replicant` build

Nothing here has started. In rough order:

1. **`git init`** the repo (it is not under version control yet).
2. **Settle the design (brainstorm output → a charter + spec).** Open decisions:
   - **Resource resolution:** how `schema.table` → an Ash resource (config map? a DSL extension registering resources? a behaviour the host app implements?). This is the "Stage-0" decision.
   - **Change → Ash action mapping:** `:insert`/`:update` → create/update (PK upsert); `:delete` → destroy; `:truncate` → ?; honor `unchanged` (don't overwrite TOASTed cols); map `record` string-keys → resource attributes.
   - **Multitenancy (owned HERE, Ash-native — never in `replicant`):** derive the tenant from the row (a tenant column?) or config; **fail-closed** if unresolvable; enforce via Ash `set_tenant`/policies. Reference `ash_arcadic`/`ash_age` `multitenancy.ex` + `validate_multitenancy_attr.ex`.
   - **Data classification / `sensitive`:** how sensitive attributes are handled (encrypted-at-rest, à la `ash_arcadic`'s sensitive=encrypted-binary?); keep `replicant`'s value-free telemetry/error discipline end-to-end.
   - **Effect-once mechanism:** `handle_transaction/1` must wrap all resource writes **+** the checkpoint write in ONE AshPostgres transaction (skip `commit_lsn <= checkpoint`), so a crash re-delivers and dedups → dup = 0, loss = 0. Decide where the checkpoint lives (a dedicated Ash resource/table).
   - **Schema-change policy:** `handle_schema_change/2` — which drifts are safe vs destructive-halt.
   - **Snapshot/backfill:** implement `handle_snapshot/2` + `handle_snapshot_complete/1` to seed the mirror.
3. **`mix.exs` skeleton** — mirror `ash_arcadic`'s deps shape: `{:ash, "~> 3.x"}`, `{:ash_postgres, ...}` (the data layer the resources use), `{:replicant, "~> 0.1"}` (or path dep), `spark`/`splode` if a DSL extension is built, `jason`, `telemetry`, + dev tools (`ex_doc`, `credo`, `dialyxir`, `mix_audit`).
4. **The sink implementation** (`lib/ash_replicant/…`) + the resolution/tenancy/classification machinery.
5. **Tests to `replicant`'s proof standard:** unit + a **live-PG16 crash-injection marquee** proving effect-once (dup = 0, loss = 0) end-to-end through Ash. `replicant`'s `test/integration/**` crash-injection suites are the template.
6. **Docs mirroring the `ash_X` family:** `README.md`, `AGENTS.md`, `CLAUDE.md`, a gitignored `docs/CHARTER.md`, `CHANGELOG.md`, `usage-rules.md`, `CONTRIBUTING.md`, `LICENSE`, `NOTICE`.
7. **Publish to Hex** when complete (the `HEX_API_KEY` is in `.env`).

**No prior scope was dropped** — this project simply has not started. Nothing was discussed-and-deferred; the above IS the full scope to design.

---

## Git + environment

- **`ash_replicant`:** NOT a git repo (no HEAD, no commits). No concurrent executor. `.env` holds `HEX_API_KEY` (gitignored — redact, never commit/echo). The `.gitignore` gitignores `/docs/superpowers/` (specs/plans/reviews there are on-disk only) but **not** `/docs/handoffs/` — this handoff lives in the tracked `docs/handoffs/`.
- **`replicant` (the dependency):** published `0.1.0`; local HEAD `6fe9d3c` on `main`, tag `v0.1.0`, pushed to private `baselabs/replicant`. Clean tree. Note: `replicant`'s git history was rewritten to a GitHub noreply email at publish, so any SHAs cited in *its* older docs/memory (e.g. `489c6b1`) are historical labels — content intact.
- **Live substrate for tests:** the docker PG16 on `localhost:5599` (`wal_level=logical`) that `replicant` uses; `export REPLICANT_TEST_URL="postgres://postgres@localhost:5599/postgres"`. `ash_replicant` will need the same for its integration marquee.

## Cadence + guardrails for the next agent

- **Global rules bind** (`~/.claude/CLAUDE.md` + `~/.claude/memory-universal/`): absolute honesty (evidence before claims), no MVP/effort-weighting, the decision-protocol 4-axis double-take on every design choice, "done = zero open risk."
- **`ash_X` family conventions (from the sibling `ash_arcadic` — read its `CLAUDE.md` + `AGENTS.md` first):** a `CLAUDE.md` start-here pointer → binding `AGENTS.md` → an unpublished gitignored `docs/CHARTER.md` carrying mission/layering/scope/the open Stage-0 decision. **Tenancy + classification live in the Ash layer, NEVER in the transport** — keep `replicant` tenant-blind (do not send patches upstream to add tenancy). Fail-closed multitenancy. `sensitive` ⇒ encrypted. Carry `replicant`'s value-free (no row value in any error/log/telemetry) discipline through the Ash mapping.
- **Commit discipline:** explicit pathspecs only, never `git add -A`; solo project ⇒ no feature branches (work on `main` after `git init`); one logical change per commit.
- **Do not conflate layers:** `replicant` = tenant-blind CDC transport (published); `ash_replicant` = the Ash sink adapter one layer up. Same split as `postgrex`/`ash_postgres` and `arcadic`/`ash_arcadic`.

## Referenced artifacts (by path/URL — do NOT duplicate)

- **`replicant` sink contract:** https://hexdocs.pm/replicant/0.1.0 · `Replicant.Sink` (`/Users/rp/Developer/Base/replicant/lib/replicant/sink.ex`), `Replicant.Transaction`, `Replicant.Change`.
- **`replicant` layering + `ash_replicant` intent:** `/Users/rp/Developer/Base/replicant/README.md` (the "one layer up, in a future `ash_replicant` sink adapter" framing + the Roadmap) and its `AGENTS.md` (the 5 critical rules, incl. "stay tenant-blind").
- **The `ash_X` pattern (closest template):** `/Users/rp/Developer/Base/ash_arcadic/` — read `CLAUDE.md`, `AGENTS.md`, `docs/CHARTER.md` (gitignored), `mix.exs`, and `lib/` structure. NOTE: `ash_arcadic` is an Ash **DataLayer**; `ash_replicant` is a **sink adapter** (different shape) — mirror its *conventions/tenancy/sensitive patterns*, not its data-layer callbacks.
- **Multitenancy/`sensitive` design reference:** `/Users/rp/Developer/Base/ash_age/` (the reference `ash_arcadic` itself ports from).
- **`replicant` crash-injection test template:** `/Users/rp/Developer/Base/replicant/test/integration/**` (the effect-once, loss=0 proof standard to match).

## Suggested skills + concrete next action

1. **First:** `cd /Users/rp/Developer/Base/ash_replicant && git init`. Read the references above — especially `Replicant.Sink` (the contract you implement) and `ash_arcadic`'s `CLAUDE.md`/`AGENTS.md`/`CHARTER.md` (the conventions you mirror).
2. **Then `/brainstorm-autopilot`** to design `ash_replicant` — settle the resource-resolution + multitenancy + classification + **effect-once transactional-checkpoint** model (the Worst-open-item decision). Output a `docs/CHARTER.md` + a design spec. **Do not write sink code before the design is settled.**
3. **Then the lifecycle:** `/plan-autopilot <spec>` → `/exec-autopilot <plan>` → `/review-autopilot <spec> <plan> --fix`, matching `replicant`'s bar (per-task two-stage review, live-PG16 crash-injection marquee proving dup=0/loss=0, 100/100 closeout).
4. **Finally:** publish to Hex (`HEX_API_KEY` in `.env`), mirroring the `replicant` release (private GitHub repo in `baselabs`, `v0.x.0` tag, `mix hex.publish`).
