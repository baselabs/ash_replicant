# 4. Public authority and release history

Date: 2026-08-13

## Status

Accepted for the pre-1.0 history and the 1.0.0 hardening program.

## Context

AshReplicant's current behavior and release history were described across source,
README, Charter, changelog, tags, Hex, GitHub Releases, and historical lifecycle
artifacts. Some surfaces drifted after 0.3.0. In particular, Hex 0.3.3 exists but
no `v0.3.3` tag or GitHub Release exists; Hex 0.4.0 and tag `v0.4.0` exist without
a GitHub Release object. Historical handoffs also retained actionable instructions
after their work shipped.

The Hex 0.3.3 archive was fetched and compared to commit
`3b61d3a9ae553fb96ff26e9fcf581416af723843`. Every packaged source and document
matched. The missing tag is therefore a receipt gap, not uncertainty about the
release bytes.

## Decision

- Live code and immutable package/git evidence decide current behavior. The
  canonical implementation queue is `docs/ROADMAP.md`; the Charter explains the
  product boundary; ADRs record durable decisions.
- Historical lifecycle artifacts retain point-in-time testimony but must carry a
  historical/superseded banner when their instructions are no longer actionable.
- Pre-1.0 release history is reported exactly as it exists. The project does not
  create or move a retroactive 0.3.3 tag and does not claim missing GitHub Release
  objects exist.
- Hex 0.3.3 is attributed to immutable commit `3b61d3a`; tag-backed releases link
  to their real tags. GitHub Releases is documented as an incomplete historical
  mirror for 0.x, not silently treated as complete.
- The stable release uses the stricter E1 provenance contract: release commit,
  package checksum, tag, GitHub Release, Hex publication, and post-publish fetch
  must bind to one candidate. The incomplete 0.x history is not the 1.0 standard.

## Consequences

- Documentation may name a missing historical receipt, but may not fabricate it.
- A release/version claim must cite immutable evidence appropriate to the claim.
- Current public docs cannot use a historical handoff as implementation authority.
- Publication, tagging, and GitHub Release creation remain explicit release actions;
  this documentation decision does not perform them.

## Evidence

- `CHANGELOG.md` 0.3.3 provenance note and immutable commit link.
- `docs/ROADMAP.md` A4 and E1 acceptance contracts.
- Hex package metadata and the local package-to-commit byte comparison recorded in
  the A4 Forge design receipt.
- Local/remote tag and GitHub Release enumeration performed during A4.
