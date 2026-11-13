defmodule Cadmium.Workload do
  @moduledoc """
  A running pod joined with its measured runtime behaviour: "request vs. reality".

  Drift ratios are actual / requested (1.0 = using exactly the request, 3.0 = using
  three times the request). They are `nil` when the pod declares no request or no
  sample exists yet.
  """

  alias Cadmium.Isotope.PodSample
  alias Cadmium.Kube.Pod

  @type t :: %__MODULE__{
          pod: Pod.t(),
          k8s_node: String.t(),
          sample: PodSample.t() | nil,
          cpu_drift: float() | nil,
          memory_drift: float() | nil
        }

  @enforce_keys [:pod, :k8s_node]
  defstruct [:pod, :k8s_node, :sample, :cpu_drift, :memory_drift]
end
