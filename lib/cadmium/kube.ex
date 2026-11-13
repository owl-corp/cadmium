defmodule Cadmium.Kube do
  @moduledoc """
  Facade over the configured `Cadmium.Kube.Client` implementation
  (`config :cadmium, :kube_client`). All Kubernetes access goes through here.
  """

  def client, do: Application.get_env(:cadmium, :kube_client, Cadmium.Kube.HTTP)

  def list_pods(opts \\ []), do: client().list_pods(opts)
  def list_nodes, do: client().list_nodes()
  def list_pdbs, do: client().list_pdbs()

  def workload_replicas(namespace, kind, name),
    do: client().workload_replicas(namespace, kind, name)

  def evict_pod(namespace, name, opts \\ []), do: client().evict_pod(namespace, name, opts)
  def add_node_taint(node, taint), do: client().add_node_taint(node, taint)
  def remove_node_taint(node, key), do: client().remove_node_taint(node, key)
  def get_lease(namespace, name), do: client().get_lease(namespace, name)
  def create_lease(lease), do: client().create_lease(lease)
  def update_lease(lease), do: client().update_lease(lease)
end
