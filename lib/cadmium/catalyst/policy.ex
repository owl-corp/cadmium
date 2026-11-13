defmodule Cadmium.Catalyst.Policy do
  @moduledoc """
  The rebalancing policy: pure functions from a snapshot of the cluster to a
  `Cadmium.Catalyst.Plan`. Nothing here talks to Kubernetes, the mesh or the clock.

  The guiding rule is conservatism: missing or contradictory information always means
  "do not evict".

  ## Imbalance

    * At least two live nodes are required (`:insufficient_nodes`).
    * A node is **hot** when `score >= hot_threshold` and
      `score - coolest_score >= spread_threshold` (coolest = lowest score of any live node).
    * A node is a viable **cool destination** when it is not hot, its score is strictly
      below `hot_threshold - spread_threshold / 2` (`Cadmium.Catalyst.Config.cool_ceiling/1`,
      57.5 with the defaults - half the spread is the margin that keeps us from pushing
      pods onto a node that is itself about to be hot), and its Kubernetes node is known,
      Ready, not unschedulable, has no `NoSchedule`/`NoExecute` taint and does not carry
      the cadmium taint.
    * A hot node is only acted on when its Kubernetes node is known, Ready and not
      cordoned (a cordoned node is being drained by someone else), and at least one
      viable destination is `spread_threshold` or more below it.
    * It must not be in node cooldown (`:cooling_down` when every actionable hot node
      is), and it must have been continuously hot for `sustained_ms` (`:not_sustained`),
      unless `ignore_sustained?` is set (simulation).

  When hot nodes exist but nothing can be done about them (no destination, node list
  unavailable, ...) the status is `:imbalanced` with no moves and an explanatory summary.

  ## Candidates

  Every workload on an eligible hot node is checked in this fixed order and lands in
  `plan.rejected` with the first reason that applies:

  `:namespace_excluded`, `:mirror_pod`, `:daemonset`, `:job`, `:unmanaged`, `:deleting`,
  `:not_running`, `:opted_out`, `:local_storage`, `:single_replica`,
  `:replicas_not_ready`, `:pdb_blocked`, `:workload_cooldown`.

  Unknown replica counts are `:single_replica`; an unavailable PDB list is
  `:pdb_blocked`. Healthy single-replica workloads may be moved, which causes
  downtime; replica readiness and PDBs still apply. Pods with emptyDir may be moved,
  losing their temporary contents, but hostPath pods remain excluded.

  ## Ranking

  Survivors are ranked per node by how much they contribute to the node's dominant
  pressure component (largest of cpu/memory/io, ties in that order):

    * cpu: 0.5 x share of CPU usage (relative to the biggest survivor) + 0.3 x throttled
      ratio + 0.2 x CPU drift (capped at 4x)
    * memory: 0.6 x share of memory + 0.25 x memory drift (capped at 4x) + 0.15 x
      relative memory PSI
    * io: 0.7 x share of I/O throughput + 0.3 x relative I/O PSI

  plus a small bonus (up to 0.1) for more replicas. A survivor with no measurable
  contribution (no sample, or all zeros) is never moved: evicting it cannot relieve the
  pressure. Moves are taken round-robin across eligible nodes, hottest first, never two
  pods of the same controller in one cycle, at most `max_evictions_per_cycle` in total.
  """

  alias Cadmium.Catalyst.{Config, Move, Plan, Selector}
  alias Cadmium.Kube.Node, as: KubeNode
  alias Cadmium.Kube.Pod
  alias Cadmium.Valence.NodeScore
  alias Cadmium.Workload

  @typedoc """
  Planner input.

    * `:config` - `Cadmium.Catalyst.Config`
    * `:generated_at` - wall-clock ms stamped on the plan
    * `:scores` - live `NodeScore`s
    * `:kube_nodes` - `[Cadmium.Kube.Node]`, or `nil` when the list is unavailable
    * `:hot_since` - `%{k8s_node => monotonic ms}` from `track_hot/4`
    * `:mono_now` - monotonic ms, same timebase as `:hot_since`
    * `:ignore_sustained?` - skip the sustained window (simulation)
    * `:spread_only?` - allow destinations above the normal cool ceiling for a manual
      cycle; source scores need the configured spread
    * `:node_cooldowns` / `:workload_cooldowns` - maps whose keys are the node names /
      `workload_key/1`s currently cooling down (values are ignored)
    * `:workloads` - `%{k8s_node => [Workload]}` for the eligible hot nodes
    * `:pdbs` - `[Cadmium.Kube.PDB]`, or `nil` when unavailable
    * `:replicas` - `%{{namespace, owner_kind, owner_name} => %{desired: n, ready: n}}`
  """
  @type input :: map()

  @type assessment :: %{
          status: Plan.status(),
          summary: String.t(),
          hot: [NodeScore.t()],
          cool: [NodeScore.t()],
          eligible: [NodeScore.t()],
          coolest: NodeScore.t() | nil
        }

  @blocking_effects ["NoSchedule", "NoExecute"]
  @drift_cap 4.0
  @replica_bonus 0.1

  ## Hot tracking

  @doc "Well-formed scores, one per Kubernetes node."
  @spec live_scores(term()) :: [NodeScore.t()]
  def live_scores(scores) do
    scores
    |> List.wrap()
    |> Enum.filter(fn
      %NodeScore{k8s_node: name, score: score} -> is_binary(name) and is_number(score)
      _ -> false
    end)
    |> Enum.uniq_by(& &1.k8s_node)
  end

  @doc "Hot nodes, hottest first. Empty with fewer than two live nodes."
  @spec hot_nodes(term(), Config.t()) :: [NodeScore.t()]
  def hot_nodes(scores, %Config{} = cfg) do
    case live_scores(scores) do
      [_, _ | _] = live ->
        coolest = live |> Enum.map(& &1.score) |> Enum.min()

        live
        |> Enum.filter(fn s ->
          s.score >= cfg.hot_threshold and s.score - coolest >= cfg.spread_threshold
        end)
        |> Enum.sort_by(&{-&1.score, &1.k8s_node})

      _ ->
        []
    end
  end

  @doc """
  Updates the "hot since" map: nodes that are still hot keep their timestamp, newly hot
  nodes start at `mono_now`, and nodes that cooled down or disappeared are dropped (so
  the sustained window starts over if they become hot again).
  """
  @spec track_hot(map(), term(), Config.t(), integer()) :: %{String.t() => integer()}
  def track_hot(hot_since, scores, %Config{} = cfg, mono_now) do
    scores
    |> hot_nodes(cfg)
    |> Map.new(fn s -> {s.k8s_node, Map.get(hot_since, s.k8s_node, mono_now)} end)
  end

  ## Destinations

  @doc "Whether a (non-hot) node may receive pods. See the moduledoc."
  @spec viable_destination?(NodeScore.t(), KubeNode.t() | nil, Config.t()) :: boolean()
  def viable_destination?(score, node, cfg, spread_only? \\ false)

  def viable_destination?(%NodeScore{} = score, %KubeNode{} = node, %Config{} = cfg, spread_only?) do
    (spread_only? or score.score < Config.cool_ceiling(cfg)) and node.ready? == true and
      node.unschedulable? == false and not blocking_taint?(node, cfg)
  end

  def viable_destination?(_score, _node, _cfg, _spread_only?), do: false

  @doc "True when the node carries a taint with the configured cadmium key."
  @spec cadmium_tainted?(KubeNode.t(), Config.t()) :: boolean()
  def cadmium_tainted?(%KubeNode{taints: taints}, %Config{taint_key: key}) do
    Enum.any?(List.wrap(taints), &(taint_field(&1, :key) == key))
  end

  defp blocking_taint?(%KubeNode{taints: taints} = node, cfg) do
    cadmium_tainted?(node, cfg) or
      Enum.any?(List.wrap(taints), &(taint_field(&1, :effect) in @blocking_effects))
  end

  defp taint_field(taint, key) when is_map(taint),
    do: Map.get(taint, key) || Map.get(taint, Atom.to_string(key))

  defp taint_field(_taint, _key), do: nil

  ## Assessment

  @doc """
  The node-level half of planning: status, hot/cool lists and the hot nodes that are
  eligible for candidate selection right now. Needs no workload data, so callers use it
  to decide which nodes' workloads to fetch.
  """
  @spec assess(input()) :: assessment()
  def assess(input) do
    input = normalize(input)
    cfg = input.config
    live = live_scores(input.scores)

    if length(live) < 2 do
      %{
        status: :insufficient_nodes,
        summary: "Need at least 2 live nodes to rebalance; #{length(live)} reporting.",
        hot: [],
        cool: [],
        eligible: [],
        coolest: nil
      }
    else
      coolest = Enum.min_by(live, &{&1.score, &1.k8s_node})
      hot = hot_nodes(live, cfg)
      hot_names = MapSet.new(hot, & &1.k8s_node)
      kube = kube_index(input.kube_nodes)

      cool =
        live
        |> Enum.reject(&MapSet.member?(hot_names, &1.k8s_node))
        |> Enum.filter(
          &viable_destination?(&1, Map.get(kube, &1.k8s_node), cfg, input.spread_only?)
        )
        |> Enum.sort_by(&{&1.score, &1.k8s_node})

      assess_hot(%{hot: hot, cool: cool, eligible: [], coolest: coolest}, live, kube, input)
    end
  end

  defp assess_hot(%{hot: []} = base, live, _kube, input) do
    cfg = input.config
    hottest = Enum.max_by(live, & &1.score)

    criterion =
      if input.spread_only?,
        do: "spread >= #{num(cfg.spread_threshold)}",
        else: "hot means >= #{num(cfg.hot_threshold)} and >= #{num(cfg.spread_threshold)}"

    done(
      base,
      :balanced,
      "Balanced: hottest node #{hottest.k8s_node} is at #{num(hottest.score)} " <>
        "(#{criterion} above " <>
        "the coolest, #{base.coolest.k8s_node} at #{num(base.coolest.score)})."
    )
  end

  defp assess_hot(base, _live, kube, input) do
    cfg = input.config

    hot_text =
      describe_nodes(base.hot) <>
        if(input.spread_only?, do: " above the spread threshold", else: " hot")

    cond do
      not is_list(input.kube_nodes) ->
        done(
          base,
          :imbalanced,
          "#{hot_text}, but the Kubernetes node list is unavailable; not acting."
        )

      base.cool == [] ->
        ceiling =
          if input.spread_only?, do: "", else: " and below #{num(Config.cool_ceiling(cfg))}"

        done(
          base,
          :imbalanced,
          "#{hot_text}, but there is no viable cool destination (Ready, schedulable, " <>
            "untainted#{ceiling}); not acting."
        )

      true ->
        coolest_destination = hd(base.cool)

        actionable =
          Enum.filter(base.hot, fn s ->
            actionable_source?(Map.get(kube, s.k8s_node)) and
              s.score - coolest_destination.score >= cfg.spread_threshold
          end)

        assess_actionable(base, actionable, hot_text, input)
    end
  end

  defp assess_actionable(base, [], hot_text, input) do
    done(
      base,
      :imbalanced,
      "#{hot_text}, but cannot be acted on (node unknown to Kubernetes, not Ready, " <>
        "cordoned, or no destination at least #{num(input.config.spread_threshold)} cooler); " <>
        "not acting."
    )
  end

  defp assess_actionable(base, actionable, hot_text, input) do
    cfg = input.config
    free = Enum.reject(actionable, &Map.has_key?(input.node_cooldowns, &1.k8s_node))
    sustained = Enum.filter(free, &sustained?(&1, input))

    cond do
      free == [] ->
        done(base, :cooling_down, "#{hot_text}, but in node cooldown after a recent action.")

      sustained == [] ->
        done(
          base,
          :not_sustained,
          "#{describe_nodes(free)} hot, but not yet continuously for " <>
            "#{duration(cfg.sustained_ms)} (#{hot_durations(free, input)})."
        )

      true ->
        %{done(base, :imbalanced, "#{hot_text}.") | eligible: sustained}
    end
  end

  defp done(base, status, summary), do: Map.merge(base, %{status: status, summary: summary})

  defp actionable_source?(%KubeNode{ready?: true, unschedulable?: false}), do: true
  defp actionable_source?(_node), do: false

  defp sustained?(_score, %{ignore_sustained?: true}), do: true

  defp sustained?(%NodeScore{k8s_node: name}, input) do
    case Map.get(input.hot_since, name) do
      since when is_integer(since) -> input.mono_now - since >= input.config.sustained_ms
      _ -> false
    end
  end

  defp hot_durations(nodes, input) do
    Enum.map_join(nodes, ", ", fn s ->
      case Map.get(input.hot_since, s.k8s_node) do
        since when is_integer(since) ->
          "#{s.k8s_node} for #{duration(max(input.mono_now - since, 0))}"

        _ ->
          "#{s.k8s_node} just now"
      end
    end)
  end

  ## Planning

  @doc "Builds the full plan. Pure; see the moduledoc for the rules."
  @spec plan(input()) :: Plan.t()
  def plan(input) do
    input = normalize(input)
    assessment = assess(input)

    {moves, rejected, survivors} =
      case assessment.eligible do
        [] -> {[], [], 0}
        eligible -> select(eligible, assessment.coolest, input)
      end

    %Plan{
      generated_at: input.generated_at,
      status: assessment.status,
      spread_only?: input.spread_only?,
      summary:
        if(input.spread_only?, do: "Manual spread-only evaluation: ", else: "") <>
          plan_summary(assessment, moves, rejected, survivors),
      hot: assessment.hot,
      cool: assessment.cool,
      moves: moves,
      rejected: rejected
    }
  end

  defp plan_summary(%{eligible: []} = assessment, _moves, _rejected, _survivors),
    do: assessment.summary

  defp plan_summary(assessment, moves, rejected, survivors) do
    hottest = hd(assessment.eligible)
    coolest = assessment.coolest

    head =
      "#{hottest.k8s_node} at #{num(hottest.score)} is #{num(hottest.score - coolest.score)} " <>
        "above the coolest node #{coolest.k8s_node} (#{num(coolest.score)})"

    tail =
      case moves do
        [] ->
          "no movable workload (#{length(rejected)} rejected, #{survivors} eligible " <>
            "but not contributing to the pressure)"

        moves ->
          "#{length(moves)} move(s) planned, #{length(rejected)} candidate(s) rejected"
      end

    head <> "; " <> tail <> "."
  end

  defp select(eligible, coolest, input) do
    per_node =
      Enum.map(eligible, fn score ->
        workloads =
          input.workloads
          |> Map.get(score.k8s_node, [])
          |> List.wrap()
          |> Enum.filter(&match?(%Workload{pod: %Pod{}}, &1))
          |> Enum.filter(&(&1.k8s_node == score.k8s_node))

        {survivors, rejected} =
          Enum.reduce(workloads, {[], []}, fn workload, {ok, rejected} ->
            case rejection(workload, input) do
              nil -> {[{workload, replicas_for(workload.pod, input)} | ok], rejected}
              reason -> {ok, [{workload, reason} | rejected]}
            end
          end)

        {score, Enum.reverse(survivors), Enum.reverse(rejected)}
      end)

    queues =
      Enum.map(per_node, fn {score, survivors, _rejected} ->
        {score, rank(survivors, dominant_component(score))}
      end)

    max = max(input.config.max_evictions_per_cycle, 0)
    moves = pick(queues, max, coolest, [], MapSet.new())
    rejected = Enum.flat_map(per_node, fn {_score, _survivors, rejected} -> rejected end)

    survivors =
      per_node |> Enum.map(fn {_s, survivors, _r} -> length(survivors) end) |> Enum.sum()

    {moves, rejected, survivors}
  end

  # One pick per node per pass (hottest node first), until the budget is used or a
  # whole pass yields nothing.
  defp pick(_queues, max, _coolest, moves, _seen) when length(moves) >= max,
    do: Enum.reverse(moves)

  defp pick(queues, max, coolest, moves, seen) do
    {queues, new_moves, new_seen} =
      Enum.reduce(queues, {[], moves, seen}, fn {score, queue}, {acc, moves, seen} ->
        queue = Enum.reject(queue, fn c -> MapSet.member?(seen, workload_key(c.workload.pod)) end)

        case queue do
          [candidate | rest] when length(moves) < max ->
            move = %Move{
              workload: candidate.workload,
              from_node: score.k8s_node,
              reason: move_reason(score, coolest, candidate)
            }

            seen = MapSet.put(seen, workload_key(candidate.workload.pod))
            {[{score, rest} | acc], [move | moves], seen}

          queue ->
            {[{score, queue} | acc], moves, seen}
        end
      end)

    if length(new_moves) == length(moves) do
      Enum.reverse(moves)
    else
      pick(Enum.reverse(queues), max, coolest, new_moves, new_seen)
    end
  end

  ## Candidate filtering

  @doc """
  The first reason this workload must not be moved, or `nil` when it is a candidate.
  """
  @spec rejection(Workload.t(), input()) :: atom() | nil
  def rejection(%Workload{pod: %Pod{} = pod} = workload, input) do
    input = normalize(input)

    with nil <- static_rejection(workload, input.config),
         nil <- replica_rejection(pod, input),
         nil <- pdb_rejection(pod, input) do
      if Map.has_key?(input.workload_cooldowns, workload_key(pod)), do: :workload_cooldown
    end
  end

  @doc """
  The rejection reasons that depend only on the pod itself (everything before the
  replica lookup). Callers use this to avoid fetching replica counts for pods that are
  rejected anyway.
  """
  @spec static_rejection(Workload.t(), Config.t()) :: atom() | nil
  def static_rejection(%Workload{pod: %Pod{} = pod}, %Config{} = cfg) do
    cond do
      pod.namespace in cfg.excluded_namespaces -> :namespace_excluded
      pod.mirror? == true or pod.owner_kind == "Node" -> :mirror_pod
      pod.owner_kind == "DaemonSet" -> :daemonset
      pod.owner_kind == "Job" -> :job
      not is_binary(pod.owner_kind) or not is_binary(pod.owner_name) -> :unmanaged
      pod.deleting? == true -> :deleting
      pod.phase != "Running" -> :not_running
      opted_out?(pod, cfg) -> :opted_out
      pod.local_storage? != false -> :local_storage
      true -> nil
    end
  end

  defp opted_out?(%Pod{annotations: annotations}, cfg) when is_map(annotations) do
    case Map.get(annotations, cfg.opt_out_annotation) do
      value when is_binary(value) -> value |> String.trim() |> String.downcase() == "false"
      _ -> false
    end
  end

  defp opted_out?(_pod, _cfg), do: false

  defp replica_rejection(pod, input) do
    case replicas_for(pod, input) do
      %{desired: desired, ready: ready} when desired < 1 or ready < 0 -> :single_replica
      %{desired: desired, ready: ready} when ready < desired -> :replicas_not_ready
      %{desired: _, ready: _} -> nil
      nil -> :single_replica
    end
  end

  defp replicas_for(%Pod{} = pod, input) do
    case Map.get(input.replicas, replicas_key(pod)) do
      %{desired: desired, ready: ready} = info when is_integer(desired) and is_integer(ready) ->
        info

      _ ->
        nil
    end
  end

  defp pdb_rejection(pod, %{pdbs: pdbs}) when is_list(pdbs) do
    if Selector.blocked?(pdbs, pod), do: :pdb_blocked
  end

  # PDB list unavailable: we cannot prove the eviction is allowed.
  defp pdb_rejection(_pod, _input), do: :pdb_blocked

  @doc "Key of the replica map for a pod's controller."
  @spec replicas_key(Pod.t()) :: {String.t(), String.t() | nil, String.t() | nil}
  def replicas_key(%Pod{} = pod), do: {pod.namespace, pod.owner_kind, pod.owner_name}

  @doc ~S'Workload-cooldown key: `"namespace/owner_kind/owner_name"`.'
  @spec workload_key(Pod.t()) :: String.t()
  def workload_key(%Pod{} = pod), do: "#{pod.namespace}/#{pod.owner_kind}/#{pod.owner_name}"

  ## Ranking

  @doc "The node's dominant pressure component (ties resolve cpu, memory, io)."
  @spec dominant_component(NodeScore.t()) :: :cpu | :memory | :io
  def dominant_component(%NodeScore{components: components}) do
    components = if is_map(components), do: components, else: %{}

    [:cpu, :memory, :io]
    |> Enum.map(fn key -> {key, number(Map.get(components, key))} end)
    |> Enum.reduce(fn {_k, v} = entry, {_bk, bv} = best -> if v > bv, do: entry, else: best end)
    |> elem(0)
  end

  @doc """
  Ranks `{workload, replicas}` survivors of one node for the given pressure component,
  best eviction candidate first. Survivors without a measurable contribution are dropped.
  """
  @spec rank([{Workload.t(), map() | nil}], :cpu | :memory | :io) :: [map()]
  def rank(survivors, component) do
    raw = Enum.map(survivors, fn {workload, _replicas} -> metrics(component, workload) end)

    maxima =
      raw
      |> Enum.zip_with(fn column -> column |> Enum.map(&elem(&1, 0)) |> Enum.max() end)

    survivors
    |> Enum.zip(raw)
    |> Enum.map(fn {{workload, replicas}, metrics} ->
      contribution =
        metrics
        |> Enum.zip(maxima)
        |> Enum.map(fn {{value, weight, mode}, max} -> weight * normalise(value, max, mode) end)
        |> Enum.sum()

      desired = if is_map(replicas), do: number(replicas[:desired]), else: 0.0

      %{
        workload: workload,
        replicas: replicas,
        component: component,
        contribution: contribution,
        rank: contribution + @replica_bonus * min(desired, 10.0) / 10.0
      }
    end)
    |> Enum.filter(&(&1.contribution > 0.0))
    |> Enum.sort_by(&{-&1.rank, &1.workload.pod.namespace, &1.workload.pod.name})
  end

  # {value, weight, :relative | :absolute | :drift}
  defp metrics(:cpu, w) do
    [
      {sample(w, :cpu_usage_millis), 0.5, :relative},
      {sample(w, :cpu_throttled_ratio), 0.3, :absolute},
      {number(w.cpu_drift), 0.2, :drift}
    ]
  end

  defp metrics(:memory, w) do
    [
      {sample(w, :memory_bytes), 0.6, :relative},
      {number(w.memory_drift), 0.25, :drift},
      {sample(w, :psi_memory_some), 0.15, :relative}
    ]
  end

  defp metrics(:io, w) do
    [
      {sample(w, :io_bytes_per_s), 0.7, :relative},
      {sample(w, :psi_io_some), 0.3, :relative}
    ]
  end

  defp normalise(value, max, :relative) when max > 0, do: value / max
  defp normalise(_value, _max, :relative), do: 0.0
  defp normalise(value, _max, :absolute), do: min(value, 1.0)
  defp normalise(value, _max, :drift), do: min(value, @drift_cap) / @drift_cap

  defp sample(%Workload{sample: sample}, field) when is_map(sample),
    do: number(Map.get(sample, field))

  defp sample(_workload, _field), do: 0.0

  defp number(value) when is_number(value) and value > 0, do: value * 1.0
  defp number(_value), do: 0.0

  ## Reasons and formatting

  defp move_reason(score, coolest, candidate) do
    component = candidate.component

    "#{score.k8s_node} at #{num(score.score)} (#{component}), " <>
      "#{num(score.score - coolest.score)} above coolest; " <>
      pod_detail(component, candidate.workload) <> replica_detail(candidate.replicas)
  end

  defp pod_detail(:cpu, w) do
    throttled = sample(w, :cpu_throttled_ratio)
    usage = sample(w, :cpu_usage_millis)

    parts =
      [
        if(throttled > 0, do: "throttled #{num(throttled * 100)}%"),
        cond do
          number(w.cpu_drift) > 0 -> "using #{ratio(w.cpu_drift)}x its CPU request"
          usage > 0 -> "using #{num(usage)}m CPU"
          true -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)

    "pod " <> Enum.join(parts, " ")
  end

  defp pod_detail(:memory, w) do
    bytes = sample(w, :memory_bytes)

    drift =
      if number(w.memory_drift) > 0, do: " (#{ratio(w.memory_drift)}x its request)", else: ""

    if bytes > 0,
      do: "pod using #{bytes(bytes)} of memory#{drift}",
      else: "pod under memory pressure#{drift}"
  end

  defp pod_detail(:io, w) do
    rate = sample(w, :io_bytes_per_s)

    if rate > 0,
      do: "pod doing #{bytes(rate)}/s of I/O",
      else: "pod stalled on I/O #{ratio(sample(w, :psi_io_some))} (PSI some)"
  end

  defp replica_detail(%{desired: desired, ready: ready}),
    do: "; #{ready}/#{desired} replicas ready"

  defp replica_detail(_replicas), do: ""

  defp describe_nodes(nodes) do
    Enum.map_join(nodes, ", ", fn s -> "#{s.k8s_node} (#{num(s.score)})" end) <>
      if(length(nodes) == 1, do: " is", else: " are")
  end

  defp num(value) when is_number(value), do: value |> round() |> Integer.to_string()
  defp ratio(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp bytes(value) when value >= 1_073_741_824, do: "#{ratio(value / 1_073_741_824)} GiB"
  defp bytes(value) when value >= 1_048_576, do: "#{ratio(value / 1_048_576)} MiB"
  defp bytes(value) when value >= 1024, do: "#{ratio(value / 1024)} KiB"
  defp bytes(value), do: "#{num(value)} B"

  defp duration(ms) when ms >= 60_000 and rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp duration(ms) when ms >= 1_000, do: "#{div(ms, 1_000)}s"
  defp duration(ms), do: "#{ms}ms"

  defp kube_index(nodes) when is_list(nodes) do
    for %KubeNode{name: name} = node <- nodes, into: %{}, do: {name, node}
  end

  defp kube_index(_nodes), do: %{}

  defp normalize(%{__normalized__: true} = input), do: input

  defp normalize(input) when is_map(input) do
    %{
      __normalized__: true,
      config: Config.load(Map.get(input, :config, [])),
      generated_at: Map.get(input, :generated_at, 0),
      scores: Map.get(input, :scores, []),
      kube_nodes: Map.get(input, :kube_nodes),
      hot_since: map_or_empty(Map.get(input, :hot_since)),
      mono_now: Map.get(input, :mono_now, 0),
      ignore_sustained?: Map.get(input, :ignore_sustained?, false) == true,
      spread_only?: Map.get(input, :spread_only?, false) == true,
      node_cooldowns: map_or_empty(Map.get(input, :node_cooldowns)),
      workload_cooldowns: map_or_empty(Map.get(input, :workload_cooldowns)),
      workloads: map_or_empty(Map.get(input, :workloads)),
      pdbs: Map.get(input, :pdbs),
      replicas: map_or_empty(Map.get(input, :replicas))
    }
  end

  defp map_or_empty(map) when is_map(map) and not is_struct(map), do: map
  defp map_or_empty(_other), do: %{}
end
