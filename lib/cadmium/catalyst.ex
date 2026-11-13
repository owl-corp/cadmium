defmodule Cadmium.Catalyst do
  @moduledoc """
  Safe, disruption-aware rebalancing.

  The agent holding the `Cadmium.Leader` lease runs the coordinator. Every
  `evaluate_interval_ms` it looks at `Cadmium.Valence.nodes/0`; when a node has been hot
  (score >= `hot_threshold`, and at least `spread_threshold` above the coolest node) for
  `sustained_ms`, it picks movable workloads on that node, puts a temporary
  `PreferNoSchedule` taint (`taint_key`) on it, evicts through the Eviction API, and
  removes the taint when the node cooldown expires. Dry-run records what it would have
  done without touching the cluster.

  Events go cluster-wide on `topic/0`:

    * `{:catalyst_action, %Cadmium.Catalyst.Action{}}` - a new audit entry
    * `{:catalyst_status, status()}` - settings/leader/last-plan changed

  Every agent keeps a copy of the audit log and settings, so any agent's dashboard can
  show them and change settings regardless of which agent is leader.

  This module is the public contract. Other subsystems must only call these functions.

  ## Implementation map

    * `Cadmium.Catalyst.Policy` - the pure rules (hot/cool, filtering, ranking)
    * `Cadmium.Catalyst.Planner` - gathers inputs for the policy; `simulate/0`
    * `Cadmium.Catalyst.Executor` - taint/evict/untaint with leadership re-checks
    * `Cadmium.Catalyst.Coordinator` - the leader's evaluation loop and status
    * `Cadmium.Catalyst.Cooldowns` - cooldown and taint bookkeeping (crash-safe)
    * `Cadmium.Catalyst.Settings` - replicated dry-run/enabled switches
    * `Cadmium.Catalyst.AuditLog` - replicated, bounded audit log

  `{:catalyst_status, status}` is announced by each agent's own coordinator to its local
  subscribers, so the `leader?` in it is always about the agent you are connected to.
  """

  alias Cadmium.Catalyst.{Action, AuditLog, Coordinator, Plan, Planner, Safe, Settings}

  @topic "catalyst:events"

  @type status :: %{
          dry_run?: boolean(),
          enabled?: boolean(),
          leader: String.t() | nil,
          leader?: boolean(),
          last_plan: Plan.t() | nil,
          last_evaluated_at: integer() | nil,
          cooldowns: %{nodes: %{String.t() => integer()}, workloads: %{String.t() => integer()}}
        }

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @topic)

  @doc "Current coordinator status as known on this agent. Cooldown values are expiry timestamps (ms)."
  @spec status() :: status()
  def status do
    case Safe.call(fn -> Coordinator.status() end, nil) do
      %{dry_run?: _, leader?: _} = status ->
        status

      _ ->
        settings = Settings.get()

        %{
          dry_run?: settings.dry_run?,
          enabled?: settings.enabled?,
          leader: Safe.call(&Cadmium.Leader.current/0, nil),
          leader?: false,
          last_plan: nil,
          last_evaluated_at: nil,
          cooldowns: %{nodes: %{}, workloads: %{}}
        }
    end
  end

  @spec dry_run?() :: boolean()
  def dry_run?, do: Settings.get().dry_run?

  @doc "Sets dry-run cluster-wide (propagates to all agents) and records an audit entry."
  @spec set_dry_run(boolean()) :: :ok
  def set_dry_run(dry_run?) when is_boolean(dry_run?), do: Settings.put(:dry_run?, dry_run?)

  @doc "Pauses/resumes rebalancing cluster-wide and records an audit entry."
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled?) when is_boolean(enabled?), do: Settings.put(:enabled?, enabled?)

  @doc """
  Requests one immediate spread-only evaluation on the current leader. It skips the
  sustained window but preserves dry-run, cooldowns and disruption safeguards.
  A communication failure may occur after the leader has started the cycle.
  """
  @spec rebalance_now() :: Coordinator.result() | {:error, :leader_unavailable | :request_failed}
  def rebalance_now do
    leader = Cadmium.Leader.current()

    target =
      cond do
        is_nil(leader) -> nil
        leader == Cadmium.node_name() -> node()
        true -> Cadmium.Valence.beam_node_for(leader)
      end

    if target do
      try do
        :erpc.call(target, Coordinator, :rebalance_now, [], 65_000)
      catch
        _, _ -> {:error, :request_failed}
      end
    else
      {:error, :leader_unavailable}
    end
  end

  @doc """
  Computes a plan from the current cluster state right now, with no side effects and
  ignoring the `sustained_ms` requirement. Works on any agent, leader or not.

  Never raises: if live data cannot be read the plan has no moves and its `summary`
  says why. Cooldowns are respected as this agent knows them (its own when it is the
  leader, otherwise the leader's last published ones).
  """
  @spec simulate() :: Plan.t()
  def simulate do
    Planner.simulate(cooldowns: status().cooldowns)
  rescue
    e -> Planner.failed_plan(Exception.message(e))
  catch
    kind, reason -> Planner.failed_plan("#{kind}: #{inspect(reason)}")
  end

  @doc "Up to `limit` most recent audit entries, newest first."
  @spec audit_log(pos_integer()) :: [Action.t()]
  def audit_log(limit \\ 200), do: AuditLog.recent(limit)
end
