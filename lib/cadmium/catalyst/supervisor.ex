defmodule Cadmium.Catalyst.Supervisor do
  @moduledoc "Supervises leader election, settings, the audit log and the coordinator."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end
