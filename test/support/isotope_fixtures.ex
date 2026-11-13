defmodule Cadmium.IsotopeFixtures do
  @moduledoc """
  Test helpers for Isotope: kernel file fixtures (`test/fixtures/isotope`), fake cgroup
  and proc trees built from them, and raw readings in the `Cadmium.Isotope.Source` shape.
  """

  @fixtures Path.expand("../fixtures/isotope", __DIR__)
  @cgroup_files ~w(cpu.stat cpu.pressure memory.pressure io.pressure io.stat memory.current memory.stat)
  @proc_files ~w(stat meminfo loadavg vmstat pressure/cpu pressure/memory pressure/io)

  @doc "Contents of a fixture file, e.g. `fixture(\"cgroup/cpu.stat\")`."
  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  @doc """
  Writes a cgroup directory populated from the fixtures. `overrides` maps a file name to
  replacement content, or to nil to leave that file out.
  """
  def write_cgroup(dir, overrides \\ %{}) do
    File.mkdir_p!(dir)

    for name <- @cgroup_files do
      case Map.get(overrides, name, fixture("cgroup/#{name}")) do
        nil -> File.rm(Path.join(dir, name))
        content -> File.write!(Path.join(dir, name), content)
      end
    end

    dir
  end

  @doc "Writes a fake procfs populated from the fixtures (same `overrides` as `write_cgroup/2`)."
  def write_proc(dir, overrides \\ %{}) do
    for name <- @proc_files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))

      case Map.get(overrides, name, fixture("proc/#{name}")) do
        nil -> File.rm(path)
        content -> File.write!(path, content)
      end
    end

    dir
  end

  @doc "Directory of a pod cgroup under `cgroup_root` for the given driver and QoS class."
  def pod_dir(cgroup_root, :systemd, qos, uid) do
    escaped = String.replace(uid, "-", "_")

    case qos do
      :guaranteed ->
        Path.join([cgroup_root, "kubepods.slice", "kubepods-pod#{escaped}.slice"])

      qos ->
        Path.join([
          cgroup_root,
          "kubepods.slice",
          "kubepods-#{qos}.slice",
          "kubepods-#{qos}-pod#{escaped}.slice"
        ])
    end
  end

  def pod_dir(cgroup_root, :cgroupfs, :guaranteed, uid),
    do: Path.join([cgroup_root, "kubepods", "pod#{uid}"])

  def pod_dir(cgroup_root, :cgroupfs, qos, uid),
    do: Path.join([cgroup_root, "kubepods", "#{qos}", "pod#{uid}"])

  @doc "A `cpu.stat` body."
  def cpu_stat(usage_usec, nr_periods, nr_throttled) do
    """
    usage_usec #{usage_usec}
    user_usec #{div(usage_usec, 2)}
    system_usec #{div(usage_usec, 2)}
    nr_periods #{nr_periods}
    nr_throttled #{nr_throttled}
    throttled_usec #{nr_throttled * 50_000}
    """
  end

  @doc "A raw node reading with every field present; `overrides` replaces top-level keys."
  def node_raw(overrides \\ %{}) do
    Map.merge(
      %{
        cpu: %{busy: 1_000, total: 10_000},
        kubepods_cpu: %{usage_usec: 0, nr_periods: 100, nr_throttled: 10, throttled_usec: 0},
        psi_cpu: psi(12.5, 0.0),
        psi_memory: psi(2.5, 1.25),
        psi_io: psi(7.0, 5.0),
        memory: %{mem_total_bytes: 1_000, mem_available_bytes: 400},
        load: %{load1: 1.5, load5: 1.0, load15: 0.5},
        vm: %{pgmajfault: 100, pgfault: 1_000},
        io: %{rbytes: 1_000, wbytes: 2_000, rios: 1, wios: 2}
      },
      overrides
    )
  end

  @doc "A raw pod reading with every field present; `overrides` replaces top-level keys."
  def pod_raw(overrides \\ %{}) do
    Map.merge(
      %{
        cpu: %{usage_usec: 1_000_000, nr_periods: 100, nr_throttled: 10, throttled_usec: 0},
        psi_cpu: psi(20.0, 1.0),
        psi_memory: psi(0.5, 0.0),
        psi_io: psi(3.0, 2.0),
        io: %{rbytes: 1_000, wbytes: 2_000, rios: 1, wios: 2},
        memory_current: 64_000_000,
        memory_stat: %{pgmajfault: 10, pgfault: 100}
      },
      overrides
    )
  end

  @doc "A parsed PSI file with the given `some` / `full` avg10."
  def psi(some, full) do
    line = fn avg10 -> %{avg10: avg10, avg60: avg10, avg300: avg10, total: 0} end
    %{some: line.(some), full: line.(full)}
  end
end
