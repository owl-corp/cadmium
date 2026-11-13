defmodule Cadmium.ValencePeer do
  @moduledoc """
  Helpers executed *on a `:peer` node* by the distributed Valence tests. They live in a
  compiled module (not the test file) so the peer can load them from the code path.
  """

  alias Cadmium.Isotope.NodeSample

  @doc """
  Boots a minimal Cadmium agent on the calling node: PubSub, the pod cache (backed by
  `Cadmium.ValenceKubeStub` returning `pods`) and a fast score broadcaster. The processes
  hang off a holder process so they outlive the `:erpc` call that started them.
  """
  def start_agent(k8s_node, pods) do
    parent = self()

    holder =
      spawn(fn ->
        Application.put_env(:cadmium, :node_name, k8s_node)
        Application.put_env(:cadmium, :kube_client, Cadmium.ValenceKubeStub)
        Cadmium.ValenceKubeStub.put({:ok, pods})
        {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

        {:ok, _sup} =
          Supervisor.start_link(
            [
              {Phoenix.PubSub, name: Cadmium.PubSub},
              {Cadmium.Workloads.PodCache, interval_ms: :infinity},
              {Cadmium.Valence.Broadcaster, interval_ms: 50, subscribe: &__MODULE__.noop/0}
            ],
            strategy: :one_for_one
          )

        send(parent, {:agent_started, self()})
        Process.sleep(:infinity)
      end)

    receive do
      {:agent_started, ^holder} -> :ok
    after
      15_000 -> {:error, :timeout}
    end
  end

  @doc "Feeds the peer's broadcaster one node sample stamped with the current time."
  def feed(fields) do
    sample = struct!(NodeSample, [ts: System.system_time(:millisecond)] ++ fields)
    send(Cadmium.Valence.Broadcaster, {:isotope_sample, sample})
    :ok
  end

  def noop, do: :ok
end
