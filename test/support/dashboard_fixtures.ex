defmodule CadmiumWeb.DashboardFixtures do
  @moduledoc """
  A deterministic `CadmiumWeb.Dashboard.Data` backend for LiveView tests.

  Install it per test (tests using it must be `async: false`, the backend is global):

      setup {CadmiumWeb.DashboardFixtures, :install}

  The default dataset is a five-node cluster served from `test-node`:

      node-a     91.0  critical, cooling down, hosts shop/web-1 and shop/api-1
      node-d     62.0  stale (score is 30s old)
      node-b     55.5  leader, hosts data/cache-0
      test-node  34.0  the node serving the dashboard, hosts batch/report-1
      node-c     18.0  hosts kube-system/kube-proxy-x (no sample yet)

  Any part can be replaced with `put/2`. Calls to `set_dry_run/1` and `set_enabled/1`
  update the fixture status and are reported to the installing test process as
  `{:fixture_call, {name, arg}}`.
  """

  @behaviour CadmiumWeb.Dashboard.Data

  alias Cadmium.Catalyst.{Action, Move, Plan}
  alias Cadmium.Isotope.{NodeSample, PodSample}
  alias Cadmium.Kube.Pod
  alias Cadmium.Valence.NodeScore
  alias Cadmium.Workload

  @mi 1024 * 1024
  @key :dashboard_fixture_state

  # ---- installation -----------------------------------------------------------

  @doc "ExUnit setup callback: makes this module the dashboard data backend for one test."
  def install(_context \\ %{}) do
    Application.put_env(:cadmium, @key, default_state(self()))
    Application.put_env(:cadmium, :dashboard_data, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:cadmium, :dashboard_data)
      Application.delete_env(:cadmium, @key)
    end)

    :ok
  end

  @doc "Replaces one part of the dataset (`:nodes`, `:workloads`, `:status`, `:audit`, ...)."
  def put(key, value) do
    Application.put_env(:cadmium, @key, Map.put(state(), key, value))
  end

  @doc "The current dataset."
  def state, do: Application.fetch_env!(:cadmium, @key)

  # ---- behaviour ------------------------------------------------------------------

  @impl true
  def node_name, do: Cadmium.node_name()

  @impl true
  def nodes, do: state().nodes

  @impl true
  def history(k8s_node, limit) do
    case Enum.find(state().nodes, &(&1.k8s_node == k8s_node)) do
      nil ->
        []

      score ->
        count = min(limit, 10)
        for i <- (count - 1)..0//-1, do: %{score | ts: score.ts - i * 2_000}
    end
  end

  @impl true
  def workloads, do: state().workloads

  @impl true
  def workloads_on_node(k8s_node), do: Enum.filter(state().workloads, &(&1.k8s_node == k8s_node))

  @impl true
  def isotope_history(limit), do: Enum.take(state().isotope, -limit)

  @impl true
  def status, do: state().status

  @impl true
  def simulate, do: state().plan

  @impl true
  def audit_log(limit), do: Enum.take(state().audit, limit)

  @impl true
  def set_dry_run(dry_run?) do
    put(:status, %{status() | dry_run?: dry_run?})
    notify({:set_dry_run, dry_run?})
  end

  @impl true
  def set_enabled(enabled?) do
    put(:status, %{status() | enabled?: enabled?})
    notify({:set_enabled, enabled?})
  end

  defp notify(call) do
    send(state().notify, {:fixture_call, call})
    :ok
  end

  # ---- builders -------------------------------------------------------------------

  @doc "Builds a `%NodeScore{}`. Options: `:ts`, `:components`, `:pod_count`."
  def node_score(name, score, opts \\ []) do
    %NodeScore{
      k8s_node: name,
      beam_node: :"cadmium@#{name}",
      score: score,
      ts: Keyword.get(opts, :ts, System.system_time(:millisecond)),
      components: Keyword.get(opts, :components, %{cpu: score, memory: score / 2, io: score / 4}),
      pod_count: Keyword.get(opts, :pod_count, 3)
    }
  end

  @doc """
  Builds a `%Workload{}`. Options: `:kind`, `:owner`, `:cpu_request`, `:cpu` (actual,
  millicores), `:memory_request`, `:memory` (bytes), `:throttled`, `:psi_memory`,
  `:sample?` (false = no sample yet), `:local_storage?`.
  """
  def workload(namespace, name, node, opts \\ []) do
    uid = "uid-#{namespace}-#{name}"
    cpu_request = Keyword.get(opts, :cpu_request, 100)
    memory_request = Keyword.get(opts, :memory_request, 128 * @mi)

    pod = %Pod{
      namespace: namespace,
      name: name,
      uid: uid,
      node_name: node,
      phase: "Running",
      owner_kind: Keyword.get(opts, :kind, "ReplicaSet"),
      owner_name: Keyword.get(opts, :owner, name),
      cpu_request_millis: cpu_request,
      memory_request_bytes: memory_request,
      local_storage?: Keyword.get(opts, :local_storage?, false)
    }

    sample =
      if Keyword.get(opts, :sample?, true) do
        %PodSample{
          pod_uid: uid,
          ts: System.system_time(:millisecond),
          cpu_usage_millis: Keyword.get(opts, :cpu, 100.0),
          cpu_throttled_ratio: Keyword.get(opts, :throttled, 0.0),
          memory_bytes: Keyword.get(opts, :memory, 128 * @mi),
          psi_memory_some: Keyword.get(opts, :psi_memory, 0.0)
        }
      end

    %Workload{
      pod: pod,
      k8s_node: node,
      sample: sample,
      cpu_drift: drift(sample && sample.cpu_usage_millis, cpu_request),
      memory_drift: drift(sample && sample.memory_bytes, memory_request)
    }
  end

  defp drift(nil, _request), do: nil
  defp drift(_actual, 0), do: nil
  defp drift(actual, request), do: actual / request

  @doc "Builds an `%Action{}`. Options are struct fields; `:ts` defaults to now."
  def action(id, type, opts \\ []) do
    struct!(
      %Action{id: id, type: type, ts: System.system_time(:millisecond), actor: "node-b"},
      opts
    )
  end

  @doc "Builds a `%NodeSample{}` at `ts` with every series set."
  def node_sample(ts, opts \\ []) do
    struct!(
      %NodeSample{
        ts: ts,
        cpu_usage_ratio: 0.5,
        cpu_throttled_ratio: 0.1,
        psi_cpu_some: 12.5,
        psi_memory_some: 2.0,
        psi_memory_full: 0.5,
        psi_io_some: 4.0,
        psi_io_full: 1.0,
        memory_used_ratio: 0.6,
        major_faults_per_s: 3.0,
        io_read_bytes_per_s: 1.0e6,
        io_write_bytes_per_s: 2.0e6,
        load1: 2.0
      },
      opts
    )
  end

  @doc "The fixture workload with the given pod name."
  def workload!(name), do: Enum.find(state().workloads, &(&1.pod.name == name)) || raise(name)

  # ---- default dataset --------------------------------------------------------------

  defp default_state(notify) do
    now = System.system_time(:millisecond)

    nodes = [
      node_score("node-a", 91.0, components: %{cpu: 91.0, memory: 40.0, io: 12.0}, pod_count: 14),
      node_score("node-b", 55.5, pod_count: 9),
      node_score("node-c", 18.0, pod_count: 4),
      node_score("node-d", 62.0, ts: now - 30_000),
      node_score("test-node", 34.0, pod_count: 6)
    ]

    web =
      workload("shop", "web-1", "node-a",
        owner: "web",
        cpu_request: 250,
        cpu: 700.0,
        memory_request: 256 * @mi,
        memory: 128 * @mi,
        throttled: 0.05
      )

    api =
      workload("shop", "api-1", "node-a",
        owner: "api",
        cpu_request: 500,
        cpu: 600.0,
        memory_request: 512 * @mi,
        memory: 1536 * @mi,
        throttled: 0.6,
        psi_memory: 7.5
      )

    cache =
      workload("data", "cache-0", "node-b",
        kind: "StatefulSet",
        owner: "cache",
        cpu_request: 1000,
        cpu: 300.0,
        memory_request: 1024 * @mi,
        memory: 700 * @mi,
        local_storage?: true
      )

    report =
      workload("batch", "report-1", "test-node",
        kind: "Job",
        owner: "report",
        cpu_request: 0,
        cpu: 1900.0
      )

    proxy =
      workload("kube-system", "kube-proxy-x", "node-c",
        kind: "DaemonSet",
        owner: "kube-proxy",
        sample?: false
      )

    plan = %Plan{
      generated_at: now - 5_000,
      status: :imbalanced,
      summary: "node-a is hot (score 91); 1 move proposed.",
      hot: [Enum.at(nodes, 0)],
      cool: [Enum.at(nodes, 2)],
      moves: [%Move{workload: web, from_node: "node-a", reason: "cpu drift 2.8x on hot node"}],
      rejected: [
        {api, :pdb_blocked},
        {cache, :local_storage},
        {proxy, :daemonset},
        {report, :job}
      ]
    }

    %{
      notify: notify,
      nodes: nodes,
      workloads: [web, api, cache, report, proxy],
      isotope: for(i <- 4..0//-1, do: node_sample(now - i * 1_000)),
      plan: plan,
      status: %{
        dry_run?: true,
        enabled?: true,
        leader: "node-b",
        leader?: false,
        last_plan: plan,
        last_evaluated_at: now - 5_000,
        cooldowns: %{
          # node-c's cooldown already expired and must not be shown
          nodes: %{"node-a" => now + 119_000, "node-c" => now - 1_000},
          workloads: %{"shop/ReplicaSet/web" => now + 299_000}
        }
      },
      audit: [
        action("a4", :evict,
          ts: now - 10_000,
          dry_run?: true,
          node: "node-a",
          namespace: "shop",
          pod: "web-1",
          reason: "cpu drift 2.8x on hot node",
          result: :simulated
        ),
        action("a3", :evict,
          ts: now - 60_000,
          node: "node-a",
          namespace: "shop",
          pod: "api-1",
          reason: "throttled 60%",
          result: {:error, "eviction blocked by budget"}
        ),
        action("a2", :taint, ts: now - 61_000, node: "node-a", reason: "node hot for 120s"),
        action("a1", :settings_changed, ts: now - 3_600_000, reason: "dry_run set to true")
      ]
    }
  end
end
