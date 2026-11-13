defmodule Cadmium.Isotope.Sampler do
  @moduledoc """
  Samples the host once per interval.

  Each tick it pulls a raw reading from the configured `Cadmium.Isotope.Source`, derives
  rates and ratios against the previous reading (`Cadmium.Isotope.Derive`), pushes a
  `NodeSample` and one `PodSample` per pod cgroup into the ring buffer, drops the series of
  pods whose cgroup is gone, and broadcasts the node sample locally as
  `{:isotope_sample, sample}`.

  Readers never call this process: they read the ring buffer (`Cadmium.Isotope`).

  A source that fails or raises costs that one tick: the error is logged (at most once per
  `:log_interval_ms`) and sampling carries on; the next good reading is diffed against the
  last good one over the real elapsed time.

  ## Options

  All default to `config :cadmium, Cadmium.Isotope`, then to the value shown.

    * `:name` - process name (`#{inspect(__MODULE__)}`; `nil` for none)
    * `:table` - the `Cadmium.Isotope.RingBuffer` to write to, which must already exist
      (`Cadmium.Isotope.table/0`)
    * `:source` - source module (`Cadmium.Isotope.Source.Cgroup`); it is given all of
      these options in `init/1`
    * `:interval_ms` - tick interval (1000), or `:manual` to tick only via `tick/1`
    * `:pubsub` / `:topic` - where node samples are broadcast
    * `:clock` - zero-arity fun returning monotonic milliseconds
    * `:log_interval_ms` - minimum gap between source-failure log lines (30000)
  """

  use GenServer
  require Logger

  alias Cadmium.Isotope
  alias Cadmium.Isotope.{Derive, NodeSample, RingBuffer}

  @node_series :node

  @doc "Ring buffer series holding the node samples."
  def node_series, do: @node_series

  @doc "Ring buffer series holding the samples of pod `pod_uid`."
  def pod_series(pod_uid), do: {:pod, pod_uid}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Takes one sample right now and returns it. This is how tests (and `:manual` mode) drive
  the sampler; it does not disturb the regular schedule.
  """
  @spec tick(GenServer.server()) :: {:ok, NodeSample.t()} | {:error, term()}
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  # -- callbacks -------------------------------------------------------------------------

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:cadmium, Isotope, []), opts)

    state = %{
      opts: opts,
      source: Keyword.get(opts, :source, Cadmium.Isotope.Source.Cgroup),
      source_state: :uninitialized,
      table: Keyword.get(opts, :table, Isotope.table()),
      interval: Keyword.get(opts, :interval_ms, 1_000),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get(opts, :topic, Isotope.topic()),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      log_interval: Keyword.get(opts, :log_interval_ms, 30_000),
      # last good reading: %{at: monotonic ms, reading: reading}
      prev: nil,
      failures: 0,
      last_logged_at: nil
    }

    if is_integer(state.interval), do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {result, state} = sample(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    started = System.monotonic_time(:millisecond)
    {_result, state} = sample(state)

    if is_integer(state.interval) do
      elapsed = System.monotonic_time(:millisecond) - started
      Process.send_after(self(), :tick, max(state.interval - elapsed, 0))
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- sampling --------------------------------------------------------------------------

  defp sample(state) do
    case read_and_store(state) do
      {:ok, sample, state} ->
        Phoenix.PubSub.local_broadcast(state.pubsub, state.topic, {:isotope_sample, sample})
        {{:ok, sample}, recovered(state)}

      {:error, reason, state} ->
        {{:error, reason}, failed(state, reason)}
    end
  end

  # Nothing a source does - error tuples, bad return values, raising, exiting - and
  # nothing a malformed reading does to the derivation may take the sampler down.
  defp read_and_store(state) do
    with {:ok, state} <- ensure_source(state),
         {:ok, reading, state} <- read(state) do
      now = state.clock.()
      sample = store(state, reading, now)
      {:ok, sample, %{state | prev: %{at: now, reading: reading}}}
    end
  rescue
    exception -> {:error, {:exception, exception, __STACKTRACE__}, state}
  catch
    kind, value -> {:error, {kind, value}, state}
  end

  defp ensure_source(%{source_state: :uninitialized} = state) do
    case state.source.init(state.opts) do
      {:ok, source_state} -> {:ok, %{state | source_state: {:ok, source_state}}}
      {:error, reason} -> {:error, {:source_init, reason}, state}
      other -> {:error, {:bad_source_init, other}, state}
    end
  end

  defp ensure_source(state), do: {:ok, state}

  defp read(%{source_state: {:ok, source_state}} = state) do
    case state.source.read(source_state) do
      {:ok, %{node: %{}, pods: %{}} = reading, source_state} ->
        {:ok, reading, %{state | source_state: {:ok, source_state}}}

      {:error, reason, source_state} ->
        {:error, reason, %{state | source_state: {:ok, source_state}}}

      other ->
        {:error, {:bad_source_read, other}, state}
    end
  end

  defp store(state, reading, now) do
    ts = System.system_time(:millisecond)
    dt_ms = state.prev && now - state.prev.at
    prev_node = state.prev && state.prev.reading.node
    prev_pods = (state.prev && state.prev.reading.pods) || %{}

    # Build everything before writing anything, so a bad reading stores nothing.
    node_sample = Derive.node_sample(prev_node, reading.node, dt_ms, ts)

    pod_samples =
      for {uid, raw} when is_binary(uid) and is_map(raw) <- reading.pods do
        Derive.pod_sample(uid, Map.get(prev_pods, uid), raw, dt_ms, ts)
      end

    for sample <- pod_samples do
      RingBuffer.push(state.table, pod_series(sample.pod_uid), sample)
    end

    # Pods whose cgroup has disappeared: checked against the buffer rather than the
    # previous reading so nothing is left behind across a sampler restart either.
    for {:pod, uid} = series <- RingBuffer.series(state.table),
        not is_map_key(reading.pods, uid) do
      RingBuffer.delete(state.table, series)
    end

    RingBuffer.push(state.table, @node_series, node_sample)
    node_sample
  end

  # -- failure logging -------------------------------------------------------------------

  defp failed(state, reason) do
    now = state.clock.()
    failures = state.failures + 1

    if state.last_logged_at == nil or now - state.last_logged_at >= state.log_interval do
      Logger.error(
        "Isotope: #{inspect(state.source)} failed to produce a sample " <>
          "(#{failures} consecutive): #{format_reason(reason)}"
      )

      %{state | failures: failures, last_logged_at: now}
    else
      %{state | failures: failures}
    end
  end

  defp recovered(%{failures: 0} = state), do: state

  defp recovered(state) do
    Logger.info("Isotope: sampling recovered after #{state.failures} failed ticks")
    %{state | failures: 0, last_logged_at: nil}
  end

  defp format_reason({:exception, exception, stacktrace}),
    do: Exception.format(:error, exception, stacktrace)

  defp format_reason(reason), do: inspect(reason)
end
