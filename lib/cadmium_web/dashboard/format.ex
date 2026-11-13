defmodule CadmiumWeb.Dashboard.Format do
  @moduledoc "Pure formatting helpers shared by the dashboard LiveViews and components."

  @mi 1024 * 1024
  @gi 1024 * @mi

  # ---- heat ---------------------------------------------------------------

  @doc """
  Maps a 0..100 pressure score onto the five-step heat scale used everywhere:
  0 cool, 1 mild, 2 warm, 3 hot, 4 critical.
  """
  @spec heat_level(number() | nil) :: 0..4
  def heat_level(score) when is_number(score) do
    cond do
      score >= 85 -> 4
      score >= 70 -> 3
      score >= 50 -> 2
      score >= 25 -> 1
      true -> 0
    end
  end

  def heat_level(_), do: 0

  @doc "CSS class (`heat-0`..`heat-4`) for a score."
  def heat_class(score), do: "heat-#{heat_level(score)}"

  @doc "Word for a score's heat level, shown next to the number so colour is never alone."
  def heat_label(score) do
    case heat_level(score) do
      0 -> "cool"
      1 -> "mild"
      2 -> "warm"
      3 -> "hot"
      4 -> "critical"
    end
  end

  @doc "Legend rows: `{level, label, range}`."
  def heat_legend do
    [
      {0, "cool", "0–24"},
      {1, "mild", "25–49"},
      {2, "warm", "50–69"},
      {3, "hot", "70–84"},
      {4, "critical", "85–100"}
    ]
  end

  # ---- numbers ------------------------------------------------------------

  @doc "A 0..100 score, rounded."
  def score(nil), do: "–"
  def score(score) when is_number(score), do: Integer.to_string(round(score))

  @doc "A number with a fixed count of decimals."
  def decimal(nil, _decimals), do: "–"
  def decimal(value, decimals), do: :erlang.float_to_binary(value * 1.0, decimals: decimals)

  @doc "CPU in millicores: `250m` below one core, `1.5 cores` above."
  def cpu(nil), do: "–"
  def cpu(millis) when millis < 1000, do: "#{round(millis)}m"

  def cpu(millis) do
    cores = millis / 1000
    if cores == 1.0, do: "1 core", else: "#{trim(decimal(cores, 2))} cores"
  end

  @doc "Bytes in binary units: `256 Mi`, `1.5 Gi`."
  def bytes(nil), do: "–"
  def bytes(bytes) when bytes >= @gi, do: "#{trim(decimal(bytes / @gi, 2))} Gi"
  def bytes(bytes) when bytes >= @mi, do: "#{round(bytes / @mi)} Mi"
  def bytes(bytes) when bytes >= 1024, do: "#{round(bytes / 1024)} Ki"
  def bytes(bytes), do: "#{bytes} B"

  @doc "Bytes per second in decimal-free binary units."
  def rate(nil), do: "–"
  def rate(bytes_per_s), do: bytes(round(bytes_per_s)) <> "/s"

  @doc "A drift ratio: `2.4x`."
  def ratio(nil), do: "–"
  def ratio(ratio) when ratio >= 10, do: "#{round(ratio)}x"
  def ratio(ratio), do: "#{decimal(ratio, 2)}x"

  @doc "A 0.0..1.0 ratio as a percentage."
  def percent(nil), do: "–"
  def percent(ratio), do: "#{round(ratio * 100)}%"

  @doc "A kernel PSI avg10 value, already a percentage."
  def psi(nil), do: "–"
  def psi(value), do: "#{decimal(value, 1)}%"

  defp trim(string) do
    if String.contains?(string, ".") do
      string |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      string
    end
  end

  # ---- time ---------------------------------------------------------------

  @doc "A duration in milliseconds: `45s`, `4m 12s`, `2h 5m`."
  def duration(ms) when is_number(ms) do
    seconds = max(div(round(ms), 1000), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"
    end
  end

  @doc "How long ago a millisecond timestamp was, relative to `now`."
  def ago(nil, _now), do: "never"

  def ago(ts, now) do
    case now - ts do
      diff when diff < 1500 -> "just now"
      diff -> duration(diff) <> " ago"
    end
  end

  @doc "UTC wall-clock time of a millisecond timestamp: `14:03:22`."
  def clock(nil), do: "–"

  def clock(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  @doc "UTC date of a millisecond timestamp: `2026-11-13`."
  def date(ts), do: ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d")

  @doc "ISO 8601 form of a millisecond timestamp, for `<time datetime>`."
  def iso(ts), do: ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # ---- catalyst vocabulary --------------------------------------------------

  @rejections %{
    namespace_excluded:
      {"Namespace excluded", "The pod's namespace is excluded from rebalancing."},
    daemonset:
      {"DaemonSet pod", "DaemonSet pods are pinned to their node; evicting one moves nothing."},
    mirror_pod: {"Static pod", "Mirror pods are managed by the kubelet and cannot be evicted."},
    unmanaged:
      {"No controller", "Nothing owns this pod, so it would not be recreated elsewhere."},
    local_storage:
      {"Local storage", "Uses emptyDir or hostPath storage that would be lost on eviction."},
    single_replica:
      {"Single replica", "It is the only replica; evicting it would cause downtime."},
    replicas_not_ready:
      {"Replicas not ready", "Other replicas of the workload are not ready to take the load."},
    pdb_blocked:
      {"PodDisruptionBudget", "Blocked by a PodDisruptionBudget that allows no disruptions now."},
    workload_cooldown:
      {"Workload cooling down", "This workload was moved recently and is still in its cooldown."},
    opted_out: {"Opted out", "The pod opted out of rebalancing with an annotation."},
    deleting: {"Terminating", "The pod is already being deleted."},
    not_running: {"Not running", "The pod is not in the Running phase."},
    job: {"Job pod", "Job pods are left to finish; evicting one would discard its progress."}
  }

  @doc "Every rejection reason documented in `Cadmium.Catalyst.Plan`."
  def rejection_reasons, do: Map.keys(@rejections)

  @doc "`{short title, human explanation}` for a rejection reason atom."
  def rejection(reason) do
    Map.get_lazy(@rejections, reason, fn ->
      {humanize(reason), "Rejected by the planner (#{reason})."}
    end)
  end

  @doc "`{label, tone}` for a plan status."
  def plan_status(:balanced), do: {"Balanced", :ok}
  def plan_status(:imbalanced), do: {"Imbalanced", :danger}
  def plan_status(:not_sustained), do: {"Not sustained", :warn}
  def plan_status(:cooling_down), do: {"Cooling down", :info}
  def plan_status(:insufficient_nodes), do: {"Insufficient nodes", :neutral}
  def plan_status(other), do: {humanize(other), :neutral}

  @doc "`{label, tone}` for an audit action type."
  def action_type(:evict), do: {"Evict", :danger}
  def action_type(:taint), do: {"Taint", :warn}
  def action_type(:untaint), do: {"Untaint", :ok}
  def action_type(:leader_acquired), do: {"Leader acquired", :info}
  def action_type(:leader_lost), do: {"Leader lost", :neutral}
  def action_type(:settings_changed), do: {"Settings", :neutral}
  def action_type(other), do: {humanize(other), :neutral}

  @doc "Turns an atom or other term into words."
  def humanize(term) when is_atom(term) do
    term |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  def humanize(term) when is_binary(term), do: term
  def humanize(term), do: inspect(term)

  @doc "A string safe to embed in a DOM id / CSS selector."
  def dom_id(string), do: String.replace(to_string(string), ~r/[^A-Za-z0-9_-]/, "-")
end
