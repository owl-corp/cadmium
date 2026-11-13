defmodule CadmiumWeb.RebalancerLiveTest do
  use CadmiumWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CadmiumWeb.DashboardFixtures, as: Fixtures

  describe "with no subsystems running" do
    test "renders empty states and an insufficient-nodes simulation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      assert has_element?(view, "#controls-mode-dry-run")
      assert has_element?(view, "#controls-leader", "no leader elected")
      assert has_element?(view, "#last-plan-empty")
      assert has_element?(view, "#cooldowns-empty")
      assert has_element?(view, "#simulation-idle")

      view |> element("#simulate-btn") |> render_click()
      render_async(view)

      # the real planner, with an empty mesh, has nothing to balance between
      assert has_element?(view, "#simulation-plan[data-status=insufficient_nodes]")
    end
  end

  describe "controls" do
    setup {Fixtures, :install}

    test "going live needs an explicit confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      assert has_element?(view, "#go-live-btn")
      refute has_element?(view, "#confirm-live")

      view |> element("#go-live-btn") |> render_click()

      assert has_element?(view, "#confirm-live", "Evictions will really happen")
      assert has_element?(view, "#confirm-live", "single-replica workload causes downtime")
      assert has_element?(view, "#controls-mode-dry-run")
      refute_received {:fixture_call, _}

      view |> element("#confirm-live-btn") |> render_click()

      assert_received {:fixture_call, {:set_dry_run, false}}
      assert has_element?(view, "#controls-mode-live")
      assert has_element?(view, "#nav-mode-live")
      refute has_element?(view, "#confirm-live")
      refute has_element?(view, "#go-live-btn")
    end

    test "the confirmation can be cancelled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      view |> element("#go-live-btn") |> render_click()
      view |> element("#cancel-live-btn") |> render_click()

      refute has_element?(view, "#confirm-live")
      assert has_element?(view, "#controls-mode-dry-run")
      refute_received {:fixture_call, _}
    end

    test "a confirm event without the confirmation step is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      render_click(view, "confirm_live")

      refute_received {:fixture_call, _}
      assert has_element?(view, "#controls-mode-dry-run")
    end

    test "returning to dry-run is a single click", %{conn: conn} do
      Fixtures.put(:status, %{Fixtures.status() | dry_run?: false})
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      assert has_element?(view, "#controls-mode-live")
      view |> element("#dry-run-btn") |> render_click()

      assert_received {:fixture_call, {:set_dry_run, true}}
      assert has_element?(view, "#controls-mode-dry-run")
    end

    test "pause and resume", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      view |> element("#pause-btn") |> render_click()
      assert_received {:fixture_call, {:set_enabled, false}}
      assert has_element?(view, "#controls-mode-paused")
      assert has_element?(view, "#nav-mode-paused")

      view |> element("#resume-btn") |> render_click()
      assert_received {:fixture_call, {:set_enabled, true}}
      refute has_element?(view, "#controls-mode-paused")
      assert has_element?(view, "#pause-btn")
    end

    test "manual rebalance requires confirmation and reports the result", %{conn: conn} do
      Fixtures.put(:plan, %{Fixtures.state().plan | spread_only?: true})
      {:ok, view, _html} = live(conn, ~p"/rebalancer")
      render_click(view, "confirm_rebalance")
      refute_received {:fixture_call, :rebalance_now}
      view |> element("#request-rebalance-btn") |> render_click()
      assert has_element?(view, "#confirm-rebalance")

      assert has_element?(
               view,
               "#confirm-rebalance",
               "Single-replica workloads may experience downtime"
             )

      view |> element("#cancel-rebalance-btn") |> render_click()
      refute has_element?(view, "#confirm-rebalance")
      view |> element("#request-rebalance-btn") |> render_click()
      view |> element("#confirm-rebalance-btn") |> render_click()
      render_async(view)
      assert_received {:fixture_call, :rebalance_now}
      assert has_element?(view, "#rebalance-plan")
      assert has_element?(view, "#rebalance-plan-hot", "Source nodes")
    end

    test "follows status broadcasts from other agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      status = %{Fixtures.status() | dry_run?: false, leader: "node-c", last_plan: nil}

      Phoenix.PubSub.local_broadcast(
        Cadmium.PubSub,
        Cadmium.Catalyst.topic(),
        {:catalyst_status, status}
      )

      assert has_element?(view, "#controls-mode-live")
      assert has_element?(view, "#controls-leader", "node-c")
      assert has_element?(view, "#last-plan-empty")
    end
  end

  describe "plans and cooldowns" do
    setup {Fixtures, :install}

    test "simulates on demand and renders the plan", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")
      refute has_element?(view, "#simulation-plan")

      view |> element("#simulate-btn") |> render_click()
      render_async(view)

      assert has_element?(view, "#simulation-plan[data-status=imbalanced]")
      assert has_element?(view, "#simulation-plan-status", "Imbalanced")
      assert has_element?(view, "#simulation-plan-summary", "node-a is hot")
      assert has_element?(view, "#simulation-plan-hot", "node-a")
      assert has_element?(view, "#simulation-plan-cool", "node-c")
      assert has_element?(view, "#simulation-plan-moves [data-move='web-1']", "node-a")

      assert has_element?(
               view,
               "#simulation-plan-moves [data-move='web-1']",
               "cpu drift 2.8x on hot node"
             )
    end

    test "groups rejected candidates by reason with an explanation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")
      view |> element("#simulate-btn") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#simulation-plan-rejected-pdb_blocked",
               "Blocked by a PodDisruptionBudget"
             )

      assert has_element?(view, "#simulation-plan-rejected-pdb_blocked", "api-1")
      assert has_element?(view, "#simulation-plan-rejected-local_storage", "cache-0")
      assert has_element?(view, "#simulation-plan-rejected-daemonset", "kube-proxy-x")
      assert has_element?(view, "#simulation-plan-rejected-job", "report-1")
    end

    test "shows the leader's last plan", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      assert has_element?(view, "#last-plan-view[data-status=imbalanced]")
      assert has_element?(view, "#last-plan-view-moves [data-move='web-1']")
    end

    test "lists active cooldowns with time remaining", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rebalancer")

      assert has_element?(view, "#cooldowns-nodes [data-cooldown='node-a']", "1m 5")
      refute has_element?(view, "#cooldowns-nodes [data-cooldown='node-c']")

      assert has_element?(
               view,
               "#cooldowns-workloads [data-cooldown='shop/ReplicaSet/web']",
               "4m 5"
             )
    end
  end
end
