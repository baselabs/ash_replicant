defmodule AshReplicant.ValidateSensitiveTest do
  use ExUnit.Case, async: true
  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  # Spark surfaces a verifier's `{:error, DslError}` as a compiler diagnostic:
  # it is caught in the `@after_verify` hook and re-emitted via `IO.warn`
  # (spark `dsl.ex` catch -> `Spark.Warning.warn`), NOT raised — so `assert_raise`
  # is unsuitable (see the `Spark.Test` moduledoc). `Spark.Test` registers the
  # test process as a collector and returns the DslError values as data. Under
  # `mix compile --warnings-as-errors` the same diagnostic is build-blocking.

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    # exec: established test-domain pattern (Tasks 2-4) — silences Ash
    # "domain does not accept this resource" verifier warnings for the
    # unregistered inline resources below.
    resources do
      allow_unregistered? true
    end
  end

  test "a plaintext :string sensitive column, not skipped, fails closed (tripwire)" do
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :sensitive]} do
        defmodule Elixir.AshReplicant.ValidateSensitiveTest.BadPan do
          use Ash.Resource,
            domain: AshReplicant.ValidateSensitiveTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("cards")
            sensitive([:pan])
          end

          attributes do
            uuid_primary_key :id
            attribute :pan, :string
          end
        end
      end

    assert err.message =~ "sensitive source column"
  end

  test "a skipped sensitive column compiles clean (green control)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateSensitiveTest.SkippedPan do
        use Ash.Resource,
          domain: AshReplicant.ValidateSensitiveTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("cards")
          sensitive([:pan])
          skip([:pan])
        end

        attributes do
          uuid_primary_key :id
          attribute :pan, :string
        end
      end
    end
  end

  test "a hand-rolled encrypted_<name> :string attr fails closed (encrypted_<name> is never a protection without AshCloak)" do
    # With case (c) removed, a hand-rolled encrypted_pan fails regardless of its
    # storage type — the shape is not a protection at all (no AshCloak encryptor
    # to confirm), not merely because it is :string rather than :binary.
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :sensitive]} do
        defmodule Elixir.AshReplicant.ValidateSensitiveTest.EncryptedPanString do
          use Ash.Resource,
            domain: AshReplicant.ValidateSensitiveTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("cards")
            sensitive([:pan])
          end

          attributes do
            uuid_primary_key :id
            attribute :encrypted_pan, :string
          end
        end
      end

    assert err.message =~ "sensitive source column"
  end

  test "a :binary-storage sensitive attribute compiles clean (clause b)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateSensitiveTest.BinaryPan do
        use Ash.Resource,
          domain: AshReplicant.ValidateSensitiveTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("cards")
          sensitive([:pan])
        end

        attributes do
          uuid_primary_key :id
          attribute :pan, :binary
        end
      end
    end
  end

  test "a hand-rolled encrypted_<name> :binary attr WITHOUT AshCloak fails closed (case c removed)" do
    # AshCloak is the single source of truth for encryption. A hand-rolled
    # encrypted_pan :binary attribute (no AshCloak, no :pan cloak attr) is NOT a
    # recognized protection: the resolver routes "pan" to the plaintext :pan
    # branch (it maps to encrypted_<name> only for real AshCloak cloak
    # attributes), so blessing this shape would leak plaintext. Fail closed.
    err =
      assert_dsl_error %Spark.Error.DslError{path: [:replicant, :sensitive]} do
        defmodule Elixir.AshReplicant.ValidateSensitiveTest.HandRolledEncryptedPan do
          use Ash.Resource,
            domain: AshReplicant.ValidateSensitiveTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("cards")
            sensitive([:pan])
          end

          attributes do
            uuid_primary_key :id
            attribute :encrypted_pan, :binary
          end
        end
      end

    assert err.message =~ "sensitive source column"
  end

  test "a sensitive column backed by an AshCloak-cloaked attribute compiles clean (clause a)" do
    refute_dsl_errors do
      defmodule Elixir.AshReplicant.ValidateSensitiveTest.CloakedPan do
        use Ash.Resource,
          domain: AshReplicant.ValidateSensitiveTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource, AshCloak]

        cloak do
          vault AshReplicant.Test.CloakVault
          attributes [:pan]
        end

        replicant do
          source_table("cards")
          sensitive([:pan])
        end

        attributes do
          uuid_primary_key :id
          attribute :pan, :string
        end
      end
    end
  end
end
