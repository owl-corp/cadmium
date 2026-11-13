defmodule Cadmium.Valence do
  @moduledoc """
  The distributed mesh: cluster membership (libcluster) and the shared view of
  per-node pressure scores.

  Each agent derives a `Cadmium.Valence.NodeScore` from its local Isotope samples and
  broadcasts it cluster-wide on `scores_topic/0` as `{:node_score, %NodeScore{}}`.
  Every agent keeps the latest score (and a short history) for every node, drops nodes
  that go stale, and emits `{:cluster_updated, [%NodeScore{}]}` on `cluster_topic/0`
  (local broadcast) whenever its view changes.

  This module is the public contract. Other subsystems must only call these functions.
  """

  alias Cadmium.Valence.NodeScore

  @scores_topic "valence:scores"
  @cluster_topic "valence:cluster"

  def scores_topic, do: @scores_topic
  def cluster_topic, do: @cluster_topic

  @doc "Subscribes the caller to `{:cluster_updated, [%NodeScore{}]}`."
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @cluster_topic)

  @doc "Latest score for every live node, sorted by `k8s_node`."
  @spec nodes() :: [NodeScore.t()]
  def nodes, do: []

  @doc "Latest score for one Kubernetes node."
  @spec node_score(String.t()) :: NodeScore.t() | nil
  def node_score(_k8s_node), do: nil

  @doc "Up to `limit` most recent scores for one node, oldest first."
  @spec history(String.t(), pos_integer()) :: [NodeScore.t()]
  def history(_k8s_node, _limit \\ 120), do: []

  @doc "BEAM node of the agent running on the given Kubernetes node, if connected."
  @spec beam_node_for(String.t()) :: node() | nil
  def beam_node_for(_k8s_node), do: nil
end
