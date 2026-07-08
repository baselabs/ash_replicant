# EXEC-GATING SPIKE (throwaway; record the outcome in the plan decision log #9).
#
# Question: does AshCloak's `before_action` encryption fire on an UPSERT
# (ON CONFLICT DO UPDATE), not only on INSERT, when the write routes through a
# single-row Ash action and `encrypted_<attr>` is in `upsert_fields`?
#
# This is proven LIVE on PG16 (localhost:5599) — a stub/mock would only prove the
# code produces the request, never that Postgres+AshCloak refresh the ciphertext.
# The inline resource + vault below are the minimal substrate for that proof.

defmodule AshReplicant.Spike.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshReplicant.Spike.Secret do
  @moduledoc false
  use Ash.Resource,
    domain: AshReplicant.Spike.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    table "ash_replicant_cloak_spike"
    repo AshReplicant.TestRepo
  end

  cloak do
    vault AshReplicant.Test.CloakVault
    attributes [:secret]
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      public? true
    end

    # AshCloak removes :secret and adds :encrypted_secret (:binary) + a :secret
    # calculation + a :secret create argument whose before_action sets the cipher.
    attribute :secret, :string do
      public? true
    end
  end

  identities do
    identity :id_pk, [:id]
  end

  actions do
    defaults [:read]

    create :upsert do
      upsert? true
      upsert_identity :id_pk
      # :secret is accepted so AshCloak rewrites it into a :secret argument +
      # before_action encrypt change (it is then removed from the accept list).
      accept [:id, :label, :secret]
    end
  end
end

defmodule AshReplicant.Integration.CloakUpsertSpikeTest do
  use AshReplicant.DataCase, async: false

  @moduletag :integration

  alias AshReplicant.Spike.Secret

  setup do
    start_supervised!(AshReplicant.Test.CloakVault)

    # Spike table created inside the per-test Sandbox transaction (rolled back after).
    TestRepo.query!("""
    CREATE TABLE IF NOT EXISTS ash_replicant_cloak_spike (
      id text NOT NULL PRIMARY KEY,
      label text,
      encrypted_secret bytea
    )
    """)

    :ok
  end

  test "AshCloak refreshes ciphertext on UPSERT (ON CONFLICT DO UPDATE), not only INSERT" do
    # INSERT branch: encrypt "v1".
    assert {:ok, _} =
             Ash.create(Secret, %{id: "row1", label: "a", secret: "v1"},
               action: :upsert,
               upsert?: true,
               upsert_identity: :id_pk,
               upsert_fields: [:label, :encrypted_secret],
               authorize?: false
             )

    c1 = raw_encrypted("row1")

    # UPDATE branch of the same PK: encrypt "v2"; :encrypted_secret is in upsert_fields.
    assert {:ok, _} =
             Ash.create(Secret, %{id: "row1", label: "b", secret: "v2"},
               action: :upsert,
               upsert?: true,
               upsert_identity: :id_pk,
               upsert_fields: [:label, :encrypted_secret],
               authorize?: false
             )

    c2 = raw_encrypted("row1")

    # EVIDENCE 1 — the stored ciphertext changed on the ON CONFLICT DO UPDATE branch.
    refute is_nil(c1)
    refute is_nil(c2)
    assert c2 != c1

    # EVIDENCE 2 — the decrypt calculation yields the new plaintext.
    decrypted = Ash.get!(Secret, "row1", load: [:secret], authorize?: false).secret
    assert decrypted == "v2"

    # SPIKE FINDING (record in plan decision log #9): confirmed — AshCloak's
    # before_action encryption fires on UPSERT. With :encrypted_secret in
    # upsert_fields the ON CONFLICT DO UPDATE refreshes the ciphertext (C2 != C1)
    # and it decrypts to "v2". The sink's sensitive-column path (upsert_fields must
    # reference :encrypted_<attr>, per resolver contract) is CORRECT — no
    # destroy-then-create fallback is required.
  end

  defp raw_encrypted(id) do
    %Postgrex.Result{rows: [[value]]} =
      TestRepo.query!(
        "SELECT encrypted_secret FROM ash_replicant_cloak_spike WHERE id = $1",
        [id]
      )

    value
  end
end
