# AshReplicant handoff — 2026-07-09 (post-0.2.0 release + SCD2 plan ready)

_For a fresh agent with zero conversation history, after a machine reboot + Claude account switch._

## ⚠️ Worst open item first

**The SCD2 history-mirror feature is fully designed + planned + independently reviewed, but NOT executed — zero implementation code exists yet.** The next action is to execute the plan. **Reboot blocker for that:** the PostgreSQL container the plan's integration tests depend on has `RestartPolicy=no`, so the reboot will stop it. **Before running any test or gate:**

```bash
docker start replicant_pg16          # the stopped container survives reboot with its data
docker ps --filter name=replicant_pg16   # confirm State=running, 0.0.0.0:5599->5432
```

If the container is **gone** (not just stopped), recreate it — `wal_level=logical` is mandatory:

```bash
docker run -d --name replicant_pg16 -p 5599:5432 -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16 -c wal_level=logical -c max_wal_senders=10 -c max_replication_slots=10
# then re-run migrations: export ASH_REPLICANT_TEST_URL=postgres://postgres@localhost:5599/postgres && mix ecto.migrate -r AshReplicant.TestRepo
```

Every test/gate command in this project must be prefixed with `export ASH_REPLICANT_TEST_URL=postgres://postgres@localhost:5599/postgres`.

## Status

ash_replicant **0.2.0 is published to Hex and pushed to GitHub** (done, irreversible — verified live). On top of that, a full **brainstorm → spec → plan** pipeline for **SCD2 (validity-windowed history) mirroring** completed this session: the spec and the 11-task implementation plan are written, machine-gated, and passed a fresh-context independent review (a real masked defect + should-fixes fixed). Nothing of SCD2 is built. Branch `main`, HEAD `7b034e3`, tree clean, in sync with `origin/main`. The reboot + account switch is safe: everything the next agent needs is on disk or machine-level (see Git + environment).

## Done (verified)

