defmodule Cadmium.Valence.BroadcasterTest do
  use ExUnit.Case, async: true

  alias Cadmium.Isotope.{NodeSample, PodSample}
  alias Cadmium.Valence.{Broadcaster, NodeScore, Score}

  @now 1_700_000_000_000

  setup context do
    pubsub = Module.concat(__MODULE__, "PubSub#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, "scores")
    clock = start_supervised!({Agent, fn -> @now end})

    opts =
      Keyword.merge(
        [
          name: nil,
          pubsub: pubsub,
          topic: "scores",
          interval_ms: :infinity,
          subscribe: fn -> :ok end,
          pod_samples: fn ->
            [%PodSample{pod_uid: "a", ts: 1}, %PodSample{pod_uid: "b", ts: 1}]
          end,
          node_name: "node-a",
          clock: fn -> Agent.get(clock, & &1) end
        ],
        Map.get(context, :broadcaster, [])
      )

    {:ok, pid: start_supervised!({Broadcaster, opts}), clock: clock}
  end

  defp hot(ts), do: %NodeSample{ts: ts, psi_cpu_some: 60.0, cpu_throttled_ratio: 0.5}

  test "does not broadcast before any sample arrives", %{pid: pid} do
    assert Broadcaster.broadcast_now(pid) == :no_samples
    refute_received {:node_score, _}
  end

  test "broadcasts the score of the sample window", %{pid: pid} do
    samples = for i <- 5..1//-1, do: hot(@now - i * 1_000)
    Enum.each(samples, &send(pid, {:isotope_sample, &1}))

    assert {:ok, %NodeScore{} = score} = Broadcaster.broadcast_now(pid)
    assert_receive {:node_score, ^score}

    expected = Score.compute(samples)

    assert score == %NodeScore{
             k8s_node: "node-a",
             beam_node: node(),
             score: expected.score,
             components: expected.components,
             pod_count: 2,
             ts: @now
           }

    assert score.score > 40.0
  end

  test "ignores samples that have aged out of the window", %{pid: pid, clock: clock} do
    send(pid, {:isotope_sample, hot(@now - 60_000)})
    send(pid, {:isotope_sample, %NodeSample{ts: @now, psi_cpu_some: 0.0}})

    assert {:ok, %NodeScore{score: +0.0}} = Broadcaster.broadcast_now(pid)

    # the sampler died: once every sample is too old, stop broadcasting
    Agent.update(clock, &(&1 + 60_000))
    assert Broadcaster.broadcast_now(pid) == :no_samples
  end

  @tag broadcaster: [pod_samples: &__MODULE__.boom/0]
  test "a failing pod_samples source counts as zero pods", %{pid: pid} do
    send(pid, {:isotope_sample, hot(@now)})
    assert {:ok, %NodeScore{pod_count: 0}} = Broadcaster.broadcast_now(pid)
  end

  @tag broadcaster: [interval_ms: 10]
  test "broadcasts periodically on its own", %{pid: pid} do
    refute_receive {:node_score, _}, 50
    send(pid, {:isotope_sample, hot(@now)})

    assert_receive {:node_score, %NodeScore{k8s_node: "node-a"}}, 1_000
    assert_receive {:node_score, %NodeScore{k8s_node: "node-a"}}, 1_000
  end

  test "defaults subscribe to Isotope and use Cadmium.node_name/0" do
    pid = start_supervised!({Broadcaster, name: nil, interval_ms: :infinity}, id: :defaults)
    Phoenix.PubSub.subscribe(Cadmium.PubSub, Cadmium.Valence.scores_topic())
    ts = System.system_time(:millisecond)

    Phoenix.PubSub.local_broadcast(
      Cadmium.PubSub,
      Cadmium.Isotope.topic(),
      {:isotope_sample, %NodeSample{ts: ts, psi_io_some: 10.0}}
    )

    # the local broadcast above is delivered before this call is handled
    assert {:ok, %NodeScore{k8s_node: "test-node"} = score} = Broadcaster.broadcast_now(pid)
    assert_receive {:node_score, ^score}
  end

  def boom, do: raise("isotope is down")
end
