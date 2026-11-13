defmodule Cadmium.Valence.ScoreTest do
  use ExUnit.Case, async: true

  alias Cadmium.Isotope.NodeSample
  alias Cadmium.Valence.Score

  @idle [
    cpu_usage_ratio: 0.1,
    cpu_throttled_ratio: 0.0,
    psi_cpu_some: 0.0,
    psi_memory_some: 0.0,
    psi_memory_full: 0.0,
    psi_io_some: 0.0,
    psi_io_full: 0.0,
    memory_used_ratio: 0.3,
    major_faults_per_s: 0.0
  ]

  defp sample(ts, fields), do: struct!(NodeSample, [ts: ts] ++ fields)

  # `n` identical one-per-second samples
  defp steady(fields, n \\ 10), do: for(i <- 1..n, do: sample(i * 1_000, fields))

  defp score(fields), do: fields |> steady() |> Score.compute()

  describe "curves" do
    test "saturate is 0 at 0, ~63 at the knee, monotonic and bounded" do
      assert Score.saturate(0, 25) == 0.0
      assert Score.saturate(-5, 25) == 0.0
      assert_in_delta Score.saturate(25, 25), 63.21, 0.01
      assert Score.saturate(10, 25) < Score.saturate(20, 25)
      assert Score.saturate(10_000, 25) <= 100.0
    end

    test "ramp ignores low utilisation and is convex above the threshold" do
      assert Score.ramp(0.2, 0.5) == 0.0
      assert Score.ramp(0.5, 0.5) == 0.0
      assert_in_delta Score.ramp(0.75, 0.5), 25.0, 1.0e-9
      assert Score.ramp(1.0, 0.5) == 100.0
      assert Score.ramp(1.7, 0.5) == 100.0
    end
  end

  describe "compute/2" do
    test "empty window scores zero" do
      assert Score.compute([]) == %{score: 0.0, components: %{cpu: 0.0, memory: 0.0, io: 0.0}}
    end

    test "an idle node scores zero" do
      assert %{score: +0.0, components: %{cpu: +0.0, memory: +0.0, io: +0.0}} = score(@idle)
    end

    test "a fully saturated node scores close to 100 and never above" do
      result =
        score(
          cpu_usage_ratio: 1.0,
          cpu_throttled_ratio: 1.0,
          psi_cpu_some: 100.0,
          psi_memory_some: 100.0,
          psi_memory_full: 100.0,
          psi_io_some: 100.0,
          psi_io_full: 100.0,
          memory_used_ratio: 1.0,
          major_faults_per_s: 50_000.0
        )

      assert result.score > 97.0 and result.score <= 100.0

      for {_name, value} <- result.components do
        assert value > 97.0 and value <= 100.0
      end
    end

    test "matches the documented formula" do
      result = score(Keyword.merge(@idle, psi_cpu_some: 20.0, cpu_throttled_ratio: 0.2))

      # cpu = 0.5 * 63.21 + 0.3 * 63.21 + 0.2 * 0
      assert_in_delta result.components.cpu, 50.57, 0.01
      assert result.components.memory == 0.0
      assert result.components.io == 0.0
      # overall = 0.8 * max + 0.2 * (0.4 * cpu)
      assert_in_delta result.score, 0.8 * 50.57 + 0.2 * 0.4 * 50.57, 0.02
    end

    test "contention outweighs utilisation" do
      busy_but_fine = score(Keyword.merge(@idle, cpu_usage_ratio: 0.95, memory_used_ratio: 0.9))

      contended =
        score(
          Keyword.merge(@idle, cpu_usage_ratio: 0.6, psi_cpu_some: 40.0, cpu_throttled_ratio: 0.3)
        )

      assert contended.components.cpu > 3 * busy_but_fine.components.cpu
      assert contended.score > 2 * busy_but_fine.score
      # usage alone can never make a node hot
      assert busy_but_fine.score < 25.0
    end

    test "the worst component dominates the overall score" do
      result = score(Keyword.merge(@idle, psi_io_some: 80.0, psi_io_full: 60.0))

      assert result.components.io > 95.0
      assert result.components.cpu == 0.0
      assert result.score >= 0.8 * result.components.io
      assert result.score < result.components.io
    end

    test "memory pressure is weighted more aggressively than cpu pressure" do
      cpu = score(Keyword.merge(@idle, psi_cpu_some: 10.0))
      memory = score(Keyword.merge(@idle, psi_memory_some: 10.0, psi_memory_full: 10.0))

      assert memory.components.memory > cpu.components.cpu
    end

    test "each pressure signal raises its own component only" do
      base = score(@idle)

      for {field, value, component} <- [
            {:psi_cpu_some, 30.0, :cpu},
            {:cpu_throttled_ratio, 0.4, :cpu},
            {:psi_memory_some, 20.0, :memory},
            {:psi_memory_full, 10.0, :memory},
            {:major_faults_per_s, 400.0, :memory},
            {:psi_io_some, 30.0, :io},
            {:psi_io_full, 15.0, :io}
          ] do
        result = score(Keyword.put(@idle, field, value))
        assert result.components[component] > base.components[component]
        assert result.score > base.score

        for other <- [:cpu, :memory, :io] -- [component] do
          assert result.components[other] == base.components[other]
        end
      end
    end

    test "nil fields are ignored and the remaining weights renormalised" do
      # Without PSI (old kernel) throttling and usage carry the whole cpu component.
      no_psi = score(cpu_usage_ratio: 1.0, cpu_throttled_ratio: 0.25)
      expected_cpu = (0.3 * Score.saturate(0.25, 0.2) + 0.2 * 100.0) / 0.5
      assert_in_delta no_psi.components.cpu, expected_cpu, 0.01

      # memory and io have no signals at all: reported as 0 but not dragging the mean down
      assert no_psi.components.memory == 0.0
      assert no_psi.components.io == 0.0
      assert_in_delta no_psi.score, expected_cpu, 0.01
    end

    test "samples with every field nil score zero" do
      assert %{score: +0.0} = Score.compute(steady([]))
    end

    test "nil readings inside the window are skipped per field" do
      samples = [
        sample(1_000, psi_io_some: 20.0, psi_io_full: 10.0),
        sample(2_000, []),
        sample(3_000, psi_io_some: 20.0, psi_io_full: nil)
      ]

      assert_in_delta Score.compute(samples).components.io, 63.21, 0.01
    end

    test "one spiky second does not make a node hot" do
      spike =
        Keyword.merge(@idle, psi_cpu_some: 90.0, cpu_throttled_ratio: 0.9, cpu_usage_ratio: 0.95)

      calm = steady(@idle, 9)

      spike_last = Score.compute(calm ++ [sample(10_000, spike)])
      spike_first = Score.compute([sample(500, spike) | calm])
      sustained = score(spike)

      assert sustained.score > 70.0
      assert spike_last.score < 0.6 * sustained.score
      assert spike_last.score < 50.0
      # an old spike has all but decayed away
      assert spike_first.score < 15.0
      assert spike_first.score < spike_last.score
    end

    test "sustained pressure converges to the steady-state score" do
      pressured = Keyword.merge(@idle, psi_cpu_some: 50.0)
      ramping = steady(@idle, 3) ++ for i <- 4..10, do: sample(i * 1_000, pressured)
      steady_state = score(pressured)

      assert_in_delta Score.compute(ramping).components.cpu, steady_state.components.cpu, 5.0
    end

    test "sample order does not matter and samples outside the window are dropped" do
      samples = steady(Keyword.merge(@idle, psi_cpu_some: 30.0))
      assert Score.compute(Enum.shuffle(samples)) == Score.compute(samples)

      ancient = sample(-5_000, Keyword.merge(@idle, psi_memory_full: 100.0))
      assert Score.compute([ancient | samples]) == Score.compute(samples)
      assert Score.compute([ancient | samples], window_ms: 120_000) != Score.compute(samples)
    end

    test "results are floats within 0..100 for arbitrary input" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..200 do
        fields =
          for {field, max} <- [
                cpu_usage_ratio: 1.5,
                cpu_throttled_ratio: 1.5,
                psi_cpu_some: 150.0,
                psi_memory_some: 150.0,
                psi_memory_full: 150.0,
                psi_io_some: 150.0,
                psi_io_full: 150.0,
                memory_used_ratio: 1.5,
                major_faults_per_s: 10_000.0
              ],
              :rand.uniform() > 0.3,
              do: {field, :rand.uniform() * max}

        %{score: score, components: components} = score(fields)

        for value <- [score | Map.values(components)] do
          assert is_float(value) and value >= 0.0 and value <= 100.0
        end

        assert score <= Enum.max(Map.values(components)) + 0.01
      end
    end
  end

  describe "smooth/2" do
    test "weights samples by age" do
      samples = [sample(1_000, psi_cpu_some: 10.0), sample(2_000, psi_cpu_some: 20.0)]
      w = :math.exp(-1_000 / 5_000)

      assert_in_delta Score.smooth(samples).psi_cpu_some, (20.0 + 10.0 * w) / (1 + w), 1.0e-9
      # a huge tau degenerates to the plain mean, a tiny one to the newest sample
      assert_in_delta Score.smooth(samples, tau_ms: 1.0e12).psi_cpu_some, 15.0, 1.0e-6
      assert_in_delta Score.smooth(samples, tau_ms: 1).psi_cpu_some, 20.0, 1.0e-6
      assert Score.smooth(samples).psi_io_full == nil
      assert Score.smooth([]).psi_cpu_some == nil
    end
  end
end
