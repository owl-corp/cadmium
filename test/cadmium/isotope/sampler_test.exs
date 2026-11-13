defmodule Cadmium.Isotope.SamplerTest do
  use ExUnit.Case, async: true

  import Cadmium.IsotopeFixtures, only: [node_raw: 0, node_raw: 1, pod_raw: 0, pod_raw: 1]
  import ExUnit.CaptureLog

  alias Cadmium.Isotope.{NodeSample, PodSample, RingBuffer, Sampler}
  alias Cadmium.IsotopeScriptedSource, as: Scripted

  @pod_a "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b"
  @pod_b "a1b2c3d4-e5f6-4789-8abc-def012345678"

  setup do
    table = :"sampler_test_#{System.unique_integer([:positive])}"
    topic = "isotope:test:#{table}"
    clock = :atomics.new(1, [])
    {:ok, script} = Scripted.start_script([])

    start_supervised!({RingBuffer, name: table, capacity: 5})
    Phoenix.PubSub.subscribe(Cadmium.PubSub, topic)

    opts = [
      name: nil,
      table: table,
      topic: topic,
      source: Scripted,
      script: script,
      interval_ms: :manual,
      clock: fn -> :atomics.get(clock, 1) end
    ]

    %{table: table, topic: topic, clock: clock, script: script, opts: opts}
  end

  defp start(ctx, extra \\ []), do: start_supervised!({Sampler, Keyword.merge(ctx.opts, extra)})

  defp advance(ctx, ms), do: :atomics.add(ctx.clock, 1, ms)

  defp ok(node, pods \\ %{}), do: {:ok, %{node: node, pods: pods}}

  defp busier(busy, total), do: node_raw(%{cpu: %{busy: busy, total: total}})

  defp pod_cpu(usage_usec),
    do: pod_raw(%{cpu: %{usage_usec: usage_usec, nr_periods: 0, nr_throttled: 0}})

  describe "sampling" do
    test "the first tick has gauges but no rates; the second has both", ctx do
      Scripted.push(ctx.script, [
        ok(busier(1_000, 10_000), %{@pod_a => pod_cpu(1_000_000)}),
        ok(busier(1_400, 10_800), %{@pod_a => pod_cpu(1_250_000)})
      ])

      sampler = start(ctx)

      assert {:ok, %NodeSample{} = first} = Sampler.tick(sampler)
      assert first.cpu_usage_ratio == nil
      assert first.major_faults_per_s == nil
      assert first.psi_cpu_some == 12.5
      assert first.memory_used_ratio == 0.6
      assert_in_delta first.ts, System.system_time(:millisecond), 5_000

      advance(ctx, 1_000)
      assert {:ok, second} = Sampler.tick(sampler)
      assert second.cpu_usage_ratio == 0.5
      assert second.major_faults_per_s == 0.0
      assert second.ts >= first.ts

      assert RingBuffer.last(ctx.table, Sampler.node_series(), 10) == [first, second]

      assert [%PodSample{cpu_usage_millis: nil}, %PodSample{pod_uid: @pod_a} = pod] =
               RingBuffer.last(ctx.table, Sampler.pod_series(@pod_a), 10)

      assert pod.cpu_usage_millis == 250.0
      assert pod.memory_bytes == 64_000_000
      assert pod.ts == second.ts
    end

    test "rates use the real time between readings, not the nominal interval", ctx do
      Scripted.push(ctx.script, [
        ok(node_raw(), %{@pod_a => pod_cpu(0)}),
        ok(node_raw(%{vm: %{pgmajfault: 150}}), %{@pod_a => pod_cpu(1_000_000)})
      ])

      sampler = start(ctx)
      Sampler.tick(sampler)
      advance(ctx, 4_000)

      assert {:ok, sample} = Sampler.tick(sampler)
      assert sample.major_faults_per_s == 12.5

      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_a)).cpu_usage_millis == 250.0
    end

    test "broadcasts every node sample locally", ctx do
      Scripted.push(ctx.script, [ok(node_raw()), ok(node_raw())])
      sampler = start(ctx)

      {:ok, first} = Sampler.tick(sampler)
      assert_receive {:isotope_sample, ^first}

      advance(ctx, 1_000)
      {:ok, second} = Sampler.tick(sampler)
      assert_receive {:isotope_sample, ^second}
      refute_received {:isotope_sample, _}
    end

    test "a counter reset gives nil for that tick and recovers on the next", ctx do
      Scripted.push(ctx.script, [
        ok(busier(5_000, 50_000), %{@pod_a => pod_cpu(9_000_000)}),
        ok(busier(10, 100), %{@pod_a => pod_cpu(1_000)}),
        ok(busier(20, 200), %{@pod_a => pod_cpu(101_000)})
      ])

      sampler = start(ctx)
      Sampler.tick(sampler)

      advance(ctx, 1_000)
      assert {:ok, reset} = Sampler.tick(sampler)
      assert reset.cpu_usage_ratio == nil
      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_a)).cpu_usage_millis == nil

      advance(ctx, 1_000)
      assert {:ok, after_reset} = Sampler.tick(sampler)
      assert after_reset.cpu_usage_ratio == 0.1
      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_a)).cpu_usage_millis == 100.0
    end

    test "keeps at most history_size samples per series", ctx do
      Scripted.push(ctx.script, for(_ <- 1..12, do: ok(node_raw(), %{@pod_a => pod_raw()})))
      sampler = start(ctx)

      samples =
        for _ <- 1..12 do
          advance(ctx, 1_000)
          {:ok, sample} = Sampler.tick(sampler)
          sample
        end

      assert RingBuffer.last(ctx.table, Sampler.node_series(), 100) == Enum.take(samples, -5)
      assert RingBuffer.size(ctx.table, Sampler.pod_series(@pod_a)) == 5
    end
  end

  describe "pods coming and going" do
    test "a new pod starts with nil rates; a vanished pod's series is removed", ctx do
      Scripted.push(ctx.script, [
        ok(node_raw(), %{@pod_a => pod_cpu(0)}),
        ok(node_raw(), %{@pod_a => pod_cpu(100_000), @pod_b => pod_cpu(7_000_000)}),
        ok(node_raw(), %{@pod_b => pod_cpu(7_200_000)}),
        ok(node_raw(), %{})
      ])

      sampler = start(ctx)
      Sampler.tick(sampler)

      advance(ctx, 1_000)
      Sampler.tick(sampler)
      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_a)).cpu_usage_millis == 100.0
      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_b)).cpu_usage_millis == nil

      advance(ctx, 1_000)
      Sampler.tick(sampler)
      assert RingBuffer.last(ctx.table, Sampler.pod_series(@pod_a), 10) == []
      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_b)).cpu_usage_millis == 200.0
      assert Enum.sort(RingBuffer.series(ctx.table)) == [:node, {:pod, @pod_b}]

      advance(ctx, 1_000)
      Sampler.tick(sampler)
      assert RingBuffer.series(ctx.table) == [:node]
    end

    test "pod churn does not grow the table", ctx do
      uids = for i <- 1..200, do: "00000000-0000-4000-8000-#{String.pad_leading("#{i}", 12, "0")}"
      Scripted.push(ctx.script, for(uid <- uids, do: ok(node_raw(), %{uid => pod_raw()})))
      sampler = start(ctx)

      for _ <- uids, do: {:ok, _} = Sampler.tick(sampler)

      assert length(RingBuffer.series(ctx.table)) == 2
      # capacity row + 5 node samples + the one live pod's single sample
      assert :ets.info(ctx.table, :size) == 1 + 5 + 1
    end

    test "series left behind by a previous sampler are cleaned up", ctx do
      RingBuffer.push(ctx.table, Sampler.pod_series(@pod_b), :stale)
      Scripted.push(ctx.script, [ok(node_raw(), %{@pod_a => pod_raw()})])

      Sampler.tick(start(ctx))

      assert RingBuffer.series(ctx.table) |> Enum.sort() == [:node, {:pod, @pod_a}]
    end
  end

  describe "a misbehaving source" do
    test "errors, raises, exits, throws and bad returns never stop sampling", ctx do
      Scripted.push(ctx.script, [
        ok(node_raw(%{vm: %{pgmajfault: 100}})),
        {:error, :enoent},
        {:raise, "boom"},
        {:exit, :kaboom},
        {:throw, :ball},
        {:return, :nonsense},
        {:return, {:ok, %{node: nil, pods: []}, :state}},
        ok(node_raw(%{vm: %{pgmajfault: 800}}))
      ])

      sampler = start(ctx)
      {:ok, good} = Sampler.tick(sampler)

      log =
        capture_log(fn ->
          advance(ctx, 1_000)
          assert Sampler.tick(sampler) == {:error, :enoent}
          advance(ctx, 1_000)
          assert {:error, {:exception, %RuntimeError{message: "boom"}, _}} = Sampler.tick(sampler)
          advance(ctx, 1_000)
          assert Sampler.tick(sampler) == {:error, {:exit, :kaboom}}
          advance(ctx, 1_000)
          assert Sampler.tick(sampler) == {:error, {:throw, :ball}}
          advance(ctx, 1_000)
          assert Sampler.tick(sampler) == {:error, {:bad_source_read, :nonsense}}
          advance(ctx, 1_000)
          assert {:error, {:bad_source_read, _}} = Sampler.tick(sampler)
        end)

      assert log =~ "failed to produce a sample"
      assert log =~ ":enoent"

      # nothing was stored or published for the failed ticks
      assert RingBuffer.last(ctx.table, Sampler.node_series(), 10) == [good]
      assert_receive {:isotope_sample, ^good}
      refute_received {:isotope_sample, _}

      # the next good reading is diffed against the last good one, 7 seconds earlier
      advance(ctx, 1_000)
      assert {:ok, recovered} = Sampler.tick(sampler)
      assert recovered.major_faults_per_s == 100.0
      assert_receive {:isotope_sample, ^recovered}
    end

    test "malformed pod entries in a reading are skipped", ctx do
      Scripted.push(ctx.script, [
        ok(node_raw(), %{@pod_a => pod_raw(), @pod_b => :not_a_map, 42 => pod_raw()}),
        ok(%{cpu: "garbage", psi_cpu: [1, 2], memory: 7}, %{@pod_a => %{cpu: :bad, io: "x"}})
      ])

      sampler = start(ctx)

      assert {:ok, %NodeSample{}} = Sampler.tick(sampler)
      assert Enum.sort(RingBuffer.series(ctx.table)) == [:node, {:pod, @pod_a}]

      # values of the wrong type are treated as missing
      assert {:ok, sample} = Sampler.tick(sampler)
      assert sample == %NodeSample{ts: sample.ts}

      assert RingBuffer.latest(ctx.table, Sampler.pod_series(@pod_a)) ==
               %PodSample{pod_uid: @pod_a, ts: sample.ts}
    end

    test "failure logging is rate limited", ctx do
      Scripted.push(ctx.script, for(_ <- 1..7, do: {:error, :still_broken}))
      sampler = start(ctx, log_interval_ms: 30_000)

      log =
        capture_log(fn ->
          for _ <- 1..5 do
            assert {:error, :still_broken} = Sampler.tick(sampler)
            advance(ctx, 1_000)
          end
        end)

      assert length(String.split(log, "failed to produce a sample")) == 2
      assert log =~ "(1 consecutive)"

      advance(ctx, 30_000)
      log = capture_log(fn -> Sampler.tick(sampler) end)
      assert log =~ "(6 consecutive)"

      assert capture_log(fn -> Sampler.tick(sampler) end) == ""
    end

    test "a failure after a recovery is logged straight away", ctx do
      Scripted.push(ctx.script, [{:error, :first}, ok(node_raw()), {:error, :second}])
      sampler = start(ctx)

      assert capture_log(fn -> Sampler.tick(sampler) end) =~ ":first"
      assert {:ok, _} = Sampler.tick(sampler)
      assert capture_log(fn -> Sampler.tick(sampler) end) =~ ":second"
    end

    test "a source that cannot initialise is retried on every tick", ctx do
      {:ok, init_script} = Scripted.start_script([{:error, :not_yet}, {:raise, "nope"}, :ok])
      Scripted.push(ctx.script, [ok(node_raw())])
      sampler = start(ctx, init_script: init_script)

      capture_log(fn ->
        assert Sampler.tick(sampler) == {:error, {:source_init, :not_yet}}
        assert {:error, {:exception, %RuntimeError{message: "nope"}, _}} = Sampler.tick(sampler)
      end)

      assert {:ok, %NodeSample{}} = Sampler.tick(sampler)
    end
  end

  describe "the timer" do
    test "ticks on its own, starting immediately", ctx do
      Scripted.push(ctx.script, for(_ <- 1..50, do: ok(node_raw())))
      start(ctx, interval_ms: 5)

      assert_receive {:isotope_sample, %NodeSample{}}, 1_000
      assert_receive {:isotope_sample, %NodeSample{}}, 1_000
      assert_receive {:isotope_sample, %NodeSample{}}, 1_000
    end

    test "keeps ticking through source failures", ctx do
      Scripted.push(ctx.script, [{:raise, "boom"}, {:error, :nope}, ok(node_raw())])

      capture_log(fn ->
        start(ctx, interval_ms: 5)
        assert_receive {:isotope_sample, %NodeSample{}}, 1_000
      end)
    end

    test "manual mode never ticks by itself, and stray messages are ignored", ctx do
      Scripted.push(ctx.script, [ok(node_raw())])
      sampler = start(ctx)

      send(sampler, :unexpected)
      _ = :sys.get_state(sampler)
      refute_received {:isotope_sample, _}
      assert RingBuffer.latest(ctx.table, Sampler.node_series()) == nil
    end
  end

  test "is registered under a name when given one", ctx do
    name = :"#{ctx.table}_sampler"
    Scripted.push(ctx.script, [ok(node_raw())])
    start(ctx, name: name)

    assert {:ok, %NodeSample{}} = Sampler.tick(name)
  end
end
