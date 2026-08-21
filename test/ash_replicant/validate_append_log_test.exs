defmodule AshReplicant.ValidateAppendLogTest do
  @moduledoc """
  Compile-time tripwires for the immutable append-log target contract
  (ADR-0018).

  ADR-0018 §2/§3 make the append target a HOST-owned resource: the package
  never generates the table, so every structural obligation delivery relies on
  — the immutable create action, the structural attributes, the exact
  five-column append identity, the refusal to reuse state-mirror machinery —
  has to be a build-time gate. A clause no test can drive red is a clause that
  is not enforced.

  Every red gate below is the SAME conforming resource with exactly ONE clause
  mutated. `append_resource/2` is a MACRO so the `defmodule` expands inline and
  Spark's verification pass actually runs — building the same AST and handing
  it to `Code.eval_quoted` skips `@after_verify` entirely and every gate reads
  green. A red that needed a differently-shaped resource would not prove the
  clause it names.

  Spark surfaces a verifier's `{:error, DslError}` as a compiler DIAGNOSTIC via
  `IO.warn`, not a raise, so these use `Spark.Test`; the same diagnostic is
  build-blocking under `mix compile --warnings-as-errors`.
  """

  use ExUnit.Case, async: true

  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule ManualAppend do
    @behaviour Ash.Resource.ManualCreate

    @impl true
    def create(_changeset, _opts, _context), do: {:error, :manual_append_forbidden}
  end

  @structural_accept [
    :source_system_id,
    :source_database,
    :slot_name,
    :commit_lsn,
    :ordinal,
    :operation,
    :origin,
    :snapshot_attempt
  ]

  defmacrop append_resource(name, overrides \\ []) do
    replicant_extra = Keyword.get(overrides, :replicant_extra, [])
    attributes_extra = Keyword.get(overrides, :attributes_extra, [])
    global_changes = Keyword.get(overrides, :global_changes, [])

    global_change_blocks =
      case global_changes do
        [] ->
          []

        changes ->
          [
            quote do
              changes do
                (unquote_splicing(changes))
              end
            end
          ]
      end

    identity_keys =
      Keyword.get(overrides, :identity_keys, [
        :source_system_id,
        :source_database,
        :slot_name,
        :commit_lsn,
        :ordinal
      ])

    accept = Keyword.get(overrides, :accept, @structural_accept ++ [:id, :note])

    actions =
      Keyword.get(overrides, :actions, [
        quote(do: defaults([:read])),
        quote do
          create :append do
            accept unquote(accept)
          end
        end
      ])

    quote do
      defmodule unquote(name) do
        use Ash.Resource,
          domain: AshReplicant.ValidateAppendLogTest.Domain,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshReplicant.Resource]

        replicant do
          source_table("orders")
          append_log(true)
          unquote_splicing(replicant_extra)
        end

        attributes do
          uuid_primary_key :event_id
          attribute :source_system_id, :string, allow_nil?: false, public?: true
          attribute :source_database, :string, allow_nil?: false, public?: true
          attribute :slot_name, :string, allow_nil?: false, public?: true
          attribute :commit_lsn, :integer, allow_nil?: false, public?: true
          attribute :ordinal, :integer, allow_nil?: false, public?: true
          attribute :operation, :string, allow_nil?: false, public?: true
          attribute :origin, :string, allow_nil?: false, public?: true
          attribute :snapshot_attempt, :binary, public?: true
          attribute :id, :string, public?: true
          attribute :note, :string, public?: true
          unquote_splicing(attributes_extra)
        end

        identities do
          identity :append_identity, unquote(identity_keys) do
            pre_check_with AshReplicant.ValidateAppendLogTest.Domain
          end
        end

        unquote_splicing(global_change_blocks)

        actions do
          (unquote_splicing(actions))
        end
      end
    end
  end

  describe "the conforming shape (green controls)" do
    test "a fully conforming append target compiles clean" do
      refute_dsl_errors do
        append_resource(Elixir.AshReplicant.ValidateAppendLogTest.GoodAppend)
      end
    end

    test "an append target may append a structural truncate event" do
      refute_dsl_errors do
        append_resource(Elixir.AshReplicant.ValidateAppendLogTest.GoodTruncateAppend,
          replicant_extra: [on_truncate(:append)]
        )
      end
    end

    test "an ordinary state-mirror resource is untouched by the append gates" do
      refute_dsl_errors do
        defmodule Elixir.AshReplicant.ValidateAppendLogTest.PlainMirror do
          use Ash.Resource,
            domain: AshReplicant.ValidateAppendLogTest.Domain,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshReplicant.Resource]

          replicant do
            source_table("orders")
            on_truncate(:mirror)
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

  describe "the append action must exist and be an immutable create" do
    test "a missing append action is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_action]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.NoAppendAction,
            actions: [defaults([:read])]
          )
        end

      assert error.message =~ "must declare the append action :append"
    end

    test "an append action that is not a create is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_action]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendIsUpdate,
            actions: [defaults([:read]), update(:append)]
          )
        end

      assert error.message =~ "must be a `:create` action"
    end

    test "an append action declaring its own upsert is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :append, :upsert?]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendUpserts,
            actions: [
              defaults([:read]),
              create :append do
                upsert? true
                upsert_identity :append_identity

                accept [
                  :source_system_id,
                  :source_database,
                  :slot_name,
                  :commit_lsn,
                  :ordinal,
                  :operation,
                  :origin,
                  :snapshot_attempt,
                  :id,
                  :note
                ]
              end
            ]
          )
        end

      assert error.message =~ "must not declare its own upsert"
    end

    test "a manual append action is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :append, :manual]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendIsManual,
            actions: [
              defaults([:read]),
              create :append do
                accept [
                  :source_system_id,
                  :source_database,
                  :slot_name,
                  :commit_lsn,
                  :ordinal,
                  :operation,
                  :origin,
                  :snapshot_attempt,
                  :id,
                  :note
                ]

                manual AshReplicant.ValidateAppendLogTest.ManualAppend
              end
            ]
          )
        end

      assert error.message =~ "must not be manual"
    end

    test "an append action that does not accept a structural attribute is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :append, :accept]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendMissingAccept,
            accept: [
              :source_system_id,
              :source_database,
              :slot_name,
              :commit_lsn,
              :operation,
              :origin,
              :snapshot_attempt,
              :id,
              :note
            ]
          )
        end

      assert error.message =~ "does not accept [:ordinal]"
    end

    test "an append action change that can rewrite the immutable identity is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:actions, :append, :changes]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendRewritesOrdinal,
            actions: [
              defaults([:read]),
              create :append do
                accept [
                  :source_system_id,
                  :source_database,
                  :slot_name,
                  :commit_lsn,
                  :ordinal,
                  :operation,
                  :origin,
                  :snapshot_attempt,
                  :id,
                  :note
                ]

                change set_attribute(:ordinal, 0)
              end
            ]
          )
        end

      assert error.message =~ "must not declare mutating action changes"
    end

    test "a global create change that can rewrite append identity is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:changes]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.GlobalRewritesOrdinal,
            global_changes: [change(set_attribute(:ordinal, 0), on: [:create])]
          )
        end

      assert error.message =~ "global `changes` block"
      assert error.message =~ "rewrite an append identity axis"
    end
  end

  describe "the structural attributes" do
    test "a missing structural attribute is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_origin_attribute]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.NoOriginAttribute,
            replicant_extra: [append_origin_attribute(:absent_origin)]
          )
        end

      assert error.message =~ "must declare the origin attribute :absent_origin"
    end

    test "a structural attribute of the wrong storage is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{
          path: [:replicant, :append_commit_lsn_attribute]
        } do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.WrongLsnType,
            replicant_extra: [append_commit_lsn_attribute(:note)]
          )
        end

      assert error.message =~ "must store as :integer"
    end

    test "a structural attribute classified sensitive is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_ordinal_attribute]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.SensitiveStructural,
            replicant_extra: [sensitive([:ordinal])]
          )
        end

      assert error.message =~ "must not be listed in the `replicant` `sensitive` option"
    end

    test "a structural attribute marked sensitive? on the attribute is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_origin_attribute]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.SensitiveFlagStructural,
            replicant_extra: [append_origin_attribute(:secret_origin)],
            attributes_extra: [
              attribute(:secret_origin, :string,
                allow_nil?: false,
                public?: true,
                sensitive?: true
              )
            ],
            accept: [
              :source_system_id,
              :source_database,
              :slot_name,
              :commit_lsn,
              :ordinal,
              :operation,
              :secret_origin,
              :snapshot_attempt,
              :id,
              :note
            ]
          )
        end

      assert error.message =~ "must not be `sensitive?: true`"
    end

    test "a nullable append identity axis is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{
          path: [:replicant, :append_commit_lsn_attribute]
        } do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.NullableIdentityAxis,
            replicant_extra: [append_commit_lsn_attribute(:nullable_commit_lsn)],
            attributes_extra: [attribute(:nullable_commit_lsn, :integer, public?: true)],
            identity_keys: [
              :source_system_id,
              :source_database,
              :slot_name,
              :nullable_commit_lsn,
              :ordinal
            ],
            accept: [
              :source_system_id,
              :source_database,
              :slot_name,
              :nullable_commit_lsn,
              :ordinal,
              :operation,
              :origin,
              :snapshot_attempt,
              :id,
              :note
            ]
          )
        end

      assert error.message =~ "must declare `allow_nil? false`"
    end
  end

  describe "the append identity is EXACTLY the five-column tuple" do
    test "a four-key identity is rejected (a narrower key collides distinct effects)" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_identity]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.ShortIdentity,
            identity_keys: [:source_system_id, :source_database, :slot_name, :commit_lsn]
          )
        end

      assert error.message =~ "must have EXACTLY the five append axes"
    end

    test "a six-key identity is rejected (a wider key lets a replay append twice)" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_identity]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.LongIdentity,
            identity_keys: [
              :source_system_id,
              :source_database,
              :slot_name,
              :commit_lsn,
              :ordinal,
              :operation
            ]
          )
        end

      assert error.message =~ "must have EXACTLY the five append axes"
    end

    test "an attribute-multitenant target without `all_tenants? true` is rejected" do
      # Without it Ash PREPENDS the tenant discriminator to the upsert conflict
      # target. The host's five-column unique index then matches nothing and
      # every append dies at delivery with a Postgres 42P10 — this gate is what
      # moves that to build time.
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_identity]} do
          defmodule Elixir.AshReplicant.ValidateAppendLogTest.TenantScopedIdentity do
            use Ash.Resource,
              domain: AshReplicant.ValidateAppendLogTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("tenant_orders")
              append_log(true)
              tenant_attribute(:org_id)
            end

            attributes do
              uuid_primary_key :event_id
              attribute :source_system_id, :string, allow_nil?: false, public?: true
              attribute :source_database, :string, allow_nil?: false, public?: true
              attribute :slot_name, :string, allow_nil?: false, public?: true
              attribute :commit_lsn, :integer, allow_nil?: false, public?: true
              attribute :ordinal, :integer, allow_nil?: false, public?: true
              attribute :operation, :string, allow_nil?: false, public?: true
              attribute :origin, :string, allow_nil?: false, public?: true
              attribute :snapshot_attempt, :binary, public?: true
              attribute :id, :string, public?: true
              attribute :org_id, :string, allow_nil?: false, public?: true
            end

            multitenancy do
              strategy :attribute
              attribute :org_id
            end

            identities do
              identity :append_identity,
                       [:source_system_id, :source_database, :slot_name, :commit_lsn, :ordinal] do
                pre_check_with AshReplicant.ValidateAppendLogTest.Domain
              end
            end

            actions do
              defaults [:read]

              create :append do
                accept [
                  :source_system_id,
                  :source_database,
                  :slot_name,
                  :commit_lsn,
                  :ordinal,
                  :operation,
                  :origin,
                  :snapshot_attempt,
                  :id,
                  :org_id
                ]
              end
            end
          end
        end

      assert error.message =~ "must declare `all_tenants? true`"
    end

    test "a missing append identity is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :append_identity]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.NoIdentity,
            replicant_extra: [append_identity(:absent_identity)]
          )
        end

      assert error.message =~ "must declare the append identity :absent_identity"
    end
  end

  describe "state-mirror machinery is refused on an append target" do
    test "SCD2 history on an append target is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :history_strategy]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendScd2,
            replicant_extra: [history_strategy(:scd2), history_business_key([:id])]
          )
        end

      assert error.message =~ "`history_strategy :scd2` is a STATE-MIRROR strategy"
    end

    test "snapshot provenance on an append target is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :snapshot_provenance]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendProvenance,
            replicant_extra: [snapshot_provenance(true)]
          )
        end

      assert error.message =~ "`snapshot_provenance true` is a STATE-MIRROR mechanism"
    end

    test "on_truncate :mirror on an append target is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :on_truncate]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.AppendTruncateMirror,
            replicant_extra: [on_truncate(:mirror)]
          )
        end

      assert error.message =~ "is a STATE-MIRROR policy"
    end

    test "on_truncate :append on a state-mirror resource is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :on_truncate]} do
          defmodule Elixir.AshReplicant.ValidateAppendLogTest.MirrorTruncateAppend do
            use Ash.Resource,
              domain: AshReplicant.ValidateAppendLogTest.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshReplicant.Resource]

            replicant do
              source_table("orders")
              on_truncate(:append)
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

      assert error.message =~ "is an APPEND-LOG policy"
    end
  end

  describe "a tenant-scoped append target cannot append a tenant-blind truncate" do
    test "on_truncate :append with a tenant source is rejected" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:replicant, :on_truncate]} do
          append_resource(Elixir.AshReplicant.ValidateAppendLogTest.TenantTruncateAppend,
            replicant_extra: [on_truncate(:append), tenant_attribute(:org_id)],
            attributes_extra: [attribute(:org_id, :string, allow_nil?: false, public?: true)],
            accept: [
              :source_system_id,
              :source_database,
              :slot_name,
              :commit_lsn,
              :ordinal,
              :operation,
              :origin,
              :snapshot_attempt,
              :id,
              :note,
              :org_id
            ]
          )
        end

      assert error.message =~ "cannot be combined with a declared tenant source"
    end
  end
end
