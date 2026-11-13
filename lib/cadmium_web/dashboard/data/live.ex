defmodule CadmiumWeb.Dashboard.Data.Live do
  @moduledoc "Dashboard data straight from the Cadmium subsystem contracts."

  @behaviour CadmiumWeb.Dashboard.Data

  @impl true
  def node_name, do: Cadmium.node_name()

  @impl true
  def nodes, do: Cadmium.Valence.nodes()

  @impl true
  def history(k8s_node, limit), do: Cadmium.Valence.history(k8s_node, limit)

  @impl true
  def workloads, do: Cadmium.Workloads.cluster()

  @impl true
  def workloads_on_node(k8s_node), do: Cadmium.Workloads.on_node(k8s_node)

  @impl true
  def isotope_history(limit), do: Cadmium.Isotope.history(limit)

  @impl true
  def status, do: Cadmium.Catalyst.status()

  @impl true
  def simulate, do: Cadmium.Catalyst.simulate()

  @impl true
  def rebalance_now, do: Cadmium.Catalyst.rebalance_now()

  @impl true
  def audit_log(limit), do: Cadmium.Catalyst.audit_log(limit)

  @impl true
  def set_dry_run(dry_run?), do: Cadmium.Catalyst.set_dry_run(dry_run?)

  @impl true
  def set_enabled(enabled?), do: Cadmium.Catalyst.set_enabled(enabled?)
end
