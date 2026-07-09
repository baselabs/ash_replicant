defmodule AshReplicant.Resource.Verifiers.ValidateHistory do
  @moduledoc """
  Compile-verifier for `replicant do history_strategy :scd2 ... end` (surfaced as a
  Spark diagnostic; build-blocking under `--warnings-as-errors`).

  When SCD2 is selected, verifies the DSL-checkable SHAPE of the host version table:
  a non-empty declared business key; declared integer `valid_from_lsn` / `valid_to_lsn`
  (`valid_to` nullable so a version can stay open); a SURROGATE primary key disjoint
  from the business key; the `upsert_identity` identity present with keys equal to
  `business_key ++ [valid_from_lsn]`; the `history_close_action` update action present;
  and any declared optional timestamp / `is_current` attributes typed correctly.

  Checks SHAPE, not behavior — the partial-unique-open index, the action bodies, and
  the `REPLICA IDENTITY FULL` precondition for non-PK business keys are host
  obligations covered by integration tests (cf. `ValidateSensitive` checking type
  shape, not ciphertext). Messages are value-free: schema structure only.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    strategy = Verifier.get_option(dsl_state, [:replicant], :history_strategy, :scd1)

    with :ok <- check_close_requires_scd2(dsl_state, strategy) do
      if strategy == :scd2, do: do_verify(dsl_state), else: :ok
    end
  end

  # `on_truncate :close` closes validity windows — an SCD2-only operation. The enum
  # accepts `:close` globally (a shared option), so this guard runs REGARDLESS of
  # strategy, BEFORE the SCD1 early-out: an SCD1 resource selecting `:close` would
  # otherwise reach `Apply.apply_to`'s SCD1 truncate `case` (only `:mirror`/`:halt`)
  # and raise `CaseClauseError` at RUNTIME. Fail closed at build instead.
  defp check_close_requires_scd2(dsl_state, strategy) do
    on_truncate = Verifier.get_option(dsl_state, [:replicant], :on_truncate, :halt)

    if on_truncate == :close and strategy != :scd2 do
      err(
        Verifier.get_persisted(dsl_state, :module),
        [:replicant, :on_truncate],
        "`on_truncate :close` requires `history_strategy :scd2` (closing validity windows is an SCD2 operation)."
      )
    else
      :ok
    end
  end

  defp do_verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    bk = Verifier.get_option(dsl_state, [:replicant], :history_business_key, [])

    from_lsn =
      Verifier.get_option(
        dsl_state,
        [:replicant],
        :history_valid_from_lsn_attribute,
        :valid_from_lsn
      )

    to_lsn =
      Verifier.get_option(dsl_state, [:replicant], :history_valid_to_lsn_attribute, :valid_to_lsn)

    from_ts =
      Verifier.get_option(dsl_state, [:replicant], :history_valid_from_timestamp_attribute)

    to_ts = Verifier.get_option(dsl_state, [:replicant], :history_valid_to_timestamp_attribute)
    current = Verifier.get_option(dsl_state, [:replicant], :history_current_attribute)
    identity_name = Verifier.get_option(dsl_state, [:replicant], :upsert_identity)

    close_action =
      Verifier.get_option(dsl_state, [:replicant], :history_close_action, :close_version)

    attrs = Map.new(Verifier.get_entities(dsl_state, [:attributes]), &{&1.name, &1})
    pk = for a <- Map.values(attrs), a.primary_key?, do: a.name
    identities = Verifier.get_entities(dsl_state, [:identities])
    actions = Verifier.get_entities(dsl_state, [:actions])

    with :ok <- check_business_key(module, bk, attrs, pk),
         :ok <- check_lsn(module, from_lsn, attrs, :from),
         :ok <- check_lsn(module, to_lsn, attrs, :to),
         :ok <- check_optional(module, from_ts, attrs, :datetime),
         :ok <- check_optional(module, to_ts, attrs, :datetime),
         :ok <- check_optional(module, current, attrs, :boolean),
         :ok <- check_identity(module, identity_name, bk, from_lsn, identities) do
      check_close(module, close_action, actions)
    end
  end

  defp err(module, path, message),
    do: {:error, DslError.exception(module: module, path: path, message: message)}

  defp check_business_key(module, [], _attrs, _pk),
    do:
      err(
        module,
        [:replicant, :history_business_key],
        "SCD2 requires a non-empty `history_business_key` (the source business key / natural key)."
      )

  defp check_business_key(module, bk, attrs, pk) do
    cond do
      missing = Enum.find(bk, &(not Map.has_key?(attrs, &1))) ->
        err(
          module,
          [:replicant, :history_business_key],
          "history_business_key #{inspect(missing)} is not a declared attribute."
        )

      MapSet.equal?(MapSet.new(bk), MapSet.new(pk)) ->
        err(
          module,
          [:replicant],
          "the primary key must be a surrogate key distinct from `history_business_key` " <>
            "#{inspect(bk)} — an SCD2 version table holds many rows per business key, so the " <>
            "business key cannot be the primary key."
        )

      true ->
        :ok
    end
  end

  defp check_lsn(module, name, attrs, which) do
    case Map.get(attrs, name) do
      nil ->
        err(
          module,
          [:replicant],
          "SCD2 requires a declared integer attribute #{inspect(name)} (the valid_#{which}_lsn window column)."
        )

      attr ->
        cond do
          Ash.Type.storage_type(attr.type, attr.constraints) != :integer ->
            err(
              module,
              [:replicant],
              "the SCD2 window column #{inspect(name)} must be integer-storage-typed (Postgres bigint)."
            )

          which == :to and attr.allow_nil? != true ->
            err(
              module,
              [:replicant],
              "the SCD2 close column #{inspect(name)} must be `allow_nil?: true` — an open version " <>
                "has no valid_to yet."
            )

          true ->
            :ok
        end
    end
  end

  defp check_optional(_module, nil, _attrs, _kind), do: :ok

  defp check_optional(module, name, attrs, kind) do
    case Map.get(attrs, name) do
      nil ->
        err(
          module,
          [:replicant],
          "the declared SCD2 attribute #{inspect(name)} is not present on the resource."
        )

      attr ->
        type_ok? =
          case kind do
            :datetime ->
              Ash.Type.storage_type(attr.type, attr.constraints) in [
                :naive_datetime,
                :utc_datetime,
                :utc_datetime_usec
              ]

            :boolean ->
              Ash.Type.storage_type(attr.type, attr.constraints) == :boolean
          end

        cond do
          not type_ok? ->
            err(
              module,
              [:replicant],
              "the SCD2 attribute #{inspect(name)} has the wrong type for a #{kind} window column."
            )

          # A ts window column can be nil (snapshots carry no source commit timestamp, and
          # the design stamps valid_from_ts = nil there) — it MUST be allow_nil?: true or a
          # snapshot/insert fails at runtime instead of failing closed at build.
          kind == :datetime and attr.allow_nil? != true ->
            err(
              module,
              [:replicant],
              "the SCD2 timestamp column #{inspect(name)} must be `allow_nil?: true` (a snapshot " <>
                "carries no source commit timestamp, so it opens with a nil valid_from_ts)."
            )

          true ->
            :ok
        end
    end
  end

  defp check_identity(module, identity_name, bk, from_lsn, identities) do
    want = MapSet.new(bk ++ [from_lsn])
    found = Enum.find(identities, &(&1.name == identity_name))

    cond do
      is_nil(identity_name) or is_nil(found) ->
        err(
          module,
          [:replicant, :upsert_identity],
          "SCD2 requires `upsert_identity` to name a declared identity with keys " <>
            "`history_business_key ++ [valid_from_lsn]`."
        )

      not MapSet.equal?(MapSet.new(found.keys), want) ->
        err(
          module,
          [:replicant, :upsert_identity],
          "the version identity #{inspect(identity_name)} must have keys " <>
            "`history_business_key ++ [valid_from_lsn]` (#{inspect(MapSet.to_list(want))})."
        )

      true ->
        :ok
    end
  end

  defp check_close(module, close_action, actions) do
    case Enum.find(actions, &(&1.name == close_action and &1.type == :update)) do
      nil ->
        err(
          module,
          [:replicant, :history_close_action],
          "SCD2 requires an `:update` action named #{inspect(close_action)} that closes a version " <>
            "(sets the valid_to window columns)."
        )

      _ ->
        :ok
    end
  end
end
