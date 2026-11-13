defmodule Cadmium.Valence.Broadcaster do
  @moduledoc """
  Turns local Isotope samples into this node's `Cadmium.Valence.NodeScore` and publishes
  it cluster-wide every `broadcast_interval_ms`.

  Keeps only a short window of raw samples (raw telemetry never leaves the node). Nothing
  is broadcast until a sample has arrived, nor when all samples have aged out of the
  window (a dead sampler makes this node go stale for its peers rather than freezing
  its last score forever).

  ## Options (all optional)

    * `:name` - process name (default `Cadmium.Valence.Broadcaster`; `nil` for none)
    * `:interval_ms` - broadcast period, or `:infinity` to only broadcast via `broadcast_now/1`
    * `:window_ms` - how much sample history feeds the score (default 10s)
    * `:pubsub`, `:topic` - where scores are published
    * `:subscribe` - 0-arity fun subscribing the process to `{:isotope_sample, sample}`
    * `:pod_samples` - 0-arity fun returning the local pod samples
    * `:node_name` - Kubernetes node name, or a 0-arity fun returning it
    * `:clock` - 0-arity fun returning wall-clock milliseconds
  """
  use GenServer

  alias Cadmium.Isotope.NodeSample
  alias Cadmium.Valence.{NodeScore, Score}

  @default_window_ms 10_000
  @max_samples 120

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Computes and publishes a score immediately; `:no_samples` when there is nothing to score."
  @spec broadcast_now(GenServer.server()) :: {:ok, NodeScore.t()} | :no_samples
  def broadcast_now(server \\ __MODULE__), do: GenServer.call(server, :broadcast_now)

  @impl true
  def init(opts) do
    config = Application.get_env(:cadmium, Cadmium.Valence, [])

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, config[:broadcast_interval_ms] || 2_000),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get(opts, :topic, Cadmium.Valence.scores_topic()),
      pod_samples: Keyword.get(opts, :pod_samples, &Cadmium.Isotope.pod_samples/0),
      node_name: Keyword.get(opts, :node_name, &Cadmium.node_name/0),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      # newest first
      samples: []
    }

    subscribe = Keyword.get(opts, :subscribe, &Cadmium.Isotope.subscribe/0)
    subscribe.()
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:isotope_sample, %NodeSample{} = sample}, state) do
    {:noreply, %{state | samples: Enum.take([sample | state.samples], @max_samples)}}
  end

  def handle_info(:broadcast, state) do
    {_result, state} = publish(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:broadcast_now, _from, state) do
    {result, state} = publish(state)
    {:reply, result, state}
  end

  defp publish(state) do
    now = state.clock.()
    samples = Enum.filter(state.samples, &(now - &1.ts <= state.window_ms))
    state = %{state | samples: samples}

    case samples do
      [] ->
        {:no_samples, state}

      _ ->
        %{score: score, components: components} =
          Score.compute(samples, window_ms: state.window_ms)

        node_score = %NodeScore{
          k8s_node: resolve(state.node_name),
          beam_node: node(),
          score: score,
          components: components,
          pod_count: pod_count(state.pod_samples),
          ts: now
        }

        Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:node_score, node_score})
        {{:ok, node_score}, state}
    end
  end

  defp pod_count(fun) do
    length(fun.())
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(name) when is_binary(name), do: name

  defp schedule(%{interval_ms: ms}) when is_integer(ms),
    do: Process.send_after(self(), :broadcast, ms)

  defp schedule(_state), do: :ok
end
