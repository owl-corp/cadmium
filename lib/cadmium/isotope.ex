defmodule Cadmium.Isotope do
  @moduledoc """
  Kernel-level telemetry for the local host.

  A sampler reads cgroups v2 and /proc once per interval, keeps raw samples in ETS ring
  buffers on this node only, and publishes each node sample on the local PubSub topic
  `topic/0` as `{:isotope_sample, %Cadmium.Isotope.NodeSample{}}` (local broadcast only;
  raw samples never leave the node).

  This module is the public contract. Other subsystems must only call these functions.
  They read ETS directly (never the sampler process) and return empty values when the
  sampler is not running.
  """

  alias Cadmium.Isotope.{NodeSample, PodSample, RingBuffer, Sampler}

  @topic "isotope:samples"
  @table Cadmium.Isotope.Samples

  @doc "PubSub topic (on `Cadmium.PubSub`) carrying `{:isotope_sample, %NodeSample{}}`."
  def topic, do: @topic

  @doc false
  # Name of the ring buffer the supervised sampler writes to.
  def table, do: @table

  @doc "Subscribes the caller to local node samples."
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @topic)

  @doc "Most recent node sample, or nil before the first tick."
  @spec latest() :: NodeSample.t() | nil
  def latest, do: RingBuffer.latest(@table, Sampler.node_series())

  @doc "Up to `limit` most recent node samples, oldest first."
  @spec history(pos_integer()) :: [NodeSample.t()]
  def history(limit \\ 60), do: RingBuffer.last(@table, Sampler.node_series(), limit)

  @doc "Latest sample for every pod cgroup currently present on this host."
  @spec pod_samples() :: [PodSample.t()]
  def pod_samples do
    for {:pod, _uid} = series <- RingBuffer.series(@table),
        sample = RingBuffer.latest(@table, series),
        do: sample
  end

  @doc "Up to `limit` most recent samples for one pod, oldest first."
  @spec pod_history(String.t(), pos_integer()) :: [PodSample.t()]
  def pod_history(pod_uid, limit \\ 60),
    do: RingBuffer.last(@table, Sampler.pod_series(pod_uid), limit)
end
