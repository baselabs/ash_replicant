defmodule AshReplicant.ValidateSnapshotProvenanceTest do
  @moduledoc """
  S01 compile-time tripwires for the snapshot provenance and retirement
  contract (ADR-0017).

  ADR-0017 requires: *"A compile-time guard goes red when either protected
  attribute becomes writable or acceptable through `accept :*` or an explicit
  action list."* Every named clause of the contract gets its own red gate here,
  because a verifier clause that no test can drive red is a clause that is not
  actually enforced.

  Spark surfaces a verifier's `{:error, DslError}` as a compiler DIAGNOSTIC via
  `IO.warn`, not a raise — see `AshReplicant.ValidateSensitiveTest` — so these
  use `Spark.Test`, and the same diagnostic is build-blocking under
  `mix compile --warnings-as-errors`.
  """

  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Scopes do
    @moduledoc false
    use Ash.Resource.Actions.Implementation
    @behaviour AshReplicant.DestinationParticipant

    @impl AshReplicant.DestinationParticipant
    def destination_participants(_opts, _context), do: {:ok, :no_database}

    @impl Ash.Resource.Actions.Implementation
    def run(_input, _opts, _context), do: {:ok, ["tenant_a"]}

    @doc false
    def resolve(record), do: Map.get(record, "org_schema")
  end

  describe "the conforming shape (green controls)" do
    test "a fully conforming SCD1 resource compiles clean" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GoodScd1 do
          use Ash.Resource,
            domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            snapshot_provenance(true)
          end

          attributes do
            uuid_primary_key :id
            attribute :note, :string, public?: true
            attribute :replica_fingerprint, :binary, public?: false, writable?: false
            attribute :replica_seen_attempt, :binary, public?: false, writable?: false
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]

            update :replicant_mark_seen do
              public? false
              accept []
              require_atomic? false
              change AshReplicant.Snapshot.MarkSeen
            end

            destroy :replicant_retire_unseen do
              public? false
            end
          end
        end
      end
    end

    test "a fully conforming SCD2 resource compiles clean (retirement is the version close)" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GoodScd2 do
          use Ash.Resource,
            domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            snapshot_provenance(true)
            history_strategy(:scd2)
            history_business_key([:business_id])
            upsert_identity(:business_version)
          end

          attributes do
            uuid_primary_key :id
            attribute :business_id, :string, public?: true
            attribute :valid_from_lsn, :integer, public?: true, allow_nil?: false
            attribute :valid_to_lsn, :integer, public?: true, allow_nil?: true
            attribute :replica_fingerprint, :binary, public?: false, writable?: false
            attribute :replica_seen_attempt, :binary, public?: false, writable?: false
          end

          identities do
            # ETS cannot check identities natively; the green control only needs
            # the identity to EXIST for the SCD2 upsert_identity rule.
            identity :business_version, [:business_id, :valid_from_lsn] do
              pre_check_with AshReplicant.ValidateSnapshotProvenanceTest.Domain
            end
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]

            update :close_version do
              accept [:valid_to_lsn]
            end

            update :replicant_mark_seen do
              public? false
              accept []
              require_atomic? false
              change AshReplicant.Snapshot.MarkSeen
            end

            update :replicant_retire_unseen do
              public? false
              accept [:valid_to_lsn]
            end
          end
        end
      end
    end

    test "UPGRADE PATH: a resource that never opts in compiles clean without the attributes" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.NoOptIn do
          use Ash.Resource,
            domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
          end

          attributes do
            uuid_primary_key :id
            attribute :note, :string, public?: true
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]
          end
        end
      end
    end
  end

  describe "the protected attributes must exist with the exact shape" do
    test "a missing protected attribute fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.MissingAttribute do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "replica_seen_attempt"
      assert err.message =~ "must declare"
    end

    test "TRIPWIRE: a WRITABLE protected attribute fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.WritableAttribute do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: true
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "writable?"
    end

    test "TRIPWIRE: a PUBLIC protected attribute fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.PublicAttribute do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: true, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "public?"
    end

    test "TRIPWIRE: a non-binary-storage protected attribute fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.StringAttribute do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :string, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "binary"
    end

    test "TRIPWIRE: a protected attribute marked sensitive fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.SensitiveAttribute do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id

              attribute :replica_fingerprint, :binary,
                public?: false,
                writable?: false,
                sensitive?: true

              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "sensitive"
    end

    test "TRIPWIRE: naming a protected attribute in the replicant `sensitive` list fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.ClassifiedProvenance do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              sensitive([:replica_fingerprint])
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "sensitive"
    end
  end

  describe "no action may accept a protected attribute (the ADR-named guard)" do
    test "TRIPWIRE: an EXPLICIT accept list naming a protected attribute fails closed" do
      # `accept :*` expands only to public AND writable attributes
      # (deps/ash/.../default_accept.ex:17), so `:*` already excludes these, and
      # Ash's own DefaultAccept independently rejects accepting a NON-writable
      # attribute. The shape Ash does NOT cover — probed against 3.31.3 — is a
      # `writable?: true, public?: false` attribute named in an explicit accept
      # list, which Ash admits happily. That is this clause's own case, so the
      # fixture uses exactly it and the assertion pins THIS package's message.
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :create, :accept]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.ExplicitAccept do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :note, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: true
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, update: :*]

              create :create do
                primary? true
                accept [:id, :note, :replica_fingerprint]
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "replica_fingerprint"
      assert err.message =~ "forge snapshot provenance"
    end

    test "TRIPWIRE: an ARGUMENT named for a protected attribute fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.ProvenanceArgument do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :tamper do
                accept []
                require_atomic? false
                argument :replica_seen_attempt, :binary
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "replica_seen_attempt"
      assert err.message =~ "argument"
    end
  end

  describe "only PRIVATE package actions may mark seen or retire unseen" do
    test "a missing mark action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_mark_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.NoMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "replicant_mark_seen"
    end

    test "TRIPWIRE: a PUBLIC mark action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_mark_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.PublicMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? true
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "private"
    end

    test "TRIPWIRE: another public action carrying MarkSeen fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :host_update, :changes]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.PublicAlternateMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*]

              update :host_update do
                public? true
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "host_update"
      assert err.message =~ "Only"
      assert err.message =~ "replicant_mark_seen"
    end

    test "TRIPWIRE: a global MarkSeen change fails closed even when the private action is valid" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:changes]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GlobalAndPrivateMarkChange do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            changes do
              change AshReplicant.Snapshot.MarkSeen, on: [:update]
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "global"
      assert err.message =~ "Only"
      assert err.message =~ "replicant_mark_seen"
    end

    test "TRIPWIRE: a mark action that does NOT carry the package change fails closed (vacuous mark)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_mark_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.VacuousMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "AshReplicant.Snapshot.MarkSeen"
    end

    test "TRIPWIRE: a GLOBAL change does not satisfy the mark action (it would stamp business updates too)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:changes]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GlobalMarkChange do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            changes do
              change AshReplicant.Snapshot.MarkSeen, on: [:update]
            end

            actions do
              defaults [:read, :destroy, create: :*]

              update :update do
                primary? true
                accept []
                require_atomic? false
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "AshReplicant.Snapshot.MarkSeen"
      assert err.message =~ "global"
    end

    test "TRIPWIRE: a mark action of the wrong TYPE fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_mark_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.CreateMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              create :replicant_mark_seen do
                public? false
                accept []
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ ":update"
    end

    test "a missing retire action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_retire_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.NoRetireAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end
            end
          end
        end

      assert err.message =~ "replicant_retire_unseen"
    end

    test "TRIPWIRE: a PUBLIC retire action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_retire_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.PublicRetireAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? true
              end
            end
          end
        end

      assert err.message =~ "private"
    end

    test "TRIPWIRE: an SCD1 retire action that is not a :destroy fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_retire_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.Scd1UpdateRetire do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
            end

            attributes do
              uuid_primary_key :id
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              update :replicant_retire_unseen do
                public? false
                accept []
                require_atomic? false
              end
            end
          end
        end

      assert err.message =~ ":destroy"
    end

    test "TRIPWIRE: an SCD2 retire action that is a :destroy fails closed (history is immutable)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_retire_action]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.Scd2DestroyRetire do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              history_strategy(:scd2)
              history_business_key([:business_id])
              upsert_identity(:business_version)
            end

            attributes do
              uuid_primary_key :id
              attribute :business_id, :string, public?: true
              attribute :valid_from_lsn, :integer, public?: true, allow_nil?: false
              attribute :valid_to_lsn, :integer, public?: true, allow_nil?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            identities do
              identity :business_version, [:business_id, :valid_from_lsn] do
                pre_check_with AshReplicant.ValidateSnapshotProvenanceTest.Domain
              end
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :close_version do
                accept [:valid_to_lsn]
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ ":update"
    end
  end

  describe "the provenance actions are tenant-scoped like every other sink action" do
    test "TRIPWIRE: a mark action declaring `multitenancy :bypass` fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :replicant_mark_seen]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.BypassMarkAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              tenant_attribute(:org_id)
            end

            multitenancy do
              strategy :attribute
              attribute :org_id
            end

            attributes do
              uuid_primary_key :id
              attribute :org_id, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                multitenancy :bypass
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "multitenancy"
    end

    test "TRIPWIRE: a retire action declaring `multitenancy :bypass_all` fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :replicant_retire_unseen]} do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.BypassRetireAction do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              tenant_attribute(:org_id)
            end

            multitenancy do
              strategy :attribute
              attribute :org_id
            end

            attributes do
              uuid_primary_key :id
              attribute :org_id, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
                multitenancy :bypass_all
              end
            end
          end
        end

      assert err.message =~ "multitenancy"
    end
  end

  describe "the CONTEXT-tenant retained-scope enumerator (S02, ADR-0017)" do
    test "a context-multitenant provenance resource with NO scope action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{
          path: [:replicant, :snapshot_tenant_scope_action]
        } do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.CtxNoScope do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              tenant_mfa({AshReplicant.ValidateSnapshotProvenanceTest.Scopes, :resolve, []})
            end

            attributes do
              uuid_primary_key :id
              attribute :note, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            multitenancy do
              strategy :context
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "enumerate"
    end

    test "a scope action that is not a generic array-returning action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{
          path: [:replicant, :snapshot_tenant_scope_action]
        } do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.CtxBadScope do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              tenant_mfa({AshReplicant.ValidateSnapshotProvenanceTest.Scopes, :resolve, []})
              snapshot_tenant_scope_action(:read)
            end

            attributes do
              uuid_primary_key :id
              attribute :note, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            multitenancy do
              strategy :context
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "generic"
    end

    test "a PUBLIC scope action fails closed" do
      err =
        assert_dsl_error %Spark.Error.DslError{
          path: [:replicant, :snapshot_tenant_scope_action]
        } do
          defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.CtxPublicScope do
            use Ash.Resource,
              domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              snapshot_provenance(true)
              tenant_mfa({AshReplicant.ValidateSnapshotProvenanceTest.Scopes, :resolve, []})
              snapshot_tenant_scope_action(:retained_scopes)
            end

            attributes do
              uuid_primary_key :id
              attribute :note, :string, public?: true
              attribute :replica_fingerprint, :binary, public?: false, writable?: false
              attribute :replica_seen_attempt, :binary, public?: false, writable?: false
            end

            multitenancy do
              strategy :context
            end

            actions do
              defaults [:read, :destroy, create: :*, update: :*]

              action :retained_scopes, {:array, :string} do
                run AshReplicant.ValidateSnapshotProvenanceTest.Scopes
              end

              update :replicant_mark_seen do
                public? false
                accept []
                require_atomic? false
                change AshReplicant.Snapshot.MarkSeen
              end

              destroy :replicant_retire_unseen do
                public? false
              end
            end
          end
        end

      assert err.message =~ "private"
    end

    test "a conforming context-multitenant resource compiles clean" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GoodCtx do
          use Ash.Resource,
            domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            snapshot_provenance(true)
            tenant_mfa({AshReplicant.ValidateSnapshotProvenanceTest.Scopes, :resolve, []})
            snapshot_tenant_scope_action(:retained_scopes)
          end

          attributes do
            uuid_primary_key :id
            attribute :note, :string, public?: true
            attribute :replica_fingerprint, :binary, public?: false, writable?: false
            attribute :replica_seen_attempt, :binary, public?: false, writable?: false
          end

          multitenancy do
            strategy :context
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]

            action :retained_scopes, {:array, :string} do
              public? false
              run AshReplicant.ValidateSnapshotProvenanceTest.Scopes
            end

            update :replicant_mark_seen do
              public? false
              accept []
              require_atomic? false
              change AshReplicant.Snapshot.MarkSeen
            end

            destroy :replicant_retire_unseen do
              public? false
            end
          end
        end
      end
    end

    test "an ATTRIBUTE-multitenant provenance resource needs no scope action (DISTINCT covers it)" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateSnapshotProvenanceTest.GoodAttrTenant do
          use Ash.Resource,
            domain: AshReplicant.ValidateSnapshotProvenanceTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            snapshot_provenance(true)
            tenant_attribute(:org_id)
          end

          attributes do
            uuid_primary_key :id
            attribute :org_id, :string, public?: true, allow_nil?: false
            attribute :note, :string, public?: true
            attribute :replica_fingerprint, :binary, public?: false, writable?: false
            attribute :replica_seen_attempt, :binary, public?: false, writable?: false
          end

          multitenancy do
            strategy :attribute
            attribute :org_id
          end

          actions do
            defaults [:read, :destroy, create: :*, update: :*]

            update :replicant_mark_seen do
              public? false
              accept []
              require_atomic? false
              change AshReplicant.Snapshot.MarkSeen
            end

            destroy :replicant_retire_unseen do
              public? false
            end
          end
        end
      end
    end
  end
end
