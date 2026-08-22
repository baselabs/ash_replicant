defmodule AshReplicant.Doctor.Check do
  @moduledoc """
  One canonical diagnosis result.

  This struct IS the contract of `mix ash_replicant.preflight` and
  `mix ash_replicant.doctor`: `name` is the stable machine identifier, `reason`
  is drawn from a closed vocabulary, and both renderings are total functions of
  this struct — there is no second source of truth a human and a machine reader
  could disagree about.

  `detail` carries STRUCTURAL identifiers only (a qualified table, a column, a
  PostgreSQL type name, a catalog flag, a dependency name). It is populated from
  a closed allowlist of reasons in `AshReplicant.Doctor`; anything else is
  dropped to `nil`. Row values, connection options, publication names, source
  identity, slot names, and watermarks never appear here (Critical Rule 4).
  """

  @type status :: :pass | :warn | :fail | :skipped

  @type domain :: :runtime | :source | :slot | :checkpoint | :contract

  @type t :: %__MODULE__{
          name: atom(),
          domain: domain(),
          status: status(),
          reason: atom(),
          detail: String.t() | nil
        }

  @enforce_keys [:name, :domain, :status, :reason]
  defstruct [:name, :domain, :status, :reason, :detail]
end
