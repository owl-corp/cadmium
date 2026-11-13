defmodule Cadmium.Isotope.Derive do
  @moduledoc """
  Turns two consecutive raw readings (see `Cadmium.Isotope.Source`) into samples.

  Gauges come straight from the current reading. Rates and ratios come from the delta
  against the previous reading and are `nil` - never negative, never a guess - when there
  is no previous reading (first tick, new pod), when a counter went backwards (cgroup
  recreated, counter reset) or when no time has passed.
  """

  alias Cadmium.Isotope.{NodeSample, PodSample}

  @doc "Builds a node sample. `dt_ms` is the time since `prev` was read (nil on the first tick)."
  @spec node_sample(map() | nil, map(), number() | nil, integer()) :: NodeSample.t()
  def node_sample(prev, cur, dt_ms, ts) do
    %NodeSample{
      ts: ts,
      cpu_usage_ratio:
        ratio(delta(prev, cur, [:cpu, :busy]), delta(prev, cur, [:cpu, :total]), nil),
      cpu_throttled_ratio: throttled_ratio(prev, cur, :kubepods_cpu),
      psi_cpu_some: gauge(cur, [:psi_cpu, :some, :avg10]),
      psi_memory_some: gauge(cur, [:psi_memory, :some, :avg10]),
      psi_memory_full: gauge(cur, [:psi_memory, :full, :avg10]),
      psi_io_some: gauge(cur, [:psi_io, :some, :avg10]),
      psi_io_full: gauge(cur, [:psi_io, :full, :avg10]),
      memory_used_ratio: memory_used_ratio(cur),
      major_faults_per_s: rate(delta(prev, cur, [:vm, :pgmajfault]), dt_ms),
      io_read_bytes_per_s: rate(delta(prev, cur, [:io, :rbytes]), dt_ms),
      io_write_bytes_per_s: rate(delta(prev, cur, [:io, :wbytes]), dt_ms),
      load1: gauge(cur, [:load, :load1])
    }
  end

  @doc "Builds a pod sample. `prev` is nil for a pod first seen in this reading."
  @spec pod_sample(String.t(), map() | nil, map(), number() | nil, integer()) :: PodSample.t()
  def pod_sample(pod_uid, prev, cur, dt_ms, ts) do
    %PodSample{
      pod_uid: pod_uid,
      ts: ts,
      # usec of CPU per ms of wall time is exactly millicores
      cpu_usage_millis: per_ms(delta(prev, cur, [:cpu, :usage_usec]), dt_ms),
      cpu_throttled_ratio: throttled_ratio(prev, cur, :cpu),
      memory_bytes: integer(cur, [:memory_current]),
      psi_cpu_some: gauge(cur, [:psi_cpu, :some, :avg10]),
      psi_memory_some: gauge(cur, [:psi_memory, :some, :avg10]),
      psi_io_some: gauge(cur, [:psi_io, :some, :avg10]),
      major_faults_per_s: rate(delta(prev, cur, [:memory_stat, :pgmajfault]), dt_ms),
      io_bytes_per_s:
        rate(sum(delta(prev, cur, [:io, :rbytes]), delta(prev, cur, [:io, :wbytes])), dt_ms)
    }
  end

  @doc "Counter delta at `path`; nil if either side is missing or the counter went backwards."
  @spec delta(map() | nil, map() | nil, [atom()]) :: number() | nil
  def delta(prev, cur, path) do
    with a when is_number(a) <- fetch(prev, path),
         b when is_number(b) and b >= a <- fetch(cur, path) do
      b - a
    else
      _ -> nil
    end
  end

  # nr_throttled / nr_periods over the interval. No CFS periods elapsed (no CPU limit, or
  # an idle cgroup) means nothing was throttled: 0.0, not nil.
  defp throttled_ratio(prev, cur, key) do
    ratio(delta(prev, cur, [key, :nr_throttled]), delta(prev, cur, [key, :nr_periods]), 0.0)
  end

  defp ratio(nil, _den, _when_zero), do: nil
  defp ratio(_num, nil, _when_zero), do: nil
  defp ratio(_num, den, when_zero) when den <= 0, do: when_zero
  defp ratio(num, den, _when_zero), do: clamp(num / den)

  defp rate(delta, dt_ms) do
    case per_ms(delta, dt_ms) do
      nil -> nil
      per_ms -> per_ms * 1000
    end
  end

  defp per_ms(delta, dt_ms) when is_number(delta) and is_number(dt_ms) and dt_ms > 0,
    do: delta / dt_ms

  defp per_ms(_delta, _dt_ms), do: nil

  defp sum(nil, _), do: nil
  defp sum(_, nil), do: nil
  defp sum(a, b), do: a + b

  defp memory_used_ratio(cur) do
    with total when is_number(total) and total > 0 <- fetch(cur, [:memory, :mem_total_bytes]),
         available when is_number(available) <- fetch(cur, [:memory, :mem_available_bytes]) do
      clamp(1.0 - available / total)
    else
      _ -> nil
    end
  end

  defp gauge(cur, path) do
    case fetch(cur, path) do
      n when is_number(n) -> n * 1.0
      _ -> nil
    end
  end

  defp integer(cur, path) do
    case fetch(cur, path) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp fetch(value, []), do: value
  defp fetch(%{} = map, [key | rest]), do: fetch(Map.get(map, key), rest)
  defp fetch(_, _), do: nil

  defp clamp(x), do: x |> max(0.0) |> min(1.0)
end
