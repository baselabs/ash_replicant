defmodule AshReplicant.Error do
  @moduledoc """
  Value-free error for the sink boundary. Carries structure only — a reason atom,
  the resource module, the op, and the offending error's struct-module NAME —
  never a row value, changeset, or DB message. `scrub/3` normalizes any raised or
  returned error into this shape, so the fail-closed halt path leaks nothing
  (including pre-encryption sensitive plaintext).

  The value-free guarantee is enforced by `scrub/3` and by callers passing only a
  `reason`, a resource module, and an op atom to `exception/1`. Do NOT forward an
  upstream error's message, `vars`, or `bread_crumbs` into `exception/1` — those
  Splode fields are rendered by `inspect`/`message` and would leak.
  """
  use Splode.Error, fields: [:reason, :resource, :op, :shape], class: :invalid

  @type reason ::
          :sink_failed
          | :tenant_required
          | :schema_change_destructive
          | :truncate_halt
          | :duplicate_source
          | :config_invalid
          | :source_identity_mismatch
          | :source_identity_rebound
          | :source_timeline_changed
          | :source_behind_watermark
          | :publication_contract_incompatible
          | :checkpoint_unbound
          | :checkpoint_adopt_conflict
          | :checkpoint_adopt_invalid
          | :checkpoint_legacy_rows_present
          | {:invalid_destination_config, :onetime_store}

  @type t :: %__MODULE__{
          reason: reason() | nil,
          resource: module() | nil,
          op: atom() | nil,
          shape: String.t() | nil
        }

  def message(%{reason: reason, resource: resource, op: op, shape: shape}) do
    "ash_replicant error reason=#{inspect(reason)} resource=#{inspect(resource)} op=#{inspect(op)}" <>
      if(shape, do: " shape=#{shape}", else: "")
  end

  @doc """
  A caught `:throw`/`:exit` value normalized for the sink's catch clauses: a
  value that is ALREADY an `%AshReplicant.Error{}` cannot be trusted (the
  thrower may have built it with ANY field) — the reason survives only when
  it matches the closed typed reason shape (an atom, or the one structural
  `{:invalid_destination_config, atom}` tuple); everything else is dropped.
  """
  @spec scrub_caught(term(), module() | nil, atom()) :: t()
  def scrub_caught(value, resource, op), do: scrub(value, resource, op)

  @doc """
  Normalize any error into a value-free `%AshReplicant.Error{}`. Never inspects a
  message, changeset, or value — keeps only the struct-module name on `:shape`.
  An INCOMING `%AshReplicant.Error{}` (raised or thrown by host code inside
  the sink's call) is rebuilt from its reason when — and only when — the
  reason matches the closed typed shape; a forged struct's other fields
  (shape/resource/class) never render. Our OWN structural errors carry
  typed reasons throughout, so their reason survives; their config-shaped
  `shape` strings are traded away for the closed boundary.
  """
  @spec scrub(term(), module() | nil, atom()) :: t()
  def scrub(%__MODULE__{reason: reason}, resource, op) do
    %__MODULE__{reason: typed_reason(reason), resource: resource, op: op}
  end

  def scrub(%{__struct__: mod}, resource, op) when is_atom(mod) do
    %__MODULE__{reason: :sink_failed, resource: resource, op: op, shape: inspect(mod)}
  end

  def scrub(_other, resource, op) do
    %__MODULE__{reason: :sink_failed, resource: resource, op: op}
  end

  # The closed reason shape: an atom (every reason this library mints) or
  # the one structural tuple. Anything else a forged struct carries is
  # dropped — value-free by construction, not by trust.
  defp typed_reason(reason) when is_atom(reason), do: reason

  defp typed_reason({:invalid_destination_config, tag}) when is_atom(tag),
    do: {:invalid_destination_config, tag}

  defp typed_reason(_other), do: :sink_failed
end
