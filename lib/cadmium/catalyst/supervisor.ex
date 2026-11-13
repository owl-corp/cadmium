defmodule Cadmium.Catalyst.Supervisor do
  @moduledoc """
  Supervises leader election, settings, the audit log and the coordinator.

  Start order matters: the lease first, then the state the coordinator reads and writes
  (settings, audit log, cooldowns), then the coordinator itself.

  The strategy is `:one_for_one` on purpose. The children share no links or pids - they
  find each other by name on every use and treat an absent sibling as "skip" - so
  restarting one must not wipe the others:

    * a coordinator crash must not lose cooldowns (that is what prevents a repeat
      eviction) or the audit log;
    * a `Cadmium.Leader` crash must not reset runtime settings such as a dry-run switch
      an operator just flipped.

  The one dependency that matters across restarts is handled explicitly: if the
  cooldown table is recreated, the coordinator notices (`Cooldowns.instance/1`) and
  starts its sustained-window tracking over instead of acting on stale assumptions.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Cadmium.Leader,
      Cadmium.Catalyst.Settings,
      Cadmium.Catalyst.AuditLog,
      Cadmium.Catalyst.Cooldowns,
      Cadmium.Catalyst.Coordinator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
