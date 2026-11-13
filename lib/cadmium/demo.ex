defmodule Cadmium.Demo do
  @moduledoc """
  Deterministic demo fixtures shared by the synthetic telemetry source
  (`Cadmium.Isotope.Source.Synthetic`) and the in-memory Kubernetes client
  (`Cadmium.Kube.Fake`), so that the pods one invents are the pods the other measures.

  Everything here is a pure function of the Kubernetes node name.
  """

  alias Cadmium.Kube.Pod

  @mi 1024 * 1024

  # profile describes how the synthetic source should make the pod behave relative to
  # its requests: :steady (~60% of request), :bursty (swings 0.5x-3x), :throttled
  # (pinned at its CPU limit, heavily throttled), :leaky (memory creeps up to 2.5x).
  @workloads [
    %{
      ns: "shop",
      kind: "ReplicaSet",
      owner: "web-7d9f8b6c5",
      per_node: 2,
      cpu: 250,
      mem: 256,
      profile: :bursty
    },
    %{
      ns: "shop",
      kind: "ReplicaSet",
      owner: "api-5c7b9d4f8",
      per_node: 2,
      cpu: 500,
      mem: 512,
      profile: :throttled,
      cpu_limit: 600
    },
    %{
      ns: "shop",
      kind: "ReplicaSet",
      owner: "checkout-6b8c7d9f4",
      per_node: 1,
      cpu: 200,
      mem: 256,
      profile: :steady,
      pdb: true
    },
    %{
      ns: "data",
      kind: "ReplicaSet",
      owner: "indexer-84d5f6c7b",
      per_node: 1,
      cpu: 300,
      mem: 512,
      profile: :leaky
    },
    %{
      ns: "data",
      kind: "StatefulSet",
      owner: "cache",
      per_node: 1,
      cpu: 500,
      mem: 1024,
      profile: :steady,
      local_storage: true
    },
    %{
      ns: "batch",
      kind: "Job",
      owner: "report-28391",
      per_node: 1,
      cpu: 1000,
      mem: 512,
      profile: :bursty
    },
    %{
      ns: "monitoring",
      kind: "DaemonSet",
      owner: "node-exporter",
      per_node: 1,
      cpu: 50,
      mem: 64,
      profile: :steady
    },
    %{
      ns: "kube-system",
      kind: "DaemonSet",
      owner: "kube-proxy",
      per_node: 1,
      cpu: 100,
      mem: 128,
      profile: :steady
    }
  ]

  @doc """
  Workload templates. Keys: `:ns`, `:kind`, `:owner`, `:per_node`, `:cpu` (request,
  millicores), `:mem` (request, MiB), `:profile`, and optionally `:cpu_limit`,
  `:local_storage`, `:pdb` (true = covered by a PDB that currently allows no disruptions).
  """
  def workloads, do: @workloads

  @doc "The pods that exist on `node_name` in the demo cluster."
  @spec pods(String.t()) :: [Pod.t()]
  def pods(node_name) do
    for w <- @workloads, i <- 1..w.per_node do
      name = "#{w.owner}-#{suffix(node_name, w.owner, i)}"

      %Pod{
        namespace: w.ns,
        name: name,
        uid: uid(node_name, w.ns, name),
        node_name: node_name,
        phase: "Running",
        labels: %{"app" => app_label(w)},
        owner_kind: w.kind,
        owner_name: w.owner,
        cpu_request_millis: w.cpu,
        cpu_limit_millis: w[:cpu_limit],
        memory_request_bytes: w.mem * @mi,
        memory_limit_bytes: nil,
        qos_class: "Burstable",
        local_storage?: w[:local_storage] == true,
        created_at: ~U[2026-01-01 00:00:00Z]
      }
    end
  end

  @doc "The behaviour profile for a demo pod UID on `node_name`, or nil if unknown."
  @spec profile(String.t(), String.t()) :: atom() | nil
  def profile(node_name, pod_uid) do
    Enum.find_value(@workloads, fn w ->
      Enum.find_value(1..w.per_node, fn i ->
        name = "#{w.owner}-#{suffix(node_name, w.owner, i)}"
        if uid(node_name, w.ns, name) == pod_uid, do: w.profile
      end)
    end)
  end

  @doc "The `app` label value for a workload template."
  def app_label(%{owner: owner, kind: "ReplicaSet"}),
    do: owner |> String.split("-") |> Enum.drop(-1) |> Enum.join("-")

  def app_label(%{owner: owner, kind: "Job"}),
    do: owner |> String.split("-") |> Enum.drop(-1) |> Enum.join("-")

  def app_label(%{owner: owner}), do: owner

  defp suffix(node_name, owner, i) do
    :crypto.hash(:md5, "#{node_name}/#{owner}/#{i}")
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 5)
  end

  defp uid(node_name, ns, name) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      :crypto.hash(:md5, "#{node_name}/#{ns}/#{name}") |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end
end
