defmodule Cadmium.Leader do
  @moduledoc """
  Leader election over a Kubernetes Lease (`coordination.k8s.io/v1`).

  One agent holds the lease and runs the Catalyst coordinator. The process acquires,
  renews and (on shutdown) releases the lease, and announces transitions on the local
  PubSub topic `topic/0` as `{:leadership, :acquired | :lost}`. The holder identity is
  `Cadmium.node_name/0`.

  Leadership must be reported as lost as soon as a renewal has not succeeded within the
  lease duration, even if the API server is unreachable.

  ## Algorithm

  The same as client-go's leader election:

    * no lease: create it;
    * lease without a holder, or held by us: take / renew it;
    * lease held by someone else: follow, and take it over (incrementing
      `transitions`) once it has not changed for its `duration_seconds`. Expiry is judged
      by how long ago *we* last saw the record change on our monotonic clock, never by
      comparing the remote `renew_time` with the local wall clock;
    * as leader: renew every `lease_renew_interval_ms` with a `resource_version`-guarded
      update. A conflict (someone else wrote the lease) means stepping down at once. Other
      failures are retried sooner, and leadership ends when the lease duration has passed
      since the start of the last successful renewal.

  `leader?/0` reads an ETS row holding that local deadline, so it is cheap, false when
  the process is not running, and never true past the deadline even while the process
  itself is stuck in an API call.

  ## Options

  All optional; the defaults come from `config :cadmium, Cadmium.Catalyst`.

    * `:name` - registered name and ETS table name (default `Cadmium.Leader`)
    * `:identity` - holder identity (default `Cadmium.node_name/0`)
    * `:lease_namespace`, `:lease_name`, `:lease_duration_s`, `:lease_renew_interval_ms`
    * `:retry_interval_ms` - delay after a failed attempt (default: half the renew interval)
    * `:jitter` - fraction of random extra delay added to every wait (default `0.1`)
    * `:clock` - zero-arity function returning monotonic milliseconds
    * `:now` - zero-arity function returning the wall-clock `DateTime` written to the lease
    * `:kube` - module with the lease functions of `Cadmium.Kube` (default `Cadmium.Kube`)
    * `:pubsub`, `:topic` - where transitions are broadcast (default `Cadmium.PubSub`, `topic/0`)

  With `lease_renew_interval_ms: :infinity` nothing is scheduled after the first round and
  rounds are driven with `tick/1`, which is how the tests stay deterministic.
  """

  use GenServer

  alias Cadmium.Kube.Lease

  require Logger

  @topic "leader"

  defstruct [
    :name,
    :identity,
    :namespace,
    :lease_name,
    :duration_s,
    :renew_ms,
    :retry_ms,
    :jitter,
    :clock,
    :now,
    :kube,
    :pubsub,
    :topic,
    # the lease as we last wrote it, while leading
    :lease,
    :deadline,
    # {holder, renew_time, resource_version} of the last record seen, and when it changed
    :observed,
    :observed_at,
    :tick_timer,
    :deadline_timer,
    leader?: false
  ]

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Cadmium.PubSub, @topic)

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "True when this agent currently holds a valid lease."
  @spec leader?(atom()) :: boolean()
  def leader?(name \\ __MODULE__) do
    case :ets.lookup(name, :leadership) do
      [{:leadership, deadline, clock}] when is_integer(deadline) -> clock.() < deadline
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Identity (Kubernetes node name) of the current lease holder as last observed."
  @spec current(atom()) :: String.t() | nil
  def current(name \\ __MODULE__) do
    case :ets.lookup(name, :holder) do
      [{:holder, holder}] -> holder
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Runs one election round now and returns whether this process leads afterwards. The
  process does this by itself on a timer; this is for tests and debugging.
  """
  @spec tick(GenServer.server()) :: boolean()
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  ## GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Application.get_env(:cadmium, Cadmium.Catalyst, [])
    option = fn key, default -> Keyword.get(opts, key, Keyword.get(config, key, default)) end
    renew_ms = option.(:lease_renew_interval_ms, 5_000)

    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      identity: Keyword.get_lazy(opts, :identity, &Cadmium.node_name/0),
      namespace: option.(:lease_namespace, "default"),
      lease_name: option.(:lease_name, "cadmium-catalyst"),
      duration_s: option.(:lease_duration_s, 15),
      renew_ms: renew_ms,
      retry_ms: Keyword.get_lazy(opts, :retry_interval_ms, fn -> default_retry(renew_ms) end),
      jitter: Keyword.get(opts, :jitter, 0.1),
      clock: Keyword.get(opts, :clock, &__MODULE__.monotonic_ms/0),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      kube: Keyword.get(opts, :kube, Cadmium.Kube),
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get(opts, :topic, @topic)
    }

    :ets.new(state.name, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(state.name, [{:leadership, nil, state.clock}, {:holder, nil}])

    {:ok, state, {:continue, :tick}}
  end

  @doc false
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  defp default_retry(:infinity), do: :infinity
  defp default_retry(renew_ms), do: max(div(renew_ms, 2), 1)

  @impl true
  def handle_continue(:tick, state), do: {:noreply, run_round(state)}

  @impl true
  def handle_call(:tick, _from, state) do
    state = run_round(state)
    {:reply, state.leader?, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, run_round(%{state | tick_timer: nil})}

  def handle_info(:deadline, state) do
    state = check_deadline(%{state | deadline_timer: nil})
    {:noreply, if(state.leader?, do: arm_deadline(state), else: state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.leader? and state.clock.() < state.deadline do
      released = %{state.lease | holder: nil, renew_time: state.now.(), duration_seconds: 1}

      case kube(state, :update_lease, [released]) do
        {:ok, _lease} -> :ok
        {:error, reason} -> Logger.warning("could not release the lease: #{inspect(reason)}")
      end
    end

    step_down(state, :shutdown)
    :ok
  end

  ## Election

  defp run_round(state) do
    started = state.clock.()
    state = check_deadline(state)

    {state, wait} =
      if state.leader?, do: renew(state, started), else: contend(state, started)

    schedule_tick(state, wait)
  end

  defp renew(state, started) do
    lease = %{state.lease | renew_time: state.now.(), duration_seconds: state.duration_s}

    case kube(state, :update_lease, [lease]) do
      {:ok, lease} ->
        {lead(state, lease, started), state.renew_ms}

      {:error, reason} when reason in [:conflict, :not_found] ->
        {step_down(state, "the lease was changed by someone else"), state.retry_ms}

      {:error, reason} ->
        Logger.warning("lease renewal failed: #{inspect(reason)}")
        {check_deadline(state), state.retry_ms}
    end
  end

  defp contend(state, started) do
    case kube(state, :get_lease, [state.namespace, state.lease_name]) do
      {:error, :not_found} ->
        now = state.now.()

        lease = %Lease{
          namespace: state.namespace,
          name: state.lease_name,
          holder: state.identity,
          acquire_time: now,
          renew_time: now,
          duration_seconds: state.duration_s,
          transitions: 0
        }

        acquire(state, :create_lease, lease, started)

      {:ok, %Lease{} = lease} ->
        state = observe(state, lease, started)
        now = state.now.()

        cond do
          lease.holder == state.identity ->
            # ours from before a restart or a step-down: carry on without a transition
            lease = %{
              lease
              | acquire_time: lease.acquire_time || now,
                renew_time: now,
                duration_seconds: state.duration_s
            }

            acquire(state, :update_lease, lease, started)

          lease.holder in [nil, ""] or expired?(state, lease, started) ->
            lease = %{
              lease
              | holder: state.identity,
                acquire_time: now,
                renew_time: now,
                duration_seconds: state.duration_s,
                transitions: (lease.transitions || 0) + 1
            }

            acquire(state, :update_lease, lease, started)

          true ->
            {state, state.renew_ms}
        end

      {:error, reason} ->
        Logger.debug("could not read the lease: #{inspect(reason)}")
        {state, state.retry_ms}
    end
  end

  defp acquire(state, operation, lease, started) do
    case kube(state, operation, [lease]) do
      {:ok, lease} ->
        {lead(state, lease, started), state.renew_ms}

      {:error, reason} ->
        # typically :conflict - another contender got there first
        Logger.debug("could not acquire the lease: #{inspect(reason)}")
        {state, state.retry_ms}
    end
  end

  defp observe(state, lease, at) do
    put_holder(state, lease.holder)

    case {lease.holder, lease.renew_time, lease.resource_version} do
      observed when observed == state.observed -> state
      observed -> %{state | observed: observed, observed_at: at}
    end
  end

  defp expired?(state, lease, at),
    do: at >= state.observed_at + (lease.duration_seconds || state.duration_s) * 1_000

  # The lease is ours as of `started`, the moment the successful request was sent.
  defp lead(state, lease, started) do
    deadline = started + state.duration_s * 1_000
    :ets.insert(state.name, [{:leadership, deadline, state.clock}, {:holder, state.identity}])

    if not state.leader? do
      Logger.info("#{state.identity} acquired the leader lease #{state.lease_name}")
      broadcast(state, :acquired)
    end

    %{state | leader?: true, lease: lease, deadline: deadline, observed: nil, observed_at: nil}
    |> arm_deadline()
    |> check_deadline()
  end

  defp check_deadline(%{leader?: true} = state) do
    if state.clock.() >= state.deadline,
      do: step_down(state, "the lease was not renewed in time"),
      else: state
  end

  defp check_deadline(state), do: state

  defp step_down(%{leader?: true} = state, why) do
    :ets.insert(state.name, {:leadership, nil, state.clock})
    cancel(state.deadline_timer)

    case why do
      :shutdown -> Logger.info("#{state.identity} gave up the leader lease #{state.lease_name}")
      why -> Logger.warning("#{state.identity} lost the leader lease #{state.lease_name}: #{why}")
    end

    broadcast(state, :lost)
    %{state | leader?: false, lease: nil, deadline: nil, deadline_timer: nil}
  end

  defp step_down(state, _why), do: state

  defp broadcast(state, event),
    do: Phoenix.PubSub.local_broadcast(state.pubsub, state.topic, {:leadership, event})

  defp put_holder(state, holder) do
    holder = if holder == "", do: nil, else: holder
    :ets.insert(state.name, {:holder, holder})
  end

  defp kube(state, function, args) do
    apply(state.kube, function, args)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  ## Timers

  defp schedule_tick(state, wait) do
    cancel(state.tick_timer)

    timer =
      if wait != :infinity, do: Process.send_after(self(), :tick, jitter(wait, state.jitter))

    %{state | tick_timer: timer}
  end

  # Makes the :lost announcement prompt even if the next round is far away or slow.
  defp arm_deadline(state) do
    cancel(state.deadline_timer)
    remaining = max(state.deadline - state.clock.(), 1)
    %{state | deadline_timer: Process.send_after(self(), :deadline, remaining)}
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp jitter(wait, fraction) do
    case trunc(wait * fraction) do
      extra when extra > 0 -> wait + :rand.uniform(extra)
      _ -> wait
    end
  end
end
