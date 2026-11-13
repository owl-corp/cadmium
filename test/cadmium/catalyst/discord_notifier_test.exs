defmodule Cadmium.Catalyst.DiscordNotifierTest do
  use ExUnit.Case, async: true

  alias Cadmium.Catalyst.{AuditLog, DiscordNotifier}

  test "sends locally recorded actions once, but not replicated actions" do
    topic = "discord-test:#{System.unique_integer([:positive])}"
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook, conn.method, Jason.decode!(body)})
      Plug.Conn.resp(conn, 204, "")
    end

    start_supervised!(
      {DiscordNotifier,
       name: nil,
       topic: topic,
       webhook_url: "https://discord.test/api/webhooks/test",
       req_options: [plug: plug, retry: false]}
    )

    log = :"discord_audit_#{System.unique_integer([:positive])}"
    start_supervised!({AuditLog, name: log, topic: topic, peers_fun: fn -> [] end})

    action =
      AuditLog.record(log,
        type: :evict,
        node: "node-a",
        namespace: "default",
        pod: "web-1",
        dry_run?: true,
        result: :simulated
      )

    assert_receive {:webhook, "POST",
                    %{
                      "allowed_mentions" => %{"parse" => []},
                      "embeds" => [%{"title" => "Evict", "description" => description}]
                    }},
                   5_000

    assert description =~ "default/web-1"
    assert description =~ "Dry-run"

    Phoenix.PubSub.broadcast(Cadmium.PubSub, topic, {:catalyst_action, action})
    refute_receive {:webhook, _, _}
  end

  test "does not subscribe when the URL is blank" do
    topic = "discord-test:#{System.unique_integer([:positive])}"
    test_pid = self()

    plug = fn conn ->
      send(test_pid, :webhook)
      Plug.Conn.resp(conn, 204, "")
    end

    start_supervised!(
      {DiscordNotifier,
       name: nil, topic: topic, webhook_url: "", req_options: [plug: plug, retry: false]}
    )

    action = AuditLog.build(type: :taint)

    Phoenix.PubSub.local_broadcast(
      Cadmium.PubSub,
      AuditLog.local_topic(topic),
      {:catalyst_action, action}
    )

    refute_receive :webhook
  end

  test "continues delivering after a webhook rejection" do
    topic = "discord-test:#{System.unique_integer([:positive])}"
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"embeds" => [%{"title" => title}]} = Jason.decode!(body)
      send(test_pid, {:webhook, title})
      Plug.Conn.resp(conn, if(title == "Taint", do: 400, else: 204), "")
    end

    start_supervised!(
      {DiscordNotifier,
       name: nil,
       topic: topic,
       webhook_url: "https://discord.test/api/webhooks/test",
       req_options: [plug: plug, retry: false]}
    )

    log = :"discord_audit_#{System.unique_integer([:positive])}"
    start_supervised!({AuditLog, name: log, topic: topic, peers_fun: fn -> [] end})

    AuditLog.record(log, type: :taint)
    assert_receive {:webhook, "Taint"}, 5_000
    AuditLog.record(log, type: :untaint)
    assert_receive {:webhook, "Untaint"}, 5_000
  end
end
