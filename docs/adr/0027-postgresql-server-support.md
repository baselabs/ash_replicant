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

**2.0 amendment (2026-11-27).** AshReplicant removes PostgreSQL sources
below 15 and `decoder: :wal2json` along with its options `tables:`,
`allow_keyless_tables:`, and `schema_check_interval:`. Activation and
doctor enforce the same floor before querying the source catalogs. Doctor
warns on PostgreSQL 20 and newer.

## Qualification

The full compatibility suite retains its PostgreSQL 15, 16, and 17 upstream
lanes and the PostgreSQL 18 platform-engine lanes. Separate decoder lanes
exercise pgoutput and pglogical on sources 15–19 against the platform
destination. Each source image is pinned by digest and pglogical is pinned
by commit and built against headers matching that image. Each lane verifies
the live major and exercises preflight, CRUD, and stop/resume against the
real source and destination. The supported-major sources allow
`pglogical_output` in `output_plugin_libraries` for pglogical delivery.

All 19 qualification jobs passed for the AshReplicant 1.7.0 candidate
`9e4776b83ebc44c2a6a2696cf5bba1a72c07fb09`, the first release carrying
this policy, including every decoder-source lane from 9.6 through 19 and
`qualified`.
[Qualification run 45914577614](https://github.com/baselabs/ash_replicant/actions/runs/45914577614).

## Migrating from wal2json

A logical slot is bound to its output plugin. AshReplicant also refuses
to resume a stored wal2json checkpoint contract. Complete the cutover before
upgrading. Create an equivalent publication or replication set and a new slot
on a supported source. With writes quiesced, drain the old pipeline and
verify the new slot's consistent point against the durable delivery boundary
before resuming writes. Use a new checkpoint binding for the new slot. Carry
forward a watermark only after verifying continuity on the same source.
A fresh snapshot can rebuild a state mirror. An append-log migration needs
retained change history through cutover.
