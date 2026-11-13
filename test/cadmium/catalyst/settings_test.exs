defmodule Cadmium.Catalyst.SettingsTest do
  use ExUnit.Case, async: false

  alias Cadmium.Catalyst.{AuditLog, Settings}

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_settings(opts \\ []) do
    name = unique("catalyst_settings_test")

    opts =
      Keyword.merge(
        [
          name: name,
          sync_topic: "catalyst:sync:test:#{name}",
          audit: :catalyst_audit_not_started,
          config: [dry_run: true, enabled: true]
        ],
        opts
      )

    start_supervised!({Settings, opts}, id: name)
    %{settings: name, sync_topic: opts[:sync_topic]}
  end

  describe "merge/2 (last-writer-wins)" do
    @local %{dry_run?: {true, {100, "node-a"}}, enabled?: {true, {100, "node-a"}}}

    test "the newer version wins, per setting" do
      remote = %{dry_run?: {false, {200, "node-b"}}, enabled?: {false, {50, "node-b"}}}

      assert Settings.merge(@local, remote) ==
               %{dry_run?: {false, {200, "node-b"}}, enabled?: {true, {100, "node-a"}}}
    end

    test "equal timestamps are broken by actor name, the same way on both sides" do
      a = %{dry_run?: {true, {100, "node-a"}}, enabled?: {true, {0, ""}}}
      b = %{dry_run?: {false, {100, "node-b"}}, enabled?: {true, {0, ""}}}

      assert Settings.merge(a, b) == Settings.merge(b, a)
      assert Settings.merge(a, b).dry_run? == {false, {100, "node-b"}}
    end

    test "is commutative, associative and idempotent" do
      a = %{dry_run?: {true, {300, "a"}}, enabled?: {false, {100, "a"}}}
      b = %{dry_run?: {false, {200, "b"}}, enabled?: {true, {400, "b"}}}
      c = %{dry_run?: {false, {300, "c"}}, enabled?: {false, {50, "c"}}}

      assert Settings.merge(a, b) == Settings.merge(b, a)
      assert Settings.merge(Settings.merge(a, b), c) == Settings.merge(a, Settings.merge(b, c))
      assert Settings.merge(a, a) == a
      assert Settings.merge(Settings.merge(a, b), b) == Settings.merge(a, b)
    end

    test "config defaults (version 0) lose to any runtime change" do
      defaults = %{dry_run?: {true, {0, ""}}, enabled?: {true, {0, ""}}}
      remote = %{dry_run?: {false, {1, "node-b"}}}
      assert Settings.merge(defaults, remote).dry_run? == {false, {1, "node-b"}}
    end

    test "malformed remote data is ignored" do
      for junk <- [
            nil,
            :nope,
            %{},
            %{dry_run?: false},
            %{dry_run?: {"yes", {999, "x"}}},
            %{dry_run?: {false, 999}},
            %{dry_run?: {false, {"999", "x"}}},
            %{unknown: {false, {999, "x"}}}
          ] do
        assert Settings.merge(@local, junk) == @local
      end
    end
  end

  describe "process" do
    test "starts from config" do
      %{settings: settings} = start_settings(config: [dry_run: false, enabled: false])
      assert Settings.get(settings) == %{dry_run?: false, enabled?: false}
    end

    test "put/3 changes the value and bumps the version" do
      %{settings: settings} = start_settings(wall_clock: fn -> 5_000 end, actor: "node-a")

      assert :ok = Settings.put(settings, :dry_run?, false)
      assert Settings.get(settings) == %{dry_run?: false, enabled?: true}
      assert Settings.snapshot(settings).dry_run? == {false, {5_000, "node-a"}}

      # same wall-clock reading: the version still moves forward
      assert :ok = Settings.put(settings, :dry_run?, true)
      assert Settings.snapshot(settings).dry_run? == {true, {5_001, "node-a"}}
    end

    test "a change is broadcast to peers and announced locally" do
      %{settings: settings, sync_topic: topic} = start_settings()
      Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

      Settings.put(settings, :enabled?, false)

      assert_receive {:catalyst_settings, %{enabled?: {false, {_ts, _actor}}}}
      assert_receive {:catalyst_settings_applied, %{enabled?: false, dry_run?: true}}
    end

    test "a change records a :settings_changed action; a no-op does not" do
      audit = unique("catalyst_audit_test")
      start_supervised!({AuditLog, name: audit, topic: "catalyst:events:test:#{audit}"})
      %{settings: settings} = start_settings(audit: audit, actor: "node-a")

      Settings.put(settings, :dry_run?, false)
      Settings.put(settings, :dry_run?, false)
      Settings.put(settings, :enabled?, true)

      assert [action] = AuditLog.recent(audit, 10)
      assert action.type == :settings_changed
      assert action.actor == "node-a"
      assert action.details == %{setting: :dry_run?, value: false}
      assert action.reason =~ "dry-run disabled"
    end

    test "applies newer remote settings and ignores older ones" do
      %{settings: settings, sync_topic: topic} = start_settings(wall_clock: fn -> 5_000 end)
      Settings.put(settings, :dry_run?, false)
      Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

      older = %{dry_run?: {true, {4_000, "node-b"}}}
      Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_settings, older})
      _ = :sys.get_state(settings)
      assert Settings.get(settings).dry_run? == false
      refute_received {:catalyst_settings_applied, _}

      newer = %{dry_run?: {true, {6_000, "node-b"}}}
      Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_settings, newer})
      _ = :sys.get_state(settings)
      assert Settings.get(settings).dry_run? == true
      assert_received {:catalyst_settings_applied, %{dry_run?: true}}
    end

    test "two agents converge on the last write, whoever made it" do
      topic = "catalyst:sync:test:#{unique("pair")}"
      clock = start_supervised!({Agent, fn -> 1_000 end})
      tick = fn -> Agent.get_and_update(clock, &{&1, &1 + 10}) end

      %{settings: a} = start_settings(sync_topic: topic, actor: "node-a", wall_clock: tick)
      %{settings: b} = start_settings(sync_topic: topic, actor: "node-b", wall_clock: tick)

      Settings.put(a, :dry_run?, false)
      _ = :sys.get_state(b)
      assert Settings.get(b).dry_run? == false

      Settings.put(b, :enabled?, false)
      Settings.put(b, :dry_run?, true)
      _ = :sys.get_state(a)

      assert Settings.get(a) == %{dry_run?: true, enabled?: false}
      assert Settings.snapshot(a) == Settings.snapshot(b)
    end

    test "a newly started agent syncs from its peers" do
      # The "peer" is this node's default-named process, reached over :erpc like a real peer.
      start_supervised!(
        {Settings, sync_topic: "catalyst:sync:test:peer", audit: :catalyst_audit_not_started}
      )

      Settings.put(:dry_run?, false)
      Settings.put(:enabled?, false)

      name = unique("catalyst_settings_test")
      topic = "catalyst:sync:test:#{name}"
      Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

      start_supervised!(
        {Settings,
         name: name,
         sync_topic: topic,
         audit: :catalyst_audit_not_started,
         config: [dry_run: true, enabled: true],
         peers_fun: fn -> [node()] end},
        id: name
      )

      assert_receive {:catalyst_settings_applied, %{dry_run?: false, enabled?: false}}, 2_000
      assert Settings.snapshot(name) == Settings.snapshot()
    end

    test "re-syncs when asked (as after :nodeup)" do
      start_supervised!(
        {Settings, sync_topic: "catalyst:sync:test:peer", audit: :catalyst_audit_not_started}
      )

      peers = start_supervised!({Agent, fn -> [] end})

      %{settings: settings, sync_topic: topic} =
        start_settings(peers_fun: fn -> Agent.get(peers, & &1) end)

      Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

      Settings.put(:dry_run?, false)
      Agent.update(peers, fn _ -> [node()] end)
      send(Process.whereis(settings), :sync)

      assert_receive {:catalyst_settings_applied, %{dry_run?: false}}, 2_000
    end

    test "get/1 falls back to config and put/3 is a no-op when not running" do
      assert Settings.fetch(:catalyst_settings_not_started) == nil
      assert Settings.get(:catalyst_settings_not_started) == Settings.defaults()
      assert Settings.put(:catalyst_settings_not_started, :dry_run?, false) == :ok
      assert Settings.snapshot(:catalyst_settings_not_started) == nil
    end
  end
end
