# ash_replicant — closeout + verifier handoff (2026-07-09)

> **[Superseded 2026-07-09]** The two carried F13/F14 optimizations this doc hands off
> were implemented and closed at **100/100** (`/review-autopilot --fix`, slice commits
> `4ee5338`/`cab54b8`/`82652e7` + closeout fix commits `9052e0c`/`7cd8860`/`4d438b8`),
> and the routed no-notifier-on-mirrored-write coverage gap was closed by `2e50844`
> (`test/ash_replicant/notifier_suppression_test.exs`). Repo HEAD `2e50844`, `main`,
> all gates green (87 tests / 0 failures). Retained as the historical record of the
> state at `f3f2a1f`; do **not** act on its "Open / not done" F13/F14 items — they are
> done. The only remaining work is the deliberately-deferred release/publish path.

## ⚠️ Worst open item first

**No open risk, blocker, or unresolved decision.** The slice closed at **100/100** (fresh-context grader) and the follow-on verifier shipped gate-green. The single most important thing a fresh session must know is a **continuity caveat, not a defect:**

> The spec, plan, and closeout review report live under `docs/superpowers/`, which is **gitignored (local-only)** — they exist ONLY on this machine's disk, never in git. The kickoff handoff, CHARTER, CHANGELOG, AGENTS.md, README, usage-rules ARE tracked. A fresh session **on this machine** has everything; a session on a **different machine** will not have the spec amendments or the review artifact. Do not re-derive that state — read it from disk here.

The only carried *work* is two **advisory** optimizations, deliberately deferred (see Open / not done). Neither is a risk.

## Status

Two things happened this session, both complete and verified:
1. **`/review-autopilot --fix` closeout** of the ash_replicant slice (reviewed range `e5795137..76fb850`). 7 review lenses + cross-vendor Codex + 2 fix-round re-reviews; ~16 findings; all fixed / refuted / routed. Fresh-context grader: **100/100**.
2. **F7 backlog item implemented** — a new `ValidateTenantSource` compile-time verifier (the additive DX-hardening deferred during closeout).

Working tree clean, `main`, HEAD `f3f2a1f`. Full gate battery green and nonce-`--verify`d at HEAD. No remote configured (local-only repo).

## Done (verified)

**Gate evidence (this session, at HEAD `f3f2a1f`, nonce-verified log `docs/superpowers/gate-logs/20260709-015029-ash_replicant_verifier-f3f2a1fd62.log`):**
`mix compile --warnings-as-errors` PASS · `mix format --check` PASS · `mix credo --strict` PASS (200 mods/funs, 0 issues) · migration-drift (`ash_postgres.generate_migrations --check`) PASS · `mix hex.audit` PASS · **`mix test` 53 no-URL / 0 failures + 83 with-URL (30 live-PG16 integration) / 0 failures** · `mix dialyzer` **0 errors / 0 skipped / no ignore-file**. Re-verify with: `~/.claude/scripts/gate-run.sh --verify docs/superpowers/gate-logs/20260709-015029-ash_replicant_verifier-f3f2a1fd62.log ash_replicant_verifier`.

