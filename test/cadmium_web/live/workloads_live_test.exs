defmodule CadmiumWeb.WorkloadsLiveTest do
  use CadmiumWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CadmiumWeb.DashboardFixtures, as: Fixtures

  defp row_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workloads > tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "wl-uid-", ""))
  end

  test "renders an empty state with the stub subsystems", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workloads")
    render_async(view)

    assert has_element?(view, "#workloads-empty")
    refute has_element?(view, "#workloads-loading")
    assert has_element?(view, "#nav-workloads[aria-current=page]")
  end

  describe "with workloads" do
    setup {Fixtures, :install}

    test "mount never waits for the fan-out", %{conn: conn} do
      document = conn |> get(~p"/workloads") |> html_response(200) |> LazyHTML.from_document()

      assert LazyHTML.query(document, "#workloads-loading") |> Enum.count() == 1
      assert LazyHTML.query(document, "#workloads > tr") |> Enum.count() == 0
    end

    test "lists workloads, worst CPU drift first, missing drift last", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      assert row_order(view) ==
               ~w(shop-web-1 shop-api-1 data-cache-0 batch-report-1 kube-system-kube-proxy-x)

      assert has_element?(view, "#workloads-count[data-shown='5'][data-matching='5']")
      refute has_element?(view, "#workloads-capped")
      assert has_element?(view, "#sort-cpu_drift")
      assert has_element?(view, "th[aria-sort=descending] #sort-cpu_drift")
    end

    test "shows request vs. actual in human units", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      assert has_element?(view, "#wl-uid-shop-web-1", "250m")
      assert has_element?(view, "#wl-uid-shop-web-1", "700m")
      assert has_element?(view, "#wl-uid-shop-web-1", "2.80x")
      assert has_element?(view, "#wl-uid-shop-web-1", "256 Mi")
      assert has_element?(view, "#wl-uid-data-cache-0", "1 core")
      assert has_element?(view, "#wl-uid-data-cache-0", "1 Gi")
      assert has_element?(view, "#wl-uid-shop-api-1", "1.5 Gi")
      assert has_element?(view, "#wl-uid-shop-api-1", "60%")
      assert has_element?(view, "#wl-uid-shop-api-1", "7.5%")
      assert has_element?(view, "#wl-uid-batch-report-1", "1.9 cores")
      assert has_element?(view, "#wl-uid-shop-web-1", "ReplicaSet/")
    end

    test "drift bars distinguish over- from under-request", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      # using more than requested
      assert has_element?(view, "#wl-uid-shop-web-1-cpu-drift[data-direction=over]")
      assert has_element?(view, "#wl-uid-shop-web-1-cpu-drift [data-mark='1.0x']")
      # using less than requested
      assert has_element?(view, "#wl-uid-shop-web-1-mem-drift[data-direction=under]")
      assert has_element?(view, "#wl-uid-data-cache-0-cpu-drift[data-direction=under]")
      # no request / no sample
      assert has_element?(view, "#wl-uid-batch-report-1-cpu-drift[data-direction=none]")
      assert has_element?(view, "#wl-uid-kube-system-kube-proxy-x-mem-drift[data-direction=none]")
    end

    test "sorts by column through the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      view |> element("#sort-pod") |> render_click()
      assert_patch(view, ~p"/workloads?sort=pod")

      assert row_order(view) ==
               ~w(batch-report-1 data-cache-0 kube-system-kube-proxy-x shop-api-1 shop-web-1)

      view |> element("#sort-pod") |> render_click()
      assert_patch(view, ~p"/workloads?dir=desc&sort=pod")
      assert hd(row_order(view)) == "shop-web-1"

      view |> element("#sort-mem_drift") |> render_click()
      assert_patch(view, ~p"/workloads?sort=mem_drift")
      assert hd(row_order(view)) == "shop-api-1"
    end

    test "restores sort and filters from URL params", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads?node=node-a&q=WEB&sort=mem_drift&dir=asc")
      render_async(view)

      assert row_order(view) == ["shop-web-1"]
      assert has_element?(view, "#workloads-count[data-shown='1'][data-matching='1']")
      assert has_element?(view, "th[aria-sort=ascending] #sort-mem_drift")
      assert has_element?(view, "#workload-filters-clear")
    end

    test "filters by namespace, node and pod search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      view |> form("#workload-filters", %{"ns" => "shop"}) |> render_change()
      assert_patch(view, ~p"/workloads?ns=shop")
      assert row_order(view) == ~w(shop-web-1 shop-api-1)

      view |> form("#workload-filters", %{"ns" => "", "node" => "node-b"}) |> render_change()
      assert_patch(view, ~p"/workloads?node=node-b")
      assert row_order(view) == ["data-cache-0"]

      view
      |> form("#workload-filters", %{"node" => "", "q" => "nothing-like-this"})
      |> render_change()

      assert_patch(view, ~p"/workloads?q=nothing-like-this")
      assert row_order(view) == []
      assert has_element?(view, "#workloads-no-match")

      view |> element("#workload-filters-clear") |> render_click()
      assert_patch(view, ~p"/workloads")
      assert length(row_order(view)) == 5
    end

    test "ignores unknown sort columns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads?sort=bogus&dir=sideways")
      render_async(view)

      assert hd(row_order(view)) == "shop-web-1"
    end

    test "caps rendered rows and says so", %{conn: conn} do
      workloads =
        for i <- 1..250 do
          Fixtures.workload("load", "pod-#{i}", "node-a", cpu_request: 100, cpu: i * 1.0)
        end

      Fixtures.put(:workloads, workloads)

      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      assert has_element?(view, "#workloads-count[data-shown='200'][data-matching='250']")
      assert has_element?(view, "#workloads-capped")
      assert length(row_order(view)) == 200
      # the worst offender is still first
      assert hd(row_order(view)) == "load-pod-250"
    end

    test "refreshes periodically", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workloads")
      render_async(view)

      Fixtures.put(:workloads, [Fixtures.workload("shop", "fresh-1", "node-a")])
      send(view.pid, :refresh)
      render_async(view)

      assert row_order(view) == ["shop-fresh-1"]
    end
  end
end
