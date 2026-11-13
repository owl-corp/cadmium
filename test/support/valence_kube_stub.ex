defmodule Cadmium.ValenceKubeStub do
  @moduledoc """
  Minimal `Cadmium.Kube.Client` for Valence/Workloads tests. Only `list_pods/1` is
  functional: it returns whatever was set with `put/1` and records the options it got.
  """
  @behaviour Cadmium.Kube.Client

  @key {__MODULE__, :list_pods}

  @doc "Sets the `list_pods/1` result, e.g. `{:ok, pods}` or `{:error, :timeout}`."
  def put(result), do: :persistent_term.put(@key, result)
  def reset, do: :persistent_term.erase(@key)

  @doc "Options of every `list_pods/1` call so far, oldest first."
  def calls, do: Enum.reverse(:persistent_term.get({__MODULE__, :calls}, []))
  def reset_calls, do: :persistent_term.erase({__MODULE__, :calls})

  @impl true
  def list_pods(opts) do
    :persistent_term.put({__MODULE__, :calls}, [
      opts | :persistent_term.get({__MODULE__, :calls}, [])
    ])

    :persistent_term.get(@key, {:ok, []})
  end

  @impl true
  def list_nodes, do: {:ok, []}
  @impl true
  def list_pdbs, do: {:ok, []}
  @impl true
  def workload_replicas(_namespace, _kind, _name), do: {:error, :not_found}
  @impl true
  def evict_pod(_namespace, _name, _opts), do: {:error, :not_implemented}
  @impl true
  def add_node_taint(_node, _taint), do: {:error, :not_implemented}
  @impl true
  def remove_node_taint(_node, _key), do: {:error, :not_implemented}
  @impl true
  def get_lease(_namespace, _name), do: {:error, :not_found}
  @impl true
  def create_lease(_lease), do: {:error, :not_implemented}
  @impl true
  def update_lease(_lease), do: {:error, :not_implemented}
end
