defmodule Cadmium.Valence.ClusterState do
  @moduledoc """
  This agent's view of the whole cluster: the latest `NodeScore` and a bounded history
  for every Kubernetes node, kept in a protected ETS table that readers hit directly.

  The owning process subscribes to the cluster-wide scores topic and:

    * ignores scores that are not newer (`ts`) than what it already holds for that node,
      and scores from BEAM nodes that are not connected (a late message racing a
      `:nodedown` must not resurrect the node);
    * lets a newer score from a *different* `beam_node` take over the same `k8s_node`
      (the agent restarted);
    * removes a node as soon as its `beam_node` goes down, and prunes nodes it has not
      heard from for `stale_after_ms`. Staleness is measured on the local monotonic
      clock from the time of receipt, so clock skew between hosts cannot fake or hide it;
    * emits `{:cluster_updated, nodes}` (local broadcast) when the view changes, at
      most once per `:notify_interval_ms`.

  ## Options (all optional)

    * `:name` (process, `nil` for none), `:table` (ETS table name)
    * `:pubsub`, `:scores_topic`, `:cluster_topic`
    * `:stale_after_ms`, `:history_size`
    * `:prune_interval_ms` - integer or `:infinity` (then call `prune/1`)
    * `:notify_interval_ms` - coalescing window for `:cluster_updated` (default 500)
    * `:clock` - 0-arity fun returning monotonic milliseconds
    * `:connected?` - 1-arity fun telling whether a BEAM node is reachable
  """
  use GenServer

  alias Cadmium.Valence.NodeScore

  @default_table __MODULE__

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  ## Reads (straight from ETS; safe when the table does not exist)

  @doc "Latest score per node, sorted by `k8s_node`."
  @spec nodes(atom()) :: [NodeScore.t()]
  def nodes(table \\ @default_table) do
    # ordered_set: rows come back in key order, i.e. sorted by k8s_node
    safe(fn -> :ets.select(table, [{{{:latest, :_}, :"$1", :_}, [], [:"$1"]}]) end, [])
  end

  @spec node_score(atom(), String.t()) :: NodeScore.t() | nil
  def node_score(table \\ @default_table, k8s_node) do
    safe(
      fn ->
        case :ets.lookup(table, {:latest, k8s_node}) do
          [{_key, score, _received_at}] -> score
          [] -> nil
        end
      end,
      nil
    )
  end

  @doc "Up to `limit` most recent scores for a node, oldest first."
  @spec history(atom(), String.t(), pos_integer()) :: [NodeScore.t()]
  def history(table \\ @default_table, k8s_node, limit) do
    safe(
      fn ->
        table
        |> :ets.select([{{{:history, k8s_node, :_}, :"$1"}, [], [:"$1"]}])
        |> Enum.take(-limit)
      end,
      []
    )
  end

  @doc "Synchronously drops stale nodes. Returns the removed `k8s_node`s."
  @spec prune(GenServer.server()) :: [String.t()]
  def prune(server \\ __MODULE__), do: GenServer.call(server, :prune)

  @doc "Default reachability check: this node or a connected one."
  @spec connected?(node()) :: boolean()
  def connected?(beam_node), do: beam_node == node() or beam_node in Node.list()

  defp safe(fun, default) do
    fun.()
  rescue
    ArgumentError -> default
  end

  ## Server

  @impl true
  def init(opts) do
    config = Application.get_env(:cadmium, Cadmium.Valence, [])
    stale_after_ms = Keyword.get(opts, :stale_after_ms, config[:stale_after_ms] || 15_000)

    state = %{
      table: Keyword.get(opts, :table, @default_table),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      cluster_topic: Keyword.get(opts, :cluster_topic, Cadmium.Valence.cluster_topic()),
      stale_after_ms: stale_after_ms,
      history_size: Keyword.get(opts, :history_size, config[:history_size] || 300),
      prune_interval_ms:
        Keyword.get(opts, :prune_interval_ms, stale_after_ms |> div(5) |> max(100) |> min(1_000)),
      notify_interval_ms: Keyword.get(opts, :notify_interval_ms, 500),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      connected?: Keyword.get(opts, :connected?, &__MODULE__.connected?/1),
      # k8s_node => number of history rows
      counts: %{},
      notify_timer: nil,
      last_notify: nil
    }

    :ets.new(state.table, [:named_table, :ordered_set, :protected, read_concurrency: true])
    :ok = :net_kernel.monitor_nodes(true)

    :ok =
      Phoenix.PubSub.subscribe(
        state.pubsub,
        Keyword.get(opts, :scores_topic, Cadmium.Valence.scores_topic())
      )

    schedule_prune(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:node_score, %NodeScore{k8s_node: k8s_node, ts: ts} = score}, state)
      when is_binary(k8s_node) and is_integer(ts) do
    if newer?(state.table, score) and state.connected?.(score.beam_node) do
      {:noreply, state |> store(score) |> changed()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, beam_node}, state) do
    gone =
      for {k8s_node, %NodeScore{beam_node: ^beam_node}} <- latest_rows(state.table),
          do: k8s_node

    {:noreply, remove(state, gone)}
  end

  def handle_info(:prune, state) do
    {_removed, state} = do_prune(state)
    schedule_prune(state)
    {:noreply, state}
  end

  def handle_info(:notify, state), do: {:noreply, notify(%{state | notify_timer: nil})}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:prune, _from, state) do
    {removed, state} = do_prune(state)
    {:reply, removed, state}
  end

  defp latest_rows(table) do
    :ets.select(table, [{{{:latest, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp newer?(table, %NodeScore{k8s_node: k8s_node, ts: ts}) do
    case :ets.lookup(table, {:latest, k8s_node}) do
      [{_key, %NodeScore{ts: known}, _received_at}] -> ts > known
      [] -> true
    end
  end

  defp store(state, %NodeScore{k8s_node: k8s_node, ts: ts} = score) do
    :ets.insert(state.table, [
      {{:latest, k8s_node}, score, state.clock.()},
      {{:history, k8s_node, ts}, score}
    ])

    count =
      trim(state.table, k8s_node, Map.get(state.counts, k8s_node, 0) + 1, state.history_size)

    %{state | counts: Map.put(state.counts, k8s_node, count)}
  end

  defp trim(table, k8s_node, count, max) when count > max do
    # smallest history key for this node = its oldest score (ts is never negative)
    case :ets.next(table, {:history, k8s_node, -1}) do
      {:history, ^k8s_node, _ts} = key -> :ets.delete(table, key)
      _ -> :ok
    end

    trim(table, k8s_node, count - 1, max)
  end

  defp trim(_table, _k8s_node, count, _max), do: count

  defp do_prune(state) do
    cutoff = state.clock.() - state.stale_after_ms

    stale =
      :ets.select(state.table, [{{{:latest, :"$1"}, :_, :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}])

    {stale, remove(state, stale)}
  end

  defp remove(state, []), do: state

  defp remove(state, k8s_nodes) do
    for k8s_node <- k8s_nodes do
      :ets.delete(state.table, {:latest, k8s_node})
      :ets.match_delete(state.table, {{:history, k8s_node, :_}, :_})
    end

    changed(%{state | counts: Map.drop(state.counts, k8s_nodes)})
  end

  # Leading-edge notification, then at most one per notify_interval_ms.
  defp changed(%{notify_timer: timer} = state) when timer != nil, do: state

  defp changed(state) do
    now = System.monotonic_time(:millisecond)

    wait =
      if state.last_notify, do: state.last_notify + state.notify_interval_ms - now, else: 0

    if wait <= 0 do
      notify(state)
    else
      %{state | notify_timer: Process.send_after(self(), :notify, wait)}
    end
  end

  defp notify(state) do
    Phoenix.PubSub.local_broadcast(
      state.pubsub,
      state.cluster_topic,
      {:cluster_updated, nodes(state.table)}
    )

    %{state | last_notify: System.monotonic_time(:millisecond)}
  end

  defp schedule_prune(%{prune_interval_ms: ms}) when is_integer(ms),
    do: Process.send_after(self(), :prune, ms)

  defp schedule_prune(_state), do: :ok
end
