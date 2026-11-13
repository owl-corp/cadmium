defmodule Cadmium.Catalyst.DiscordNotifier do
  @moduledoc """
  Forwards new audit-log entries to a Discord webhook.

  When `discord_webhook_url` is set in the `Cadmium.Catalyst` config (or the
  `CADMIUM_DISCORD_WEBHOOK_URL` environment variable in prod), this GenServer
  subscribes to locally recorded actions and POSTs a formatted embed to the
  webhook. Replicated actions and audit-log backfills are not sent again.

  The post is fire-and-forget: failures are logged but never crash the notifier.

  Options: `:webhook_url`, `:pubsub`, `:topic`, `:req_options`.
  """

  use GenServer

  require Logger

  alias Cadmium.Catalyst.{Action, AuditLog, Config, Safe}
  alias CadmiumWeb.Dashboard.Format

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## Server

  @impl true
  def init(opts) do
    url =
      Keyword.get_lazy(opts, :webhook_url, fn ->
        Config.load().discord_webhook_url
      end)

    state = %{
      webhook_url: url,
      pubsub: Keyword.get(opts, :pubsub, Cadmium.PubSub),
      topic: Keyword.get_lazy(opts, :topic, &Cadmium.Catalyst.topic/0),
      req_options: Keyword.get(opts, :req_options, [])
    }

    if is_binary(url) and String.trim(url) != "" do
      :ok = Phoenix.PubSub.subscribe(state.pubsub, AuditLog.local_topic(state.topic))
      Logger.info("[DiscordNotifier] Subscribed — notifications enabled")
    else
      Logger.debug("[DiscordNotifier] No webhook URL configured — notifications disabled")
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:catalyst_action, %Action{} = action}, %{webhook_url: url} = state)
      when is_binary(url) do
    case Task.start(fn -> post(url, action, state.req_options) end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> Logger.warning("[DiscordNotifier] Could not start webhook request")
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Formatting

  defp post(url, action, req_options) do
    payload = build_payload(action)

    options = Keyword.merge([json: payload, redirect: false, retry_log_level: false], req_options)

    case Safe.call(fn -> Req.post(url, options) end, {:error, :safe_call_failed}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[DiscordNotifier] Webhook returned HTTP #{status}")

      {:error, _reason} ->
        Logger.warning("[DiscordNotifier] Webhook request failed")
    end
  end

  defp build_payload(action) do
    {label, _tone} = Format.action_type(action.type)
    color = embed_color(action)
    ts_iso = Format.iso(action.ts)

    description = build_description(action)

    embed = %{
      title: label,
      description: description,
      color: color,
      timestamp: ts_iso,
      footer: %{text: "Cadmium · #{action.actor || "unknown"}"}
    }

    %{embeds: [embed], allowed_mentions: %{parse: []}}
  end

  defp build_description(action) do
    parts = [
      if(action.dry_run?, do: "🧪 **Dry-run**", else: nil),
      target_line(action),
      if(action.reason, do: "_#{action.reason}_", else: nil),
      result_line(action)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, 4096)
  end

  defp target_line(%{pod: pod, namespace: ns, node: node}) when is_binary(pod) do
    base = "**#{ns}/#{pod}**"
    if node, do: "#{base} on `#{node}`", else: base
  end

  defp target_line(%{node: node}) when is_binary(node), do: "`#{node}`"
  defp target_line(_), do: nil

  defp result_line(%{result: :ok}), do: "✅ ok"
  defp result_line(%{result: :simulated}), do: "🔬 simulated"
  defp result_line(%{result: {:error, reason}}), do: "❌ error — #{inspect(reason)}"
  defp result_line(_), do: nil

  # Discord embed colours (decimal RGB)
  defp embed_color(%{type: :evict, dry_run?: false}), do: 0xEF4444
  defp embed_color(%{type: :taint}), do: 0xF59E0B
  defp embed_color(%{type: :untaint}), do: 0x22C55E
  defp embed_color(%{type: :leader_acquired}), do: 0x3B82F6
  defp embed_color(%{type: :leader_lost}), do: 0x94A3B8
  defp embed_color(%{type: :settings_changed}), do: 0x8B5CF6
  defp embed_color(_), do: 0x64748B
end
