defmodule Cadmium.Isotope.Supervisor do
  @moduledoc "Supervises the local telemetry sampler and its ring buffers."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end
