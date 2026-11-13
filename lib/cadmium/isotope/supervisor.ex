defmodule Cadmium.Isotope.Supervisor do
  @moduledoc """
  Supervises the local telemetry sampler and its ring buffers.

  The ring buffer has its own owner process, so samples survive a sampler restart.

  Options override `config :cadmium, Cadmium.Isotope` and are passed on to
  `Cadmium.Isotope.Sampler` (`:source`, `:interval_ms`, `:history_size`, `:table`, ...).
  `:name` names the supervisor and `:sampler_name` the sampler.
  """
  use Supervisor

  alias Cadmium.Isotope
  alias Cadmium.Isotope.{RingBuffer, Sampler}

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:cadmium, Isotope, []), opts)
    {sampler_name, opts} = Keyword.pop(opts, :sampler_name, Sampler)
    table = Keyword.get(opts, :table, Isotope.table())

    children = [
      {RingBuffer, name: table, capacity: Keyword.get(opts, :history_size, 600)},
      {Sampler, Keyword.merge(opts, name: sampler_name, table: table)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
