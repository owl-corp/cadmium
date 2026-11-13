defmodule CadmiumWeb.WorkloadsLive do
  @moduledoc """
  Workload drift (`/workloads`): what each pod requested versus what it actually uses.

  `Cadmium.Workloads.cluster/0` is an RPC fan-out, so it is always loaded with
  `start_async/3` - never in `mount/3` - and refreshed every few seconds while connected.
  Sort, filters and search live in the URL. The full result stays in memory for
  filtering, but only the first `@max_rows` matching rows are rendered (as a stream).
  """
  use CadmiumWeb, :live_view

  import CadmiumWeb.DashboardComponents

  alias CadmiumWeb.Dashboard.{Data, Format}

  @refresh_ms 5_000
  @max_rows 200

  # column key => {default direction, value function}
  @sorts %{
    "pod" => {:asc, &__MODULE__.pod_key/1},
    "node" => {:asc, &__MODULE__.node_key/1},
    "owner" => {:asc, &__MODULE__.owner_key/1},
    "cpu_req" => {:desc, &__MODULE__.cpu_request/1},
    "cpu" => {:desc, &__MODULE__.cpu_actual/1},
    "cpu_drift" => {:desc, &__MODULE__.cpu_drift/1},
    "mem_req" => {:desc, &__MODULE__.memory_request/1},
    "mem" => {:desc, &__MODULE__.memory_actual/1},
    "mem_drift" => {:desc, &__MODULE__.memory_drift/1},
    "throttled" => {:desc, &__MODULE__.throttled/1},
    "psi_mem" => {:desc, &__MODULE__.psi_memory/1}
  }
  @default_sort "cpu_drift"

  @doc false
  def pod_key(w), do: {w.pod.namespace, w.pod.name}
  @doc false
  def node_key(w), do: w.k8s_node
  @doc false
  def owner_key(w), do: if(w.pod.owner_name, do: {w.pod.owner_kind || "", w.pod.owner_name})
  @doc false
  def cpu_request(w), do: w.pod.cpu_request_millis
  @doc false
  def cpu_actual(w), do: w.sample && w.sample.cpu_usage_millis
  @doc false
  def cpu_drift(w), do: w.cpu_drift
  @doc false
  def memory_request(w), do: w.pod.memory_request_bytes
  @doc false
  def memory_actual(w), do: w.sample && w.sample.memory_bytes
  @doc false
  def memory_drift(w), do: w.memory_drift
  @doc false
  def throttled(w), do: w.sample && w.sample.cpu_throttled_ratio
  @doc false
  def psi_memory(w), do: w.sample && w.sample.psi_memory_some

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Workload drift")
      |> assign(:max_rows, @max_rows)
      |> assign(:all, [])
      |> assign(:loaded?, false)
      |> assign(:loading?, false)
      |> assign(:load_failed?, false)
      |> assign(:updated_at, nil)
      |> assign(:matching, 0)
      |> assign(:shown, 0)
      |> assign(:namespaces, [])
      |> assign(:node_names, [])
      |> stream_configure(:workloads, dom_id: &"wl-#{&1.pod.uid}")
      |> stream(:workloads, [])

    socket =
      if connected?(socket) do
        Process.send_after(self(), :refresh, @refresh_ms)
        load(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sort = if Map.has_key?(@sorts, params["sort"]), do: params["sort"], else: @default_sort
    {default_dir, _} = Map.fetch!(@sorts, sort)

    dir =
      case params["dir"] do
        "asc" -> :asc
        "desc" -> :desc
        _ -> default_dir
      end

    filters = %{
      "ns" => string_param(params["ns"]),
      "node" => string_param(params["node"]),
      "q" => string_param(params["q"])
    }

    {:noreply,
     socket
     |> assign(:sort, sort)
     |> assign(:dir, dir)
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters))
     |> apply_view()}
  end

  defp string_param(value) when is_binary(value), do: String.trim(value)
  defp string_param(_), do: ""

  @impl true
  def handle_event("filter", params, socket) do
    filters = Map.merge(socket.assigns.filters, Map.take(params, ~w(ns node q)))

    {:noreply,
     push_patch(socket,
       to: page_path(socket.assigns.sort, socket.assigns.dir, filters),
       replace: true
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:workloads, {:ok, workloads}, socket) do
    {:noreply,
     socket
     |> assign(:all, workloads)
     |> assign(:loaded?, true)
     |> assign(:loading?, false)
     |> assign(:load_failed?, false)
     |> assign(:updated_at, System.system_time(:millisecond))
     |> assign(
       :namespaces,
       workloads |> Enum.map(& &1.pod.namespace) |> Enum.uniq() |> Enum.sort()
     )
     |> assign(:node_names, workloads |> Enum.map(& &1.k8s_node) |> Enum.uniq() |> Enum.sort())
     |> apply_view()}
  end

  def handle_async(:workloads, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:loading?, false) |> assign(:load_failed?, true)}
  end

  defp load(%{assigns: %{loading?: true}} = socket), do: socket

  defp load(socket) do
    socket
    |> assign(:loading?, true)
    |> start_async(:workloads, fn -> Data.workloads() end)
  end

  defp apply_view(socket) do
    %{all: all, filters: filters, sort: sort, dir: dir} = socket.assigns
    matching = all |> Enum.filter(&matches?(&1, filters)) |> sort_by(sort, dir)
    shown = Enum.take(matching, @max_rows)

    socket
    |> assign(:matching, length(matching))
    |> assign(:shown, length(shown))
    |> stream(:workloads, shown, reset: true)
  end

  defp matches?(workload, %{"ns" => ns, "node" => node, "q" => q}) do
    (ns == "" or workload.pod.namespace == ns) and
      (node == "" or workload.k8s_node == node) and
      (q == "" or String.contains?(String.downcase(workload.pod.name), String.downcase(q)))
  end

  # Rows with no value for the sort column (no request, no sample) always sink to the end.
  defp sort_by(workloads, sort, dir) do
    {_, fun} = Map.fetch!(@sorts, sort)
    {missing, present} = Enum.split_with(workloads, &is_nil(fun.(&1)))
    Enum.sort_by(present, &{fun.(&1), pod_key(&1)}, dir) ++ Enum.sort_by(missing, &pod_key/1)
  end

  defp page_path(sort, dir, filters) do
    {default_dir, _} = Map.fetch!(@sorts, sort)

    query =
      [
        sort: if(sort != @default_sort, do: sort),
        dir: if(dir != default_dir, do: dir),
        ns: non_empty(filters["ns"]),
        node: non_empty(filters["node"]),
        q: non_empty(filters["q"])
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/workloads?#{query}"
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp sort_path(column, sort, dir, filters) do
    {default_dir, _} = Map.fetch!(@sorts, column)

    next =
      cond do
        column != sort -> default_dir
        dir == :asc -> :desc
        true -> :asc
      end

    page_path(column, next, filters)
  end

  defp filtered?(filters), do: Enum.any?(filters, fn {_key, value} -> value != "" end)

  # ---- rendering ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:workloads} status={@status} node_name={@node_name}>
      <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-2">
        <div>
          <h1 class="text-base font-semibold text-ink">Request vs. reality</h1>
          <p class="mt-0.5 max-w-2xl text-xs leading-5 text-ink-2">
            Drift is actual usage divided by the request. The tick marks 1.0x: bars growing
            <span class="heat-0 font-medium text-ink">
              <span class="inline-block size-2 rounded-sm bg-heat align-middle"></span> left
            </span>
            use less than they asked for (over-requested); bars growing
            <span class="heat-3 font-medium text-ink">
              <span class="inline-block size-2 rounded-sm bg-heat align-middle"></span> right
            </span>
            use more (under-requested).
          </p>
        </div>
        <p
          id="workloads-count"
          class="text-xs text-ink-2"
          data-shown={@shown}
          data-matching={@matching}
        >
          <%= if @loaded? do %>
            Showing <span class="font-semibold text-ink">{@shown}</span>
            of <span class="font-semibold text-ink">{@matching}</span>
            <span :if={@matching != length(@all)}>matching ({length(@all)} total)</span>
            <span :if={@shown < @matching} id="workloads-capped">
              · capped at {@max_rows}, narrow the filters to see the rest
            </span>
            <span class="text-ink-3">· refreshed {Format.ago(@updated_at, @now)}</span>
          <% else %>
            <span class="text-ink-3">Loading…</span>
          <% end %>
          <span :if={@load_failed?} id="workloads-load-failed" class="ml-1 font-medium text-danger">
            · last refresh failed
          </span>
        </p>
      </div>

      <.form
        for={@form}
        id="workload-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mt-3 flex flex-wrap items-center gap-2"
      >
        <.input
          field={@form[:q]}
          type="search"
          placeholder="Search pods…"
          phx-debounce="250"
          autocomplete="off"
          class={[input_class(), "w-56"]}
        />
        <.input
          field={@form[:ns]}
          type="select"
          prompt="All namespaces"
          options={@namespaces}
          class={input_class()}
        />
        <.input
          field={@form[:node]}
          type="select"
          prompt="All nodes"
          options={@node_names}
          class={input_class()}
        />
        <.link
          :if={filtered?(@filters)}
          id="workload-filters-clear"
          patch={page_path(@sort, @dir, %{"ns" => "", "node" => "", "q" => ""})}
          class="mb-2 text-xs text-ink-2 underline-offset-2 hover:text-ink hover:underline"
        >
          Clear filters
        </.link>
      </.form>

      <div class="mt-1 overflow-x-auto rounded-lg border border-line bg-surface">
        <table id="workloads-table" class="w-full min-w-[68rem] text-left text-xs">
          <thead class="bg-sunken text-[0.6875rem] uppercase tracking-wider text-ink-2">
            <tr class="border-b border-line">
              <.th column="pod" label="Namespace / pod" {sort_assigns(assigns)} />
              <.th column="node" label="Node" {sort_assigns(assigns)} />
              <.th column="owner" label="Owner" {sort_assigns(assigns)} />
              <.th column="cpu_req" label="CPU req" align="right" {sort_assigns(assigns)} />
              <.th column="cpu" label="actual" align="right" {sort_assigns(assigns)} />
              <.th column="cpu_drift" label="CPU drift" {sort_assigns(assigns)} />
              <.th column="mem_req" label="Mem req" align="right" {sort_assigns(assigns)} />
              <.th column="mem" label="actual" align="right" {sort_assigns(assigns)} />
              <.th column="mem_drift" label="Mem drift" {sort_assigns(assigns)} />
              <.th column="throttled" label="Throttled" align="right" {sort_assigns(assigns)} />
              <.th column="psi_mem" label="Mem PSI" align="right" {sort_assigns(assigns)} />
            </tr>
          </thead>
          <tbody id="workloads" phx-update="stream" class="divide-y divide-line">
            <tr
              :for={{id, workload} <- @streams.workloads}
              id={id}
              class="transition-colors hover:bg-sunken/70"
            >
              <td class="max-w-72 px-3 py-1.5">
                <div class="truncate font-mono text-ink" title={workload.pod.name}>
                  <span class="text-ink-3">{workload.pod.namespace}/</span>{workload.pod.name}
                </div>
              </td>
              <td class="whitespace-nowrap px-3 py-1.5">
                <.link
                  navigate={~p"/nodes/#{workload.k8s_node}"}
                  class="font-mono text-ink-2 hover:text-ink hover:underline"
                >
                  {workload.k8s_node}
                </.link>
              </td>
              <td class="max-w-56 px-3 py-1.5">
                <div :if={workload.pod.owner_name} class="truncate" title={workload.pod.owner_name}>
                  <span class="text-ink-3">{workload.pod.owner_kind}/</span><span class="text-ink-2">{workload.pod.owner_name}</span>
                </div>
                <span :if={!workload.pod.owner_name} class="text-ink-3">unmanaged</span>
              </td>
              <td class="whitespace-nowrap px-3 py-1.5 text-right text-ink-2">
                {request(workload.pod.cpu_request_millis, &Format.cpu/1)}
              </td>
              <td class="whitespace-nowrap px-3 py-1.5 text-right text-ink">
                {Format.cpu(cpu_actual(workload))}
              </td>
              <td class="px-3 py-1.5">
                <.drift_bar id={"#{id}-cpu-drift"} ratio={workload.cpu_drift} />
              </td>
              <td class="whitespace-nowrap px-3 py-1.5 text-right text-ink-2">
                {request(workload.pod.memory_request_bytes, &Format.bytes/1)}
              </td>
              <td class="whitespace-nowrap px-3 py-1.5 text-right text-ink">
                {Format.bytes(memory_actual(workload))}
              </td>
              <td class="px-3 py-1.5">
                <.drift_bar id={"#{id}-mem-drift"} ratio={workload.memory_drift} />
              </td>
              <td class="px-3 py-1.5">
                <.pressure_cell
                  value={throttled(workload)}
                  scale={100}
                  text={Format.percent(throttled(workload))}
                />
              </td>
              <td class="px-3 py-1.5">
                <.pressure_cell
                  value={psi_memory(workload)}
                  scale={1}
                  text={Format.psi(psi_memory(workload))}
                />
              </td>
            </tr>
          </tbody>
        </table>

        <%= cond do %>
          <% !@loaded? -> %>
            <p id="workloads-loading" class="px-4 py-10 text-center text-xs text-ink-3">
              <.icon name="hero-arrow-path" class="mr-1 size-3.5 motion-safe:animate-spin" />
              Asking every agent in the mesh for its workloads…
            </p>
          <% @all == [] -> %>
            <.empty_state id="workloads-empty" icon="hero-cube" title="No workloads reported">
              No agent returned any pods. Either the mesh is empty or the agents cannot
              list pods on their nodes yet.
            </.empty_state>
          <% @matching == 0 -> %>
            <.empty_state
              id="workloads-no-match"
              icon="hero-funnel"
              title="No workloads match these filters"
            >
              {length(@all)} workloads are hidden by the current search and filters.
            </.empty_state>
          <% true -> %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp input_class do
    "h-8 rounded-md border border-line-strong bg-surface px-2 text-xs text-ink " <>
      "placeholder:text-ink-3 focus:border-ink focus:outline-none"
  end

  defp request(0, _formatter), do: "–"
  defp request(value, formatter), do: formatter.(value)

  defp sort_assigns(assigns), do: Map.take(assigns, [:sort, :dir, :filters])

  attr :column, :string, required: true
  attr :label, :string, required: true
  attr :align, :string, default: "left"
  attr :sort, :string, required: true
  attr :dir, :atom, required: true
  attr :filters, :map, required: true

  defp th(assigns) do
    ~H"""
    <th
      class={["px-3 py-2 font-medium", @align == "right" && "text-right"]}
      aria-sort={
        cond do
          @sort != @column -> "none"
          @dir == :asc -> "ascending"
          true -> "descending"
        end
      }
    >
      <.link
        id={"sort-#{@column}"}
        patch={sort_path(@column, @sort, @dir, @filters)}
        class={[
          "inline-flex items-center gap-0.5 whitespace-nowrap hover:text-ink",
          @sort == @column && "font-semibold text-ink"
        ]}
      >
        {@label}
        <.icon
          :if={@sort == @column}
          name={if(@dir == :asc, do: "hero-chevron-up-micro", else: "hero-chevron-down-micro")}
          class="size-3.5"
        />
      </.link>
    </th>
    """
  end

  # A right-aligned number with a thin meter under it. `scale` turns the value into 0..100.
  attr :value, :any, required: true
  attr :scale, :integer, required: true
  attr :text, :string, required: true

  defp pressure_cell(assigns) do
    assigns = assign(assigns, :level, (assigns.value || 0) * assigns.scale)

    ~H"""
    <div class={["ml-auto w-14 text-right", Format.heat_class(@level)]}>
      <div class={if(@value, do: "text-ink", else: "text-ink-3")}>{@text}</div>
      <div class="mt-0.5 h-1 overflow-hidden rounded-full bg-ink/[0.07]">
        <div class="ml-auto h-full rounded-full bg-heat" style={"width: #{min(round(@level), 100)}%"}>
        </div>
      </div>
    </div>
    """
  end
end
