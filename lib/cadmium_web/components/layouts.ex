defmodule CadmiumWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CadmiumWeb, :html

  import CadmiumWeb.DashboardComponents, only: [mode_badge: 1]

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @tabs [
    {:cluster, "Cluster", "hero-squares-2x2-micro"},
    {:workloads, "Workloads", "hero-scale-micro"},
    {:rebalancer, "Rebalancer", "hero-arrows-right-left-micro"},
    {:audit, "Audit log", "hero-queue-list-micro"}
  ]

  @doc """
  Renders the dashboard shell: brand, section tabs, rebalancer mode, the node this
  dashboard is served from, and the theme toggle.

  ## Examples

      <Layouts.app flash={@flash} active={:cluster} status={@status} node_name={@node_name}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the active tab"
  attr :status, :map, default: nil, doc: "Cadmium.Catalyst.status/0, for the mode badge"
  attr :node_name, :string, default: nil, doc: "the Kubernetes node serving this page"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <header class="sticky top-0 z-20 border-b border-line bg-surface/95 backdrop-blur">
      <div class="mx-auto flex max-w-[110rem] flex-wrap items-center gap-x-4 gap-y-1 px-3 sm:px-5">
        <.link navigate={~p"/"} id="brand" class="flex items-center gap-2 py-2">
          <span
            class="flex size-7 flex-col items-center justify-center rounded border border-ink bg-ink text-surface"
            aria-hidden="true"
          >
            <span class="text-[0.4375rem] font-medium leading-none opacity-70">48</span>
            <span class="text-[0.75rem] font-bold leading-none">Cd</span>
          </span>
          <span class="text-sm font-semibold tracking-tight text-ink">Cadmium</span>
        </.link>

        <nav
          id="main-nav"
          class="order-last -mb-px flex w-full gap-1 overflow-x-auto md:order-none md:w-auto"
        >
          <.link
            :for={{key, label, icon} <- @tabs}
            id={"nav-#{key}"}
            navigate={tab_path(key)}
            aria-current={@active == key && "page"}
            class={[
              "flex items-center gap-1.5 whitespace-nowrap border-b-2 px-2.5 py-2.5 text-sm transition-colors",
              if(@active == key,
                do: "border-ink font-semibold text-ink",
                else: "border-transparent text-ink-2 hover:border-line-strong hover:text-ink"
              )
            ]}
          >
            <.icon name={icon} class="size-4" />
            {label}
          </.link>
        </nav>

        <div class="ml-auto flex items-center gap-3 py-1.5">
          <.mode_badge :if={@status} id="nav-mode" status={@status} />
          <span
            :if={@node_name}
            id="nav-node"
            class="hidden items-center gap-1 text-xs text-ink-2 sm:flex"
            title="Kubernetes node serving this dashboard"
          >
            <.icon name="hero-server-micro" class="size-3.5 text-ink-3" />
            <span class="font-mono">{@node_name}</span>
          </span>
          <.theme_toggle />
        </div>
      </div>
    </header>

    <main class="mx-auto max-w-[110rem] px-3 py-4 sm:px-5">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp tab_path(:cluster), do: ~p"/"
  defp tab_path(:workloads), do: ~p"/workloads"
  defp tab_path(:rebalancer), do: ~p"/rebalancer"
  defp tab_path(:audit), do: ~p"/audit"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="relative flex flex-row items-center rounded-full border border-line bg-sunken"
    >
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-line-strong bg-surface transition-[left] [[data-theme=dark]_&]:left-2/3 [[data-theme=light]_&]:left-1/3" />

      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "Use system theme"},
            {"light", "hero-sun-micro", "Use light theme"},
            {"dark", "hero-moon-micro", "Use dark theme"}
          ]
        }
        type="button"
        class="relative flex w-1/3 cursor-pointer px-1.5 py-1 text-ink-2 hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end
end
