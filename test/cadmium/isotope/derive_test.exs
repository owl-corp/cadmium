defmodule Cadmium.Isotope.DeriveTest do
  use ExUnit.Case, async: true

  import Cadmium.IsotopeFixtures, only: [node_raw: 0, node_raw: 1, pod_raw: 0, pod_raw: 1]

  alias Cadmium.Isotope.{Derive, NodeSample, PodSample}

  @uid "0f5c2a1e-7b3d-4c8e-9a51-d2e4f6a8b09b"

  describe "node_sample/4" do
    test "first tick: gauges are populated, everything delta-based is nil" do
      assert %NodeSample{
               ts: 42,
               cpu_usage_ratio: nil,
               cpu_throttled_ratio: nil,
               psi_cpu_some: 12.5,
               psi_memory_some: 2.5,
               psi_memory_full: 1.25,
               psi_io_some: 7.0,
               psi_io_full: 5.0,
               memory_used_ratio: 0.6,
               major_faults_per_s: nil,
               io_read_bytes_per_s: nil,
               io_write_bytes_per_s: nil,
               load1: 1.5
             } = Derive.node_sample(nil, node_raw(), nil, 42)
    end

    test "derives ratios and per-second rates from the deltas" do
      cur =
        node_raw(%{
          cpu: %{busy: 1_300, total: 10_400},
          kubepods_cpu: %{usage_usec: 0, nr_periods: 300, nr_throttled: 60, throttled_usec: 0},
          vm: %{pgmajfault: 150},
          io: %{rbytes: 5_000, wbytes: 10_000, rios: 0, wios: 0}
        })

      sample = Derive.node_sample(node_raw(), cur, 2_000, 1)

      assert sample.cpu_usage_ratio == 0.75
      assert sample.cpu_throttled_ratio == 0.25
      assert sample.major_faults_per_s == 25.0
      assert sample.io_read_bytes_per_s == 2_000.0
      assert sample.io_write_bytes_per_s == 4_000.0
    end

    test "a counter that went backwards yields nil, never a negative value" do
      cur =
        node_raw(%{
          cpu: %{busy: 10, total: 100},
          kubepods_cpu: %{usage_usec: 0, nr_periods: 5, nr_throttled: 1, throttled_usec: 0},
          vm: %{pgmajfault: 3},
          io: %{rbytes: 0, wbytes: 2_500, rios: 0, wios: 0}
        })

      sample = Derive.node_sample(node_raw(), cur, 1_000, 1)

      assert sample.cpu_usage_ratio == nil
      assert sample.cpu_throttled_ratio == nil
      assert sample.major_faults_per_s == nil
      assert sample.io_read_bytes_per_s == nil
      # the write counter did not reset
      assert sample.io_write_bytes_per_s == 500.0
    end

    test "no elapsed time or no jiffies gives nil rather than dividing by zero" do
      sample = Derive.node_sample(node_raw(), node_raw(), 0, 1)

      assert sample.cpu_usage_ratio == nil
      assert sample.major_faults_per_s == nil
      assert sample.io_read_bytes_per_s == nil
    end

    test "no CFS periods in the interval means nothing was throttled" do
      assert Derive.node_sample(node_raw(), node_raw(), 1_000, 1).cpu_throttled_ratio == 0.0
    end

    test "fields the host does not expose are nil" do
      empty = %{
        cpu: nil,
        kubepods_cpu: nil,
        psi_cpu: nil,
        psi_memory: %{some: %{avg10: 1.0}, full: nil},
        psi_io: nil,
        memory: %{mem_total_bytes: 100, mem_available_bytes: nil},
        load: nil,
        vm: nil,
        io: nil
      }

      sample = Derive.node_sample(empty, empty, 1_000, 7)

      assert sample == %NodeSample{ts: 7, psi_memory_some: 1.0}
      assert Derive.node_sample(%{}, %{}, 1_000, 7) == %NodeSample{ts: 7}
    end

    test "ratios are clamped to 0.0..1.0" do
      cur = node_raw(%{memory: %{mem_total_bytes: 100, mem_available_bytes: 150}})
      assert Derive.node_sample(nil, cur, nil, 1).memory_used_ratio == 0.0

      # more throttled periods than periods cannot happen, but must not exceed 1.0
      cur =
        node_raw(%{
          kubepods_cpu: %{usage_usec: 0, nr_periods: 110, nr_throttled: 50, throttled_usec: 0}
        })

      assert Derive.node_sample(node_raw(), cur, 1_000, 1).cpu_throttled_ratio == 1.0
    end
  end

  describe "pod_sample/5" do
    test "a pod seen for the first time has gauges only" do
      assert %PodSample{
               pod_uid: @uid,
               ts: 9,
               cpu_usage_millis: nil,
               cpu_throttled_ratio: nil,
               memory_bytes: 64_000_000,
               psi_cpu_some: 20.0,
               psi_memory_some: 0.5,
               psi_io_some: 3.0,
               major_faults_per_s: nil,
               io_bytes_per_s: nil
             } = Derive.pod_sample(@uid, nil, pod_raw(), 1_000, 9)
    end

    test "derives millicores, throttling, faults and IO" do
      cur =
        pod_raw(%{
          # 0.5s of CPU in 2s of wall time = 250m
          cpu: %{usage_usec: 1_500_000, nr_periods: 120, nr_throttled: 25, throttled_usec: 0},
          io: %{rbytes: 2_000, wbytes: 5_000, rios: 0, wios: 0},
          memory_stat: %{pgmajfault: 30, pgfault: 0}
        })

      sample = Derive.pod_sample(@uid, pod_raw(), cur, 2_000, 1)

      assert sample.cpu_usage_millis == 250.0
      assert sample.cpu_throttled_ratio == 0.75
      assert sample.major_faults_per_s == 10.0
      assert sample.io_bytes_per_s == 2_000.0
    end

    test "a recreated cgroup (counters reset) yields nil" do
      cur =
        pod_raw(%{
          cpu: %{usage_usec: 5, nr_periods: 1, nr_throttled: 0, throttled_usec: 0},
          io: %{rbytes: 0, wbytes: 9_000, rios: 0, wios: 0},
          memory_stat: %{pgmajfault: 0, pgfault: 0}
        })

      sample = Derive.pod_sample(@uid, pod_raw(), cur, 1_000, 1)

      assert sample.cpu_usage_millis == nil
      assert sample.cpu_throttled_ratio == nil
      assert sample.major_faults_per_s == nil
      # one of the two IO counters reset: no partial sum
      assert sample.io_bytes_per_s == nil
    end

    test "a pod without a CPU limit is not throttled" do
      raw = pod_raw(%{cpu: %{usage_usec: 1, nr_periods: 0, nr_throttled: 0, throttled_usec: 0}})
      assert Derive.pod_sample(@uid, raw, raw, 1_000, 1).cpu_throttled_ratio == 0.0
    end

    test "without the cpu controller the throttled ratio is unknown" do
      raw = pod_raw(%{cpu: %{usage_usec: 1, nr_periods: nil, nr_throttled: nil}})
      assert Derive.pod_sample(@uid, raw, raw, 1_000, 1).cpu_throttled_ratio == nil
    end

    test "missing files are nil" do
      raw = %{cpu: nil, psi_cpu: nil, io: nil, memory_current: nil, memory_stat: nil}
      assert Derive.pod_sample(@uid, raw, raw, 1_000, 3) == %PodSample{pod_uid: @uid, ts: 3}
    end
  end
end
