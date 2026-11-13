defmodule Cadmium.Catalyst.AuditLogTest do
  use ExUnit.Case, async: false

  alias Cadmium.Catalyst.{Action, AuditLog}

  defp start_log(opts \\ []) do
    id = System.unique_integer([:positive])
    name = :"catalyst_audit_test_#{id}"
    topic = "catalyst:events:test:#{id}"
    opts = Keyword.merge([name: name, topic: topic, size: 50], opts)
    start_supervised!({AuditLog, opts}, id: name)
    %{log: opts[:name], topic: opts[:topic]}
  end

  defp action(id, ts, attrs \\ []),
    do: struct!(%Action{id: id, ts: ts, type: :evict, actor: "node-z"}, attrs)

  test "records actions and returns them newest first" do
    %{log: log} = start_log()

    first = AuditLog.record(log, type: :taint, node: "node-a")

    second =
      AuditLog.record(log, type: :evict, node: "node-a", namespace: "default", pod: "web-1")

    third = AuditLog.record(log, type: :untaint, node: "node-a")

    assert AuditLog.recent(log, 10) == [third, second, first]
    assert AuditLog.recent(log, 2) == [third, second]
    assert AuditLog.recent(log, 0) == []
  end

  test "stamps a unique id, a strictly increasing ts and the actor" do
    %{log: log} = start_log()
    actions = for _ <- 1..20, do: AuditLog.record(log, type: :evict)

    assert actions |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 20
    timestamps = Enum.map(actions, & &1.ts)
    assert timestamps == Enum.sort(timestamps)
    assert timestamps == Enum.uniq(timestamps)
    assert Enum.all?(actions, &(&1.actor == Cadmium.node_name()))
    assert Enum.all?(actions, &(&1.result == :ok and &1.dry_run? == false))
  end

  test "is bounded: the oldest entries are dropped" do
    %{log: log} = start_log(size: 3)
    actions = for i <- 1..7, do: AuditLog.record(log, type: :evict, pod: "pod-#{i}")

    assert AuditLog.recent(log, 100) == actions |> Enum.reverse() |> Enum.take(3)
    assert :ets.info(log, :size) == 3
  end

  test "broadcasts every new action cluster-wide on the topic" do
    %{log: log, topic: topic} = start_log()
    Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

    action = AuditLog.record(log, type: :leader_acquired)
    assert_receive {:catalyst_action, ^action}
  end

  test "stores actions received from other agents, deduplicated by id" do
    %{log: log, topic: topic} = start_log()
    remote = action("node-z-1", 1_000, pod: "web-1")

    for _ <- 1..3, do: Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_action, remote})
    _ = :sys.get_state(log)

    assert AuditLog.recent(log, 10) == [remote]
  end

  test "does not re-store its own broadcast" do
    %{log: log} = start_log()
    action = AuditLog.record(log, type: :evict)
    _ = :sys.get_state(log)
    assert AuditLog.recent(log, 10) == [action]
  end

  test "remote actions are merged in timestamp order and respect the bound" do
    %{log: log, topic: topic} = start_log(size: 3)

    for {id, ts} <- [{"c", 3_000}, {"a", 1_000}, {"d", 4_000}, {"b", 2_000}] do
      Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_action, action(id, ts)})
    end

    _ = :sys.get_state(log)
    assert log |> AuditLog.recent(10) |> Enum.map(& &1.id) == ["d", "c", "b"]
  end

  test "ignores malformed messages" do
    %{log: log, topic: topic} = start_log()

    for junk <- [:nope, %{id: "x"}, %Action{id: nil, ts: 1, type: :evict}] do
      Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_action, junk})
    end

    send(Process.whereis(log), :unexpected)
    _ = :sys.get_state(log)
    assert AuditLog.recent(log, 10) == []
  end

  test "a newly started log backfills from its peers" do
    # The "peer" is this node's default-named log, reached over :erpc like a real peer.
    start_supervised!({AuditLog, topic: "catalyst:events:test:peer", size: 50})
    old = for i <- 1..3, do: AuditLog.record(type: :evict, pod: "pod-#{i}")

    %{log: log} = start_log(peers_fun: fn -> [node()] end)

    assert eventually(fn -> length(AuditLog.recent(log, 10)) == 3 end)
    assert AuditLog.recent(log, 10) == Enum.reverse(old)
  end

  test "recent/2 and record/2 are safe when the log is not running" do
    assert AuditLog.recent(:catalyst_audit_not_started, 10) == []

    assert %Action{type: :evict, id: id} =
             AuditLog.record(:catalyst_audit_not_started, type: :evict)

    assert is_binary(id)
  end

  # The backfill arrives from a helper process via :erpc, so there is no message of our
  # own to wait on; poll with a bounded deadline instead.
  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end
    end
  end
end
