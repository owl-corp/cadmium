defmodule Cadmium.Isotope.Source.CgroupTest do
  use ExUnit.Case, async: true

  import Cadmium.IsotopeFixtures

  alias Cadmium.Isotope.{RingBuffer, Sampler}
  alias Cadmium.Isotope.Source.Cgroup

  doctest Cgroup

  @moduletag :tmp_dir

  @guaranteed "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b"
  @burstable "a1b2c3d4-e5f6-4789-8abc-def012345678"
  @besteffort "deadbeef-0000-4111-8222-333344445555"

  setup %{tmp_dir: tmp_dir} do
    cgroup_root = Path.join(tmp_dir, "cgroup")
    proc_root = write_proc(Path.join(tmp_dir, "proc"))
    File.mkdir_p!(cgroup_root)
    {:ok, state} = Cgroup.init(cgroup_root: cgroup_root, proc_root: proc_root)
    %{cgroup_root: cgroup_root, proc_root: proc_root, state: state}
  end

  defp build_tree(cgroup_root, driver) do
    for {qos, uid} <- [guaranteed: @guaranteed, burstable: @burstable, besteffort: @besteffort] do
      write_cgroup(pod_dir(cgroup_root, driver, qos, uid))
    end

    cgroup_root |> Cgroup.kubepods_root() |> write_cgroup()
  end

  describe "pod_uid/1" do
    test "normalises systemd-escaped UIDs to the dashed form" do
      assert Cgroup.pod_uid("kubepods-pod0f5c2a1e_7b3d_4c8e_9a51_d2e4f6a8b09b.slice") ==
               @guaranteed

      assert Cgroup.pod_uid("kubepods-besteffort-poddeadbeef_0000_4111_8222_333344445555.slice") ==
               @besteffort

      assert Cgroup.pod_uid("podDEADBEEF-0000-4111-8222-333344445555") == @besteffort
    end

    test "rejects everything that is not a pod cgroup" do
      for name <- [
            "kubepods.slice",
            "kubepods-burstable.slice",
            "burstable",
            "cri-containerd-3f1c0e7a9b.scope",
            "pod-not-a-uid",
            "pod0f5c2a1e_7b3d_4c8e_9a51.slice",
            "system.slice",
            ""
          ] do
        assert Cgroup.pod_uid(name) == nil, name
      end
    end
  end

  describe "pod discovery" do
    for driver <- [:systemd, :cgroupfs] do
      test "#{driver} driver: finds guaranteed, burstable and besteffort pods", %{
        cgroup_root: cgroup_root
      } do
        driver = unquote(driver)
        build_tree(cgroup_root, driver)

        assert Cgroup.discover_pods(cgroup_root) == %{
                 @guaranteed => pod_dir(cgroup_root, driver, :guaranteed, @guaranteed),
                 @burstable => pod_dir(cgroup_root, driver, :burstable, @burstable),
                 @besteffort => pod_dir(cgroup_root, driver, :besteffort, @besteffort)
               }
      end
    end

    test "ignores container cgroups, stray files and unrelated slices", %{cgroup_root: root} do
      build_tree(root, :systemd)
      pod = pod_dir(root, :systemd, :burstable, @burstable)

      write_cgroup(Path.join(pod, "cri-containerd-3f1c0e7a9b0d.scope"))
      write_cgroup(Path.join(root, "system.slice/docker.service"))
      File.write!(Path.join(root, "kubepods.slice/kubepods-burstable.slice/cgroup.procs"), "")

      # a pod-looking directory outside the QoS directories is not a pod
      write_cgroup(
        Path.join(root, "kubepods.slice/other.slice/pod11111111-2222-3333-4444-555555555555")
      )

      assert root |> Cgroup.discover_pods() |> Map.keys() |> Enum.sort() ==
               Enum.sort([@guaranteed, @burstable, @besteffort])
    end

    test "finds the kubelet.slice layout used by kind", %{cgroup_root: root} do
      dir =
        Path.join([
          root,
          "kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice",
          "kubelet-kubepods-burstable-pod#{String.replace(@burstable, "-", "_")}.slice"
        ])

      write_cgroup(dir)

      assert Cgroup.discover_pods(root) == %{@burstable => dir}
    end

    test "no kubepods cgroup means no pods", %{cgroup_root: root} do
      assert Cgroup.kubepods_root(root) == nil
      assert Cgroup.discover_pods(root) == %{}
      assert Cgroup.discover_pods(Path.join(root, "does-not-exist")) == %{}
    end
  end

  describe "read/1" do
    test "reads node values from /proc and the kubepods root", %{cgroup_root: root, state: state} do
      build_tree(root, :systemd)
      File.write!(Path.join(root, "io.stat"), "8:0 rbytes=100 wbytes=200 rios=1 wios=2\n")

      assert {:ok, %{node: node}, ^state} = Cgroup.read(state)

      assert node.cpu == %{busy: 1_451_363, total: 10_602_719}
      assert node.kubepods_cpu.nr_periods == 412_367
      assert node.kubepods_cpu.nr_throttled == 18_233
      assert node.psi_cpu.some.avg10 == 45.12
      assert node.psi_memory.full.avg10 == 1.25
      assert node.psi_io.some.avg10 == 7.7
      assert node.memory.mem_total_bytes == 16_303_428 * 1024
      assert node.load.load1 == 3.52
      assert node.vm.pgmajfault == 88_213
      assert node.io == %{rbytes: 100, wbytes: 200, rios: 1, wios: 2}
    end

    test "reads the pod-level cgroup of every pod", %{cgroup_root: root, state: state} do
      build_tree(root, :cgroupfs)

      write_cgroup(pod_dir(root, :cgroupfs, :burstable, @burstable), %{
        "cpu.stat" => cpu_stat(5_000_000, 200, 50),
        "memory.current" => "1048576\n"
      })

      assert {:ok, %{pods: pods}, _} = Cgroup.read(state)

      assert pods |> Map.keys() |> Enum.sort() ==
               Enum.sort([@guaranteed, @burstable, @besteffort])

      assert pods[@burstable].cpu == %{
               usage_usec: 5_000_000,
               nr_periods: 200,
               nr_throttled: 50,
               throttled_usec: 2_500_000
             }

      assert pods[@burstable].memory_current == 1_048_576

      assert pods[@guaranteed].cpu.usage_usec == 8_421_337_412
      assert pods[@guaranteed].psi_cpu.some.avg10 == 12.34
      assert pods[@guaranteed].psi_memory.some.avg10 == 0.0
      assert pods[@guaranteed].psi_io.some.avg10 == 3.07
      assert pods[@guaranteed].io.wbytes == 90_328_145_920
      assert pods[@guaranteed].memory_current == 268_435_456
      assert pods[@guaranteed].memory_stat == %{pgfault: 9_912_345, pgmajfault: 421}
    end

    test "missing and malformed files become nil fields", %{
      cgroup_root: root,
      proc_root: proc_root,
      state: state
    } do
      build_tree(root, :systemd)

      write_cgroup(pod_dir(root, :systemd, :burstable, @burstable), %{
        "cpu.pressure" => nil,
        "io.stat" => nil,
        "memory.current" => "max\n",
        "memory.stat" => "garbage\n"
      })

      write_proc(proc_root, %{"loadavg" => nil, "pressure/io" => nil, "vmstat" => "nope\n"})

      assert {:ok, %{node: node, pods: pods}, _} = Cgroup.read(state)

      assert node.load == nil
      assert node.psi_io == nil
      assert node.vm == nil
      assert node.cpu != nil

      pod = pods[@burstable]
      assert pod.psi_cpu == nil
      assert pod.io == nil
      assert pod.memory_current == nil
      assert pod.memory_stat == nil
      assert pod.cpu.usage_usec == 8_421_337_412
    end

    test "falls back to the root cgroup for PSI and to kubepods for IO", %{
      cgroup_root: root,
      proc_root: proc_root,
      state: state
    } do
      build_tree(root, :systemd)
      write_proc(proc_root, %{"pressure/cpu" => nil})
      File.write!(Path.join(root, "cpu.pressure"), "some avg10=9.00 avg60=0 avg300=0 total=1\n")

      assert {:ok, %{node: node}, _} = Cgroup.read(state)
      assert node.psi_cpu.some.avg10 == 9.0
      assert node.io.rbytes == 1_811_111_936 + 4096
    end

    test "a host without kubepods still yields node values", %{state: state} do
      assert {:ok, %{node: node, pods: pods}, _} = Cgroup.read(state)

      assert pods == %{}
      assert node.kubepods_cpu == nil
      assert node.io == nil
      assert node.cpu.total == 10_602_719
    end

    test "a pod cgroup with nothing readable in it is skipped", %{cgroup_root: root, state: state} do
      build_tree(root, :cgroupfs)
      File.mkdir_p!(pod_dir(root, :cgroupfs, :burstable, "99999999-aaaa-bbbb-cccc-000000000000"))

      assert {:ok, %{pods: pods}, _} = Cgroup.read(state)
      assert map_size(pods) == 3
    end

    test "nothing to read at all is an error, not an empty sample", %{tmp_dir: tmp_dir} do
      {:ok, state} =
        Cgroup.init(
          cgroup_root: Path.join(tmp_dir, "nope"),
          proc_root: Path.join(tmp_dir, "nada")
        )

      assert {:error, {:no_telemetry, _}, ^state} = Cgroup.read(state)
    end

    test "roots default to the application config" do
      assert {:ok, %{cgroup_root: "/sys/fs/cgroup", proc_root: "/proc"}} = Cgroup.init([])
    end
  end

  describe "through the sampler" do
    setup %{cgroup_root: cgroup_root, proc_root: proc_root} do
      table = :"cgroup_test_#{System.unique_integer([:positive])}"
      clock = :atomics.new(1, [])
      start_supervised!({RingBuffer, name: table, capacity: 10})

      sampler =
        start_supervised!(
          {Sampler,
           name: nil,
           table: table,
           source: Cgroup,
           cgroup_root: cgroup_root,
           proc_root: proc_root,
           interval_ms: :manual,
           topic: "isotope:test:#{table}",
           clock: fn -> :atomics.get(clock, 1) end}
        )

      %{table: table, sampler: sampler, clock: clock}
    end

    test "rates come from the change in the kernel counters between ticks", ctx do
      %{cgroup_root: root, proc_root: proc_root, table: table, sampler: sampler} = ctx
      build_tree(root, :systemd)
      pod = pod_dir(root, :systemd, :burstable, @burstable)
      kubepods = Cgroup.kubepods_root(root)

      write_cgroup(pod, %{"cpu.stat" => cpu_stat(1_000_000, 100, 10)})
      write_cgroup(kubepods, %{"cpu.stat" => cpu_stat(9_000_000, 1_000, 100)})
      write_proc(proc_root, %{"stat" => "cpu 100 0 100 800 0 0 0 0 0 0\n"})

      assert {:ok, first} = Sampler.tick(sampler)
      assert first.cpu_usage_ratio == nil
      assert first.psi_cpu_some == 45.12
      assert_in_delta first.memory_used_ratio, 0.6, 0.001

      # one second later: the pod used 350ms of CPU and was throttled in 8 of 10 periods
      :atomics.add(ctx.clock, 1, 1_000)
      write_cgroup(pod, %{"cpu.stat" => cpu_stat(1_350_000, 110, 18)})
      write_cgroup(kubepods, %{"cpu.stat" => cpu_stat(9_900_000, 1_040, 110)})
      write_proc(proc_root, %{"stat" => "cpu 400 0 200 1100 100 0 0 0 0 0\n"})

      assert {:ok, second} = Sampler.tick(sampler)
      assert second.cpu_usage_ratio == 0.5
      assert second.cpu_throttled_ratio == 0.25
      assert second.major_faults_per_s == 0.0

      assert [_, pod_sample] = RingBuffer.last(table, Sampler.pod_series(@burstable), 10)
      assert pod_sample.pod_uid == @burstable
      assert pod_sample.cpu_usage_millis == 350.0
      assert pod_sample.cpu_throttled_ratio == 0.8
      assert pod_sample.memory_bytes == 268_435_456
    end

    test "a pod's history goes away with its cgroup", ctx do
      %{cgroup_root: root, table: table, sampler: sampler} = ctx
      build_tree(root, :cgroupfs)

      assert {:ok, _} = Sampler.tick(sampler)
      assert RingBuffer.size(table, Sampler.pod_series(@besteffort)) == 1

      File.rm_rf!(pod_dir(root, :cgroupfs, :besteffort, @besteffort))
      assert {:ok, _} = Sampler.tick(sampler)

      assert RingBuffer.last(table, Sampler.pod_series(@besteffort), 10) == []
      assert RingBuffer.size(table, Sampler.pod_series(@guaranteed)) == 2

      assert Enum.sort(RingBuffer.series(table)) ==
               Enum.sort([:node, {:pod, @guaranteed}, {:pod, @burstable}])
    end
  end
end
