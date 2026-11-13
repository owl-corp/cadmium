defmodule Cadmium.IsotopeTest do
  # not async: uses the globally named supervisor, sampler and ring buffer
  use ExUnit.Case, async: false

  alias Cadmium.Isotope
  alias Cadmium.Isotope.{NodeSample, PodSample, Sampler}

  describe "without a running sampler" do
    test "everything returns its documented empty value" do
      assert Isotope.latest() == nil
      assert Isotope.history() == []
      assert Isotope.history(5) == []
      assert Isotope.pod_samples() == []
      assert Isotope.pod_history("0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b") == []
      assert Isotope.pod_history("0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b", 5) == []
    end

    test "the topic is part of the contract" do
      assert Isotope.topic() == "isotope:samples"
    end
  end

  describe "with the supervisor running (synthetic source)" do
    setup do
      clock = :atomics.new(1, [])
      :atomics.put(clock, 1, 1_800_000_000_000)

      start_supervised!(
        {Isotope.Supervisor,
         source: Isotope.Source.Synthetic,
         interval_ms: :manual,
         history_size: 4,
         clock: fn -> :atomics.get(clock, 1) end}
      )

      tick = fn ->
        :atomics.add(clock, 1, 1_000)
        {:ok, sample} = Sampler.tick()
        sample
      end

      %{tick: tick, uids: Enum.map(Cadmium.Demo.pods(Cadmium.node_name()), & &1.uid)}
    end

    test "is empty before the first tick" do
      assert Isotope.latest() == nil
      assert Isotope.history() == []
      assert Isotope.pod_samples() == []
    end

    test "latest/0 and history/1 return node samples, oldest first", %{tick: tick} do
      first = tick.()
      assert Isotope.latest() == first
      assert Isotope.history() == [first]

      second = tick.()
      third = tick.()

      assert %NodeSample{cpu_usage_ratio: ratio, load1: load1} = Isotope.latest()
      assert Isotope.latest() == third
      assert is_float(ratio) and ratio >= 0.0 and ratio <= 1.0
      assert is_float(load1)

      assert Isotope.history() == [first, second, third]
      assert Isotope.history(2) == [second, third]
      assert Isotope.history(1) == [third]
    end

    test "history is bounded by history_size", %{tick: tick} do
      samples = for _ <- 1..7, do: tick.()
      assert Isotope.history(100) == Enum.take(samples, -4)
    end

    test "pod_samples/0 has the latest sample of every pod", %{tick: tick, uids: uids} do
      tick.()
      node = tick.()

      samples = Isotope.pod_samples()

      assert samples |> Enum.map(& &1.pod_uid) |> Enum.sort() == Enum.sort(uids)

      for %PodSample{} = sample <- samples do
        assert sample.ts == node.ts
        assert sample.cpu_usage_millis > 0.0
        assert sample.memory_bytes > 0
        assert sample.cpu_throttled_ratio >= 0.0
      end
    end

    test "pod_history/2 returns one pod's samples, oldest first", %{tick: tick, uids: [uid | _]} do
      for _ <- 1..3, do: tick.()

      assert [a, b, c] = Isotope.pod_history(uid)
      assert Enum.all?([a, b, c], &(&1.pod_uid == uid))
      assert a.cpu_usage_millis == nil
      assert is_float(b.cpu_usage_millis)
      assert Isotope.pod_history(uid, 2) == [b, c]
      assert List.last(Isotope.pod_history(uid)) in Isotope.pod_samples()

      assert Isotope.pod_history("00000000-0000-0000-0000-000000000000") == []
    end

    test "subscribe/0 delivers each node sample", %{tick: tick} do
      :ok = Isotope.subscribe()
      sample = tick.()
      assert_receive {:isotope_sample, ^sample}
    end

    test "reads do not go through the sampler process", %{tick: tick} do
      sample = tick.()
      :sys.suspend(Sampler)

      assert Isotope.latest() == sample
      assert length(Isotope.pod_samples()) > 0

      :sys.resume(Sampler)
    end

    test "samples survive a sampler crash, and sampling resumes", %{tick: tick} do
      before = tick.()

      pid = Process.whereis(Sampler)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # the supervisor has restarted the sampler by the time it answers
      assert [_, _] = Supervisor.which_children(Isotope.Supervisor)
      assert Process.whereis(Sampler) != pid
      assert Isotope.latest() == before

      later = tick.()
      assert Isotope.history() == [before, later]
    end
  end

  test "is empty again once the supervisor has stopped" do
    start_supervised!(
      {Isotope.Supervisor, source: Isotope.Source.Synthetic, interval_ms: :manual}
    )

    assert {:ok, _} = Sampler.tick()
    assert %NodeSample{} = Isotope.latest()

    stop_supervised!(Isotope.Supervisor)

    assert Isotope.latest() == nil
    assert Isotope.pod_samples() == []
  end

  test "the supervisor and sampler names can be overridden" do
    start_supervised!(
      {Isotope.Supervisor,
       name: :isotope_test_supervisor,
       sampler_name: :isotope_test_sampler,
       table: :isotope_test_table,
       source: Isotope.Source.Synthetic,
       interval_ms: :manual}
    )

    assert {:ok, sample} = Sampler.tick(:isotope_test_sampler)
    assert Isotope.RingBuffer.latest(:isotope_test_table, Sampler.node_series()) == sample
    assert Isotope.latest() == nil
  end
end
