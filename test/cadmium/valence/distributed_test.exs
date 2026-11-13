defmodule Cadmium.Valence.DistributedTest do
  @moduledoc """
  Real two-node test using `:peer`. Starts Erlang distribution in the test VM if it is
  not already running (needs `epmd`, which is started on demand).

  Run on its own with `mix test --only distributed`.
  """
  use ExUnit.Case, async: false

  alias Cadmium.Kube.Pod
  alias Cadmium.{Valence, ValencePeer, Workload, Workloads}
  alias Cadmium.Valence.{ClusterState, NodeScore}

  @moduletag :distributed
  @moduletag timeout: 60_000

  setup_all do
    unless Node.alive?() do
      _ = System.cmd("epmd", ["-daemon"])
      name = :"cadmium_test_#{System.unique_integer([:positive])}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
      on_exit(fn -> :net_kernel.stop() end)
    end

    :ok
  end

  defp start_peer(k8s_node, pods) do
    {:ok, peer, peer_node} =
      :peer.start_link(%{
        name: :"cadmium_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    :ok = :erpc.call(peer_node, ValencePeer, :start_agent, [k8s_node, pods])
    {peer, peer_node}
  end

  test "scores and workloads flow across nodes and a vanished node is pruned" do
    # stale_after_ms is huge so that only :nodedown can explain the removal below
    start_supervised!(
      {ClusterState, notify_interval_ms: 0, stale_after_ms: 600_000, prune_interval_ms: :infinity}
    )

    :ok = Valence.subscribe()

    pod = %Pod{namespace: "default", name: "remote-web", uid: "uid-remote", cpu_request_millis: 1}
    {peer, peer_node} = start_peer("peer-node", [pod])

    assert peer_node in Node.list()
    assert Valence.nodes() == []

    # The peer's broadcaster ticks every 50ms once it has samples.
    :ok = :erpc.call(peer_node, ValencePeer, :feed, [[psi_cpu_some: 80.0, psi_io_full: 30.0]])

    assert_receive {:cluster_updated, [%NodeScore{k8s_node: "peer-node"} = score]}, 10_000
    assert score.beam_node == peer_node
    assert score.score > 50.0
    assert score.components.cpu > 40.0

    assert [%NodeScore{k8s_node: "peer-node", beam_node: ^peer_node}] = Valence.nodes()
    assert %NodeScore{} = Valence.node_score("peer-node")
    assert [_ | _] = Valence.history("peer-node")
    assert Valence.beam_node_for("peer-node") == peer_node

    # Workloads fan out over the same mesh.
    assert [%Workload{pod: %Pod{name: "remote-web"}, k8s_node: "peer-node"}] =
             Workloads.on_node("peer-node")

    assert [%Workload{pod: %Pod{name: "remote-web"}, k8s_node: "peer-node"}] =
             Workloads.cluster()

    # The node disappears: it must leave the view promptly.
    flush_updates()
    :peer.stop(peer)

    assert_receive {:cluster_updated, []}, 10_000
    assert Valence.nodes() == []
    assert Valence.node_score("peer-node") == nil
    assert Valence.beam_node_for("peer-node") == nil
    assert Workloads.on_node("peer-node") == []
    assert Workloads.cluster() == []
  end

  defp flush_updates do
    receive do
      {:cluster_updated, _} -> flush_updates()
    after
      0 -> :ok
    end
  end
end
