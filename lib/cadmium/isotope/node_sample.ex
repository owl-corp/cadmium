defmodule Cadmium.Isotope.NodeSample do
  @moduledoc """
  One per-second snapshot of host-level pressure, as read from cgroups v2 and /proc.

  All `*_ratio` fields are 0.0..1.0. PSI fields are the kernel's `avg10` percentages
  (0.0..100.0). Rates are per second, derived from the delta against the previous sample.
  A field is `nil` when the kernel does not expose it on this host.
  """

  @type t :: %__MODULE__{
          ts: integer(),
          cpu_usage_ratio: float() | nil,
          cpu_throttled_ratio: float() | nil,
          psi_cpu_some: float() | nil,
          psi_memory_some: float() | nil,
          psi_memory_full: float() | nil,
          psi_io_some: float() | nil,
          psi_io_full: float() | nil,
          memory_used_ratio: float() | nil,
          major_faults_per_s: float() | nil,
          io_read_bytes_per_s: float() | nil,
          io_write_bytes_per_s: float() | nil,
          load1: float() | nil
        }

  @enforce_keys [:ts]
  defstruct [
    # System.system_time(:millisecond)
    :ts,
    # host CPU busy fraction across all cores
    :cpu_usage_ratio,
    # fraction of CFS periods throttled across kubepods (nr_throttled / nr_periods delta)
    :cpu_throttled_ratio,
    :psi_cpu_some,
    :psi_memory_some,
    :psi_memory_full,
    :psi_io_some,
    :psi_io_full,
    :memory_used_ratio,
    :major_faults_per_s,
    :io_read_bytes_per_s,
    :io_write_bytes_per_s,
    :load1
  ]
end
