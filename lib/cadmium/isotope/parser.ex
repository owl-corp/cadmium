defmodule Cadmium.Isotope.Parser do
  @moduledoc """
  Pure parsers for the cgroup v2 and /proc files Isotope reads.

  Every function takes the file's text (or `nil` when the file could not be read) and
  returns a map of parsed values, or `nil` when nothing useful could be extracted. They
  never raise on missing fields, malformed lines or arbitrary binaries: a field that is
  absent or unparsable is simply `nil` in the result.
  """

  @type cpu_stat :: %{
          usage_usec: non_neg_integer() | nil,
          nr_periods: non_neg_integer() | nil,
          nr_throttled: non_neg_integer() | nil,
          throttled_usec: non_neg_integer() | nil
        }
  @type pressure_line :: %{
          avg10: float() | nil,
          avg60: float() | nil,
          avg300: float() | nil,
          total: non_neg_integer() | nil
        }
  @type pressure :: %{some: pressure_line() | nil, full: pressure_line() | nil}
  @type io_stat :: %{
          rbytes: non_neg_integer(),
          wbytes: non_neg_integer(),
          rios: non_neg_integer(),
          wios: non_neg_integer()
        }

  @ws [" ", "\t", "\r"]

  @doc "cgroup v2 `cpu.stat`. The throttling fields are nil when the cpu controller is off."
  @spec cpu_stat(binary() | nil) :: cpu_stat() | nil
  def cpu_stat(text) do
    text
    |> flat_keyed()
    |> pick(%{
      "usage_usec" => :usage_usec,
      "nr_periods" => :nr_periods,
      "nr_throttled" => :nr_throttled,
      "throttled_usec" => :throttled_usec
    })
  end

  @doc """
  A PSI file (`cpu.pressure`, `memory.pressure`, `io.pressure`, `/proc/pressure/*`).
  `full` is nil where the kernel does not report it (e.g. CPU on older kernels).
  """
  @spec pressure(binary() | nil) :: pressure() | nil
  def pressure(text) when is_binary(text) do
    parsed =
      for line <- lines(text),
          [kind | fields] <- [tokens(line)],
          kind in ["some", "full"],
          parsed = pressure_fields(fields),
          into: %{},
          do: {kind, parsed}

    if map_size(parsed) == 0 do
      nil
    else
      %{some: parsed["some"], full: parsed["full"]}
    end
  end

  def pressure(_), do: nil

  @doc """
  cgroup v2 `io.stat`, summed over all devices. An empty file (a cgroup that has done no
  IO) is all zeros; a missing file is nil.
  """
  @spec io_stat(binary() | nil) :: io_stat() | nil
  def io_stat(text) when is_binary(text) do
    zero = %{rbytes: 0, wbytes: 0, rios: 0, wios: 0}

    for line <- lines(text),
        [device | fields] <- [tokens(line)],
        device?(device),
        field <- fields,
        reduce: zero do
      acc ->
        case :binary.split(field, "=") do
          ["rbytes", v] -> add(acc, :rbytes, v)
          ["wbytes", v] -> add(acc, :wbytes, v)
          ["rios", v] -> add(acc, :rios, v)
          ["wios", v] -> add(acc, :wios, v)
          _ -> acc
        end
    end
  end

  def io_stat(_), do: nil

  @doc "cgroup v2 `memory.current` (bytes)."
  @spec memory_current(binary() | nil) :: non_neg_integer() | nil
  def memory_current(text) when is_binary(text) do
    case first_line_tokens(text) do
      [value | _] -> int(value)
      [] -> nil
    end
  end

  def memory_current(_), do: nil

  @doc "cgroup v2 `memory.stat`: the fault counters."
  @spec memory_stat(binary() | nil) ::
          %{pgfault: non_neg_integer() | nil, pgmajfault: non_neg_integer() | nil} | nil
  def memory_stat(text) do
    text |> flat_keyed() |> pick(%{"pgfault" => :pgfault, "pgmajfault" => :pgmajfault})
  end

  @doc """
  `/proc/stat`: the aggregate `cpu` line as cumulative jiffies. `busy` excludes idle and
  iowait; `total` is user+nice+system+idle+iowait+irq+softirq+steal (guest time is
  already included in user).
  """
  @spec proc_stat(binary() | nil) :: %{busy: non_neg_integer(), total: non_neg_integer()} | nil
  def proc_stat(text) when is_binary(text) do
    Enum.find_value(lines(text), fn line ->
      with ["cpu" | fields] <- tokens(line),
           values = Enum.map(fields, &int/1),
           true <- length(values) >= 4 and Enum.all?(values, &is_integer/1) do
        counted = Enum.take(values, 8)
        total = Enum.sum(counted)
        idle = Enum.at(counted, 3) + Enum.at(counted, 4, 0)
        %{busy: total - idle, total: total}
      else
        _ -> nil
      end
    end)
  end

  def proc_stat(_), do: nil

  @doc "`/proc/meminfo`: MemTotal and MemAvailable, converted to bytes."
  @spec meminfo(binary() | nil) ::
          %{
            mem_total_bytes: non_neg_integer() | nil,
            mem_available_bytes: non_neg_integer() | nil
          }
          | nil
  def meminfo(text) when is_binary(text) do
    kv =
      for line <- lines(text),
          [key, value | unit] <- [:binary.split(line, [":" | @ws], [:global, :trim_all])],
          key in ["MemTotal", "MemAvailable"],
          n = int(value),
          into: %{},
          do: {key, n * unit_bytes(unit)}

    pick(kv, %{"MemTotal" => :mem_total_bytes, "MemAvailable" => :mem_available_bytes})
  end

  def meminfo(_), do: nil

  @doc "`/proc/loadavg`."
  @spec loadavg(binary() | nil) ::
          %{load1: float(), load5: float() | nil, load15: float() | nil} | nil
  def loadavg(text) when is_binary(text) do
    with [first | rest] <- first_line_tokens(text),
         load1 when is_float(load1) <- float(first) do
      %{load1: load1, load5: float(Enum.at(rest, 0)), load15: float(Enum.at(rest, 1))}
    else
      _ -> nil
    end
  end

  def loadavg(_), do: nil

  @doc "`/proc/vmstat`: the fault counters."
  @spec vmstat(binary() | nil) ::
          %{pgfault: non_neg_integer() | nil, pgmajfault: non_neg_integer() | nil} | nil
  def vmstat(text) do
    text |> flat_keyed() |> pick(%{"pgfault" => :pgfault, "pgmajfault" => :pgmajfault})
  end

  @doc "Parses a flat-keyed file (`key value` per line) into a map of integer values."
  @spec flat_keyed(binary() | nil) :: %{binary() => non_neg_integer()}
  def flat_keyed(text) when is_binary(text) do
    for line <- lines(text),
        [key, value | _] <- [tokens(line)],
        n = int(value),
        into: %{},
        do: {key, n}
  end

  def flat_keyed(_), do: %{}

  # -- helpers ---------------------------------------------------------------------------

  defp lines(text), do: :binary.split(text, "\n", [:global, :trim_all])
  defp tokens(line), do: :binary.split(line, @ws, [:global, :trim_all])

  defp first_line_tokens(text) do
    case lines(text) do
      [line | _] -> tokens(line)
      [] -> []
    end
  end

  defp pick(kv, mapping) do
    result = Map.new(mapping, fn {key, name} -> {name, Map.get(kv, key)} end)
    if Enum.all?(result, fn {_, v} -> is_nil(v) end), do: nil, else: result
  end

  defp pressure_fields(fields) do
    kv =
      for field <- fields, [k, v] <- [:binary.split(field, "=")], into: %{}, do: {k, v}

    result = %{
      avg10: float(kv["avg10"]),
      avg60: float(kv["avg60"]),
      avg300: float(kv["avg300"]),
      total: int(kv["total"])
    }

    if Enum.all?(result, fn {_, v} -> is_nil(v) end), do: nil, else: result
  end

  defp device?(token) do
    case :binary.split(token, ":") do
      [major, minor] -> is_integer(int(major)) and is_integer(int(minor))
      _ -> false
    end
  end

  defp add(acc, key, value) do
    case int(value) do
      nil -> acc
      n -> Map.update!(acc, key, &(&1 + n))
    end
  end

  defp unit_bytes(["kB" | _]), do: 1024
  defp unit_bytes(_), do: 1

  # Non-negative integers only: every counter we read is unsigned.
  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp float(value) when is_binary(value) do
    case Float.parse(value) do
      {f, ""} when f >= 0 -> f
      _ -> nil
    end
  end

  defp float(_), do: nil
end
