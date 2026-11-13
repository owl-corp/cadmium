defmodule Cadmium.Catalyst.PolicyTest do
  use ExUnit.Case, async: true

  import Cadmium.CatalystFixtures

  alias Cadmium.Catalyst.{Plan, Policy}

  @nodes ["node-a", "node-b", "node-c"]

  # node-a is hot (86), node-b is warm (60, above the 57.5 destination ceiling),
  # node-c is cool (45). hot_since makes node-a sustained at mono_now.
  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        config: config(),
        generated_at: 1_700_000_000_000,
        scores: [score("node-a", 86), score("node-b", 60), score("node-c", 45)],
        kube_nodes: Enum.map(@nodes, &kube_node/1),
        hot_since: %{"node-a" => 0},
        mono_now: 120_000,
        node_cooldowns: %{},
        workload_cooldowns: %{},
        workloads: %{},
        pdbs: [],
        replicas: %{}
      },
      Map.new(overrides)
    )
  end

  defp with_workloads(workloads, overrides \\ %{}) do
    input(
      Map.merge(
        %{workloads: %{"node-a" => workloads}, replicas: replicas(workloads)},
        Map.new(overrides)
      )
    )
  end

  defp rejection_of(workload, overrides \\ %{}) do
    plan = Policy.plan(with_workloads([workload], overrides))
    assert plan.moves == []
    assert [{^workload, reason}] = plan.rejected
    reason
  end

  describe "imbalance detection" do
    test "fewer than two live nodes is :insufficient_nodes" do
      for scores <- [[], [score("node-a", 99)], nil] do
        plan = Policy.plan(input(scores: scores))
        assert %Plan{status: :insufficient_nodes, moves: [], hot: [], cool: []} = plan
        assert plan.summary =~ "at least 2"
        assert plan.generated_at == 1_700_000_000_000
      end
    end

    test "duplicate and malformed scores do not count as extra nodes" do
      scores = [score("node-a", 99), score("node-a", 10), %{score: 1}, nil]
      assert Policy.plan(input(scores: scores)).status == :insufficient_nodes
    end

    test "balanced when no node reaches the hot threshold" do
      plan = Policy.plan(input(scores: [score("node-a", 69.9), score("node-c", 20)]))
      assert plan.status == :balanced
      assert plan.hot == []
      assert Enum.map(plan.cool, & &1.k8s_node) == ["node-c"]
      assert plan.summary =~ "Balanced"
    end

    test "balanced when everything is uniformly busy (spread below threshold)" do
      plan = Policy.plan(input(scores: [score("node-a", 90), score("node-c", 66)]))
      assert plan.status == :balanced
      assert plan.hot == []
    end

    test "hot needs both the threshold and the spread (boundaries are inclusive)" do
      cfg = config()
      hot = fn scores -> scores |> Policy.hot_nodes(cfg) |> Enum.map(& &1.k8s_node) end

      assert hot.([score("a", 70), score("b", 45)]) == ["a"]
      assert hot.([score("a", 70), score("b", 45.1)]) == []
      assert hot.([score("a", 69.9), score("b", 10)]) == []
      assert hot.([score("a", 80), score("b", 95), score("c", 40)]) == ["b", "a"]
    end

    test "imbalanced plan lists hot (hottest first) and viable cool nodes" do
      plan = Policy.plan(input())
      assert plan.status == :imbalanced
      assert Enum.map(plan.hot, & &1.k8s_node) == ["node-a"]
      # node-b (60) is neither hot nor below the 57.5 ceiling
      assert Enum.map(plan.cool, & &1.k8s_node) == ["node-c"]
      assert plan.summary =~ "node-a"
    end

    test "the destination ceiling is hot_threshold - spread_threshold / 2, exclusive" do
      cfg = config()
      assert Cadmium.Catalyst.Config.cool_ceiling(cfg) == 57.5
      assert Policy.viable_destination?(score("n", 57.4), kube_node("n"), cfg)
      refute Policy.viable_destination?(score("n", 57.5), kube_node("n"), cfg)
    end

    test "destinations must be Ready, schedulable, untainted and known to Kubernetes" do
      cfg = config()
      cool = score("n", 20)

      assert Policy.viable_destination?(cool, kube_node("n"), cfg)

      assert Policy.viable_destination?(
               cool,
               kube_node("n", taints: [%{key: "soft", value: nil, effect: "PreferNoSchedule"}]),
               cfg
             )

      refute Policy.viable_destination?(cool, nil, cfg)
      refute Policy.viable_destination?(cool, kube_node("n", ready?: false), cfg)
      refute Policy.viable_destination?(cool, kube_node("n", unschedulable?: true), cfg)

      for effect <- ["NoSchedule", "NoExecute"] do
        node = kube_node("n", taints: [%{key: "dedicated", value: "x", effect: effect}])
        refute Policy.viable_destination?(cool, node, cfg)
      end

      refute Policy.viable_destination?(cool, kube_node("n", taints: [cadmium_taint()]), cfg)
    end

    test "no viable destination means imbalanced with no moves" do
      w = workload("web-1", "node-a")

      for bad <- [
            kube_node("node-c", ready?: false),
            kube_node("node-c", unschedulable?: true),
            kube_node("node-c", taints: [cadmium_taint()]),
            kube_node("node-c", taints: [%{key: "k", value: nil, effect: "NoSchedule"}])
          ] do
        nodes = [kube_node("node-a"), kube_node("node-b"), bad]
        plan = Policy.plan(with_workloads([w], kube_nodes: nodes))
        assert plan.status == :imbalanced
        assert plan.moves == []
        assert plan.rejected == []
        assert plan.cool == []
        assert plan.summary =~ "no viable cool destination"
      end
    end

    test "an unavailable Kubernetes node list means no action" do
      plan = Policy.plan(with_workloads([workload("web-1", "node-a")], kube_nodes: nil))
      assert plan.status == :imbalanced
      assert plan.moves == []
      assert plan.summary =~ "unavailable"
    end

    test "a hot node that is cordoned, NotReady or unknown to Kubernetes is not acted on" do
      w = workload("web-1", "node-a")

      for nodes <- [
            [kube_node("node-a", unschedulable?: true), kube_node("node-c")],
            [kube_node("node-a", ready?: false), kube_node("node-c")],
            [kube_node("node-c")]
          ] do
        plan = Policy.plan(with_workloads([w], kube_nodes: nodes))
        assert plan.status == :imbalanced
        assert plan.moves == []
        assert plan.summary =~ "cannot be acted on"
      end
    end

    test "the only viable destination must be at least the spread cooler than the hot node" do
      # coolest overall (node-c, 40) is cordoned; node-b at 50 is viable but only 22 cooler
      scores = [score("node-a", 72), score("node-b", 50), score("node-c", 40)]

      nodes = [
        kube_node("node-a"),
        kube_node("node-b"),
        kube_node("node-c", unschedulable?: true)
      ]

      plan =
        Policy.plan(with_workloads([workload("w", "node-a")], scores: scores, kube_nodes: nodes))

      assert Enum.map(plan.hot, & &1.k8s_node) == ["node-a"]
      assert Enum.map(plan.cool, & &1.k8s_node) == ["node-b"]
      assert plan.moves == []
    end
  end

  describe "sustained window" do
    test ":not_sustained until the node has been hot for sustained_ms" do
      w = workload("web-1", "node-a")

      plan = Policy.plan(with_workloads([w], hot_since: %{"node-a" => 1}, mono_now: 120_000))
      assert plan.status == :not_sustained
      assert plan.moves == []
      assert plan.rejected == []
      assert Enum.map(plan.hot, & &1.k8s_node) == ["node-a"]
      assert plan.summary =~ "not yet"

      plan = Policy.plan(with_workloads([w], hot_since: %{"node-a" => 0}, mono_now: 120_000))
      assert plan.status == :imbalanced
      assert [_move] = plan.moves
    end

    test "a hot node without tracking is not sustained" do
      plan = Policy.plan(with_workloads([workload("web-1", "node-a")], hot_since: %{}))
      assert plan.status == :not_sustained
    end

    test "ignore_sustained? (simulation) skips the window" do
      plan =
        Policy.plan(
          with_workloads([workload("web-1", "node-a")], hot_since: %{}, ignore_sustained?: true)
        )

      assert plan.status == :imbalanced
      assert [_move] = plan.moves
    end

    test "track_hot keeps, starts and resets timestamps" do
      cfg = config()
      hot = [score("node-a", 86), score("node-c", 45)]
      calm = [score("node-a", 60), score("node-c", 45)]

      since = Policy.track_hot(%{}, hot, cfg, 1_000)
      assert since == %{"node-a" => 1_000}

      # still hot: timestamp kept
      assert Policy.track_hot(since, hot, cfg, 5_000) == %{"node-a" => 1_000}

      # dropped below the threshold: forgotten, and the window restarts afterwards
      assert Policy.track_hot(since, calm, cfg, 6_000) == %{}
      assert Policy.track_hot(%{}, hot, cfg, 7_000) == %{"node-a" => 7_000}

      # disappeared from the mesh: forgotten
      assert Policy.track_hot(since, [score("node-b", 90), score("node-c", 45)], cfg, 8_000) ==
               %{"node-b" => 8_000}

      # still above the threshold but no longer spread enough: forgotten
      assert Policy.track_hot(since, [score("node-a", 86), score("node-c", 70)], cfg, 9_000) ==
               %{}
    end
  end

  describe "node cooldown" do
    test ":cooling_down when every actionable hot node is cooling" do
      plan =
        Policy.plan(
          with_workloads([workload("web-1", "node-a")], node_cooldowns: %{"node-a" => 999_999})
        )

      assert plan.status == :cooling_down
      assert plan.moves == []
      assert plan.rejected == []
      assert plan.summary =~ "cooldown"
    end

    test "a cooling node is skipped while another hot node is handled" do
      scores = [score("node-a", 90), score("node-b", 80), score("node-c", 40)]
      wa = workload("api-1", "node-a")
      wb = workload("web-1", "node-b")

      plan =
        Policy.plan(
          input(
            scores: scores,
            hot_since: %{"node-a" => 0, "node-b" => 0},
            node_cooldowns: %{"node-a" => 1},
            workloads: %{"node-a" => [wa], "node-b" => [wb]},
            replicas: replicas([wa, wb]),
            config: config(max_evictions_per_cycle: 5)
          )
        )

      assert plan.status == :imbalanced
      assert [%{from_node: "node-b", workload: ^wb}] = plan.moves
    end
  end

  describe "candidate rejection reasons" do
    test "a healthy replicated pod is a candidate" do
      w = workload("web-1", "node-a")
      plan = Policy.plan(with_workloads([w]))
      assert [%{workload: ^w, from_node: "node-a"}] = plan.moves
      assert plan.rejected == []
    end

    test ":namespace_excluded" do
      assert rejection_of(workload("dns", "node-a", namespace: "kube-system")) ==
               :namespace_excluded
    end

    test ":mirror_pod" do
      assert rejection_of(workload("etcd", "node-a", mirror?: true)) == :mirror_pod
      assert rejection_of(workload("etcd", "node-a", owner_kind: "Node")) == :mirror_pod
    end

    test ":daemonset" do
      assert rejection_of(workload("agent", "node-a", owner_kind: "DaemonSet")) == :daemonset
    end

    test ":job" do
      assert rejection_of(workload("batch", "node-a", owner_kind: "Job")) == :job
    end

    test ":unmanaged" do
      assert rejection_of(workload("bare", "node-a", owner_kind: nil, owner_name: nil)) ==
               :unmanaged

      assert rejection_of(workload("bare", "node-a", owner_name: nil)) == :unmanaged
    end

    test ":deleting" do
      assert rejection_of(workload("web-1", "node-a", deleting?: true)) == :deleting
    end

    test ":not_running" do
      assert rejection_of(workload("web-1", "node-a", phase: "Pending")) == :not_running
      assert rejection_of(workload("web-1", "node-a", phase: nil)) == :not_running
    end

    test ":opted_out only when the annotation is \"false\"" do
      annotation = config().opt_out_annotation

      assert rejection_of(workload("web-1", "node-a", annotations: %{annotation => "false"})) ==
               :opted_out

      assert rejection_of(workload("web-1", "node-a", annotations: %{annotation => " False "})) ==
               :opted_out

      w = workload("web-1", "node-a", annotations: %{annotation => "true"})
      assert [_move] = Policy.plan(with_workloads([w])).moves
    end

    test ":local_storage" do
      assert rejection_of(workload("cache", "node-a", local_storage?: true)) == :local_storage
    end

    test "decoded emptyDir pods are movable, but hostPath pods are rejected" do
      w = workload("scratch", "node-a")

      raw = %{
        "metadata" => %{
          "name" => w.pod.name,
          "namespace" => w.pod.namespace,
          "uid" => w.pod.uid,
          "ownerReferences" => [
            %{"kind" => "ReplicaSet", "name" => w.pod.owner_name, "controller" => true}
          ]
        },
        "spec" => %{"nodeName" => "node-a", "volumes" => [%{"emptyDir" => %{}}]},
        "status" => %{"phase" => "Running"}
      }

      scratch = %{w | pod: Cadmium.Kube.Decode.pod(raw)}
      assert [%{workload: ^scratch}] = Policy.plan(with_workloads([scratch])).moves

      raw = put_in(raw, ["spec", "volumes"], [%{"emptyDir" => %{}}, %{"hostPath" => %{}}])
      host = %{w | pod: Cadmium.Kube.Decode.pod(raw)}
      assert rejection_of(host) == :local_storage
    end

    test "single-replica workloads are eligible when ready" do
      w = workload("solo", "node-a")

      assert [%{workload: ^w}] =
               Policy.plan(with_workloads([w], replicas: replicas([w], %{desired: 1, ready: 1}))).moves
    end

    test ":single_replica when desired is zero or replica info is unavailable" do
      w = workload("solo", "node-a")
      assert rejection_of(w, replicas: replicas([w], %{desired: 0, ready: 1})) == :single_replica
      assert rejection_of(w, replicas: %{}) == :single_replica
      assert rejection_of(w, replicas: replicas([w], :error)) == :single_replica
    end

    test ":replicas_not_ready when the workload is already degraded" do
      w = workload("web-1", "node-a")

      assert rejection_of(w, replicas: replicas([w], %{desired: 3, ready: 2})) ==
               :replicas_not_ready

      assert rejection_of(w, replicas: replicas([w], %{desired: 1, ready: 0})) ==
               :replicas_not_ready
    end

    test ":pdb_blocked when a matching PDB allows no disruptions" do
      w = workload("web-1", "node-a")
      blocked = pdb("web", match_labels: %{"app" => "web-1"}, disruptions_allowed: 0)
      assert rejection_of(w, pdbs: [blocked]) == :pdb_blocked

      # any one blocking PDB is enough
      open = pdb("web-open", match_labels: %{"app" => "web-1"}, disruptions_allowed: 2)
      assert rejection_of(w, pdbs: [open, blocked]) == :pdb_blocked

      # PDB list unavailable
      assert rejection_of(w, pdbs: nil) == :pdb_blocked
    end

    test "PDBs that do not apply or still allow disruptions do not block" do
      w = workload("web-1", "node-a")

      pdbs = [
        pdb("allows", match_labels: %{"app" => "web-1"}, disruptions_allowed: 1),
        pdb("other-app", match_labels: %{"app" => "db"}, disruptions_allowed: 0),
        pdb("other-ns", namespace: "prod", match_labels: %{}, disruptions_allowed: 0)
      ]

      assert [_move] = Policy.plan(with_workloads([w], pdbs: pdbs)).moves
    end

    test ":workload_cooldown is keyed by namespace/owner_kind/owner_name" do
      w = workload("web-1", "node-a")
      assert Policy.workload_key(w.pod) == "default/ReplicaSet/web-1-rs"

      assert rejection_of(w, workload_cooldowns: %{"default/ReplicaSet/web-1-rs" => 1}) ==
               :workload_cooldown

      plan =
        Policy.plan(with_workloads([w], workload_cooldowns: %{"other/ReplicaSet/web-1-rs" => 1}))

      assert [_move] = plan.moves
    end

    test "checks run in the documented order" do
      annotation = config().opt_out_annotation
      # violates everything at once; peel reasons off one at a time
      steps = [
        {:namespace_excluded, namespace: "default"},
        {:mirror_pod, mirror?: false},
        {:daemonset, owner_kind: "Job"},
        {:job, owner_kind: nil},
        {:unmanaged, owner_kind: "ReplicaSet"},
        {:deleting, deleting?: false},
        {:not_running, phase: "Running"},
        {:opted_out, annotations: %{}},
        {:local_storage, local_storage?: false}
      ]

      attrs = [
        namespace: "kube-system",
        mirror?: true,
        owner_kind: "DaemonSet",
        owner_name: "x-rs",
        deleting?: true,
        phase: "Pending",
        annotations: %{annotation => "false"},
        local_storage?: true
      ]

      blocked = pdb("all", disruptions_allowed: 0)
      cooldowns = %{"default/ReplicaSet/x-rs" => 1}
      key = {"default", "ReplicaSet", "x-rs"}

      attrs =
        Enum.reduce(steps, attrs, fn {expected, fix}, attrs ->
          w = workload("x", "node-a", attrs)

          assert rejection_of(w, replicas: %{}, pdbs: [blocked], workload_cooldowns: cooldowns) ==
                   expected

          Keyword.merge(attrs, fix)
        end)

      w = workload("x", "node-a", attrs)
      common = [pdbs: [blocked], workload_cooldowns: cooldowns]

      assert rejection_of(w, [replicas: %{}] ++ common) == :single_replica

      assert rejection_of(w, [replicas: %{key => %{desired: 2, ready: 1}}] ++ common) ==
               :replicas_not_ready

      ready = %{key => %{desired: 2, ready: 2}}
      assert rejection_of(w, [replicas: ready] ++ common) == :pdb_blocked

      assert rejection_of(w, replicas: ready, pdbs: [], workload_cooldowns: cooldowns) ==
               :workload_cooldown
    end

    test "only workloads on eligible hot nodes are considered" do
      wa = workload("web-1", "node-a")
      stray = workload("web-2", "node-b")

      plan =
        Policy.plan(
          input(
            workloads: %{"node-a" => [wa, stray], "node-b" => [stray]},
            replicas: replicas([wa, stray])
          )
        )

      assert [%{workload: ^wa}] = plan.moves
      assert plan.rejected == []
    end
  end

  describe "ranking" do
    test "cpu-dominant node: the pod contributing most CPU pressure goes first" do
      quiet = workload("quiet", "node-a", sample: [cpu_usage_millis: 100.0])

      busy =
        workload("busy", "node-a",
          sample: [cpu_usage_millis: 3_100.0, cpu_throttled_ratio: 0.62],
          cpu_drift: 3.1
        )

      mid = workload("mid", "node-a", sample: [cpu_usage_millis: 900.0], cpu_drift: 1.2)

      plan =
        Policy.plan(
          with_workloads([quiet, busy, mid], config: config(max_evictions_per_cycle: 3))
        )

      assert Enum.map(plan.moves, & &1.workload.pod.name) == ["busy", "mid", "quiet"]
    end

    test "a throttled pod outranks an unthrottled one with similar usage" do
      a = workload("a", "node-a", sample: [cpu_usage_millis: 1_000.0])
      b = workload("b", "node-a", sample: [cpu_usage_millis: 950.0, cpu_throttled_ratio: 0.5])
      assert [%{workload: ^b}] = Policy.plan(with_workloads([a, b])).moves
    end

    test "memory-dominant node ranks by memory" do
      scores = [
        score("node-a", 86, %{cpu: 20.0, memory: 86.0, io: 5.0}),
        score("node-c", 45)
      ]

      cpu_hog =
        workload("cpu-hog", "node-a", sample: [cpu_usage_millis: 4_000.0, memory_bytes: 1_000])

      mem_hog =
        workload("mem-hog", "node-a",
          sample: [cpu_usage_millis: 10.0, memory_bytes: 2_147_483_648],
          memory_drift: 2.0
        )

      plan = Policy.plan(with_workloads([cpu_hog, mem_hog], scores: scores))
      assert [%{workload: ^mem_hog, reason: reason}] = plan.moves
      assert reason =~ "(memory)"
      assert reason =~ "2.0 GiB"
      assert reason =~ "2.0x its request"
    end

    test "io-dominant node ranks by I/O" do
      scores = [score("node-a", 86, %{cpu: 20.0, memory: 30.0, io: 86.0}), score("node-c", 45)]
      idle = workload("idle", "node-a", sample: [cpu_usage_millis: 4_000.0, io_bytes_per_s: 10.0])
      writer = workload("writer", "node-a", sample: [io_bytes_per_s: 52_428_800.0])

      plan = Policy.plan(with_workloads([idle, writer], scores: scores))
      assert [%{workload: ^writer, reason: reason}] = plan.moves
      assert reason =~ "(io)"
      assert reason =~ "50.0 MiB/s"
    end

    test "dominant component ties resolve cpu, then memory, then io" do
      assert Policy.dominant_component(score("n", 80, %{cpu: 80.0, memory: 80.0, io: 80.0})) ==
               :cpu

      assert Policy.dominant_component(score("n", 80, %{cpu: 1.0, memory: 80.0, io: 80.0})) ==
               :memory

      assert Policy.dominant_component(score("n", 80, %{cpu: 1.0, memory: 2.0, io: 80.0})) == :io
    end

    test "between equal contributors, the workload with more replicas is preferred" do
      few = workload("few", "node-a")
      many = workload("many", "node-a")

      replicas =
        Map.merge(
          replicas([few], %{desired: 2, ready: 2}),
          replicas([many], %{desired: 8, ready: 8})
        )

      assert [%{workload: ^many}] =
               Policy.plan(with_workloads([few, many], replicas: replicas)).moves
    end

    test "never two pods of the same controller in one cycle" do
      a = workload("web-a", "node-a", owner_name: "web-rs", sample: [cpu_usage_millis: 900.0])
      b = workload("web-b", "node-a", owner_name: "web-rs", sample: [cpu_usage_millis: 800.0])
      c = workload("api-a", "node-a", owner_name: "api-rs", sample: [cpu_usage_millis: 100.0])

      plan = Policy.plan(with_workloads([a, b, c], config: config(max_evictions_per_cycle: 5)))
      assert Enum.map(plan.moves, & &1.workload.pod.name) == ["web-a", "api-a"]
    end

    test "the same controller is not picked on two different hot nodes either" do
      scores = [score("node-a", 90), score("node-b", 85), score("node-c", 40)]
      a = workload("web-a", "node-a", owner_name: "web-rs")
      b = workload("web-b", "node-b", owner_name: "web-rs")

      plan =
        Policy.plan(
          input(
            scores: scores,
            hot_since: %{"node-a" => 0, "node-b" => 0},
            workloads: %{"node-a" => [a], "node-b" => [b]},
            replicas: replicas([a]),
            config: config(max_evictions_per_cycle: 5)
          )
        )

      assert [%{workload: ^a, from_node: "node-a"}] = plan.moves
    end

    test "pods without a measurable contribution are never moved" do
      unsampled = workload("unsampled", "node-a", sample: nil)
      idle = workload("idle", "node-a", sample: [cpu_usage_millis: 0.0])

      plan = Policy.plan(with_workloads([unsampled, idle]))
      assert plan.status == :imbalanced
      assert plan.moves == []
      assert plan.rejected == []
      assert plan.summary =~ "no movable workload"
    end
  end

  describe "max evictions per cycle" do
    test "is a cluster-wide cap" do
      workloads = for i <- 1..5, do: workload("web-#{i}", "node-a")

      for max <- [1, 2, 4] do
        plan =
          Policy.plan(with_workloads(workloads, config: config(max_evictions_per_cycle: max)))

        assert length(plan.moves) == max
      end
    end

    test "zero disables moves" do
      plan =
        Policy.plan(
          with_workloads([workload("web-1", "node-a")],
            config: config(max_evictions_per_cycle: 0)
          )
        )

      assert plan.moves == []
    end

    test "moves are spread across hot nodes, hottest first" do
      scores = [score("node-a", 90), score("node-b", 95), score("node-c", 40)]
      on_a = for i <- 1..2, do: workload("a-#{i}", "node-a")
      on_b = for i <- 1..2, do: workload("b-#{i}", "node-b")

      plan =
        Policy.plan(
          input(
            scores: scores,
            hot_since: %{"node-a" => 0, "node-b" => 0},
            workloads: %{"node-a" => on_a, "node-b" => on_b},
            replicas: replicas(on_a ++ on_b),
            config: config(max_evictions_per_cycle: 3)
          )
        )

      assert Enum.map(plan.moves, & &1.from_node) == ["node-b", "node-a", "node-b"]
    end
  end

  describe "move reason" do
    test "explains the node and the pod" do
      w =
        workload("busy", "node-a",
          sample: [cpu_usage_millis: 3_100.0, cpu_throttled_ratio: 0.62],
          cpu_drift: 3.1
        )

      assert [%{reason: reason}] = Policy.plan(with_workloads([w])).moves

      assert reason ==
               "node-a at 86 (cpu), 41 above coolest; pod throttled 62% using 3.1x its CPU " <>
                 "request; 3/3 replicas ready"
    end
  end
end
