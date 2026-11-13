defmodule Cadmium.Kube.Client do
  @moduledoc """
  Behaviour for talking to the Kubernetes API. `Cadmium.Kube` dispatches to the module
  configured as `config :cadmium, :kube_client`.

  Implementations: `Cadmium.Kube.HTTP` (in-cluster, Req) and `Cadmium.Kube.Fake`
  (in-memory, for dev and tests).
  """

  alias Cadmium.Kube.{Lease, Node, PDB, Pod}

  @type error :: {:error, term()}

  @doc "Lists pods. Options: `:node` (spec.nodeName), `:namespace`."
  @callback list_pods(keyword()) :: {:ok, [Pod.t()]} | error
  @callback list_nodes() :: {:ok, [Node.t()]} | error
  @doc "Lists PodDisruptionBudgets in all namespaces."
  @callback list_pdbs() :: {:ok, [PDB.t()]} | error

  @doc """
  Replica counts for a pod's controller. `kind` is the pod's `owner_kind`
  ("ReplicaSet", "StatefulSet", "Deployment", ...).
  """
  @callback workload_replicas(namespace :: String.t(), kind :: String.t(), name :: String.t()) ::
              {:ok, %{desired: non_neg_integer(), ready: non_neg_integer()}}
              | {:error, :not_found | :unsupported_kind | term()}

  @doc """
  Evicts a pod through the policy/v1 Eviction subresource (so the API server enforces
  PDBs). Options: `:dry_run` (boolean, sends `dryRun: ["All"]`).
  Returns `{:error, :pdb_blocked}` on HTTP 429 and `{:error, :not_found}` on 404.
  """
  @callback evict_pod(namespace :: String.t(), name :: String.t(), keyword()) :: :ok | error

  @doc "Adds (or replaces, by key) a taint on a node."
  @callback add_node_taint(node :: String.t(), Node.taint()) :: :ok | error
  @doc "Removes every taint with the given key from a node. Idempotent."
  @callback remove_node_taint(node :: String.t(), key :: String.t()) :: :ok | error

  @callback get_lease(namespace :: String.t(), name :: String.t()) ::
              {:ok, Lease.t()} | {:error, :not_found | term()}
  @doc "Creates a lease. `{:error, :conflict}` if it already exists."
  @callback create_lease(Lease.t()) :: {:ok, Lease.t()} | {:error, :conflict | term()}
  @doc "Replaces a lease, guarded by `resource_version`. `{:error, :conflict}` if it moved."
  @callback update_lease(Lease.t()) :: {:ok, Lease.t()} | {:error, :conflict | term()}
end
