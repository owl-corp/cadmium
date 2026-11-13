defmodule Cadmium.Valence.NodeScore do
  @moduledoc """
  The compact pressure summary each agent broadcasts to the mesh.

  `score` is 0.0..100.0 (higher = hotter) and is the max-weighted blend of the
  `components`, each of which is also 0.0..100.0.
  """

  @type t :: %__MODULE__{
          k8s_node: String.t(),
          beam_node: node(),
          score: float(),
          components: %{cpu: float(), memory: float(), io: float()},
          pod_count: non_neg_integer(),
          ts: integer()
        }

  @enforce_keys [:k8s_node, :beam_node, :score, :ts]
  defstruct [
    :k8s_node,
    :beam_node,
    :score,
    :ts,
    components: %{cpu: 0.0, memory: 0.0, io: 0.0},
    pod_count: 0
  ]
end
