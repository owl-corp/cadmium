defmodule Cadmium.Kube.Pod do
  @moduledoc "The subset of a Kubernetes Pod that Cadmium reasons about."

  @type t :: %__MODULE__{
          namespace: String.t(),
          name: String.t(),
          uid: String.t(),
          node_name: String.t() | nil,
          phase: String.t() | nil,
          labels: %{String.t() => String.t()},
          annotations: %{String.t() => String.t()},
          owner_kind: String.t() | nil,
          owner_name: String.t() | nil,
          cpu_request_millis: non_neg_integer(),
          cpu_limit_millis: non_neg_integer() | nil,
          memory_request_bytes: non_neg_integer(),
          memory_limit_bytes: non_neg_integer() | nil,
          qos_class: String.t() | nil,
          priority_class: String.t() | nil,
          local_storage?: boolean(),
          mirror?: boolean(),
          deleting?: boolean(),
          created_at: DateTime.t() | nil
        }

  @enforce_keys [:namespace, :name, :uid]
  defstruct [
    :namespace,
    :name,
    :uid,
    :node_name,
    :phase,
    # immediate controller ownerReference ("ReplicaSet", "StatefulSet", "DaemonSet", "Job", nil)
    :owner_kind,
    :owner_name,
    :cpu_limit_millis,
    :memory_limit_bytes,
    :qos_class,
    :priority_class,
    :created_at,
    labels: %{},
    annotations: %{},
    # summed over containers; 0 when unset
    cpu_request_millis: 0,
    memory_request_bytes: 0,
    # true when any volume is hostPath; emptyDir is disposable
    local_storage?: false,
    # static/mirror pod (kubernetes.io/config.mirror annotation)
    mirror?: false,
    # metadata.deletionTimestamp is set
    deleting?: false
  ]
end

defmodule Cadmium.Kube.Node do
  @moduledoc "The subset of a Kubernetes Node that Cadmium reasons about."

  @type taint :: %{key: String.t(), value: String.t() | nil, effect: String.t()}
  @type t :: %__MODULE__{
          name: String.t(),
          labels: %{String.t() => String.t()},
          taints: [taint()],
          unschedulable?: boolean(),
          ready?: boolean(),
          allocatable_cpu_millis: non_neg_integer(),
          allocatable_memory_bytes: non_neg_integer()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    labels: %{},
    taints: [],
    unschedulable?: false,
    ready?: true,
    allocatable_cpu_millis: 0,
    allocatable_memory_bytes: 0
  ]
end

defmodule Cadmium.Kube.PDB do
  @moduledoc "A PodDisruptionBudget: its label selector and how many disruptions it allows now."

  @type t :: %__MODULE__{
          namespace: String.t(),
          name: String.t(),
          match_labels: %{String.t() => String.t()},
          match_expressions: [map()],
          disruptions_allowed: non_neg_integer()
        }

  @enforce_keys [:namespace, :name]
  defstruct [:namespace, :name, match_labels: %{}, match_expressions: [], disruptions_allowed: 0]
end

defmodule Cadmium.Kube.Lease do
  @moduledoc "A coordination.k8s.io/v1 Lease, used for Catalyst leader election."

  @type t :: %__MODULE__{
          namespace: String.t(),
          name: String.t(),
          holder: String.t() | nil,
          acquire_time: DateTime.t() | nil,
          renew_time: DateTime.t() | nil,
          duration_seconds: pos_integer() | nil,
          transitions: non_neg_integer(),
          resource_version: String.t() | nil
        }

  @enforce_keys [:namespace, :name]
  defstruct [
    :namespace,
    :name,
    :holder,
    :acquire_time,
    :renew_time,
    :duration_seconds,
    :resource_version,
    transitions: 0
  ]
end
