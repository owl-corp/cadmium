defmodule Cadmium.Catalyst.Move do
  @moduledoc "A proposed eviction of one workload off a hot node."

  @type t :: %__MODULE__{
          workload: Cadmium.Workload.t(),
          from_node: String.t(),
          reason: String.t()
        }

  @enforce_keys [:workload, :from_node]
  defstruct [:workload, :from_node, :reason]
end

defmodule Cadmium.Catalyst.Plan do
  @moduledoc """
  The outcome of one evaluation: whether the cluster is imbalanced, which nodes are
  hot/cool, which moves would be made, and which candidates were rejected and why.
  Producing a plan has no side effects; this is what dry-run/simulation shows.

  Rejection reasons: `:namespace_excluded`, `:daemonset`, `:mirror_pod`, `:unmanaged`,
  `:local_storage`, `:single_replica`, `:replicas_not_ready`, `:pdb_blocked`,
  `:workload_cooldown`, `:opted_out`, `:deleting`, `:not_running`, `:job`.
  """

  alias Cadmium.Catalyst.Move
  alias Cadmium.Valence.NodeScore

  @type status :: :balanced | :imbalanced | :not_sustained | :cooling_down | :insufficient_nodes
  @type t :: %__MODULE__{
          generated_at: integer(),
          status: status(),
          summary: String.t(),
          hot: [NodeScore.t()],
          cool: [NodeScore.t()],
          moves: [Move.t()],
          rejected: [{Cadmium.Workload.t(), atom()}]
        }

  @enforce_keys [:generated_at, :status]
  defstruct [:generated_at, :status, summary: "", hot: [], cool: [], moves: [], rejected: []]
end

defmodule Cadmium.Catalyst.Action do
  @moduledoc """
  One audit-log entry. Everything Catalyst does (or would have done in dry-run) is
  recorded as an Action and broadcast cluster-wide.
  """

  @type type ::
          :evict | :taint | :untaint | :leader_acquired | :leader_lost | :settings_changed
  @type t :: %__MODULE__{
          id: String.t(),
          ts: integer(),
          type: type(),
          dry_run?: boolean(),
          actor: String.t() | nil,
          node: String.t() | nil,
          namespace: String.t() | nil,
          pod: String.t() | nil,
          reason: String.t() | nil,
          result: :ok | :simulated | {:error, term()},
          details: map()
        }

  @enforce_keys [:id, :ts, :type]
  defstruct [
    :id,
    :ts,
    :type,
    # Kubernetes node name of the agent that performed the action
    :actor,
    :node,
    :namespace,
    :pod,
    :reason,
    dry_run?: false,
    result: :ok,
    details: %{}
  ]
end
