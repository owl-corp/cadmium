defmodule Cadmium.LeaderTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Cadmium.Kube
  alias Cadmium.Kube.{Fake, Lease}
  alias Cadmium.Leader

  @namespace "cadmium"
  @lease "test-lease"

  setup context do
    fake = start_supervised!({Fake, name: nil})
    Fake.use_server(fake)

    # a hand-cranked monotonic clock (ms) shared by every contender in the test
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000_000)

    %{fake: fake, clock: clock, prefix: "leader-test-#{context.test |> :erlang.phash2()}"}
  end

  defp advance(clock, ms), do: :atomics.add(clock, 1, ms)

  # Starts a contender driven by `Leader.tick/1`; its transitions arrive as
  # `{identity, :acquired | :lost}`.
  defp start_leader(context, identity, opts \\ []) do
    name = :"#{context.prefix}-#{identity}"
    topic = "#{context.prefix}:#{identity}"
    test = self()
    clock = context.clock

    {:ok, relay} =
      Task.start_link(fn ->
        Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)
        send(test, {:subscribed, identity})
        relay(test, identity)
      end)

    assert_receive {:subscribed, ^identity}

    opts =
      Keyword.merge(
        [
          name: name,
          identity: identity,
          topic: topic,
          lease_namespace: @namespace,
          lease_name: @lease,
          lease_duration_s: 15,
          lease_renew_interval_ms: :infinity,
          clock: fn -> :atomics.get(clock, 1) end
        ],
        opts
      )

    pid = start_supervised!({Leader, opts}, id: name)
    _ = :sys.get_state(pid)
    on_exit(fn -> Process.exit(relay, :kill) end)
    name
  end

  defp relay(test, identity) do
    receive do
      {:leadership, event} -> send(test, {identity, event})
    end

    relay(test, identity)
  end

  defp lease do
    {:ok, lease} = Kube.get_lease(@namespace, @lease)
    lease
  end

  test "the public contract" do
    assert Leader.topic() == "leader"
    assert %{id: Leader, start: {Leader, :start_link, [[]]}} = Leader.child_spec([])
  end

  test "leader?/0 and current/0 are safe when no leader process runs" do
    refute Leader.leader?()
    assert Leader.current() == nil
    refute Leader.leader?(:no_such_leader)
    assert Leader.current(:no_such_leader) == nil
  end

  describe "acquisition" do
    test "creates the lease when there is none", context do
      a = start_leader(context, "node-a", now: fn -> ~U[2026-03-04 09:00:00.000000Z] end)

      assert_receive {"node-a", :acquired}
      assert Leader.leader?(a)
      assert Leader.current(a) == "node-a"

      assert %Lease{
               holder: "node-a",
               acquire_time: ~U[2026-03-04 09:00:00.000000Z],
               renew_time: ~U[2026-03-04 09:00:00.000000Z],
               duration_seconds: 15,
               transitions: 0
             } = lease()
    end

    test "takes a lease nobody holds straight away", context do
      {:ok, _} = Kube.create_lease(%Lease{namespace: @namespace, name: @lease, transitions: 4})

      a = start_leader(context, "node-a")

      assert_receive {"node-a", :acquired}
      assert Leader.leader?(a)
      assert %Lease{holder: "node-a", transitions: 5} = lease()
    end

    test "resumes its own lease after a restart without a transition", context do
      {:ok, _} =
        Kube.create_lease(%Lease{
          namespace: @namespace,
          name: @lease,
          holder: "node-a",
          acquire_time: ~U[2026-01-01 00:00:00.000000Z],
          renew_time: ~U[2026-01-01 00:00:10.000000Z],
          duration_seconds: 15,
          transitions: 2
        })

      a = start_leader(context, "node-a")

      assert_receive {"node-a", :acquired}
      assert Leader.leader?(a)

      assert %Lease{
               holder: "node-a",
               transitions: 2,
               acquire_time: ~U[2026-01-01 00:00:00.000000Z]
             } =
               lease()
    end

    test "defaults come from the Catalyst config and Cadmium.node_name/0", context do
      name = :"#{context.prefix}-defaults"

      start_supervised!(
        {Leader, name: name, topic: context.prefix, lease_renew_interval_ms: :infinity}
      )

      assert Leader.tick(name)
      assert Leader.current(name) == Cadmium.node_name()

      assert {:ok, %Lease{holder: holder, duration_seconds: 15}} =
               Kube.get_lease("default", "cadmium-catalyst")

      assert holder == Cadmium.node_name()
    end
  end

  describe "renewal" do
    test "each round renews the lease and pushes the deadline out", context do
      times = :atomics.new(1, [])

      now = fn ->
        DateTime.add(~U[2026-03-04 09:00:00.000000Z], :atomics.add_get(times, 1, 1), :second)
      end

      a = start_leader(context, "node-a", now: now)
      assert_receive {"node-a", :acquired}
      first = lease()

      advance(context.clock, 5_000)
      assert Leader.tick(a)
      renewed = lease()
      assert DateTime.compare(renewed.renew_time, first.renew_time) == :gt
      assert renewed.resource_version != first.resource_version
      assert renewed.acquire_time == first.acquire_time
      assert renewed.transitions == 0

      # 16s after acquiring, but only 11s after the last renewal
      advance(context.clock, 11_000)
      assert Leader.leader?(a)

      advance(context.clock, 3_999)
      assert Leader.leader?(a)
      advance(context.clock, 1)
      refute Leader.leader?(a)

      refute_received {"node-a", :lost}
    end

    test "runs on its own timer", context do
      test = self()

      now = fn ->
        send(test, :lease_written)
        DateTime.utc_now()
      end

      a =
        start_leader(context, "node-a",
          now: now,
          clock: &Leader.monotonic_ms/0,
          lease_renew_interval_ms: 5,
          lease_duration_s: 60
        )

      for _write <- 1..4, do: assert_receive(:lease_written, 1_000)
      assert Leader.leader?(a)
      assert_received {"node-a", :acquired}
      refute_received {"node-a", _again}
    end
  end

  describe "two contenders" do
    test "only one leads; the other follows and knows who leads", context do
      a = start_leader(context, "node-a")
      b = start_leader(context, "node-b")

      assert_receive {"node-a", :acquired}
      assert Leader.leader?(a)
      refute Leader.leader?(b)
      assert Leader.current(a) == "node-a"
      assert Leader.current(b) == "node-a"

      for _round <- 1..5 do
        advance(context.clock, 5_000)
        assert Leader.tick(a)
        refute Leader.tick(b)
      end

      assert %Lease{holder: "node-a", transitions: 0} = lease()
      refute_received {"node-b", _event}
      refute_received {"node-a", :lost}
    end

    test "a simultaneous start still yields one leader", context do
      # both read "no lease" before either creates it: the loser's create conflicts
      {:ok, _} = Kube.create_lease(%Lease{namespace: @namespace, name: @lease})
      Fake.fail(:get_lease, :not_found)

      a = start_leader(context, "node-a")
      refute Leader.leader?(a)

      Fake.heal()
      b = start_leader(context, "node-b")
      assert Leader.leader?(b)
      refute Leader.tick(a)
      assert Leader.current(a) == "node-b"
    end
  end

  describe "takeover" do
    test "a follower takes over once the lease has been still for its duration", context do
      a = start_leader(context, "node-a")
      b = start_leader(context, "node-b")
      assert_receive {"node-a", :acquired}

      # node-a stops renewing (crashed, partitioned, ...)
      advance(context.clock, 14_999)
      refute Leader.tick(b)
      refute_received {"node-b", :acquired}

      advance(context.clock, 1)
      assert Leader.tick(b)
      assert_receive {"node-b", :acquired}
      assert Leader.leader?(b)
      assert Leader.current(b) == "node-b"
      assert %Lease{holder: "node-b", transitions: 1} = lease()

      # node-a's own deadline has passed as well, even before it finds out
      refute Leader.leader?(a)
      refute Leader.tick(a)
      assert_receive {"node-a", :lost}
      assert Leader.current(a) == "node-b"
    end

    test "expiry is counted from when the follower last saw the lease change", context do
      a = start_leader(context, "node-a", now: fn -> ~U[2020-01-01 00:00:00.000000Z] end)
      assert_receive {"node-a", :acquired}

      # the timestamps in the record are ancient; that alone must not matter
      advance(context.clock, 60_000)
      assert Leader.tick(a)
      b = start_leader(context, "node-b")
      refute Leader.leader?(b)

      advance(context.clock, 10_000)
      assert Leader.tick(a)
      refute Leader.tick(b)

      # 20s after b first looked, but only 10s after the renewal it saw
      advance(context.clock, 10_000)
      refute Leader.tick(b)

      advance(context.clock, 5_000)
      assert Leader.tick(b)
      assert %Lease{holder: "node-b", transitions: 1} = lease()
    end
  end

  describe "stepping down" do
    test "keeps leading through API errors only until the lease deadline", context do
      a = start_leader(context, "node-a")
      assert_receive {"node-a", :acquired}

      Fake.fail(:all, :timeout)

      advance(context.clock, 5_000)
      assert Leader.tick(a)
      advance(context.clock, 9_999)
      assert Leader.tick(a)
      refute_received {"node-a", :lost}

      # the deadline passes: leader?/0 flips without the process doing anything
      advance(context.clock, 1)
      refute Leader.leader?(a)

      refute Leader.tick(a)
      assert_receive {"node-a", :lost}
      refute Leader.tick(a)
      refute_received {"node-a", _event}

      Fake.heal()
      assert Leader.tick(a)
      assert_receive {"node-a", :acquired}
      assert %Lease{holder: "node-a", transitions: 0} = lease()
    end

    test "survives the API client blowing up", context do
      a = start_leader(context, "node-a")
      assert_receive {"node-a", :acquired}

      stop_supervised!(Fake)
      advance(context.clock, 5_000)
      assert Leader.tick(a)
      advance(context.clock, 10_000)
      refute Leader.tick(a)
      assert_receive {"node-a", :lost}
    end

    test "steps down at once when someone else wrote the lease", context do
      a = start_leader(context, "node-a")
      assert_receive {"node-a", :acquired}

      {:ok, _} = Kube.update_lease(%{lease() | holder: "intruder", transitions: 1})

      advance(context.clock, 5_000)
      refute Leader.tick(a)
      assert_receive {"node-a", :lost}
      refute Leader.leader?(a)

      refute Leader.tick(a)
      assert Leader.current(a) == "intruder"
      assert %Lease{holder: "intruder"} = lease()
    end

    test "steps down when the lease disappears, then recreates it", context do
      a = start_leader(context, "node-a")
      assert_receive {"node-a", :acquired}

      Fake.delete_lease(@namespace, @lease)
      refute Leader.tick(a)
      assert_receive {"node-a", :lost}

      assert Leader.tick(a)
      assert_receive {"node-a", :acquired}
    end
  end

  describe "shutdown" do
    test "releases the lease so a follower takes over immediately", context do
      a = start_leader(context, "node-a")
      b = start_leader(context, "node-b")
      assert_receive {"node-a", :acquired}

      stop_supervised!(a)

      assert_receive {"node-a", :lost}
      refute Leader.leader?(a)
      assert %Lease{holder: nil, duration_seconds: 1, transitions: 0} = lease()

      assert Leader.tick(b)
      assert_receive {"node-b", :acquired}
      assert %Lease{holder: "node-b", transitions: 1, duration_seconds: 15} = lease()
    end

    test "a follower leaves the lease alone", context do
      _a = start_leader(context, "node-a")
      b = start_leader(context, "node-b")
      before = lease()

      stop_supervised!(b)

      assert lease() == before
      refute_received {"node-b", _event}
    end
  end
end
