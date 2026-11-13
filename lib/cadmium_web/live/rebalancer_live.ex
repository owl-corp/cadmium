defmodule CadmiumWeb.RebalancerLive do
  @moduledoc """
  Rebalancer (`/rebalancer`): Catalyst's controls, on-demand simulation, the leader's
  last plan and active cooldowns.

  Leaving dry-run is a two-step action: the first click only reveals a confirmation that
  spells out that pods will really be evicted.
  """
  use CadmiumWeb, :live_view

  import CadmiumWeb.DashboardComponents

  alias CadmiumWeb.Dashboard.{Data, Format}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Rebalancer")
     |> assign(:confirm_live?, false)
     |> assign(:confirm_rebalance?, false)
     |> assign(:rebalance, nil)
     |> assign(:simulation, nil)}
  end

  @impl true
  def handle_event("request_live", _params, socket) do
    {:noreply, assign(socket, :confirm_live?, true)}
  end

  def handle_event("cancel_live", _params, socket) do
    {:noreply, assign(socket, :confirm_live?, false)}
  end

  def handle_event("confirm_live", _params, socket) do
    # Only honoured after the confirmation step was shown in this session.
    if socket.assigns.confirm_live? do
      :ok = Data.set_dry_run(false)
      {:noreply, socket |> assign(:confirm_live?, false) |> refresh_status()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("enable_dry_run", _params, socket) do
    :ok = Data.set_dry_run(true)
    {:noreply, socket |> assign(:confirm_live?, false) |> refresh_status()}
  end

  def handle_event("pause", _params, socket) do
    :ok = Data.set_enabled(false)
    {:noreply, refresh_status(socket)}
  end

  def handle_event("resume", _params, socket) do
    :ok = Data.set_enabled(true)
    {:noreply, refresh_status(socket)}
  end

  def handle_event("simulate", _params, socket) do
    previous = socket.assigns.simulation || %AsyncResult{}

    {:noreply,
     socket
     |> assign(:simulation, AsyncResult.loading(previous))
     |> start_async(:simulate, fn -> Data.simulate() end)}
  end

  def handle_event("request_rebalance", _params, socket) do
    {:noreply, assign(socket, :confirm_rebalance?, true)}
  end

  def handle_event("cancel_rebalance", _params, socket) do
    {:noreply, assign(socket, :confirm_rebalance?, false)}
  end

  def handle_event("confirm_rebalance", _params, socket) do
    if socket.assigns.confirm_rebalance? and
         (is_nil(socket.assigns.rebalance) or is_nil(socket.assigns.rebalance.loading)) do
      {:noreply,
       socket
       |> assign(:confirm_rebalance?, false)
       |> assign(:rebalance, AsyncResult.loading())
       |> start_async(:rebalance, fn -> Data.rebalance_now() end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:rebalance, {:ok, {:ok, plan}}, socket) do
    {:noreply,
     socket
     |> assign(:rebalance, AsyncResult.ok(socket.assigns.rebalance, plan))
     |> refresh_status()}
  end

  def handle_async(:rebalance, {:ok, result}, socket) do
    {:noreply, assign(socket, :rebalance, AsyncResult.failed(socket.assigns.rebalance, result))}
  end

  def handle_async(:rebalance, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :rebalance, AsyncResult.failed(socket.assigns.rebalance, {:exit, reason}))}
  end

  def handle_async(:simulate, {:ok, plan}, socket) do
    {:noreply, assign(socket, :simulation, AsyncResult.ok(socket.assigns.simulation, plan))}
  end

  def handle_async(:simulate, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :simulation, AsyncResult.failed(socket.assigns.simulation, {:exit, reason}))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # The subsystem also broadcasts `{:catalyst_status, _}`; re-reading here just makes the
  # controls reflect the change without waiting for that round trip.
  defp refresh_status(socket), do: assign(socket, :status, Data.status())

  defp active(cooldowns, now) do
    cooldowns
    |> Enum.filter(fn {_name, expiry} -> expiry > now end)
    |> Enum.sort_by(fn {name, expiry} -> {expiry, name} end)
  end

  # ---- rendering ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:node_cooldowns, active(assigns.status.cooldowns.nodes, assigns.now))
      |> assign(:workload_cooldowns, active(assigns.status.cooldowns.workloads, assigns.now))

    ~H"""
    <Layouts.app flash={@flash} active={:rebalancer} status={@status} node_name={@node_name}>
      <div class="grid gap-4 xl:grid-cols-[minmax(0,24rem)_minmax(0,1fr)] xl:items-start">
        <div class="space-y-4">
          <.panel id="controls" title="Controls">
            <dl class="space-y-2 text-xs">
              <div class="flex items-center justify-between gap-3">
                <dt class="text-ink-2">Mode</dt>
                <dd><.mode_badge id="controls-mode" status={@status} /></dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt class="text-ink-2">Leader</dt>
                <dd id="controls-leader" class="text-right">
                  <span :if={@status.leader} class="font-mono text-ink">{@status.leader}</span>
                  <span :if={@status.leader && @status.leader?} class="text-ink-3">
                    (this agent)
                  </span>
                  <span :if={!@status.leader} class="text-ink-3">no leader elected</span>
                </dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt class="text-ink-2">Last evaluation</dt>
                <dd id="controls-evaluated" class="text-ink">
                  <%= if @status.last_evaluated_at do %>
                    {Format.clock(@status.last_evaluated_at)} UTC
                    <span class="text-ink-3">
                      · {Format.ago(@status.last_evaluated_at, @now)}
                    </span>
                  <% else %>
                    <span class="text-ink-3">not yet</span>
                  <% end %>
                </dd>
              </div>
            </dl>

            <div class="mt-3 space-y-3 border-t border-line pt-3">
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-sm font-medium text-ink">Dry-run</p>
                  <p class="text-xs leading-5 text-ink-2">
                    <%= if @status.dry_run? do %>
                      Plans are recorded in the audit log; nothing in the cluster is touched.
                    <% else %>
                      Catalyst is tainting nodes and evicting pods for real.
                    <% end %>
                  </p>
                </div>
                <button
                  :if={@status.dry_run?}
                  id="go-live-btn"
                  type="button"
                  phx-click="request_live"
                  disabled={@confirm_live?}
                  class={[btn(:outline), "shrink-0"]}
                >
                  Go live…
                </button>
                <button
                  :if={!@status.dry_run?}
                  id="dry-run-btn"
                  type="button"
                  phx-click="enable_dry_run"
                  class={[btn(:primary), "shrink-0"]}
                >
                  Switch to dry-run
                </button>
              </div>

              <div
                :if={@confirm_live? and @status.dry_run?}
                id="confirm-live"
                role="alertdialog"
                aria-labelledby="confirm-live-title"
                class="rounded-md border border-danger/50 bg-danger/10 p-3"
              >
                <p
                  id="confirm-live-title"
                  class="flex items-center gap-1.5 text-sm font-semibold text-ink"
                >
                  <.icon name="hero-exclamation-triangle-mini" class="size-4 text-danger" />
                  Evictions will really happen
                </p>
                <p class="mt-1 text-xs leading-5 text-ink-2">
                  In LIVE mode the leader taints hot nodes and evicts pods through the
                  Kubernetes Eviction API, cluster-wide, starting with the next evaluation.
                  Evicting a single-replica workload causes downtime until it restarts.
                  Contents of emptyDir volumes are lost when pods move.
                  PodDisruptionBudgets, replica readiness and cooldowns are still respected.
                </p>
                <div class="mt-2.5 flex flex-wrap gap-2">
                  <button
                    id="confirm-live-btn"
                    type="button"
                    phx-click="confirm_live"
                    class={btn(:danger)}
                  >
                    Yes, leave dry-run
                  </button>
                  <button
                    id="cancel-live-btn"
                    type="button"
                    phx-click="cancel_live"
                    class={btn(:outline)}
                  >
                    Stay in dry-run
                  </button>
                </div>
              </div>

              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-sm font-medium text-ink">Rebalancing</p>
                  <p class="text-xs leading-5 text-ink-2">
                    <%= if @status.enabled? do %>
                      The leader evaluates the cluster on every interval.
                    <% else %>
                      Paused cluster-wide: no evaluations, no actions.
                    <% end %>
                  </p>
                </div>
                <button
                  :if={@status.enabled?}
                  id="pause-btn"
                  type="button"
                  phx-click="pause"
                  class={[btn(:outline), "shrink-0"]}
                >
                  <.icon name="hero-pause-micro" class="size-3.5" /> Pause
                </button>
                <button
                  :if={!@status.enabled?}
                  id="resume-btn"
                  type="button"
                  phx-click="resume"
                  class={[btn(:primary), "shrink-0"]}
                >
                  <.icon name="hero-play-micro" class="size-3.5" /> Resume
                </button>
              </div>
            </div>
          </.panel>

          <.panel id="cooldowns" title="Active cooldowns">
            <%= if @node_cooldowns == [] and @workload_cooldowns == [] do %>
              <p id="cooldowns-empty" class="text-xs leading-5 text-ink-3">
                Nothing is cooling down. After Catalyst acts on a node or a workload it
                leaves it alone for a while; those timers appear here.
              </p>
            <% else %>
              <.cooldown_list id="cooldowns-nodes" title="Nodes" entries={@node_cooldowns} now={@now} />
              <.cooldown_list
                id="cooldowns-workloads"
                title="Workloads"
                entries={@workload_cooldowns}
                now={@now}
              />
            <% end %>
          </.panel>
        </div>

        <div class="min-w-0 space-y-4">
          <.panel id="simulation" title="Simulation">
            <:actions>
              <button
                id="simulate-btn"
                type="button"
                phx-click="simulate"
                disabled={@simulation != nil and @simulation.loading != nil}
                class={btn(:primary)}
              >
                <.icon
                  name="hero-arrow-path-micro"
                  class={[
                    "size-3.5",
                    @simulation && @simulation.loading && "motion-safe:animate-spin"
                  ]}
                /> Simulate now
              </button>
            </:actions>
            <%= cond do %>
              <% @simulation == nil -> %>
                <p id="simulation-idle" class="text-xs leading-5 text-ink-2">
                  Computes a plan from the cluster as it is right now, ignoring the
                  sustained-pressure wait. It has no side effects in either mode and works
                  on any agent, leader or not.
                </p>
              <% @simulation.ok? -> %>
                <.plan id="simulation-plan" plan={@simulation.result} now={@now} />
              <% @simulation.failed -> %>
                <p id="simulation-failed" class="text-xs font-medium text-danger">
                  The simulation crashed: {inspect(@simulation.failed)}
                </p>
              <% true -> %>
                <p id="simulation-loading" class="text-xs text-ink-3">Simulating…</p>
            <% end %>
          </.panel>

          <.panel id="manual-rebalance" title="Lower-threshold rebalance">
            <p class="text-xs leading-5 text-ink-2">
              Run one evaluation using the configured spread threshold without requiring a hot
              score or sustained wait. Single-replica workloads may be evicted, causing downtime;
              emptyDir contents are lost.
              Dry-run, cooldowns, disruption budgets and other safety checks still apply.
            </p>
            <button
              id="request-rebalance-btn"
              type="button"
              phx-click="request_rebalance"
              disabled={@confirm_rebalance? or (@rebalance && @rebalance.loading != nil)}
              class={[btn(:outline), "mt-3"]}
            >
              Rebalance now…
            </button>
            <div
              :if={@confirm_rebalance?}
              id="confirm-rebalance"
              role="alertdialog"
              aria-labelledby="confirm-rebalance-title"
              class="mt-3 rounded-md border border-danger/50 bg-danger/10 p-3"
            >
              <p id="confirm-rebalance-title" class="text-sm font-semibold text-ink">
                Confirm lower-threshold rebalance
              </p>
              <p class="mt-1 text-xs leading-5 text-ink-2">
                In live mode this may taint nodes and evict pods immediately, even when no node
                is hot. Single-replica workloads may experience downtime, and emptyDir contents
                are lost. The leader runs one cycle; normal thresholds remain unchanged.
              </p>
              <div class="mt-2.5 flex flex-wrap gap-2">
                <button
                  id="confirm-rebalance-btn"
                  type="button"
                  phx-click="confirm_rebalance"
                  class={btn(:danger)}
                >
                  Run one cycle
                </button>
                <button
                  id="cancel-rebalance-btn"
                  type="button"
                  phx-click="cancel_rebalance"
                  class={btn(:outline)}
                >
                  Cancel
                </button>
              </div>
            </div>
            <%= if @rebalance && @rebalance.loading do %>
              <p id="rebalance-loading" class="mt-3 text-xs text-ink-3">Running evaluation…</p>
            <% end %>
            <%= if @rebalance && @rebalance.ok? do %>
              <div class="mt-3">
                <.plan id="rebalance-plan" plan={@rebalance.result} now={@now} />
              </div>
            <% end %>
            <%= if @rebalance && @rebalance.failed do %>
              <p id="rebalance-failed" class="mt-3 text-xs text-danger">
                Request failed or was skipped: {inspect(@rebalance.failed)}. If the connection
                failed, the cycle may still have run; check the audit log before retrying.
              </p>
            <% end %>
          </.panel>

          <.panel id="last-plan" title="Leader's last plan">
            <%= if @status.last_plan do %>
              <.plan id="last-plan-view" plan={@status.last_plan} now={@now} />
            <% else %>
              <p id="last-plan-empty" class="text-xs leading-5 text-ink-3">
                The leader has not evaluated the cluster yet, or no agent holds the lease.
              </p>
            <% end %>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :entries, :list, required: true
  attr :now, :integer, required: true

  defp cooldown_list(assigns) do
    ~H"""
    <div :if={@entries != []} id={@id} class="mb-3 last:mb-0">
      <h3 class="mb-1 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-3">
        {@title} · {length(@entries)}
      </h3>
      <ul class="divide-y divide-line rounded border border-line">
        <li
          :for={{name, expiry} <- @entries}
          class="flex items-center justify-between gap-3 px-2.5 py-1.5 text-xs"
          data-cooldown={name}
        >
          <span class="truncate font-mono text-ink" title={name}>{name}</span>
          <span class="shrink-0 text-ink-2">
            <span class="font-semibold text-ink">{Format.duration(expiry - @now)}</span> left
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp btn(variant) do
    [
      "inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-md border px-2.5 text-xs font-semibold",
      "transition-colors disabled:cursor-not-allowed disabled:opacity-50",
      case variant do
        :primary -> "border-ink bg-ink text-surface hover:bg-ink/85"
        :outline -> "border-line-strong bg-surface text-ink hover:bg-sunken"
        :danger -> "border-danger bg-danger text-surface hover:bg-danger/85"
      end
    ]
  end
end
