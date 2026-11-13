defmodule Cadmium.WorkloadsTest do
  # Uses the default PodCache name, application env and the Kube stub: not async.
  use ExUnit.Case, async: false

  alias Cadmium.Isotope.PodSample
  alias Cadmium.Kube.Pod
  alias Cadmium.{ValenceKubeStub, Workload, Workloads}
  alias Cadmium.Workloads.PodCache

  @gib 1_073_741_824

  setup do
    previous = Application.get_env(:cadmium, :kube_client)
    Application.put_env(:cadmium, :kube_client, ValenceKubeStub)
    ValenceKubeStub.reset_calls()

    on_exit(fn ->
      Application.put_env(:cadmium, :kube_client, previous)
      ValenceKubeStub.reset()
      ValenceKubeStub.reset_calls()
    end)
  end

  defp pod(name, fields \\ []) do
    struct!(%Pod{namespace: "default", name: name, uid: "uid-" <> name}, fields)
  end

  defp sample(name, fields) do
    struct!(%PodSample{pod_uid: "uid-" <> name, ts: 1}, fields)
  end

  describe "join/3" do
    test "computes drift as actual / requested" do
      web = pod("web", cpu_request_millis: 500, memory_request_bytes: @gib)
      web_sample = sample("web", cpu_usage_millis: 1_500.0, memory_bytes: div(@gib, 2))

      assert Workloads.join([web], [web_sample], "node-a") == [
               %Workload{
                 pod: web,
                 k8s_node: "node-a",
                 sample: web_sample,
                 cpu_drift: 3.0,
                 memory_drift: 0.5
               }
             ]
    end

    test "drift is nil without a request, without a sample or without a reading" do
      no_request = pod("no-request")
      no_sample = pod("no-sample", cpu_request_millis: 100, memory_request_bytes: @gib)
      no_reading = pod("no-reading", cpu_request_millis: 100, memory_request_bytes: @gib)

      samples = [
        sample("no-request", cpu_usage_millis: 250.0, memory_bytes: 1_000),
        sample("no-reading", cpu_usage_millis: nil, memory_bytes: nil),
        # a cgroup the API does not know about (e.g. already deleted) is not a workload
        sample("orphan", cpu_usage_millis: 10.0, memory_bytes: 10)
      ]

      assert [a, b, c] = Workloads.join([no_request, no_sample, no_reading], samples, "node-a")

      assert %Workload{pod: ^no_request, sample: %PodSample{}, cpu_drift: nil, memory_drift: nil} =
               a

      assert %Workload{pod: ^no_sample, sample: nil, cpu_drift: nil, memory_drift: nil} = b

      assert %Workload{pod: ^no_reading, sample: %PodSample{}, cpu_drift: nil, memory_drift: nil} =
               c
    end

    test "no pods, no workloads" do
      assert Workloads.join([], [sample("x", cpu_usage_millis: 1.0)], "node-a") == []
    end
  end

  describe "without a running cache" do
    test "everything returns [] instead of crashing" do
      assert Workloads.local() == []
      assert Workloads.cluster() == []
      assert Workloads.on_node("test-node") == []
      assert Workloads.on_node("unknown-node") == []
    end
  end

  describe "local/1" do
    test "joins the cached pods of this node with pod samples" do
      web = pod("web", cpu_request_millis: 200, memory_request_bytes: 1_000)
      db = pod("db", cpu_request_millis: 1_000)
      ValenceKubeStub.put({:ok, [web, db]})
      cache = start_supervised!({PodCache, interval_ms: :infinity})
      :sys.get_state(cache)

      samples = [sample("web", cpu_usage_millis: 300.0, memory_bytes: 4_000)]

      assert [
               %Workload{pod: ^web, k8s_node: "test-node", cpu_drift: 1.5, memory_drift: 4.0},
               %Workload{pod: ^db, k8s_node: "test-node", sample: nil, cpu_drift: nil}
             ] = Workloads.local(pod_samples: fn -> samples end)

      # the cache asked the API for this node's pods only
      assert ValenceKubeStub.calls() == [[node: "test-node"]]

      # default Isotope source (a stub here): pods still listed, without samples
      assert [%Workload{sample: nil}, %Workload{sample: nil}] = Workloads.local()
      assert Workloads.on_node("test-node") == Workloads.local()
    end

    test "refreshes on demand while the cache is empty" do
      ValenceKubeStub.put({:ok, []})
      cache = start_supervised!({PodCache, interval_ms: :infinity, min_refresh_ms: 0})
      :sys.get_state(cache)
      assert Workloads.local() == []

      ValenceKubeStub.put({:ok, [pod("late")]})
      assert [%Workload{pod: %Pod{name: "late"}}] = Workloads.local()
    end

    test "tolerates a crashing sample source" do
      ValenceKubeStub.put({:ok, [pod("web")]})
      cache = start_supervised!({PodCache, interval_ms: :infinity})
      :sys.get_state(cache)

      assert [%Workload{sample: nil}] = Workloads.local(pod_samples: fn -> raise "down" end)
    end
  end

  describe "cluster/1 and on_node/2" do
    setup do
      ValenceKubeStub.put({:ok, [pod("web")]})
      cache = start_supervised!({PodCache, interval_ms: :infinity})
      :sys.get_state(cache)
      :ok
    end

    test "cluster/1 includes this node and skips unreachable ones" do
      assert [%Workload{pod: %Pod{name: "web"}}] = Workloads.cluster()

      assert [%Workload{pod: %Pod{name: "web"}}] =
               Workloads.cluster(nodes: [node(), :"missing@127.0.0.1"], timeout: 500)

      assert Workloads.cluster(nodes: [:"missing@127.0.0.1"], timeout: 500) == []
    end

    test "on_node/2 resolves the agent through Valence" do
      local = Workloads.local()
      assert [_] = local

      assert Workloads.on_node("unknown-node") == []
      assert Workloads.on_node("other", beam_node_for: fn "other" -> node() end) == local

      assert Workloads.on_node("gone",
               beam_node_for: fn "gone" -> :"missing@127.0.0.1" end,
               timeout: 500
             ) == []
    end
  end
end
