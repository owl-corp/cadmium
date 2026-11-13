defmodule Cadmium.Kube.FakeTest do
  use ExUnit.Case, async: true

  alias Cadmium.Kube
  alias Cadmium.Kube.{Fake, Lease, Node, PDB, Pod}

  setup do
    fake = start_supervised!({Fake, name: nil})
    Fake.use_server(fake)
    %{fake: fake}
  end

  defp pod(namespace, name, attrs \\ []) do
    struct!(
      %Pod{
        namespace: namespace,
        name: name,
        uid: "uid-#{namespace}-#{name}",
        node_name: "node-a",
        phase: "Running",
        labels: %{"app" => "web"},
        owner_kind: "ReplicaSet",
        owner_name: "web-abc"
      },
      attrs
    )
  end

  describe "server resolution" do
    test "the facade reaches the server chosen with use_server/1", %{fake: fake} do
      assert Kube.client() == Fake
      assert Fake.server() == fake

      Fake.put_node("node-a")
      assert {:ok, [%Node{name: "node-a"}]} = Kube.list_nodes()
    end

    test "tasks and supervised processes inherit the test's server", %{fake: fake} do
      assert Task.await(Task.async(&Fake.server/0)) == fake

      agent = start_supervised!({Agent, fn -> Fake.server() end})
      assert Agent.get(agent, & &1) == fake
      assert Agent.get(agent, fn _ -> Fake.server() end) == fake
    end

    test "falls back to the default name" do
      assert spawn_server_lookup() == Fake
    end

    test "callbacks report :unavailable when no server runs" do
      Fake.use_server(:no_such_fake)

      assert Kube.list_nodes() == {:error, :unavailable}
      assert Kube.get_lease("default", "l") == {:error, :unavailable}
      assert Kube.evict_pod("shop", "p") == {:error, :unavailable}
    end

    test "helpers take an explicit server" do
      other = start_supervised!({Fake, name: nil}, id: :other)

      assert Fake.put_node(other, "node-z") == :ok
      assert %Node{name: "node-z"} = Fake.get_node(other, "node-z")
      assert Fake.get_node("node-z") == nil
    end

    # an unlinked process with no $callers/$ancestors pointing at the test
    defp spawn_server_lookup do
      test = self()
      spawn(fn -> send(test, {:server, Fake.server()}) end)
      assert_receive {:server, server}
      server
    end
  end

  describe "nodes, pods and PDBs" do
    test "put_node/1 with a name creates a healthy node" do
      Fake.put_node("node-a")

      assert %Node{
               name: "node-a",
               ready?: true,
               unschedulable?: false,
               taints: [],
               allocatable_cpu_millis: 8_000
             } = Fake.get_node("node-a")

      Fake.put_node(%Node{name: "node-a", ready?: false})
      assert {:ok, [%Node{ready?: false}]} = Kube.list_nodes()

      Fake.delete_node("node-a")
      assert Kube.list_nodes() == {:ok, []}
    end

    test "list_pods/1 filters by node and namespace" do
      Fake.put_pod(pod("shop", "web-1"))
      Fake.put_pod(pod("shop", "web-2", node_name: "node-b"))
      Fake.put_pod(pod("data", "idx-1"))

      names = fn opts ->
        {:ok, pods} = Kube.list_pods(opts)
        Enum.map(pods, & &1.name)
      end

      assert names.([]) == ["idx-1", "web-1", "web-2"]
      assert names.(node: "node-a") == ["idx-1", "web-1"]
      assert names.(namespace: "shop") == ["web-1", "web-2"]
      assert names.(namespace: "shop", node: "node-b") == ["web-2"]
      assert names.(node: "node-x") == []

      Fake.delete_pod("shop", "web-1")
      assert Fake.get_pod("shop", "web-1") == nil
      assert %Pod{name: "web-2"} = Fake.get_pod("shop", "web-2")
    end

    test "list_pdbs/0" do
      pdb = %PDB{namespace: "shop", name: "web", match_labels: %{"app" => "web"}}
      Fake.put_pdb(pdb)
      assert Kube.list_pdbs() == {:ok, [pdb]}

      Fake.delete_pdb("shop", "web")
      assert Kube.list_pdbs() == {:ok, []}
    end
  end

  describe "workload_replicas/3" do
    test "returns registered counts" do
      Fake.set_workload_replicas("shop", "ReplicaSet", "web-abc", 3)
      Fake.set_workload_replicas("data", "StatefulSet", "cache", %{desired: 3, ready: 1})
      Fake.set_workload_replicas("shop", "Deployment", "web", desired: 2)

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-abc") ==
               {:ok, %{desired: 3, ready: 3}}

      assert Kube.workload_replicas("data", "StatefulSet", "cache") ==
               {:ok, %{desired: 3, ready: 1}}

      assert Kube.workload_replicas("shop", "Deployment", "web") == {:ok, %{desired: 2, ready: 2}}

      Fake.set_workload_replicas("shop", "Deployment", "web", nil)
      assert Kube.workload_replicas("shop", "Deployment", "web") == {:error, :not_found}
    end

    test "mirrors the HTTP client's errors" do
      Fake.set_workload_replicas("batch", "Job", "report", 1)

      assert Kube.workload_replicas("shop", "ReplicaSet", "nope") == {:error, :not_found}
      assert Kube.workload_replicas("batch", "Job", "report") == {:error, :unsupported_kind}
      assert Kube.workload_replicas("x", "DaemonSet", "y") == {:error, :unsupported_kind}
    end
  end

  describe "evict_pod/3" do
    test "removes the pod" do
      Fake.put_pod(pod("shop", "web-1"))

      assert Kube.evict_pod("shop", "web-1") == :ok
      assert Kube.list_pods() == {:ok, []}
      assert Kube.evict_pod("shop", "web-1") == {:error, :not_found}
    end

    test "a dry run changes nothing" do
      Fake.put_pod(pod("shop", "web-1"))

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "web",
        match_labels: %{"app" => "web"},
        disruptions_allowed: 1
      })

      assert Kube.evict_pod("shop", "web-1", dry_run: true) == :ok
      assert %Pod{} = Fake.get_pod("shop", "web-1")
      assert {:ok, [%PDB{disruptions_allowed: 1}]} = Kube.list_pdbs()
    end

    test "a real eviction uses up the matching PDB's allowance" do
      Fake.put_pod(pod("shop", "web-1"))
      Fake.put_pod(pod("shop", "web-2"))

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "web",
        match_labels: %{"app" => "web"},
        disruptions_allowed: 1
      })

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "api",
        match_labels: %{"app" => "api"},
        disruptions_allowed: 1
      })

      Fake.put_pdb(%PDB{
        namespace: "data",
        name: "web",
        match_labels: %{"app" => "web"},
        disruptions_allowed: 1
      })

      assert Kube.evict_pod("shop", "web-1") == :ok

      {:ok, pdbs} = Kube.list_pdbs()

      assert Map.new(pdbs, &{{&1.namespace, &1.name}, &1.disruptions_allowed}) ==
               %{{"shop", "web"} => 0, {"shop", "api"} => 1, {"data", "web"} => 1}

      assert Kube.evict_pod("shop", "web-2") == {:error, :pdb_blocked}
      assert Kube.evict_pod("shop", "web-2", dry_run: true) == {:error, :pdb_blocked}
      assert %Pod{} = Fake.get_pod("shop", "web-2")
    end

    test "match expressions select pods too" do
      Fake.put_pod(pod("shop", "web-1", labels: %{"tier" => "front"}))

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "front",
        match_expressions: [%{"key" => "tier", "operator" => "In", "values" => ["front"]}]
      })

      assert Kube.evict_pod("shop", "web-1") == {:error, :pdb_blocked}
    end

    test "evicted pods are not recreated by default", %{fake: fake} do
      Fake.put_node("node-b")
      Fake.put_pod(pod("shop", "web-1"))
      Fake.set_workload_replicas("shop", "ReplicaSet", "web-abc", 2)

      assert Kube.evict_pod("shop", "web-1") == :ok
      _ = :sys.get_state(fake)

      assert Kube.list_pods() == {:ok, []}

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-abc") ==
               {:ok, %{desired: 2, ready: 2}}
    end
  end

  describe "node taints" do
    @hot %{key: "cadmium.owl-corp.io/hot", value: "true", effect: "PreferNoSchedule"}

    test "add replaces by key and remove is idempotent" do
      Fake.put_node(%Node{
        name: "node-a",
        taints: [%{key: "dedicated", value: "batch", effect: "NoSchedule"}]
      })

      assert Kube.add_node_taint("node-a", @hot) == :ok
      assert Kube.add_node_taint("node-a", %{key: @hot.key, effect: "NoSchedule"}) == :ok

      assert Fake.get_node("node-a").taints == [
               %{key: "dedicated", value: "batch", effect: "NoSchedule"},
               %{key: @hot.key, value: nil, effect: "NoSchedule"}
             ]

      assert Kube.remove_node_taint("node-a", @hot.key) == :ok
      assert Kube.remove_node_taint("node-a", @hot.key) == :ok

      assert Fake.get_node("node-a").taints == [
               %{key: "dedicated", value: "batch", effect: "NoSchedule"}
             ]
    end

    test "unknown nodes are :not_found" do
      assert Kube.add_node_taint("node-x", @hot) == {:error, :not_found}
      assert Kube.remove_node_taint("node-x", @hot.key) == {:error, :not_found}
    end
  end

  describe "recorded calls" do
    test "evictions/0 and taint_calls/0 list every attempt in order" do
      Fake.put_node("node-a")
      Fake.put_pod(pod("shop", "web-1"))

      Kube.add_node_taint("node-a", @hot)
      Kube.evict_pod("shop", "web-1", dry_run: true)
      Kube.evict_pod("shop", "web-1")
      Kube.evict_pod("shop", "gone")
      Kube.remove_node_taint("node-a", @hot.key)
      Kube.remove_node_taint("node-x", @hot.key)

      assert Fake.evictions() == [
               %{namespace: "shop", name: "web-1", dry_run: true, result: :ok},
               %{namespace: "shop", name: "web-1", dry_run: false, result: :ok},
               %{namespace: "shop", name: "gone", dry_run: false, result: {:error, :not_found}}
             ]

      assert Fake.taint_calls() == [
               %{op: :add, node: "node-a", taint: @hot, result: :ok},
               %{op: :remove, node: "node-a", key: @hot.key, result: :ok},
               %{op: :remove, node: "node-x", key: @hot.key, result: {:error, :not_found}}
             ]

      assert [%{op: :add_node_taint, args: ["node-a", @hot], result: :ok} | _] = Fake.calls()
      assert length(Fake.calls()) == 6

      Fake.clear_calls()
      assert Fake.calls() == []
      assert Fake.evictions() == []
    end
  end

  describe "injected failures" do
    test "fail/2 breaks one callback until healed" do
      Fake.put_pod(pod("shop", "web-1"))
      Fake.fail(:evict_pod, :boom)

      assert Kube.evict_pod("shop", "web-1") == {:error, :boom}
      assert {:ok, [_pod]} = Kube.list_pods()
      assert [%{result: {:error, :boom}}] = Fake.evictions()

      Fake.fail(:evict_pod, nil)
      assert Kube.evict_pod("shop", "web-1") == :ok
    end

    test "fail(:all, reason) breaks everything" do
      Fake.fail(:all, :timeout)

      assert Kube.list_nodes() == {:error, :timeout}
      assert Kube.get_lease("default", "l") == {:error, :timeout}

      Fake.heal()
      assert Kube.list_nodes() == {:ok, []}
    end
  end

  describe "leases" do
    @lease %Lease{
      namespace: "default",
      name: "cadmium-catalyst",
      holder: "node-a",
      duration_seconds: 15
    }

    test "create, get and update with resourceVersion guards" do
      assert Kube.get_lease("default", "cadmium-catalyst") == {:error, :not_found}
      assert Kube.update_lease(@lease) == {:error, :not_found}

      assert {:ok, %Lease{holder: "node-a", resource_version: v1} = created} =
               Kube.create_lease(@lease)

      assert is_binary(v1)
      assert Kube.create_lease(@lease) == {:error, :conflict}
      assert Kube.get_lease("default", "cadmium-catalyst") == {:ok, created}

      assert {:ok, %Lease{transitions: 1, resource_version: v2} = updated} =
               Kube.update_lease(%{created | transitions: 1})

      assert v2 != v1
      assert Kube.update_lease(%{created | holder: "node-b"}) == {:error, :conflict}
      assert Kube.get_lease("default", "cadmium-catalyst") == {:ok, updated}

      # like the API server: no resourceVersion, no guard
      assert {:ok, %Lease{holder: "node-c"}} =
               Kube.update_lease(%{updated | holder: "node-c", resource_version: nil})

      Fake.delete_lease("default", "cadmium-catalyst")
      assert Kube.get_lease("default", "cadmium-catalyst") == {:error, :not_found}
    end
  end

  test "reset/0 drops everything" do
    Fake.put_node("node-a")
    Fake.put_pod(pod("shop", "web-1"))
    Fake.fail(:list_pdbs, :boom)
    Kube.create_lease(@lease)
    Kube.evict_pod("shop", "web-1", dry_run: true)

    Fake.reset()

    assert Kube.list_nodes() == {:ok, []}
    assert Kube.list_pods() == {:ok, []}
    assert Kube.list_pdbs() == {:ok, []}
    assert Kube.get_lease("default", "cadmium-catalyst") == {:error, :not_found}
    assert Fake.calls() == []
  end

  describe "seed_demo/1" do
    test "adds the node, its demo pods, replica counts and the blocking PDB" do
      assert Fake.seed_demo("node-a") == :ok

      assert {:ok, [%Node{name: "node-a", ready?: true}]} = Kube.list_nodes()
      assert {:ok, pods} = Kube.list_pods(node: "node-a")

      assert Enum.sort_by(pods, &{&1.namespace, &1.name}) ==
               Enum.sort_by(Cadmium.Demo.pods("node-a"), &{&1.namespace, &1.name})

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-7d9f8b6c5") ==
               {:ok, %{desired: 2, ready: 2}}

      assert Kube.workload_replicas("shop", "ReplicaSet", "checkout-6b8c7d9f4") ==
               {:ok, %{desired: 1, ready: 1}}

      assert Kube.workload_replicas("data", "StatefulSet", "cache") ==
               {:ok, %{desired: 1, ready: 1}}

      assert Kube.workload_replicas("batch", "Job", "report-28391") == {:error, :unsupported_kind}

      assert Kube.list_pdbs() ==
               {:ok,
                [
                  %PDB{
                    namespace: "shop",
                    name: "checkout",
                    match_labels: %{"app" => "checkout"},
                    disruptions_allowed: 0
                  }
                ]}

      checkout = Enum.find(pods, &(&1.owner_name == "checkout-6b8c7d9f4"))
      assert Kube.evict_pod("shop", checkout.name) == {:error, :pdb_blocked}
    end

    test "replica counts add up across nodes" do
      Fake.seed_demo("node-a")
      Fake.seed_demo("node-b")
      Fake.seed_demo("node-c")

      assert {:ok, nodes} = Kube.list_nodes()
      assert Enum.map(nodes, & &1.name) == ["node-a", "node-b", "node-c"]

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-7d9f8b6c5") ==
               {:ok, %{desired: 6, ready: 6}}

      assert Kube.workload_replicas("data", "ReplicaSet", "indexer-84d5f6c7b") ==
               {:ok, %{desired: 3, ready: 3}}

      assert {:ok, [_one]} = Kube.list_pdbs()

      {:ok, pods} = Kube.list_pods()
      assert length(pods) == 3 * length(Cadmium.Demo.pods("node-a"))
    end

    test "is idempotent and leaves a seeded node alone" do
      Fake.seed_demo("node-a")
      {:ok, [victim | _] = before} = Kube.list_pods(namespace: "data")
      assert Kube.evict_pod(victim.namespace, victim.name) == :ok

      Fake.seed_demo("node-a")

      {:ok, pods} = Kube.list_pods(namespace: "data")
      assert length(pods) == length(before) - 1

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-7d9f8b6c5") ==
               {:ok, %{desired: 2, ready: 2}}
    end

    test "can be requested at start" do
      fake = start_supervised!({Fake, name: nil, seed_demo: "node-q"}, id: :seeded)
      assert %Node{name: "node-q"} = Fake.get_node(fake, "node-q")
    end
  end

  describe "rescheduling" do
    setup do
      fake =
        start_supervised!({Fake, name: nil, reschedule: true, reschedule_delay_ms: 0},
          id: :rescheduling
        )

      Fake.use_server(fake)
      %{fake: fake}
    end

    test "an evicted pod comes back on the emptiest untainted node", %{fake: fake} do
      Fake.put_node("node-a")
      Fake.put_node("node-b")
      Fake.put_node("node-c")

      Fake.put_node(%Node{
        name: "node-d",
        taints: [%{key: "k", value: nil, effect: "NoSchedule"}]
      })

      Fake.put_node(%Node{name: "node-e", unschedulable?: true})
      Fake.put_node(%Node{name: "node-f", ready?: false})
      Kube.add_node_taint("node-a", @hot)

      evicted = pod("shop", "web-1")
      Fake.put_pod(evicted)
      Fake.put_pod(pod("shop", "web-2"))
      Fake.put_pod(pod("shop", "web-3", node_name: "node-b"))
      Fake.set_workload_replicas("shop", "ReplicaSet", "web-abc", 3)

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "web",
        match_labels: %{"app" => "web"},
        disruptions_allowed: 1
      })

      assert Kube.evict_pod("shop", "web-1") == :ok
      _ = :sys.get_state(fake)

      {:ok, pods} = Kube.list_pods(namespace: "shop")
      assert length(pods) == 3
      assert Fake.get_pod("shop", "web-1") == nil

      assert [moved] = Enum.filter(pods, &(&1.node_name == "node-c"))
      assert moved.name =~ ~r/^web-abc-[a-z2-7]{5}$/
      assert moved.uid != evicted.uid
      assert moved.labels == evicted.labels
      assert moved.owner_name == evicted.owner_name

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-abc") ==
               {:ok, %{desired: 3, ready: 3}}

      assert {:ok, [%PDB{disruptions_allowed: 1}]} = Kube.list_pdbs()
    end

    test "with nowhere to go the pod stays away, the workload one short and the PDB used up" do
      Fake.put_node(%Node{
        name: "node-a",
        taints: [%{key: "k", value: nil, effect: "PreferNoSchedule"}]
      })

      Fake.put_pod(pod("shop", "web-1"))
      Fake.set_workload_replicas("shop", "ReplicaSet", "web-abc", 3)

      Fake.put_pdb(%PDB{
        namespace: "shop",
        name: "web",
        match_labels: %{"app" => "web"},
        disruptions_allowed: 1
      })

      assert Kube.evict_pod("shop", "web-1") == :ok

      assert Kube.list_pods() == {:ok, []}

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-abc") ==
               {:ok, %{desired: 3, ready: 2}}

      assert {:ok, [%PDB{disruptions_allowed: 0}]} = Kube.list_pdbs()
    end

    test "StatefulSet pods keep their name; DaemonSet pods and dry runs are not rescheduled", %{
      fake: fake
    } do
      Fake.put_node("node-a")
      Fake.put_node("node-b")
      Fake.put_pod(pod("data", "cache-0", owner_kind: "StatefulSet", owner_name: "cache"))
      Fake.put_pod(pod("mon", "exporter-1", owner_kind: "DaemonSet", owner_name: "exporter"))
      Fake.put_pod(pod("shop", "web-1"))

      assert Kube.evict_pod("data", "cache-0") == :ok
      assert Kube.evict_pod("mon", "exporter-1") == :ok
      assert Kube.evict_pod("shop", "web-1", dry_run: true) == :ok
      _ = :sys.get_state(fake)

      assert %Pod{node_name: "node-b", uid: uid} = Fake.get_pod("data", "cache-0")
      assert uid != "uid-data-cache-0"
      assert Kube.list_pods(namespace: "mon") == {:ok, []}
      assert %Pod{node_name: "node-a", uid: "uid-shop-web-1"} = Fake.get_pod("shop", "web-1")
    end
  end
end
