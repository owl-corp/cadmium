defmodule Cadmium.Catalyst.CoordinatorTest do
  # The Kubernetes stub is a named process selected through the application env.
  use ExUnit.Case, async: false

  import Cadmium.CatalystFixtures
  import ExUnit.CaptureLog

  alias Cadmium.Catalyst.{AuditLog, Cooldowns, Coordinator, Settings}
  alias Cadmium.CatalystKubeStub, as: Kube

  @wall_offset 1_000_000
  @node_cooldown 300_000
  @workload_cooldown 900_000
  @sustained 120_000

  setup do
    previous = Application.get_env(:cadmium, :kube_client)
    Application.put_env(:cadmium, :kube_client, Kube)
    on_exit(fn -> Application.put_env(:cadmium, :kube_client, previous) end)

    id = System.unique_integer([:positive])
    web = workload("web-1", "node-a", sample: [cpu_usage_millis: 900.0])
    api = workload("api-1", "node-a", sample: [cpu_usage_millis: 600.0])
    db = workload("db-1", "node-a", sample: [cpu_usage_millis: 300.0])

    start_supervised!(
      {Kube,
       nodes: Enum.map(["node-a", "node-b", "node-c"], &kube_node/1),
       replicas: replicas([web, api, db])}
    )

    world =
      start_supervised!(
        {Agent,
         fn ->
           %{
             leader?: true,
             mono: 0,
             scores: [score("node-a", 86), score("node-b", 60), score("node-c", 45)],
             workloads: %{"node-a" => [web]}
           }
         end},
        id: :world
      )

    ctx = %{
      world: world,
      web: web,
      api: api,
      db: db,
      settings: :"catalyst_settings_#{id}",
      audit: :"catalyst_audit_#{id}",
      cooldowns: :"catalyst_cooldowns_#{id}",
      coordinator: :"catalyst_coordinator_#{id}",
      topic: "catalyst:events:test:#{id}",
      sync_topic: "catalyst:sync:test:#{id}",
      leader_topic: "leader:test:#{id}"
    }

    start_supervised!({AuditLog, name: ctx.audit, topic: ctx.topic, size: 200})
    start_supervised!({Cooldowns, table: ctx.cooldowns})
    {:ok, ctx}
  end

  ## Harness

  defp set(ctx, key, value), do: Agent.update(ctx.world, &Map.put(&1, key, value))
  defp at(ctx, mono), do: set(ctx, :mono, mono)
  defp world(ctx, key), do: Agent.get(ctx.world, &Map.fetch!(&1, key))

  # Starts settings + coordinator and waits for the cycle a leader runs at boot.
  defp start(ctx, opts \\ []) do
    pid = start_nowait(ctx, opts)
    :ok = Coordinator.await_idle(ctx.coordinator)
    pid
  end

  defp start_nowait(ctx, opts) do
    {dry_run?, opts} = Keyword.pop(opts, :dry_run, false)
    {enabled?, opts} = Keyword.pop(opts, :enabled, true)
    {config, opts} = Keyword.pop(opts, :config, [])

    start_supervised!(
      {Settings,
       name: ctx.settings,
       sync_topic: ctx.sync_topic,
       audit: ctx.audit,
       actor: "node-a",
       config: [dry_run: dry_run?, enabled: enabled?]}
    )

    config =
      Keyword.merge(
        [
          hot_threshold: 70.0,
          spread_threshold: 25.0,
          sustained_ms: @sustained,
          node_cooldown_ms: @node_cooldown,
          workload_cooldown_ms: @workload_cooldown,
          max_evictions_per_cycle: 1,
          taint_key: taint_key(),
          opt_out_annotation: "cadmium.owl-corp.io/rebalance",
          excluded_namespaces: ["kube-system"]
        ],
        config
      )

    world = ctx.world

    opts =
      Keyword.merge(
        [
          name: ctx.coordinator,
          config: config,
          interval: :manual,
          nodes_fun: fn ->
            case Agent.get(world, & &1.scores) do
              :boom -> raise "valence is down"
              scores -> scores
            end
          end,
          workloads_fun: fn node -> Agent.get(world, &Map.get(&1.workloads, node, [])) end,
          leader_fun: fn -> Agent.get(world, & &1.leader?) end,
          leader_current_fun: fn -> "node-a" end,
          clock: fn -> Agent.get(world, & &1.mono) end,
          wall_clock: fn -> @wall_offset + Agent.get(world, & &1.mono) end,
          settings: ctx.settings,
          audit: ctx.audit,
          cooldowns: ctx.cooldowns,
          topic: ctx.topic,
          sync_topic: ctx.sync_topic,
          leader_topic: ctx.leader_topic,
          actor: "node-a"
        ],
        opts
      )

    start_supervised!({Coordinator, opts})
  end

  defp evaluate(ctx), do: Coordinator.evaluate_now(ctx.coordinator)

  defp evaluate_at(ctx, mono) do
    at(ctx, mono)
    evaluate(ctx)
  end

  defp actions(ctx, type \\ nil) do
    log = ctx.audit |> AuditLog.recent(200) |> Enum.reverse()
    if type, do: Enum.filter(log, &(&1.type == type)), else: log
  end

  defp evicted, do: for([_ns, name, _opts] <- Kube.calls(:evict_pod), do: name)
  defp mutation_ops, do: Enum.map(Kube.mutations(), &elem(&1, 0))

  describe "manual spread-only rebalance" do
    test "moves a non-hot node immediately, respects cooldowns and restores normal policy", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-b", 50), score("node-c", 30)])
      start(ctx)
      assert {:ok, %{status: :balanced}} = evaluate(ctx)
      assert Kube.mutations() == []

      assert {:ok, %{status: :imbalanced, spread_only?: true, moves: [_]}} =
               Coordinator.rebalance_now(ctx.coordinator)

      assert evicted() == ["web-1"]

      assert [
               %{
                 reason:
                   "manual spread-only rebalance; sustained wait skipped; single replicas allowed"
               }
             ] =
               actions(ctx, :manual_rebalance)

      assert {:ok, %{status: :cooling_down, moves: []}} =
               Coordinator.rebalance_now(ctx.coordinator)

      assert {:ok, %{status: :balanced, spread_only?: false, moves: []}} = evaluate(ctx)
      assert evicted() == ["web-1"]
    end

    test "respects dry-run and disabled settings", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 30)])
      start(ctx, dry_run: true)
      assert {:ok, %{moves: [_]}} = Coordinator.rebalance_now(ctx.coordinator)
      assert Kube.mutations() == []
      assert [%{dry_run?: true, result: :simulated}] = actions(ctx, :evict)
      Settings.put(ctx.settings, :enabled?, false)
      assert {:skipped, :disabled} = Coordinator.rebalance_now(ctx.coordinator)
    end

    test "automatic cycle evicts a healthy singleton after the sustained window", ctx do
      Kube.put(:replicas, replicas([ctx.web], %{desired: 1, ready: 1}))
      start(ctx)
      assert {:ok, %{status: :not_sustained, moves: []}} = evaluate_at(ctx, @sustained - 1)
      assert Kube.mutations() == []
      assert {:ok, %{moves: [move]}} = evaluate_at(ctx, @sustained)
      assert move.workload == ctx.web
      assert evicted() == ["web-1"]
    end

    test "manual cycle can evict a healthy singleton", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 30)])
      Kube.put(:replicas, replicas([ctx.web], %{desired: 1, ready: 1}))
      start(ctx)
      assert {:ok, %{moves: [move]}} = Coordinator.rebalance_now(ctx.coordinator)
      assert move.workload == ctx.web
      assert evicted() == ["web-1"]
    end

    test "automatic singleton eviction respects dry-run and disruption budgets", ctx do
      Kube.put(:replicas, replicas([ctx.web], %{desired: 1, ready: 1}))
      Kube.put(:pdbs, [pdb("web", match_labels: %{"app" => "web-1"}, disruptions_allowed: 0)])
      start(ctx, dry_run: true)

      assert {:ok, %{moves: [], rejected: [{_, :pdb_blocked}]}} =
               evaluate_at(ctx, @sustained)

      Kube.put(:pdbs, [])
      assert {:ok, %{moves: [_]}} = evaluate(ctx)
      assert Kube.mutations() == []
      assert [%{dry_run?: true, result: :simulated}] = actions(ctx, :evict)
    end

    test "automatic cycle evicts a decoded pod with emptyDir", ctx do
      pod = ctx.web.pod

      decoded =
        Cadmium.Kube.Decode.pod(%{
          "metadata" => %{
            "name" => pod.name,
            "namespace" => pod.namespace,
            "uid" => pod.uid,
            "ownerReferences" => [
              %{"kind" => pod.owner_kind, "name" => pod.owner_name, "controller" => true}
            ]
          },
          "spec" => %{"nodeName" => "node-a", "volumes" => [%{"emptyDir" => %{}}]},
          "status" => %{"phase" => "Running"}
        })

      set(ctx, :workloads, %{"node-a" => [%{ctx.web | pod: decoded}]})
      start(ctx)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)
      assert evicted() == ["web-1"]
    end

    test "singleton eviction still requires a permitting disruption budget", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 30)])
      Kube.put(:replicas, replicas([ctx.web], %{desired: 1, ready: 1}))
      Kube.put(:pdbs, [pdb("web", match_labels: %{"app" => "web-1"}, disruptions_allowed: 0)])
      start(ctx)

      assert {:ok, %{moves: [], rejected: [{_, :pdb_blocked}]}} =
               Coordinator.rebalance_now(ctx.coordinator)

      assert Kube.mutations() == []
    end

    test "manual cycle rejects unknown, unready, and scaled-down singleton replica counts", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 30)])
      start(ctx)

      for {info, reason} <- [
            {nil, :single_replica},
            {%{desired: 1, ready: 0}, :replicas_not_ready},
            {%{desired: 0, ready: 1}, :single_replica}
          ] do
        Kube.put(:replicas, if(info, do: replicas([ctx.web], info), else: %{}))

        assert {:ok, %{moves: [], rejected: [{_, ^reason}]}} =
                 Coordinator.rebalance_now(ctx.coordinator)
      end

      assert Kube.mutations() == []
    end

    test "requires the configured spread", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 40)])
      start(ctx)
      assert {:ok, %{status: :balanced, moves: []}} = Coordinator.rebalance_now(ctx.coordinator)
      assert Kube.mutations() == []
    end

    test "permits a safe destination above the normal cool ceiling", ctx do
      set(ctx, :scores, [score("node-a", 95), score("node-c", 65)])
      start(ctx)
      assert {:ok, %{moves: [_]}} = Coordinator.rebalance_now(ctx.coordinator)
      assert evicted() == ["web-1"]
    end

    test "does not act when there is no eligible destination", ctx do
      set(ctx, :scores, [score("node-a", 60), score("unknown", 30)])
      start(ctx)
      assert {:ok, %{moves: []}} = Coordinator.rebalance_now(ctx.coordinator)
      assert Kube.mutations() == []
    end

    test "does not evict when disruption budgets cannot be read", ctx do
      set(ctx, :scores, [score("node-a", 60), score("node-c", 30)])
      start(ctx)
      Kube.respond(:list_pdbs, {:error, :unavailable})

      assert {:ok, %{moves: [], rejected: [{_, :pdb_blocked}]}} =
               Coordinator.rebalance_now(ctx.coordinator)

      assert Kube.mutations() == []
    end

    test "rejects a request on a non-leader", ctx do
      set(ctx, :leader?, false)
      start(ctx)
      assert {:skipped, :not_leader} = Coordinator.rebalance_now(ctx.coordinator)
      assert Kube.mutations() == []
    end
  end

  ## Sustained window

  describe "sustained window" do
    test "a hot node is left alone until it has been hot for sustained_ms", ctx do
      start(ctx)

      assert {:ok, %{status: :not_sustained, moves: []}} = evaluate_at(ctx, 60_000)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, @sustained - 1)
      assert Kube.mutations() == []

      assert {:ok, %{status: :imbalanced, moves: [move]}} = evaluate_at(ctx, @sustained)
      assert move.workload == ctx.web
      assert evicted() == ["web-1"]
    end

    test "the window starts over when the node cools down in between", ctx do
      start(ctx)

      set(ctx, :scores, [score("node-a", 60), score("node-b", 60), score("node-c", 45)])
      assert {:ok, %{status: :balanced}} = evaluate_at(ctx, 60_000)

      set(ctx, :scores, [score("node-a", 86), score("node-b", 60), score("node-c", 45)])
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 100_000)
      # 120s after it first became hot, but only 30s after it became hot again
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 130_000)
      assert Kube.mutations() == []

      assert {:ok, %{status: :imbalanced, moves: [_]}} = evaluate_at(ctx, 220_000)
    end

    test "the window starts over when the node disappears from the mesh", ctx do
      start(ctx)

      set(ctx, :scores, [score("node-b", 60), score("node-c", 45)])
      assert {:ok, %{status: :balanced}} = evaluate_at(ctx, 60_000)

      set(ctx, :scores, [score("node-a", 86), score("node-b", 60), score("node-c", 45)])
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 150_000)
      assert Kube.mutations() == []
    end

    test "a new leader waits out the window itself", ctx do
      start(ctx)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 100_000)

      set(ctx, :leader?, false)
      assert {:skipped, :not_leader} = evaluate(ctx)
      set(ctx, :leader?, true)

      # hot for 130s in total, but only observed for 0s by this term of leadership
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 130_000)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 249_999)
      assert {:ok, %{status: :imbalanced, moves: [_]}} = evaluate_at(ctx, 250_000)
    end
  end

  ## Live execution

  describe "live execution" do
    test "taints the node, then evicts, and records both", ctx do
      start(ctx)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)

      assert [
               {:add_node_taint, ["node-a", taint]},
               {:evict_pod, ["default", "web-1", _opts]}
             ] = Kube.mutations()

      assert taint == %{key: taint_key(), value: "true", effect: "PreferNoSchedule"}
      assert Kube.taints("node-a") == [taint]

      assert [%{type: :taint} = tainted, %{type: :evict} = evict] =
               Enum.filter(actions(ctx), &(&1.type in [:taint, :evict]))

      assert %{node: "node-a", result: :ok, dry_run?: false, actor: "node-a"} = tainted

      assert %{node: "node-a", namespace: "default", pod: "web-1", result: :ok, dry_run?: false} =
               evict

      assert evict.reason =~ "node-a at 86 (cpu), 41 above coolest"
      assert evict.details.owner_name == "web-1-rs"
    end

    test "node cooldown: nothing more happens on the node until it expires", ctx do
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
      start(ctx)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)

      assert {:ok, %{status: :cooling_down, moves: []}} = evaluate_at(ctx, @sustained + 1)

      assert {:ok, %{status: :cooling_down}} =
               evaluate_at(ctx, @sustained + @node_cooldown - 1)

      assert evicted() == ["web-1"]
      assert Kube.calls(:remove_node_taint) == []
    end

    test "the taint is removed when the node cooldown expires", ctx do
      start(ctx)
      evaluate_at(ctx, @sustained)
      assert [_] = Kube.taints("node-a")

      # the node has recovered in the meantime
      set(ctx, :scores, [score("node-a", 50), score("node-b", 60), score("node-c", 45)])
      assert {:ok, %{status: :balanced}} = evaluate_at(ctx, @sustained + @node_cooldown)

      assert Kube.calls(:remove_node_taint) == [["node-a", taint_key()]]
      assert Kube.taints("node-a") == []
      assert [%{node: "node-a", result: :ok, dry_run?: false}] = actions(ctx, :untaint)

      assert mutation_ops() == [:add_node_taint, :evict_pod, :remove_node_taint]

      # and only once
      evaluate_at(ctx, @sustained + @node_cooldown + 15_000)
      assert length(Kube.calls(:remove_node_taint)) == 1
    end

    test "workload cooldown outlives the node cooldown", ctx do
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
      start(ctx)
      evaluate_at(ctx, @sustained)
      assert evicted() == ["web-1"]

      # node cooldown over, node still hot: web is rejected, api goes instead
      web = ctx.web
      api = ctx.api
      assert {:ok, plan} = evaluate_at(ctx, @sustained + @node_cooldown)
      assert [{^web, :workload_cooldown}] = plan.rejected
      assert [%{workload: ^api}] = plan.moves
      assert evicted() == ["web-1", "api-1"]

      # both controllers cooling: nothing to move
      assert {:ok, plan} = evaluate_at(ctx, @sustained + 2 * @node_cooldown)
      assert plan.moves == []

      assert Enum.sort(Enum.map(plan.rejected, &elem(&1, 1))) == [
               :workload_cooldown,
               :workload_cooldown
             ]

      # web's workload cooldown has expired
      assert {:ok, %{moves: [%{workload: ^web}]}} =
               evaluate_at(ctx, @sustained + @workload_cooldown)

      assert evicted() == ["web-1", "api-1", "web-1"]
    end

    test "max_evictions_per_cycle caps a cycle; the node is tainted once", ctx do
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api, ctx.db]})
      start(ctx, config: [max_evictions_per_cycle: 2])
      assert {:ok, %{moves: [_, _]}} = evaluate_at(ctx, @sustained)

      assert mutation_ops() == [:add_node_taint, :evict_pod, :evict_pod]
      assert evicted() == ["web-1", "api-1"]
    end

    test "status reports cooldown expiries as wall-clock ms and is broadcast locally", ctx do
      Phoenix.PubSub.subscribe(Cadmium.PubSub, ctx.topic)
      start(ctx)
      assert {:ok, plan} = evaluate_at(ctx, @sustained)

      status = Coordinator.status(ctx.coordinator)

      assert status == %{
               dry_run?: false,
               enabled?: true,
               leader: "node-a",
               leader?: true,
               last_plan: plan,
               last_evaluated_at: @wall_offset + @sustained,
               cooldowns: %{
                 nodes: %{"node-a" => @wall_offset + @sustained + @node_cooldown},
                 workloads: %{
                   "default/ReplicaSet/web-1-rs" => @wall_offset + @sustained + @workload_cooldown
                 }
               }
             }

      assert_received {:catalyst_status, ^status}
    end
  end

  ## Dry-run

  describe "dry-run" do
    test "performs no mutating Kubernetes call and records simulated actions", ctx do
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
      start(ctx, dry_run: true, config: [max_evictions_per_cycle: 2])
      assert {:ok, %{status: :imbalanced, moves: [_, _]}} = evaluate_at(ctx, @sustained)

      assert Kube.mutations() == []
      assert Kube.taints("node-a") == []

      assert [%{type: :taint}, %{type: :evict, pod: "web-1"}, %{type: :evict, pod: "api-1"}] =
               simulated = Enum.filter(actions(ctx), &(&1.type in [:taint, :evict]))

      assert Enum.all?(simulated, &(&1.dry_run? == true and &1.result == :simulated))
    end

    test "applies cooldowns to itself so the same move is not logged every cycle", ctx do
      start(ctx, dry_run: true)
      evaluate_at(ctx, @sustained)
      assert length(actions(ctx, :evict)) == 1

      for offset <- [15_000, 30_000, @node_cooldown - 1] do
        assert {:ok, %{status: :cooling_down}} = evaluate_at(ctx, @sustained + offset)
      end

      assert length(actions(ctx, :evict)) == 1
      assert length(actions(ctx, :taint)) == 1

      # cooldown over: a simulated untaint, and the pod's controller is still cooling
      assert {:ok, %{moves: []}} = evaluate_at(ctx, @sustained + @node_cooldown)
      assert [%{dry_run?: true, result: :simulated, node: "node-a"}] = actions(ctx, :untaint)
      assert length(actions(ctx, :evict)) == 1
      assert Kube.mutations() == []
    end

    test "switching to live at runtime takes effect on the next cycle", ctx do
      start(ctx, dry_run: true)
      Settings.put(ctx.settings, :dry_run?, false)

      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)
      assert mutation_ops() == [:add_node_taint, :evict_pod]
    end
  end

  ## Enabled / leadership gates

  describe "gates" do
    test "a paused coordinator plans and evicts nothing", ctx do
      start(ctx, enabled: false)
      assert {:skipped, :disabled} = evaluate_at(ctx, @sustained)
      assert Kube.mutations() == []
      assert Coordinator.status(ctx.coordinator).enabled? == false

      # resuming restarts the sustained window
      Settings.put(ctx.settings, :enabled?, true)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, @sustained + 1)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, 2 * @sustained + 1)
    end

    test "a non-leader does nothing at all", ctx do
      set(ctx, :leader?, false)
      start(ctx)

      assert {:skipped, :not_leader} = evaluate_at(ctx, @sustained)
      assert {:skipped, :not_leader} = evaluate_at(ctx, 10 * @sustained)
      assert Kube.calls() == []
      assert actions(ctx) == []
      assert Coordinator.status(ctx.coordinator).leader? == false
    end

    test "leadership transitions are recorded once each", ctx do
      set(ctx, :leader?, false)
      start(ctx)

      set(ctx, :leader?, true)
      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.leader_topic, {:leadership, :acquired})
      evaluate(ctx)
      evaluate(ctx)
      assert [%{type: :leader_acquired, actor: "node-a"}] = actions(ctx)

      set(ctx, :leader?, false)
      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.leader_topic, {:leadership, :lost})
      assert {:skipped, :not_leader} = evaluate(ctx)
      assert [%{type: :leader_acquired}, %{type: :leader_lost}] = actions(ctx)
    end

    test "a missed transition message is caught by re-reading the leader state", ctx do
      set(ctx, :leader?, false)
      start(ctx)

      set(ctx, :leader?, true)
      assert {:ok, _plan} = evaluate(ctx)
      assert [%{type: :leader_acquired}] = actions(ctx)
    end

    test "a tick evaluates on the leader", ctx do
      pid = start(ctx)
      at(ctx, @sustained)
      send(pid, :tick)
      _ = :sys.get_state(pid)
      :ok = Coordinator.await_idle(ctx.coordinator)
      assert evicted() == ["web-1"]
    end
  end

  ## Leadership lost mid-cycle

  describe "leadership lost mid-cycle" do
    test "aborts before evicting when leadership is lost after the taint", ctx do
      world = ctx.world

      Kube.on_call(fn
        :add_node_taint, _args -> Agent.update(world, &Map.put(&1, :leader?, false))
        _op, _args -> :ok
      end)

      start(ctx)

      log =
        capture_log(fn ->
          assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)
        end)

      assert log =~ "leadership lost mid-cycle"
      assert mutation_ops() == [:add_node_taint]
      assert actions(ctx, :evict) == []

      assert {:skipped, :not_leader} = evaluate(ctx)
      assert List.last(actions(ctx)).type == :leader_lost
      assert mutation_ops() == [:add_node_taint]
    end

    test "aborts between evictions", ctx do
      world = ctx.world

      Kube.on_call(fn
        :evict_pod, _args -> Agent.update(world, &Map.put(&1, :leader?, false))
        _op, _args -> :ok
      end)

      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api, ctx.db]})
      start(ctx, config: [max_evictions_per_cycle: 3])

      capture_log(fn -> assert {:ok, %{moves: [_, _, _]}} = evaluate_at(ctx, @sustained) end)
      assert evicted() == ["web-1"]
    end

    test "aborts before tainting when leadership is lost during planning", ctx do
      world = ctx.world

      Kube.on_call(fn
        :list_pdbs, _args -> Agent.update(world, &Map.put(&1, :leader?, false))
        _op, _args -> :ok
      end)

      start(ctx)
      capture_log(fn -> assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained) end)
      assert Kube.mutations() == []
    end

    test "dry-run stops recording simulated actions too", ctx do
      world = ctx.world

      Kube.on_call(fn
        :list_pdbs, _args -> Agent.update(world, &Map.put(&1, :leader?, false))
        _op, _args -> :ok
      end)

      start(ctx, dry_run: true)
      capture_log(fn -> evaluate_at(ctx, @sustained) end)
      assert actions(ctx, :taint) == []
      assert actions(ctx, :evict) == []
    end
  end

  ## Error paths

  describe "eviction errors" do
    for reason <- [:pdb_blocked, :not_found, :timeout] do
      test "#{reason}: recorded, not retried this cycle, next move still attempted", ctx do
        reason = unquote(reason)

        Kube.respond(:evict_pod, fn
          [_ns, "web-1", _opts] -> {:error, reason}
          _other -> :ok
        end)

        set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
        start(ctx, config: [max_evictions_per_cycle: 2])
        assert {:ok, %{moves: [_, _]}} = evaluate_at(ctx, @sustained)

        assert evicted() == ["web-1", "api-1"]

        assert [
                 %{pod: "web-1", result: {:error, ^reason}},
                 %{pod: "api-1", result: :ok}
               ] = actions(ctx, :evict)

        # only the successful eviction starts a workload cooldown
        status = Coordinator.status(ctx.coordinator)
        assert Map.keys(status.cooldowns.workloads) == ["default/ReplicaSet/api-1-rs"]
      end
    end

    test "a failed eviction still leaves the node in cooldown (no taint flapping)", ctx do
      Kube.respond(:evict_pod, {:error, :pdb_blocked})
      start(ctx)
      evaluate_at(ctx, @sustained)

      assert {:ok, %{status: :cooling_down}} = evaluate_at(ctx, @sustained + 15_000)
      assert mutation_ops() == [:add_node_taint, :evict_pod]

      # and the taint is cleaned up when that cooldown ends
      Kube.clear_response(:evict_pod)
      set(ctx, :scores, [score("node-a", 50), score("node-b", 60), score("node-c", 45)])
      evaluate_at(ctx, @sustained + @node_cooldown)
      assert Kube.taints("node-a") == []
    end

    test "a crashing Kubernetes client counts as a failed eviction", ctx do
      Kube.respond(:evict_pod, fn _args -> raise "connection reset" end)
      start(ctx)
      assert {:ok, _plan} = evaluate_at(ctx, @sustained)
      assert [%{result: {:error, {:exception, "connection reset"}}}] = actions(ctx, :evict)
    end

    test "an unexpected eviction response is treated as an error", ctx do
      Kube.respond(:evict_pod, {:ok, :whatever})
      start(ctx)
      evaluate_at(ctx, @sustained)

      assert [%{result: {:error, {:unexpected_response, {:ok, :whatever}}}}] =
               actions(ctx, :evict)

      assert Coordinator.status(ctx.coordinator).cooldowns.workloads == %{}
    end

    test "if the taint fails, nothing is evicted from that node", ctx do
      Kube.respond(:add_node_taint, {:error, :forbidden})
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
      start(ctx, config: [max_evictions_per_cycle: 2])
      assert {:ok, %{moves: [_, _]}} = evaluate_at(ctx, @sustained)

      assert mutation_ops() == [:add_node_taint]
      assert [%{result: {:error, :forbidden}, node: "node-a"}] = actions(ctx, :taint)
      assert actions(ctx, :evict) == []
      assert Coordinator.status(ctx.coordinator).cooldowns == %{nodes: %{}, workloads: %{}}
    end

    test "missing information means skip: node list, PDBs, replicas", ctx do
      start(ctx)

      Kube.respond(:list_nodes, {:error, :timeout})

      assert {:ok, %{status: :imbalanced, moves: [], summary: summary}} =
               evaluate_at(ctx, @sustained)

      assert summary =~ "unavailable"
      Kube.clear_response(:list_nodes)

      web = ctx.web
      Kube.respond(:list_pdbs, {:error, :timeout})
      assert {:ok, %{moves: [], rejected: [{^web, :pdb_blocked}]}} = evaluate(ctx)
      Kube.clear_response(:list_pdbs)

      Kube.respond(:workload_replicas, {:error, :unsupported_kind})
      assert {:ok, %{moves: [], rejected: [{^web, :single_replica}]}} = evaluate(ctx)

      assert Kube.mutations() == []
    end

    test "replicas are only looked up for pods that pass the pod-local checks", ctx do
      daemon = workload("agent", "node-a", owner_kind: "DaemonSet", owner_name: "agent")
      set(ctx, :workloads, %{"node-a" => [ctx.web, daemon]})
      start(ctx)
      evaluate_at(ctx, @sustained)

      assert Kube.calls(:workload_replicas) == [["default", "ReplicaSet", "web-1-rs"]]
    end
  end

  ## Taint hygiene

  describe "taint hygiene" do
    test "on becoming leader, stale taints from a previous leader are removed", ctx do
      Kube.put(:nodes, [
        kube_node("node-a"),
        kube_node("node-b", taints: [cadmium_taint()]),
        kube_node("node-c",
          taints: [cadmium_taint(), %{key: "other", value: "x", effect: "NoSchedule"}]
        )
      ])

      set(ctx, :leader?, false)
      set(ctx, :scores, [score("node-a", 50), score("node-b", 50), score("node-c", 45)])
      start(ctx)
      assert Kube.calls() == []

      set(ctx, :leader?, true)
      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.leader_topic, {:leadership, :acquired})
      _ = :sys.get_state(ctx.coordinator)
      :ok = Coordinator.await_idle(ctx.coordinator)

      assert Kube.calls(:remove_node_taint) == [
               ["node-b", taint_key()],
               ["node-c", taint_key()]
             ]

      assert Kube.taints("node-b") == []
      assert Kube.taints("node-c") == [%{key: "other", value: "x", effect: "NoSchedule"}]

      assert [%{type: :leader_acquired} | untaints] = actions(ctx)
      assert [%{node: "node-b", result: :ok}, %{node: "node-c", result: :ok}] = untaints
      assert Enum.all?(untaints, &(&1.type == :untaint and &1.reason =~ "stale taint"))
    end

    test "stale taints are removed even in dry-run and while paused", ctx do
      Kube.put(:nodes, [kube_node("node-a"), kube_node("node-b", taints: [cadmium_taint()])])
      start(ctx, dry_run: true, enabled: false)

      assert Kube.mutations() == [{:remove_node_taint, ["node-b", taint_key()]}]
      assert [%{type: :untaint, dry_run?: false, result: :ok}] = actions(ctx, :untaint)
    end

    test "a taint this coordinator still has a cooldown for is kept", ctx do
      start(ctx)
      evaluate_at(ctx, @sustained)
      assert [_] = Kube.taints("node-a")

      # losing and regaining leadership triggers reconciliation, cooldown still active
      set(ctx, :leader?, false)
      evaluate(ctx)
      set(ctx, :leader?, true)
      evaluate_at(ctx, @sustained + 30_000)

      assert Kube.calls(:remove_node_taint) == []
      assert [_] = Kube.taints("node-a")
    end

    test "a failed removal is retried every cycle and logged once", ctx do
      start(ctx)
      evaluate_at(ctx, @sustained)
      set(ctx, :scores, [score("node-a", 50), score("node-b", 60), score("node-c", 45)])

      Kube.respond(:remove_node_taint, {:error, :timeout})
      evaluate_at(ctx, @sustained + @node_cooldown)
      evaluate_at(ctx, @sustained + @node_cooldown + 15_000)
      evaluate_at(ctx, @sustained + @node_cooldown + 30_000)

      assert length(Kube.calls(:remove_node_taint)) == 3
      assert [%{result: {:error, :timeout}}] = actions(ctx, :untaint)
      assert [_] = Kube.taints("node-a")

      Kube.clear_response(:remove_node_taint)
      evaluate_at(ctx, @sustained + @node_cooldown + 45_000)

      assert Kube.taints("node-a") == []
      assert [%{result: {:error, :timeout}}, %{result: :ok}] = actions(ctx, :untaint)

      evaluate_at(ctx, @sustained + @node_cooldown + 60_000)
      assert length(Kube.calls(:remove_node_taint)) == 4
    end

    test "a failed stale-taint removal is retried too", ctx do
      Kube.put(:nodes, [kube_node("node-a"), kube_node("node-b", taints: [cadmium_taint()])])
      Kube.respond(:remove_node_taint, {:error, :timeout})
      set(ctx, :scores, [score("node-a", 50), score("node-b", 50)])
      start(ctx)
      evaluate(ctx)

      assert length(Kube.calls(:remove_node_taint)) == 2
      assert [%{result: {:error, :timeout}}] = actions(ctx, :untaint)

      Kube.clear_response(:remove_node_taint)
      evaluate(ctx)
      assert Kube.taints("node-b") == []
    end

    test "taints are not removed after leadership is lost", ctx do
      start(ctx)
      evaluate_at(ctx, @sustained)

      set(ctx, :leader?, false)
      assert {:skipped, :not_leader} = evaluate_at(ctx, @sustained + @node_cooldown)
      assert Kube.calls(:remove_node_taint) == []
    end

    test "a tainted node is not used as a destination", ctx do
      Kube.put(:nodes, [
        kube_node("node-a"),
        kube_node("node-b"),
        kube_node("node-c", taints: [%{key: "dedicated", value: "gpu", effect: "NoSchedule"}])
      ])

      start(ctx)
      assert {:ok, %{status: :imbalanced, moves: [], cool: []}} = evaluate_at(ctx, @sustained)
      assert Kube.mutations() == []
    end
  end

  ## Robustness

  describe "robustness" do
    test "a failing evaluation is reported and the coordinator carries on", ctx do
      pid = start(ctx)
      good = world(ctx, :scores)

      log =
        capture_log(fn ->
          set(ctx, :scores, :boom)
          assert {:error, _reason} = evaluate_at(ctx, 60_000)
        end)

      assert log =~ "evaluation failed"
      assert Process.whereis(ctx.coordinator) == pid

      set(ctx, :scores, good)
      # the window that started at boot is still intact
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, @sustained)
    end

    test "a cycle killed after an eviction cannot cause a repeat eviction", ctx do
      world = ctx.world

      Kube.on_call(fn
        :evict_pod, [_ns, "api-1", _opts] ->
          if Agent.get(world, & &1.kill?), do: Process.exit(self(), :kill)

        _op, _args ->
          :ok
      end)

      set(ctx, :kill?, true)
      set(ctx, :workloads, %{"node-a" => [ctx.web, ctx.api]})
      pid = start(ctx, config: [max_evictions_per_cycle: 2])

      log =
        capture_log(fn ->
          assert {:error, {:crashed, :killed}} = evaluate_at(ctx, @sustained)
        end)

      assert log =~ "evaluation crashed"
      assert Process.whereis(ctx.coordinator) == pid
      assert [%{pod: "web-1", result: :ok}] = actions(ctx, :evict)

      # the cooldowns written before the crash hold
      set(ctx, :kill?, false)
      assert {:ok, %{status: :cooling_down}} = evaluate_at(ctx, @sustained + 15_000)
      assert {:ok, plan} = evaluate_at(ctx, @sustained + @node_cooldown)
      assert {ctx.web, :workload_cooldown} in plan.rejected
      assert Enum.count(evicted(), &(&1 == "web-1")) == 1
    end

    test "never runs two evaluations at once", ctx do
      test = self()

      blocking = fn node ->
        send(test, {:planning, self()})

        receive do
          :continue -> Agent.get(ctx.world, &Map.get(&1.workloads, node, []))
        end
      end

      # sustained_ms: 0 so that the cycle run at boot already reaches the workload fetch
      start_nowait(ctx, workloads_fun: blocking, config: [sustained_ms: 0])
      assert_receive {:planning, eval}
      assert {:skipped, :busy} = Coordinator.rebalance_now(ctx.coordinator)

      callers = for _ <- 1..3, do: Task.async(fn -> evaluate(ctx) end)
      send(Process.whereis(ctx.coordinator), :tick)
      send(Process.whereis(ctx.coordinator), :tick)
      _ = :sys.get_state(ctx.coordinator)

      # Everybody joined the cycle in flight; nobody started a second one.
      refute_received {:planning, _other}
      send(eval, :continue)

      results = Task.await_many(callers)
      assert [{:ok, plan}, {:ok, plan}, {:ok, plan}] = results
      assert length(plan.moves) == 1
      refute_received {:planning, _other}
      assert evicted() == ["web-1"]
    end

    test "a cycle that straddles a leadership change does not keep its hot tracking", ctx do
      test = self()
      world = ctx.world

      nodes_fun = fn ->
        if Agent.get(world, &Map.get(&1, :block?, false)) do
          send(test, {:reading_scores, self()})

          receive do
            :continue -> :ok
          end
        end

        Agent.get(world, & &1.scores)
      end

      start(ctx, nodes_fun: nodes_fun)

      set(ctx, :block?, true)
      caller = Task.async(fn -> evaluate_at(ctx, 119_000) end)
      assert_receive {:reading_scores, eval}

      # leadership is lost and regained while that cycle is still running
      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.leader_topic, {:leadership, :lost})
      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.leader_topic, {:leadership, :acquired})
      _ = :sys.get_state(ctx.coordinator)

      set(ctx, :block?, false)
      send(eval, :continue)
      assert {:ok, %{status: :not_sustained}} = Task.await(caller)
      :ok = Coordinator.await_idle(ctx.coordinator)

      # hot since 0 according to the old term; the new term started watching at 119s
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, @sustained)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 238_999)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, 239_000)
    end

    test "losing the cooldown table restarts the sustained window", ctx do
      start(ctx)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 100_000)

      :ok = stop_supervised(Cooldowns)
      assert {:skipped, :cooldowns_unavailable} = evaluate_at(ctx, @sustained)
      assert Kube.mutations() == []

      start_supervised!({Cooldowns, table: ctx.cooldowns})
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 130_000)
      assert {:ok, %{status: :not_sustained}} = evaluate_at(ctx, 249_999)
      assert {:ok, %{moves: [_]}} = evaluate_at(ctx, 250_000)
    end

    test "no settings process means skip", ctx do
      start(ctx)
      :ok = stop_supervised(Settings)
      assert {:skipped, :settings_unavailable} = evaluate_at(ctx, @sustained)
      assert Kube.mutations() == []
    end
  end

  ## Status replication

  describe "status on non-leaders" do
    setup ctx do
      set(ctx, :leader?, false)
      :ok
    end

    defp leader_state(ctx, cooldowns) do
      plan = %Cadmium.Catalyst.Plan{generated_at: 42, status: :balanced, summary: "from node-b"}

      payload = %{
        from: "node-b",
        last_plan: plan,
        last_evaluated_at: 42,
        cooldowns: cooldowns
      }

      Phoenix.PubSub.broadcast(Cadmium.PubSub, ctx.sync_topic, {:catalyst_leader_state, payload})
      _ = :sys.get_state(ctx.coordinator)
      plan
    end

    test "shows the leader's last plan and cooldowns", ctx do
      start(ctx, leader_current_fun: fn -> "node-b" end)
      Phoenix.PubSub.subscribe(Cadmium.PubSub, ctx.topic)

      cooldowns = %{
        nodes: %{"node-a" => 5_000_000},
        workloads: %{"default/ReplicaSet/x" => 6_000_000}
      }

      plan = leader_state(ctx, cooldowns)

      status = Coordinator.status(ctx.coordinator)
      assert %{leader: "node-b", leader?: false, last_plan: ^plan, last_evaluated_at: 42} = status
      assert status.cooldowns == cooldowns
      assert_received {:catalyst_status, ^status}
    end

    test "announces its status when settings change", ctx do
      start(ctx)
      Phoenix.PubSub.subscribe(Cadmium.PubSub, ctx.topic)

      Settings.put(ctx.settings, :dry_run?, true)
      assert_receive {:catalyst_status, %{dry_run?: true, leader?: false}}
    end

    test "a new leader adopts the previous leader's cooldowns", ctx do
      Kube.put(:nodes, [
        kube_node("node-a", taints: [cadmium_taint()]),
        kube_node("node-b"),
        kube_node("node-c")
      ])

      start(ctx)

      leader_state(ctx, %{
        nodes: %{"node-a" => @wall_offset + 200_000},
        workloads: %{"default/ReplicaSet/web-1-rs" => @wall_offset + 800_000}
      })

      set(ctx, :leader?, true)
      assert {:ok, %{status: :cooling_down}} = evaluate(ctx)
      # node-a's taint belongs to a cooldown we inherited: not stale
      assert Kube.calls(:remove_node_taint) == []

      assert Coordinator.status(ctx.coordinator).cooldowns == %{
               nodes: %{"node-a" => @wall_offset + 200_000},
               workloads: %{"default/ReplicaSet/web-1-rs" => @wall_offset + 800_000}
             }

      # ...and is removed by us when that cooldown ends
      set(ctx, :scores, [score("node-a", 50), score("node-b", 60), score("node-c", 45)])
      evaluate_at(ctx, 200_000)
      assert Kube.calls(:remove_node_taint) == [["node-a", taint_key()]]
    end

    test "adopted cooldowns are clamped to the configured lengths", ctx do
      start(ctx)
      leader_state(ctx, %{nodes: %{"node-a" => @wall_offset + 999_999_999}, workloads: %{}})

      set(ctx, :leader?, true)
      evaluate(ctx)

      assert Coordinator.status(ctx.coordinator).cooldowns.nodes ==
               %{"node-a" => @wall_offset + @node_cooldown}
    end

    test "the leader publishes its state for the others", ctx do
      set(ctx, :leader?, true)
      Phoenix.PubSub.subscribe(Cadmium.PubSub, ctx.sync_topic)
      start(ctx)
      assert {:ok, plan} = evaluate_at(ctx, @sustained)

      expected_nodes = %{"node-a" => @wall_offset + @sustained + @node_cooldown}

      assert_receive {:catalyst_leader_state,
                      %{from: "node-a", last_plan: ^plan, cooldowns: %{nodes: ^expected_nodes}}}
    end
  end
end
