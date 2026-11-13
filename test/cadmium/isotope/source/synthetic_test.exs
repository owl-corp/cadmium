defmodule Cadmium.Isotope.Source.SyntheticTest do
  # not async: one test sets CADMIUM_SYNTHETIC_HEAT
  use ExUnit.Case, async: false

  import Cadmium.IsotopeFixtures, only: [write_cgroup: 1, write_proc: 1, pod_dir: 4]

  alias Cadmium.Demo
  alias Cadmium.Isotope.Derive
  alias Cadmium.Isotope.Source.{Cgroup, Synthetic}

  @node "node-a"
  @t0 1_800_000_000_000
  @mi 1024 * 1024

  defp init(opts \\ []) do
    {:ok, state} = Synthetic.init(Keyword.put_new(opts, :node_name, @node))
    state
  end

  # Reads once per second for `seconds` seconds and derives the samples, exactly as the
  # sampler would: [{node_sample, %{uid => pod_sample}}, ...]
  defp run(state, seconds) do
    {:ok, first, state} = Synthetic.read(state, @t0)

    {samples, _} =
      Enum.map_reduce(1..seconds, {first, state}, fn i, {prev, state} ->
        {:ok, cur, state} = Synthetic.read(state, @t0 + i * 1_000)
        node = Derive.node_sample(prev.node, cur.node, 1_000, i)

        pods =
          Map.new(cur.pods, fn {uid, raw} ->
            {uid, Derive.pod_sample(uid, prev.pods[uid], raw, 1_000, i)}
          end)

        {{node, pods}, {cur, state}}
      end)

    samples
  end

  defp pods_with(profile) do
    for pod <- Demo.pods(@node), Demo.profile(@node, pod.uid) == profile, do: pod
  end

  defp series(samples, uid, field) do
    for {_node, pods} <- samples, do: Map.fetch!(pods[uid], field)
  end

  describe "shape" do
    test "covers exactly the demo pods of the node" do
      {:ok, reading, _} = Synthetic.read(init(), @t0)

      assert reading.pods |> Map.keys() |> Enum.sort() ==
               @node |> Demo.pods() |> Enum.map(& &1.uid) |> Enum.sort()
    end

    @tag :tmp_dir
    test "is the same shape the cgroup source produces", %{tmp_dir: tmp_dir} do
      cgroup_root = Path.join(tmp_dir, "cgroup")

      write_cgroup(
        pod_dir(cgroup_root, :systemd, :burstable, "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b")
      )

      write_cgroup(Cgroup.kubepods_root(cgroup_root))
      File.write!(Path.join(cgroup_root, "io.stat"), "8:0 rbytes=1 wbytes=1 rios=1 wios=1\n")
      proc_root = write_proc(Path.join(tmp_dir, "proc"))

      {:ok, cgroup_state} = Cgroup.init(cgroup_root: cgroup_root, proc_root: proc_root)
      {:ok, real, _} = Cgroup.read(cgroup_state)
      {:ok, synthetic, _} = Synthetic.read(init(), @t0)

      assert shape(synthetic.node) == shape(real.node)

      [real_pod] = Map.values(real.pods)

      for {_uid, pod} <- synthetic.pods do
        assert shape(pod) == shape(real_pod)
      end
    end

    test "counters are integers that never go backwards" do
      state = init(base_heat: 0.8)

      {readings, _} =
        Enum.map_reduce(0..30, state, fn i, state ->
          # irregular intervals, including a repeated timestamp and a clock step backwards
          {:ok, reading, state} = Synthetic.read(state, @t0 + i * 700 - rem(i, 3) * 900)
          {reading, state}
        end)

      for [a, b] <- Enum.chunk_every(readings, 2, 1, :discard) do
        for path <- [
              [:cpu, :busy],
              [:cpu, :total],
              [:kubepods_cpu, :nr_periods],
              [:kubepods_cpu, :nr_throttled],
              [:vm, :pgmajfault],
              [:io, :rbytes],
              [:io, :wbytes]
            ] do
          assert is_integer(get_in(b.node, path))
          assert Derive.delta(a.node, b.node, path) != nil, inspect(path)
        end

        for {uid, pod} <- b.pods, path <- [[:cpu, :usage_usec], [:io, :rbytes]] do
          assert is_integer(pod.memory_current)
          assert Derive.delta(a.pods[uid], pod, path) != nil
        end
      end
    end
  end

  describe "pod profiles" do
    setup do
      %{samples: run(init(), 300)}
    end

    test ":steady pods sit around 60% of their CPU and memory request", %{samples: samples} do
      for pod <- pods_with(:steady) do
        for cpu <- series(samples, pod.uid, :cpu_usage_millis) do
          assert_in_delta cpu / pod.cpu_request_millis, 0.6, 0.1
        end

        for memory <- series(samples, pod.uid, :memory_bytes) do
          assert_in_delta memory / pod.memory_request_bytes, 0.6, 0.05
        end

        assert Enum.all?(series(samples, pod.uid, :cpu_throttled_ratio), &(&1 == 0.0))
      end
    end

    test ":bursty pods swing between 0.5x and 3x their CPU request", %{samples: samples} do
      assert pods_with(:bursty) != []

      for pod <- pods_with(:bursty) do
        ratios =
          for cpu <- series(samples, pod.uid, :cpu_usage_millis), do: cpu / pod.cpu_request_millis

        assert Enum.min(ratios) >= 0.45
        assert Enum.min(ratios) < 0.7
        assert Enum.max(ratios) > 2.7
        assert Enum.max(ratios) <= 3.05
      end
    end

    test ":throttled pods are pinned at their CPU limit and heavily throttled", %{
      samples: samples
    } do
      assert pods_with(:throttled) != []

      for pod <- pods_with(:throttled) do
        for cpu <- series(samples, pod.uid, :cpu_usage_millis) do
          assert_in_delta cpu, pod.cpu_limit_millis, 1.0
        end

        throttled = series(samples, pod.uid, :cpu_throttled_ratio)
        assert Enum.sum(throttled) / length(throttled) > 0.7
        assert Enum.all?(series(samples, pod.uid, :psi_cpu_some), &(&1 > 30.0))
      end
    end

    test ":leaky pods creep up to ~2.5x their memory request, then reset", %{samples: samples} do
      assert pods_with(:leaky) != []

      for pod <- pods_with(:leaky) do
        ratios =
          for m <- series(samples, pod.uid, :memory_bytes), do: m / pod.memory_request_bytes

        assert Enum.max(ratios) > 2.4
        assert Enum.max(ratios) <= 2.5
        assert Enum.min(ratios) < 0.7

        steps = for [a, b] <- Enum.chunk_every(ratios, 2, 1, :discard), do: b - a
        {resets, creeps} = Enum.split_with(steps, &(&1 < 0))

        # one or two sharp drops in 300s of a 240s cycle; otherwise it only ever grows
        assert length(resets) in 1..2
        assert Enum.all?(resets, &(&1 < -1.5))
        assert Enum.all?(creeps, &(&1 > 0 and &1 < 0.02))
      end
    end
  end

  describe "node heat" do
    test "a hot node is clearly under pressure" do
      for {node, _pods} <- run(init(base_heat: 0.9), 60) do
        assert node.cpu_usage_ratio > 0.7
        assert node.cpu_throttled_ratio > 0.3
        assert node.psi_cpu_some > 30.0
        assert node.psi_memory_some > 5.0
        assert node.memory_used_ratio > 0.7
        assert node.load1 > 8.0
      end
    end

    test "a cool node is clearly calm" do
      for {node, _pods} <- run(init(base_heat: 0.15), 60) do
        assert node.cpu_usage_ratio < 0.4
        assert node.cpu_throttled_ratio < 0.05
        assert node.psi_cpu_some == 0.0
        assert node.psi_memory_some == 0.0
        assert node.memory_used_ratio < 0.5
      end
    end

    test "drifts slowly around the base and stays within 0.0..1.0" do
      state = init(base_heat: 0.5)
      heats = for s <- 0..180, do: Synthetic.heat(state, @t0 + s * 1_000)

      assert Enum.max(heats) > 0.6
      assert Enum.min(heats) < 0.4
      assert_in_delta Enum.sum(heats) / length(heats), 0.5, 0.01

      for [a, b] <- Enum.chunk_every(heats, 2, 1, :discard) do
        assert abs(b - a) < 0.01
      end

      for base <- [0.0, 1.0], s <- 0..180//10 do
        heat = Synthetic.heat(init(base_heat: base), @t0 + s * 1_000, 0.03)
        assert heat >= 0.0 and heat <= 1.0
      end
    end

    test "the base heat is a stable function of the node name" do
      assert Synthetic.base_heat("node-a") == Synthetic.base_heat("node-a")
      assert init(node_name: "node-b").base_heat == Synthetic.base_heat("node-b")

      for name <- ["node-a", "ip-10-0-3-17.ec2.internal", "", "x"] do
        assert Synthetic.base_heat(name) >= 0.15
        assert Synthetic.base_heat(name) <= 0.90
      end
    end

    test "three local nodes include a clearly hot and a clearly cool one" do
      for trio <- [~w(node-a node-b node-c), ~w(node-1 node-2 node-3), ~w(a b c)] do
        heats = Enum.map(trio, &Synthetic.base_heat/1)

        assert Enum.max(heats) >= 0.75, inspect(trio)
        assert Enum.min(heats) <= 0.30, inspect(trio)
      end
    end

    test "is deterministic for a given node and clock" do
      assert run(init(), 20) == run(init(), 20)
      refute run(init(), 20) == run(init(node_name: "node-b"), 20)
    end

    test "CADMIUM_SYNTHETIC_HEAT overrides the base heat" do
      previous = System.get_env("CADMIUM_SYNTHETIC_HEAT")

      on_exit(fn ->
        if previous,
          do: System.put_env("CADMIUM_SYNTHETIC_HEAT", previous),
          else: System.delete_env("CADMIUM_SYNTHETIC_HEAT")
      end)

      System.put_env("CADMIUM_SYNTHETIC_HEAT", "0.85")
      assert init().base_heat == 0.85

      System.put_env("CADMIUM_SYNTHETIC_HEAT", "1")
      assert init().base_heat == 1.0

      System.put_env("CADMIUM_SYNTHETIC_HEAT", "7.5")
      assert init().base_heat == 1.0

      System.put_env("CADMIUM_SYNTHETIC_HEAT", "hot")
      assert init().base_heat == Synthetic.base_heat(@node)

      # an explicit option wins over the environment
      System.put_env("CADMIUM_SYNTHETIC_HEAT", "0.85")
      assert init(base_heat: 0.2).base_heat == 0.2

      System.delete_env("CADMIUM_SYNTHETIC_HEAT")
      assert init().base_heat == Synthetic.base_heat(@node)
    end
  end

  test "read/1 uses the injected clock" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, @t0)
    state = init(clock: fn -> :atomics.get(clock, 1) end)

    {:ok, first, state} = Synthetic.read(state)
    :atomics.add(clock, 1, 1_000)
    {:ok, second, _state} = Synthetic.read(state)

    # 8 synthetic cores at USER_HZ=100
    assert first.node.cpu.total == 0
    assert second.node.cpu.total == 800
    assert second.node.memory.mem_total_bytes == 16 * 1024 * @mi
  end

  # Keys only, recursively: the values differ, the structure must not.
  defp shape(%{} = map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape(_), do: :value
end
