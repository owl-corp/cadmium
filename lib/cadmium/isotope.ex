defmodule Cadmium.Isotope do
  @moduledoc """
  Kernel-level telemetry for the local host.

  A sampler reads cgroups v2 and /proc once per interval, keeps raw samples in ETS ring
  buffers on this node only, and publishes each node sample on the local PubSub topic
  `topic/0` as `{:isotope_sample, %Cadmium.Isotope.NodeSample{}}` (local broadcast only;
  raw samples never leave the node).

  This module is the public contract. Other subsystems must only call these functions.
  """

  alias Cadmium.Isotope.{NodeSample, PodSample}

  @topic "isotope:samples"

  @doc "PubSub topic (on `Cadmium.PubSub`) carrying `{:isotope_sample, %NodeSample{}}`."
  def topic, do: @topic

  @doc "Subscribes the caller to local node samples."
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @topic)

  @doc "Most recent node sample, or nil before the first tick."
  @spec latest() :: NodeSample.t() | nil
  def latest, do: nil

  @doc "Up to `limit` most recent node samples, oldest first."
  @spec history(pos_integer()) :: [NodeSample.t()]
  def history(_limit \\ 60), do: []

  @doc "Latest sample for every pod cgroup currently present on this host."
  @spec pod_samples() :: [PodSample.t()]
  def pod_samples, do: []

  @doc "Up to `limit` most recent samples for one pod, oldest first."
  @spec pod_history(String.t(), pos_integer()) :: [PodSample.t()]
  def pod_history(_pod_uid, _limit \\ 60), do: []
end
