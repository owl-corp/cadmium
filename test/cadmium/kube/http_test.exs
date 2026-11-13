defmodule Cadmium.Kube.HTTPTest do
  # The client reads its configuration from the application env.
  use ExUnit.Case, async: false

  alias Cadmium.Kube.{HTTP, Lease, Node, PDB, Pod}

  @stub __MODULE__

  setup do
    configure(token: "t0ken")
    on_exit(fn -> Application.delete_env(:cadmium, HTTP) end)
  end

  defp configure(overrides) do
    config =
      Keyword.merge(
        [base_url: "https://kube.test:6443", req_options: [plug: {Req.Test, @stub}]],
        overrides
      )

    Application.put_env(:cadmium, HTTP, config)
  end

  # Replies come from `handler`; every request is reported to the test process.
  defp stub(handler) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(test, {:request, conn.method, conn.request_path, conn.query_params, body, conn})
      handler.(conn, body)
    end)
  end

  defp json(conn, status \\ 200, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp status(conn, code, message) do
    json(conn, code, %{
      "kind" => "Status",
      "status" => "Failure",
      "message" => message,
      "code" => code
    })
  end

  defp pod_json(namespace, name, node \\ "node-a") do
    %{
      "metadata" => %{"namespace" => namespace, "name" => name, "uid" => "uid-" <> name},
      "spec" => %{
        "nodeName" => node,
        "containers" => [
          %{"name" => "c", "resources" => %{"requests" => %{"cpu" => "250m", "memory" => "64Mi"}}}
        ]
      },
      "status" => %{"phase" => "Running"}
    }
  end

  describe "requests" do
    test "send the bearer token and accept JSON" do
      stub(fn conn, _body -> json(conn, %{"items" => []}) end)

      assert HTTP.list_nodes() == {:ok, []}
      assert_received {:request, "GET", "/api/v1/nodes", _params, nil, conn}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0ken"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
      assert conn.host == "kube.test"
      assert conn.port == 6443
    end

    @tag :tmp_dir
    test "re-read the token file on every request", %{tmp_dir: dir} do
      path = Path.join(dir, "token")
      configure(token_path: path)
      stub(fn conn, _body -> json(conn, %{"items" => []}) end)

      File.write!(path, "first\n")
      assert {:ok, []} = HTTP.list_nodes()
      assert_received {:request, "GET", _path, _params, nil, conn}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer first"]

      File.write!(path, "rotated\n")
      assert {:ok, []} = HTTP.list_nodes()
      assert_received {:request, "GET", _path, _params, nil, conn}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated"]
    end

    @tag :tmp_dir
    test "fail cleanly when the token file is missing", %{tmp_dir: dir} do
      configure(token_path: Path.join(dir, "missing"))
      assert HTTP.list_nodes() == {:error, {:service_account_token, :enoent}}
    end

    test "decode JSON bodies sent without a content type" do
      stub(fn conn, _body -> Plug.Conn.send_resp(conn, 200, ~s({"items": []})) end)
      assert HTTP.list_pdbs() == {:ok, []}
    end

    test "map other statuses to {:http, status, message}" do
      stub(fn conn, _body -> status(conn, 403, "nodes is forbidden") end)
      assert HTTP.list_nodes() == {:error, {:http, 403, "nodes is forbidden"}}

      stub(fn conn, _body -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)
      assert HTTP.get_lease("default", "l") == {:error, {:http, 502, "bad gateway"}}
    end

    test "return transport errors" do
      stub(fn conn, _body -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               HTTP.get_lease("default", "l")

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               HTTP.evict_pod("shop", "web-1")
    end
  end

  describe "in_cluster_url/2" do
    test "builds the API server URL, bracketing IPv6 hosts" do
      assert HTTP.in_cluster_url("10.96.0.1", "443") == {:ok, "https://10.96.0.1:443"}
      assert HTTP.in_cluster_url("fd00:10:96::1", "443") == {:ok, "https://[fd00:10:96::1]:443"}
      assert HTTP.in_cluster_url("[fd00::1]", "6443") == {:ok, "https://[fd00::1]:6443"}

      assert HTTP.in_cluster_url("kubernetes.default.svc", "443") ==
               {:ok, "https://kubernetes.default.svc:443"}
    end

    test "is an error outside a cluster" do
      assert HTTP.in_cluster_url(nil, "443") == {:error, :not_in_cluster}
      assert HTTP.in_cluster_url("", "443") == {:error, :not_in_cluster}
    end
  end

  describe "list_pods/1" do
    test "decodes pods from all namespaces" do
      stub(fn conn, _body ->
        json(conn, %{"metadata" => %{}, "items" => [pod_json("shop", "web-1")]})
      end)

      assert {:ok, [%Pod{} = pod]} = HTTP.list_pods()
      assert pod.namespace == "shop"
      assert pod.name == "web-1"
      assert pod.node_name == "node-a"
      assert pod.cpu_request_millis == 250
      assert pod.memory_request_bytes == 64 * 1024 * 1024

      assert_received {:request, "GET", "/api/v1/pods", %{"limit" => "500"} = params, nil, _conn}
      refute Map.has_key?(params, "fieldSelector")
      refute Map.has_key?(params, "continue")
    end

    test ":node becomes a field selector and :namespace scopes the path" do
      stub(fn conn, _body -> json(conn, %{"items" => []}) end)

      assert {:ok, []} = HTTP.list_pods(node: "node-a", namespace: "shop")

      assert_received {:request, "GET", "/api/v1/namespaces/shop/pods",
                       %{"fieldSelector" => "spec.nodeName=node-a"}, nil, _conn}
    end

    test "follows continue tokens" do
      configure(token: "t0ken", page_limit: 2)

      stub(fn conn, _body ->
        case conn.query_params do
          %{"continue" => "page-2"} ->
            json(conn, %{
              "metadata" => %{"continue" => "page-3"},
              "items" => [pod_json("a", "p3")]
            })

          %{"continue" => "page-3"} ->
            json(conn, %{"metadata" => %{"continue" => ""}, "items" => [pod_json("a", "p4")]})

          _first ->
            json(conn, %{
              "metadata" => %{"continue" => "page-2"},
              "items" => [pod_json("a", "p1"), pod_json("a", "p2")]
            })
        end
      end)

      assert {:ok, pods} = HTTP.list_pods(node: "node-a")
      assert Enum.map(pods, & &1.name) == ["p1", "p2", "p3", "p4"]

      selector = "spec.nodeName=node-a"

      assert_received {:request, "GET", _path, first, nil, _conn}
      assert first == %{"limit" => "2", "fieldSelector" => selector}
      assert_received {:request, "GET", _path, second, nil, _conn}
      assert second == %{"limit" => "2", "fieldSelector" => selector, "continue" => "page-2"}
      assert_received {:request, "GET", _path, third, nil, _conn}
      assert third == %{"limit" => "2", "fieldSelector" => selector, "continue" => "page-3"}
      refute_received {:request, _method, _path, _params, _body, _conn}
    end

    test "an error on a later page fails the whole list" do
      configure(token: "t0ken", req_options: [plug: {Req.Test, @stub}, retry: false])

      stub(fn conn, _body ->
        case conn.query_params do
          %{"continue" => _token} -> status(conn, 410, "continue token expired")
          _first -> json(conn, %{"metadata" => %{"continue" => "x"}, "items" => []})
        end
      end)

      assert HTTP.list_pods() == {:error, {:http, 410, "continue token expired"}}
    end

    test "retries a transient failure" do
      configure(token: "t0ken", req_options: [plug: {Req.Test, @stub}, retry_delay: 0])
      counter = :counters.new(1, [])

      stub(fn conn, _body ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: status(conn, 503, "etcd leader changed"),
          else: json(conn, %{"items" => []})
      end)

      assert ExUnit.CaptureLog.capture_log(fn -> assert HTTP.list_nodes() == {:ok, []} end) =~
               "retry"

      assert :counters.get(counter, 1) == 2
    end
  end

  test "list_nodes/0" do
    stub(fn conn, _body ->
      json(conn, %{
        "items" => [
          %{
            "metadata" => %{"name" => "node-a", "labels" => %{"zone" => "a"}},
            "spec" => %{"taints" => [%{"key" => "k", "effect" => "NoSchedule"}]},
            "status" => %{
              "allocatable" => %{"cpu" => "3920m", "memory" => "8Gi"},
              "conditions" => [%{"type" => "Ready", "status" => "True"}]
            }
          },
          %{"metadata" => %{"name" => "node-b"}, "status" => %{"conditions" => []}}
        ]
      })
    end)

    assert {:ok, [%Node{} = a, %Node{} = b]} = HTTP.list_nodes()

    assert a == %Node{
             name: "node-a",
             labels: %{"zone" => "a"},
             taints: [%{key: "k", value: nil, effect: "NoSchedule"}],
             ready?: true,
             allocatable_cpu_millis: 3_920,
             allocatable_memory_bytes: 8 * 1024 * 1024 * 1024
           }

    assert %Node{name: "node-b", ready?: false, taints: []} = b
    assert_received {:request, "GET", "/api/v1/nodes", %{"limit" => "500"}, nil, _conn}
  end

  test "list_pdbs/0 uses policy/v1 across namespaces" do
    stub(fn conn, _body ->
      json(conn, %{
        "items" => [
          %{
            "metadata" => %{"namespace" => "shop", "name" => "checkout"},
            "spec" => %{"selector" => %{"matchLabels" => %{"app" => "checkout"}}},
            "status" => %{"disruptionsAllowed" => 0}
          }
        ]
      })
    end)

    assert HTTP.list_pdbs() ==
             {:ok,
              [
                %PDB{
                  namespace: "shop",
                  name: "checkout",
                  match_labels: %{"app" => "checkout"},
                  disruptions_allowed: 0
                }
              ]}

    assert_received {:request, "GET", "/apis/policy/v1/poddisruptionbudgets", _params, nil, _conn}
  end

  describe "workload_replicas/3" do
    test "reads spec.replicas and status.readyReplicas of each supported kind" do
      stub(fn conn, _body ->
        json(conn, %{"spec" => %{"replicas" => 3}, "status" => %{"readyReplicas" => 2}})
      end)

      for {kind, path} <- [
            {"ReplicaSet", "/apis/apps/v1/namespaces/shop/replicasets/web"},
            {"StatefulSet", "/apis/apps/v1/namespaces/shop/statefulsets/web"},
            {"Deployment", "/apis/apps/v1/namespaces/shop/deployments/web"},
            {"ReplicationController", "/api/v1/namespaces/shop/replicationcontrollers/web"}
          ] do
        assert HTTP.workload_replicas("shop", kind, "web") == {:ok, %{desired: 3, ready: 2}}
        assert_received {:request, "GET", ^path, _params, nil, _conn}
      end
    end

    test "ready defaults to zero" do
      stub(fn conn, _body -> json(conn, %{"spec" => %{"replicas" => 2}, "status" => %{}}) end)
      assert HTTP.workload_replicas("shop", "ReplicaSet", "web") == {:ok, %{desired: 2, ready: 0}}
    end

    test "unsupported kinds do not hit the API" do
      stub(fn _conn, _body -> flunk("unexpected request") end)

      assert HTTP.workload_replicas("batch", "Job", "report") == {:error, :unsupported_kind}

      assert HTTP.workload_replicas("kube-system", "DaemonSet", "p") ==
               {:error, :unsupported_kind}
    end

    test "404 is :not_found" do
      stub(fn conn, _body -> status(conn, 404, ~s(replicasets.apps "web" not found)) end)
      assert HTTP.workload_replicas("shop", "ReplicaSet", "web") == {:error, :not_found}
    end
  end

  describe "evict_pod/3" do
    test "posts a policy/v1 Eviction" do
      stub(fn conn, _body -> status(conn, 201, "") end)

      assert HTTP.evict_pod("shop", "web-1") == :ok

      assert_received {:request, "POST", "/api/v1/namespaces/shop/pods/web-1/eviction", _params,
                       body, conn}

      assert body == %{
               "apiVersion" => "policy/v1",
               "kind" => "Eviction",
               "metadata" => %{"namespace" => "shop", "name" => "web-1"}
             }

      assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")
    end

    test "dry_run sends deleteOptions.dryRun" do
      stub(fn conn, _body -> status(conn, 201, "") end)

      assert HTTP.evict_pod("shop", "web-1", dry_run: true) == :ok
      assert_received {:request, "POST", _path, _params, body, _conn}
      assert body["deleteOptions"] == %{"dryRun" => ["All"]}
    end

    test "429 is :pdb_blocked, 404 is :not_found, and nothing is retried" do
      counter = :counters.new(1, [])

      stub(fn conn, _body ->
        :counters.add(counter, 1, 1)
        status(conn, 429, "Cannot evict pod as it would violate the pod's disruption budget.")
      end)

      assert HTTP.evict_pod("shop", "web-1") == {:error, :pdb_blocked}
      assert :counters.get(counter, 1) == 1

      stub(fn conn, _body -> status(conn, 404, "not found") end)
      assert HTTP.evict_pod("shop", "web-1") == {:error, :not_found}

      stub(fn conn, _body -> status(conn, 500, "boom") end)
      assert HTTP.evict_pod("shop", "web-1") == {:error, {:http, 500, "boom"}}
    end
  end

  describe "node taints" do
    @hot %{key: "cadmium.owl-corp.io/hot", value: "true", effect: "PreferNoSchedule"}
    @hot_json %{
      "key" => "cadmium.owl-corp.io/hot",
      "value" => "true",
      "effect" => "PreferNoSchedule"
    }
    @other %{"key" => "dedicated", "value" => "batch", "effect" => "NoSchedule"}

    defp node_json(taints, version \\ "41") do
      spec = if taints, do: %{"taints" => taints}, else: %{}
      %{"metadata" => %{"name" => "node-a", "resourceVersion" => version}, "spec" => spec}
    end

    defp taint_stub(taints) do
      stub(fn conn, _body ->
        case conn.method do
          "GET" -> json(conn, node_json(taints))
          "PATCH" -> json(conn, node_json([]))
        end
      end)
    end

    test "add appends to the existing taints, guarded by a test op" do
      taint_stub([@other])

      assert HTTP.add_node_taint("node-a", @hot) == :ok

      assert_received {:request, "GET", "/api/v1/nodes/node-a", _params, nil, _conn}
      assert_received {:request, "PATCH", "/api/v1/nodes/node-a", _params, patch, conn}

      assert patch == [
               %{"op" => "test", "path" => "/spec/taints", "value" => [@other]},
               %{"op" => "add", "path" => "/spec/taints", "value" => [@other, @hot_json]}
             ]

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json-patch+json"]
    end

    test "add on a node without taints is guarded by its resourceVersion" do
      taint_stub(nil)

      assert HTTP.add_node_taint("node-a", %{key: "k", value: nil, effect: "NoSchedule"}) == :ok
      assert_received {:request, "PATCH", _path, _params, patch, _conn}

      assert patch == [
               %{"op" => "test", "path" => "/metadata/resourceVersion", "value" => "41"},
               %{
                 "op" => "add",
                 "path" => "/spec/taints",
                 "value" => [%{"key" => "k", "effect" => "NoSchedule"}]
               }
             ]
    end

    test "add replaces a taint with the same key" do
      stale =
        %{@hot_json | "effect" => "NoSchedule"} |> Map.put("timeAdded", "2026-01-01T00:00:00Z")

      taint_stub([stale, @other])

      assert HTTP.add_node_taint("node-a", @hot) == :ok
      assert_received {:request, "PATCH", _path, _params, [test, add], _conn}
      assert test["value"] == [stale, @other]
      assert add["value"] == [@other, @hot_json]
    end

    test "add is a no-op when the taint is already there" do
      taint_stub([@hot_json])

      assert HTTP.add_node_taint("node-a", @hot) == :ok
      assert_received {:request, "GET", _path, _params, nil, _conn}
      refute_received {:request, "PATCH", _path, _params, _body, _conn}
    end

    test "remove drops every taint with the key" do
      taint_stub([@hot_json, @other])

      assert HTTP.remove_node_taint("node-a", "cadmium.owl-corp.io/hot") == :ok
      assert_received {:request, "PATCH", _path, _params, patch, _conn}

      assert patch == [
               %{"op" => "test", "path" => "/spec/taints", "value" => [@hot_json, @other]},
               %{"op" => "add", "path" => "/spec/taints", "value" => [@other]}
             ]
    end

    test "remove is idempotent" do
      taint_stub([@other])
      assert HTTP.remove_node_taint("node-a", "cadmium.owl-corp.io/hot") == :ok
      refute_received {:request, "PATCH", _path, _params, _body, _conn}

      taint_stub(nil)
      assert HTTP.remove_node_taint("node-a", "cadmium.owl-corp.io/hot") == :ok
      refute_received {:request, "PATCH", _path, _params, _body, _conn}
    end

    test "re-reads and retries when someone else changed the taints in between" do
      for conflict <- [409, 422] do
        counter = :counters.new(1, [])

        # the first read misses a taint that a concurrent writer adds before our patch
        stub(fn conn, _body ->
          :counters.add(counter, 1, 1)

          case {conn.method, :counters.get(counter, 1)} do
            {"GET", 1} -> json(conn, node_json([]))
            {"PATCH", 2} -> status(conn, conflict, "the server rejected our request")
            {"GET", 3} -> json(conn, node_json([@other], "42"))
            {"PATCH", 4} -> json(conn, node_json([@other, @hot_json], "43"))
          end
        end)

        assert HTTP.add_node_taint("node-a", @hot) == :ok

        assert_received {:request, "PATCH", _path, _params, [first_test, _add], _conn}
        assert first_test["value"] == []
        assert_received {:request, "PATCH", _path, _params, [second_test, add], _conn}
        assert second_test["value"] == [@other]
        assert add["value"] == [@other, @hot_json]
      end
    end

    test "gives up after a few conflicts" do
      counter = :counters.new(1, [])

      stub(fn conn, _body ->
        case conn.method do
          "GET" ->
            json(conn, node_json([]))

          "PATCH" ->
            :counters.add(counter, 1, 1)
            status(conn, 409, "conflict")
        end
      end)

      assert HTTP.add_node_taint("node-a", @hot) == {:error, :conflict}
      assert :counters.get(counter, 1) == 4
    end

    test "an unknown node is :not_found" do
      stub(fn conn, _body -> status(conn, 404, ~s(nodes "node-x" not found)) end)

      assert HTTP.add_node_taint("node-x", @hot) == {:error, :not_found}
      assert HTTP.remove_node_taint("node-x", "k") == {:error, :not_found}
    end
  end

  describe "leases" do
    @path "/apis/coordination.k8s.io/v1/namespaces/cadmium/leases"
    @lease %Lease{
      namespace: "cadmium",
      name: "cadmium-catalyst",
      holder: "node-a",
      acquire_time: ~U[2026-03-04 09:12:44.000001Z],
      renew_time: ~U[2026-03-04 09:13:04.250000Z],
      duration_seconds: 15,
      transitions: 2,
      resource_version: "77"
    }
    @spec_json %{
      "holderIdentity" => "node-a",
      "acquireTime" => "2026-03-04T09:12:44.000001Z",
      "renewTime" => "2026-03-04T09:13:04.250000Z",
      "leaseDurationSeconds" => 15,
      "leaseTransitions" => 2
    }

    defp lease_json(version) do
      %{
        "apiVersion" => "coordination.k8s.io/v1",
        "kind" => "Lease",
        "metadata" => %{
          "namespace" => "cadmium",
          "name" => "cadmium-catalyst",
          "resourceVersion" => version
        },
        "spec" => @spec_json
      }
    end

    test "get_lease/2" do
      stub(fn conn, _body -> json(conn, lease_json("77")) end)

      assert HTTP.get_lease("cadmium", "cadmium-catalyst") == {:ok, @lease}
      assert_received {:request, "GET", @path <> "/cadmium-catalyst", _params, nil, _conn}

      stub(fn conn, _body -> status(conn, 404, "not found") end)
      assert HTTP.get_lease("cadmium", "cadmium-catalyst") == {:error, :not_found}
    end

    test "create_lease/1 posts to the collection without a resourceVersion" do
      stub(fn conn, _body -> json(conn, 201, lease_json("1")) end)

      assert HTTP.create_lease(@lease) == {:ok, %{@lease | resource_version: "1"}}
      assert_received {:request, "POST", @path, _params, body, _conn}
      assert body["spec"] == @spec_json
      assert body["metadata"] == %{"namespace" => "cadmium", "name" => "cadmium-catalyst"}
      assert body["kind"] == "Lease"

      stub(fn conn, _body -> status(conn, 409, "already exists") end)
      assert HTTP.create_lease(@lease) == {:error, :conflict}
    end

    test "update_lease/1 puts the lease guarded by its resourceVersion" do
      stub(fn conn, _body -> json(conn, lease_json("78")) end)

      assert HTTP.update_lease(@lease) == {:ok, %{@lease | resource_version: "78"}}
      assert_received {:request, "PUT", @path <> "/cadmium-catalyst", _params, body, _conn}
      assert body == lease_json("77")

      stub(fn conn, _body -> status(conn, 409, "the object has been modified") end)
      assert HTTP.update_lease(@lease) == {:error, :conflict}

      stub(fn conn, _body -> status(conn, 404, "not found") end)
      assert HTTP.update_lease(@lease) == {:error, :not_found}
    end

    test "a released lease is written without a holder" do
      stub(fn conn, _body -> json(conn, put_in(lease_json("79"), ["spec"], %{})) end)

      assert {:ok, %Lease{holder: nil, resource_version: "79"}} =
               HTTP.update_lease(%{@lease | holder: nil})

      assert_received {:request, "PUT", _path, _params, body, _conn}
      refute Map.has_key?(body["spec"], "holderIdentity")
    end

    test "lease calls are not retried" do
      counter = :counters.new(1, [])

      stub(fn conn, _body ->
        :counters.add(counter, 1, 1)
        status(conn, 503, "unavailable")
      end)

      assert HTTP.get_lease("cadmium", "cadmium-catalyst") ==
               {:error, {:http, 503, "unavailable"}}

      assert :counters.get(counter, 1) == 1
    end
  end
end