**Closeout fix commits** (`a4bac9c..76fb850`), each with a red-capable test (all tamper-proven non-vacuous by a worktree-isolated re-review):
- `1a7891f` — snapshot path fails closed on empty resolver index. Files: `lib/ash_replicant/sink/impl.ex` (shared `empty_index?/1` across handle_transaction/handle_snapshot/handle_snapshot_complete), `test/ash_replicant/snapshot_test.exs`.
- `dec26a0` — `on_truncate :mirror` clears tenant-blind (was `TenantRequired` dead-end for non-global tenant resources; raw quoted DELETE, `clear_mirror` pattern). Files: `lib/ash_replicant/apply.ex`, `test/ash_replicant/apply_test.exs`.
- `57c00dc` — emit the spec's full telemetry contract (`[:snapshot,:batch]`/`[:snapshot,:complete]` events never emitted before; `:halted` `error_class`; `:applied` `change_count`+`duration`, counted single-pass). Files: `lib/ash_replicant/sink/impl.ex`, `test/ash_replicant/sink_test.exs`, `test/ash_replicant/snapshot_test.exs`.
- `105ba2e` — load-bearing value-free gate for the raw-Postgrex-error class (with a CONTROL assertion; Ash redacts its own changesets, so the sink-level refutes were vacuous). Files: `test/ash_replicant/error_test.exs`.
- `4fa2140` — `transaction?: false` on the per-record upsert (spec decision 7; `Ash.destroy!` has no such option, so destroy joins the ambient txn unchanged). Files: `lib/ash_replicant/apply.ex`.
- `6be3e47` — centralize index-lookup convention (`Resolver.lookup/3`, ×3 sites) + quote ledger ident. Files: `lib/ash_replicant/resolver.ex`, `lib/ash_replicant/apply.ex`, `lib/ash_replicant/sink/impl.ex`.
- `c9931ff` — document the **REPLICA IDENTITY FULL** requirement for tenant-scoped mirrors + a key-only-`old_record` fail-closed red-gate. Files: `AGENTS.md`, `README.md`, `usage-rules.md`, `lib/ash_replicant/resource.ex`, `test/ash_replicant/apply_test.exs`.
- `e62efa4` — closeout docs-currency: CHARTER task-refs/status + CHANGELOG closeout section. Files: `CHANGELOG.md`, `docs/CHARTER.md`.
- `76fb850` — credo `--strict` clean after the fixes (extract `apply_all/2` + `run_snapshot_batch/6`, alias `Impl`). Files: `lib/ash_replicant/sink/impl.ex`, `test/ash_replicant/snapshot_test.exs`.

**Verifier commit** (`f3f2a1f`):
- `feat: ValidateTenantSource verifier`. Files: `lib/ash_replicant/resource/verifiers/validate_tenant_source.ex` (NEW), `lib/ash_replicant/resource.ex` (registered + moduledoc), `test/ash_replicant/validate_tenant_source_test.exs` (NEW, 6 adversarial tests: 2 tripwires RED-proven pre-implement, mfa-branch tamper-proven), `AGENTS.md` (Rule 2 note). Reads `Ash.Resource.Info.multitenancy_strategy/global?` off the `dsl_state`; fails closed at compile time when a non-global multitenant resource declares neither `tenant_attribute` nor `tenant_mfa`. `global?` + non-tenant resources exempt.

**One refuted finding kept in the record (not a fix):** the "tenant-reassignment leaves a ghost row" correctness finding was **REFUTED** by a live throwaway probe (reassign org_1→org_2 → `count=1`, `ON CONFLICT(id)` updates in place; mirror PK globally unique). Evidence in the review report.

## Open / not done

No blocker. Carried items, all optional:

1. **F13 (advisory) — snapshot bulk-path per-row reflection.** `apply_snapshot_batch` calls `Resolver.attrs_for_upsert/2` once per row, each re-deriving `skip`/`cloak`/`attrs` (batch-invariant). Next step: hoist the 3 reflections above the loop and thread precomputed metadata into a per-row mapper. **Why open:** snapshot is one-time backfill, not a hot path; the gain is marginal vs the bulk INSERT, and the fix changes the `Resolver` API surface — a larger-than-mechanical change than the value warrants. Recommendation lives in the review report.
2. **F14 (advisory) — delete path two round-trips.** `Apply.destroy_by_pk/3` does `Ash.get!` then `Ash.destroy!` per delete. Next step: collapse to an atomic filtered `bulk_destroy(:atomic)`. **Why open:** it is a behavior change (atomic vs read-then-destroy) with tenant-scoping implications (interacts with the REPLICA IDENTITY FULL contract) — beyond safe-mechanical.
3. **Publish prep (future release, not this slice).** `mix.exs` still has `{:replicant, path: "../replicant"}`; the spec calls for `{:replicant, "~> 0.1"}` (hex) at publish. v0.1.0 is in CHANGELOG `[Unreleased]`/`[0.1.0]` but **not tagged**; there is no git remote. Next step at release time: swap the path dep for the hex version, tag `v0.1.0`, add a remote + push.
4. **System-level lifecycle experiments (NOT repo work — informational).** The metrics harvest fired two pooled-telemetry triggers: a **dual-pass authoring** reopen (18 authoring/user-attributed findings across 10 slices) and an **intent-level tasks** experiment overdue. These are suggestions for how *future* slices are planned/authored, recorded in `~/.claude/lifecycle-metrics.md`; they do not touch this repo.

