defmodule CadmiumWeb.Dashboard.Data do
  @moduledoc """
  The dashboard's only door to the rest of Cadmium.

  LiveViews never call `Cadmium.Valence`, `Cadmium.Workloads`, `Cadmium.Catalyst` or
  `Cadmium.Isotope` directly for data; they call the functions here, which delegate to
  a backing module implementing this behaviour:

    * `CadmiumWeb.Dashboard.Data.Live` - the real subsystem facades (default)
    * `CadmiumWeb.Dashboard.Data.Demo` - synthetic data for looking at the UI locally,
      selected by starting the server with `CADMIUM_DASHBOARD_FIXTURES=1` (dev only)
    * anything set with `config :cadmium, :dashboard_data, SomeModule` - tests install
      `CadmiumWeb.DashboardFixtures` this way

  PubSub subscriptions are not part of this behaviour: LiveViews subscribe through the
  subsystem contracts (`Cadmium.Valence.subscribe/0` etc.) whichever backend is active.
  """

  alias Cadmium.Catalyst.{Action, Plan}
  alias Cadmium.Isotope.NodeSample
  alias Cadmium.Valence.NodeScore
  alias Cadmium.Workload

  @callback node_name() :: String.t()
  @callback nodes() :: [NodeScore.t()]
  @callback history(String.t(), pos_integer()) :: [NodeScore.t()]
  @callback workloads() :: [Workload.t()]
  @callback workloads_on_node(String.t()) :: [Workload.t()]
  @callback isotope_history(pos_integer()) :: [NodeSample.t()]
  @callback status() :: Cadmium.Catalyst.status()
  @callback simulate() :: Plan.t()
  @callback rebalance_now() :: Cadmium.Catalyst.Coordinator.result() | {:error, atom()}
  @callback audit_log(pos_integer()) :: [Action.t()]
  @callback set_dry_run(boolean()) :: :ok
  @callback set_enabled(boolean()) :: :ok

  @doc "The backing module currently in use."
  @spec impl() :: module()
  def impl do
    case Application.get_env(:cadmium, :dashboard_data) do
      nil -> if demo?(), do: __MODULE__.Demo, else: __MODULE__.Live
      module -> module
    end
  end

  @doc "True when the dev-only `CADMIUM_DASHBOARD_FIXTURES` switch is on."
  @spec demo?() :: boolean()
  def demo?, do: System.get_env("CADMIUM_DASHBOARD_FIXTURES") in ~w(1 true)

  def node_name, do: impl().node_name()
  def nodes, do: impl().nodes()
  def history(k8s_node, limit \\ 120), do: impl().history(k8s_node, limit)
  def workloads, do: impl().workloads()
  def workloads_on_node(k8s_node), do: impl().workloads_on_node(k8s_node)
  def isotope_history(limit \\ 120), do: impl().isotope_history(limit)
  def status, do: impl().status()
  def simulate, do: impl().simulate()
  def rebalance_now, do: impl().rebalance_now()
  def audit_log(limit \\ 200), do: impl().audit_log(limit)
  def set_dry_run(dry_run?), do: impl().set_dry_run(dry_run?)
  def set_enabled(enabled?), do: impl().set_enabled(enabled?)
end
