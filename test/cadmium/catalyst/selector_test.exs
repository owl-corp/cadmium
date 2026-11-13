defmodule Cadmium.Catalyst.SelectorTest do
  use ExUnit.Case, async: true

  import Cadmium.CatalystFixtures

  alias Cadmium.Catalyst.Selector
  alias Cadmium.Kube.Pod

  @labels %{"app" => "web", "tier" => "frontend"}

  defp expr(key, operator, values \\ []),
    do: %{"key" => key, "operator" => operator, "values" => values}

  test "an empty selector matches everything" do
    assert Selector.matches?(pdb("all"), @labels)
    assert Selector.matches?(pdb("all"), %{})
  end

  test "matchLabels requires every label to be equal" do
    assert Selector.matches?(pdb("p", match_labels: %{"app" => "web"}), @labels)
    assert Selector.matches?(pdb("p", match_labels: @labels), @labels)
    refute Selector.matches?(pdb("p", match_labels: %{"app" => "api"}), @labels)
    refute Selector.matches?(pdb("p", match_labels: %{"app" => "web", "zone" => "a"}), @labels)
    refute Selector.matches?(pdb("p", match_labels: %{"app" => "web"}), %{})
  end

  test "In" do
    assert Selector.matches?(
             pdb("p", match_expressions: [expr("app", "In", ["api", "web"])]),
             @labels
           )

    refute Selector.matches?(pdb("p", match_expressions: [expr("app", "In", ["api"])]), @labels)
    refute Selector.matches?(pdb("p", match_expressions: [expr("zone", "In", ["a"])]), @labels)
  end

  test "NotIn (a missing label matches)" do
    assert Selector.matches?(
             pdb("p", match_expressions: [expr("app", "NotIn", ["api"])]),
             @labels
           )

    refute Selector.matches?(
             pdb("p", match_expressions: [expr("app", "NotIn", ["web"])]),
             @labels
           )

    assert Selector.matches?(pdb("p", match_expressions: [expr("zone", "NotIn", ["a"])]), @labels)
  end

  test "Exists and DoesNotExist" do
    assert Selector.matches?(pdb("p", match_expressions: [expr("tier", "Exists")]), @labels)
    refute Selector.matches?(pdb("p", match_expressions: [expr("zone", "Exists")]), @labels)
    assert Selector.matches?(pdb("p", match_expressions: [expr("zone", "DoesNotExist")]), @labels)
    refute Selector.matches?(pdb("p", match_expressions: [expr("tier", "DoesNotExist")]), @labels)
  end

  test "matchLabels and all expressions are ANDed" do
    pdb =
      pdb("p",
        match_labels: %{"app" => "web"},
        match_expressions: [expr("tier", "In", ["frontend"]), expr("zone", "DoesNotExist")]
      )

    assert Selector.matches?(pdb, @labels)
    refute Selector.matches?(pdb, Map.put(@labels, "zone", "a"))
    refute Selector.matches?(pdb, Map.put(@labels, "tier", "backend"))
  end

  test "expressions with atom keys are understood" do
    pdb = pdb("p", match_expressions: [%{key: "app", operator: "In", values: ["web"]}])
    assert Selector.matches?(pdb, @labels)
    refute Selector.matches?(pdb, %{"app" => "api"})
  end

  test "unknown operators and malformed expressions match (so the PDB can still block)" do
    assert Selector.matches?(pdb("p", match_expressions: [expr("app", "Gt", ["1"])]), @labels)
    assert Selector.matches?(pdb("p", match_expressions: [%{"operator" => "In"}]), @labels)
    assert Selector.matches?(pdb("p", match_expressions: ["garbage"]), @labels)
  end

  describe "blocked?/2" do
    defp pod(labels, namespace \\ "default"),
      do: %Pod{namespace: namespace, name: "p", uid: "u", labels: labels}

    test "blocks only for a matching PDB in the same namespace with no disruptions left" do
      blocking = pdb("b", match_labels: %{"app" => "web"}, disruptions_allowed: 0)
      allowing = pdb("a", match_labels: %{"app" => "web"}, disruptions_allowed: 1)

      assert Selector.blocked?([blocking], pod(@labels))
      refute Selector.blocked?([allowing], pod(@labels))
      assert Selector.blocked?([allowing, blocking], pod(@labels))
      refute Selector.blocked?([blocking], pod(%{"app" => "api"}))
      refute Selector.blocked?([blocking], pod(@labels, "other"))
      refute Selector.blocked?([], pod(@labels))
    end

    test "an empty selector covers every pod in its namespace only" do
      everything = pdb("all", disruptions_allowed: 0)
      assert Selector.blocked?([everything], pod(%{}))
      assert Selector.blocked?([everything], pod(@labels))
      refute Selector.blocked?([everything], pod(@labels, "other"))
    end

    test "a PDB with an unusable disruptions_allowed blocks" do
      assert Selector.blocked?([pdb("p", disruptions_allowed: nil)], pod(@labels))
    end
  end
end
