defmodule CadmiumWeb.HealthControllerTest do
  use CadmiumWeb.ConnCase, async: true

  test "GET /healthz", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok", "node" => "test-node"}
  end

  test "GET /healthz does not need an Accept header a probe would not send", %{conn: conn} do
    conn = conn |> put_req_header("accept", "*/*") |> get(~p"/healthz")

    assert json_response(conn, 200)["status"] == "ok"
  end
end
