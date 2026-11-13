defmodule Cadmium.Catalyst.Settings do
  @moduledoc """
  Runtime-togglable Catalyst settings (`dry_run?`, `enabled?`), replicated to every agent.

  Each setting is a last-writer-wins register: a value plus a version `{wall_clock_ms,
  actor}`. A change made on any agent bumps the version (always above the one it
  replaces, so a slow clock cannot lose to itself), is applied locally, and is broadcast
  to the other agents on `sync_topic/0`; receivers keep whichever version is larger
  (`merge/2`), comparing the timestamp first and the actor name as a tie-break, so all
  agents converge on the same value regardless of delivery order. Values from config
  start at version `{0, ""}` and therefore lose to any runtime change.

  A newly started agent pulls the settings of its peers (`:erpc.multicall` to
  `Node.list/0`) at startup and again on `:nodeup`, which also heals netsplits.

  Replication uses the internal `sync_topic/0` rather than `Cadmium.Catalyst.topic/0`,
  so subscribers of the public topic only ever see the two documented messages. After
  any effective change the process announces `{:catalyst_settings_applied, settings}`
  locally on `sync_topic/0`; the coordinator turns that into a `{:catalyst_status, _}`
  broadcast.

  Each change made here records a `:settings_changed` audit action (on the originating
  agent only).
  """

  use GenServer

  alias Cadmium.Catalyst.{AuditLog, Config, Safe}

  @sync_topic "catalyst:sync"
  @keys [:dry_run?, :enabled?]
  @rpc_timeout 2_000
  @nodeup_delay_ms 1_000

  @type version :: {integer(), String.t()}
  @type registers :: %{dry_run?: {boolean(), version()}, enabled?: {boolean(), version()}}
  @type t :: %{dry_run?: boolean(), enabled?: boolean()}

  @doc "Internal topic used for agent-to-agent replication of Catalyst state."
  def sync_topic, do: @sync_topic

  ## API

  @doc """
  Options: `:name`, `:config` (overrides for the initial values), `:pubsub`,
  `:sync_topic`, `:audit` (audit log server), `:actor`, `:wall_clock`, `:peers_fun`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Current settings; falls back to the configured values when the process is not running."
  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__), do: fetch(server) || defaults()

  @doc "Current settings, or `nil` when the process is not running."
  @spec fetch(GenServer.server()) :: t() | nil
  def fetch(server \\ __MODULE__) do
    Safe.call(fn -> GenServer.call(server, :get) end, nil)
  end

  @doc "Sets one setting cluster-wide. A no-op (no audit entry) when the value is unchanged."
  @spec put(GenServer.server(), :dry_run? | :enabled?, boolean()) :: :ok
  def put(server \\ __MODULE__, key, value) when key in @keys and is_boolean(value) do
    Safe.call(fn -> GenServer.call(server, {:put, key, value}) end, :ok)
  end

  @doc "The versioned registers, for peers to merge. `nil` when not running."
  @spec snapshot(GenServer.server()) :: registers() | nil
  def snapshot(server \\ __MODULE__) do
    Safe.call(fn -> GenServer.call(server, :snapshot) end, nil)
  end

  @doc "The configured (not runtime) values."
  @spec defaults(keyword()) :: t()
  def defaults(overrides \\ []) do
    config = Config.load(overrides)
    %{dry_run?: config.dry_run != false, enabled?: config.enabled == true}
  end

  @doc """
  Last-writer-wins merge of two register maps (pure): per setting, the entry with the
  larger version wins. Malformed remote entries are ignored. Commutative, associative
  and idempotent.
  """
  @spec merge(registers(), term()) :: registers()
  def merge(local, remote) when is_map(remote) do
    Map.new(local, fn {key, {_value, version} = current} ->
      case Map.get(remote, key) do
        {value, {ts, actor} = remote_version}
        when is_boolean(value) and is_integer(ts) and is_binary(actor) and
               remote_version > version ->
          {key, {value, remote_version}}

        _ ->
          {key, current}
      end
    end)
  end

  def merge(local, _remote), do: local

  ## Server

  @impl true
  def init(opts) do
    defaults = defaults(Keyword.get(opts, :config, []))

    state = %{
      registers: Map.new(defaults, fn {key, value} -> {key, {value, {0, ""}}} end),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      sync_topic: Keyword.get(opts, :sync_topic, @sync_topic),
      audit: Keyword.get(opts, :audit, AuditLog),
      actor: Keyword.get_lazy(opts, :actor, &Cadmium.node_name/0),
      wall_clock: Keyword.get(opts, :wall_clock, fn -> System.system_time(:millisecond) end),
      peers_fun: Keyword.get(opts, :peers_fun, &Node.list/0)
    }

    Phoenix.PubSub.subscribe(state.pubsub, state.sync_topic)
    :net_kernel.monitor_nodes(true)
    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    sync_from_peers(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, values(state.registers), state}
  def handle_call(:snapshot, _from, state), do: {:reply, state.registers, state}

  def handle_call({:put, key, value}, _from, state) do
    case Map.fetch!(state.registers, key) do
      {^value, _version} ->
        {:reply, :ok, state}

      {_old, {old_ts, _actor}} ->
        version = {max(state.wall_clock.(), old_ts + 1), state.actor}
        registers = Map.put(state.registers, key, {value, version})
        state = %{state | registers: registers}

        Safe.call(
          fn ->
            Phoenix.PubSub.broadcast_from(
              state.pubsub,
              self(),
              state.sync_topic,
              {:catalyst_settings, registers}
            )
          end,
          :ok
        )

        announce(state)

        AuditLog.record(state.audit,
          type: :settings_changed,
          actor: state.actor,
          reason: describe(key, value),
          details: %{setting: key, value: value}
        )

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:merge, remote}, state), do: {:noreply, apply_remote(state, remote)}
  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info({:catalyst_settings, remote}, state),
    do: {:noreply, apply_remote(state, remote)}

  def handle_info({:nodeup, _node}, state) do
    # Give the peer's application a moment to start before asking it.
    Process.send_after(self(), :sync, @nodeup_delay_ms)
    {:noreply, state}
  end

  def handle_info(:sync, state) do
    sync_from_peers(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp apply_remote(state, remote) do
    case merge(state.registers, remote) do
      unchanged when unchanged == state.registers ->
        state

      merged ->
        state = %{state | registers: merged}
        announce(state)
        state
    end
  end

  defp announce(state) do
    Safe.call(
      fn ->
        Phoenix.PubSub.local_broadcast(
          state.pubsub,
          state.sync_topic,
          {:catalyst_settings_applied, values(state.registers)}
        )
      end,
      :ok
    )
  end

  defp values(registers), do: Map.new(registers, fn {key, {value, _version}} -> {key, value} end)

  defp describe(:dry_run?, true), do: "dry-run enabled"
  defp describe(:dry_run?, false), do: "dry-run disabled: evictions are live"
  defp describe(:enabled?, true), do: "rebalancing resumed"
  defp describe(:enabled?, false), do: "rebalancing paused"

  # Pulls peers' registers in a throwaway process so a slow peer never blocks settings.
  defp sync_from_peers(state) do
    server = self()

    case Safe.call(state.peers_fun, []) do
      [_ | _] = peers ->
        Task.start(fn ->
          peers
          |> :erpc.multicall(__MODULE__, :snapshot, [], @rpc_timeout)
          |> Enum.each(fn
            {:ok, registers} when is_map(registers) -> GenServer.cast(server, {:merge, registers})
            _ -> :ok
          end)
        end)

      _ ->
        :ok
    end
  end
end
