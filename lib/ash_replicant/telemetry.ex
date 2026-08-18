defmodule AshReplicant.Telemetry do
  @moduledoc """
  Value-free telemetry. Owns the metadata allowlist — the single enforcement
  point for "no row value in telemetry". An off-allowlist key raises rather than
  shipping a value downstream. Mirrors `replicant`/`ash_arcadic`.

  The allowlist gates metadata KEYS; D5 (U3) additionally TYPES every value:
  per-key expected shapes enforced in `validate!/1`, a closed measurement key
  set with non-negative finite numeric values enforced in `event/3`. A future
  call site passing a row value under an allowlisted key — or a value-bearing
  measurement — now fails at the enforcement point instead of shipping
  downstream. Violations name the KEY and expected type ONLY; a row value in
  KEY position renders as a count, never the key itself.
  """

  @typed_meta_keys ~w(commit_lsn resource table change_count txn_count tenant? duration reason error_class kind slot_name transactional)a

  @doc "The permitted metadata keys."
  @spec allowed_meta_keys() :: [atom()]
  def allowed_meta_keys, do: @typed_meta_keys

  @meta_types %{
    commit_lsn: "nil | non_neg_integer",
    resource: "nil | atom",
    table: "nil | binary",
    change_count: "nil | non_neg_integer",
    txn_count: "nil | non_neg_integer",
    tenant?: "boolean",
    duration: "non_neg_integer",
    reason: "nil | atom | {:invalid_destination_config, atom}",
    error_class: "nil | atom",
    kind: "nil | atom",
    slot_name: "nil | binary",
    transactional: "boolean"
  }

  @allowed_measurement_keys ~w(count change_count duration byte_size)a

  @doc """
  The closed measurement key set (`byte_size` carries the C1 message claims'
  content size — a count, never the content).
  """
  @spec allowed_measurement_keys() :: [atom()]
  def allowed_measurement_keys, do: @allowed_measurement_keys

  @doc """
  Every event name the library emits — the conformance gate attaches handlers
  for exactly this inventory, so a new emission without a conforming shape goes
  red where it fires.
  """
  @spec emitted_event_names() :: [[atom(), ...]]
  def emitted_event_names do
    [
      [:ash_replicant, :sink, :session_identity_accepted],
      [:ash_replicant, :sink, :applied],
      [:ash_replicant, :sink, :batch_applied],
      [:ash_replicant, :sink, :skipped],
      [:ash_replicant, :sink, :halted],
      [:ash_replicant, :checkpoint, :conflict],
      [:ash_replicant, :message, :applied],
      [:ash_replicant, :snapshot, :batch],
      [:ash_replicant, :snapshot, :complete],
      [:ash_replicant, :preflight, :failed]
    ]
  end

  # Hand-rolled span (NOT :telemetry.span/3): the library wrapper's
  # exception event emits the RAW exception to every handler — a value leak
  # (cross-vendor final4). Here a raising fun emits the STOP event with the
  # scrubbed structural reason only, then re-raises the original for the
  # caller (semantics preserved; the telemetry boundary stays value-free).
  @spec span(atom(), map(), (-> {term(), map()})) :: term()
  def span(op, start_meta, fun) when is_atom(op) and is_map(start_meta) and is_function(fun, 0) do
    start = System.monotonic_time()
    :telemetry.execute([:ash_replicant, op, :start], %{duration: 0}, validate!(start_meta))

    result =
      try do
        fun.()
      rescue
        e ->
          stopped = System.monotonic_time() - start

          :telemetry.execute(
            [:ash_replicant, op, :stop],
            %{duration: stopped},
            validate!(Map.put(start_meta, :error_class, class_of(e)))
          )

          reraise e, __STACKTRACE__
      catch
        kind, value ->
          stopped = System.monotonic_time() - start

          :telemetry.execute(
            [:ash_replicant, op, :stop],
            %{duration: stopped},
            validate!(Map.put(start_meta, :error_class, class_of(value)))
          )

          :erlang.raise(kind, value, __STACKTRACE__)
      end

    # A malformed fun result (anything but {term, map}) must not leak its
    # value through a BadMapError on the merge — the stop event falls back
    # to the start metadata and the VALUE itself is returned untouched
    # (cross-vendor final5).
    {value, stop_meta} =
      case result do
        {v, meta} when is_map(meta) -> {v, meta}
        v -> {v, %{}}
      end

    stopped = System.monotonic_time() - start

    :telemetry.execute(
      [:ash_replicant, op, :stop],
      %{duration: stopped},
      validate!(Map.merge(start_meta, stop_meta))
    )

    value
  end

  # The structural class only — and only from the CLOSED class set (a
  # thrown map can mint an atom into its :class key at data level; the
  # library emits Splode class atoms and :error only — cross-vendor final6).
  @closed_classes [
    :error,
    :invalid,
    :forbidden,
    :unknown,
    :not_found,
    :required,
    :runtime,
    :conflict,
    :framework
  ]

  defp class_of(%{class: class}) when class in @closed_classes, do: class
  defp class_of(_other), do: :error

  @spec event([atom(), ...], map(), map()) :: :ok
  def event(name, measurements, meta)
      when is_list(name) and is_map(measurements) and is_map(meta) do
    validate_measurements!(measurements)
    :telemetry.execute(name, measurements, validate!(meta))
  end

  @doc false
  @spec validate!(map()) :: map()
  def validate!(meta) when is_map(meta) do
    case Map.keys(meta) -- @typed_meta_keys do
      [] ->
        Enum.each(meta, &validate_meta_value!/1)
        meta

      bad ->
        # Count ONLY: a row value placed in KEY position must never render —
        # neither the key nor its value reaches the message.
        raise ArgumentError,
              "telemetry metadata has #{length(bad)} key(s) outside the value-free " <>
                "allowlist #{inspect(@typed_meta_keys)} (no row values in telemetry)"
    end
  end

  defp validate_meta_value!({key, value}) do
    expected = Map.fetch!(@meta_types, key)

    unless meta_value_ok?(expected, value) do
      raise ArgumentError,
            "telemetry metadata key #{inspect(key)} must be #{expected} " <>
              "(value-free: key + expected type only, never the value)"
    end
  end

  defp meta_value_ok?("nil | " <> _, nil), do: true
  defp meta_value_ok?("nil | non_neg_integer", v), do: is_integer(v) and v >= 0
  defp meta_value_ok?("nil | atom", v), do: is_atom(v)

  # The library's own runtime reason includes one STRUCTURAL tuple (the
  # onetime-store preflight halt) — shape-typed, never a value; atoms and nil
  # keep their ordinary acceptance under the same key.
  defp meta_value_ok?("nil | atom | {:invalid_destination_config, atom}", v)
       when is_nil(v) or is_atom(v),
       do: true

  defp meta_value_ok?(
         "nil | atom | {:invalid_destination_config, atom}",
         {:invalid_destination_config, tag}
       )
       when is_atom(tag),
       do: true

  defp meta_value_ok?("nil | binary", v), do: is_binary(v)
  defp meta_value_ok?("boolean", v), do: is_boolean(v)
  defp meta_value_ok?("non_neg_integer", v), do: is_integer(v) and v >= 0
  defp meta_value_ok?(_other, _v), do: false

  @doc false
  @spec validate_measurements!(map()) :: :ok
  def validate_measurements!(measurements) when is_map(measurements) do
    case Map.keys(measurements) -- @allowed_measurement_keys do
      [] ->
        Enum.each(measurements, &validate_measurement!/1)
        :ok

      bad ->
        raise ArgumentError,
              "telemetry measurements has #{length(bad)} key(s) outside the closed set " <>
                "#{inspect(@allowed_measurement_keys)} (byte_size reserved for C1)"
    end
  end

  defp validate_measurement!({key, value}) do
    unless finite_non_negative_number?(value) do
      raise ArgumentError,
            "telemetry measurement #{inspect(key)} must be a non-negative finite " <>
              "number (closed set #{inspect(@allowed_measurement_keys)})"
    end
  end

  # On the BEAM floats are always finite (arithmetic raises badarith instead
  # of producing NaN/inf — unconstructible, verified live), so the NaN clause
  # is defensive documentation for any future port, not a reachable rejection
  # here. No absorption check: `v + 1 != v` would reject every finite float
  # >= 2^53 (cross-vendor finding) — large finite floats are legitimate.
  defp finite_non_negative_number?(v) when is_number(v) and v >= 0 do
    # NaN is the only value for which `v == v` is false (IEEE 754); the
    # same-operand lint cannot see that.
    # credo:disable-for-next-line Credo.Check.Warning.OperationOnSameValues
    v == v
  end

  defp finite_non_negative_number?(_v), do: false
end
