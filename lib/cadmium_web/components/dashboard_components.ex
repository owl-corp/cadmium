defmodule CadmiumWeb.DashboardComponents do
  @moduledoc """
  Function components shared by the dashboard LiveViews: badges, panels, heat chips,
  hand-rolled SVG sparklines/charts, drift bars and the plan view.
  """
  use CadmiumWeb, :html

  alias Cadmium.Catalyst.Plan
  alias CadmiumWeb.Dashboard.Format

  # ---- small building blocks ------------------------------------------------

  attr :tone, :atom, default: :neutral, values: [:neutral, :info, :ok, :warn, :danger, :live]
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 whitespace-nowrap rounded border px-1.5 py-px",
        "text-[0.6875rem] font-semibold uppercase leading-4 tracking-wide",
        tone_class(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tone_class(:neutral), do: "border-line-strong bg-sunken text-ink-2"
  defp tone_class(:info), do: "border-brand/40 bg-brand/10 text-brand"
  defp tone_class(:ok), do: "border-ok/40 bg-ok/10 text-ok"
  defp tone_class(:warn), do: "border-warn/50 bg-warn/10 text-warn"
  defp tone_class(:danger), do: "border-danger/40 bg-danger/10 text-danger"
  defp tone_class(:live), do: "border-danger bg-danger text-surface"

  @doc "DRY-RUN / LIVE badge, preceded by PAUSED when the rebalancer is disabled."
  attr :status, :map, required: true
  attr :id, :string, required: true

  def mode_badge(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1">
      <.badge :if={!@status.enabled?} id={"#{@id}-paused"} tone={:warn}>
        <.icon name="hero-pause-micro" class="size-3" /> Paused
      </.badge>
      <.badge :if={@status.dry_run?} id={"#{@id}-dry-run"} tone={:info}>Dry-run</.badge>
      <.badge :if={!@status.dry_run?} id={"#{@id}-live"} tone={:live}>Live</.badge>
    </span>
    """
  end

  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :body_class, :any, default: "p-3"
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-lg border border-line bg-surface", @class]}>
      <header
        :if={@title}
        class="flex min-h-9 items-center justify-between gap-2 border-b border-line px-3 py-1.5"
      >
        <h2 class="text-xs font-semibold uppercase tracking-wider text-ink-2">{@title}</h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center gap-1 px-4 py-10 text-center">
      <.icon name={@icon} class="mb-1 size-6 text-ink-3" />
      <p class="text-sm font-medium text-ink">{@title}</p>
      <p :if={@inner_block != []} class="max-w-md text-xs leading-5 text-ink-3">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc "A node name with its score, tinted by heat. Links to the node detail panel."
  attr :score, :map, required: true, doc: "a %NodeScore{}"
  attr :id, :string, default: nil

  def node_chip(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={~p"/nodes/#{@score.k8s_node}"}
      class={[
        "heat-chip inline-flex items-center gap-1.5 rounded border px-1.5 py-0.5 text-xs",
        "transition-shadow hover:shadow-sm",
        Format.heat_class(@score.score)
      ]}
    >
      <span class="size-2 rounded-full bg-heat" aria-hidden="true"></span>
      <span class="font-mono text-ink">{@score.k8s_node}</span>
      <span class="font-semibold text-ink">{Format.score(@score.score)}</span>
      <span class="text-ink-2">{Format.heat_label(@score.score)}</span>
    </.link>
    """
  end

  @doc "The heat scale legend."
  attr :id, :string, default: "heat-legend"

  def heat_legend(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[0.6875rem] text-ink-3">
      <span :for={{level, label, range} <- Format.heat_legend()} class={"heat-#{level}"}>
        <span class="mr-1 inline-block size-2 rounded-sm bg-heat align-middle" aria-hidden="true">
        </span>{label}
        <span class="text-ink-3/80">{range}</span>
      </span>
    </div>
    """
  end

  # ---- charts -----------------------------------------------------------------

  @doc """
  A sparkline: an inline SVG polyline over an evenly spaced series.

  The line is drawn in `currentColor`, so the caller picks the colour with a text class.
  `max: nil` auto-scales to the series, but never below `floor` so that noise on a
  near-zero series does not look like a spike.
  """
  attr :values, :list, required: true
  attr :min, :any, default: 0
  attr :max, :any, default: nil
  attr :floor, :any, default: 1
  attr :class, :any, default: "h-8 w-full text-ink-2"
  attr :label, :string, default: nil
  attr :rest, :global

  def sparkline(assigns) do
    values = Enum.filter(assigns.values, &is_number/1)
    top = assigns.max || Enum.max([assigns.floor | values])
    span = max(top - assigns.min, 1.0e-9)
    count = length(values)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        x = if count > 1, do: index / (count - 1) * 100, else: 100.0
        y = 29 - min(max((value - assigns.min) / span, 0.0), 1.0) * 28
        {Float.round(x * 1.0, 2), Float.round(y * 1.0, 2)}
      end)

    line = Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end)

    assigns =
      assigns
      |> assign(:line, line)
      |> assign(:area, if(count > 1, do: "0,30 #{line} 100,30"))
      |> assign(:count, count)
      |> assign(:last, List.last(points))

    ~H"""
    <svg
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      class={@class}
      role="img"
      aria-label={@label}
      data-points={@count}
      {@rest}
    >
      <line
        x1="0"
        y1="29.5"
        x2="100"
        y2="29.5"
        stroke="currentColor"
        stroke-opacity="0.25"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
      <polygon :if={@area} points={@area} fill="currentColor" fill-opacity="0.12" />
      <polyline
        :if={@count > 1}
        points={@line}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
      <line
        :if={@count == 1}
        x1="96"
        y1={elem(@last, 1)}
        x2="100"
        y2={elem(@last, 1)}
        stroke="currentColor"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  @doc """
  Score history for one node: a 0..100 line chart over heat-tinted bands, with the
  rebalancer's hot threshold drawn as a dashed rule. Axis labels are HTML so they stay
  crisp while the SVG stretches to the panel width.
  """
  attr :id, :string, required: true
  attr :scores, :list, required: true, doc: "[%NodeScore{}], oldest first"
  attr :threshold, :any, default: 70.0

  def score_chart(assigns) do
    scores = assigns.scores
    count = length(scores)

    points =
      scores
      |> Enum.with_index()
      |> Enum.map(fn {score, index} ->
        x = if count > 1, do: index / (count - 1) * 100, else: 100.0
        {Float.round(x * 1.0, 2), Float.round(100 - clamp(score.score) * 1.0, 2), score}
      end)

    step = if count > 1, do: 100 / (count - 1), else: 100.0

    assigns =
      assigns
      |> assign(:count, count)
      |> assign(:points, points)
      |> assign(:step, step)
      |> assign(:line, Enum.map_join(points, " ", fn {x, y, _} -> "#{x},#{y}" end))
      |> assign(:first, List.first(scores))
      |> assign(:last, List.last(scores))
      |> assign(:bands, for(level <- 0..4, do: {level, band_bottom(level), band_top(level)}))

    ~H"""
    <figure id={@id} class="select-none" data-points={@count}>
      <div class="flex gap-2">
        <div class="relative h-36 w-6 shrink-0 text-[0.625rem] text-ink-3">
          <span class="absolute right-0 top-0 -translate-y-1/2">100</span>
          <span class="absolute right-0 -translate-y-1/2" style={"top: #{100 - @threshold}%"}>
            {Format.score(@threshold)}
          </span>
          <span class="absolute bottom-0 right-0 translate-y-1/2">0</span>
        </div>
        <div class="relative h-36 min-w-0 flex-1 overflow-hidden rounded border border-line">
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" class="absolute inset-0 size-full">
            <%!-- heat bands, hottest on top: y = 100 - score --%>
            <rect
              :for={{level, from, to} <- @bands}
              x="0"
              y={100 - to}
              width="100"
              height={to - from}
              class={"heat-#{level} fill-heat"}
              fill-opacity="0.09"
              data-band={"#{from}-#{to}"}
            />
            <line
              x1="0"
              x2="100"
              y1={100 - @threshold}
              y2={100 - @threshold}
              class="stroke-ink-3"
              stroke-width="1"
              stroke-dasharray="4 3"
              vector-effect="non-scaling-stroke"
            />
            <polyline
              :if={@count > 1}
              points={@line}
              fill="none"
              class="stroke-ink"
              stroke-width="2"
              stroke-linejoin="round"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
            <%!-- per-sample hover targets: full-height slices carrying a native tooltip --%>
            <rect
              :for={{x, _y, score} <- @points}
              x={x - @step / 2}
              y="0"
              width={@step}
              height="100"
              class="fill-ink opacity-0 hover:opacity-10"
            >
              <title>{Format.clock(score.ts)} UTC · score {Format.decimal(score.score, 1)}</title>
            </rect>
          </svg>
          <p
            :if={@count < 2}
            class="absolute inset-0 flex items-center justify-center text-xs text-ink-3"
          >
            Collecting score history…
          </p>
        </div>
      </div>
      <figcaption class="mt-1 flex justify-between pl-8 text-[0.625rem] text-ink-3">
        <span>{@first && Format.clock(@first.ts)}</span>
        <span>dashed: hot threshold {Format.score(@threshold)}</span>
        <span>{@last && Format.clock(@last.ts)} UTC</span>
      </figcaption>
    </figure>
    """
  end

  defp clamp(value), do: value |> max(0.0) |> min(100.0)

  defp band_bottom(0), do: 0
  defp band_bottom(1), do: 25
  defp band_bottom(2), do: 50
  defp band_bottom(3), do: 70
  defp band_bottom(4), do: 85

  defp band_top(4), do: 100
  defp band_top(level), do: band_bottom(level + 1)

  @doc "A labelled 0..100 meter in the heat colour of its own value."
  attr :label, :string, required: true
  attr :value, :any, required: true

  def component_bar(assigns) do
    ~H"""
    <div
      class={["flex items-center gap-1.5 text-[0.6875rem]", Format.heat_class(@value)]}
      title={"#{@label} pressure #{Format.score(@value)}"}
    >
      <span class="w-7 shrink-0 text-ink-2">{@label}</span>
      <span class="h-1.5 min-w-0 flex-1 overflow-hidden rounded-full bg-ink/10">
        <span class="block h-full rounded-full bg-heat" style={"width: #{meter(@value)}%"}></span>
      </span>
      <span class="w-5 shrink-0 text-right text-ink">{Format.score(@value)}</span>
    </div>
    """
  end

  defp meter(value) when is_number(value), do: value |> max(0) |> min(100) |> round()
  defp meter(_), do: 0

  @doc """
  Request-vs-reality drift on a log scale centred on 1.0x.

  Bars growing left (cool) mean the pod uses less than it requested - over-requested.
  Bars growing right (warm to hot) mean it uses more than it requested - under-requested.
  The scale is clamped at 1/4x and 4x.
  """
  attr :ratio, :any, required: true
  attr :id, :string, default: nil
  attr :compact, :boolean, default: false

  def drift_bar(%{ratio: nil} = assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-2" data-direction="none">
      <div class={[
        "h-3 shrink-0 rounded-sm border border-dashed border-line-strong",
        if(@compact, do: "w-14", else: "w-24")
      ]}>
      </div>
      <span class="text-xs text-ink-3">no request</span>
    </div>
    """
  end

  def drift_bar(assigns) do
    ratio = max(assigns.ratio, 0.001)
    log = :math.log2(ratio) |> max(-2.0) |> min(2.0)
    width = Float.round(abs(log) / 2 * 50, 1)

    {direction, heat, left} =
      cond do
        ratio > 1.05 -> {"over", over_heat(ratio), 50.0}
        ratio < 0.95 -> {"under", 0, 50.0 - width}
        true -> {"even", 1, 50.0}
      end

    assigns =
      assign(assigns, width: width, direction: direction, heat: heat, left: left, ratio: ratio)

    ~H"""
    <div
      id={@id}
      class={["flex items-center gap-2", "heat-#{@heat}"]}
      data-direction={@direction}
      title={drift_title(@direction, @ratio)}
    >
      <div class={[
        "relative h-3 shrink-0 rounded-sm bg-ink/[0.07]",
        if(@compact, do: "w-14", else: "w-24")
      ]}>
        <span
          class="absolute inset-y-0 rounded-sm bg-heat"
          style={"left: #{@left}%; width: #{@width}%"}
        >
        </span>
        <span class="absolute -inset-y-0.5 left-1/2 w-px bg-ink" data-mark="1.0x"></span>
      </div>
      <span class="w-10 text-xs font-semibold text-ink">{Format.ratio(@ratio)}</span>
    </div>
    """
  end

  defp over_heat(ratio) when ratio >= 3, do: 4
  defp over_heat(ratio) when ratio >= 1.5, do: 3
  defp over_heat(_ratio), do: 2

  defp drift_title("over", ratio),
    do: "Using #{Format.ratio(ratio)} its request - under-requested"

  defp drift_title("under", ratio),
    do: "Using #{Format.ratio(ratio)} its request - over-requested"

  defp drift_title(_, _ratio), do: "Using about what it requested"

  # ---- plan -----------------------------------------------------------------

  @doc "Renders a `%Cadmium.Catalyst.Plan{}`: status, hot/cool nodes, moves, rejections."
  attr :id, :string, required: true
  attr :plan, Plan, required: true
  attr :now, :integer, required: true

  def plan(assigns) do
    {label, tone} = Format.plan_status(assigns.plan.status)

    rejected =
      assigns.plan.rejected
      |> Enum.group_by(fn {_workload, reason} -> reason end, fn {workload, _} -> workload end)
      |> Enum.sort_by(fn {reason, workloads} -> {-length(workloads), reason} end)

    assigns = assign(assigns, label: label, tone: tone, rejected: rejected)

    ~H"""
    <div id={@id} class="space-y-4" data-status={@plan.status}>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <.badge id={"#{@id}-status"} tone={@tone}>{@label}</.badge>
        <p id={"#{@id}-summary"} class="text-sm text-ink">
          {if @plan.summary in [nil, ""], do: "No summary.", else: @plan.summary}
        </p>
        <span class="ml-auto text-xs text-ink-3">
          {Format.clock(@plan.generated_at)} UTC · {Format.ago(@plan.generated_at, @now)}
        </span>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <div id={"#{@id}-hot"}>
          <h3 class="mb-1.5 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-3">
            {if(@plan.spread_only?, do: "Source nodes", else: "Hot nodes")} · {length(@plan.hot)}
          </h3>
          <div class="flex flex-wrap gap-1.5">
            <.node_chip :for={score <- @plan.hot} score={score} />
            <span :if={@plan.hot == []} class="text-xs text-ink-3">None above threshold.</span>
          </div>
        </div>
        <div id={"#{@id}-cool"}>
          <h3 class="mb-1.5 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-3">
            {if(@plan.spread_only?, do: "Destination nodes", else: "Cool nodes")} · {length(
              @plan.cool
            )}
          </h3>
          <div class="flex flex-wrap gap-1.5">
            <.node_chip :for={score <- @plan.cool} score={score} />
            <span :if={@plan.cool == []} class="text-xs text-ink-3">None with headroom.</span>
          </div>
        </div>
      </div>

      <div id={"#{@id}-moves"}>
        <h3 class="mb-1.5 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-3">
          Proposed moves · {length(@plan.moves)}
        </h3>
        <p :if={@plan.moves == []} class="text-xs text-ink-3">No evictions proposed.</p>
        <ul :if={@plan.moves != []} class="divide-y divide-line rounded border border-line">
          <li
            :for={move <- @plan.moves}
            class="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 px-2.5 py-1.5 text-xs"
            data-move={move.workload.pod.name}
          >
            <span class="font-mono text-ink">
              <span class="text-ink-3">{move.workload.pod.namespace}/</span>{move.workload.pod.name}
            </span>
            <span class="text-ink-2">
              evict from <span class="font-mono text-ink">{move.from_node}</span>
            </span>
            <span :if={move.reason} class="text-ink-2">— {move.reason}</span>
          </li>
        </ul>
      </div>

      <div id={"#{@id}-rejected"}>
        <h3 class="mb-1.5 text-[0.6875rem] font-semibold uppercase tracking-wider text-ink-3">
          Rejected candidates · {length(@plan.rejected)}
        </h3>
        <p :if={@rejected == []} class="text-xs text-ink-3">No candidates were rejected.</p>
        <div class="space-y-2">
          <details
            :for={{reason, workloads} <- @rejected}
            id={"#{@id}-rejected-#{reason}"}
            class="group rounded border border-line"
            open={length(workloads) <= 6}
          >
            <summary class="flex cursor-pointer flex-wrap items-baseline gap-x-2 px-2.5 py-1.5 text-xs marker:text-ink-3">
              <span class="font-semibold text-ink">{elem(Format.rejection(reason), 0)}</span>
              <span class="rounded-full bg-sunken px-1.5 text-ink-2">{length(workloads)}</span>
              <span class="text-ink-2">{elem(Format.rejection(reason), 1)}</span>
            </summary>
            <ul class="flex flex-wrap gap-x-4 gap-y-0.5 border-t border-line px-2.5 py-1.5 font-mono text-[0.6875rem] text-ink-2">
              <li :for={workload <- workloads}>
                <span class="text-ink-3">{workload.pod.namespace}/</span>{workload.pod.name}
                <span class="text-ink-3">@{workload.k8s_node}</span>
              </li>
            </ul>
          </details>
        </div>
      </div>
    </div>
    """
  end
end
