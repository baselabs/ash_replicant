defmodule AshReplicant.Upgrade.Checkpoint.Error do
  @moduledoc """
  A value-free structural refusal from the checkpoint upgrade boundary.

  The exception deliberately carries only a reason atom. Legacy slot names,
  source identities, watermarks, and connection facts are data-plane values and
  must never cross an error or report boundary.
  """

  @type reason ::
          :checkpoint_missing
          | :facts_invalid
          | :foreign_checkpoint
          | :interrupted_upgrade
          | :legacy_row_ambiguous
          | :legacy_row_unbound
          | :database_fault
          | :destination_mismatch
          | :pipelines_not_stopped
          | :rollback_ledger_invalid
          | :rollback_state_changed
          | :rollback_unavailable

  @type t :: %__MODULE__{reason: reason()}

  defexception [:reason]

  @impl Exception
  def message(%__MODULE__{reason: :checkpoint_missing}),
    do: "the legacy checkpoint table is missing; use the fresh-install path"

  def message(%__MODULE__{reason: :facts_invalid}),
    do: "the checkpoint upgrade facts are malformed; refusing to guess"

  def message(%__MODULE__{reason: :foreign_checkpoint}),
    do: "the checkpoint table has a foreign shape; no change was made"

  def message(%__MODULE__{reason: :interrupted_upgrade}),
    do: "the checkpoint table has an interrupted upgrade shape; no change was made"

  def message(%__MODULE__{reason: :legacy_row_ambiguous}),
    do: "a legacy checkpoint row has more than one declared owner; no change was made"

  def message(%__MODULE__{reason: :legacy_row_unbound}),
    do: "a legacy checkpoint row has no declared owner; no change was made"

  def message(%__MODULE__{reason: :database_fault}),
    do: "the checkpoint upgrade database operation failed; no data value is reported"

  def message(%__MODULE__{reason: :destination_mismatch}),
    do: "the connected destination database does not match the declared upgrade destination"

  def message(%__MODULE__{reason: :pipelines_not_stopped}),
    do: "stop every pipeline node and explicitly assert that state before changing checkpoints"

  def message(%__MODULE__{reason: :rollback_ledger_invalid}),
    do: "the checkpoint rollback ledger is malformed or fails its integrity check"

  def message(%__MODULE__{reason: :rollback_state_changed}),
    do: "the 1.0 checkpoint state changed after upgrade; rollback is refused"

  def message(%__MODULE__{reason: :rollback_unavailable}),
    do: "the checkpoint rollback ledger is absent; rollback is refused"
end

defmodule AshReplicant.Upgrade.Checkpoint.Report do
  @moduledoc "A value-free checkpoint upgrade classification report."

  @type state :: :legacy_ready | :already_upgraded | :upgraded | :rolled_back

  @type t :: %__MODULE__{
          state: state(),
          legacy_rows: non_neg_integer(),
          bound_rows: non_neg_integer(),
          dormant_bindings: non_neg_integer()
        }

  @enforce_keys [:state, :legacy_rows, :bound_rows, :dormant_bindings]
  defstruct @enforce_keys
end

