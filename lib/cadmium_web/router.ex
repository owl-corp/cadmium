defmodule CadmiumWeb.Router do
  use CadmiumWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CadmiumWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Kubernetes liveness/readiness probes: no pipeline, no content negotiation.
  scope "/", CadmiumWeb do
    get "/healthz", HealthController, :show
  end

  scope "/", CadmiumWeb do
    pipe_through :browser

    live_session :dashboard, on_mount: CadmiumWeb.DashboardHooks do
      live "/", ClusterLive, :index
      live "/nodes/:name", ClusterLive, :show
      live "/workloads", WorkloadsLive, :index
      live "/rebalancer", RebalancerLive, :index
      live "/audit", AuditLive, :index
    end
  end
end
