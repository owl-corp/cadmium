defmodule Cadmium.Catalyst.FacadeTest do
  # Uses the default process names and the application env.
  use ExUnit.Case, async: false

  import Cadmium.CatalystFixtures

  alias Cadmium.Catalyst
  alias Cadmium.Catalyst.{Action, Plan, Planner}
  alias Cadmium.CatalystKubeStub, as: Kube

  defp use_kube_stub(opts) do
    previous = Application.get_env(:cadmium, :kube_client)
    Application.put_env(:cadmium, :kube_client, Kube)
    on_exit(fn -> Application.put_env(:cadmium, :kube_client, previous) end)
    start_supervised!({Kube, opts})
  end

  describe "with nothing running" do
    test "every function returns a sane default" do
      assert Catalyst.status() == %{
               dry_run?: true,
               enabled?: true,
               leader: nil,
               leader?: false,
               last_plan: nil,
               last_evaluated_at: nil,
               cooldowns: %{nodes: %{}, workloads: %{}}
             }

      assert Catalyst.dry_run?() == true
      assert Catalyst.set_dry_run(false) == :ok
      assert Catalyst.set_enabled(false) == :ok
      assert Catalyst.dry_run?() == true
      assert Catalyst.audit_log() == []
      assert Catalyst.audit_log(5) == []
      assert %Plan{moves: [], status: :insufficient_nodes} = Catalyst.simulate()
    end

    test "simulate/0 does not raise when the Kubernetes client is broken" do
      previous = Application.get_env(:cadmium, :kube_client)
      Application.put_env(:cadmium, :kube_client, Cadmium.Kube.DoesNotExist)
      on_exit(fn -> Application.put_env(:cadmium, :kube_client, previous) end)

      assert %Plan{moves: [], summary: summary} = Catalyst.simulate()
      assert summary != ""
    end
  end

  describe "under the supervisor" do
    setup do
      start_supervised!(Cadmium.Catalyst.Supervisor)
      :ok
    end

    test "children start in dependency order under one_for_one" do
      assert {:ok, {%{strategy: :one_for_one}, specs}} = Cadmium.Catalyst.Supervisor.init([])

      assert Enum.map(specs, & &1.id) == [
               Cadmium.Leader,
               Cadmium.Catalyst.Settings,
               Cadmium.Catalyst.AuditLog,
               Cadmium.Catalyst.Cooldowns,
               Cadmium.Catalyst.DiscordNotifier,
               Cadmium.Catalyst.Coordinator
             ]

      for name <- [
            Cadmium.Catalyst.Settings,
            Cadmium.Catalyst.AuditLog,
            Cadmium.Catalyst.Cooldowns,
            Cadmium.Catalyst.DiscordNotifier,
            Cadmium.Catalyst.Coordinator
          ] do
        assert is_pid(Process.whereis(name))
      end
    end

    test "settings can be toggled and are audited" do
      Catalyst.subscribe()
      assert Catalyst.dry_run?() == true

      assert :ok = Catalyst.set_dry_run(false)
      assert Catalyst.dry_run?() == false
      assert %{dry_run?: false, enabled?: true, leader?: false} = Catalyst.status()

      assert :ok = Catalyst.set_enabled(false)
      assert %{dry_run?: false, enabled?: false} = Catalyst.status()

      assert [
               %Action{type: :settings_changed, details: %{setting: :enabled?, value: false}},
               %Action{type: :settings_changed, details: %{setting: :dry_run?, value: false}} = a
             ] = Catalyst.audit_log()

      assert a.actor == Cadmium.node_name()
      assert [%Action{details: %{setting: :enabled?}}] = Catalyst.audit_log(1)

      assert_receive {:catalyst_action, %Action{type: :settings_changed}}
      assert_receive {:catalyst_status, %{dry_run?: false, enabled?: false}}
    end

    test "a non-leader evaluates nothing and status stays empty" do
      assert {:skipped, :not_leader} = Cadmium.Catalyst.Coordinator.evaluate_now()
      assert %{last_plan: nil, cooldowns: %{nodes: %{}, workloads: %{}}} = Catalyst.status()
    end

    test "a crashed coordinator does not take cooldowns or the audit log with it" do
      Catalyst.set_dry_run(false)
      Cadmium.Catalyst.Cooldowns.put_node("node-a", System.monotonic_time(:millisecond) + 60_000)
      cooldowns = Process.whereis(Cadmium.Catalyst.Cooldowns)

      coordinator = Process.whereis(Cadmium.Catalyst.Coordinator)
      ref = Process.monitor(coordinator)
      Process.exit(coordinator, :kill)
      assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}

      assert Process.whereis(Cadmium.Catalyst.Cooldowns) == cooldowns
      assert [%Action{type: :settings_changed}] = Catalyst.audit_log()
      assert Catalyst.dry_run?() == false
    end
  end

  describe "simulation" do
    setup do
      web = workload("web-1", "node-a")

      use_kube_stub(
        nodes: Enum.map(["node-a", "node-c"], &kube_node/1),
        replicas: replicas([web])
      )

      opts = [
        config: config(),
        nodes_fun: fn -> [score("node-a", 86), score("node-c", 45)] end,
        workloads_fun: fn
          "node-a" -> [web]
          _ -> []
        end
      ]

      {:ok, web: web, opts: opts}
    end

    test "plans from live data, ignoring the sustained window, without side effects", ctx do
      web = ctx.web
      plan = Planner.simulate(ctx.opts)

      assert %Plan{status: :imbalanced, moves: [%{workload: ^web, from_node: "node-a"}]} = plan
      assert Enum.map(plan.hot, & &1.k8s_node) == ["node-a"]
      assert Enum.map(plan.cool, & &1.k8s_node) == ["node-c"]
      assert Kube.mutations() == []
    end

    test "respects cooldowns that have not expired", ctx do
      now = System.system_time(:millisecond)

      cooling = %{nodes: %{"node-a" => now + 60_000}, workloads: %{}}

      assert %Plan{status: :cooling_down, moves: []} =
               Planner.simulate([cooldowns: cooling] ++ ctx.opts)

      expired = %{nodes: %{"node-a" => now - 1}, workloads: %{}}
      assert %Plan{moves: [_]} = Planner.simulate([cooldowns: expired] ++ ctx.opts)

      web = ctx.web
      workload = %{nodes: %{}, workloads: %{"default/ReplicaSet/web-1-rs" => now + 60_000}}

      assert %Plan{moves: [], rejected: [{^web, :workload_cooldown}]} =
               Planner.simulate([cooldowns: workload] ++ ctx.opts)
    end

    test "degrades to an explanatory plan when live data cannot be read", ctx do
      opts = Keyword.put(ctx.opts, :nodes_fun, fn -> raise "mesh unavailable" end)
      assert %Plan{moves: [], summary: summary} = Planner.simulate(opts)
      assert summary =~ "mesh unavailable"

      opts = Keyword.put(ctx.opts, :nodes_fun, fn -> exit(:noproc) end)
      assert %Plan{moves: [], summary: summary} = Planner.simulate(opts)
      assert summary =~ "noproc"
    end

    test "a failing workload source just means nothing to move", ctx do
      opts = Keyword.put(ctx.opts, :workloads_fun, fn _node -> raise "agent unreachable" end)
      assert %Plan{status: :imbalanced, moves: [], rejected: []} = Planner.simulate(opts)
    end
  end
end
