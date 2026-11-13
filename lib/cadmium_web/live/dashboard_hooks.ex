defmodule CadmiumWeb.DashboardHooks do
  @moduledoc """
  `on_mount` hook shared by every dashboard LiveView.

  Assigns what the shell needs on every page and keeps it fresh:

    * `:node_name` - the Kubernetes node serving this dashboard
    * `:status`    - `Cadmium.Catalyst.status/0`, replaced on `{:catalyst_status, status}`
    * `:now`       - wall clock in ms, ticked once a second while connected so that
                     countdowns, "x ago" labels and staleness dimming stay current

  The hook subscribes to the Catalyst topic, so LiveViews also receive
  `{:catalyst_action, action}` in their own `handle_info/2`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias CadmiumWeb.Dashboard.Data

  @tick_ms 1_000

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Cadmium.Catalyst.subscribe()
      :timer.send_interval(@tick_ms, self(), :dashboard_tick)
    end

    socket =
      socket
      |> assign(:node_name, Data.node_name())
      |> assign(:status, Data.status())
      |> assign(:now, System.system_time(:millisecond))
      |> attach_hook(:dashboard_shell, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_info(:dashboard_tick, socket) do
    {:halt, assign(socket, :now, System.system_time(:millisecond))}
  end

  defp handle_info({:catalyst_status, status}, socket) when is_map(status) do
    {:halt, assign(socket, :status, status)}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
