defmodule Cadmium.Kube.Decode do
  @moduledoc """
  Pure translation between Kubernetes API JSON (already decoded into string-keyed maps)
  and the structs in `Cadmium.Kube` (`Pod`, `Node`, `PDB`, `Lease`).

  Also parses Kubernetes resource quantities: `cpu_millis/1` and `memory_bytes/1`.
  """

  alias Cadmium.Kube.{Lease, Node, PDB, Pod}

  @mirror_annotation "kubernetes.io/config.mirror"

  # {numerator, denominator} multipliers for every quantity suffix
  @suffixes %{
    "" => {1, 1},
    "n" => {1, 1_000_000_000},
    "u" => {1, 1_000_000},
    "m" => {1, 1_000},
    "k" => {1_000, 1},
    "M" => {1_000_000, 1},
    "G" => {1_000_000_000, 1},
    "T" => {1_000_000_000_000, 1},
    "P" => {1_000_000_000_000_000, 1},
    "E" => {1_000_000_000_000_000_000, 1},
    "Ki" => {1_024, 1},
    "Mi" => {1_048_576, 1},
    "Gi" => {1_073_741_824, 1},
    "Ti" => {1_099_511_627_776, 1},
    "Pi" => {1_125_899_906_842_624, 1},
    "Ei" => {1_152_921_504_606_846_976, 1}
  }

  @quantity ~r/^(?<sign>[+-]?)(?<int>\d*)(?:\.(?<frac>\d*))?(?:[eE](?<exp>[+-]?\d+)|(?<suffix>Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE]))?$/

  ## Quantities

  @doc """
  Parses a CPU quantity into millicores, rounding up like the API server does.

      iex> Cadmium.Kube.Decode.cpu_millis("250m")
      250
      iex> Cadmium.Kube.Decode.cpu_millis("0.5")
      500
      iex> Cadmium.Kube.Decode.cpu_millis("2500u")
      3

  Missing or unparseable quantities are 0.
  """
  @spec cpu_millis(term()) :: non_neg_integer()
  def cpu_millis(quantity), do: scaled(quantity, 1_000)

  @doc """
  Parses a memory quantity into bytes, rounding up.

      iex> Cadmium.Kube.Decode.memory_bytes("128Mi")
      134217728
      iex> Cadmium.Kube.Decode.memory_bytes("1e3")
      1000
      iex> Cadmium.Kube.Decode.memory_bytes("1500m")
      2

  Missing or unparseable quantities are 0.
  """
  @spec memory_bytes(term()) :: non_neg_integer()
  def memory_bytes(quantity), do: scaled(quantity, 1)

  @doc """
  Parses a quantity into an exact rational `{numerator, denominator}` of base units.
  """
  @spec parse_quantity(term()) :: {:ok, {integer(), pos_integer()}} | :error
  def parse_quantity(quantity) when is_integer(quantity), do: {:ok, {quantity, 1}}

  def parse_quantity(quantity) when is_float(quantity),
    do: quantity |> :erlang.float_to_binary([:short]) |> parse_quantity()

  def parse_quantity(quantity) when is_binary(quantity) do
    case Regex.named_captures(@quantity, String.trim(quantity)) do
      %{"int" => "", "frac" => ""} ->
        :error

      %{"sign" => sign, "int" => int, "frac" => frac, "exp" => exp, "suffix" => suffix} ->
        digits = String.to_integer("0" <> int <> frac)
        digits = if sign == "-", do: -digits, else: digits
        {num, den} = Map.fetch!(@suffixes, suffix)
        exponent = if(exp == "", do: 0, else: String.to_integer(exp)) - byte_size(frac)

        if exponent >= 0 do
          {:ok, {digits * num * Integer.pow(10, exponent), den}}
        else
          {:ok, {digits * num, den * Integer.pow(10, -exponent)}}
        end

      nil ->
        :error
    end
  end

  def parse_quantity(_quantity), do: :error

  defp scaled(quantity, factor) do
    case parse_quantity(quantity) do
      {:ok, {num, den}} when num > 0 -> div(num * factor + den - 1, den)
      _ -> 0
    end
  end

  ## Lists

  @doc "Decodes the `items` of a list response with `fun`."
  @spec items(map(), (map() -> struct)) :: [struct] when struct: var
  def items(body, fun) when is_map(body), do: Enum.map(body["items"] || [], fun)

  @doc "The `metadata.continue` token of a list response, or nil when the list is complete."
  @spec continue_token(map()) :: String.t() | nil
  def continue_token(body) do
    case get_in(body, ["metadata", "continue"]) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  ## Pods

  @doc """
  Decodes a v1 Pod.

  Requests follow the Kubernetes effective-request rule in its simple form: the larger of
  (the sum over regular containers plus restartable "sidecar" init containers) and (the
  largest ordinary init container). Limits are the sum over regular containers, and nil
  unless every regular container sets one.
  """
  @spec pod(map()) :: Pod.t()
  def pod(obj) do
    meta = obj["metadata"] || %{}
    spec = obj["spec"] || %{}
    status = obj["status"] || %{}
    containers = spec["containers"] || []
    annotations = meta["annotations"] || %{}
    owner = Enum.find(meta["ownerReferences"] || [], &(&1["controller"] == true)) || %{}

    {sidecars, inits} =
      Enum.split_with(spec["initContainers"] || [], &(&1["restartPolicy"] == "Always"))

    %Pod{
      namespace: meta["namespace"],
      name: meta["name"],
      uid: meta["uid"],
      node_name: spec["nodeName"],
      phase: status["phase"],
      labels: meta["labels"] || %{},
      annotations: annotations,
      owner_kind: owner["kind"],
      owner_name: owner["name"],
      cpu_request_millis: request(containers, sidecars, inits, "cpu", &cpu_millis/1),
      cpu_limit_millis: limit(containers, "cpu", &cpu_millis/1),
      memory_request_bytes: request(containers, sidecars, inits, "memory", &memory_bytes/1),
      memory_limit_bytes: limit(containers, "memory", &memory_bytes/1),
      qos_class: status["qosClass"],
      priority_class: spec["priorityClassName"],
      local_storage?:
        Enum.any?(spec["volumes"] || [], &(is_map(&1["emptyDir"]) or is_map(&1["hostPath"]))),
      mirror?: Map.has_key?(annotations, @mirror_annotation),
      deleting?: meta["deletionTimestamp"] != nil,
      created_at: datetime(meta["creationTimestamp"])
    }
  end

  defp request(containers, sidecars, inits, resource, parse) do
    value = fn container -> parse.(get_in(container, ["resources", "requests", resource])) end
    steady = containers |> Enum.concat(sidecars) |> Enum.map(value) |> Enum.sum()
    startup = inits |> Enum.map(value) |> Enum.max(fn -> 0 end)
    max(steady, startup)
  end

  defp limit([], _resource, _parse), do: nil

  defp limit(containers, resource, parse) do
    limits = Enum.map(containers, &get_in(&1, ["resources", "limits", resource]))

    if Enum.all?(limits, &(&1 != nil)) do
      limits |> Enum.map(parse) |> Enum.sum()
    end
  end

  ## Nodes

  @doc "Decodes a v1 Node."
  @spec node(map()) :: Node.t()
  def node(obj) do
    meta = obj["metadata"] || %{}
    spec = obj["spec"] || %{}
    status = obj["status"] || %{}
    allocatable = status["allocatable"] || %{}

    %Node{
      name: meta["name"],
      labels: meta["labels"] || %{},
      taints: Enum.map(spec["taints"] || [], &taint/1),
      unschedulable?: spec["unschedulable"] == true,
      ready?:
        Enum.any?(status["conditions"] || [], &(&1["type"] == "Ready" and &1["status"] == "True")),
      allocatable_cpu_millis: cpu_millis(allocatable["cpu"]),
      allocatable_memory_bytes: memory_bytes(allocatable["memory"])
    }
  end

  @doc "Decodes a taint from a Node's `spec.taints`."
  @spec taint(map()) :: Node.taint()
  def taint(raw), do: %{key: raw["key"], value: raw["value"], effect: raw["effect"]}

  @doc "Encodes a taint for a Node's `spec.taints` (the value is omitted when nil)."
  @spec encode_taint(Node.taint()) :: map()
  def encode_taint(%{key: key, effect: effect} = taint) do
    case Map.get(taint, :value) do
      nil -> %{"key" => key, "effect" => effect}
      value -> %{"key" => key, "value" => value, "effect" => effect}
    end
  end

  ## PodDisruptionBudgets

  @doc "Decodes a policy/v1 PodDisruptionBudget."
  @spec pdb(map()) :: PDB.t()
  def pdb(obj) do
    meta = obj["metadata"] || %{}
    selector = get_in(obj, ["spec", "selector"]) || %{}

    %PDB{
      namespace: meta["namespace"],
      name: meta["name"],
      match_labels: selector["matchLabels"] || %{},
      match_expressions: selector["matchExpressions"] || [],
      disruptions_allowed: get_in(obj, ["status", "disruptionsAllowed"]) || 0
    }
  end

  ## Workloads

  @doc "Replica counts of a ReplicaSet, StatefulSet, Deployment or ReplicationController."
  @spec replicas(map()) :: %{desired: non_neg_integer(), ready: non_neg_integer()}
  def replicas(obj) do
    %{
      desired: get_in(obj, ["spec", "replicas"]) || 0,
      ready: get_in(obj, ["status", "readyReplicas"]) || 0
    }
  end

  ## Leases

  @doc "Decodes a coordination.k8s.io/v1 Lease."
  @spec lease(map()) :: Lease.t()
  def lease(obj) do
    meta = obj["metadata"] || %{}
    spec = obj["spec"] || %{}

    %Lease{
      namespace: meta["namespace"],
      name: meta["name"],
      holder: if(spec["holderIdentity"] in [nil, ""], do: nil, else: spec["holderIdentity"]),
      acquire_time: datetime(spec["acquireTime"]),
      renew_time: datetime(spec["renewTime"]),
      duration_seconds: spec["leaseDurationSeconds"],
      transitions: spec["leaseTransitions"] || 0,
      resource_version: meta["resourceVersion"]
    }
  end

  @doc """
  Encodes a Lease as a coordination.k8s.io/v1 object. Nil fields are omitted, so a lease
  with a nil holder is a released lease.
  """
  @spec encode_lease(Lease.t()) :: map()
  def encode_lease(%Lease{} = lease) do
    metadata =
      compact(%{
        "namespace" => lease.namespace,
        "name" => lease.name,
        "resourceVersion" => lease.resource_version
      })

    spec =
      compact(%{
        "holderIdentity" => lease.holder,
        "acquireTime" => micro_time(lease.acquire_time),
        "renewTime" => micro_time(lease.renew_time),
        "leaseDurationSeconds" => lease.duration_seconds,
        "leaseTransitions" => lease.transitions
      })

    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => metadata,
      "spec" => spec
    }
  end

  ## Time

  @doc "Parses an RFC 3339 timestamp; nil when missing or invalid."
  @spec datetime(term()) :: DateTime.t() | nil
  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def datetime(_value), do: nil

  @doc """
  Formats a DateTime as a Kubernetes MicroTime (RFC 3339, UTC, exactly six fractional digits).
  """
  @spec micro_time(DateTime.t() | nil) :: String.t() | nil
  def micro_time(nil), do: nil

  def micro_time(%DateTime{} = datetime) do
    utc = DateTime.shift_zone!(datetime, "Etc/UTC")
    {micros, _precision} = utc.microsecond
    DateTime.to_iso8601(%{utc | microsecond: {micros, 6}})
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> value == nil end)
end
