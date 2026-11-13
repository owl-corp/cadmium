defmodule Cadmium do
  @moduledoc """
  Cadmium - a runtime-aware Kubernetes cluster rebalancer.

    * `Cadmium.Isotope`   - per-host kernel telemetry (cgroups v2, PSI, /proc)
    * `Cadmium.Valence`   - the BEAM mesh and shared node pressure scores
    * `Cadmium.Workloads` - request-vs-reality view of pods
    * `Cadmium.Kube`      - Kubernetes API access
    * `Cadmium.Leader`    - Lease-based leader election
    * `Cadmium.Catalyst`  - disruption-aware rebalancing
  """

  @doc "Name of the Kubernetes node this agent runs on (`NODE_NAME`, else the hostname)."
  @spec node_name() :: String.t()
  def node_name do
    case Application.get_env(:cadmium, :node_name) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        {:ok, host} = :inet.gethostname()
        List.to_string(host)
    end
  end
end
