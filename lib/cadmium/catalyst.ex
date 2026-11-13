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
  """

  alias Cadmium.Catalyst.{Action, Plan}

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
    %{
      dry_run?: true,
      enabled?: true,
      leader: nil,
      leader?: false,
      last_plan: nil,
      last_evaluated_at: nil,
      cooldowns: %{nodes: %{}, workloads: %{}}
    }
  end

  @spec dry_run?() :: boolean()
  def dry_run?, do: true

  @doc "Sets dry-run cluster-wide (propagates to all agents) and records an audit entry."
  @spec set_dry_run(boolean()) :: :ok
  def set_dry_run(_dry_run?), do: :ok

  @doc "Pauses/resumes rebalancing cluster-wide and records an audit entry."
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(_enabled?), do: :ok

  @doc """
  Computes a plan from the current cluster state right now, with no side effects and
  ignoring the `sustained_ms` requirement. Works on any agent, leader or not.
  """
  @spec simulate() :: Plan.t()
  def simulate do
    %Plan{generated_at: System.system_time(:millisecond), status: :balanced}
  end

  @doc "Up to `limit` most recent audit entries, newest first."
  @spec audit_log(pos_integer()) :: [Action.t()]
  def audit_log(_limit \\ 200), do: []
end
