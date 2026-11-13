defmodule Cadmium.Catalyst.Cooldowns do
  @moduledoc """
  Node cooldowns, workload cooldowns and the set of nodes this agent has tainted.

  This state deliberately lives in its own process (which does nothing but own a public
  ETS table), outside the coordinator and outside the evaluation that writes to it. An
  eviction is recorded here the moment it happens, so a crash later in the same
  evaluation - or of the coordinator itself - cannot forget it and evict again on the
  next cycle.

  Expiries are monotonic milliseconds from the coordinator's clock. `instance/1` returns
  a token that changes when the table is recreated; the coordinator uses it to notice
  that cooldown state was lost and to start its sustained-window tracking over.

  All functions take the table name; reads on a missing table return empty values,
  writes raise (which the evaluation treats as "skip").
  """

  use GenServer

  @type table :: atom()

  def start_link(opts \\ []) do
    table = Keyword.get(opts, :table, __MODULE__)
    GenServer.start_link(__MODULE__, table, name: Keyword.get(opts, :name, table))
  end

  @impl true
  def init(table) do
    ^table = :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(table, {:instance, make_ref()})
    {:ok, table}
  end

  @doc "Token identifying this incarnation of the table, or `nil` when it does not exist."
  @spec instance(table()) :: reference() | nil
  def instance(table \\ __MODULE__) do
    case safe_lookup(table, :instance) do
      [{:instance, ref}] -> ref
      _ -> nil
    end
  end

  @doc "Starts (or extends, never shortens) a node cooldown."
  @spec put_node(table(), String.t(), integer()) :: :ok
  def put_node(table \\ __MODULE__, node, expires_at), do: put(table, {:node, node}, expires_at)

  @doc "Starts (or extends, never shortens) a workload cooldown."
  @spec put_workload(table(), String.t(), integer()) :: :ok
  def put_workload(table \\ __MODULE__, key, expires_at),
    do: put(table, {:workload, key}, expires_at)

  defp put(table, key, expires_at) when is_integer(expires_at) do
    case :ets.lookup(table, key) do
      [{^key, current}] when current >= expires_at -> :ok
      _ -> :ets.insert(table, {key, expires_at})
    end

    :ok
  end

  @doc "Unexpired cooldowns as `%{nodes: %{name => expiry}, workloads: %{key => expiry}}`."
  @spec active(table(), integer()) :: %{nodes: map(), workloads: map()}
  def active(table \\ __MODULE__, now) do
    table
    |> safe_tab2list()
    |> Enum.reduce(%{nodes: %{}, workloads: %{}}, fn
      {{:node, name}, expiry}, acc when expiry > now -> put_in(acc, [:nodes, name], expiry)
      {{:workload, key}, expiry}, acc when expiry > now -> put_in(acc, [:workloads, key], expiry)
      _, acc -> acc
    end)
  end

  @doc "Deletes expired cooldowns."
  @spec prune(table(), integer()) :: :ok
  def prune(table \\ __MODULE__, now) do
    for {{kind, _} = key, expiry} <- safe_tab2list(table),
        kind in [:node, :workload],
        expiry <= now,
        do: :ets.delete(table, key)

    :ok
  end

  @doc "Remembers that this agent put (or, in dry-run, would have put) the taint on a node."
  @spec mark_tainted(table(), String.t(), boolean()) :: :ok
  def mark_tainted(table \\ __MODULE__, node, dry_run?) do
    :ets.insert(table, {{:taint, node}, %{dry_run?: dry_run?, failures: 0}})
    :ok
  end

  @doc "Counts a failed taint removal; returns the number of failures so far."
  @spec taint_removal_failed(table(), String.t()) :: pos_integer()
  def taint_removal_failed(table \\ __MODULE__, node) do
    entry =
      case :ets.lookup(table, {:taint, node}) do
        [{_, entry}] -> entry
        [] -> %{dry_run?: false, failures: 0}
      end

    entry = %{entry | failures: entry.failures + 1}
    :ets.insert(table, {{:taint, node}, entry})
    entry.failures
  end

  @spec clear_taint(table(), String.t()) :: :ok
  def clear_taint(table \\ __MODULE__, node) do
    :ets.delete(table, {:taint, node})
    :ok
  end

  @doc "Tracked taints as `%{node => %{dry_run?: boolean, failures: n}}`."
  @spec tainted(table()) :: %{String.t() => map()}
  def tainted(table \\ __MODULE__) do
    for {{:taint, node}, entry} <- safe_tab2list(table), into: %{}, do: {node, entry}
  end

  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
