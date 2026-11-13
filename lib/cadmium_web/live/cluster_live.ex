defmodule CadmiumWeb.ClusterLive do
  @moduledoc """
  Cluster heatmap (`/`) and node detail panel (`/nodes/:name`).

  One tile per `%Cadmium.Valence.NodeScore{}`, hottest first, kept live from
  `{:cluster_updated, scores}`. The detail panel adds the node's score history, its
  workloads (fetched async from the agent on that node) and - only for the node serving
  this page - the raw local Isotope series, kept live from `{:isotope_sample, sample}`.
  """
  use CadmiumWeb, :live_view

  import CadmiumWeb.DashboardComponents

  alias CadmiumWeb.Dashboard.{Data, Format}
  alias Phoenix.LiveView.AsyncResult

  # A score older than this is dimmed; Valence drops the node entirely a little later.
  @stale_after_ms 10_000
  @tile_history 60
  @detail_history 120
  @isotope_history 120
  @detail_refresh_ms 5_000

  @isotope_series [
    %{key: :psi_cpu_some, label: "CPU pressure", hint: "PSI some, avg10", unit: :psi, floor: 5},
    %{
      key: :psi_memory_some,
      label: "Memory pressure",
      hint: "PSI some, avg10",
      unit: :psi,
      floor: 5
    },
    %{
      key: :psi_memory_full,
      label: "Memory stall",
      hint: "PSI full, avg10",
      unit: :psi,
      floor: 5
    },
    %{key: :psi_io_some, label: "IO pressure", hint: "PSI some, avg10", unit: :psi, floor: 5},
    %{
      key: :cpu_throttled_ratio,
      label: "CPU throttled",
      hint: "CFS periods throttled",
      unit: :ratio,
      max: 1
    },
    %{key: :cpu_usage_ratio, label: "CPU usage", hint: "busy, all cores", unit: :ratio, max: 1},
    %{
      key: :memory_used_ratio,
      label: "Memory used",
      hint: "of host memory",
      unit: :ratio,
      max: 1
    },
    %{
      key: :major_faults_per_s,
      label: "Major faults",
      hint: "per second",
      unit: :count,
      floor: 10
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cadmium.Valence.subscribe()
      Cadmium.Isotope.subscribe()
      Process.send_after(self(), :refresh_detail, @detail_refresh_ms)
    end

    nodes = Data.nodes()

    histories =
      Map.new(nodes, fn node ->
        {node.k8s_node, node.k8s_node |> Data.history(@tile_history) |> Enum.map(&point/1)}
      end)

    {:ok,
     socket
     |> assign(:page_title, "Cluster")
     |> assign(:hot_threshold, hot_threshold())
     |> assign(:isotope_series, @isotope_series)
     |> assign(:nodes, sort(nodes))
     |> assign(:histories, histories)
     |> assign(:selected, nil)
     |> assign(:detail_history, [])
     |> assign(:isotope, [])
     |> assign(:node_workloads, AsyncResult.ok([]))}
  end

  @impl true
  def handle_params(%{"name" => name}, _uri, %{assigns: %{live_action: :show}} = socket) do
    local? = name == socket.assigns.node_name

    socket =
      socket
      |> assign(:page_title, name)
      |> assign(:selected, name)
      |> assign(:detail_history, Data.history(name, @detail_history))
      |> assign(:isotope, if(local?, do: Data.isotope_history(@isotope_history), else: []))
      |> assign(:node_workloads, AsyncResult.loading())
      |> load_node_workloads()

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Cluster")
     |> assign(:selected, nil)
     |> assign(:detail_history, [])
     |> assign(:isotope, [])}
  end

  defp load_node_workloads(%{assigns: %{selected: nil}} = socket), do: socket

  defp load_node_workloads(socket) do
    if connected?(socket) do
      name = socket.assigns.selected
      start_async(socket, :node_workloads, fn -> {name, Data.workloads_on_node(name)} end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:node_workloads, {:ok, {name, workloads}}, socket) do
    if name == socket.assigns.selected do
      sorted = Enum.sort_by(workloads, &(&1.cpu_drift || -1.0), :desc)
      {:noreply, assign(socket, :node_workloads, AsyncResult.ok(sorted))}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:node_workloads, {:exit, reason}, socket) do
    result = AsyncResult.failed(socket.assigns.node_workloads, {:exit, reason})
    {:noreply, assign(socket, :node_workloads, result)}
  end

  @impl true
  def handle_info({:cluster_updated, scores}, socket) when is_list(scores) do
    histories =
      Map.new(scores, fn score ->
        history = Map.get(socket.assigns.histories, score.k8s_node, [])
        {score.k8s_node, append_point(history, point(score), @tile_history)}
      end)

    detail_history =
      case Enum.find(scores, &(&1.k8s_node == socket.assigns.selected)) do
        nil -> socket.assigns.detail_history
        score -> append_score(socket.assigns.detail_history, score, @detail_history)
      end

    {:noreply,
     socket
     |> assign(:nodes, sort(scores))
     |> assign(:histories, histories)
     |> assign(:detail_history, detail_history)}
  end

  def handle_info({:isotope_sample, sample}, socket) do
    if socket.assigns.selected == socket.assigns.node_name do
      isotope = Enum.take(socket.assigns.isotope ++ [sample], -@isotope_history)
      {:noreply, assign(socket, :isotope, isotope)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_detail, socket) do
    Process.send_after(self(), :refresh_detail, @detail_refresh_ms)
    {:noreply, load_node_workloads(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---- helpers ----------------------------------------------------------------

  defp sort(nodes), do: Enum.sort_by(nodes, &{-&1.score, &1.k8s_node})

  defp point(score), do: {score.ts, score.score}

  defp append_point(history, {ts, _} = point, limit) do
    case List.last(history) do
      {last_ts, _} when last_ts >= ts -> history
      _ -> Enum.take(history ++ [point], -limit)
    end
  end

  defp append_score(history, score, limit) do
    case List.last(history) do
      %{ts: last_ts} when last_ts >= score.ts -> history
      _ -> Enum.take(history ++ [score], -limit)
    end
  end

  defp hot_threshold do
    :cadmium |> Application.get_env(Cadmium.Catalyst, []) |> Keyword.get(:hot_threshold, 70.0)
  end

  defp stale?(score, now), do: now - score.ts > @stale_after_ms

  defp cooldown_left(status, name, now) do
    case status.cooldowns.nodes do
      %{^name => expiry} when expiry > now -> expiry - now
      _ -> nil
    end
  end

  defp series_values(samples, key), do: Enum.map(samples, &Map.get(&1, key))

  defp series_latest(samples, series) do
    value = samples |> List.last() |> Map.get(series.key)

    case series.unit do
      :psi -> Format.psi(value)
      :ratio -> Format.percent(value)
      :count -> if(value, do: Format.decimal(value, 1) <> "/s", else: "–")
    end
  end

  # ---- rendering ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :selected_score,
        Enum.find(assigns.nodes, &(&1.k8s_node == assigns.selected))
      )

    ~H"""
    <Layouts.app flash={@flash} active={:cluster} status={@status} node_name={@node_name}>
      <.summary_strip nodes={@nodes} status={@status} node_name={@node_name} now={@now} />

      <div class={[
        "mt-4 gap-4",
        @selected && "lg:grid lg:grid-cols-[minmax(0,1fr)_minmax(22rem,30rem)] lg:items-start"
      ]}>
        <aside
          :if={@selected}
          id="node-detail"
          data-node={@selected}
          class="mb-4 lg:sticky lg:top-16 lg:order-2 lg:mb-0 lg:max-h-[calc(100vh-5rem)] lg:overflow-y-auto"
        >
          <.node_detail
            name={@selected}
            score={@selected_score}
            history={@detail_history}
            workloads={@node_workloads}
            isotope={@isotope}
            isotope_series={@isotope_series}
            local?={@selected == @node_name}
            leader?={@selected == @status.leader}
            stale?={@selected_score != nil and stale?(@selected_score, @now)}
            threshold={@hot_threshold}
            now={@now}
          />
        </aside>

        <section id="heatmap" class="min-w-0">
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <h1 class="text-xs font-semibold uppercase tracking-wider text-ink-2">
              Node pressure · hottest first
            </h1>
            <.heat_legend />
          </div>

          <div
            :if={@nodes == []}
            class="rounded-lg border border-dashed border-line-strong bg-surface"
          >
            <.empty_state id="cluster-empty" icon="hero-signal-slash" title="No nodes in the mesh yet">
              Agents publish a pressure score every couple of seconds once they join the mesh.
              This agent ({@node_name}) has not heard from any node, including itself.
            </.empty_state>
          </div>

          <div
            :if={@nodes != []}
            id="node-grid"
            class="grid grid-cols-[repeat(auto-fill,minmax(13.5rem,1fr))] gap-2"
          >
            <.node_tile
              :for={node <- @nodes}
              node={node}
              history={Map.get(@histories, node.k8s_node, [])}
              selected?={node.k8s_node == @selected}
              local?={node.k8s_node == @node_name}
              leader?={node.k8s_node == @status.leader}
              cooldown={cooldown_left(@status, node.k8s_node, @now)}
              stale?={stale?(node, @now)}
              now={@now}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :nodes, :list, required: true
  attr :status, :map, required: true
  attr :node_name, :string, required: true
  attr :now, :integer, required: true

  defp summary_strip(assigns) do
    ~H"""
    <dl
      id="cluster-summary"
      class="grid grid-cols-2 divide-line overflow-hidden rounded-lg border border-line bg-surface sm:grid-cols-3 xl:grid-cols-[auto_auto_auto_auto_auto_minmax(0,1fr)] xl:divide-x"
    >
      <.summary_item id="summary-nodes" label="Mesh nodes">
        <span class="text-lg font-semibold leading-6">{length(@nodes)}</span>
      </.summary_item>
      <.summary_item id="summary-self" label="Served from">
        <span class="font-mono text-sm">{@node_name}</span>
      </.summary_item>
      <.summary_item id="summary-leader" label="Leader">
        <span :if={@status.leader} class="font-mono text-sm">{@status.leader}</span>
        <span :if={!@status.leader} class="text-sm text-ink-3">no leader elected</span>
      </.summary_item>
      <.summary_item id="summary-mode" label="Mode">
        <.mode_badge id="summary-mode-badge" status={@status} />
      </.summary_item>
      <.summary_item id="summary-evaluated" label="Last evaluation">
        <span :if={@status.last_evaluated_at} class="text-sm">
          {Format.clock(@status.last_evaluated_at)}
          <span class="text-ink-3">· {Format.ago(@status.last_evaluated_at, @now)}</span>
        </span>
        <span :if={!@status.last_evaluated_at} class="text-sm text-ink-3">not yet</span>
      </.summary_item>
      <.summary_item id="summary-plan" label="Last plan">
        <%= if @status.last_plan do %>
          <span class="flex min-w-0 items-center gap-2">
            <.badge tone={elem(Format.plan_status(@status.last_plan.status), 1)}>
              {elem(Format.plan_status(@status.last_plan.status), 0)}
            </.badge>
            <.link
              navigate={~p"/rebalancer"}
              class="truncate text-sm text-ink-2 hover:text-ink hover:underline"
              title={@status.last_plan.summary}
            >
              {@status.last_plan.summary}
            </.link>
          </span>
        <% else %>
          <span class="text-sm text-ink-3">no plan yet</span>
        <% end %>
      </.summary_item>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp summary_item(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 px-3 py-2">
      <dt class="text-[0.6875rem] font-medium uppercase tracking-wider text-ink-3">{@label}</dt>
      <dd class="mt-0.5 flex min-h-6 min-w-0 items-center text-ink">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :history, :list, required: true
  attr :selected?, :boolean, required: true
  attr :local?, :boolean, required: true
  attr :leader?, :boolean, required: true
  attr :stale?, :boolean, required: true
  attr :cooldown, :any, required: true
  attr :now, :integer, required: true

  defp node_tile(assigns) do
    ~H"""
    <.link
      id={"node-#{Format.dom_id(@node.k8s_node)}"}
      patch={~p"/nodes/#{@node.k8s_node}"}
      data-node={@node.k8s_node}
      data-score={Format.score(@node.score)}
      data-heat={Format.heat_level(@node.score)}
      data-stale={to_string(@stale?)}
      aria-current={@selected? && "true"}
      class={[
        "heat-surface group relative flex flex-col gap-2 rounded-lg border p-2.5",
        "transition duration-150 hover:-translate-y-px hover:shadow-md focus-visible:outline-2 focus-visible:outline-ink",
        Format.heat_class(@node.score),
        @selected? && "ring-2 ring-ink",
        @stale? && "opacity-50 saturate-50"
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <span class="truncate font-mono text-xs font-medium text-ink" title={@node.k8s_node}>
          {@node.k8s_node}
        </span>
        <span class="flex shrink-0 flex-wrap justify-end gap-1">
          <.badge :if={@leader?} tone={:info} data-badge="leader">Leader</.badge>
          <.badge :if={@local?} tone={:neutral} data-badge="self">This node</.badge>
        </span>
      </div>

      <div class="flex items-end justify-between gap-3">
        <div>
          <div class="text-4xl font-semibold leading-none tracking-tight text-ink">
            {Format.score(@node.score)}
          </div>
          <div class="mt-1 flex items-center gap-1 text-[0.6875rem] font-medium uppercase tracking-wide text-ink-2">
            <span class="size-2 rounded-full bg-heat" aria-hidden="true"></span>
            {Format.heat_label(@node.score)}
          </div>
        </div>
        <.sparkline
          values={Enum.map(@history, &elem(&1, 1))}
          max={100}
          class="h-9 w-24 text-ink/70"
          label={"Recent score history for #{@node.k8s_node}"}
        />
      </div>

      <div class="space-y-0.5">
        <.component_bar label="cpu" value={@node.components.cpu} />
        <.component_bar label="mem" value={@node.components.memory} />
        <.component_bar label="io" value={@node.components.io} />
      </div>

      <div class="flex items-center justify-between gap-2 text-[0.6875rem] text-ink-2">
        <span>{@node.pod_count} pods</span>
        <.badge :if={@cooldown} tone={:warn} data-badge="cooldown">
          Cooling {Format.duration(@cooldown)}
        </.badge>
        <span :if={@stale?} data-badge="stale" class="font-medium text-ink">
          stale · {Format.ago(@node.ts, @now)}
        </span>
      </div>
    </.link>
    """
  end

  attr :name, :string, required: true
  attr :score, :any, required: true
  attr :history, :list, required: true
  attr :workloads, AsyncResult, required: true
  attr :isotope, :list, required: true
  attr :isotope_series, :list, required: true
  attr :local?, :boolean, required: true
  attr :leader?, :boolean, required: true
  attr :stale?, :boolean, required: true
  attr :threshold, :any, required: true
  attr :now, :integer, required: true

  defp node_detail(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class={[
        "rounded-lg border p-3",
        if(@score,
          do: ["heat-surface", Format.heat_class(@score.score)],
          else: "border-line bg-surface"
        )
      ]}>
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <p class="text-[0.6875rem] font-medium uppercase tracking-wider text-ink-2">Node</p>
            <h2 id="node-detail-name" class="truncate font-mono text-base font-semibold text-ink">
              {@name}
            </h2>
          </div>
          <.link
            id="node-detail-close"
            patch={~p"/"}
            class="rounded p-1 text-ink-2 transition-colors hover:bg-ink/10 hover:text-ink"
            aria-label="Close node detail"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.link>
        </div>

        <%= if @score do %>
          <div class="mt-2 flex flex-wrap items-end gap-x-4 gap-y-2">
            <div class="flex items-baseline gap-2">
              <span id="node-detail-score" class="text-4xl font-semibold leading-none text-ink">
                {Format.decimal(@score.score, 1)}
              </span>
              <span class="flex items-center gap-1 text-xs font-medium uppercase tracking-wide text-ink-2">
                <span class="size-2 rounded-full bg-heat" aria-hidden="true"></span>
                {Format.heat_label(@score.score)}
              </span>
            </div>
            <div class="flex flex-wrap gap-1">
              <.badge :if={@leader?} tone={:info}>Leader</.badge>
              <.badge :if={@local?} tone={:neutral}>This node</.badge>
              <.badge :if={@stale?} tone={:warn}>Stale</.badge>
            </div>
            <span class="ml-auto text-xs text-ink-2">
              {@score.pod_count} pods · updated {Format.ago(@score.ts, @now)}
            </span>
          </div>
          <div class="mt-3 grid gap-x-4 gap-y-0.5 sm:grid-cols-3 lg:grid-cols-1 xl:grid-cols-3">
            <.component_bar label="cpu" value={@score.components.cpu} />
            <.component_bar label="mem" value={@score.components.memory} />
            <.component_bar label="io" value={@score.components.io} />
          </div>
        <% else %>
          <p id="node-detail-missing" class="mt-2 text-sm text-ink-2">
            This node is not in the mesh right now. It may have gone stale, been drained,
            or never run a Cadmium agent.
          </p>
        <% end %>
      </div>

      <.panel id="node-history" title="Score history">
        <.score_chart id="node-history-chart" scores={@history} threshold={@threshold} />
      </.panel>

      <.panel id="node-workloads" title="Workloads on this node" body_class="">
        <:actions>
          <span :if={@workloads.ok?} class="text-xs text-ink-3">
            {length(@workloads.result)} pods
          </span>
        </:actions>
        <%= cond do %>
          <% @workloads.ok? and @workloads.result == [] -> %>
            <.empty_state id="node-workloads-empty" icon="hero-cube" title="No workloads reported">
              The agent on this node returned no pods, or it could not be reached.
            </.empty_state>
          <% @workloads.ok? -> %>
            <div class="overflow-x-auto">
              <table class="w-full text-left text-xs">
                <thead class="text-[0.6875rem] uppercase tracking-wider text-ink-3">
                  <tr class="border-b border-line">
                    <th class="px-3 py-1.5 font-medium">Pod</th>
                    <th class="px-2 py-1.5 font-medium">CPU drift</th>
                    <th class="px-2 py-1.5 font-medium">Mem drift</th>
                    <th class="px-3 py-1.5 text-right font-medium">Thr.</th>
                  </tr>
                </thead>
                <tbody id="node-workloads-rows" class="divide-y divide-line">
                  <tr :for={workload <- @workloads.result} id={"node-wl-#{workload.pod.uid}"}>
                    <td class="max-w-36 py-1.5 pl-3 pr-1">
                      <div class="truncate font-mono text-ink" title={workload.pod.name}>
                        {workload.pod.name}
                      </div>
                      <div class="truncate text-ink-3">{workload.pod.namespace}</div>
                    </td>
                    <td class="px-2 py-1.5">
                      <.drift_bar ratio={workload.cpu_drift} compact />
                      <div class="mt-0.5 text-ink-3">
                        {Format.cpu(workload.sample && workload.sample.cpu_usage_millis)} of {Format.cpu(
                          workload.pod.cpu_request_millis
                        )}
                      </div>
                    </td>
                    <td class="px-2 py-1.5">
                      <.drift_bar ratio={workload.memory_drift} compact />
                      <div class="mt-0.5 text-ink-3">
                        {Format.bytes(workload.sample && workload.sample.memory_bytes)} of {Format.bytes(
                          workload.pod.memory_request_bytes
                        )}
                      </div>
                    </td>
                    <td class="px-3 py-1.5 text-right text-ink">
                      {Format.percent(workload.sample && workload.sample.cpu_throttled_ratio)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% @workloads.failed -> %>
            <.empty_state
              id="node-workloads-failed"
              icon="hero-exclamation-triangle"
              title="Could not reach the agent on this node"
            >
              Retrying every few seconds.
            </.empty_state>
          <% true -> %>
            <p id="node-workloads-loading" class="px-3 py-6 text-center text-xs text-ink-3">
              <.icon name="hero-arrow-path" class="mr-1 size-3.5 motion-safe:animate-spin" />
              Asking the agent on {@name}…
            </p>
        <% end %>
      </.panel>

      <.panel :if={@local?} id="node-isotope" title="Local kernel telemetry · live">
        <%= if @isotope == [] do %>
          <.empty_state id="node-isotope-empty" icon="hero-cpu-chip" title="No samples yet">
            Isotope has not produced a sample on this host. Raw samples never leave the node,
            so they are only shown for the node serving this page.
          </.empty_state>
        <% else %>
          <div class="grid grid-cols-2 gap-x-4 gap-y-3">
            <div :for={series <- @isotope_series} id={"isotope-#{series.key}"}>
              <div class="flex items-baseline justify-between gap-2">
                <span class="truncate text-xs font-medium text-ink">{series.label}</span>
                <span class="text-sm font-semibold text-ink" data-latest>
                  {series_latest(@isotope, series)}
                </span>
              </div>
              <.sparkline
                values={series_values(@isotope, series.key)}
                max={series[:max]}
                floor={series[:floor] || 1}
                class="mt-1 h-8 w-full text-ink-2"
                label={series.label}
              />
              <div class="text-[0.625rem] text-ink-3">{series.hint}</div>
            </div>
          </div>
        <% end %>
      </.panel>

      <p :if={!@local?} id="node-isotope-remote" class="px-1 text-xs leading-5 text-ink-3">
        Raw kernel telemetry stays on each host. Port-forward to the agent on
        <span class="font-mono">{@name}</span>
        to see its PSI and throttling series.
      </p>
    </div>
    """
  end
end