**Docs-currency:** verified current this session — spec status header + Closeout amendments block, CHARTER, CHANGELOG all reflect what shipped. No stale "planned/pending" surfaces carried.

## Git + environment

- **HEAD:** `f3f2a1f` on `main`. Clean working tree (`git status --short` empty).
- **This session's range:** `a4bac9c..f3f2a1f` (9 closeout-fix commits + 1 verifier commit).
- **Reviewed slice range:** `e5795137..76fb850` (baseline `e5795137` = pre-scaffold).
- **Worktrees:** one (primary). No concurrent/parallel session — all commits are this session's; **no uncommitted files owned by anyone else.**
- **Remote:** none (local-only repo). Nothing to push; a fresh session cannot pull.
- **Substrate:** live PG16 at `postgres://postgres@localhost:5599/postgres` (docker `replicant_pg16`); integration tests gate on `ASH_REPLICANT_TEST_URL`. Sibling checkouts required for co-development: `../replicant` (path dep), `../ash_postgres` (reference).

## Cadence + guardrails for the next agent

From CLAUDE.md / AGENTS.md (binding):
- **Commit discipline:** explicit pathspecs only — **never `git add -A`** in the project repo. One logical change per commit. Commit/push only when asked.
- **Branch/worktree:** solo project, work on `main`; **no feature branches**. Instrument (never-merged, auto-removed) worktrees are the only exception.
- **Frozen conventions (AGENTS.md Critical Rules — binding):** route writes through Ash actions (never raw Ecto); fail-closed multitenancy; sensitive = AshCloak-encrypted-or-binary (verifier-enforced, **AshCloak is the single source of truth — no hand-rolled `encrypted_<name>`**); **value-free** (no row value in any error/log/telemetry, including the halt path); stay tenant-blind one layer up (never add tenancy to `replicant`); effect-once = one txn / watermark dedup / upsert by PK.
- **TDD:** test-first against the critical rules; gate battery (`mix format` → `credo --strict` → `compile --warnings-as-errors` → `test` → `dialyzer`) green before any commit.
- **No concurrent-executor warning active** (single session, clean tree).

## Referenced artifacts (by path — not duplicated; ⚠ gitignored local-only where noted)

- Closeout review report (all raw lens reports + findings table + dispositions): `docs/superpowers/reviews/2026-07-08-ash-replicant-lens-reports.md` — ⚠ **local-only**.
- Design spec (with the Closeout amendments block): `docs/superpowers/specs/2026-07-08-ash-replicant-design.md` — ⚠ **local-only**.
- Implementation plan (per-task commit ledger, single status source): `docs/superpowers/plans/2026-07-08-ash-replicant.md` — ⚠ **local-only**.
- Gate logs (durable, nonce-bound): `docs/superpowers/gate-logs/` — ⚠ **local-only**.
- Charter (tracked): `docs/CHARTER.md`. Agent contract (tracked, binding): `AGENTS.md`. Changelog: `CHANGELOG.md`. Usage rules: `usage-rules.md`.
- Kickoff handoff (prior session): `docs/handoffs/2026-07-08-ash-replicant-kickoff-handoff.md`.
- Lifecycle metrics (pooled): `~/.claude/lifecycle-metrics.md` and `docs/superpowers/lifecycle-metrics.md`.

## Suggested skills + next action

- **If continuing polish:** knock out F13/F14 with `/exec-autopilot` discipline (or directly, TDD) — both are small and scoped in the review report. Lowest-value work; only if you want the polish.
- **If heading to release:** `/plan-autopilot` is overkill — do the publish-prep checklist in Open item 3 manually (path→hex dep, tag, remote).
- **If nothing else:** the slice is closed at 100/100 and the verifier is shipped green. No action required.
- **Concrete first step for a cold resume:** `cd /Users/rp/Developer/Base/ash_replicant && git rev-parse HEAD` (expect `f3f2a1f…`), then re-verify the gate snapshot with the `gate-run.sh --verify` command in the Done section. A divergent HEAD or a failing verify is a stop condition — surface it before continuing.
