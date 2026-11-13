defmodule CadmiumWeb.Dashboard.Data.DemoTicker do
  @moduledoc """
  Publishes `CadmiumWeb.Dashboard.Data.Demo` data on the real PubSub topics, with the
  message shapes of the subsystem contracts, so the dashboard's live-update paths can be
  watched without a cluster. DEV ONLY: started lazily, and only by the Demo backend.
  """
  use GenServer

  alias Cadmium.Catalyst.Action
  alias CadmiumWeb.Dashboard.Data.Demo

  @isotope_ms 1_000
  @cluster_every 2
  @action_every 20

  @doc "Starts the ticker (unsupervised) unless it is already running."
  def ensure_started do
    if Process.whereis(__MODULE__) == nil do
      GenServer.start(__MODULE__, :ok, name: __MODULE__)
    end

    :ok
  end

  def broadcast(topic, message) do
    Phoenix.PubSub.local_broadcast(Cadmium.PubSub, topic, message)
  end

  @impl true
  def init(:ok) do
    Process.send_after(self(), :tick, @isotope_ms)
    {:ok, 0}
  end

  @impl true
  def handle_info(:tick, count) do
    Process.send_after(self(), :tick, @isotope_ms)
    now = System.system_time(:millisecond)

    broadcast(Cadmium.Isotope.topic(), {:isotope_sample, Demo.isotope_sample(now)})

    if rem(count, @cluster_every) == 0 do
      broadcast(Cadmium.Valence.cluster_topic(), {:cluster_updated, Demo.nodes()})
    end

    if rem(count, @action_every) == @action_every - 1 do
      status = Demo.status()
      broadcast(Cadmium.Catalyst.topic(), {:catalyst_status, status})

      if status.enabled? do
        broadcast(Cadmium.Catalyst.topic(), {:catalyst_action, action(status, now)})
      end
    end

    {:noreply, count + 1}
  end

  defp action(status, now) do
    move = status.last_plan && List.first(status.last_plan.moves)

    %Action{
      id: "demo-live-#{System.unique_integer([:positive])}",
      ts: now,
      type: :evict,
      dry_run?: status.dry_run?,
      actor: status.leader,
      node: move && move.from_node,
      namespace: move && move.workload.pod.namespace,
      pod: move && move.workload.pod.name,
      reason: (move && move.reason) || "demo tick",
      result: if(status.dry_run?, do: :simulated, else: :ok)
    }
  end
end
