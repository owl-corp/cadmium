defmodule Cadmium.Workloads do
  @moduledoc """
  Request-vs-reality view of pods: Kubernetes pod metadata joined with Isotope pod samples.

  `local/0` covers pods on this host; `cluster/0` fans out to every connected agent.
  """

  alias Cadmium.Workload

  @doc "Workloads running on this agent's host."
  @spec local() :: [Workload.t()]
  def local, do: []

  @doc "Workloads across all reachable agents (unreachable nodes are skipped)."
  @spec cluster() :: [Workload.t()]
  def cluster, do: []

  @doc "Workloads on one Kubernetes node, fetched from the agent running there."
  @spec on_node(String.t()) :: [Workload.t()]
  def on_node(_k8s_node), do: []
end
