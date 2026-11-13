defmodule CadmiumWeb.AuditLive do
  @moduledoc """
  Audit log (`/audit`): everything Catalyst did, or would have done in dry-run,
  newest first. New entries are prepended live from `{:catalyst_action, action}`.
  Filters (`type`, `mode`) live in the URL.
  """
  use CadmiumWeb, :live_view

  import CadmiumWeb.DashboardComponents

  alias Cadmium.Catalyst.Action
  alias CadmiumWeb.Dashboard.{Data, Format}

  @limit 200

  # URL value => {label, action types it covers}
  @type_filters [
    {"all", "All", nil},
    {"evict", "Evictions", [:evict]},
    {"taint", "Taints", [:taint, :untaint]},
    {"leader", "Leadership", [:leader_acquired, :leader_lost]},
    {"settings", "Settings", [:settings_changed]}
  ]
  @mode_filters [{"all", "All"}, {"live", "Live"}, {"dry", "Dry-run"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:type_filters, @type_filters)
     |> assign(:mode_filters, @mode_filters)
     |> assign(:limit, @limit)
     |> stream_configure(:actions, dom_id: &"action-#{Format.dom_id(&1.id)}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    type = if Enum.any?(@type_filters, &(elem(&1, 0) == params["type"])), do: params["type"]
    mode = if params["mode"] in ~w(live dry), do: params["mode"]

    socket = socket |> assign(:type, type || "all") |> assign(:mode, mode || "all")
    actions = Enum.filter(Data.audit_log(@limit), &matches?(&1, socket.assigns))

    {:noreply,
     socket
     |> assign(:count, length(actions))
     |> stream(:actions, actions, reset: true)}
  end

  @impl true
  def handle_info({:catalyst_action, %Action{} = action}, socket) do
    if matches?(action, socket.assigns) do
      {:noreply,
       socket
       |> update(:count, &min(&1 + 1, @limit))
       |> stream_insert(:actions, action, at: 0, limit: @limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp matches?(action, %{type: type, mode: mode}) do
    {_, _, types} = List.keyfind(@type_filters, type, 0)

    (types == nil or action.type in types) and
      case mode do
        "live" -> not action.dry_run?
        "dry" -> action.dry_run?
        _ -> true
      end
  end

  defp page_path(type, mode) do
    query =
      Enum.reject([type: type, mode: mode], fn {_key, value} -> value == "all" end)

    ~p"/audit?#{query}"
  end

  # ---- rendering ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:audit} status={@status} node_name={@node_name}>
      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2">
        <div>
          <h1 class="text-base font-semibold text-ink">Audit log</h1>
          <p class="mt-0.5 text-xs text-ink-2">
            <span id="audit-count" class="font-semibold text-ink">{@count}</span>
            {if @count == 1, do: "entry", else: "entries"}, newest first · updates live ·
            last {@limit} kept in view
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <div
            id="audit-type-filter"
            class="flex overflow-hidden rounded-md border border-line-strong"
            role="group"
            aria-label="Filter by type"
          >
            <.link
              :for={{value, label, _types} <- @type_filters}
              id={"audit-type-#{value}"}
              patch={page_path(value, @mode)}
              aria-pressed={to_string(@type == value)}
              class={segment_class(@type == value)}
            >
              {label}
            </.link>
          </div>
          <div
            id="audit-mode-filter"
            class="flex overflow-hidden rounded-md border border-line-strong"
            role="group"
            aria-label="Filter by mode"
          >
            <.link
              :for={{value, label} <- @mode_filters}
              id={"audit-mode-#{value}"}
              patch={page_path(@type, value)}
              aria-pressed={to_string(@mode == value)}
              class={segment_class(@mode == value)}
            >
              {label}
            </.link>
          </div>
        </div>
      </div>

      <div class="mt-3 overflow-x-auto rounded-lg border border-line bg-surface">
        <table id="audit-table" class="w-full min-w-[56rem] text-left text-xs">
          <thead class="bg-sunken text-[0.6875rem] uppercase tracking-wider text-ink-2">
            <tr class="border-b border-line">
              <th class="px-3 py-2 font-medium">Time (UTC)</th>
              <th class="px-3 py-2 font-medium">Action</th>
              <th class="px-3 py-2 font-medium">Target</th>
              <th class="px-3 py-2 font-medium">Reason</th>
              <th class="px-3 py-2 font-medium">Result</th>
              <th class="px-3 py-2 font-medium">Actor</th>
            </tr>
          </thead>
          <tbody id="audit-actions" phx-update="stream" class="divide-y divide-line">
            <tr
              :for={{id, action} <- @streams.actions}
              id={id}
              data-type={action.type}
              data-dry-run={to_string(action.dry_run?)}
              class="align-top transition-colors hover:bg-sunken/70"
            >
              <td class="whitespace-nowrap px-3 py-1.5">
                <time datetime={Format.iso(action.ts)} class="text-ink">
                  {Format.clock(action.ts)}
                </time>
                <span class="text-ink-3">{Format.date(action.ts)}</span>
                <div
                  id={"#{id}-ago"}
                  phx-hook=".RelativeTime"
                  phx-update="ignore"
                  data-ts={action.ts}
                  class="text-ink-3"
                >
                  {Format.ago(action.ts, @now)}
                </div>
              </td>
              <td class="whitespace-nowrap px-3 py-1.5">
                <.badge tone={elem(Format.action_type(action.type), 1)}>
                  {elem(Format.action_type(action.type), 0)}
                </.badge>
                <.badge :if={action.dry_run?} tone={:info} data-marker="dry-run" class="ml-1">
                  Dry-run
                </.badge>
              </td>
              <td class="whitespace-nowrap px-3 py-1.5">
                <.target action={action} />
              </td>
              <td class="max-w-md px-3 py-1.5 text-ink-2">{action.reason || "–"}</td>
              <td class="px-3 py-1.5">
                <.result result={action.result} />
              </td>
              <td class="whitespace-nowrap px-3 py-1.5 font-mono text-ink-2">
                {action.actor || "–"}
              </td>
            </tr>
          </tbody>
        </table>
        <div :if={@count == 0}>
          <.empty_state
            id="audit-empty"
            icon="hero-queue-list"
            title={
              if(@type == "all" and @mode == "all",
                do: "No rebalancing actions yet",
                else: "No actions match this filter"
              )
            }
          >
            Evictions, taints, leadership changes and settings changes show up here the
            moment they happen - including what Catalyst would have done while in dry-run.
          </.empty_state>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".RelativeTime">
        const format = (ms) => {
          const s = Math.max(Math.floor(ms / 1000), 0)
          if (s < 2) return "just now"
          if (s < 60) return `${s}s ago`
          if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s ago`
          if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ago`
          return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h ago`
        }

        export default {
          mounted() {
            this.render()
            this.timer = setInterval(() => this.render(), 1000)
          },
          destroyed() {
            clearInterval(this.timer)
          },
          render() {
            this.el.textContent = format(Date.now() - Number(this.el.dataset.ts))
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp segment_class(active?) do
    [
      "border-r border-line-strong px-2.5 py-1 text-xs transition-colors last:border-r-0",
      if(active?,
        do: "bg-ink font-semibold text-surface",
        else: "bg-surface text-ink-2 hover:bg-sunken hover:text-ink"
      )
    ]
  end

  attr :action, Action, required: true

  defp target(assigns) do
    ~H"""
    <div :if={@action.pod} class="font-mono text-ink">
      <span class="text-ink-3">{@action.namespace}/</span>{@action.pod}
    </div>
    <div :if={@action.node} class="font-mono text-ink-2">
      <span :if={@action.pod} class="font-sans text-ink-3">on</span>
      <.link navigate={~p"/nodes/#{@action.node}"} class="hover:text-ink hover:underline">
        {@action.node}
      </.link>
    </div>
    <span :if={!@action.pod and !@action.node} class="text-ink-3">cluster</span>
    """
  end

  attr :result, :any, required: true

  defp result(%{result: :ok} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 font-medium text-ink" data-result="ok">
      <.icon name="hero-check-circle-micro" class="size-3.5 text-ok" /> ok
    </span>
    """
  end

  defp result(%{result: :simulated} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 text-ink-2" data-result="simulated">
      <.icon name="hero-beaker-micro" class="size-3.5 text-brand" /> simulated
    </span>
    """
  end

  defp result(%{result: {:error, reason}} = assigns) do
    assigns = assign(assigns, :message, if(is_binary(reason), do: reason, else: inspect(reason)))

    ~H"""
    <span class="inline-flex items-start gap-1 font-medium text-ink" data-result="error">
      <.icon name="hero-x-circle-micro" class="mt-px size-3.5 shrink-0 text-danger" />
      <span>error <span class="font-normal text-ink-2">— {@message}</span></span>
    </span>
    """
  end

  defp result(assigns) do
    ~H"""
    <span class="text-ink-2" data-result="other">{inspect(@result)}</span>
    """
  end
end
