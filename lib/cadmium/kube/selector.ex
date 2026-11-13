defmodule Cadmium.Kube.Selector do
  @moduledoc """
  Kubernetes label selector matching (`matchLabels` and `matchExpressions`), as used by
  PodDisruptionBudgets.
  """

  alias Cadmium.Kube.{PDB, Pod}

  @doc "True when the PDB is in the pod's namespace and its selector matches the pod's labels."
  @spec pdb_matches?(PDB.t(), Pod.t()) :: boolean()
  def pdb_matches?(%PDB{} = pdb, %Pod{} = pod) do
    pdb.namespace == pod.namespace and
      matches?(pdb.match_labels, pdb.match_expressions, pod.labels)
  end

  @doc """
  True when `labels` satisfy every `match_labels` entry and every expression. Expressions
  are maps with `"key"`, `"operator"` (`In`, `NotIn`, `Exists`, `DoesNotExist`) and
  `"values"` (atom keys are accepted too). An empty selector matches everything, as in
  policy/v1.
  """
  @spec matches?(map(), [map()], map()) :: boolean()
  def matches?(match_labels, match_expressions, labels) do
    Enum.all?(match_labels || %{}, fn {key, value} -> Map.get(labels, key) == value end) and
      Enum.all?(match_expressions || [], &expression_matches?(&1, labels))
  end

  defp expression_matches?(expression, labels) do
    key = field(expression, "key", :key)
    values = field(expression, "values", :values) || []

    case field(expression, "operator", :operator) do
      "In" -> Map.has_key?(labels, key) and Map.get(labels, key) in values
      "NotIn" -> Map.get(labels, key) not in values
      "Exists" -> Map.has_key?(labels, key)
      "DoesNotExist" -> not Map.has_key?(labels, key)
      _ -> false
    end
  end

  defp field(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)
end
