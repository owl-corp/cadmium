defmodule Cadmium.Catalyst.Executor do
  @moduledoc """
  Carries out a plan, and keeps Cadmium's taints tidy.

  ## Executing moves (`execute/2`)

  For each move, in order:

    1. taint the hot node `PreferNoSchedule` (once per node per cycle) and start the
       node cooldown;
    2. evict the pod through `Cadmium.Kube.evict_pod/3`;
    3. on success start the workload cooldown (and refresh the node cooldown).

  Leadership is re-checked through `ctx.leader_fun` immediately before every mutating
  step; if it was lost the cycle is aborted on the spot. If tainting fails, nothing is
  evicted from that node this cycle. If an eviction fails (`:pdb_blocked`, `:not_found`,
  anything else) it is recorded and the next move is tried; nothing is retried within
  the cycle.

  The node cooldown starts when the taint is applied rather than after the eviction:
  the taint and the cooldown are one unit ("leave the node and its taint alone"), and it
  means a persistently failing eviction cannot cause a taint/evict/untaint loop every
  cycle.

  ## Dry-run

  In dry-run no mutating Kubernetes call is made. The same actions are recorded with
  `dry_run?: true, result: :simulated`, and - deliberately - the same node and workload
  cooldowns are applied, so the audit log shows one simulated move per cooldown window
  (what live mode would have done) instead of the same move every cycle.

  ## Taint hygiene (`sweep_taints/2`)

  Run at the start of every cycle the leader evaluates, including the first one after
  gaining leadership and while rebalancing is paused or in dry-run:

    * a tracked taint whose node cooldown has expired is removed;
    * a node that carries the cadmium taint but that this coordinator has neither a
      cooldown nor a record for (a previous leader crashed, state was lost) is cleaned
      up as a stale taint;
    * a node that carries the taint and *is* in cooldown (adopted from the previous
      leader's last broadcast) starts being tracked.

  Removing a real taint is undoing Cadmium's own change, so it happens regardless of the
  current dry-run/enabled settings; a taint that was only simulated is "removed" by
  recording a simulated `:untaint`. Failed removals stay tracked and are retried every
  cycle; only the first failure is written to the audit log.
  """

  require Logger

  alias Cadmium.Catalyst.{AuditLog, Config, Cooldowns, Plan, Policy, Safe}

  @typedoc """
  Execution context: `:config`, `:dry_run?`, `:leader_fun`, `:clock` (monotonic ms),
  `:cooldowns` (table), `:audit` (audit log server) and optionally `:actor` (defaults
  to `Cadmium.node_name/0`).
  """
  @type ctx :: %{
          optional(:actor) => String.t(),
          config: Config.t(),
          dry_run?: boolean(),
          leader_fun: (-> boolean()),
          clock: (-> integer()),
          cooldowns: atom(),
          audit: GenServer.server()
        }

  @type outcome :: %{status: :completed | :aborted, evicted: non_neg_integer()}

  ## Moves

  @spec execute(Plan.t(), ctx()) :: outcome()
  def execute(%Plan{moves: moves}, ctx) do
    acc = %{status: :completed, evicted: 0, tainted: MapSet.new(), failed: MapSet.new()}

    acc =
      moves
      |> Enum.take(max(ctx.config.max_evictions_per_cycle, 0))
      |> Enum.reduce_while(acc, fn move, acc ->
        if MapSet.member?(acc.failed, move.from_node) do
          {:cont, acc}
        else
          run_move(move, acc, ctx)
        end
      end)

    Map.take(acc, [:status, :evicted])
  end

  defp run_move(move, acc, ctx) do
    with {:ok, acc} <- ensure_tainted(move.from_node, acc, ctx),
         {:ok, acc} <- evict(move, acc, ctx) do
      {:cont, acc}
    else
      {:skip, acc} ->
        {:cont, acc}

      :leadership_lost ->
        Logger.warning("Catalyst: leadership lost mid-cycle; aborting before the next action")
        {:halt, %{acc | status: :aborted}}
    end
  end

  defp ensure_tainted(node, acc, ctx) do
    cond do
      MapSet.member?(acc.tainted, node) ->
        {:ok, acc}

      not leader?(ctx) ->
        :leadership_lost

      true ->
        taint = Config.taint(ctx.config)

        result =
          if ctx.dry_run?,
            do: :ok,
            else: Safe.kube(fn -> Cadmium.Kube.add_node_taint(node, taint) end)

        base = [type: :taint, node: node, dry_run?: ctx.dry_run?, details: %{taint: taint}]

        case normalise(result) do
          :ok ->
            Cooldowns.mark_tainted(ctx.cooldowns, node, ctx.dry_run?)
            start_node_cooldown(node, ctx)

            reason =
              if Map.get(ctx, :spread_only?, false),
                do: "manual spread-only rebalance; steering new pods away",
                else: "hot node; steering new pods away while it is relieved"

            record(ctx, base ++ [reason: reason])

            {:ok, %{acc | tainted: MapSet.put(acc.tainted, node)}}

          {:error, _} = error ->
            record(
              ctx,
              base ++ [result: error, reason: "could not taint; no eviction from this node"]
            )

            {:skip, %{acc | failed: MapSet.put(acc.failed, node)}}
        end
    end
  end

  defp evict(move, acc, ctx) do
    if leader?(ctx) do
      pod = move.workload.pod

      result =
        if ctx.dry_run?,
          do: :ok,
          else: Safe.kube(fn -> Cadmium.Kube.evict_pod(pod.namespace, pod.name, []) end)

      base = [
        type: :evict,
        node: move.from_node,
        namespace: pod.namespace,
        pod: pod.name,
        reason: move.reason,
        dry_run?: ctx.dry_run?,
        details: %{uid: pod.uid, owner_kind: pod.owner_kind, owner_name: pod.owner_name}
      ]

      case normalise(result) do
        :ok ->
          # Cooldowns first: they are what prevents a repeat if anything below fails.
          Cooldowns.put_workload(
            ctx.cooldowns,
            Policy.workload_key(pod),
            ctx.clock.() + ctx.config.workload_cooldown_ms
          )

          start_node_cooldown(move.from_node, ctx)
          record(ctx, base)
          {:ok, %{acc | evicted: acc.evicted + 1}}

        {:error, _} = error ->
          record(ctx, base ++ [result: error])
          {:skip, acc}
      end
    else
      :leadership_lost
    end
  end

  defp start_node_cooldown(node, ctx) do
    Cooldowns.put_node(ctx.cooldowns, node, ctx.clock.() + ctx.config.node_cooldown_ms)
  end

  ## Taints

  @doc """
  Removes expired and stale cadmium taints. `kube_nodes` is a `Cadmium.Kube.list_nodes/0`
  result; without it only tracked taints can be handled. Returns `:aborted` if
  leadership was lost.
  """
  @spec sweep_taints(ctx(), {:ok, [Cadmium.Kube.Node.t()]} | term()) :: :ok | :aborted
  def sweep_taints(ctx, kube_nodes) do
    cooling = Cooldowns.active(ctx.cooldowns, ctx.clock.()).nodes
    tracked = Cooldowns.tainted(ctx.cooldowns)

    carrying =
      case kube_nodes do
        {:ok, nodes} when is_list(nodes) ->
          for %Cadmium.Kube.Node{} = node <- nodes,
              Policy.cadmium_tainted?(node, ctx.config),
              do: node.name

        _ ->
          []
      end

    # Taints inherited together with their cooldown: ours to remove when it expires.
    for node <- carrying, Map.has_key?(cooling, node), not Map.has_key?(tracked, node) do
      Cooldowns.mark_tainted(ctx.cooldowns, node, false)
    end

    expired =
      for {node, entry} <- tracked, not Map.has_key?(cooling, node), do: {node, entry, :expired}

    stale =
      for node <- carrying,
          not Map.has_key?(cooling, node),
          not Map.has_key?(tracked, node),
          do: {node, %{dry_run?: false, failures: 0}, :stale}

    (Enum.sort(expired) ++ Enum.sort(stale))
    |> Enum.reduce_while(:ok, fn {node, entry, why}, :ok ->
      case remove_taint(node, entry, why, ctx) do
        :leadership_lost -> {:halt, :aborted}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp remove_taint(node, %{dry_run?: true}, _why, ctx) do
    Cooldowns.clear_taint(ctx.cooldowns, node)

    record(ctx,
      type: :untaint,
      node: node,
      dry_run?: true,
      reason: "node cooldown expired"
    )

    :ok
  end

  defp remove_taint(node, entry, why, ctx) do
    if leader?(ctx) do
      key = ctx.config.taint_key
      result = normalise(Safe.kube(fn -> Cadmium.Kube.remove_node_taint(node, key) end))

      reason =
        case why do
          :expired -> "node cooldown expired"
          :stale -> "stale taint left by a previous leader; no active cooldown for this node"
        end

      case result do
        :ok ->
          Cooldowns.clear_taint(ctx.cooldowns, node)
          record(ctx, type: :untaint, node: node, reason: reason, details: %{taint_key: key})

        {:error, _} = error ->
          # Stays (or becomes) tracked, so it is retried next cycle.
          if Cooldowns.taint_removal_failed(ctx.cooldowns, node) == 1 or entry.failures == 0 do
            record(ctx,
              type: :untaint,
              node: node,
              result: error,
              reason: reason <> " (removal failed; will retry every cycle)",
              details: %{taint_key: key}
            )
          end
      end

      :ok
    else
      :leadership_lost
    end
  end

  ## Helpers

  defp leader?(ctx), do: Safe.true?(ctx.leader_fun)

  defp normalise(:ok), do: :ok
  defp normalise({:error, _} = error), do: error
  defp normalise(other), do: {:error, {:unexpected_response, other}}

  defp record(ctx, attrs) do
    attrs =
      if Keyword.get(attrs, :dry_run?, false) and not Keyword.has_key?(attrs, :result),
        do: Keyword.put(attrs, :result, :simulated),
        else: attrs

    attrs =
      case ctx do
        %{actor: actor} when is_binary(actor) -> Keyword.put_new(attrs, :actor, actor)
        _ -> attrs
      end

    AuditLog.record(ctx.audit, attrs)
  end
end
