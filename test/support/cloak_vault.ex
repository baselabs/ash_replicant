defmodule AshReplicant.Test.CloakVault do
  @moduledoc """
  Test-only Cloak vault with a fixed, deterministic AES-256-GCM key, for the
  AshCloak-upsert exec-gating spike.

  The key is derived from a constant so the spike is reproducible. NEVER use this
  key or this in-code-key pattern in production.
  """
  use Cloak.Vault, otp_app: :ash_replicant

  @impl GenServer
  def init(config) do
    key = :crypto.hash(:sha256, "ash_replicant-cloak-upsert-spike-fixed-key")

    ciphers = [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}
    ]

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end
end
