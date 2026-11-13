defmodule Cadmium.ValenceTest do
  # Uses the default process/table names and the application PubSub: not async.
  use ExUnit.Case, async: false

  alias Cadmium.Isotope.NodeSample
  alias Cadmium.Valence
  alias Cadmium.Valence.{Broadcaster, ClusterState, NodeScore}

  describe "without running processes" do
    test "the public API returns the documented empty values" do
      assert Valence.nodes() == []
      assert Valence.node_score("node-a") == nil
      assert Valence.history("node-a") == []
      assert Valence.history("node-a", 5) == []
      assert Valence.beam_node_for("node-a") == nil
    end
  end

  describe "with ClusterState running" do
    setup do
      start_supervised!({ClusterState, notify_interval_ms: 0, prune_interval_ms: :infinity})
      :ok = Valence.subscribe()
    end

    defp publish(score) do
      Phoenix.PubSub.broadcast(Cadmium.PubSub, Valence.scores_topic(), {:node_score, score})
      :sys.get_state(ClusterState)
      score
    end

    test "serves scores published on the scores topic" do
      b = publish(%NodeScore{k8s_node: "node-b", beam_node: node(), score: 80.0, ts: 1})
      a1 = publish(%NodeScore{k8s_node: "node-a", beam_node: node(), score: 20.0, ts: 1})
      a2 = publish(%NodeScore{k8s_node: "node-a", beam_node: node(), score: 30.0, ts: 2})

      assert Valence.nodes() == [a2, b]
      assert Valence.node_score("node-a") == a2
      assert Valence.history("node-a") == [a1, a2]
      assert Valence.history("node-a", 1) == [a2]
      assert Valence.beam_node_for("node-a") == node()
      assert Valence.beam_node_for("nope") == nil

      assert_receive {:cluster_updated, [^a2, ^b]}
    end

    test "drops scores from unconnected beam nodes" do
      publish(%NodeScore{k8s_node: "ghost", beam_node: :ghost@nowhere, score: 1.0, ts: 1})

      assert Valence.nodes() == []
      assert Valence.beam_node_for("ghost") == nil
    end

    test "end to end: isotope sample -> broadcaster -> cluster state" do
      start_supervised!({Broadcaster, interval_ms: :infinity})
      ts = System.system_time(:millisecond)

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Isotope.topic(),
        {:isotope_sample, %NodeSample{ts: ts, psi_memory_full: 40.0, memory_used_ratio: 0.9}}
      )

      assert {:ok, score} = Broadcaster.broadcast_now()
      assert_receive {:cluster_updated, [^score]}
      assert Valence.nodes() == [score]
      assert score.k8s_node == "test-node"
      assert score.components.memory > 30.0
      assert Valence.beam_node_for("test-node") == node()
    end
  end

  describe "Supervisor" do
    setup do
      previous = Application.get_env(:cadmium, :kube_client)
      Application.put_env(:cadmium, :kube_client, Cadmium.ValenceKubeStub)
      on_exit(fn -> Application.put_env(:cadmium, :kube_client, previous) end)
    end

    test "starts cluster state, pod cache and broadcaster; no libcluster without topologies" do
      sup = start_supervised!({Valence.Supervisor, []})

      ids = for {id, _pid, _type, _mods} <- Supervisor.which_children(sup), do: id

      assert Enum.sort(ids) ==
               Enum.sort([ClusterState, Cadmium.Workloads.PodCache, Broadcaster])

      assert Process.whereis(Cadmium.ClusterSupervisor) == nil
      assert Valence.nodes() == []
    end

    test "starts libcluster with the given topologies" do
      topologies = [test: [strategy: Cluster.Strategy.Gossip, config: [port: 45_899]]]
      start_supervised!({Valence.Supervisor, topologies: topologies})

      assert is_pid(Process.whereis(Cadmium.ClusterSupervisor))
    end
  end
end
