defmodule CadmiumWeb.Dashboard.Data.Demo do
  @moduledoc """
  Synthetic dashboard data for looking at the UI on a laptop. DEV ONLY.

  Selected by starting the server with `CADMIUM_DASHBOARD_FIXTURES=1`; nothing here is
  used otherwise. Everything is a pure function of the wall clock, so the pages move
  without any subsystem running. `CadmiumWeb.Dashboard.Data.DemoTicker` (started lazily
  on first use) publishes the same data on the real PubSub topics so the live-update
  paths are exercised too.

  Dry-run / paused toggles are kept in the application env and touch nothing else.
  """

  @behaviour CadmiumWeb.Dashboard.Data

  alias Cadmium.Catalyst.{Action, Move, Plan}
  alias Cadmium.Isotope.{NodeSample, PodSample}
  alias Cadmium.Valence.NodeScore
  alias Cadmium.Workload
  alias CadmiumWeb.Dashboard.Data.DemoTicker

  # {node, base score}: a spread from critical to idle.
  @nodes [
    {"ip-10-0-1-17", 86.0},
    {"ip-10-0-1-42", 73.0},
    {"ip-10-0-2-8", 60.0},
    {"ip-10-0-2-31", 47.0},
    {"ip-10-0-3-5", 36.0},
    {"ip-10-0-3-64", 27.0},
    {"ip-10-0-4-12", 18.0},
    {"ip-10-0-4-77", 9.0}
  ]
  @self "ip-10-0-2-8"
  @leader "ip-10-0-1-42"
  # this node's agent is lagging, to show stale dimming
  @lagging "ip-10-0-3-64"
  @score_interval_ms 2_000

  @impl true
  def node_name, do: @self

  @impl true
  def nodes do
    DemoTicker.ensure_started()
    now = now()
    Enum.map(@nodes, fn {name, _} -> score_at(name, score_ts(name, now)) end)
  end

  @impl true
  def history(k8s_node, limit) do
    if List.keymember?(@nodes, k8s_node, 0) do
      last = score_ts(k8s_node, now())
      for i <- (limit - 1)..0//-1, do: score_at(k8s_node, last - i * @score_interval_ms)
    else
      []
    end
  end

  @impl true
  def workloads, do: Enum.flat_map(@nodes, fn {name, _} -> workloads_on_node(name) end)

  @impl true
  def workloads_on_node(k8s_node) do
    case List.keyfind(@nodes, k8s_node, 0) do
      nil -> []
      {_, base} -> k8s_node |> Cadmium.Demo.pods() |> Enum.map(&workload(&1, base, now()))
    end
  end

  @impl true
  def isotope_history(limit) do
    now = div(now(), 1000) * 1000
    for i <- (limit - 1)..0//-1, do: isotope_sample(now - i * 1000)
  end

  @impl true
  def status do
    DemoTicker.ensure_started()
    now = now()
    state = state()

    %{
      dry_run?: state.dry_run?,
      enabled?: state.enabled?,
      leader: @leader,
      leader?: false,
      last_plan: plan(now - rem(now, 15_000)),
      last_evaluated_at: now - rem(now, 15_000),
      cooldowns: %{
        nodes: %{"ip-10-0-1-42" => state.started_at + 300_000},
        workloads: %{
          "shop/ReplicaSet/api-5c7b9d4f8" => state.started_at + 900_000,
          "data/ReplicaSet/indexer-84d5f6c7b" => state.started_at + 420_000
        }
      }
    }
  end

  @impl true
  def simulate do
    # long enough to see the button's busy state
    Process.sleep(400)
    plan(now())
  end

  @impl true
  def rebalance_now, do: {:ok, plan(now())}

  @impl true
  def audit_log(limit) do
    now = now()

    [
      {12_000, :evict, true, "ip-10-0-1-17", "shop", "web-7d9f8b6c5-x2k9q",
       "cpu drift 2.8x on hot node (score 86)", :simulated},
      {12_500, :taint, true, "ip-10-0-1-17", nil, nil, "node hot for 120s (score 86, spread 77)",
       :simulated},
      {95_000, :settings_changed, false, nil, nil, nil, "dry_run set to true", :ok},
      {260_000, :untaint, false, "ip-10-0-1-42", nil, nil, "node cooldown expired", :ok},
      {560_000, :evict, false, "ip-10-0-1-42", "shop", "api-5c7b9d4f8-p7w3m",
       "throttled 61% on hot node (score 81)", :ok},
      {561_000, :evict, false, "ip-10-0-1-42", "shop", "checkout-6b8c7d9f4-hd2lz",
       "cpu drift 1.9x on hot node (score 81)",
       {:error,
        "429 Too Many Requests: Cannot evict pod as it would violate the pod's disruption budget."}},
      {562_000, :taint, false, "ip-10-0-1-42", nil, nil,
       "node hot for 120s (score 81, spread 70)", :ok},
      {1_900_000, :leader_acquired, false, @leader, nil, nil, "lease cadmium-catalyst acquired",
       :ok},
      {1_915_000, :leader_lost, false, "ip-10-0-3-5", nil, nil, "lease renewal failed for 15s",
       :ok},
      {7_300_000, :settings_changed, false, nil, nil, nil, "enabled set to true", :ok}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {{age, type, dry_run?, node, namespace, pod, reason, result}, index} ->
      %Action{
        id: "demo-#{index}",
        ts: state().started_at - age,
        type: type,
        dry_run?: dry_run?,
        actor: if(type == :leader_lost, do: "ip-10-0-3-5", else: @leader),
        node: node,
        namespace: namespace,
        pod: pod,
        reason: reason,
        result: result
      }
    end)
    |> Enum.filter(&(&1.ts <= now))
    |> Enum.take(limit)
  end

  @impl true
  def set_dry_run(dry_run?), do: change(:dry_run?, dry_run?, "dry_run")

  @impl true
  def set_enabled(enabled?), do: change(:enabled?, enabled?, "enabled")

  defp change(key, value, name) do
    Application.put_env(:cadmium, :dashboard_demo_state, Map.put(state(), key, value))

    DemoTicker.broadcast(Cadmium.Catalyst.topic(), {:catalyst_status, status()})

    DemoTicker.broadcast(
      Cadmium.Catalyst.topic(),
      {:catalyst_action,
       %Action{
         id: "demo-settings-#{System.unique_integer([:positive])}",
         ts: now(),
         type: :settings_changed,
         actor: @self,
         reason: "#{name} set to #{value}",
         result: :ok
       }}
    )

    :ok
  end

  @doc false
  def state do
    case Application.get_env(:cadmium, :dashboard_demo_state) do
      nil ->
        state = %{dry_run?: true, enabled?: true, started_at: now()}
        Application.put_env(:cadmium, :dashboard_demo_state, state)
        state

      state ->
        state
    end
  end

  @doc "The Isotope sample the demo host produced at `ts`."
  def isotope_sample(ts) do
    t = ts / 1000
    burst = max(:math.sin(t / 37), 0.0)

    %NodeSample{
      ts: ts,
      cpu_usage_ratio: clamp(0.52 + 0.2 * :math.sin(t / 23) + 0.05 * :math.sin(t / 2.3), 0, 1),
      cpu_throttled_ratio: clamp(0.08 + 0.3 * burst + 0.03 * :math.sin(t / 3.1), 0, 1),
      psi_cpu_some: clamp(6 + 22 * burst + 2 * :math.sin(t / 4.7), 0, 100),
      psi_memory_some: clamp(1.5 + 5 * max(:math.sin(t / 61), 0.0), 0, 100),
      psi_memory_full: clamp(0.4 + 1.5 * max(:math.sin(t / 61), 0.0), 0, 100),
      psi_io_some: clamp(3 + 9 * max(:math.sin(t / 17 + 1), 0.0), 0, 100),
      psi_io_full: clamp(1 + 3 * max(:math.sin(t / 17 + 1), 0.0), 0, 100),
      memory_used_ratio: clamp(0.61 + 0.04 * :math.sin(t / 90), 0, 1),
      major_faults_per_s: clamp(2 + 40 * max(:math.sin(t / 61), 0.0) ** 3, 0, 1000),
      io_read_bytes_per_s: 4.0e6 + 3.0e6 * :math.sin(t / 17),
      io_write_bytes_per_s: 9.0e6 + 6.0e6 * :math.sin(t / 29),
      load1: 3.2 + 1.5 * :math.sin(t / 23)
    }
  end

  # ---- generators -------------------------------------------------------------

  defp now, do: System.system_time(:millisecond)

  defp score_ts(@lagging, now), do: now - 12_000 - rem(now, @score_interval_ms)
  defp score_ts(_name, now), do: now - rem(now, @score_interval_ms)

  defp score_at(name, ts) do
    {_, base} = List.keyfind(@nodes, name, 0)
    phase = :erlang.phash2(name, 628) / 100
    t = ts / 1000

    score =
      clamp(base + 7 * :math.sin(t / 40 + phase) + 2.5 * :math.sin(t / 5 + phase * 3), 0, 100)

    %NodeScore{
      k8s_node: name,
      beam_node: :"cadmium@#{name}",
      score: Float.round(score, 1),
      ts: ts,
      pod_count: length(Cadmium.Demo.pods(name)),
      components: %{
        cpu: Float.round(score * 1.0, 1),
        memory: Float.round(clamp(score * 0.62 + 12 * :math.sin(t / 70 + phase), 0, 100), 1),
        io: Float.round(clamp(score * 0.35 + 8 * :math.sin(t / 30 + phase * 2), 0, 100), 1)
      }
    }
  end

  defp workload(pod, node_base, now) do
    template = Enum.find(Cadmium.Demo.workloads(), &(&1.owner == pod.owner_name))
    phase = :erlang.phash2(pod.uid, 628) / 100
    t = now / 1000
    heat = node_base / 60

    {cpu_ratio, throttled, mem_ratio} =
      case template.profile do
        :steady ->
          {0.6 + 0.05 * :math.sin(t / 20 + phase), 0.0, 0.7}

        :bursty ->
          {clamp(heat * (1.3 + 1.1 * :math.sin(t / 25 + phase)), 0.15, 3.4), 0.04 * heat, 0.9}

        :throttled ->
          {pod.cpu_limit_millis / pod.cpu_request_millis, clamp(0.4 * heat, 0.05, 0.9), 0.8}

        :leaky ->
          {0.8, 0.02, clamp(1.2 + 1.3 * heat * abs(:math.sin(t / 240 + phase)), 1.0, 2.5)}
      end

    sample = %PodSample{
      pod_uid: pod.uid,
      ts: now,
      cpu_usage_millis: Float.round(pod.cpu_request_millis * cpu_ratio, 1),
      cpu_throttled_ratio: Float.round(throttled * 1.0, 3),
      memory_bytes: round(pod.memory_request_bytes * mem_ratio),
      psi_cpu_some: Float.round(clamp(throttled * 60 + cpu_ratio * 2, 0, 100), 1),
      psi_memory_some: Float.round(clamp((mem_ratio - 1) * 14, 0, 100), 1),
      psi_io_some: 0.4,
      major_faults_per_s: Float.round(max(mem_ratio - 1, 0.0) * 12.0, 1),
      io_bytes_per_s: 1.2e5
    }

    %Workload{
      pod: pod,
      k8s_node: pod.node_name,
      sample: sample,
      cpu_drift: Float.round(cpu_ratio * 1.0, 2),
      memory_drift: Float.round(mem_ratio * 1.0, 2)
    }
  end

  defp plan(now) do
    scores = Enum.map(@nodes, fn {name, _} -> score_at(name, score_ts(name, now)) end)
    hot = scores |> Enum.filter(&(&1.score >= 70)) |> Enum.sort_by(& &1.score, :desc)
    cool = scores |> Enum.sort_by(& &1.score) |> Enum.take(3)

    case hot do
      [] ->
        %Plan{
          generated_at: now,
          status: :balanced,
          summary: "No node is above the hot threshold (70).",
          cool: cool
        }

      [hottest | _] ->
        workloads = workloads_on_node(hottest.k8s_node)

        by_owner = fn prefix ->
          Enum.filter(workloads, &String.starts_with?(&1.pod.owner_name, prefix))
        end

        [mover | other_web] = Enum.sort_by(by_owner.("web-"), & &1.cpu_drift, :desc)

        rejected =
          Enum.map(other_web, &{&1, :workload_cooldown}) ++
            Enum.map(by_owner.("api-"), &{&1, :replicas_not_ready}) ++
            Enum.map(by_owner.("checkout-"), &{&1, :pdb_blocked}) ++
            Enum.map(by_owner.("indexer-"), &{&1, :single_replica}) ++
            Enum.map(by_owner.("cache"), &{&1, :local_storage}) ++
            Enum.map(by_owner.("report-"), &{&1, :job}) ++
            Enum.map(by_owner.("node-exporter"), &{&1, :daemonset}) ++
            Enum.map(by_owner.("kube-proxy"), &{&1, :namespace_excluded})

        %Plan{
          generated_at: now,
          status: :imbalanced,
          summary:
            "#{hottest.k8s_node} is hot (score #{round(hottest.score)}), " <>
              "#{round(hottest.score - hd(cool).score)} above the coolest node; 1 move proposed.",
          hot: hot,
          cool: cool,
          moves: [
            %Move{
              workload: mover,
              from_node: hottest.k8s_node,
              reason: "cpu drift #{mover.cpu_drift}x on hot node (score #{round(hottest.score)})"
            }
          ],
          rejected: rejected
        }
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high) |> Kernel.*(1.0)
end
