defmodule Cadmium.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CadmiumWeb.Telemetry,
        {Phoenix.PubSub, name: Cadmium.PubSub}
      ] ++ subsystems() ++ [CadmiumWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cadmium.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Subsystems are skipped in the test env (config :cadmium, start_subsystems: false)
  # so tests can start the pieces they need under their own supervision.
  defp subsystems do
    if Application.get_env(:cadmium, :start_subsystems, true) do
      [Cadmium.Isotope.Supervisor, Cadmium.Valence.Supervisor, Cadmium.Catalyst.Supervisor]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CadmiumWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
