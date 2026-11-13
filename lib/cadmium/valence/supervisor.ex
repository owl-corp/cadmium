defmodule Cadmium.Valence.Supervisor do
  @moduledoc """
  Supervises libcluster, the cluster-state table, the pod cache and the score broadcaster.

  libcluster is only started when `config :cadmium, Cadmium.Valence, topologies: [...]`
  is non-empty. `opts` may carry `:topologies`, `:cluster_state`, `:pod_cache` and
  `:broadcaster` keyword lists that are passed to the respective children.
  """
  use Supervisor

  alias Cadmium.Valence.{Broadcaster, ClusterState}
  alias Cadmium.Workloads.PodCache

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Application.get_env(:cadmium, Cadmium.Valence, [])

    cluster =
      case Keyword.get(opts, :topologies, config[:topologies]) do
        empty when empty in [nil, []] -> []
        topologies -> [{Cluster.Supervisor, [topologies, [name: Cadmium.ClusterSupervisor]]}]
      end

    children =
      cluster ++
        [
          {ClusterState, Keyword.get(opts, :cluster_state, [])},
          {PodCache, Keyword.get(opts, :pod_cache, [])},
          {Broadcaster, Keyword.get(opts, :broadcaster, [])}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
