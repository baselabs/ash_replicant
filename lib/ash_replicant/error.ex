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

  @type t :: %__MODULE__{
          reason: reason() | nil,
          resource: module() | nil,
          op: atom() | nil,
          shape: String.t() | nil
        }

  def message(%{reason: reason, resource: resource, op: op, shape: shape}) do
    "ash_replicant error reason=#{reason} resource=#{inspect(resource)} op=#{inspect(op)}" <>
      if(shape, do: " shape=#{shape}", else: "")
  end

  @doc """
  Normalize any error into a value-free `%AshReplicant.Error{}`. Never inspects a
  message, changeset, or value — keeps only the struct-module name on `:shape`.
  """
  @spec scrub(term(), module() | nil, atom()) :: t()
  def scrub(%__MODULE__{} = already, _resource, _op), do: already

  def scrub(%{__struct__: mod}, resource, op) when is_atom(mod) do
    %__MODULE__{reason: :sink_failed, resource: resource, op: op, shape: inspect(mod)}
  end

  def scrub(_other, resource, op) do
    %__MODULE__{reason: :sink_failed, resource: resource, op: op}
  end
end
