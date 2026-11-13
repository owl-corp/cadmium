defmodule Cadmium.Isotope.Source.Cgroup do
  @moduledoc """
  Reads raw telemetry from cgroups v2 and /proc.

  Options (defaulting to `config :cadmium, Cadmium.Isotope`):

    * `:cgroup_root` - the cgroup2 mount (`/sys/fs/cgroup`; a hostPath mount in the DaemonSet)
    * `:proc_root` - the host's procfs (`/proc`; likewise)

  Pod cgroups are discovered under the kubepods root for both kubelet cgroup drivers:

      systemd   kubepods.slice/kubepods-pod<uid>.slice                               (guaranteed)
                kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice
                kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod<uid>.slice
      cgroupfs  kubepods/pod<uid>, kubepods/burstable/pod<uid>, kubepods/besteffort/pod<uid>

  (plus the `kubelet.slice/kubelet-kubepods.slice` / `kubelet/kubepods` layouts used by
  kind). The systemd driver writes the UID with underscores; UIDs are always returned in
  the dashed form. Only the pod-level cgroup is read, never the per-container ones.

  Node CPU, memory, load and faults come from /proc; PSI from `/proc/pressure` (falling
  back to the root cgroup's `*.pressure`); throttling from the kubepods root `cpu.stat`;
  IO from the root cgroup's `io.stat` (falling back to the kubepods root on kernels whose
  root cgroup has none, in which case it covers pod IO only).
  """

  @behaviour Cadmium.Isotope.Source

  alias Cadmium.Isotope.Parser

  @kubepods_roots [
    "kubepods.slice",
    "kubepods",
    "kubelet.slice/kubelet-kubepods.slice",
    "kubelet/kubepods"
  ]

  @hex "[0-9a-fA-F]"
  @uid "#{@hex}{8}[-_]#{@hex}{4}[-_]#{@hex}{4}[-_]#{@hex}{4}[-_]#{@hex}{12}"

  @impl true
  def init(opts) do
    config = Application.get_env(:cadmium, Cadmium.Isotope, [])

    {:ok,
     %{
       cgroup_root: opts[:cgroup_root] || config[:cgroup_root] || "/sys/fs/cgroup",
       proc_root: opts[:proc_root] || config[:proc_root] || "/proc"
     }}
  end

  @impl true
  def read(%{cgroup_root: cgroup_root, proc_root: proc_root} = state) do
    kubepods = kubepods_root(cgroup_root)
    node = read_node(cgroup_root, proc_root, kubepods)

    pods =
      for {uid, path} <- pods_under(kubepods),
          raw = read_cgroup(path),
          not all_nil?(raw),
          into: %{},
          do: {uid, raw}

    if all_nil?(node) and pods == %{} do
      {:error, {:no_telemetry, cgroup_root: cgroup_root, proc_root: proc_root}, state}
    else
      {:ok, %{node: node, pods: pods}, state}
    end
  end

  @doc "The kubepods root cgroup directory under `cgroup_root`, or nil if there is none."
  @spec kubepods_root(Path.t()) :: Path.t() | nil
  def kubepods_root(cgroup_root) do
    Enum.find_value(@kubepods_roots, fn rel ->
      path = Path.join(cgroup_root, rel)
      if File.dir?(path), do: path
    end)
  end

  @doc "Pod-level cgroup directories under `cgroup_root`, keyed by dashed pod UID."
  @spec discover_pods(Path.t()) :: %{String.t() => Path.t()}
  def discover_pods(cgroup_root), do: cgroup_root |> kubepods_root() |> pods_under()

  @doc """
  Extracts the dashed pod UID from a pod cgroup directory name, or nil if it is not one.

      iex> Cadmium.Isotope.Source.Cgroup.pod_uid("kubepods-burstable-pod0f5c2a1e_7b3d_4c8e_9a51_d2e4f6a8b09b.slice")
      "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b"
      iex> Cadmium.Isotope.Source.Cgroup.pod_uid("pod0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b")
      "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b"
      iex> Cadmium.Isotope.Source.Cgroup.pod_uid("kubepods-burstable.slice")
      nil
  """
  @spec pod_uid(String.t()) :: String.t() | nil
  def pod_uid(dirname) when is_binary(dirname) do
    case Regex.run(~r/^(?:.*-)?pod(#{@uid})(?:\.slice)?$/, dirname) do
      [_, uid] -> uid |> String.replace("_", "-") |> String.downcase()
      _ -> nil
    end
  end

  @doc "Reads the raw values of one cgroup directory."
  @spec read_cgroup(Path.t()) :: Cadmium.Isotope.Source.pod_raw()
  def read_cgroup(path) do
    %{
      cpu: Parser.cpu_stat(read_file(path, "cpu.stat")),
      psi_cpu: Parser.pressure(read_file(path, "cpu.pressure")),
      psi_memory: Parser.pressure(read_file(path, "memory.pressure")),
      psi_io: Parser.pressure(read_file(path, "io.pressure")),
      io: Parser.io_stat(read_file(path, "io.stat")),
      memory_current: Parser.memory_current(read_file(path, "memory.current")),
      memory_stat: Parser.memory_stat(read_file(path, "memory.stat"))
    }
  end

  # -- internals -------------------------------------------------------------------------

  defp read_node(cgroup_root, proc_root, kubepods) do
    %{
      cpu: Parser.proc_stat(read_file(proc_root, "stat")),
      kubepods_cpu: kubepods && Parser.cpu_stat(read_file(kubepods, "cpu.stat")),
      psi_cpu: node_pressure(cgroup_root, proc_root, "cpu"),
      psi_memory: node_pressure(cgroup_root, proc_root, "memory"),
      psi_io: node_pressure(cgroup_root, proc_root, "io"),
      memory: Parser.meminfo(read_file(proc_root, "meminfo")),
      load: Parser.loadavg(read_file(proc_root, "loadavg")),
      vm: Parser.vmstat(read_file(proc_root, "vmstat")),
      io:
        Parser.io_stat(read_file(cgroup_root, "io.stat")) ||
          (kubepods && Parser.io_stat(read_file(kubepods, "io.stat")))
    }
  end

  defp node_pressure(cgroup_root, proc_root, resource) do
    Parser.pressure(read_file(proc_root, "pressure/#{resource}")) ||
      Parser.pressure(read_file(cgroup_root, "#{resource}.pressure"))
  end

  defp pods_under(nil), do: %{}

  defp pods_under(kubepods) do
    top = subdirs(kubepods)

    # Guaranteed pods sit directly under the root; the other QoS classes one level down.
    nested =
      for {name, path} <- top,
          pod_uid(name) == nil,
          qos_dir?(name),
          entry <- subdirs(path),
          do: entry

    for {name, path} <- top ++ nested, uid = pod_uid(name), into: %{}, do: {uid, path}
  end

  defp qos_dir?(name), do: String.contains?(name, ["burstable", "besteffort"])

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, path = Path.join(dir, name), File.dir?(path), do: {name, path}

      {:error, _} ->
        []
    end
  end

  # A file that is missing, unreadable, or (PSI disabled) returns ENOTSUP is just nil.
  defp read_file(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp all_nil?(map), do: Enum.all?(map, fn {_, value} -> is_nil(value) end)
end
