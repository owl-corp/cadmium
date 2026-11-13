defmodule Cadmium.CatalystKubeStub do
  @moduledoc """
  Recording `Cadmium.Kube.Client` for Catalyst tests.

  Start it with `start_supervised!/1` and point `config :cadmium, :kube_client` at it.
  Every call is recorded (`calls/0`, `mutations/0`); taints are applied to the stubbed
  nodes so reads reflect earlier writes. `respond/2` overrides the result of an
  operation (a value, or a function of the argument list); `on_call/1` registers a hook
  that runs in the calling process before each call, e.g. to drop leadership mid-cycle.
  """

  @behaviour Cadmium.Kube.Client

  use Agent

  @mutating [:evict_pod, :add_node_taint, :remove_node_taint, :create_lease, :update_lease]

  def start_link(opts \\ []) do
    state = %{
      nodes: Keyword.get(opts, :nodes, []),
      pdbs: Keyword.get(opts, :pdbs, []),
      replicas: Keyword.get(opts, :replicas, %{}),
      responses: %{},
      hooks: [],
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  def put(key, value) when key in [:nodes, :pdbs, :replicas],
    do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def respond(op, response),
    do: Agent.update(__MODULE__, &put_in(&1, [:responses, op], response))

  def clear_response(op),
    do: Agent.update(__MODULE__, &%{&1 | responses: Map.delete(&1.responses, op)})

  def on_call(hook) when is_function(hook, 2),
    do: Agent.update(__MODULE__, &%{&1 | hooks: &1.hooks ++ [hook]})

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def calls(op), do: for({^op, args} <- calls(), do: args)
  def mutations, do: Enum.filter(calls(), fn {op, _args} -> op in @mutating end)
  def reset_calls, do: Agent.update(__MODULE__, &%{&1 | calls: []})
  def nodes, do: Agent.get(__MODULE__, & &1.nodes)

  def taints(node_name) do
    Enum.find_value(nodes(), [], fn node -> if node.name == node_name, do: node.taints end)
  end

  defp invoke(op, args, default) do
    {hooks, response} =
      Agent.get_and_update(__MODULE__, fn state ->
        {{state.hooks, Map.fetch(state.responses, op)},
         %{state | calls: [{op, args} | state.calls]}}
      end)

    Enum.each(hooks, & &1.(op, args))

    case response do
      {:ok, fun} when is_function(fun, 1) -> fun.(args)
      {:ok, value} -> value
      :error -> default.()
    end
  end

  @impl true
  def list_pods(opts), do: invoke(:list_pods, [opts], fn -> {:ok, []} end)

  @impl true
  def list_nodes, do: invoke(:list_nodes, [], fn -> {:ok, nodes()} end)

  @impl true
  def list_pdbs, do: invoke(:list_pdbs, [], fn -> {:ok, Agent.get(__MODULE__, & &1.pdbs)} end)

  @impl true
  def workload_replicas(namespace, kind, name) do
    invoke(:workload_replicas, [namespace, kind, name], fn ->
      case Agent.get(__MODULE__, &Map.fetch(&1.replicas, {namespace, kind, name})) do
        {:ok, replicas} -> {:ok, replicas}
        :error -> {:error, :not_found}
      end
    end)
  end

  @impl true
  def evict_pod(namespace, name, opts),
    do: invoke(:evict_pod, [namespace, name, opts], fn -> :ok end)

  @impl true
  def add_node_taint(node_name, taint) do
    invoke(:add_node_taint, [node_name, taint], fn ->
      update_taints(node_name, fn taints ->
        Enum.reject(taints, &(&1.key == taint.key)) ++ [taint]
      end)
    end)
  end

  @impl true
  def remove_node_taint(node_name, key) do
    invoke(:remove_node_taint, [node_name, key], fn ->
      update_taints(node_name, fn taints -> Enum.reject(taints, &(&1.key == key)) end)
    end)
  end

  @impl true
  def get_lease(namespace, name),
    do: invoke(:get_lease, [namespace, name], fn -> {:error, :not_found} end)

  @impl true
  def create_lease(lease), do: invoke(:create_lease, [lease], fn -> {:ok, lease} end)

  @impl true
  def update_lease(lease), do: invoke(:update_lease, [lease], fn -> {:ok, lease} end)

  defp update_taints(node_name, fun) do
    Agent.update(__MODULE__, fn state ->
      nodes =
        Enum.map(state.nodes, fn node ->
          if node.name == node_name, do: %{node | taints: fun.(node.taints)}, else: node
        end)

      %{state | nodes: nodes}
    end)
  end
end
