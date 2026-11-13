defmodule Cadmium.Isotope.Source do
  @moduledoc """
  Where the sampler gets its raw readings from.

  A source returns *raw* values: cumulative kernel counters (CPU time, throttled periods,
  IO bytes, page faults) and instantaneous gauges (PSI averages, memory). It never
  computes rates; `Cadmium.Isotope.Derive` does that from two consecutive readings, so
  every source runs through the same derivation code.

  Any map, or any field within one, may be `nil` when the host does not expose it.
  """

  alias Cadmium.Isotope.Parser

  @typedoc "Raw host-level values."
  @type node_raw :: %{
          # /proc/stat aggregate cpu line, cumulative jiffies
          cpu: %{busy: non_neg_integer(), total: non_neg_integer()} | nil,
          # cpu.stat of the kubepods root cgroup
          kubepods_cpu: Parser.cpu_stat() | nil,
          psi_cpu: Parser.pressure() | nil,
          psi_memory: Parser.pressure() | nil,
          psi_io: Parser.pressure() | nil,
          memory: %{mem_total_bytes: integer() | nil, mem_available_bytes: integer() | nil} | nil,
          load: %{load1: float()} | nil,
          vm: %{pgmajfault: integer() | nil} | nil,
          io: Parser.io_stat() | nil
        }

  @typedoc "Raw values for one pod-level cgroup."
  @type pod_raw :: %{
          cpu: Parser.cpu_stat() | nil,
          psi_cpu: Parser.pressure() | nil,
          psi_memory: Parser.pressure() | nil,
          psi_io: Parser.pressure() | nil,
          io: Parser.io_stat() | nil,
          memory_current: non_neg_integer() | nil,
          memory_stat: %{pgmajfault: integer() | nil, pgfault: integer() | nil} | nil
        }

  @typedoc "One reading: the node plus every pod cgroup present, keyed by dashed pod UID."
  @type reading :: %{node: node_raw(), pods: %{String.t() => pod_raw()}}

  @type state :: term()

  @doc """
  Builds the source state. `opts` is the `config :cadmium, Cadmium.Isotope` keyword list
  merged with whatever was passed to the sampler (so `:cgroup_root`, `:proc_root`, ...).
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc "Takes one reading."
  @callback read(state()) :: {:ok, reading(), state()} | {:error, term(), state()}
end
