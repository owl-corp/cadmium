defmodule Cadmium.Isotope.Source.Synthetic do
  @moduledoc """
  Synthetic telemetry for machines without cgroups (macOS dev boxes, demos).

  It invents a host and measures the pods `Cadmium.Demo.pods/1` says run on this node,
  each behaving according to its `Cadmium.Demo.profile/2`:

    * `:steady` - CPU and memory around 60% of the request
    * `:bursty` - CPU swinging between 0.5x and 3x the request
    * `:throttled` - CPU pinned at its limit, most CFS periods throttled
    * `:leaky` - memory creeping from 0.6x to 2.5x the request, then resetting

  The readings have exactly the shape `Cadmium.Isotope.Source.Cgroup` produces -
  cumulative counters and PSI gauges - so the same derivation code runs in dev and prod.

  ## Node heat

  How loaded the node looks is driven by a single *heat* value in 0.0..1.0: a base that is
  a pure function of the node name (see `base_heat/1`), a slow sine drift (180 s period)
  and a little noise. Set `CADMIUM_SYNTHETIC_HEAT` (0.0-1.0) to override the base.

  Options: `:node_name` (default `Cadmium.node_name/0`), `:base_heat` (takes precedence
  over the environment variable), `:clock` (zero-arity fun returning milliseconds).
  """

  @behaviour Cadmium.Isotope.Source

  @ncpu 8
  @user_hz 100
  @mem_total 16 * 1024 * 1024 * 1024
  @mi 1024 * 1024
  @two_pi 2 * :math.pi()

  @drift_period_ms 180_000
  @drift_amplitude 0.12
  @noise_amplitude 0.03
  @burst_period_ms 45_000
  @leak_period_ms 240_000
  # CFS periods per second (cpu.cfs_period_us = 100ms)
  @periods_per_s 10
  @heat_salt 299

  @impl true
  def init(opts) do
    node_name = opts[:node_name] || Cadmium.node_name()
    hash = :erlang.phash2({:cadmium_synthetic, node_name}, 1_000_000)

    pods =
      for pod <- Cadmium.Demo.pods(node_name) do
        %{
          uid: pod.uid,
          profile: Cadmium.Demo.profile(node_name, pod.uid) || :steady,
          cpu_request: max(pod.cpu_request_millis, 10),
          cpu_limit: pod.cpu_limit_millis,
          memory_request: max(pod.memory_request_bytes, 16 * @mi),
          phase: :erlang.phash2(pod.uid, 1_000) / 1_000
        }
      end

    {:ok,
     %{
       node_name: node_name,
       base_heat: opts[:base_heat] || env_heat() || base_heat(node_name),
       phase: hash / 1_000_000 * @two_pi,
       rng: :rand.seed_s(:exsss, {hash, hash * 31 + 7, hash * 131 + 13}),
       clock: opts[:clock] || fn -> System.system_time(:millisecond) end,
       last_ms: nil,
       pods: pods,
       node_counters: %{},
       pod_counters: %{}
     }}
  end

  @impl true
  def read(state), do: read(state, state.clock.())

  @doc "Like `read/1` at an explicit time (milliseconds), for deterministic tests."
  @spec read(map(), integer()) :: {:ok, Cadmium.Isotope.Source.reading(), map()}
  def read(state, now_ms) do
    dt_s = if state.last_ms, do: max(now_ms - state.last_ms, 0) / 1000, else: 0.0
    {noise, rng} = noise(state.rng, @noise_amplitude)
    heat = heat(state, now_ms, noise)

    {pods, {pod_counters, rng}} =
      Enum.map_reduce(state.pods, {state.pod_counters, rng}, fn pod, {counters, rng} ->
        {jitter, rng} = noise(rng, 1.0)
        behaviour = behaviour(pod, now_ms, jitter)
        acc = advance(Map.get(counters, pod.uid, %{}), pod_rates(behaviour), dt_s)
        {{pod.uid, pod_raw(behaviour, acc)}, {Map.put(counters, pod.uid, acc), rng}}
      end)

    node_counters = advance(state.node_counters, node_rates(heat, length(pods)), dt_s)

    reading = %{node: node_raw(heat, state.base_heat, node_counters), pods: Map.new(pods)}

    {:ok, reading,
     %{
       state
       | last_ms: now_ms,
         rng: rng,
         node_counters: node_counters,
         pod_counters: pod_counters
     }}
  end

  @doc """
  The base heat of a node: a stable hash of its name, so a given node is consistently
  hot, warm or cool across restarts.

  The hash picks a band rather than a point on a line - cool (0.15..0.30, 40% of names),
  warm (0.45..0.55, 20%) or hot (0.78..0.90, 40%) - so a handful of nodes usually
  includes a clearly hot and a clearly cool one. The salt was chosen so the usual local
  trios (`node-a`/`node-b`/`node-c`, `node-1`/`node-2`/`node-3`, ...) are spread out.
  """
  @spec base_heat(String.t()) :: float()
  def base_heat(node_name) do
    u = :erlang.phash2({@heat_salt, node_name}, 1_000) / 999

    cond do
      u < 0.4 -> 0.15 + u / 0.4 * 0.15
      u < 0.6 -> 0.45 + (u - 0.4) / 0.2 * 0.10
      true -> 0.78 + (u - 0.6) / 0.4 * 0.12
    end
  end

  @doc "Heat of the node at `now_ms`: base + slow sine drift + `noise`, clamped to 0.0..1.0."
  @spec heat(map(), integer(), float()) :: float()
  def heat(%{base_heat: base, phase: phase}, now_ms, noise \\ 0.0) do
    drift = @drift_amplitude * :math.sin(@two_pi * now_ms / @drift_period_ms + phase)
    clamp(base + drift + noise)
  end

  # -- node ------------------------------------------------------------------------------

  # Per-second rates of the cumulative node counters at a given heat.
  defp node_rates(heat, pod_count) do
    jiffies = @ncpu * @user_hz
    periods = @periods_per_s * max(pod_count, 1)
    read_bytes = (1 + 30 * heat) * @mi
    write_bytes = (2 + 50 * heat) * @mi

    %{
      cpu_total: jiffies,
      cpu_busy: jiffies * clamp(0.08 + 0.87 * heat),
      kubepods_usage_usec: 1_000_000 * @ncpu * clamp(0.05 + 0.8 * heat),
      nr_periods: periods,
      nr_throttled: periods * throttled(heat),
      throttled_usec: periods * throttled(heat) * 60_000,
      pgmajfault: 2 + over(heat, 0.55) * 800,
      pgfault: 5_000 + 40_000 * heat,
      rbytes: read_bytes,
      wbytes: write_bytes,
      rios: read_bytes / 16_384,
      wios: write_bytes / 16_384,
      psi_cpu_usec: psi_cpu(heat) * 10_000,
      psi_memory_usec: psi_memory(heat) * 10_000,
      psi_io_usec: psi_io(heat) * 10_000
    }
  end

  defp node_raw(heat, base_heat, c) do
    %{
      cpu: %{busy: int(c, :cpu_busy), total: int(c, :cpu_total)},
      kubepods_cpu: %{
        usage_usec: int(c, :kubepods_usage_usec),
        nr_periods: int(c, :nr_periods),
        nr_throttled: int(c, :nr_throttled),
        throttled_usec: int(c, :throttled_usec)
      },
      psi_cpu: pressure(psi_cpu(heat), psi_cpu(base_heat), int(c, :psi_cpu_usec), 0.0),
      psi_memory:
        pressure(psi_memory(heat), psi_memory(base_heat), int(c, :psi_memory_usec), 0.5),
      psi_io: pressure(psi_io(heat), psi_io(base_heat), int(c, :psi_io_usec), 0.4),
      memory: %{
        mem_total_bytes: @mem_total,
        mem_available_bytes: round(@mem_total * (1 - clamp(0.30 + 0.55 * heat)))
      },
      load: %{
        load1: Float.round(@ncpu * (0.1 + 1.6 * heat), 2),
        load5: Float.round(@ncpu * (0.1 + 1.6 * base_heat), 2),
        load15: Float.round(@ncpu * (0.1 + 1.6 * base_heat), 2)
      },
      vm: %{pgmajfault: int(c, :pgmajfault), pgfault: int(c, :pgfault)},
      io: %{
        rbytes: int(c, :rbytes),
        wbytes: int(c, :wbytes),
        rios: int(c, :rios),
        wios: int(c, :wios)
      }
    }
  end

  # Calm below ~0.4 heat, clearly under pressure above ~0.75.
  defp throttled(heat), do: clamp(0.02 + over(heat, 0.45) * 1.3) |> min(0.9)
  defp psi_cpu(heat), do: 100 * clamp(:math.pow(over(heat, 0.35), 1.3) * 1.6)
  defp psi_memory(heat), do: 100 * clamp(over(heat, 0.55) * 0.9)
  defp psi_io(heat), do: 100 * clamp(over(heat, 0.40) * 0.7)

  # -- pods ------------------------------------------------------------------------------

  # What a pod is doing right now: CPU in millicores, memory in bytes, the fraction of CFS
  # periods throttled, PSI percentages and fault/IO rates. `jitter` is -1.0..1.0.
  defp behaviour(%{profile: :bursty} = pod, now_ms, jitter) do
    swing = wave(now_ms, @burst_period_ms, pod.phase)

    %{
      base(pod)
      | cpu_millis: pod.cpu_request * (0.5 + 2.5 * swing),
        memory_bytes: pod.memory_request * (0.7 + 0.4 * swing + 0.02 * jitter),
        psi_cpu: 30 * swing * swing,
        io_bytes: (0.2 + 4 * swing) * @mi
    }
  end

  defp behaviour(%{profile: :throttled} = pod, _now_ms, jitter) do
    %{
      base(pod)
      | cpu_millis: (pod.cpu_limit || pod.cpu_request) * 1.0,
        memory_bytes: pod.memory_request * (0.8 + 0.02 * jitter),
        limited?: true,
        throttled: clamp(0.85 + 0.05 * jitter),
        psi_cpu: 55 + 10 * jitter
    }
  end

  defp behaviour(%{profile: :leaky} = pod, now_ms, jitter) do
    offset = round(pod.phase * @leak_period_ms)
    leaked = Integer.mod(now_ms + offset, @leak_period_ms) / @leak_period_ms

    %{
      base(pod)
      | cpu_millis: pod.cpu_request * (0.6 + 0.05 * jitter),
        memory_bytes: pod.memory_request * (0.6 + 1.9 * leaked),
        psi_memory: 25 * leaked * leaked,
        major_faults: 40 * leaked
    }
  end

  defp behaviour(pod, _now_ms, jitter) do
    %{
      base(pod)
      | cpu_millis: pod.cpu_request * (0.6 + 0.05 * jitter),
        memory_bytes: pod.memory_request * (0.6 + 0.02 * jitter)
    }
  end

  defp base(pod) do
    %{
      cpu_millis: 0.0,
      memory_bytes: 0.0,
      limited?: pod.cpu_limit != nil,
      throttled: 0.0,
      psi_cpu: 0.0,
      psi_memory: 0.0,
      psi_io: 0.0,
      major_faults: 0.0,
      io_bytes: 0.2 * @mi
    }
  end

  defp pod_rates(b) do
    # Only pods with a CPU limit have CFS periods at all.
    periods = if b.limited?, do: @periods_per_s, else: 0

    %{
      usage_usec: b.cpu_millis * 1_000,
      nr_periods: periods,
      nr_throttled: periods * b.throttled,
      throttled_usec: periods * b.throttled * 60_000,
      pgmajfault: b.major_faults,
      pgfault: 200 + b.cpu_millis,
      rbytes: b.io_bytes * 0.4,
      wbytes: b.io_bytes * 0.6,
      rios: b.io_bytes * 0.4 / 16_384,
      wios: b.io_bytes * 0.6 / 16_384,
      psi_cpu_usec: b.psi_cpu * 10_000,
      psi_memory_usec: b.psi_memory * 10_000,
      psi_io_usec: b.psi_io * 10_000
    }
  end

  defp pod_raw(b, c) do
    %{
      cpu: %{
        usage_usec: int(c, :usage_usec),
        nr_periods: int(c, :nr_periods),
        nr_throttled: int(c, :nr_throttled),
        throttled_usec: int(c, :throttled_usec)
      },
      psi_cpu: pressure(b.psi_cpu, b.psi_cpu, int(c, :psi_cpu_usec), 0.0),
      psi_memory: pressure(b.psi_memory, b.psi_memory, int(c, :psi_memory_usec), 0.5),
      psi_io: pressure(b.psi_io, b.psi_io, int(c, :psi_io_usec), 0.4),
      io: %{
        rbytes: int(c, :rbytes),
        wbytes: int(c, :wbytes),
        rios: int(c, :rios),
        wios: int(c, :wios)
      },
      memory_current: round(b.memory_bytes),
      memory_stat: %{pgmajfault: int(c, :pgmajfault), pgfault: int(c, :pgfault)}
    }
  end

  # -- helpers ---------------------------------------------------------------------------

  # Adds rate * dt to every cumulative counter (kept as floats; truncated when emitted).
  defp advance(counters, rates, dt_s) do
    Map.new(rates, fn {key, rate} -> {key, Map.get(counters, key, 0.0) + rate * dt_s} end)
  end

  defp int(counters, key), do: trunc(Map.fetch!(counters, key))

  # A PSI file: `some` at the given avg10, `full` at `full_ratio` of it.
  defp pressure(avg10, slow_avg, total_usec, full_ratio) do
    line = fn ratio, total ->
      %{
        avg10: Float.round(avg10 * ratio, 2),
        avg60: Float.round(slow_avg * ratio, 2),
        avg300: Float.round(slow_avg * ratio, 2),
        total: trunc(total * ratio)
      }
    end

    %{some: line.(1.0, total_usec), full: line.(full_ratio, total_usec)}
  end

  # 0.0..1.0 sine wave
  defp wave(now_ms, period_ms, phase) do
    0.5 + 0.5 * :math.sin(@two_pi * (now_ms / period_ms + phase))
  end

  defp noise(rng, amplitude) do
    {x, rng} = :rand.uniform_s(rng)
    {(2 * x - 1) * amplitude, rng}
  end

  defp over(value, threshold), do: max(value - threshold, 0.0)
  defp clamp(x), do: x |> max(0.0) |> min(1.0)

  defp env_heat do
    with value when is_binary(value) <- System.get_env("CADMIUM_SYNTHETIC_HEAT"),
         {heat, _} <- Float.parse(String.trim(value)) do
      clamp(heat)
    else
      _ -> nil
    end
  end
end
