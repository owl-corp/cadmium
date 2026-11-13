defmodule Cadmium.Isotope.PodSample do
  @moduledoc """
  One per-second snapshot of a single pod's cgroup, keyed by the Kubernetes pod UID
  (dashed form, e.g. `"0f5c2a1e-...-9b"`), which is what appears in the kubepods cgroup path.
  """

  @type t :: %__MODULE__{
          pod_uid: String.t(),
          ts: integer(),
          cpu_usage_millis: float() | nil,
          cpu_throttled_ratio: float() | nil,
          memory_bytes: non_neg_integer() | nil,
          psi_cpu_some: float() | nil,
          psi_memory_some: float() | nil,
          psi_io_some: float() | nil,
          major_faults_per_s: float() | nil,
          io_bytes_per_s: float() | nil
        }

  @enforce_keys [:pod_uid, :ts]
  defstruct [
    :pod_uid,
    :ts,
    # actual CPU consumption in millicores (usage_usec delta)
    :cpu_usage_millis,
    # nr_throttled / nr_periods over the last interval, 0.0..1.0
    :cpu_throttled_ratio,
    # memory.current
    :memory_bytes,
    :psi_cpu_some,
    :psi_memory_some,
    :psi_io_some,
    :major_faults_per_s,
    # read + write
    :io_bytes_per_s
  ]
end
