defmodule CadmiumWeb.ClusterLiveTest do
  use CadmiumWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CadmiumWeb.DashboardFixtures, as: Fixtures

  defp tile_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#node-grid > a")
    |> LazyHTML.attribute("data-node")
  end

  describe "with the stub subsystems" do
    test "renders the shell and an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#cluster-empty")
      refute has_element?(view, "#node-grid")
      assert has_element?(view, "#summary-nodes", "0")
      assert has_element?(view, "#summary-self", "test-node")
      assert has_element?(view, "#summary-leader", "no leader elected")
      assert has_element?(view, "#summary-mode-badge-dry-run")
      assert has_element?(view, "#summary-evaluated", "not yet")
      assert has_element?(view, "#summary-plan", "no plan yet")
      assert has_element?(view, "#nav-cluster[aria-current=page]")
    end

    test "a node that is not in the mesh gets an explanatory detail panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/ghost")
      render_async(view)

      assert has_element?(view, "#node-detail[data-node=ghost]")
      assert has_element?(view, "#node-detail-missing")
      assert has_element?(view, "#node-workloads-empty")
    end
  end

  describe "heatmap" do
    setup {Fixtures, :install}

    test "shows the header strip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#summary-nodes", "5")
      assert has_element?(view, "#summary-self", "test-node")
      assert has_element?(view, "#summary-leader", "node-b")
      assert has_element?(view, "#summary-mode-badge-dry-run")
      refute has_element?(view, "#summary-mode-badge-paused")
      assert has_element?(view, "#summary-evaluated", "ago")
      assert has_element?(view, "#summary-plan", "node-a is hot")
      assert has_element?(view, "#nav-mode-dry-run")
      assert has_element?(view, "#nav-node", "test-node")
    end

    test "renders one tile per node, hottest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert tile_order(view) == ~w(node-a node-d node-b test-node node-c)
      assert has_element?(view, "#node-node-a[data-score='91'][data-heat='4']")
      assert has_element?(view, "#node-node-c[data-score='18'][data-heat='0']")
      assert has_element?(view, "#node-node-a", "14 pods")
      # sparkline of the recent score history
      assert has_element?(view, "#node-node-a svg[data-points='10']")
    end

    test "badges leader, this node and active cooldowns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#node-node-b [data-badge=leader]")
      refute has_element?(view, "#node-node-a [data-badge=leader]")
      assert has_element?(view, "#node-test-node [data-badge=self]")
      assert has_element?(view, "#node-node-a [data-badge=cooldown]", "Cooling 1m")
      # node-c's cooldown has expired
      refute has_element?(view, "#node-node-c [data-badge=cooldown]")
    end

    test "dims stale scores", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#node-node-d[data-stale=true] [data-badge=stale]")
      assert has_element?(view, "#node-node-a[data-stale=false]")
    end

    test "updates when Valence publishes a new cluster view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      scores = [
        Fixtures.node_score("node-c", 99.0),
        Fixtures.node_score("node-a", 20.0),
        Fixtures.node_score("node-new", 50.0)
      ]

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Valence.cluster_topic(),
        {:cluster_updated, scores}
      )

      assert tile_order(view) == ~w(node-c node-new node-a)
      assert has_element?(view, "#summary-nodes", "3")
      assert has_element?(view, "#node-node-c[data-heat='4']")
      refute has_element?(view, "#node-node-b")
      # history grows by the new point
      assert has_element?(view, "#node-node-a svg[data-points='11']")
      assert has_element?(view, "#node-node-new svg[data-points='1']")
    end

    test "updates mode, leader and last plan on a status broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      status = %{
        Fixtures.status()
        | dry_run?: false,
          enabled?: false,
          leader: "node-c",
          last_plan: nil
      }

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Catalyst.topic(),
        {:catalyst_status, status}
      )

      assert has_element?(view, "#summary-mode-badge-live")
      assert has_element?(view, "#summary-mode-badge-paused")
      assert has_element?(view, "#nav-mode-live")
      assert has_element?(view, "#summary-leader", "node-c")
      assert has_element?(view, "#node-node-c [data-badge=leader]")
      assert has_element?(view, "#summary-plan", "no plan yet")
    end
  end

  describe "node detail" do
    setup {Fixtures, :install}

    test "opens from a tile and closes again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#node-detail")

      view |> element("#node-node-a") |> render_click()
      assert_patch(view, ~p"/nodes/node-a")
      assert has_element?(view, "#node-detail[data-node=node-a]")
      assert has_element?(view, "#node-node-a[aria-current=true]")

      view |> element("#node-detail-close") |> render_click()
      assert_patch(view, ~p"/")
      refute has_element?(view, "#node-detail")
    end

    test "shows score history and the node's workloads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/node-a")

      assert has_element?(view, "#node-detail-score", "91.0")
      assert has_element?(view, "#node-history-chart[data-points='10']")

      render_async(view)
      assert has_element?(view, "#node-wl-uid-shop-web-1")
      assert has_element?(view, "#node-wl-uid-shop-api-1")
      refute has_element?(view, "#node-wl-uid-data-cache-0")
    end

    test "raw Isotope series are only shown for the node serving the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/node-a")
      refute has_element?(view, "#node-isotope")
      assert has_element?(view, "#node-isotope-remote")

      {:ok, view, _html} = live(conn, ~p"/nodes/test-node")
      assert has_element?(view, "#node-isotope")
      refute has_element?(view, "#node-isotope-remote")

      for key <- ~w(psi_cpu_some psi_memory_some psi_io_some cpu_throttled_ratio
                    cpu_usage_ratio major_faults_per_s) do
        assert has_element?(view, "#isotope-#{key} svg[data-points='5']")
      end

      assert has_element?(view, "#isotope-psi_cpu_some [data-latest]", "12.5%")
      assert has_element?(view, "#isotope-cpu_throttled_ratio [data-latest]", "10%")
    end

    test "Isotope series update live", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/test-node")

      sample = Fixtures.node_sample(System.system_time(:millisecond), psi_cpu_some: 48.0)

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Isotope.topic(),
        {:isotope_sample, sample}
      )

      assert has_element?(view, "#isotope-psi_cpu_some svg[data-points='6']")
      assert has_element?(view, "#isotope-psi_cpu_some [data-latest]", "48.0%")
    end

    test "score history follows cluster updates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/node-a")

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Valence.cluster_topic(),
        {:cluster_updated, [Fixtures.node_score("node-a", 42.4)]}
      )

      assert has_element?(view, "#node-history-chart[data-points='11']")
      assert has_element?(view, "#node-detail-score", "42.4")
    end

    test "refreshes the node's workloads periodically", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/nodes/node-c")
      render_async(view)
      refute has_element?(view, "#node-wl-uid-shop-late-1")

      Fixtures.put(:workloads, [Fixtures.workload("shop", "late-1", "node-c")])
      send(view.pid, :refresh_detail)
      render_async(view)

      assert has_element?(view, "#node-wl-uid-shop-late-1")
    end
  end
end
