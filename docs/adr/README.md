# Architecture Decision Records

Product-shaping decisions for `ash_replicant`, one file per decision (Nygard format:
Status / Context / Decision / Consequences). Tracked (not gitignored) — a bare clone, CI,
or a future maintainer needs them; the deliberation stays in the local `.forge/specs/`
design notes, the DECISION lands here.

**Authoring rule:** ADRs are authored **on-touch**, by the slice that owns or changes the
surface — never bulk-authored from testimony. The charter (`docs/CHARTER.md`) still holds
the narrative "why"; an ADR is the tracked, per-decision record with code evidence.

## Records

| # | Decision | Charter ref |
|---|---|---|
| [0001](0001-fail-closed-multitenancy.md) | Multitenancy is fail-closed; a declared tenant source requires a multitenancy block | [D2] |

## On-touch gap list (not yet authored — author when a slice next touches the surface)

These product-shaping decisions are currently governed by CHARTER prose only. Each is
authored as an ADR by the next slice that touches its surface (do NOT bulk-author):

| Decision | Charter ref | Surface / code evidence |
|---|---|---|
| Effect-once via txn-granularity commit-LSN watermark | [D1] | `sink/impl.ex:285-296`, `checkpoint.ex` |
| Sensitive = AshCloak-encrypted / binary, type-shape verified | [D3] | `validate_sensitive.ex`, `resolver.ex` |
| Tenant-blind layering | [D4] | `resolver.ex`, `ash_replicant.ex` |
| Value-free boundary | [D5] | `error.ex`, `telemetry.ex` |
| SCD2 surrogate-PK disjoint from business key | CHARTER SCD2 | `validate_history.ex:114-123` |
| `REPLICA IDENTITY FULL` operational precondition | AGENTS Rule 2 | `resource.ex:51,109` (tenant + SCD2 business-key notes) |
