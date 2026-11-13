defmodule Cadmium.Catalyst.Planner do
  @moduledoc """
  Gathers the inputs `Cadmium.Catalyst.Policy` needs and produces a plan.

  This is the only impure part of planning and it only reads: the Kubernetes node list,
  workloads on the eligible hot nodes, PodDisruptionBudgets, and replica counts for the
  controllers of pods that passed the pod-local checks. Every read is wrapped: a failed
  or crashing dependency becomes missing information, which the policy turns into "do
  not evict" (`nil` node list -> no destination, `nil` PDB list -> `:pdb_blocked`,
  missing replicas -> `:single_replica`).
  """

  alias Cadmium.Catalyst.{Config, Plan, Policy, Safe}
  alias Cadmium.Workload

  @doc """
  Builds a plan. Options:

    * `:config` - `Config` or overrides
    * `:scores` - node scores (required)
    * `:kube_nodes` - a prefetched `Cadmium.Kube.list_nodes/0` result (fetched if absent)
    * `:hot_since`, `:mono_now`, `:ignore_sustained?`, `:spread_only?`, `:generated_at`
    * `:node_cooldowns`, `:workload_cooldowns` - maps keyed by the cooling entries
    * `:workloads_fun` - `(k8s_node -> [Workload])`, default `Cadmium.Workloads.on_node/1`
  """
  @spec build(keyword()) :: Plan.t()
  def build(opts) do
    cfg = Config.load(Keyword.get(opts, :config, []))
    workloads_fun = Keyword.get(opts, :workloads_fun, &Cadmium.Workloads.on_node/1)

    kube_nodes =
      case Keyword.get_lazy(opts, :kube_nodes, fn -> Safe.kube(&Cadmium.Kube.list_nodes/0) end) do
        {:ok, nodes} when is_list(nodes) -> nodes
        _ -> nil
      end

    input = %{
      config: cfg,
      generated_at:
        Keyword.get_lazy(opts, :generated_at, fn -> System.system_time(:millisecond) end),
      scores: Keyword.get(opts, :scores, []),
      kube_nodes: kube_nodes,
      hot_since: Keyword.get(opts, :hot_since, %{}),
      mono_now: Keyword.get(opts, :mono_now, 0),
      ignore_sustained?: Keyword.get(opts, :ignore_sustained?, false),
      spread_only?: Keyword.get(opts, :spread_only?, false),
      node_cooldowns: Keyword.get(opts, :node_cooldowns, %{}),
      workload_cooldowns: Keyword.get(opts, :workload_cooldowns, %{})
    }

    case Policy.assess(input).eligible do
      [] ->
        Policy.plan(input)

      eligible ->
        workloads =
          Map.new(eligible, fn score ->
            {score.k8s_node, fetch_workloads(workloads_fun, score.k8s_node)}
          end)

        pdbs =
          case Safe.kube(&Cadmium.Kube.list_pdbs/0) do
            {:ok, pdbs} when is_list(pdbs) -> pdbs
            _ -> nil
          end

        input
        |> Map.merge(%{
          workloads: workloads,
          pdbs: pdbs,
          replicas: fetch_replicas(workloads, cfg)
        })
        |> Policy.plan()
    end
  end

  @doc """
  Plans from live data with no side effects, ignoring the sustained window. Options:
  `:nodes_fun`, `:workloads_fun`, `:config`, and `:cooldowns` - the `cooldowns` map of a
  `Cadmium.Catalyst.status/0` (wall-clock expiries), so a non-leader simulates with the
  leader's cooldowns.
  """
  @spec simulate(keyword()) :: Plan.t()
  def simulate(opts \\ []) do
    now = System.system_time(:millisecond)
    nodes_fun = Keyword.get(opts, :nodes_fun, &Cadmium.Valence.nodes/0)
    cooldowns = Keyword.get(opts, :cooldowns, %{})

    build(
      config: Keyword.get(opts, :config, []),
      scores: nodes_fun.(),
      generated_at: now,
      ignore_sustained?: true,
      node_cooldowns: unexpired(cooldowns, :nodes, now),
      workload_cooldowns: unexpired(cooldowns, :workloads, now),
      workloads_fun: Keyword.get(opts, :workloads_fun, &Cadmium.Workloads.on_node/1)
    )
  rescue
    e -> failed_plan(Exception.message(e))
  catch
    kind, reason -> failed_plan("#{kind}: #{inspect(reason)}")
  end

  @doc "The explanatory plan returned when planning itself failed."
  @spec failed_plan(String.t()) :: Plan.t()
  def failed_plan(message) do
    %Plan{
      generated_at: System.system_time(:millisecond),
      status: :insufficient_nodes,
      summary: "Unable to plan from live data: #{message}"
    }
  end

  defp unexpired(cooldowns, kind, now) when is_map(cooldowns) do
    case Map.get(cooldowns, kind) do
      %{} = entries ->
        Map.filter(entries, fn {_key, expiry} -> is_integer(expiry) and expiry > now end)

      _ ->
        %{}
    end
  end

  defp unexpired(_cooldowns, _kind, _now), do: %{}

  defp fetch_workloads(workloads_fun, k8s_node) do
    case Safe.call(fn -> workloads_fun.(k8s_node) end, []) do
      workloads when is_list(workloads) -> workloads
      _ -> []
    end
  end

  # Replica counts only for controllers of pods that are still candidates after the
  # pod-local checks; one lookup per controller.
  defp fetch_replicas(workloads, cfg) do
    workloads
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&match?(%Workload{pod: %Cadmium.Kube.Pod{}}, &1))
    |> Enum.filter(&(Policy.static_rejection(&1, cfg) == nil))
    |> Enum.map(&Policy.replicas_key(&1.pod))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn {namespace, kind, name} = key, acc ->
      case Safe.kube(fn -> Cadmium.Kube.workload_replicas(namespace, kind, name) end) do
        {:ok, %{desired: desired, ready: ready}} when is_integer(desired) and is_integer(ready) ->
          Map.put(acc, key, %{desired: desired, ready: ready})

        _ ->
          acc
      end
    end)
  end
end
