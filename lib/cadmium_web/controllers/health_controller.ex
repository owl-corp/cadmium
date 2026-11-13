defmodule CadmiumWeb.HealthController do
  @moduledoc "Liveness/readiness endpoint for Kubernetes probes."
  use CadmiumWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", node: Cadmium.node_name()})
  end
end
