defmodule Cadmium.Workloads.PodCache do
  @moduledoc """
  Per-agent cache of the pods the API server has scheduled on this node.

  Refreshes every `:interval_ms` (default 15s) with
  `Cadmium.Kube.list_pods(node: Cadmium.node_name())` and stores the list in ETS so
  `Cadmium.Workloads.local/0` never blocks on the API. On an API error the previous
  list is kept and a warning is logged (at most once per `:log_interval_ms`).

  ## Options (all optional)

    * `:name` (process, `nil` for none), `:table` (ETS table name)
    * `:interval_ms` - integer or `:infinity` (then call `refresh/1`)
    * `:min_refresh_ms` - floor between on-demand refreshes via `ensure_fresh/1`
    * `:list_pods` - 1-arity fun `node_name -> {:ok, [Pod.t()]} | {:error, term}`
    * `:node_name` - Kubernetes node name, or a 0-arity fun returning it
    * `:log_interval_ms`
  """
  use GenServer

  require Logger

  alias Cadmium.Kube.Pod

  @default_table __MODULE__

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Cached pods (straight from ETS); `[]` when the cache is not running."
  @spec pods(atom()) :: [Pod.t()]
  def pods(table \\ @default_table) do
    case :ets.lookup(table, :pods) do
      [{:pods, pods}] -> pods
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Refreshes from the API now."
  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 10_000)

  @doc """
  On-demand refresh for readers that found the cache empty: refreshes unless one was
  attempted within `:min_refresh_ms`. Never raises; `:ok` even if the cache is down.
  """
  @spec ensure_fresh(GenServer.server()) :: :ok
  def ensure_fresh(server \\ __MODULE__) do
    GenServer.call(server, :ensure_fresh, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      table: Keyword.get(opts, :table, @default_table),
      interval_ms: Keyword.get(opts, :interval_ms, 15_000),
      min_refresh_ms: Keyword.get(opts, :min_refresh_ms, 2_000),
      log_interval_ms: Keyword.get(opts, :log_interval_ms, 60_000),
      list_pods:
        Keyword.get(opts, :list_pods, fn node_name -> Cadmium.Kube.list_pods(node: node_name) end),
      node_name: Keyword.get(opts, :node_name, &Cadmium.node_name/0),
      last_attempt: nil,
      last_logged: nil
    }

    :ets.new(state.table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, state, {:continue, :initial_refresh}}
  end

  @impl true
  def handle_continue(:initial_refresh, state) do
    {_result, state} = do_refresh(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {_result, state} = do_refresh(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh, _from, state) do
    {result, state} = do_refresh(state)
    {:reply, result, state}
  end

  def handle_call(:ensure_fresh, _from, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_attempt == nil or now - state.last_attempt >= state.min_refresh_ms do
      {_result, state} = do_refresh(state)
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  defp do_refresh(state) do
    state = %{state | last_attempt: System.monotonic_time(:millisecond)}

    case fetch(state) do
      {:ok, pods} when is_list(pods) ->
        :ets.insert(state.table, {:pods, pods})
        {:ok, state}

      {:error, reason} ->
        {{:error, reason}, log_failure(state, reason)}

      unexpected ->
        reason = {:unexpected, unexpected}
        {{:error, reason}, log_failure(state, reason)}
    end
  end

  defp fetch(state) do
    state.list_pods.(resolve(state.node_name))
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp log_failure(state, reason) do
    now = System.monotonic_time(:millisecond)

    if state.last_logged == nil or now - state.last_logged >= state.log_interval_ms do
      Logger.warning(
        "Cadmium.Workloads: listing pods failed, keeping previous cache: #{inspect(reason)}"
      )

      %{state | last_logged: now}
    else
      state
    end
  end

  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(name) when is_binary(name), do: name

  defp schedule(%{interval_ms: ms}) when is_integer(ms),
    do: Process.send_after(self(), :refresh, ms)

  defp schedule(_state), do: :ok
end
