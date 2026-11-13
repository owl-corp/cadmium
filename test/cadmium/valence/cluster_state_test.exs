defmodule Cadmium.Valence.ClusterStateTest do
  use ExUnit.Case, async: true

  alias Cadmium.Valence.{ClusterState, NodeScore}

  setup context do
    unique = System.unique_integer([:positive])
    pubsub = Module.concat(__MODULE__, "PubSub#{unique}")
    table = Module.concat(__MODULE__, "Table#{unique}")
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, "cluster")
    clock = start_supervised!({Agent, fn -> 0 end})

    opts =
      Keyword.merge(
        [
          name: nil,
          table: table,
          pubsub: pubsub,
          scores_topic: "scores",
          cluster_topic: "cluster",
          stale_after_ms: 15_000,
          history_size: 5,
          prune_interval_ms: :infinity,
          notify_interval_ms: 0,
          clock: fn -> Agent.get(clock, & &1) end,
          connected?: fn beam_node -> beam_node != :down@host end
        ],
        Map.get(context, :cluster_state, [])
      )

    pid = start_supervised!({ClusterState, opts})
    {:ok, pid: pid, table: table, pubsub: pubsub, clock: clock}
  end

  defp score(k8s_node, ts, fields \\ []) do
    struct!(
      %NodeScore{k8s_node: k8s_node, beam_node: :"#{k8s_node}@host", score: 10.0, ts: ts},
      fields
    )
  end

  # Publishes like a remote Broadcaster would, then waits until it has been processed.
  defp publish(%{pubsub: pubsub, pid: pid}, score) do
    Phoenix.PubSub.broadcast(pubsub, "scores", {:node_score, score})
    :sys.get_state(pid)
    score
  end

  test "reads return empty values when the table does not exist" do
    assert ClusterState.nodes(:no_such_valence_table) == []
    assert ClusterState.node_score(:no_such_valence_table, "node-a") == nil
    assert ClusterState.history(:no_such_valence_table, "node-a", 10) == []
  end

  test "stores the latest score per node, sorted by k8s_node", %{table: table} = ctx do
    b = publish(ctx, score("node-b", 1))
    c = publish(ctx, score("node-c", 1))
    a1 = publish(ctx, score("node-a", 1))
    a2 = publish(ctx, score("node-a", 2, score: 55.5))

    assert ClusterState.nodes(table) == [a2, b, c]
    assert ClusterState.node_score(table, "node-a") == a2
    assert ClusterState.node_score(table, "node-zzz") == nil
    assert ClusterState.history(table, "node-a", 10) == [a1, a2]
  end

  test "keeps a bounded history, oldest first", %{table: table} = ctx do
    scores = for ts <- 1..8, do: publish(ctx, score("node-a", ts))
    publish(ctx, score("node-b", 1))

    assert ClusterState.history(table, "node-a", 100) == Enum.take(scores, -5)
    assert ClusterState.history(table, "node-a", 2) == Enum.take(scores, -2)
    assert ClusterState.history(table, "node-b", 100) == [score("node-b", 1)]
    assert ClusterState.history(table, "node-x", 100) == []
  end

  test "ignores out-of-order, duplicate and malformed scores", %{table: table, pid: pid} = ctx do
    newest = publish(ctx, score("node-a", 10))
    assert_receive {:cluster_updated, [^newest]}

    publish(ctx, score("node-a", 9, score: 99.0))
    publish(ctx, score("node-a", 10, score: 99.0))
    send(pid, {:node_score, :garbage})
    send(pid, :unexpected)
    :sys.get_state(pid)

    assert ClusterState.nodes(table) == [newest]
    assert ClusterState.history(table, "node-a", 10) == [newest]
    refute_received {:cluster_updated, _}
  end

  test "a newer score from a new beam node takes over the k8s node", %{table: table} = ctx do
    publish(ctx, score("node-a", 10))
    restarted = publish(ctx, score("node-a", 11, beam_node: :restarted@host))
    # a straggler from the old incarnation loses
    publish(ctx, score("node-a", 5))

    assert ClusterState.nodes(table) == [restarted]

    # the old incarnation going down must not remove the new one
    send(ctx.pid, {:nodedown, :"node-a@host"})
    :sys.get_state(ctx.pid)
    assert ClusterState.nodes(table) == [restarted]
  end

  test "removes a node promptly on nodedown of its beam node", %{table: table, pid: pid} = ctx do
    publish(ctx, score("node-a", 1))
    b = publish(ctx, score("node-b", 1))
    assert_receive {:cluster_updated, [_]}
    assert_receive {:cluster_updated, [_, _]}

    send(pid, {:nodedown, :"node-a@host"})
    assert_receive {:cluster_updated, [^b]}

    assert ClusterState.nodes(table) == [b]
    assert ClusterState.node_score(table, "node-a") == nil
    assert ClusterState.history(table, "node-a", 10) == []

    send(pid, {:nodedown, :unrelated@host})
    :sys.get_state(pid)
    refute_received {:cluster_updated, _}
  end

  test "ignores scores from beam nodes that are not connected", %{table: table} = ctx do
    publish(ctx, score("node-a", 1, beam_node: :down@host))

    assert ClusterState.nodes(table) == []
    refute_received {:cluster_updated, _}
  end

  test "prunes nodes not heard from for stale_after_ms",
       %{table: table, pid: pid, clock: clock} = ctx do
    publish(ctx, score("node-a", 1))
    Agent.update(clock, fn _ -> 10_000 end)
    b = publish(ctx, score("node-b", 1))

    assert ClusterState.prune(pid) == []

    Agent.update(clock, fn _ -> 15_001 end)
    assert ClusterState.prune(pid) == ["node-a"]
    assert ClusterState.nodes(table) == [b]
    assert ClusterState.history(table, "node-a", 10) == []
    assert_receive {:cluster_updated, [^b]}

    # a pruned node can come back, even with an older ts than before
    back = publish(ctx, score("node-a", 1))
    assert ClusterState.nodes(table) == [back, b]

    Agent.update(clock, fn _ -> 100_000 end)
    assert Enum.sort(ClusterState.prune(pid)) == ["node-a", "node-b"]
    assert ClusterState.nodes(table) == []
    assert_receive {:cluster_updated, []}
  end

  @tag cluster_state: [prune_interval_ms: 10, stale_after_ms: 50]
  test "prunes on its own timer", %{table: table, clock: clock} = ctx do
    publish(ctx, score("node-a", 1))
    assert_receive {:cluster_updated, [_]}
    assert ClusterState.nodes(table) != []

    Agent.update(clock, fn _ -> 1_000 end)
    assert_receive {:cluster_updated, []}, 1_000
    assert ClusterState.nodes(table) == []
  end

  @tag cluster_state: [notify_interval_ms: 100]
  test "coalesces cluster_updated notifications", %{table: table} = ctx do
    first = publish(ctx, score("node-a", 1))
    # leading edge: the first change is announced immediately
    assert_receive {:cluster_updated, [^first]}, 50

    for ts <- 2..20, do: publish(ctx, score("node-a", ts))
    publish(ctx, score("node-b", 1))

    # ...and the burst that follows results in exactly one more, carrying the final view
    assert_receive {:cluster_updated, nodes}, 1_000
    assert nodes == ClusterState.nodes(table)
    assert [%NodeScore{k8s_node: "node-a", ts: 20}, %NodeScore{k8s_node: "node-b"}] = nodes
    refute_receive {:cluster_updated, _}, 200
  end
end
