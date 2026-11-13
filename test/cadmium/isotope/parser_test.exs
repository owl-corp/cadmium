defmodule Cadmium.Isotope.ParserTest do
  use ExUnit.Case, async: true

  import Cadmium.IsotopeFixtures, only: [fixture: 1]

  alias Cadmium.Isotope.Parser

  @parsers [
    :cpu_stat,
    :pressure,
    :io_stat,
    :memory_current,
    :memory_stat,
    :proc_stat,
    :meminfo,
    :loadavg,
    :vmstat
  ]

  describe "every parser" do
    test "returns nil for a missing file" do
      for parser <- @parsers do
        assert apply(Parser, parser, [nil]) == nil, "#{parser}(nil)"
      end
    end

    test "survives garbage without raising" do
      garbage = [
        "",
        "\n\n\n",
        "   ",
        "not a kernel file at all",
        "key\nkey value extra\n=\n:::\n",
        <<0, 255, 254, 10, 200, 32, 61, 10>>,
        "some avg10=\nfull\n",
        "cpu\ncpu  a b c d\n",
        "MemTotal:\nMemAvailable: lots kB\n",
        "-5\n",
        "usage_usec -12\nnr_periods 1e9\n"
      ]

      for parser <- @parsers, text <- garbage do
        result = apply(Parser, parser, [text])

        assert is_nil(result) or is_map(result) or is_integer(result),
               "#{parser}(#{inspect(text)})"
      end
    end

    test "returns nil when nothing useful is in the file" do
      for parser <- @parsers -- [:io_stat] do
        assert apply(Parser, parser, ["unrelated 1\nlines here\n"]) == nil, "#{parser}"
      end
    end
  end

  describe "cpu_stat/1" do
    test "parses a cgroup with the cpu controller enabled" do
      assert Parser.cpu_stat(fixture("cgroup/cpu.stat")) == %{
               usage_usec: 8_421_337_412,
               nr_periods: 412_367,
               nr_throttled: 18_233,
               throttled_usec: 912_455_120
             }
    end

    test "throttling fields are nil without the cpu controller" do
      assert Parser.cpu_stat(fixture("cgroup/cpu.stat.nocontroller")) == %{
               usage_usec: 51_233,
               nr_periods: nil,
               nr_throttled: nil,
               throttled_usec: nil
             }
    end

    test "skips malformed lines and keeps the good ones" do
      text = "usage_usec\nnr_periods ten\nnr_throttled 4 trailing\n\nthrottled_usec 9\r\n"

      assert Parser.cpu_stat(text) == %{
               usage_usec: nil,
               nr_periods: nil,
               nr_throttled: 4,
               throttled_usec: 9
             }
    end

    test "rejects negative counters" do
      assert Parser.cpu_stat("usage_usec -5\nnr_periods 3\n").usage_usec == nil
    end
  end

  describe "pressure/1" do
    test "parses some and full lines" do
      assert Parser.pressure(fixture("cgroup/cpu.pressure")) == %{
               some: %{avg10: 12.34, avg60: 8.01, avg300: 3.5, total: 482_910_332},
               full: %{avg10: 1.2, avg60: 0.75, avg300: 0.31, total: 20_113_377}
             }
    end

    test "parses the /proc/pressure files" do
      assert %{some: %{avg10: 45.12}, full: %{avg10: +0.0, total: 0}} =
               Parser.pressure(fixture("proc/pressure/cpu"))

      assert %{some: %{avg10: 2.5}, full: %{avg10: 1.25}} =
               Parser.pressure(fixture("proc/pressure/memory"))

      assert %{some: %{avg10: 7.7, total: 873_311_204}, full: %{avg300: 1.4}} =
               Parser.pressure(fixture("proc/pressure/io"))
    end

    test "full is nil on kernels that only report some" do
      text = "some avg10=1.00 avg60=2.00 avg300=3.00 total=4\n"

      assert Parser.pressure(text) == %{
               some: %{avg10: 1.0, avg60: 2.0, avg300: 3.0, total: 4},
               full: nil
             }
    end

    test "missing and malformed fields are nil" do
      text = "some avg10=1.5 avg60=oops total=7 mystery=1\nfull nonsense\nother avg10=9.0\n"

      assert Parser.pressure(text) == %{
               some: %{avg10: 1.5, avg60: nil, avg300: nil, total: 7},
               full: nil
             }
    end

    test "accepts integer-looking averages" do
      assert %{some: %{avg10: 3.0}} = Parser.pressure("some avg10=3 avg60=0 avg300=0 total=0")
    end
  end

  describe "io_stat/1" do
    test "sums all devices, tolerating devices with no counters" do
      assert Parser.io_stat(fixture("cgroup/io.stat")) == %{
               rbytes: 1_811_111_936 + 4096,
               wbytes: 90_328_145_920,
               rios: 41_234,
               wios: 3_120_045
             }
    end

    test "an empty file is a cgroup that has done no IO" do
      assert Parser.io_stat("") == %{rbytes: 0, wbytes: 0, rios: 0, wios: 0}
    end

    test "ignores malformed lines and fields" do
      text = "garbage rbytes=5\n8:0 rbytes=abc wbytes=7 wios\n8:1 rbytes=3 rbytes=4\n"
      assert Parser.io_stat(text) == %{rbytes: 7, wbytes: 7, rios: 0, wios: 0}
    end
  end

  describe "memory_current/1" do
    test "parses the byte count" do
      assert Parser.memory_current(fixture("cgroup/memory.current")) == 268_435_456
      assert Parser.memory_current("42") == 42
    end

    test "is nil for anything else" do
      assert Parser.memory_current("max\n") == nil
      assert Parser.memory_current("") == nil
      assert Parser.memory_current("12abc\n") == nil
    end
  end

  describe "memory_stat/1" do
    test "extracts the fault counters" do
      assert Parser.memory_stat(fixture("cgroup/memory.stat")) == %{
               pgfault: 9_912_345,
               pgmajfault: 421
             }
    end

    test "a missing counter is nil" do
      assert Parser.memory_stat("anon 5\npgfault 9\n") == %{pgfault: 9, pgmajfault: nil}
    end
  end

  describe "proc_stat/1" do
    test "turns the aggregate cpu line into busy and total jiffies" do
      assert Parser.proc_stat(fixture("proc/stat")) == %{busy: 1_451_363, total: 10_602_719}
    end

    test "does not count guest time twice" do
      assert Parser.proc_stat("cpu 10 0 10 70 10 0 0 0 5 5\n") == %{busy: 20, total: 100}
    end

    test "works with the short line of very old kernels" do
      assert Parser.proc_stat("cpu 10 5 5 80\n") == %{busy: 20, total: 100}
    end

    test "is nil without a usable aggregate line" do
      assert Parser.proc_stat("cpu0 1 2 3 4 5 6 7 8\n") == nil
      assert Parser.proc_stat("cpu 1 2\n") == nil
      assert Parser.proc_stat("cpu 1 2 x 4 5\n") == nil
    end
  end

  describe "meminfo/1" do
    test "extracts MemTotal and MemAvailable in bytes" do
      assert Parser.meminfo(fixture("proc/meminfo")) == %{
               mem_total_bytes: 16_303_428 * 1024,
               mem_available_bytes: 6_521_372 * 1024
             }
    end

    test "MemAvailable is nil when the kernel does not report it" do
      assert Parser.meminfo("MemTotal: 100 kB\nMemFree: 50 kB\n") == %{
               mem_total_bytes: 102_400,
               mem_available_bytes: nil
             }
    end
  end

  describe "loadavg/1" do
    test "parses the three load averages" do
      assert Parser.loadavg(fixture("proc/loadavg")) == %{load1: 3.52, load5: 2.18, load15: 1.07}
    end

    test "tolerates a truncated line" do
      assert Parser.loadavg("0.5\n") == %{load1: 0.5, load5: nil, load15: nil}
      assert Parser.loadavg("high 1.0 2.0\n") == nil
    end
  end

  describe "vmstat/1" do
    test "extracts the fault counters" do
      assert Parser.vmstat(fixture("proc/vmstat")) == %{
               pgfault: 1_820_113_344,
               pgmajfault: 88_213
             }
    end
  end
end
