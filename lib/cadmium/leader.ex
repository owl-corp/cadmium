defmodule Cadmium.Leader do
  @moduledoc """
  Leader election over a Kubernetes Lease (`coordination.k8s.io/v1`).

  One agent holds the lease and runs the Catalyst coordinator. The process acquires,
  renews and (on shutdown) releases the lease, and announces transitions on the local
  PubSub topic `topic/0` as `{:leadership, :acquired | :lost}`. The holder identity is
  `Cadmium.node_name/0`.

  Leadership must be reported as lost as soon as a renewal has not succeeded within the
  lease duration, even if the API server is unreachable.
  """

  @topic "leader"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @topic)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts), do: :ignore

  @doc "True when this agent currently holds a valid lease."
  @spec leader?() :: boolean()
  def leader?, do: false

  @doc "Identity (Kubernetes node name) of the current lease holder as last observed."
  @spec current() :: String.t() | nil
  def current, do: nil
end
