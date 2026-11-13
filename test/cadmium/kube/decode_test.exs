defmodule Cadmium.Kube.DecodeTest do
  use ExUnit.Case, async: true

  alias Cadmium.Kube.{Decode, Lease, Node, PDB, Pod}

  doctest Cadmium.Kube.Decode

  @mi 1024 * 1024

  describe "cpu_millis/1" do
    test "parses every form the API server emits" do
      assert Decode.cpu_millis("250m") == 250
      assert Decode.cpu_millis("1") == 1_000
      assert Decode.cpu_millis("0.5") == 500
      assert Decode.cpu_millis("1.5") == 1_500
      assert Decode.cpu_millis(".1") == 100
      assert Decode.cpu_millis("2") == 2_000
      assert Decode.cpu_millis("1k") == 1_000_000
      assert Decode.cpu_millis("1e3") == 1_000_000
      assert Decode.cpu_millis("100e-3") == 100
    end

    test "rounds sub-millicore quantities up" do
      assert Decode.cpu_millis("2500u") == 3
      assert Decode.cpu_millis("1500000n") == 2
      assert Decode.cpu_millis("100000000n") == 100
      assert Decode.cpu_millis("1n") == 1
      assert Decode.cpu_millis("0.0001") == 1
    end

    test "accepts JSON numbers and tolerates junk" do
      assert Decode.cpu_millis(2) == 2_000
      assert Decode.cpu_millis(0.25) == 250
      assert Decode.cpu_millis(nil) == 0
      assert Decode.cpu_millis("") == 0
      assert Decode.cpu_millis("abc") == 0
      assert Decode.cpu_millis("1Qi") == 0
      assert Decode.cpu_millis("-1") == 0
      assert Decode.cpu_millis("0") == 0
    end
  end

  describe "memory_bytes/1" do
    test "binary suffixes" do
      assert Decode.memory_bytes("1Ki") == 1024
      assert Decode.memory_bytes("128Mi") == 128 * @mi
      assert Decode.memory_bytes("1.5Gi") == 1_610_612_736
      assert Decode.memory_bytes("2Ti") == 2 * 1024 * 1024 * @mi
      assert Decode.memory_bytes("16374452Ki") == 16_374_452 * 1024
    end

    test "decimal suffixes, plain integers and exponents" do
      assert Decode.memory_bytes("1k") == 1_000
      assert Decode.memory_bytes("129M") == 129_000_000
      assert Decode.memory_bytes("1G") == 1_000_000_000
      assert Decode.memory_bytes("1T") == 1_000_000_000_000
      assert Decode.memory_bytes("134217728") == 134_217_728
      assert Decode.memory_bytes("129e6") == 129_000_000
      assert Decode.memory_bytes("1.5e3") == 1_500
      assert Decode.memory_bytes("1E3") == 1_000
      assert Decode.memory_bytes("1E") == 1_000_000_000_000_000_000
      assert Decode.memory_bytes(4096) == 4096
    end

    test "milli-bytes round up" do
      assert Decode.memory_bytes("1500m") == 2
      assert Decode.memory_bytes("128974848000m") == 128_974_848
      assert Decode.memory_bytes("1m") == 1
    end

    test "missing is zero" do
      assert Decode.memory_bytes(nil) == 0
    end
  end

  @pod Jason.decode!(~S"""
       {
         "apiVersion": "v1",
         "kind": "Pod",
         "metadata": {
           "name": "web-7d9f8b6c5-x2x7k",
           "generateName": "web-7d9f8b6c5-",
           "namespace": "shop",
           "uid": "0b0a4d5c-58a3-4a9e-9a53-0d4d4f0f3c11",
           "resourceVersion": "184467",
           "creationTimestamp": "2026-03-04T09:12:44Z",
           "labels": {"app": "web", "pod-template-hash": "7d9f8b6c5"},
           "annotations": {"cadmium.owl-corp.io/rebalance": "false"},
           "ownerReferences": [
             {"apiVersion": "v1", "kind": "ConfigMap", "name": "decoy", "uid": "1"},
             {
               "apiVersion": "apps/v1",
               "kind": "ReplicaSet",
               "name": "web-7d9f8b6c5",
               "uid": "c7f2a1de-1c1f-4d3e-8a55-6a3f0e0e3b77",
               "controller": true,
               "blockOwnerDeletion": true
             }
           ]
         },
         "spec": {
           "nodeName": "node-a",
           "priorityClassName": "high-priority",
           "priority": 1000,
           "initContainers": [
             {
               "name": "migrate",
               "image": "shop/web:1.4",
               "resources": {"requests": {"cpu": "100m", "memory": "64Mi"}}
             }
           ],
           "containers": [
             {
               "name": "web",
               "image": "shop/web:1.4",
               "resources": {
                 "requests": {"cpu": "250m", "memory": "256Mi"},
                 "limits": {"cpu": "1", "memory": "512Mi"}
               }
             },
             {
               "name": "envoy",
               "image": "envoyproxy/envoy:v1.31",
               "resources": {
                 "requests": {"cpu": "0.1", "memory": "64Mi"},
                 "limits": {"cpu": "500m", "memory": "128Mi"}
               }
             }
           ],
           "volumes": [
             {"name": "kube-api-access-abcde", "projected": {"sources": []}},
             {"name": "config", "configMap": {"name": "web"}}
           ]
         },
         "status": {
           "phase": "Running",
           "qosClass": "Burstable",
           "podIP": "10.42.1.17",
           "conditions": [{"type": "Ready", "status": "True"}]
         }
       }
       """)

  describe "pod/1" do
    test "decodes a realistic pod" do
      assert %Pod{
               namespace: "shop",
               name: "web-7d9f8b6c5-x2x7k",
               uid: "0b0a4d5c-58a3-4a9e-9a53-0d4d4f0f3c11",
               node_name: "node-a",
               phase: "Running",
               labels: %{"app" => "web", "pod-template-hash" => "7d9f8b6c5"},
               annotations: %{"cadmium.owl-corp.io/rebalance" => "false"},
               owner_kind: "ReplicaSet",
               owner_name: "web-7d9f8b6c5",
               cpu_request_millis: 350,
               cpu_limit_millis: 1_500,
               memory_request_bytes: 335_544_320,
               memory_limit_bytes: 671_088_640,
               qos_class: "Burstable",
               priority_class: "high-priority",
               local_storage?: false,
               mirror?: false,
               deleting?: false,
               created_at: ~U[2026-03-04 09:12:44Z]
             } = Decode.pod(@pod)
    end

    test "limits are nil unless every container sets one" do
      pod =
        update_in(@pod, ["spec", "containers", Access.at(1), "resources", "limits"], fn limits ->
          Map.delete(limits, "cpu")
        end)

      assert %Pod{cpu_limit_millis: nil, memory_limit_bytes: 671_088_640} = Decode.pod(pod)

      pod = update_in(@pod, ["spec", "containers", Access.at(1)], &Map.delete(&1, "resources"))

      assert %Pod{
               cpu_limit_millis: nil,
               memory_limit_bytes: nil,
               cpu_request_millis: 250,
               memory_request_bytes: 268_435_456
             } = Decode.pod(pod)
    end

    test "a large init container raises the effective request; sidecars add to it" do
      inits = [
        %{"name" => "warm", "resources" => %{"requests" => %{"cpu" => "2", "memory" => "1Gi"}}},
        %{
          "name" => "log-shipper",
          "restartPolicy" => "Always",
          "resources" => %{"requests" => %{"cpu" => "50m", "memory" => "32Mi"}}
        }
      ]

      pod = put_in(@pod, ["spec", "initContainers"], inits)

      assert %Pod{cpu_request_millis: 2_000, memory_request_bytes: 1_073_741_824} =
               Decode.pod(pod)

      pod = put_in(@pod, ["spec", "initContainers"], [Enum.at(inits, 1)])
      assert %Pod{cpu_request_millis: 400, memory_request_bytes: 369_098_752} = Decode.pod(pod)
    end

    test "emptyDir and hostPath volumes are local storage" do
      volumes = [
        %{"name" => "scratch", "emptyDir" => %{}},
        %{"name" => "logs", "hostPath" => %{"path" => "/var/log"}}
      ]

      for volume <- volumes do
        pod = update_in(@pod, ["spec", "volumes"], &[volume | &1])
        assert Decode.pod(pod).local_storage?
      end
    end

    test "mirror, deleting and unowned pods" do
      pod =
        @pod
        |> put_in(["metadata", "annotations", "kubernetes.io/config.mirror"], "f3a9")
        |> put_in(["metadata", "deletionTimestamp"], "2026-03-04T10:00:00Z")
        |> update_in(["metadata", "ownerReferences"], &Enum.take(&1, 1))

      assert %Pod{mirror?: true, deleting?: true, owner_kind: nil, owner_name: nil} =
               Decode.pod(pod)
    end

    test "a pending pod with almost nothing set" do
      pod = %{
        "metadata" => %{"namespace" => "default", "name" => "p", "uid" => "u"},
        "spec" => %{"containers" => [%{"name" => "c"}]},
        "status" => %{"phase" => "Pending"}
      }

      assert Decode.pod(pod) == %Pod{namespace: "default", name: "p", uid: "u", phase: "Pending"}
    end
  end

  @node Jason.decode!(~S"""
        {
          "metadata": {
            "name": "node-a",
            "resourceVersion": "9912",
            "labels": {"kubernetes.io/hostname": "node-a", "topology.kubernetes.io/zone": "eu-west-1b"}
          },
          "spec": {
            "podCIDR": "10.42.1.0/24",
            "taints": [
              {"key": "dedicated", "value": "batch", "effect": "NoSchedule"},
              {"key": "node.kubernetes.io/unschedulable", "effect": "NoSchedule", "timeAdded": "2026-03-04T09:00:00Z"}
            ],
            "unschedulable": true
          },
          "status": {
            "capacity": {"cpu": "4", "memory": "16393180Ki", "pods": "110"},
            "allocatable": {"cpu": "3920m", "memory": "15250140Ki", "pods": "110"},
            "conditions": [
              {"type": "MemoryPressure", "status": "False"},
              {"type": "DiskPressure", "status": "False"},
              {"type": "Ready", "status": "True", "reason": "KubeletReady"}
            ]
          }
        }
        """)

  describe "node/1" do
    test "decodes a realistic node" do
      assert Decode.node(@node) == %Node{
               name: "node-a",
               labels: %{
                 "kubernetes.io/hostname" => "node-a",
                 "topology.kubernetes.io/zone" => "eu-west-1b"
               },
               taints: [
                 %{key: "dedicated", value: "batch", effect: "NoSchedule"},
                 %{key: "node.kubernetes.io/unschedulable", value: nil, effect: "NoSchedule"}
               ],
               unschedulable?: true,
               ready?: true,
               allocatable_cpu_millis: 3_920,
               allocatable_memory_bytes: 15_250_140 * 1024
             }
    end

    test "not ready when the Ready condition is False, Unknown or missing" do
      for status <- ["False", "Unknown"] do
        node =
          put_in(@node, ["status", "conditions"], [%{"type" => "Ready", "status" => status}])

        refute Decode.node(node).ready?
      end

      refute Decode.node(put_in(@node, ["status", "conditions"], [])).ready?

      assert %Node{name: "bare", taints: [], unschedulable?: false, ready?: false} =
               Decode.node(%{"metadata" => %{"name" => "bare"}})
    end
  end

  test "encode_taint/1 omits a nil value" do
    assert Decode.encode_taint(%{key: "k", value: nil, effect: "NoSchedule"}) ==
             %{"key" => "k", "effect" => "NoSchedule"}

    assert Decode.encode_taint(%{key: "k", value: "v", effect: "PreferNoSchedule"}) ==
             %{"key" => "k", "value" => "v", "effect" => "PreferNoSchedule"}
  end

  test "pdb/1" do
    pdb =
      Jason.decode!(~S"""
      {
        "metadata": {"name": "checkout", "namespace": "shop"},
        "spec": {
          "minAvailable": 2,
          "selector": {
            "matchLabels": {"app": "checkout"},
            "matchExpressions": [{"key": "tier", "operator": "In", "values": ["web"]}]
          }
        },
        "status": {"currentHealthy": 3, "desiredHealthy": 2, "disruptionsAllowed": 1, "expectedPods": 3}
      }
      """)

    assert Decode.pdb(pdb) == %PDB{
             namespace: "shop",
             name: "checkout",
             match_labels: %{"app" => "checkout"},
             match_expressions: [%{"key" => "tier", "operator" => "In", "values" => ["web"]}],
             disruptions_allowed: 1
           }

    assert %PDB{match_labels: %{}, match_expressions: [], disruptions_allowed: 0} =
             Decode.pdb(%{"metadata" => %{"name" => "p", "namespace" => "n"}, "spec" => %{}})
  end

  test "replicas/1" do
    assert Decode.replicas(%{"spec" => %{"replicas" => 3}, "status" => %{"readyReplicas" => 2}}) ==
             %{desired: 3, ready: 2}

    assert Decode.replicas(%{"spec" => %{"replicas" => 3}, "status" => %{"replicas" => 3}}) ==
             %{desired: 3, ready: 0}
  end

  test "items/2 and continue_token/1" do
    body = %{"metadata" => %{"continue" => "abc"}, "items" => [@node]}
    assert [%Node{name: "node-a"}] = Decode.items(body, &Decode.node/1)
    assert Decode.continue_token(body) == "abc"
    assert Decode.continue_token(%{"metadata" => %{"continue" => ""}}) == nil
    assert Decode.continue_token(%{"metadata" => %{}}) == nil
    assert Decode.items(%{"items" => nil}, &Decode.node/1) == []
  end

  describe "leases" do
    @lease Jason.decode!(~S"""
           {
             "apiVersion": "coordination.k8s.io/v1",
             "kind": "Lease",
             "metadata": {"name": "cadmium-catalyst", "namespace": "cadmium", "resourceVersion": "5512"},
             "spec": {
               "holderIdentity": "node-a",
               "acquireTime": "2026-03-04T09:12:44.000001Z",
               "renewTime": "2026-03-04T09:13:04.250000Z",
               "leaseDurationSeconds": 15,
               "leaseTransitions": 3
             }
           }
           """)

    test "lease/1" do
      assert Decode.lease(@lease) == %Lease{
               namespace: "cadmium",
               name: "cadmium-catalyst",
               holder: "node-a",
               acquire_time: ~U[2026-03-04 09:12:44.000001Z],
               renew_time: ~U[2026-03-04 09:13:04.250000Z],
               duration_seconds: 15,
               transitions: 3,
               resource_version: "5512"
             }
    end

    test "an empty lease has no holder" do
      metadata = %{"name" => "l", "namespace" => "n"}
      lease = %{"metadata" => metadata, "spec" => %{"holderIdentity" => ""}}
      assert %Lease{holder: nil, transitions: 0, renew_time: nil} = Decode.lease(lease)
      assert %Lease{holder: nil} = Decode.lease(%{"metadata" => metadata})
    end

    test "encode_lease/1 round-trips and writes MicroTime" do
      assert @lease |> Decode.lease() |> Decode.encode_lease() == @lease
    end

    test "encode_lease/1 omits nil fields and pads timestamps to microseconds" do
      lease = %Lease{
        namespace: "n",
        name: "l",
        renew_time: ~U[2026-03-04 09:13:04Z],
        duration_seconds: 1
      }

      assert Decode.encode_lease(lease) == %{
               "apiVersion" => "coordination.k8s.io/v1",
               "kind" => "Lease",
               "metadata" => %{"namespace" => "n", "name" => "l"},
               "spec" => %{
                 "renewTime" => "2026-03-04T09:13:04.000000Z",
                 "leaseDurationSeconds" => 1,
                 "leaseTransitions" => 0
               }
             }
    end

    test "micro_time/1" do
      assert Decode.micro_time(~U[2026-03-04 09:13:04.123Z]) == "2026-03-04T09:13:04.123000Z"
      assert Decode.micro_time(nil) == nil
    end
  end
end
