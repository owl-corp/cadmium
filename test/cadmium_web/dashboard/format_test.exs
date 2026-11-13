defmodule CadmiumWeb.Dashboard.FormatTest do
  use ExUnit.Case, async: true

  alias CadmiumWeb.Dashboard.Format

  @mi 1024 * 1024

  test "heat levels cover the score range and line up with the hot threshold" do
    assert Enum.map([0, 24.9, 25, 49.9, 50, 69.9, 70, 84.9, 85, 100], &Format.heat_level/1) ==
             [0, 0, 1, 1, 2, 2, 3, 3, 4, 4]

    assert Format.heat_class(72.0) == "heat-3"
    assert Format.heat_label(72.0) == "hot"
    assert Format.heat_level(nil) == 0
  end

  test "cpu in millicores and cores" do
    assert Format.cpu(250) == "250m"
    assert Format.cpu(999.6) == "1000m"
    assert Format.cpu(1000) == "1 core"
    assert Format.cpu(1500) == "1.5 cores"
    assert Format.cpu(2250.0) == "2.25 cores"
    assert Format.cpu(nil) == "–"
  end

  test "memory in binary units" do
    assert Format.bytes(64 * @mi) == "64 Mi"
    assert Format.bytes(1024 * @mi) == "1 Gi"
    assert Format.bytes(1536 * @mi) == "1.5 Gi"
    assert Format.bytes(2048) == "2 Ki"
    assert Format.bytes(nil) == "–"
  end

  test "ratios, percentages and durations" do
    assert Format.ratio(2.8) == "2.80x"
    assert Format.ratio(12.4) == "12x"
    assert Format.ratio(nil) == "–"
    assert Format.percent(0.256) == "26%"
    assert Format.psi(7.52) == "7.5%"
    assert Format.duration(45_000) == "45s"
    assert Format.duration(252_000) == "4m 12s"
    assert Format.duration(7_500_000) == "2h 5m"
    assert Format.duration(-5) == "0s"
    assert Format.ago(1_000, 1_500) == "just now"
    assert Format.ago(1_000, 13_000) == "12s ago"
    assert Format.ago(nil, 13_000) == "never"
  end

  test "every rejection reason documented in Cadmium.Catalyst.Plan has a human explanation" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Cadmium.Catalyst.Plan)

    documented =
      ~r/`:([a-z_]+)`/
      |> Regex.scan(moduledoc, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)

    assert length(documented) == 13
    assert Enum.sort(documented) == Enum.sort(Format.rejection_reasons())

    for reason <- documented do
      {title, explanation} = Format.rejection(reason)
      assert title != "" and explanation != ""
      refute explanation =~ "Rejected by the planner"
    end

    assert Format.rejection(:pdb_blocked) |> elem(1) =~ "Blocked by a PodDisruptionBudget"
  end

  test "unknown vocabulary degrades gracefully" do
    assert Format.rejection(:brand_new_reason) ==
             {"Brand new reason", "Rejected by the planner (brand_new_reason)."}

    assert Format.plan_status(:something_else) == {"Something else", :neutral}
    assert Format.action_type(:something_else) == {"Something else", :neutral}
  end

  test "dom ids are selector-safe" do
    assert Format.dom_id("ip-10-0-1-17.eu-west-1.compute.internal") ==
             "ip-10-0-1-17-eu-west-1-compute-internal"
  end
end
