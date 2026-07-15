# Contributing to AshReplicant

Thank you for your interest in contributing to AshReplicant!

## Prerequisites

- **Elixir** 1.15+ and **Erlang/OTP** 26+
- `replicant` is a **Hex dependency** (`{:replicant, "~> 0.1.0"}` in `mix.exs`), pulled by
  `mix deps.get` — no sibling checkout is required to build or test. A local checkout at
  `../replicant` is only needed for cross-repo design/brainstorm work (see `CLAUDE.md`).
- **PostgreSQL** 14+ for integration tests (with `wal_level=logical`); the
  integration suite runs against a live Postgres with a logical replication slot
  and publication

## Getting Started

```bash
git clone https://github.com/baselabs/ash_replicant.git
cd ash_replicant
mix deps.get
mix test
```

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Ensure all checks pass before opening a PR:

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
mix dialyzer
# or all gates at once:
mix quality
```

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`.

## Ash conventions

- This is an Ash **sink adapter** — a `Spark.Dsl.Extension` implementing the
  `Replicant.Sink` behaviour. Learn from the sibling `ash_postgres` and the
  broader Ash extension ecosystem.
- Read `AGENTS.md` before touching multitenancy, sensitive-data, or action-execution
  code — its Critical Rules are binding.
- TDD: write the test first. Unit tests live in `test/`; integration tests (marked
  with `@moduletag :integration`) live in `test/integration/` and require a live
  Postgres. Integration tests run whenever `ASH_REPLICANT_TEST_URL` is set (it gates the
  suite); unit tests run without it. The URL supplies host/port/user, but the **database is
  always forced to a dedicated `ash_replicant_test`** (isolated from any sibling suite sharing
  the instance — see `config/test.exs`). One-time provision, then run:

  ```bash
  export ASH_REPLICANT_TEST_URL="postgres://postgres@localhost:5599/postgres"
  MIX_ENV=test mix ecto.create   # creates ash_replicant_test
  MIX_ENV=test mix ecto.migrate
  mix test                       # unit + integration (the env var enables integration)
  ```

## Critical rules (binding)

From `AGENTS.md`:

1. **Route writes through Ash actions, never raw Ecto.** The resource's mirror
   action fires AshCloak encryption, policies, and multitenancy validation.
2. **Multitenancy is fail-closed.** nil/blank tenant → error, never a base-tenant
   fallback.
3. **Sensitive = AshCloak-encrypted or binary or skip.** Verified by compile-time
   verifier.
4. **Value-free at boundaries.** No row values in errors, logs, or telemetry — ever,
   including halt paths.
5. **Tenant-blind layering.** Multitenancy lives here; `replicant` stays tenant-blind.
6. **Effect-once = one transaction + watermark dedup + atomic checkpoint.**

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
