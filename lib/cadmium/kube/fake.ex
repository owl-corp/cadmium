defmodule Cadmium.Kube.Fake do
  @moduledoc """
  In-memory Kubernetes cluster implementing `Cadmium.Kube.Client`, for dev and tests.

  It holds nodes, pods, PodDisruptionBudgets, leases and workload replica counts in a
  GenServer and answers with the same shapes and semantics as `Cadmium.Kube.HTTP`:

    * `evict_pod/3` returns `{:error, :not_found}` for unknown pods and
      `{:error, :pdb_blocked}` when a matching PDB has `disruptions_allowed == 0` (dry runs
      included). A real eviction removes the pod and decrements every matching PDB; a
      dry run changes nothing.
    * `create_lease/1` returns `{:error, :conflict}` if the lease exists; `update_lease/1`
      returns `{:error, :conflict}` when `resource_version` is stale and
      `{:error, :not_found}` when the lease is gone.
    * `workload_replicas/3` returns `{:error, :unsupported_kind}` for anything but
      ReplicaSet, StatefulSet, Deployment and ReplicationController, and
      `{:error, :not_found}` for counts that were never registered.
    * When no server is running the callbacks return `{:error, :unavailable}`.

  ## Using it in tests

  The `Cadmium.Kube` facade calls this module without a server argument, so the callbacks
  find their server like this (first hit wins):

    1. the server chosen with `use_server/1` in the calling process, or in one of its
       `$callers` / `$ancestors` (so processes a test starts with `start_supervised!/1` or
       `Task` inherit the test's choice);
    2. `config :cadmium, Cadmium.Kube.Fake, server: name`;
    3. the default registered name, `Cadmium.Kube.Fake`.

  An isolated cluster per test, which is safe with `async: true`:

      setup do
        fake = start_supervised!({Cadmium.Kube.Fake, name: nil})
        Cadmium.Kube.Fake.use_server(fake)
        %{fake: fake}
      end

  Or simply `start_supervised!(Cadmium.Kube.Fake)` under the default name in an
  `async: false` test.

  Every helper takes the server as an optional first argument (default: resolved as above):

      alias Cadmium.Kube.{Fake, Node, PDB, Pod}

      Fake.put_node("node-a")                      # healthy 8 CPU / 16Gi node
      Fake.put_node(%Node{name: "node-b", taints: [...]})
      Fake.put_pod(%Pod{namespace: "shop", name: "web-1", uid: "u1", node_name: "node-a",
                        labels: %{"app" => "web"}, owner_kind: "ReplicaSet", owner_name: "web"})
      Fake.put_pdb(%PDB{namespace: "shop", name: "web", match_labels: %{"app" => "web"},
                        disruptions_allowed: 1})
      Fake.set_workload_replicas("shop", "ReplicaSet", "web", 3)            # desired = ready
      Fake.set_workload_replicas("shop", "ReplicaSet", "web", %{desired: 3, ready: 2})
      Fake.delete_node("node-b"); Fake.delete_pod("shop", "web-1"); Fake.delete_pdb("shop", "web")
      Fake.delete_lease("default", "cadmium-catalyst")

      Fake.get_pod("shop", "web-1")   # => %Pod{} | nil
      Fake.get_node("node-a")         # => %Node{} | nil

      Fake.evictions()     # => [%{namespace: "shop", name: "web-1", dry_run: false, result: :ok}]
      Fake.taint_calls()   # => [%{op: :add, node: "node-a", taint: %{...}, result: :ok},
                           #     %{op: :remove, node: "node-a", key: "k", result: :ok}]
      Fake.calls()         # => every evict/taint call as %{op: atom, args: list, result: term}
      Fake.clear_calls()

      Fake.fail(:evict_pod, :boom)   # evict_pod now returns {:error, :boom}
      Fake.fail(:all, :timeout)      # every client callback fails
      Fake.heal()                    # back to normal
      Fake.reset()                   # drop all objects, calls and failures

  Calls are recorded in order, including failed and dry-run ones.

  ## Dev mode: one cluster shared by a local mesh

      children = [{Cadmium.Kube.Fake, shared: true, seed_demo: Cadmium.node_name()}]

  With `shared: true` every BEAM node runs a local `Cadmium.Kube.Fake` process, but only one
  of them - the one registered in `:global` - holds the cluster; the others forward every
  call to it. So all agents of a local mesh see one cluster and one lease. If the node
  holding the cluster goes away another one takes over with an empty cluster, and every
  surviving process re-applies the demo data it was seeded with (leases and moved pods are
  lost, which is fine for a demo). The same happens when two nodes that each started alone
  connect: one cluster wins, the other node re-seeds into it.

  `seed_demo/1` idempotently adds a node, its `Cadmium.Demo.pods/1`, replica counts for
  the demo ReplicaSets/StatefulSets (summed over all seeded nodes) and a blocking PDB for
  templates with `pdb: true`. A node that already exists is left untouched.

  Shared mode also turns on rescheduling (`reschedule: true`): a pod evicted for real, owned
  by a ReplicaSet, StatefulSet, ReplicationController or Job, is recreated after
  `:reschedule_delay_ms` (default 3000) with a new uid (and a new name, except for
  StatefulSets) on the ready, schedulable node with the fewest pods that carries no
  `NoSchedule`/`PreferNoSchedule`/`NoExecute` taint. Meanwhile the workload's ready count
  and the matching PDBs' allowances are down by one. This is off by default.

  ## Options

    * `:name` - registered name (default `Cadmium.Kube.Fake`; `nil` for none)
    * `:shared` - share one cluster across connected BEAM nodes (default `false`)
    * `:seed_demo` - Kubernetes node name to seed demo data for on start
    * `:reschedule` - recreate evicted pods elsewhere (default: the value of `:shared`)
    * `:reschedule_delay_ms` - default 3000
  """

  use GenServer

  @behaviour Cadmium.Kube.Client

  alias Cadmium.Kube.{Lease, Node, PDB, Pod, Selector}

  require Logger

  @server_key {__MODULE__, :server}
  @global_name __MODULE__
  @shared_check_ms 1_000
  @recorded [:evict_pod, :add_node_taint, :remove_node_taint]
  @workload_kinds ~w(ReplicaSet StatefulSet Deployment ReplicationController)
  @rescheduled_kinds ~w(ReplicaSet StatefulSet ReplicationController Job)
  @repelling_effects ~w(NoSchedule PreferNoSchedule NoExecute)
  @gi 1024 * 1024 * 1024

  defstruct nodes: %{},
            pods: %{},
            pdbs: %{},
            leases: %{},
            replicas: %{},
            calls: [],
            errors: %{},
            version: 0,
            # :active holds the cluster; :standby forwards to `active`
            role: :active,
            active: nil,
            monitor: nil,
            shared?: false,
            seeds: [],
            reschedule?: false,
            reschedule_delay_ms: 3_000

  ## Lifecycle

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Makes the calling process, and processes it starts, use `server` for all
  `Cadmium.Kube.Fake` calls. See the moduledoc.
  """
  @spec use_server(GenServer.server()) :: :ok
  def use_server(server) do
    Process.put(@server_key, server)
    :ok
  end

  @doc "The server the calling process resolves to. See the moduledoc."
  @spec server() :: GenServer.server()
  def server do
    Process.get(@server_key) || inherited_server() ||
      Application.get_env(:cadmium, __MODULE__, [])[:server] || __MODULE__
  end

  # Remembered in the caller's own dictionary, so that it still resolves after the process
  # it inherited from (typically the test) has exited, e.g. in a `terminate/2` callback.
  defp inherited_server do
    server =
      [:"$callers", :"$ancestors"]
      |> Enum.flat_map(&List.wrap(Process.get(&1)))
      |> Enum.find_value(&server_of/1)

    if server, do: Process.put(@server_key, server)
    server
  end

  defp server_of(nil), do: nil
  defp server_of(name) when is_atom(name), do: name |> Process.whereis() |> server_of()

  defp server_of(pid) when is_pid(pid) and node(pid) == node() do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {@server_key, server} <- List.keyfind(dictionary, @server_key, 0) do
      server
    else
      _ -> nil
    end
  end

  defp server_of(_other), do: nil

  ## Cadmium.Kube.Client

  @impl true
  def list_pods(opts \\ []), do: client(:list_pods, [opts])
  @impl true
  def list_nodes, do: client(:list_nodes, [])
  @impl true
  def list_pdbs, do: client(:list_pdbs, [])
  @impl true
  def workload_replicas(namespace, kind, name),
    do: client(:workload_replicas, [namespace, kind, name])

  @impl true
  def evict_pod(namespace, name, opts \\ []), do: client(:evict_pod, [namespace, name, opts])
  @impl true
  def add_node_taint(node, taint), do: client(:add_node_taint, [node, taint])
  @impl true
  def remove_node_taint(node, key), do: client(:remove_node_taint, [node, key])
  @impl true
  def get_lease(namespace, name), do: client(:get_lease, [namespace, name])
  @impl true
  def create_lease(%Lease{} = lease), do: client(:create_lease, [lease])
  @impl true
  def update_lease(%Lease{} = lease), do: client(:update_lease, [lease])

  defp client(op, args) do
    GenServer.call(server(), {:client, op, args})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  ## Test and dev helpers

  @doc "Adds or replaces a node. A bare name creates a ready 8 CPU / 16Gi node."
  @spec put_node(GenServer.server(), Node.t() | String.t()) :: :ok
  def put_node(server \\ server(), node)
  def put_node(server, name) when is_binary(name), do: put_node(server, default_node(name))
  def put_node(server, %Node{} = node), do: admin(server, :put_node, [node])

  @doc "Removes a node (its pods stay, as they would until the node lifecycle controller acts)."
  @spec delete_node(GenServer.server(), String.t()) :: :ok
  def delete_node(server \\ server(), name), do: admin(server, :delete_node, [name])

  @doc "Adds or replaces a pod, keyed by namespace and name."
  @spec put_pod(GenServer.server(), Pod.t()) :: :ok
  def put_pod(server \\ server(), %Pod{} = pod), do: admin(server, :put_pod, [pod])

  @spec delete_pod(GenServer.server(), String.t(), String.t()) :: :ok
  def delete_pod(server \\ server(), namespace, name),
    do: admin(server, :delete_pod, [namespace, name])

  @doc "Adds or replaces a PodDisruptionBudget, keyed by namespace and name."
  @spec put_pdb(GenServer.server(), PDB.t()) :: :ok
  def put_pdb(server \\ server(), %PDB{} = pdb), do: admin(server, :put_pdb, [pdb])

  @spec delete_pdb(GenServer.server(), String.t(), String.t()) :: :ok
  def delete_pdb(server \\ server(), namespace, name),
    do: admin(server, :delete_pdb, [namespace, name])

  @doc """
  Registers what `workload_replicas/3` returns. `counts` is an integer (desired and ready)
  or a map/keyword with `:desired` and `:ready`; `nil` unregisters.
  """
  @spec set_workload_replicas(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer() | map() | keyword() | nil
        ) :: :ok
  def set_workload_replicas(server \\ server(), namespace, kind, name, counts) do
    counts =
      case counts do
        nil ->
          nil

        count when is_integer(count) ->
          %{desired: count, ready: count}

        counts ->
          counts = Map.new(counts)
          %{desired: Map.fetch!(counts, :desired), ready: Map.get(counts, :ready, counts.desired)}
      end

    admin(server, :set_workload_replicas, [{namespace, kind, name}, counts])
  end

  @spec delete_lease(GenServer.server(), String.t(), String.t()) :: :ok
  def delete_lease(server \\ server(), namespace, name),
    do: admin(server, :delete_lease, [namespace, name])

  @spec get_pod(GenServer.server(), String.t(), String.t()) :: Pod.t() | nil
  def get_pod(server \\ server(), namespace, name), do: admin(server, :get_pod, [namespace, name])

  @spec get_node(GenServer.server(), String.t()) :: Node.t() | nil
  def get_node(server \\ server(), name), do: admin(server, :get_node, [name])

  @doc """
  Every eviction and taint call so far, oldest first, as
  `%{op: :evict_pod | :add_node_taint | :remove_node_taint, args: list, result: term}`.
  """
  @spec calls(GenServer.server()) :: [map()]
  def calls(server \\ server()), do: admin(server, :calls, [])

  @doc "Eviction attempts, oldest first: `%{namespace:, name:, dry_run:, result:}`."
  @spec evictions(GenServer.server()) :: [map()]
  def evictions(server \\ server()) do
    for %{op: :evict_pod, args: [namespace, name, opts], result: result} <- calls(server) do
      %{namespace: namespace, name: name, dry_run: opts[:dry_run] == true, result: result}
    end
  end

  @doc """
  Taint calls, oldest first: `%{op: :add, node:, taint:, result:}` and
  `%{op: :remove, node:, key:, result:}`.
  """
  @spec taint_calls(GenServer.server()) :: [map()]
  def taint_calls(server \\ server()) do
    Enum.flat_map(calls(server), fn
      %{op: :add_node_taint, args: [node, taint], result: result} ->
        [%{op: :add, node: node, taint: taint, result: result}]

      %{op: :remove_node_taint, args: [node, key], result: result} ->
        [%{op: :remove, node: node, key: key, result: result}]

      _other ->
        []
    end)
  end

  @spec clear_calls(GenServer.server()) :: :ok
  def clear_calls(server \\ server()), do: admin(server, :clear_calls, [])

  @doc """
  Makes a client callback (`:evict_pod`, `:get_lease`, ... or `:all`) return
  `{:error, reason}` until `heal/1`. A `nil` reason clears that one failure.
  """
  @spec fail(GenServer.server(), atom(), term()) :: :ok
  def fail(server \\ server(), op, reason), do: admin(server, :fail, [op, reason])

  @doc "Clears every failure injected with `fail/3`."
  @spec heal(GenServer.server()) :: :ok
  def heal(server \\ server()), do: admin(server, :heal, [])

  @doc "Drops all objects, recorded calls and injected failures."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ server()), do: admin(server, :reset, [])

  @doc """
  Idempotently adds the demo data for one Kubernetes node: the Node, `Cadmium.Demo.pods/1`,
  replica counts for its ReplicaSets/StatefulSets and blocking PDBs for `pdb: true`
  templates. Does nothing if the node already exists.
  """
  @spec seed_demo(GenServer.server(), String.t()) :: :ok
  def seed_demo(server \\ server(), node_name) when is_binary(node_name),
    do: GenServer.call(server, {:seed_demo, node_name})

  @doc "`%{role: :active | :standby, active: pid | nil, shared?: boolean}` of a local server."
  @spec info(GenServer.server()) :: map()
  def info(server \\ server()), do: GenServer.call(server, :info)

  defp admin(server, op, args), do: GenServer.call(server, {:admin, op, args})

  defp default_node(name) do
    %Node{
      name: name,
      labels: %{"kubernetes.io/hostname" => name},
      allocatable_cpu_millis: 8_000,
      allocatable_memory_bytes: 16 * @gi
    }
  end

  ## GenServer

  @impl true
  def init(opts) do
    shared? = Keyword.get(opts, :shared, false)

    state = %__MODULE__{
      shared?: shared?,
      role: if(shared?, do: :starting, else: :active),
      active: if(shared?, do: nil, else: self()),
      seeds: List.wrap(opts[:seed_demo]),
      reschedule?: Keyword.get(opts, :reschedule, shared?),
      reschedule_delay_ms: Keyword.get(opts, :reschedule_delay_ms, 3_000)
    }

    if shared? do
      Process.send_after(self(), :shared_check, @shared_check_ms)
      {:ok, sync_shared(state)}
    else
      {:ok, apply_seeds(state)}
    end
  end

  @impl true
  def handle_call(:info, _from, state),
    do: {:reply, Map.take(state, [:role, :active, :shared?]), state}

  def handle_call({:seed_demo, node_name}, from, state) do
    state = %{state | seeds: Enum.uniq(state.seeds ++ [node_name])}
    handle_call({:admin, :seed_demo, [node_name]}, from, state)
  end

  def handle_call(_message, _from, %{role: :standby, active: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(message, from, %{role: :standby, active: active} = state) do
    # relay without blocking; a call (unlike a bare send) fails fast if the holder just died
    spawn(fn ->
      reply =
        try do
          GenServer.call(active, message)
        catch
          :exit, _reason -> {:error, :unavailable}
        end

      GenServer.reply(from, reply)
    end)

    {:noreply, state}
  end

  def handle_call({:client, op, args}, _from, state) do
    {result, state} =
      case injected_error(state, op) do
        {:ok, reason} -> {{:error, reason}, state}
        :error -> client(op, args, state)
      end

    state =
      if op in @recorded,
        do: %{state | calls: [%{op: op, args: args, result: result} | state.calls]},
        else: state

    {:reply, result, state}
  end

  def handle_call({:admin, op, args}, _from, state) do
    {result, state} = admin_op(op, args, state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:seed_demo, node_name}, %{role: :standby} = state) do
    if state.active, do: GenServer.cast(state.active, {:seed_demo, node_name})
    {:noreply, state}
  end

  def handle_cast({:seed_demo, node_name}, state), do: {:noreply, seed(state, node_name)}

  @impl true
  def handle_info(:shared_check, state) do
    Process.send_after(self(), :shared_check, @shared_check_ms)
    {:noreply, sync_shared(state)}
  end

  def handle_info({:global_name_conflict, @global_name}, state),
    do: {:noreply, sync_shared(state)}

  def handle_info({:global_name_conflict, @global_name, _other}, state),
    do: {:noreply, sync_shared(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, sync_shared(%{state | active: nil, monitor: nil})}

  def handle_info({:reschedule, pod, pdb_keys}, %{role: :active} = state),
    do: {:noreply, reschedule(state, pod, pdb_keys)}

  def handle_info(_message, state), do: {:noreply, state}

  ## Shared mode

  # Converges on "exactly one registered server holds the cluster, everyone else follows it".
  defp sync_shared(%{shared?: false} = state), do: state

  defp sync_shared(state) do
    me = self()

    with :undefined <- :global.whereis_name(@global_name),
         :no <- :global.register_name(@global_name, me, &:global.random_notify_name/3),
         :undefined <- :global.whereis_name(@global_name) do
      # lost a registration race whose winner is not visible yet; the next check settles it
      if state.role == :active and state.active == me,
        do: state,
        else: %{state | role: :standby, active: nil}
    else
      :yes -> activate(state)
      ^me -> activate(state)
      pid when is_pid(pid) -> follow(state, pid)
    end
  end

  defp activate(%{role: :active} = state), do: state

  defp activate(state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    Logger.debug("Cadmium.Kube.Fake on #{node()} now holds the shared cluster")

    apply_seeds(%{wipe(state) | role: :active, active: self(), monitor: nil})
  end

  defp follow(%{role: :standby, active: pid} = state, pid), do: state

  defp follow(state, pid) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    Enum.each(state.seeds, &GenServer.cast(pid, {:seed_demo, &1}))

    %{wipe(state) | role: :standby, active: pid, monitor: Process.monitor(pid)}
  end

  defp wipe(state) do
    %{
      state
      | nodes: %{},
        pods: %{},
        pdbs: %{},
        leases: %{},
        replicas: %{},
        calls: [],
        errors: %{}
    }
  end

  ## Client operations

  defp injected_error(state, op) do
    with :error <- Map.fetch(state.errors, op), do: Map.fetch(state.errors, :all)
  end

  defp client(:list_pods, [opts], state) do
    pods =
      state.pods
      |> Map.values()
      |> Enum.filter(fn pod ->
        (opts[:node] == nil or pod.node_name == opts[:node]) and
          (opts[:namespace] == nil or pod.namespace == opts[:namespace])
      end)
      |> Enum.sort_by(&{&1.namespace, &1.name})

    {{:ok, pods}, state}
  end

  defp client(:list_nodes, [], state),
    do: {{:ok, state.nodes |> Map.values() |> Enum.sort_by(& &1.name)}, state}

  defp client(:list_pdbs, [], state),
    do: {{:ok, state.pdbs |> Map.values() |> Enum.sort_by(&{&1.namespace, &1.name})}, state}

  defp client(:workload_replicas, [namespace, kind, name], state) do
    cond do
      kind not in @workload_kinds -> {{:error, :unsupported_kind}, state}
      counts = state.replicas[{namespace, kind, name}] -> {{:ok, counts}, state}
      true -> {{:error, :not_found}, state}
    end
  end

  defp client(:evict_pod, [namespace, name, opts], state) do
    pod = state.pods[{namespace, name}]

    pdbs =
      if pod, do: Enum.filter(Map.values(state.pdbs), &Selector.pdb_matches?(&1, pod)), else: []

    cond do
      pod == nil -> {{:error, :not_found}, state}
      Enum.any?(pdbs, &(&1.disruptions_allowed <= 0)) -> {{:error, :pdb_blocked}, state}
      opts[:dry_run] -> {:ok, state}
      true -> {:ok, evict(state, pod, pdbs)}
    end
  end

  defp client(:add_node_taint, [name, %{key: key, effect: effect} = taint], state) do
    taint = %{key: key, value: Map.get(taint, :value), effect: effect}

    update_node(state, name, fn node ->
      %{node | taints: Enum.reject(node.taints, &(&1.key == key)) ++ [taint]}
    end)
  end

  defp client(:remove_node_taint, [name, key], state) do
    update_node(state, name, fn node ->
      %{node | taints: Enum.reject(node.taints, &(&1.key == key))}
    end)
  end

  defp client(:get_lease, [namespace, name], state) do
    case state.leases[{namespace, name}] do
      nil -> {{:error, :not_found}, state}
      lease -> {{:ok, lease}, state}
    end
  end

  defp client(:create_lease, [lease], state) do
    key = {lease.namespace, lease.name}

    if Map.has_key?(state.leases, key),
      do: {{:error, :conflict}, state},
      else: store_lease(state, key, lease)
  end

  defp client(:update_lease, [lease], state) do
    key = {lease.namespace, lease.name}

    case state.leases[key] do
      nil ->
        {{:error, :not_found}, state}

      # like the API server, an update without a resourceVersion is unconditional
      %Lease{resource_version: current}
      when lease.resource_version != nil and lease.resource_version != current ->
        {{:error, :conflict}, state}

      _current ->
        store_lease(state, key, lease)
    end
  end

  defp store_lease(state, key, lease) do
    version = state.version + 1
    lease = %{lease | resource_version: Integer.to_string(version)}
    {{:ok, lease}, %{state | version: version, leases: Map.put(state.leases, key, lease)}}
  end

  defp update_node(state, name, fun) do
    case state.nodes[name] do
      nil -> {{:error, :not_found}, state}
      node -> {:ok, %{state | nodes: Map.put(state.nodes, name, fun.(node))}}
    end
  end

  defp evict(state, pod, pdbs) do
    pdb_keys = Enum.map(pdbs, &{&1.namespace, &1.name})

    state = %{
      state
      | pods: Map.delete(state.pods, {pod.namespace, pod.name}),
        pdbs: adjust_pdbs(state.pdbs, pdb_keys, -1)
    }

    if state.reschedule? and pod.owner_kind in @rescheduled_kinds do
      schedule_reschedule(pod, pdb_keys, state.reschedule_delay_ms)
      adjust_ready(state, pod, -1)
    else
      state
    end
  end

  defp adjust_pdbs(pdbs, keys, delta) do
    Enum.reduce(keys, pdbs, fn key, pdbs ->
      case pdbs do
        %{^key => pdb} ->
          Map.put(pdbs, key, %{pdb | disruptions_allowed: max(pdb.disruptions_allowed + delta, 0)})

        _gone ->
          pdbs
      end
    end)
  end

  defp adjust_ready(state, pod, delta) do
    key = {pod.namespace, pod.owner_kind, pod.owner_name}

    case state.replicas do
      %{^key => %{desired: desired, ready: ready}} ->
        counts = %{desired: desired, ready: (ready + delta) |> max(0) |> min(desired)}
        %{state | replicas: Map.put(state.replicas, key, counts)}

      _unregistered ->
        state
    end
  end

  ## Rescheduling

  defp schedule_reschedule(pod, pdb_keys, 0), do: send(self(), {:reschedule, pod, pdb_keys})

  defp schedule_reschedule(pod, pdb_keys, delay_ms),
    do: Process.send_after(self(), {:reschedule, pod, pdb_keys}, delay_ms)

  defp reschedule(state, pod, pdb_keys) do
    counts = Enum.frequencies_by(Map.values(state.pods), & &1.node_name)

    target =
      state.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        node.ready? and not node.unschedulable? and
          not Enum.any?(node.taints, &(&1.effect in @repelling_effects))
      end)
      |> Enum.min_by(&{Map.get(counts, &1.name, 0), &1.name}, fn -> nil end)

    case target do
      nil ->
        # nowhere to go yet: stay pending and try again
        Process.send_after(
          self(),
          {:reschedule, pod, pdb_keys},
          max(state.reschedule_delay_ms, 500)
        )

        state

      node ->
        name =
          if pod.owner_kind == "StatefulSet",
            do: pod.name,
            else: "#{pod.owner_name}-#{random_suffix()}"

        pod = %{
          pod
          | name: name,
            uid: random_uid(),
            node_name: node.name,
            phase: "Running",
            deleting?: false,
            created_at: DateTime.utc_now()
        }

        state
        |> Map.update!(:pods, &Map.put(&1, {pod.namespace, pod.name}, pod))
        |> Map.update!(:pdbs, &adjust_pdbs(&1, pdb_keys, 1))
        |> adjust_ready(pod, 1)
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(5)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, 5)
  end

  defp random_uid do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  ## Admin operations

  defp admin_op(:put_node, [node], state),
    do: {:ok, %{state | nodes: Map.put(state.nodes, node.name, node)}}

  defp admin_op(:delete_node, [name], state),
    do: {:ok, %{state | nodes: Map.delete(state.nodes, name)}}

  defp admin_op(:put_pod, [pod], state),
    do: {:ok, %{state | pods: Map.put(state.pods, {pod.namespace, pod.name}, pod)}}

  defp admin_op(:delete_pod, [namespace, name], state),
    do: {:ok, %{state | pods: Map.delete(state.pods, {namespace, name})}}

  defp admin_op(:put_pdb, [pdb], state),
    do: {:ok, %{state | pdbs: Map.put(state.pdbs, {pdb.namespace, pdb.name}, pdb)}}

  defp admin_op(:delete_pdb, [namespace, name], state),
    do: {:ok, %{state | pdbs: Map.delete(state.pdbs, {namespace, name})}}

  defp admin_op(:set_workload_replicas, [key, nil], state),
    do: {:ok, %{state | replicas: Map.delete(state.replicas, key)}}

  defp admin_op(:set_workload_replicas, [key, counts], state),
    do: {:ok, %{state | replicas: Map.put(state.replicas, key, counts)}}

  defp admin_op(:delete_lease, [namespace, name], state),
    do: {:ok, %{state | leases: Map.delete(state.leases, {namespace, name})}}

  defp admin_op(:get_pod, [namespace, name], state), do: {state.pods[{namespace, name}], state}
  defp admin_op(:get_node, [name], state), do: {state.nodes[name], state}
  defp admin_op(:calls, [], state), do: {Enum.reverse(state.calls), state}
  defp admin_op(:clear_calls, [], state), do: {:ok, %{state | calls: []}}

  defp admin_op(:fail, [op, nil], state),
    do: {:ok, %{state | errors: Map.delete(state.errors, op)}}

  defp admin_op(:fail, [op, reason], state),
    do: {:ok, %{state | errors: Map.put(state.errors, op, reason)}}

  defp admin_op(:heal, [], state), do: {:ok, %{state | errors: %{}}}
  defp admin_op(:reset, [], state), do: {:ok, wipe(state)}
  defp admin_op(:seed_demo, [node_name], state), do: {:ok, seed(state, node_name)}

  ## Demo data

  defp apply_seeds(state), do: Enum.reduce(state.seeds, state, &seed(&2, &1))

  defp seed(state, node_name) when is_map_key(state.nodes, node_name), do: state

  defp seed(state, node_name) do
    pods = Map.new(Cadmium.Demo.pods(node_name), &{{&1.namespace, &1.name}, &1})

    Enum.reduce(
      Cadmium.Demo.workloads(),
      %{
        state
        | nodes: Map.put(state.nodes, node_name, default_node(node_name)),
          pods: Map.merge(state.pods, pods)
      },
      &seed_workload/2
    )
  end

  defp seed_workload(workload, state) do
    state =
      if workload.kind in @workload_kinds do
        key = {workload.ns, workload.kind, workload.owner}
        counts = Map.get(state.replicas, key, %{desired: 0, ready: 0})

        counts = %{
          desired: counts.desired + workload.per_node,
          ready: counts.ready + workload.per_node
        }

        %{state | replicas: Map.put(state.replicas, key, counts)}
      else
        state
      end

    if workload[:pdb] do
      app = Cadmium.Demo.app_label(workload)

      pdb = %PDB{
        namespace: workload.ns,
        name: app,
        match_labels: %{"app" => app},
        disruptions_allowed: 0
      }

      %{state | pdbs: Map.put_new(state.pdbs, {pdb.namespace, pdb.name}, pdb)}
    else
      state
    end
  end
end
