defmodule Cadmium.Catalyst.Coordinator do
  @moduledoc """
  Runs the evaluate -> plan -> execute cycle on the agent that holds the leader lease.

  ## Leadership

  The coordinator runs on every agent but only acts while it is leader. It learns about
  transitions from `{:leadership, :acquired | :lost}` on `Cadmium.Leader.topic/0` and,
  as a safety net against missed messages, re-reads `leader_fun` on every tick. The
  executor additionally re-checks `leader_fun` before every mutating call.

    * On **acquiring** leadership it records `:leader_acquired`, forgets its "hot since"
      tracking, adopts the previous leader's cooldowns (from its last broadcast, clamped
      to the configured cooldown lengths) and immediately runs a cycle, whose first step
      reconciles taints (see `Cadmium.Catalyst.Executor.sweep_taints/2`).
    * On **losing** leadership it records `:leader_lost` and stops starting cycles; a
      cycle in flight aborts at its next leadership check. The new leader reconciles.

  "Hot since" is tracked only by the leader and starts empty after every leader change,
  coordinator restart, pause (`enabled?: false`) or loss of cooldown state: a new leader
  must itself observe a node hot for the whole `sustained_ms` before it acts. This is
  deliberately the conservative choice.

  ## Evaluation

  A cycle runs in a linked process so the coordinator stays responsive (`status/1`
  never waits for Kubernetes). At most one runs at a time: a tick while one is in
  flight is skipped, `evaluate_now/2` callers join the one in flight. A crash in a
  cycle is logged and reported to waiters; the coordinator survives, and because
  cooldowns live in `Cadmium.Catalyst.Cooldowns` (written at the moment of each
  eviction), a crashed cycle cannot lead to a repeat eviction on the next tick. The
  next cycle only starts on the next tick, never immediately.

  ## Status replication

  After every cycle the leader publishes its last plan and cooldowns (as wall-clock
  expiries) to the other coordinators on `Cadmium.Catalyst.Settings.sync_topic/0`.
  Each coordinator announces `{:catalyst_status, status}` *locally* on
  `Cadmium.Catalyst.topic/0` whenever its own view changes, so a subscriber always sees
  the status of the agent it is connected to (with the right `leader?`), and non-leaders
  show the leader's last plan and cooldowns.

  ## Options

  `:name`, `:config` (overrides), `:interval` (ms or `:manual`; default
  `evaluate_interval_ms`), `:nodes_fun`, `:workloads_fun`, `:leader_fun`,
  `:leader_current_fun`, `:clock` (monotonic ms), `:wall_clock` (ms), `:settings`,
  `:audit`, `:cooldowns`, `:pubsub`, `:topic`, `:sync_topic`, `:leader_topic`, `:actor`.
  """

  use GenServer

  require Logger

  alias Cadmium.Catalyst.{AuditLog, Config, Cooldowns, Executor, Plan, Planner, Policy}
  alias Cadmium.Catalyst.{Safe, Settings}

  @type result :: {:ok, Plan.t()} | {:skipped, atom()} | {:error, term()}

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one evaluation cycle now (or joins the one in flight) and returns its outcome:
  `{:ok, plan}`, `{:skipped, :not_leader | :disabled | :settings_unavailable |
  :cooldowns_unavailable}` or `{:error, reason}`.
  """
  @spec evaluate_now(GenServer.server(), timeout()) :: result()
  def evaluate_now(server \\ __MODULE__, timeout \\ 60_000),
    do: GenServer.call(server, :evaluate_now, timeout)

  @doc "Runs one spread-only evaluation, rejecting requests while another cycle is running."
  def rebalance_now(server \\ __MODULE__, timeout \\ 60_000),
    do: GenServer.call(server, :rebalance_now, timeout)

  @doc "Returns once no evaluation is in flight."
  @spec await_idle(GenServer.server(), timeout()) :: :ok
  def await_idle(server \\ __MODULE__, timeout \\ 60_000),
    do: GenServer.call(server, :await_idle, timeout)

  @doc "This agent's `t:Cadmium.Catalyst.status/0`."
  @spec status(GenServer.server()) :: Cadmium.Catalyst.status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      config: Keyword.get(opts, :config, []),
      interval: Keyword.get(opts, :interval),
      nodes_fun: Keyword.get(opts, :nodes_fun, &Cadmium.Valence.nodes/0),
      workloads_fun: Keyword.get(opts, :workloads_fun, &Cadmium.Workloads.on_node/1),
      leader_fun: Keyword.get(opts, :leader_fun, &Cadmium.Leader.leader?/0),
      leader_current_fun: Keyword.get(opts, :leader_current_fun, &Cadmium.Leader.current/0),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      wall_clock: Keyword.get(opts, :wall_clock, fn -> System.system_time(:millisecond) end),
      settings: Keyword.get(opts, :settings, Settings),
      audit: Keyword.get(opts, :audit, AuditLog),
      cooldowns: Keyword.get(opts, :cooldowns, Cooldowns),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get_lazy(opts, :topic, &Cadmium.Catalyst.topic/0),
      sync_topic: Keyword.get_lazy(opts, :sync_topic, &Settings.sync_topic/0),
      leader_topic: Keyword.get_lazy(opts, :leader_topic, &Cadmium.Leader.topic/0),
      actor: Keyword.get_lazy(opts, :actor, &Cadmium.node_name/0),
      leader?: false,
      hot_since: %{},
      store_instance: nil,
      last_plan: nil,
      last_evaluated_at: nil,
      # the leader's last published state, while we are not the leader
      remote: nil,
      # %{pid, ref, waiters} while a cycle is in flight
      eval: nil,
      # bumped on every leadership change; a cycle started in an earlier term must not
      # carry its hot tracking into the current one
      term: 0
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    Phoenix.PubSub.subscribe(state.pubsub, state.leader_topic)
    Phoenix.PubSub.subscribe(state.pubsub, state.sync_topic)
    schedule_tick(state)
    {:noreply, sync_leadership(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call(:evaluate_now, from, state) do
    state = sync_leadership(state)

    cond do
      state.eval != nil -> {:noreply, add_waiter(state, {:result, from})}
      not state.leader? -> {:reply, {:skipped, :not_leader}, state}
      true -> {:noreply, state |> start_eval() |> add_waiter({:result, from})}
    end
  end

  def handle_call(:rebalance_now, from, state) do
    state = sync_leadership(state)

    cond do
      not state.leader? -> {:reply, {:skipped, :not_leader}, state}
      state.eval != nil -> {:reply, {:skipped, :busy}, state}
      true -> {:noreply, state |> start_eval(true) |> add_waiter({:result, from})}
    end
  end

  def handle_call(:await_idle, from, state) do
    if state.eval, do: {:noreply, add_waiter(state, {:idle, from})}, else: {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state)
    state = sync_leadership(state)
    state = if state.leader? and state.eval == nil, do: start_eval(state), else: state
    {:noreply, state}
  end

  def handle_info({:leadership, :acquired}, state), do: {:noreply, become(state, true)}
  def handle_info({:leadership, :lost}, state), do: {:noreply, become(state, false)}

  def handle_info({:eval_done, ref, result}, %{eval: %{ref: ref}} = state) do
    {:noreply, finish_eval(state, result)}
  end

  def handle_info({:EXIT, pid, reason}, %{eval: %{pid: pid}} = state) do
    # A normal exit is always preceded by {:eval_done, ...}; getting here means the
    # cycle died. Cooldowns it wrote are safe in the Cooldowns table.
    Logger.error("Catalyst: evaluation crashed: #{inspect(reason)}")
    outcome = %{outcome: {:error, {:crashed, reason}}, hot_since: state.hot_since}
    {:noreply, finish_eval(state, Map.put(outcome, :store_instance, state.store_instance))}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:catalyst_leader_state, %{from: from} = remote}, state) do
    if from != state.actor and not state.leader? do
      state = %{state | remote: remote}
      announce_status(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:catalyst_settings_applied, _settings}, state) do
    announce_status(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Never leave a cycle running without a coordinator to serialise the next one.
    if state.eval, do: Process.exit(state.eval.pid, :kill)
    :ok
  end

  ## Leadership

  defp sync_leadership(state), do: become(state, Safe.true?(state.leader_fun))

  defp become(%{leader?: same} = state, same), do: state

  defp become(state, true) do
    AuditLog.record(state.audit,
      type: :leader_acquired,
      actor: state.actor,
      reason: "acquired the Catalyst lease; reconciling taints"
    )

    adopt_cooldowns(state)
    state = %{state | leader?: true, hot_since: %{}, remote: nil, term: state.term + 1}
    announce_status(state)
    # Reconcile right away rather than at the next tick.
    if state.eval == nil, do: start_eval(state), else: state
  end

  defp become(state, false) do
    AuditLog.record(state.audit,
      type: :leader_lost,
      actor: state.actor,
      reason: "lost the Catalyst lease; standing down"
    )

    state = %{state | leader?: false, hot_since: %{}, term: state.term + 1}
    announce_status(state)
    state
  end

  # Carry the previous leader's cooldowns over so a leader change is not a licence to
  # evict again. Remaining times are clamped to the configured lengths in case the
  # two agents' wall clocks disagree.
  defp adopt_cooldowns(%{remote: %{cooldowns: %{} = cooldowns}} = state) do
    cfg = Config.load(state.config)
    wall = state.wall_clock.()
    mono = state.clock.()

    Safe.call(
      fn ->
        for {node, expiry} <- Map.get(cooldowns, :nodes, %{}), is_integer(expiry) do
          remaining = min(expiry - wall, cfg.node_cooldown_ms)
          if remaining > 0, do: Cooldowns.put_node(state.cooldowns, node, mono + remaining)
        end

        for {key, expiry} <- Map.get(cooldowns, :workloads, %{}), is_integer(expiry) do
          remaining = min(expiry - wall, cfg.workload_cooldown_ms)
          if remaining > 0, do: Cooldowns.put_workload(state.cooldowns, key, mono + remaining)
        end
      end,
      :ok
    )
  end

  defp adopt_cooldowns(_state), do: :ok

  ## Evaluation

  defp start_eval(state, spread_only? \\ false) do
    parent = self()
    ref = make_ref()

    snapshot =
      Map.take(state, [
        :config,
        :nodes_fun,
        :workloads_fun,
        :leader_fun,
        :clock,
        :wall_clock,
        :settings,
        :audit,
        :actor,
        :cooldowns,
        :hot_since,
        :store_instance
      ])
      |> Map.put(:spread_only?, spread_only?)

    pid = spawn_link(fn -> send(parent, {:eval_done, ref, run_cycle(snapshot)}) end)
    %{state | eval: %{pid: pid, ref: ref, waiters: [], term: state.term}}
  end

  defp add_waiter(%{eval: eval} = state, waiter),
    do: %{state | eval: %{eval | waiters: [waiter | eval.waiters]}}

  defp finish_eval(state, result) do
    waiters = state.eval.waiters

    stale? = state.eval.term != state.term

    state = %{
      state
      | eval: nil,
        hot_since: if(stale?, do: %{}, else: result.hot_since),
        store_instance: result.store_instance
    }

    state =
      case result.outcome do
        {:ok, %Plan{} = plan} ->
          %{state | last_plan: plan, last_evaluated_at: plan.generated_at}

        {:error, reason} ->
          Logger.error("Catalyst: evaluation failed: #{inspect(reason)}")
          state

        {:skipped, _reason} ->
          state
      end

    # Leadership may have been lost while the cycle ran; then hot tracking is void.
    state = if state.leader?, do: state, else: %{state | hot_since: %{}}

    if state.leader?, do: publish_leader_state(state)
    announce_status(state)

    # A cycle from an earlier term of leadership did not reconcile for this one.
    state = if stale? and state.leader?, do: start_eval(state), else: state

    Enum.reduce(Enum.reverse(waiters), state, fn
      {:result, from}, state ->
        GenServer.reply(from, result.outcome)
        state

      {:idle, _from} = waiter, %{eval: %{}} = state ->
        add_waiter(state, waiter)

      {:idle, from}, state ->
        GenServer.reply(from, :ok)
        state
    end)
  end

  # Runs in the evaluation process. Always returns a result map; never raises.
  defp run_cycle(s) do
    do_cycle(s)
  rescue
    e ->
      cycle_result(s, {:error, {:exception, Exception.format(:error, e, __STACKTRACE__)}})
  catch
    kind, reason -> cycle_result(s, {:error, {kind, reason}})
  end

  defp cycle_result(s, outcome, overrides \\ %{}) do
    Map.merge(
      %{outcome: outcome, hot_since: s.hot_since, store_instance: s.store_instance},
      overrides
    )
  end

  defp do_cycle(s) do
    cfg = Config.load(s.config)
    instance = Cooldowns.instance(s.cooldowns)
    settings = Settings.fetch(s.settings)

    cond do
      not Safe.true?(s.leader_fun) ->
        cycle_result(s, {:skipped, :not_leader})

      instance == nil ->
        # No cooldown state means no way to act safely.
        cycle_result(s, {:skipped, :cooldowns_unavailable}, %{hot_since: %{}})

      settings == nil ->
        cycle_result(s, {:skipped, :settings_unavailable})

      true ->
        # Cooldown state was recreated since the last cycle: whatever we knew about
        # recent evictions is gone, so make hot nodes wait out the full window again.
        hot_since = if s.store_instance in [nil, instance], do: s.hot_since, else: %{}
        s = %{s | hot_since: hot_since, store_instance: instance}
        evaluate(s, cfg, settings)
    end
  end

  defp evaluate(s, cfg, settings) do
    mono = s.clock.()
    Cooldowns.prune(s.cooldowns, mono)
    kube_nodes = Safe.kube(&Cadmium.Kube.list_nodes/0)

    ctx = %{
      config: cfg,
      dry_run?: settings.dry_run? != false,
      spread_only?: s.spread_only?,
      leader_fun: s.leader_fun,
      clock: s.clock,
      cooldowns: s.cooldowns,
      audit: s.audit,
      actor: s.actor
    }

    cond do
      Executor.sweep_taints(ctx, kube_nodes) == :aborted ->
        cycle_result(s, {:skipped, :not_leader})

      settings.enabled? != true ->
        cycle_result(s, {:skipped, :disabled}, %{hot_since: %{}})

      true ->
        scores = s.nodes_fun.()
        hot_since = Policy.track_hot(s.hot_since, scores, cfg, mono)
        s = %{s | hot_since: hot_since}
        active = Cooldowns.active(s.cooldowns, mono)

        if s.spread_only? do
          AuditLog.record(s.audit,
            type: :manual_rebalance,
            actor: s.actor,
            dry_run?: settings.dry_run?,
            reason: "manual spread-only rebalance; sustained wait skipped"
          )
        end

        plan =
          Planner.build(
            config: if(s.spread_only?, do: %{cfg | hot_threshold: 0}, else: cfg),
            scores: scores,
            kube_nodes: kube_nodes,
            hot_since: hot_since,
            mono_now: mono,
            spread_only?: s.spread_only?,
            ignore_sustained?: s.spread_only?,
            generated_at: s.wall_clock.(),
            node_cooldowns: active.nodes,
            workload_cooldowns: active.workloads,
            workloads_fun: s.workloads_fun
          )

        # hot_since is already in the result if execution blows up below.
        try do
          Executor.execute(plan, ctx)
          cycle_result(s, {:ok, plan})
        rescue
          e -> cycle_result(s, {:error, {:exception, Exception.message(e)}})
        catch
          kind, reason -> cycle_result(s, {:error, {kind, reason}})
        end
    end
  end

  ## Status

  defp build_status(state) do
    settings = Settings.fetch(state.settings) || Settings.defaults(state.config)

    {plan, evaluated_at, cooldowns} =
      case state do
        %{leader?: false, remote: %{} = remote} ->
          {Map.get(remote, :last_plan), Map.get(remote, :last_evaluated_at),
           Map.get(remote, :cooldowns, %{nodes: %{}, workloads: %{}})}

        _ ->
          {state.last_plan, state.last_evaluated_at, wall_cooldowns(state)}
      end

    %{
      dry_run?: settings.dry_run?,
      enabled?: settings.enabled?,
      leader: Safe.call(state.leader_current_fun, nil),
      leader?: state.leader?,
      last_plan: plan,
      last_evaluated_at: evaluated_at,
      cooldowns: cooldowns
    }
  end

  defp wall_cooldowns(state) do
    mono = state.clock.()
    wall = state.wall_clock.()
    active = Cooldowns.active(state.cooldowns, mono)

    to_wall = fn entries ->
      Map.new(entries, fn {key, expiry} -> {key, wall + expiry - mono} end)
    end

    %{nodes: to_wall.(active.nodes), workloads: to_wall.(active.workloads)}
  end

  defp announce_status(state) do
    Safe.call(
      fn ->
        Phoenix.PubSub.local_broadcast(
          state.pubsub,
          state.topic,
          {:catalyst_status, build_status(state)}
        )
      end,
      :ok
    )
  end

  defp publish_leader_state(state) do
    payload = %{
      from: state.actor,
      last_plan: state.last_plan,
      last_evaluated_at: state.last_evaluated_at,
      cooldowns: wall_cooldowns(state)
    }

    Safe.call(
      fn ->
        Phoenix.PubSub.broadcast_from(
          state.pubsub,
          self(),
          state.sync_topic,
          {:catalyst_leader_state, payload}
        )
      end,
      :ok
    )
  end

  defp schedule_tick(state) do
    interval =
      case state.interval do
        nil -> Config.load(state.config).evaluate_interval_ms
        other -> other
      end

    if is_integer(interval) and interval > 0, do: Process.send_after(self(), :tick, interval)
    :ok
  end
end
