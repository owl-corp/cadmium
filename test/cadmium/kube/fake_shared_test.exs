defmodule Cadmium.Kube.FakeSharedTest do
  # Shared mode registers one well-known :global name.
  use ExUnit.Case, async: false

  alias Cadmium.Kube
  alias Cadmium.Kube.{Fake, Lease, Node}

  defp start_shared(id, opts) do
    start_supervised!({Fake, [name: nil, shared: true] ++ opts}, id: id)
  end

  # Lets :global notice a dead holder and the survivors react to it.
  defp settle(servers) do
    _ = :sys.get_state(:global_name_server)

    for _round <- 1..2, server <- servers do
      _ = :sys.get_state(server)
    end
  end

  test "the first server holds the cluster and later ones forward to it" do
    a = start_shared(:a, seed_demo: "node-a")
    b = start_shared(:b, seed_demo: "node-b")
    settle([a, b])

    assert %{role: :active, active: ^a, shared?: true} = Fake.info(a)
    assert %{role: :standby, active: ^a} = Fake.info(b)
    assert :global.whereis_name(Fake) == a

    for server <- [a, b] do
      Fake.use_server(server)

      assert {:ok, [%Node{name: "node-a"}, %Node{name: "node-b"}]} = Kube.list_nodes()

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-7d9f8b6c5") ==
               {:ok, %{desired: 4, ready: 4}}
    end

    # one lease for everyone
    Fake.use_server(b)
    lease = %Lease{namespace: "default", name: "l", holder: "node-b"}
    assert {:ok, %Lease{holder: "node-b"} = created} = Kube.create_lease(lease)

    Fake.use_server(a)
    assert Kube.get_lease("default", "l") == {:ok, created}
    assert Kube.create_lease(lease) == {:error, :conflict}

    # helpers and recorded calls go through a standby as well
    assert Fake.put_node(b, "node-c") == :ok
    assert %Node{name: "node-c"} = Fake.get_node(a, "node-c")
    assert Kube.evict_pod("nowhere", "nothing") == {:error, :not_found}
    assert [%{name: "nothing"}] = Fake.evictions(b)
  end

  test "a standby takes over with its own demo data when the holder goes away" do
    _a = start_shared(:a, seed_demo: "node-a")
    b = start_shared(:b, [])
    c = start_shared(:c, [])
    assert Fake.seed_demo(b, "node-b") == :ok
    assert Fake.seed_demo(c, "node-c") == :ok

    Fake.use_server(c)
    assert {:ok, [_a, _b, _c]} = Kube.list_nodes()
    assert {:ok, _lease} = Kube.create_lease(%Lease{namespace: "default", name: "l", holder: "x"})

    stop_supervised!(:a)
    settle([b, c])

    assert [active] = Enum.filter([b, c], &(Fake.info(&1).role == :active))
    assert :global.whereis_name(Fake) == active
    assert Fake.info(b).active == active
    assert Fake.info(c).active == active

    # node-a's agent is gone; the survivors re-seeded themselves, the lease is lost
    for server <- [b, c] do
      Fake.use_server(server)

      assert {:ok, nodes} = Kube.list_nodes()
      assert Enum.map(nodes, & &1.name) == ["node-b", "node-c"]
      assert Kube.get_lease("default", "l") == {:error, :not_found}

      assert Kube.workload_replicas("shop", "ReplicaSet", "web-7d9f8b6c5") ==
               {:ok, %{desired: 4, ready: 4}}
    end
  end

  test "the loser of a name conflict drops its cluster and re-seeds into the winner's" do
    a = start_shared(:a, seed_demo: "node-a")
    assert Fake.info(a).role == :active

    # what a netsplit heal looks like to the losing side: :global hands the name to
    # another server and notifies us
    :global.unregister_name(Fake)
    b = start_shared(:b, seed_demo: "node-b")
    assert :global.whereis_name(Fake) == b
    send(a, {:global_name_conflict, Fake})
    settle([a, b])

    assert %{role: :standby, active: ^b} = Fake.info(a)

    Fake.use_server(a)
    assert {:ok, [%Node{name: "node-a"}, %Node{name: "node-b"}]} = Kube.list_nodes()
  end

  test "shared mode reschedules evicted pods by default" do
    a = start_shared(:a, seed_demo: "node-a", reschedule_delay_ms: 0)
    Fake.use_server(a)
    Fake.put_node("node-b")

    {:ok, pods} = Kube.list_pods(namespace: "data")
    indexer = Enum.find(pods, &(&1.owner_kind == "ReplicaSet"))

    assert Kube.evict_pod("data", indexer.name) == :ok
    _ = :sys.get_state(a)

    assert {:ok, [moved]} = Kube.list_pods(node: "node-b")
    assert moved.owner_name == indexer.owner_name
    assert moved.uid != indexer.uid
  end
end