**1. Released ash_replicant 0.2.0** (the deliberate "un-defer" — `replicant` is now on Hex 0.1.0, so the path dep was swapped).
- Commit `7b034e3` "chore(release): cut 0.2.0 — swap replicant to Hex dep" — **4 files changed:** `mix.exs` (`@version` 0.1.0→0.2.0; `{:replicant, "~> 0.1.0"}` was a path dep; ships `NOTICE`), `mix.lock` (replicant → Hex 0.1.0), `CHANGELOG.md` (`[0.2.0]` section + the previously-undocumented `ValidateTenantSource` entry), `README.md` (real Hex install; hexdocs-safe absolute links).
- **Evidence:** `mix hex.info ash_replicant` → `0.2.0 (2026-07-09)`, `{:ash_replicant, "~> 0.2.0"}`; published tarball checksum `08be177…`. Gate battery green at `7b034e3`: nonce log `docs/superpowers/gate-logs/20260709-080009-ash_replicant_release_020_final-7b034e3e56.log` (compile-WAE, format, credo-strict, dialyzer 0/0, migration-drift, hex.audit, 87 tests/0 fail incl. integration).
- **History was rewritten** this session (all 39 commits' author/committer/tagger email → the GitHub noreply `175215383+palermo-git@users.noreply.github.com`, matching `replicant`) because GitHub blocked the push of the private Gmail. The user ran the `git filter-repo` (the harness blocks history-rewrite tools). Old SHAs (e.g. the pre-rewrite `df0a859`, and any SHA referenced in prior handoffs) no longer exist.
- **GitHub `baselabs/ash_replicant` created (public)**, `main` + annotated tag `v0.2.0` pushed. hexdocs at https://hexdocs.pm/ash_replicant/0.2.0.

**2. SCD2 spec** — `docs/superpowers/specs/2026-07-09-scd2-history-mirror-design.md` (approved). Design: per-resource opt-in `history_strategy :scd2` switching the apply strategy from current-state upsert/destroy (SCD1) to close-current + insert-version against a host-defined version table; effect-once / fail-closed multitenancy / value-free / Critical-Rule-1 all preserved. Verified against `replicant`'s ascending-`commit_lsn` delivery contract.

**3. SCD2 implementation plan** — `docs/superpowers/plans/2026-07-09-scd2-history-mirror.md` (11 tasks, ~1689 lines). Machine gate `plan-verify.py` = 0 errors / 0 warnings. Independent review reconciled (8 findings fixed; attestation line in the plan header). Tier map: 8 opus / 2 sonnet / 1 haiku.

**4. Project memory updated** — `~/.claude/projects/-Users-rp-Developer-Base-ash-replicant/memory/git-identity-and-release-undefer.md` (baselabs noreply-email convention; history-rewrites are user-run; HEX_API_KEY location; 0.2.0 un-defer). Indexed in that dir's `MEMORY.md`.

## Open / not done

1. **SCD2 implementation — ALL 11 tasks unexecuted (the main pending work).** Next step: `/exec-autopilot docs/superpowers/plans/2026-07-09-scd2-history-mirror.md`. The plan is self-contained (exact code, TDD, verified body-shapes). Its Task 11 adds the SCD2 CHANGELOG/README/AGENTS/CHARTER docs — so those tracked docs currently do NOT mention SCD2 (correct: it isn't built).
2. **Dep constraint deviation** — `mix.exs` uses `{:replicant, "~> 0.1.0"}` (pins replicant to 0.1.x), not the looser `~> 0.1` the original release task text suggested. Chosen for correctness (a tightly-coupled 0.x dep shouldn't auto-pull a breaking replicant 0.2.0). Already published this way; changing it is a 0.2.1. Not blocking.
3. **CHANGELOG `[Unreleased]` is empty** after the 0.2.0 cut — expected; SCD2's entry lands with its implementation (plan Task 11).
4. **No discussed-but-dropped scope** — the only work in play beyond the release was SCD2 (fully captured in the spec/plan). Nothing else was requested and left out.

## Git + environment

- **HEAD:** `7b034e3` (= `origin/main`, pushed, in sync). **Branch:** `main`. **Worktrees:** none (single working tree). **Tree:** clean — `git status --short` empty.
- **This session's new commit:** `7b034e3` only (the release). All other 38 commits are the rewritten history (same content as before the session, new SHAs).
- **Uncommitted files:** only **this handoff itself** (`docs/handoffs/2026-07-09-ash-replicant-scd2-handoff.md`) — a new untracked file in the tracked `docs/handoffs/` dir (prior handoffs are committed; commit it if you want it in the repo, it survives the reboot on disk regardless). No modified tracked files. The SCD2 **spec, plan, and gate-logs are gitignored** (`/docs/superpowers/` — local-only per AGENTS.md), so they don't show in `git status` and were never committed. **They live only on this machine's disk** — a reboot preserves them (filesystem); the account switch does not touch them (same repo, same OS user).
- **PG container:** `replicant_pg16`, `postgres:16`, port 5599, `RestartPolicy=no` → **will NOT auto-start after reboot** (see Worst open item for recovery).
- **Auth survives the account switch (all machine-level, not tied to the Claude account):** `gh` is authed as `palermo-git` in the macOS keyring; the Hex API key is in repo-root `./.env` (`HEX_API_KEY`, gitignored); the local `git config user.email` was set to the noreply this session (in `.git/config`, persists). No concurrent/parallel session is active on this tree.

## Cadence + guardrails for the next agent

- **Commit discipline:** explicit pathspecs only — NEVER `git add -A` / `git add .`. Verify branch is `main` before committing (solo project — commit directly to `main`, **no feature branches / worktrees**).
- **Git identity:** before any commit, confirm `git config user.email` = `175215383+palermo-git@users.noreply.github.com` (NOT the private Gmail) — GitHub's push protection rejects the Gmail, and fixing it needs a full history rewrite (which the harness cannot run — the user must). See memory `[[git-identity-and-release-undefer]]`.
- **Lifecycle artifacts are gitignored** (`/docs/superpowers/` specs/plans/reviews/gate-logs) — never commit them; they're intentionally local-only.
- **History-rewrite tools** (`git filter-branch`, `git filter-repo`) are **blocked by the harness** — if a rewrite is ever needed, hand the exact command to the user.
- **Binding rules:** read `AGENTS.md` Critical Rules 1–6 (route writes through Ash actions; fail-closed multitenancy; sensitive = encrypted/binary; value-free; tenant-blind layering; effect-once one-txn+watermark) before touching `lib/`.

## Referenced artifacts (by path — do not duplicate)

- Spec: `docs/superpowers/specs/2026-07-09-scd2-history-mirror-design.md`
- Plan: `docs/superpowers/plans/2026-07-09-scd2-history-mirror.md`
- Release gate evidence: `docs/superpowers/gate-logs/20260709-080009-ash_replicant_release_020_final-7b034e3e56.log`
- Binding contract: `AGENTS.md` · Charter: `docs/CHARTER.md`
- Project memory: `~/.claude/projects/-Users-rp-Developer-Base-ash-replicant/memory/` (index `MEMORY.md`; note `git-identity-and-release-undefer.md`, `ash-cloak-integration.md`, `ash3-notify-false-noop.md`, `spark-dialyzer-gotchas.md`)
- Sibling transport (read-only context): `../replicant` (Hex 0.1.0; `usage-rules.md:47` = ascending-commit_lsn delivery contract the SCD2 effect-once proof relies on)

## Suggested skills + next action

1. `docker start replicant_pg16` and confirm it's up (Worst open item).
2. Read the plan (`docs/superpowers/plans/2026-07-09-scd2-history-mirror.md`) and the spec in full; re-verify this handoff's git/gate claims against reality (`git log --oneline -1` should be `7b034e3`; a different HEAD or a dirty tree is a STOP condition — surface it).
3. **`/exec-autopilot docs/superpowers/plans/2026-07-09-scd2-history-mirror.md`** — execute the 11 tasks (tier map 8 opus / 2 sonnet / 1 haiku).
4. After execution: **`/review-autopilot docs/superpowers/specs/2026-07-09-scd2-history-mirror-design.md docs/superpowers/plans/2026-07-09-scd2-history-mirror.md --fix`** (spec/plan-aware closeout, 100-point scorecard).
