defmodule Cadmium.Catalyst.AuditLog do
  @moduledoc """
  Bounded, replicated audit log of `Cadmium.Catalyst.Action`s.

  Each agent keeps the newest `audit_log_size` actions in an ETS `ordered_set` keyed by
  `{ts, id}`. `record/2` stamps a new action (unique `id`, `ts`, `actor:
  Cadmium.node_name()`), stores it and broadcasts `{:catalyst_action, action}`
  cluster-wide on `Cadmium.Catalyst.topic/0`. Every agent's log subscribes to that topic
  and stores what it hears (deduplicated by id), and backfills from its peers at startup
  and on `:nodeup`, so `recent/2` gives the same answer on any agent.

  Reads go straight to ETS and never block on the process.
  """

  use GenServer

  alias Cadmium.Catalyst.{Action, Config, Safe}

  @rpc_timeout 2_000
  @nodeup_delay_ms 1_000

  ## API

  @doc """
  Options: `:name`, `:table` (ETS name, defaults to the process name), `:size`,
  `:pubsub`, `:topic`, `:peers_fun` (`(-> [node()])`, default `Node.list/0`).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Builds an action from `attrs` (`:type` is required), stores it and broadcasts it.
  Returns the action. Never raises: if the log is not running the action is still
  returned, just not recorded.
  """
  @spec record(GenServer.server(), keyword() | map()) :: Action.t()
  def record(server \\ __MODULE__, attrs) do
    attrs = Map.new(attrs)
    action = build(attrs)
    # Unless the caller chose the timestamp, the log makes it strictly increasing so
    # actions recorded in the same millisecond keep their order.
    restamp? = not Map.has_key?(attrs, :ts)
    Safe.call(fn -> GenServer.call(server, {:record, action, restamp?}) end, action)
  end

  @doc "Builds a stamped action without storing it."
  @spec build(keyword() | map()) :: Action.t()
  def build(attrs) do
    attrs = Map.new(attrs)
    ts = Map.get_lazy(attrs, :ts, fn -> System.system_time(:millisecond) end)
    actor = Map.get_lazy(attrs, :actor, &Cadmium.node_name/0)

    struct!(
      Action,
      Map.merge(attrs, %{id: Map.get(attrs, :id) || new_id(actor), ts: ts, actor: actor})
    )
  end

  @doc "Up to `limit` most recent actions, newest first. `[]` when the log is not running."
  @spec recent(atom(), pos_integer()) :: [Action.t()]
  def recent(table \\ __MODULE__, limit) when is_integer(limit) do
    if limit > 0, do: walk(table, :ets.last(table), limit, []), else: []
  rescue
    ArgumentError -> []
  end

  defp walk(_table, :"$end_of_table", _left, acc), do: Enum.reverse(acc)
  defp walk(_table, _key, 0, acc), do: Enum.reverse(acc)

  defp walk(table, key, left, acc) do
    acc =
      case :ets.lookup(table, key) do
        [{^key, action}] -> [action | acc]
        [] -> acc
      end

    walk(table, :ets.prev(table, key), left - 1, acc)
  end

  defp new_id(actor) do
    random = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{actor}-#{random}"
  end

  ## Server

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = Keyword.get(opts, :table, name)

    state = %{
      table: :ets.new(table, [:named_table, :protected, :ordered_set, read_concurrency: true]),
      size: max(Keyword.get_lazy(opts, :size, fn -> Config.load().audit_log_size end), 1),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get_lazy(opts, :topic, &Cadmium.Catalyst.topic/0),
      peers_fun: Keyword.get(opts, :peers_fun, &Node.list/0),
      last_ts: 0
    }

    Phoenix.PubSub.subscribe(state.pubsub, state.topic)
    :net_kernel.monitor_nodes(true)
    {:ok, state, {:continue, :backfill}}
  end

  @impl true
  def handle_continue(:backfill, state) do
    backfill(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:record, %Action{} = action, restamp?}, _from, state) do
    action = if restamp?, do: %{action | ts: max(action.ts, state.last_ts + 1)}, else: action
    state = %{state | last_ts: max(state.last_ts, action.ts)}

    if insert(state, action) do
      Safe.call(
        fn ->
          Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:catalyst_action, action})
        end,
        :ok
      )
    end

    {:reply, action, state}
  end

  @impl true
  def handle_cast({:backfill, actions}, state) when is_list(actions) do
    Enum.each(actions, &insert(state, &1))
    {:noreply, state}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info({:catalyst_action, action}, state) do
    insert(state, action)
    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state) do
    # Give the peer's application a moment to start before asking it.
    Process.send_after(self(), :backfill, @nodeup_delay_ms)
    {:noreply, state}
  end

  def handle_info(:backfill, state) do
    backfill(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Returns true when the action was new.
  defp insert(state, %Action{id: id, ts: ts} = action) when is_binary(id) and is_integer(ts) do
    inserted? = :ets.insert_new(state.table, {{ts, id}, action})
    if inserted?, do: trim(state)
    inserted?
  end

  defp insert(_state, _other), do: false

  defp trim(state) do
    if :ets.info(state.table, :size) > state.size do
      :ets.delete(state.table, :ets.first(state.table))
      trim(state)
    end
  end

  # Pulls every peer's log in a throwaway process so a slow peer never blocks the log.
  defp backfill(state) do
    server = self()
    size = state.size

    case Safe.call(state.peers_fun, []) do
      [_ | _] = peers ->
        Task.start(fn ->
          peers
          |> :erpc.multicall(__MODULE__, :recent, [size], @rpc_timeout)
          |> Enum.each(fn
            {:ok, actions} when is_list(actions) -> GenServer.cast(server, {:backfill, actions})
            _ -> :ok
          end)
        end)

      _ ->
        :ok
    end
  end
end
