defmodule Cadmium.Catalyst.Selector do
  @moduledoc """
  Kubernetes label-selector matching for PodDisruptionBudgets (pure).

  Supports `matchLabels` and `matchExpressions` with `In`, `NotIn`, `Exists` and
  `DoesNotExist`. An empty selector matches every pod in the PDB's namespace (policy/v1
  semantics). Anything we cannot interpret (unknown operator, malformed expression) is
  treated as *matching*: a PDB we do not understand must be able to block an eviction.
  """

  alias Cadmium.Kube.{PDB, Pod}

  @doc "True when the PDB is in the pod's namespace and its selector matches the pod's labels."
  @spec selects?(PDB.t(), Pod.t()) :: boolean()
  def selects?(%PDB{} = pdb, %Pod{} = pod) do
    pdb.namespace == pod.namespace and matches?(pdb, pod.labels || %{})
  end

  @doc "True when the PDB's selector matches the given labels (namespace not considered)."
  @spec matches?(PDB.t(), map()) :: boolean()
  def matches?(%PDB{match_labels: match_labels, match_expressions: expressions}, labels)
      when is_map(labels) do
    labels_match?(match_labels || %{}, labels) and
      Enum.all?(List.wrap(expressions), &expression_matches?(&1, labels))
  end

  def matches?(%PDB{}, _labels), do: true

  @doc "True when any PDB selecting the pod currently allows no disruptions."
  @spec blocked?([PDB.t()], Pod.t()) :: boolean()
  def blocked?(pdbs, %Pod{} = pod) when is_list(pdbs) do
    Enum.any?(pdbs, fn
      %PDB{} = pdb -> selects?(pdb, pod) and not allows_disruption?(pdb)
      _ -> true
    end)
  end

  defp allows_disruption?(%PDB{disruptions_allowed: n}), do: is_integer(n) and n > 0

  defp labels_match?(match_labels, labels) when is_map(match_labels) do
    Enum.all?(match_labels, fn {key, value} -> Map.get(labels, key) == value end)
  end

  defp labels_match?(_match_labels, _labels), do: true

  defp expression_matches?(expression, labels) when is_map(expression) do
    key = field(expression, :key)
    values = List.wrap(field(expression, :values))

    case {key, field(expression, :operator)} do
      {key, "In"} when is_binary(key) ->
        Map.has_key?(labels, key) and Map.get(labels, key) in values

      {key, "NotIn"} when is_binary(key) ->
        not Map.has_key?(labels, key) or Map.get(labels, key) not in values

      {key, "Exists"} when is_binary(key) ->
        Map.has_key?(labels, key)

      {key, "DoesNotExist"} when is_binary(key) ->
        not Map.has_key?(labels, key)

      _ ->
        true
    end
  end

  defp expression_matches?(_expression, _labels), do: true

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
