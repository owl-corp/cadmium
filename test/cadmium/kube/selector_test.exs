defmodule Cadmium.Kube.SelectorTest do
  use ExUnit.Case, async: true

  alias Cadmium.Kube.{PDB, Pod, Selector}

  test "matchLabels must all match" do
    assert Selector.matches?(%{"app" => "web"}, [], %{"app" => "web", "tier" => "front"})
    refute Selector.matches?(%{"app" => "web", "tier" => "back"}, [], %{"app" => "web"})
    assert Selector.matches?(%{}, [], %{})
  end

  test "matchExpressions operators" do
    labels = %{"app" => "web", "tier" => "front"}

    expression = fn operator, values ->
      [%{"key" => "tier", "operator" => operator, "values" => values}]
    end

    assert Selector.matches?(%{}, expression.("In", ["front", "edge"]), labels)
    refute Selector.matches?(%{}, expression.("In", ["back"]), labels)
    assert Selector.matches?(%{}, expression.("NotIn", ["back"]), labels)
    refute Selector.matches?(%{}, expression.("NotIn", ["front"]), labels)
    assert Selector.matches?(%{}, expression.("Exists", nil), labels)
    refute Selector.matches?(%{}, expression.("DoesNotExist", nil), labels)
    assert Selector.matches?(%{}, [%{key: "zone", operator: "DoesNotExist"}], labels)
    assert Selector.matches?(%{}, [%{key: "zone", operator: "NotIn", values: ["a"]}], labels)
    refute Selector.matches?(%{}, expression.("Bogus", []), labels)
  end

  test "pdb_matches?/2 is namespaced" do
    pod = %Pod{namespace: "shop", name: "p", uid: "u", labels: %{"app" => "web"}}
    pdb = %PDB{namespace: "shop", name: "x", match_labels: %{"app" => "web"}}

    assert Selector.pdb_matches?(pdb, pod)
    refute Selector.pdb_matches?(%{pdb | namespace: "data"}, pod)
    refute Selector.pdb_matches?(%{pdb | match_labels: %{"app" => "api"}}, pod)
  end
end
