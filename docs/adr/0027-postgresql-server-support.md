# ADR-0027: PostgreSQL server support

**Status:** Accepted 2026-11-26. Supersedes the source support and qualification
matrix in [ADR-0002](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0002-supported-runtime-and-dependencies.md)
and [ADR-0026](https://github.com/baselabs/ash_replicant/blob/main/docs/adr/0026-decoder-options-passthrough-and-full-admission.md).

## Decision

Source servers follow the [PostgreSQL Global Development Group versioning policy](https://www.postgresql.org/support/versioning/),
as in [Replicant ADR-0010](https://github.com/baselabs/replicant/blob/1ba5808/docs/adr/0010-postgresql-server-support.md).
The supported source majors are PostgreSQL 15, 16, 17, 18, and 19, using
`pgoutput` or pglogical 2.4.8. AshPostgres destinations have a separate
supported range of PostgreSQL 16–18.

Retain pglogical because its row filters can call user-defined functions
and require every applicable set predicate to pass. Native publications
restrict row-filter expressions and combine predicates with OR. Replicant
preserves pglogical's filter intersection in both its stream and snapshots.
[PostgreSQL row filters](https://www.postgresql.org/docs/19/logical-replication-row-filter.html)
· [pglogical filter evaluation](https://github.com/2ndQuadrant/pglogical/blob/REL2_4_8/pglogical_output_plugin.c#L619-L672)

PostgreSQL sources below 15 and `decoder: :wal2json` are deprecated in 1.x.
They will be removed in 2.0 along with the wal2json-only options `tables:`,
`allow_keyless_tables:`, and `schema_check_interval:`. The 1.x admission floors
remain PostgreSQL 12 for pgoutput and 9.6 for pglogical and wal2json. Doctor
warns on PostgreSQL 20 and newer, and activation enforces the decoder floor.

## Qualification

The full compatibility suite retains its PostgreSQL 15, 16, and 17 upstream
lanes and the PostgreSQL 18 platform-engine lanes. Separate decoder lanes
exercise pgoutput and pglogical on sources 15–19 against the platform
destination. Each source image is pinned by digest and pglogical is pinned
by commit and built against headers matching that image. Each lane verifies
the live major and exercises preflight, CRUD, and stop/resume against the
real source and destination. The supported-major sources allow
`pglogical_output` in `output_plugin_libraries` for pglogical delivery.

The legacy 9.6 and 12 decoder-source lanes continue to exercise pglogical
and wal2json in 1.x. PostgreSQL 12 also exercises pgoutput delivery, and
9.6 exercises pgoutput's release-floor refusal.

## Migrating from wal2json

An existing slot is bound to its output plugin and the stored checkpoint
contract is bound to its decoder and source table set. Prepare a new slot
and the equivalent publication or replication set. Establish a verified
cutover with writes quiesced while the existing pipeline drains through
its durable checkpoint. Confirm the new slot and checkpoint origin agree
before resuming writes. A fresh snapshot can rebuild a state mirror, while
an append-log migration needs the retained change history through cutover.
