defmodule Cadmium.Valence.Score do
  @moduledoc """
  Pure pressure scoring: turns a window of recent `Cadmium.Isotope.NodeSample`s into
  component scores (cpu / memory / io) and one overall score, all `0.0..100.0`
  (higher = hotter).

  The guiding idea is that *contention* matters more than *utilisation*: a node at 90%
  CPU with nobody waiting is healthy, a node at 60% CPU whose tasks stall is not. So the
  kernel's pressure signals carry 80% of the cpu and memory components (100% of io) and
  plain usage only 20%.

  ## 1. Smoothing

  Samples older than `:window_ms` (default 10s) relative to the newest are dropped and
  every field is reduced to an exponentially time-weighted mean:

      w_i = e^(-(ts_newest - ts_i) / tau)        value = sum(w_i * x_i) / sum(w_i)

  with `:tau_ms` defaulting to 5s. With one sample per second over a full window the
  newest second carries about 21% of the weight and the oldest about 3%, so one spiky
  second cannot make a node "hot", while sustained pressure shows up within a few
  seconds. Weighting by age (rather than by position) keeps this independent of the
  sampling interval. `nil` readings are skipped per field; a field that is `nil` in
  every sample stays `nil`.

  ## 2. Signal curves (each yields 0..100)

      saturate(x, knee) = 100 * (1 - e^(-x / knee))               # 63 at the knee, then flattens
      ramp(x, from)     = 100 * clamp((x - from) / (1 - from))^2  # 0 below `from`, convex above

  | component | signal                | curve               | weight |
  |-----------|-----------------------|---------------------|--------|
  | cpu       | `psi_cpu_some`        | `saturate(x, 20)`   | 0.5    |
  | cpu       | `cpu_throttled_ratio` | `saturate(x, 0.2)`  | 0.3    |
  | cpu       | `cpu_usage_ratio`     | `ramp(x, 0.5)`      | 0.2    |
  | memory    | `psi_memory_some`     | `saturate(x, 10)`   | 0.3    |
  | memory    | `psi_memory_full`     | `saturate(x, 5)`    | 0.3    |
  | memory    | `major_faults_per_s`  | `saturate(x, 200)`  | 0.2    |
  | memory    | `memory_used_ratio`   | `ramp(x, 0.6)`      | 0.2    |
  | io        | `psi_io_some`         | `saturate(x, 20)`   | 0.5    |
  | io        | `psi_io_full`         | `saturate(x, 10)`   | 0.5    |

  Memory and "full" stalls have smaller knees because they are rarer and far more
  damaging than CPU "some" pressure.

  ## 3. Components

      component = sum(w_i * curve_i) / sum(w_i)     over the signals that are not nil

  i.e. missing kernel features are ignored and the remaining weights renormalised.
  A component with no signals at all is reported as `0.0` and excluded from the overall.

  ## 4. Overall

      overall = clamp(0.8 * max(components) + 0.2 * weighted_mean(components), 0, 100)

  with mean weights cpu 0.4, memory 0.4, io 0.2 (renormalised over the components that
  exist). The worst resource dominates: one starved resource makes a node hot even when
  the others are idle (a saturated cpu or memory alone yields 88, io alone 84), and
  pressure on several resources at once pushes the score towards 100.
  """

  alias Cadmium.Isotope.NodeSample

  @type components :: %{cpu: float(), memory: float(), io: float()}
  @type result :: %{score: float(), components: components()}
  @type signals :: %{optional(atom()) => float() | nil}

  @default_tau_ms 5_000
  @default_window_ms 10_000

  @fields [
    :cpu_usage_ratio,
    :cpu_throttled_ratio,
    :psi_cpu_some,
    :psi_memory_some,
    :psi_memory_full,
    :psi_io_some,
    :psi_io_full,
    :memory_used_ratio,
    :major_faults_per_s
  ]

  # {field, curve, curve parameter, weight}
  @cpu [
    {:psi_cpu_some, :saturate, 20.0, 0.5},
    {:cpu_throttled_ratio, :saturate, 0.2, 0.3},
    {:cpu_usage_ratio, :ramp, 0.5, 0.2}
  ]
  @memory [
    {:psi_memory_some, :saturate, 10.0, 0.3},
    {:psi_memory_full, :saturate, 5.0, 0.3},
    {:major_faults_per_s, :saturate, 200.0, 0.2},
    {:memory_used_ratio, :ramp, 0.6, 0.2}
  ]
  @io [
    {:psi_io_some, :saturate, 20.0, 0.5},
    {:psi_io_full, :saturate, 10.0, 0.5}
  ]

  @component_weights [cpu: 0.4, memory: 0.4, io: 0.2]
  @max_weight 0.8

  @doc """
  Scores a window of samples (any order). Options: `:tau_ms`, `:window_ms`.

  An empty window scores `0.0` everywhere.
  """
  @spec compute([NodeSample.t()], keyword()) :: result()
  def compute(samples, opts \\ []) when is_list(samples) do
    samples |> smooth(opts) |> from_signals()
  end

  @doc "Time-weighted mean of every scored field over the window; `nil` for fields never observed."
  @spec smooth([NodeSample.t()], keyword()) :: signals()
  def smooth(samples, opts \\ []) do
    tau_ms = Keyword.get(opts, :tau_ms, @default_tau_ms)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    case samples do
      [] ->
        Map.new(@fields, &{&1, nil})

      _ ->
        newest = samples |> Enum.map(& &1.ts) |> Enum.max()

        weighted =
          for %{ts: ts} = sample <- samples, newest - ts <= window_ms do
            {sample, :math.exp(-(newest - ts) / tau_ms)}
          end

        Map.new(@fields, fn field ->
          pairs =
            for {sample, weight} <- weighted, value = Map.get(sample, field), do: {value, weight}

          {field, weighted_mean(pairs)}
        end)
    end
  end

  @doc "Scores already-smoothed signals (a map of `NodeSample` field => value or nil)."
  @spec from_signals(signals()) :: result()
  def from_signals(signals) do
    raw = [
      cpu: component(signals, @cpu),
      memory: component(signals, @memory),
      io: component(signals, @io)
    ]

    %{
      score: raw |> overall() |> round2(),
      components: Map.new(raw, fn {name, value} -> {name, round2(value || 0.0)} end)
    }
  end

  @doc "`100 * (1 - e^(-x / knee))`, 0 for negative input."
  @spec saturate(number(), number()) :: float()
  def saturate(x, knee) when knee > 0, do: 100.0 * (1.0 - :math.exp(-max(x, 0) / knee))

  @doc "Convex ramp: 0 up to `from`, then quadratic up to 100 at 1.0."
  @spec ramp(number(), number()) :: float()
  def ramp(x, from) when from < 1 do
    t = clamp((x - from) / (1.0 - from), 0.0, 1.0)
    100.0 * t * t
  end

  defp component(signals, spec) do
    spec
    |> Enum.flat_map(fn {field, curve, param, weight} ->
      case Map.get(signals, field) do
        value when is_number(value) -> [{curve(curve, value, param), weight}]
        _ -> []
      end
    end)
    |> weighted_mean()
  end

  defp curve(:saturate, value, knee), do: saturate(value, knee)
  defp curve(:ramp, value, from), do: ramp(value, from)

  defp overall(raw) do
    present = for {name, value} <- raw, value != nil, do: {value, @component_weights[name]}

    case present do
      [] ->
        0.0

      _ ->
        worst = present |> Enum.map(&elem(&1, 0)) |> Enum.max()
        clamp(@max_weight * worst + (1.0 - @max_weight) * weighted_mean(present), 0.0, 100.0)
    end
  end

  defp weighted_mean([]), do: nil

  defp weighted_mean(pairs) do
    total = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    Enum.reduce(pairs, 0.0, fn {value, weight}, acc -> acc + value * weight end) / total
  end

  defp clamp(x, lo, hi), do: x |> max(lo) |> min(hi)
  defp round2(x), do: Float.round(x * 1.0, 2)
end