defmodule AshReplicant.Upgrade.Checkpoint do
  @moduledoc """
  Classifies the durable checkpoint boundary for the `0.4.0 -> 1.0.0` upgrade.

  Database inspection and mutation are adapters around this module. The
  classifier accepts already-normalized facts, ties every populated legacy row
  to exactly one explicit binding, permits configured sinks that have never
  written a checkpoint, and returns only value-free counts.
  """

  alias AshReplicant.Sql
  alias AshReplicant.Upgrade.Checkpoint.{Error, Report}

  @checkpoint_table "ash_replicant_checkpoints"
  @rollback_table "ash_replicant_checkpoint_upgrade_0_4_0"
  @upgrade_version "0.4.0-to-1.0.0"
  @default_lock_timeout_ms 5_000

  @legacy_columns [
    ["slot_name", "text", true, nil],
    ["commit_lsn", "bigint", true, nil]
  ]

  @current_columns [
    ["slot_name", "text", true, nil],
    ["commit_lsn", "bigint", false, nil],
    ["source_system_id", "text", true, nil],
    ["source_database", "text", true, nil],
    ["source_timeline", "bigint", false, nil],
    ["publication_contract", "bytea", false, nil],
    ["publication_fingerprint", "bytea", false, nil],
    ["snapshot_progress", "bytea", false, nil],
    ["inserted_at", "timestamp without time zone", true, "(now() AT TIME ZONE 'utc'::text)"],
    ["updated_at", "timestamp without time zone", true, "(now() AT TIME ZONE 'utc'::text)"],
    ["snapshot_state", "bytea", false, nil],
    ["origin_floor", "bigint", false, nil]
  ]

  @legacy_indexes [
    ["ash_replicant_checkpoints_pkey", true, true, ["slot_name"], nil],
    ["ash_replicant_checkpoints_unique_slot_index", true, false, ["slot_name"], nil]
  ]

  @current_indexes [
    [
      "ash_replicant_checkpoints_pkey",
      true,
      true,
      ["source_system_id", "source_database", "slot_name"],
      nil
    ],
    [
      "ash_replicant_checkpoints_source_slot_index",
      true,
      false,
      ["source_system_id", "source_database", "slot_name"],
      nil
    ],
    ["ash_replicant_checkpoints_unique_slot_index", true, false, ["slot_name"], nil]
  ]

  @rollback_columns [
    ["upgrade_version", "text", true, nil],
    ["slot_name", "text", true, nil],
    ["commit_lsn", "bigint", true, nil],
    ["source_system_id", "text", true, nil],
    ["source_database", "text", true, nil],
    ["checksum", "bytea", true, nil]
  ]

  @type binding :: %{
          required(:slot_name) => String.t(),
          required(:source_system_id) => String.t(),
          required(:source_database) => String.t()
        }

  @type legacy_row :: %{
          required(:slot_name) => String.t(),
          required(:commit_lsn) => non_neg_integer()
        }

  @type facts :: %{
          required(:schema) => :legacy | :current | :interrupted | :foreign | :missing,
          required(:rows) => [legacy_row() | map()],
          required(:bindings) => [binding()]
        }

  @spec classify(facts()) :: {:ok, Report.t()} | {:error, Error.t()}
  def classify(%{schema: schema, rows: rows, bindings: bindings})
      when is_list(rows) and is_list(bindings) do
    with :ok <- validate_bindings(bindings),
         :ok <- validate_rows(schema, rows) do
      classify_shape(schema, rows, bindings)
    end
  end

  def classify(_facts), do: error(:facts_invalid)

  @doc "Read-only classification of the connected destination checkpoint table."
  @spec check(module(), keyword()) :: {:ok, Report.t()} | {:error, Error.t()}
  def check(repo, opts) when is_atom(repo) and is_list(opts) do
    with {:ok, config} <- config(opts),
         {:ok, facts} <- inspect_facts(repo, config) do
      classify(facts)
    end
  rescue
    _error -> error(:database_fault)
  catch
    _kind, _reason -> error(:database_fault)
  end

  def check(_repo, _opts), do: error(:facts_invalid)

  @doc "Atomically migrate an exact 0.4 checkpoint table to the 1.0 shape."
  @spec up(module(), keyword()) :: {:ok, Report.t()} | {:error, Error.t()}
  def up(repo, opts) when is_atom(repo) and is_list(opts) do
    with {:ok, config} <- config(opts),
         :ok <- require_stopped(config),
         :ok <- verify_destination(repo, config) do
      transaction(repo, fn -> upgrade_locked(repo, config) end)
    end
  rescue
    _error -> error(:database_fault)
  catch
    _kind, _reason -> error(:database_fault)
  end

  def up(_repo, _opts), do: error(:facts_invalid)

  defp upgrade_locked(repo, config) do
    lock_upgrade_boundary!(repo, config)

    case inspect_facts!(repo, config) |> classify() do
      {:ok, %Report{state: :already_upgraded} = report} ->
        report

      {:ok, %Report{state: :legacy_ready} = report} ->
        perform_upgrade(repo, config, report)

      {:error, error} ->
        repo.rollback(error)
    end
  end

  defp perform_upgrade(repo, config, %Report{} = report) do
    rows = legacy_rows!(repo, config)
    binding_by_slot = Map.new(config.bindings, &{&1.slot_name, &1})
    create_rollback_ledger!(repo, config, rows, binding_by_slot)
    upgrade_schema!(repo, config, rows, binding_by_slot)
    maybe_fail_after_ddl!(config)
    %Report{report | state: :upgraded}
  end

  @doc "Roll the checkpoint back only while no 1.0-only state has been written."
  @spec down(module(), keyword()) :: {:ok, Report.t()} | {:error, Error.t()}
  def down(repo, opts) when is_atom(repo) and is_list(opts) do
    with {:ok, config} <- config(opts),
         :ok <- require_stopped(config),
         :ok <- verify_destination(repo, config) do
      transaction(repo, fn -> rollback_locked(repo, config) end)
    end
  rescue
    _error -> error(:database_fault)
  catch
    _kind, _reason -> error(:database_fault)
  end

  def down(_repo, _opts), do: error(:facts_invalid)

  defp rollback_locked(repo, config) do
    lock_upgrade_boundary!(repo, config)

    with {:ok, %Report{state: :already_upgraded}} <-
           inspect_facts!(repo, config) |> classify(),
         {:ok, ledger} <- rollback_ledger(repo, config),
         :ok <- verify_rollback_state(repo, config, ledger) do
      rollback_schema!(repo, config)
      rollback_report(config, ledger)
    else
      {:error, error} -> repo.rollback(error)
      _other -> repo.rollback(Error.exception(reason: :rollback_state_changed))
    end
  end

  defp rollback_report(config, ledger) do
    %Report{
      state: :rolled_back,
      legacy_rows: length(ledger),
      bound_rows: length(ledger),
      dormant_bindings: max(length(config.bindings) - length(ledger), 0)
    }
  end

  defp classify_shape(:legacy, rows, bindings) do
    binding_counts = Enum.frequencies_by(bindings, & &1.slot_name)

    cond do
      Enum.any?(binding_counts, fn {_slot, count} -> count > 1 end) ->
        error(:legacy_row_ambiguous)

      Enum.any?(rows, &(Map.get(binding_counts, &1.slot_name, 0) == 0)) ->
        error(:legacy_row_unbound)

      true ->
        row_slots = MapSet.new(rows, & &1.slot_name)

        {:ok,
         %Report{
           state: :legacy_ready,
           legacy_rows: length(rows),
           bound_rows: length(rows),
           dormant_bindings: Enum.count(bindings, &(!MapSet.member?(row_slots, &1.slot_name)))
         }}
    end
  end

  defp classify_shape(:current, rows, bindings) do
    binding_by_slot = Map.new(bindings, &{&1.slot_name, &1})

    if Enum.all?(rows, &current_row_owned?(&1, binding_by_slot)) do
      {:ok,
       %Report{
         state: :already_upgraded,
         legacy_rows: 0,
         bound_rows: length(rows),
         dormant_bindings: max(length(bindings) - length(rows), 0)
       }}
    else
      error(:foreign_checkpoint)
    end
  end

  defp classify_shape(:interrupted, _rows, _bindings), do: error(:interrupted_upgrade)
  defp classify_shape(:foreign, _rows, _bindings), do: error(:foreign_checkpoint)
  defp classify_shape(:missing, _rows, _bindings), do: error(:checkpoint_missing)

  defp validate_bindings(bindings) do
    cond do
      not Enum.all?(bindings, &binding?/1) ->
        error(:facts_invalid)

      bindings |> Enum.map(& &1.slot_name) |> then(&(length(&1) != length(Enum.uniq(&1)))) ->
        error(:legacy_row_ambiguous)

      true ->
        :ok
    end
  end

  defp validate_rows(:legacy, rows) do
    if Enum.all?(rows, &legacy_row?/1) and unique_slots?(rows),
      do: :ok,
      else: error(:facts_invalid)
  end

  defp validate_rows(schema, rows)
       when schema in [:current, :interrupted, :foreign, :missing] do
    if Enum.all?(rows, &is_map/1), do: :ok, else: error(:facts_invalid)
  end

  defp validate_rows(_schema, _rows), do: error(:facts_invalid)

  defp binding?(%{
         slot_name: slot,
         source_system_id: system,
         source_database: database
       }),
       do: nonempty_binary?(slot) and nonempty_binary?(system) and nonempty_binary?(database)

  defp binding?(_binding), do: false

  defp legacy_row?(%{slot_name: slot, commit_lsn: lsn}),
    do: nonempty_binary?(slot) and is_integer(lsn) and lsn >= 0

  defp legacy_row?(_row), do: false

  defp unique_slots?(rows) do
    slots = Enum.map(rows, & &1.slot_name)
    length(slots) == length(Enum.uniq(slots))
  end

  defp current_row_owned?(row, binding_by_slot) do
    with %{slot_name: slot, source_system_id: system, source_database: database} <- row,
         %{source_system_id: ^system, source_database: ^database} <-
           Map.get(binding_by_slot, slot) do
      true
    else
      _other -> false
    end
  end

  defp config(opts) do
    bindings = Keyword.get(opts, :bindings)
    prefix = Keyword.get(opts, :prefix, "public")
    destination_database = Keyword.get(opts, :destination_database)
    lock_timeout_ms = Keyword.get(opts, :lock_timeout_ms, @default_lock_timeout_ms)

    if is_list(bindings) and Sql.valid_identifier?(prefix) and
         nonempty_binary?(destination_database) and is_integer(lock_timeout_ms) and
         lock_timeout_ms > 0 and lock_timeout_ms <= 60_000 do
      case validate_bindings(bindings) do
        :ok ->
          {:ok,
           %{
             bindings: bindings,
             prefix: prefix,
             destination_database: destination_database,
             pipelines_stopped?: Keyword.get(opts, :pipelines_stopped?, false),
             lock_timeout_ms: lock_timeout_ms,
             test_fail_after_ddl?: test_failure_requested?(opts),
             test_lock_observer: test_lock_observer(opts)
           }}

        {:error, _error} = error ->
          error
      end
    else
      error(:facts_invalid)
    end
  end

  defp require_stopped(%{pipelines_stopped?: true}), do: :ok
  defp require_stopped(_config), do: error(:pipelines_not_stopped)

  defp inspect_facts(repo, config) do
    case destination_matches?(repo, config) do
      true -> {:ok, inspect_facts!(repo, config)}
      false -> error(:destination_mismatch)
    end
  end

  defp inspect_facts!(repo, config) do
    unless destination_matches?(repo, config), do: raise("destination mismatch")

    case catalog(repo, config.prefix, @checkpoint_table) do
      :missing ->
        %{schema: :missing, rows: [], bindings: config.bindings}

      %{relkind: "r", columns: @legacy_columns, indexes: @legacy_indexes} ->
        %{schema: :legacy, rows: legacy_rows!(repo, config), bindings: config.bindings}

      %{relkind: "r", columns: columns, indexes: @current_indexes} ->
        current_facts(repo, config, columns)

      %{columns: columns} ->
        schema = if upgrade_column_present?(columns), do: :interrupted, else: :foreign
        %{schema: schema, rows: [], bindings: config.bindings}
    end
  end

  defp destination_matches?(repo, config) do
    case query!(repo, "SELECT current_database()", []).rows do
      [[database]] -> database == config.destination_database
      _other -> false
    end
  end

  defp current_facts(repo, config, columns) do
    if current_columns?(columns) do
      %{
        schema: :current,
        rows: current_identity_rows!(repo, config),
        bindings: config.bindings
      }
    else
      schema = if upgrade_column_present?(columns), do: :interrupted, else: :foreign
      %{schema: schema, rows: [], bindings: config.bindings}
    end
  end

  defp current_columns?(columns), do: Enum.sort(columns) == Enum.sort(@current_columns)

  defp verify_destination(repo, config) do
    if destination_matches?(repo, config), do: :ok, else: error(:destination_mismatch)
  end

  defp catalog(repo, prefix, table) do
    relation = qualified(prefix, table)

    case query!(repo, "SELECT to_regclass($1)", [relation]).rows do
      [[nil]] ->
        :missing

      [[_relation]] ->
        [[relkind]] =
          query!(repo, "SELECT c.relkind::text FROM pg_class c WHERE c.oid = to_regclass($1)", [
            relation
          ]).rows

        columns =
          query!(
            repo,
            """
            SELECT a.attname::text,
                   format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = to_regclass($1)
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            [relation]
          ).rows

        indexes =
          query!(
            repo,
            """
            SELECT idx.relname::text,
                   i.indisunique,
                   i.indisprimary,
                   ARRAY(
                     SELECT a.attname::text
                     FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
                     LEFT JOIN pg_attribute a
                       ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                     ORDER BY k.ord
                   ),
                   pg_get_expr(i.indpred, i.indrelid)
            FROM pg_index i
            JOIN pg_class idx ON idx.oid = i.indexrelid
            WHERE i.indrelid = to_regclass($1)
            ORDER BY idx.relname
            """,
            [relation]
          ).rows

        checks =
          query!(
            repo,
            """
            SELECT con.conname::text, pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            WHERE con.conrelid = to_regclass($1)
              AND con.contype = 'c'
            ORDER BY con.conname
            """,
            [relation]
          ).rows

        %{relkind: relkind, columns: columns, indexes: indexes, checks: checks}
    end
  end

  defp legacy_rows!(repo, config) do
    query!(
      repo,
      "SELECT slot_name, commit_lsn FROM #{qualified(config.prefix, @checkpoint_table)} ORDER BY slot_name",
      []
    ).rows
    |> Enum.map(fn [slot_name, commit_lsn] ->
      %{slot_name: slot_name, commit_lsn: commit_lsn}
    end)
  end

  defp current_identity_rows!(repo, config) do
    query!(
      repo,
      "SELECT slot_name, source_system_id, source_database FROM #{qualified(config.prefix, @checkpoint_table)} ORDER BY slot_name",
      []
    ).rows
    |> Enum.map(fn [slot_name, source_system_id, source_database] ->
      %{
        slot_name: slot_name,
        source_system_id: source_system_id,
        source_database: source_database
      }
    end)
  end

  defp upgrade_column_present?(columns) do
    names = MapSet.new(columns, &hd/1)

    Enum.any?(
      ~w(source_system_id source_database source_timeline publication_contract publication_fingerprint snapshot_progress snapshot_state origin_floor inserted_at updated_at),
      &MapSet.member?(names, &1)
    )
  end

  defp transaction(repo, operation) do
    case repo.transaction(operation) do
      {:ok, %Report{} = report} -> {:ok, report}
      {:error, %Error{} = error} -> {:error, error}
      _other -> error(:database_fault)
    end
  end

  defp lock_upgrade_boundary!(repo, config) do
    query!(repo, "SELECT set_config('lock_timeout', $1, true)", [
      "#{config.lock_timeout_ms}ms"
    ])

    query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtextextended(current_database() || ':' || $1 || ':' || $2, 0))",
      [config.prefix, @checkpoint_table]
    )

    case catalog(repo, config.prefix, @checkpoint_table) do
      :missing ->
        repo.rollback(Error.exception(reason: :checkpoint_missing))

      _present ->
        query!(
          repo,
          "LOCK TABLE #{qualified(config.prefix, @checkpoint_table)} IN ACCESS EXCLUSIVE MODE"
        )

        maybe_pause_after_lock!(config)
    end
  end

  defp create_rollback_ledger!(repo, config, rows, binding_by_slot) do
    ledger = qualified(config.prefix, @rollback_table)

    query!(repo, """
    CREATE TABLE #{ledger} (
      upgrade_version text NOT NULL,
      slot_name text PRIMARY KEY NOT NULL,
      commit_lsn bigint NOT NULL,
      source_system_id text NOT NULL,
      source_database text NOT NULL,
      checksum bytea NOT NULL,
      CONSTRAINT ash_replicant_checkpoint_upgrade_version_check
        CHECK (upgrade_version = '#{@upgrade_version}')
    )
    """)

    Enum.each(rows, fn row ->
      binding = Map.fetch!(binding_by_slot, row.slot_name)

      query!(
        repo,
        """
        INSERT INTO #{ledger}
          (upgrade_version, slot_name, commit_lsn, source_system_id, source_database, checksum)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [
          @upgrade_version,
          row.slot_name,
          row.commit_lsn,
          binding.source_system_id,
          binding.source_database,
          checksum(row.slot_name, row.commit_lsn, binding)
        ]
      )
    end)
  end

  defp upgrade_schema!(repo, config, rows, binding_by_slot) do
    checkpoint = qualified(config.prefix, @checkpoint_table)

    query!(repo, "ALTER TABLE #{checkpoint} DROP CONSTRAINT ash_replicant_checkpoints_pkey")

    query!(repo, """
    ALTER TABLE #{checkpoint}
      ALTER COLUMN commit_lsn DROP NOT NULL,
      ADD COLUMN source_system_id text,
      ADD COLUMN source_database text,
      ADD COLUMN source_timeline bigint,
      ADD COLUMN publication_contract bytea,
      ADD COLUMN publication_fingerprint bytea,
      ADD COLUMN snapshot_progress bytea,
      ADD COLUMN inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      ADD COLUMN updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      ADD COLUMN snapshot_state bytea,
      ADD COLUMN origin_floor bigint
    """)

    Enum.each(rows, fn row ->
      binding = Map.fetch!(binding_by_slot, row.slot_name)

      query!(
        repo,
        """
        UPDATE #{checkpoint}
        SET source_system_id = $1, source_database = $2
        WHERE slot_name = $3
        """,
        [binding.source_system_id, binding.source_database, row.slot_name]
      )
    end)

    query!(repo, """
    ALTER TABLE #{checkpoint}
      ALTER COLUMN source_system_id SET NOT NULL,
      ALTER COLUMN source_database SET NOT NULL,
      ADD PRIMARY KEY (source_system_id, source_database, slot_name)
    """)

    query!(repo, """
    CREATE UNIQUE INDEX ash_replicant_checkpoints_source_slot_index
    ON #{checkpoint} (source_system_id, source_database, slot_name)
    """)
  end

  defp rollback_ledger(repo, config) do
    case catalog(repo, config.prefix, @rollback_table) do
      :missing ->
        error(:rollback_unavailable)

      %{relkind: "r", columns: @rollback_columns, indexes: indexes, checks: checks}
      when indexes == [
             [
               "ash_replicant_checkpoint_upgrade_0_4_0_pkey",
               true,
               true,
               ["slot_name"],
               nil
             ]
           ] and
             checks == [
               [
                 "ash_replicant_checkpoint_upgrade_version_check",
                 "CHECK (upgrade_version = '0.4.0-to-1.0.0'::text)"
               ]
             ] ->
        rows =
          query!(repo, """
          SELECT upgrade_version, slot_name, commit_lsn,
                 source_system_id, source_database, checksum
          FROM #{qualified(config.prefix, @rollback_table)}
          ORDER BY slot_name
          """).rows

        if Enum.all?(rows, &valid_ledger_row?/1),
          do: {:ok, rows},
          else: error(:rollback_ledger_invalid)

      _other ->
        error(:rollback_ledger_invalid)
    end
  end

  defp valid_ledger_row?([
         @upgrade_version,
         slot_name,
         commit_lsn,
         source_system_id,
         source_database,
         actual_checksum
       ]) do
    binding = %{source_system_id: source_system_id, source_database: source_database}
    actual_checksum == checksum(slot_name, commit_lsn, binding)
  end

  defp valid_ledger_row?(_row), do: false

  defp verify_rollback_state(repo, config, ledger) do
    current =
      query!(repo, """
      SELECT slot_name, commit_lsn, source_system_id, source_database,
             source_timeline, publication_contract, publication_fingerprint,
             snapshot_progress, snapshot_state, origin_floor
      FROM #{qualified(config.prefix, @checkpoint_table)}
      ORDER BY slot_name
      """).rows

    expected =
      Enum.map(ledger, fn [
                            @upgrade_version,
                            slot,
                            commit_lsn,
                            source_system_id,
                            source_database,
                            _checksum
                          ] ->
        [slot, commit_lsn, source_system_id, source_database, nil, nil, nil, nil, nil, nil]
      end)

    if current == expected, do: :ok, else: error(:rollback_state_changed)
  end

  defp rollback_schema!(repo, config) do
    checkpoint = qualified(config.prefix, @checkpoint_table)

    query!(repo, "ALTER TABLE #{checkpoint} DROP CONSTRAINT ash_replicant_checkpoints_pkey")

    query!(
      repo,
      "DROP INDEX #{qualified(config.prefix, "ash_replicant_checkpoints_source_slot_index")}"
    )

    query!(repo, """
    ALTER TABLE #{checkpoint}
      DROP COLUMN origin_floor,
      DROP COLUMN snapshot_state,
      DROP COLUMN updated_at,
      DROP COLUMN inserted_at,
      DROP COLUMN snapshot_progress,
      DROP COLUMN publication_fingerprint,
      DROP COLUMN publication_contract,
      DROP COLUMN source_timeline,
      DROP COLUMN source_database,
      DROP COLUMN source_system_id,
      ALTER COLUMN commit_lsn SET NOT NULL,
      ADD PRIMARY KEY (slot_name)
    """)

    query!(repo, "DROP TABLE #{qualified(config.prefix, @rollback_table)}")
  end

  defp checksum(slot_name, commit_lsn, binding) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        @upgrade_version,
        slot_name,
        commit_lsn,
        binding.source_system_id,
        binding.source_database
      })
    )
  end

  defp query!(repo, sql, params \\ []), do: repo.query!(sql, params, log: false)

  defp qualified(prefix, table),
    do: Sql.quote_identifier(prefix) <> "." <> Sql.quote_identifier(table)

  if Mix.env() == :test do
    defp test_failure_requested?(opts),
      do: Keyword.get(opts, :test_fail_after_ddl?, false) == true

    defp test_lock_observer(opts) do
      case Keyword.get(opts, :test_lock_observer) do
        pid when is_pid(pid) -> pid
        _other -> nil
      end
    end

    defp maybe_fail_after_ddl!(%{test_fail_after_ddl?: true}), do: raise("test upgrade fault")
    defp maybe_fail_after_ddl!(_config), do: :ok

    defp maybe_pause_after_lock!(%{test_lock_observer: observer}) when is_pid(observer) do
      send(observer, {:ash_replicant_upgrade_locked, self()})

      receive do
        :continue_ash_replicant_upgrade -> :ok
      after
        5_000 -> raise "test upgrade lock observer timed out"
      end
    end

    defp maybe_pause_after_lock!(_config), do: :ok
  else
    defp test_failure_requested?(_opts), do: false
    defp test_lock_observer(_opts), do: nil
    defp maybe_fail_after_ddl!(_config), do: :ok
    defp maybe_pause_after_lock!(_config), do: :ok
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp error(reason), do: {:error, Error.exception(reason: reason)}
end
