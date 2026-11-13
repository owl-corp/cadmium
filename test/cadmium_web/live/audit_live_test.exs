defmodule CadmiumWeb.AuditLiveTest do
  use CadmiumWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CadmiumWeb.DashboardFixtures, as: Fixtures

  defp row_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#audit-actions > tr")
    |> LazyHTML.attribute("id")
  end

  defp publish(action) do
    Phoenix.PubSub.local_broadcast(
      Cadmium.PubSub,
      Cadmium.Catalyst.topic(),
      {:catalyst_action, action}
    )
  end

  describe "with the stub subsystems" do
    test "renders an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert has_element?(view, "#audit-empty", "No rebalancing actions yet")
      assert has_element?(view, "#audit-count", "0")
      assert has_element?(view, "#nav-audit[aria-current=page]")
    end

    test "the first live action replaces the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      publish(Fixtures.action("first", :taint, node: "node-a"))

      assert has_element?(view, "#action-first")
      refute has_element?(view, "#audit-empty")
      assert has_element?(view, "#audit-count", "1")
    end
  end

  describe "with actions" do
    setup {Fixtures, :install}

    test "lists entries newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert row_order(view) == ~w(action-a4 action-a3 action-a2 action-a1)
      assert has_element?(view, "#audit-count", "4")
      refute has_element?(view, "#audit-empty")
    end

    test "shows type, dry-run marker, target, reason, result and actor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert has_element?(view, "#action-a4[data-type=evict][data-dry-run=true]")
      assert has_element?(view, "#action-a4 [data-marker=dry-run]")
      assert has_element?(view, "#action-a4", "shop/")
      assert has_element?(view, "#action-a4", "web-1")
      assert has_element?(view, "#action-a4", "cpu drift 2.8x on hot node")
      assert has_element?(view, "#action-a4 [data-result=simulated]")
      assert has_element?(view, "#action-a4", "node-b")
      assert has_element?(view, "#action-a4 time[datetime]")
      assert has_element?(view, "#action-a4-ago", "ago")

      refute has_element?(view, "#action-a3 [data-marker=dry-run]")
      assert has_element?(view, "#action-a3 [data-result=error]", "eviction blocked by budget")
      assert has_element?(view, "#action-a2 [data-result=ok]")
      assert has_element?(view, "#action-a1", "cluster")
    end

    test "prepends new actions live", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      publish(Fixtures.action("a5", :untaint, node: "node-a", reason: "node cooldown expired"))

      assert hd(row_order(view)) == "action-a5"
      assert has_element?(view, "#action-a5", "node cooldown expired")
      assert has_element?(view, "#audit-count", "5")
    end

    test "filters by type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      view |> element("#audit-type-evict") |> render_click()
      assert_patch(view, ~p"/audit?type=evict")
      assert row_order(view) == ~w(action-a4 action-a3)
      assert has_element?(view, "#audit-type-evict[aria-pressed=true]")

      view |> element("#audit-type-settings") |> render_click()
      assert_patch(view, ~p"/audit?type=settings")
      assert row_order(view) == ~w(action-a1)

      view |> element("#audit-type-all") |> render_click()
      assert_patch(view, ~p"/audit")
      assert length(row_order(view)) == 4
    end

    test "filters dry-run vs live, combined with type from the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit?type=evict&mode=live")
      assert row_order(view) == ~w(action-a3)

      view |> element("#audit-mode-dry") |> render_click()
      assert_patch(view, ~p"/audit?mode=dry&type=evict")
      assert row_order(view) == ~w(action-a4)
    end

    test "live actions respect the active filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit?type=evict&mode=dry")

      publish(Fixtures.action("live-evict", :evict, pod: "x", namespace: "shop"))
      publish(Fixtures.action("dry-taint", :taint, dry_run?: true, node: "node-a"))
      publish(Fixtures.action("dry-evict", :evict, dry_run?: true, result: :simulated))

      assert row_order(view) == ~w(action-dry-evict action-a4)
    end

    test "a filter with no matches says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit?type=leader")

      assert row_order(view) == []
      assert has_element?(view, "#audit-empty", "No actions match this filter")
    end
  end
end
