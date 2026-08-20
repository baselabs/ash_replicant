defmodule AshReplicant.DestinationParticipantTest do
  @moduledoc """
  U3/D1 — the per-invocation operation discriminator. One ordinal per CHANGE
  fans to up to three effects; the closed label set gives each invocation its
  own operation key so a declared AshOnetime effect can never be silently
  replayed away by a colliding key. The enumeration test pins the closed set
  to the call-site inventory: a new effect site must add a label (or the set
  fails to match the code), and every label names the test that exercises its
  mint site.
  """

  use ExUnit.Case, async: true

  alias AshReplicant.Apply.Context
  alias AshReplicant.DestinationParticipant

  @base %{
    source_system_identifier: "system",
    source_database: "source",
    slot_name: "slot",
    commit_lsn: 42,
    ordinal: 0
  }

  describe "the discriminator in operation_key/2" do
    test "identical 6-axis identity, different labels → different keys" do
      assert {:ok, close_prior} =
               DestinationParticipant.operation_key(
                 Map.put(@base, :invocation, :close_prior),
                 :auxiliary
               )

      assert {:ok, close_current} =
               DestinationParticipant.operation_key(
                 Map.put(@base, :invocation, :close_current),
                 :auxiliary
               )

      assert {:ok, open} =
               DestinationParticipant.operation_key(
                 Map.put(@base, :invocation, :open),
                 :auxiliary
               )

      # The collision class: same change (same ordinal), same action, same
      # participant — only the invocation differs, and that MUST discriminate.
      refute close_prior == close_current
      refute close_prior == open
      refute close_current == open
    end

    test "the same label mints deterministically (replay-stable)" do
      assert {:ok, a} =
               DestinationParticipant.operation_key(Map.put(@base, :invocation, :upsert), :aux)

      assert {:ok, ^a} =
               DestinationParticipant.operation_key(Map.put(@base, :invocation, :upsert), :aux)
    end

    test "an absent label fails closed" do
      assert {:error, :invalid_declaration} = DestinationParticipant.operation_key(@base, :aux)
    end

    test "an off-set label fails closed" do
      for bad <- [:bogus, :close, "upsert", nil, 0] do
        assert {:error, :invalid_declaration} =
                 DestinationParticipant.operation_key(Map.put(@base, :invocation, bad), :aux)
      end
    end
  end

  describe "the single home + the closed label set (enumeration pin)" do
    test "operation_components/0 is the canonical 7-axis list" do
      assert DestinationParticipant.operation_components() == [
               :source_system_identifier,
               :source_database,
               :slot_name,
               :commit_lsn,
               :ordinal,
               :participant,
               :invocation
             ]
    end

    test "declarations stay 6-AXIS: the home minus the sink-minted :invocation" do
      declared = DestinationParticipant.operation_components() -- [:invocation]

      assert declared == [
               :source_system_identifier,
               :source_database,
               :slot_name,
               :commit_lsn,
               :ordinal,
               :participant
             ]
    end

    test "every label minted in lib is in the closed set, and every label is USED (live pin)" do
      # Gate-integrity: the label->site mapping is not just comments — the
      # labels minted at lib call sites are grepped and must EQUAL the
      # closed set (a new effect site must add a label; an unused label is
      # stale). Same-label reuse within one change stays pinned by the
      # discriminator marquee's auxiliary-count assertion.
      minted =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          Regex.scan(~r/action_context\(config, change, :(\w+)\)/, source)
          |> Enum.map(&Enum.at(&1, 1))
          |> Kernel.++(
            Regex.scan(~r/invocation: :(\w+)/, source)
            |> Enum.map(&Enum.at(&1, 1))
          )
          |> Kernel.++(
            Regex.scan(
              ~r/destroy_by_pk\(config, resource, change\.old_record, change, :(\w+)\)/,
              source
            )
            |> Enum.map(&Enum.at(&1, 1))
          )
        end)
        |> MapSet.new()

      closed =
        Context.invocation_labels()
        |> Enum.map(&Atom.to_string/1)
        |> MapSet.new()

      assert MapSet.equal?(minted, closed),
             "minted labels in lib (#{inspect(MapSet.to_list(minted))}) must equal the closed set (#{inspect(MapSet.to_list(closed))})"
    end

    test "the closed label set is shared by both homes and matches the call-site inventory" do
      # One label per sink mint site. EVERY label names the test that drives
      # its mint site — adding an effect site without a label (or a label
      # without a site) breaks this pin:
      #   :close_prior   -> scd2.ex old-key/terminal close arms —
      #                     effect_once_discriminator_test (close_prior leg)
      #   :close_current -> scd2.ex re-opened-record close arm —
      #                     effect_once_discriminator_test (close_current leg)
      #   :open          -> scd2.ex open_version —
      #                     effect_once_discriminator_test (open leg)
      #   :destroy_prior -> apply.ex relocate/delete destroy_by_pk arms —
      #                     apply_test relocate/delete cells
      #   :upsert        -> apply.ex upsert + snapshot bulk/per-record paths —
      #                     effect_once_test (streaming) + snapshot marquees
      #   :message       -> messages.ex routed-message apply (both kinds) —
      #                     message_actions marquees + messages_test
      #   :mark_seen     -> snapshot/rows.ex provenance mark —
      #                     snapshot_v1_retry_test (bookkeeping-only legs)
      #   :retire_unseen -> snapshot/retirement.ex completion sweep —
      #                     snapshot_v1_retry_test (retirement legs)
      assert Context.invocation_labels() == DestinationParticipant.invocation_labels()

      assert Context.invocation_labels() == [
               :close_prior,
               :close_current,
               :open,
               :destroy_prior,
               :upsert,
               :message,
               :mark_seen,
               :retire_unseen
             ]
    end

    test "operation_context/3 mints the label and rejects off-set labels" do
      config = %{
        source_identity: %{system_identifier: "system", database: "source"},
        slot_name: "slot"
      }

      change = %Replicant.Change{
        op: :insert,
        schema: "public",
        table: "t",
        record: %{},
        old_record: nil,
        unchanged: [],
        commit_lsn: 5,
        ordinal: 1
      }

      assert {:ok, %{invocation: :open}} = Context.operation_context(config, change, :open)

      assert :error = Context.operation_context(config, change, :bogus)
      assert :error = Context.operation_context(config, change, "open")
    end
  end
end
