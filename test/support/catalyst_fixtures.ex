defmodule Cadmium.CatalystFixtures do
  @moduledoc "Builders for Catalyst tests."

  alias Cadmium.Catalyst.Config
  alias Cadmium.Isotope.PodSample
  alias Cadmium.Kube.{Node, PDB, Pod}
  alias Cadmium.Valence.NodeScore
  alias Cadmium.Workload

  @taint_key "cadmium.owl-corp.io/hot"

  def taint_key, do: @taint_key

  @doc "Catalyst config independent of the application environment."
  def config(overrides \\ []) do
    struct!(
      %Config{
        hot_threshold: 70.0,
        spread_threshold: 25.0,
        sustained_ms: 120_000,
        node_cooldown_ms: 300_000,
        workload_cooldown_ms: 900_000,
        max_evictions_per_cycle: 1,
        taint_key: @taint_key,
        opt_out_annotation: "cadmium.owl-corp.io/rebalance",
        excluded_namespaces: ["kube-system"],
        audit_log_size: 500
      },
      overrides
    )
  end

  def score(name, score, components \\ nil) do
    %NodeScore{
      k8s_node: name,
      beam_node: :"cadmium@#{name}",
      score: score * 1.0,
      ts: 0,
      components: components || %{cpu: score * 1.0, memory: 10.0, io: 5.0}
    }
  end

  def kube_node(name, attrs \\ []), do: struct!(%Node{name: name}, attrs)

  def cadmium_taint, do: %{key: @taint_key, value: "true", effect: "PreferNoSchedule"}

  @doc """
  A movable workload: a Running pod of ReplicaSet `<name>-rs` in namespace "default".
  `attrs` may override pod fields, plus `:sample` (keyword of `PodSample` fields),
  `:cpu_drift` and `:memory_drift`.
  """
  def workload(name, node, attrs \\ []) do
    {sample, attrs} = Keyword.pop(attrs, :sample, cpu_usage_millis: 500.0)
    {cpu_drift, attrs} = Keyword.pop(attrs, :cpu_drift)
    {memory_drift, attrs} = Keyword.pop(attrs, :memory_drift)
    uid = "uid-#{name}"

    pod =
      struct!(
        %Pod{
          namespace: "default",
          name: name,
          uid: uid,
          node_name: node,
          phase: "Running",
          owner_kind: "ReplicaSet",
          owner_name: "#{name}-rs",
          labels: %{"app" => name}
        },
        attrs
      )

    %Workload{
      pod: pod,
      k8s_node: node,
      sample: sample && struct!(%PodSample{pod_uid: uid, ts: 0}, sample),
      cpu_drift: cpu_drift,
      memory_drift: memory_drift
    }
  end

  def pdb(name, attrs \\ []), do: struct!(%PDB{namespace: "default", name: name}, attrs)

  @doc "Replica map entries (3/3 ready unless given) for the controllers of `workloads`."
  def replicas(workloads, info \\ %{desired: 3, ready: 3}) do
    Map.new(workloads, fn w -> {{w.pod.namespace, w.pod.owner_kind, w.pod.owner_name}, info} end)
  end
end
