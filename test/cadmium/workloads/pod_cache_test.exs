defmodule Cadmium.Workloads.PodCacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cadmium.Kube.Pod
  alias Cadmium.Workloads.PodCache

  setup context do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    api = start_supervised!({Agent, fn -> %{result: {:ok, []}, calls: []} end})

    list_pods = fn node_name ->
      Agent.get_and_update(api, fn state ->
        {state.result, %{state | calls: [node_name | state.calls]}}
      end)
      |> case do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    opts =
      Keyword.merge(
        [
          name: nil,
          table: table,
          interval_ms: :infinity,
          list_pods: list_pods,
          node_name: "node-a"
        ],
        Map.get(context, :pod_cache, [])
      )

    start = fn -> start_supervised!({PodCache, opts}) end
    {:ok, table: table, api: api, start: start}
  end

  defp pod(name), do: %Pod{namespace: "default", name: name, uid: "uid-" <> name}
  defp respond(api, result), do: Agent.update(api, &%{&1 | result: result})
  defp calls(api), do: Agent.get(api, &length(&1.calls))

  test "pods/1 is empty when the cache is not running" do
    assert PodCache.pods(:no_such_pod_cache_table) == []
    assert PodCache.ensure_fresh(:no_such_pod_cache) == :ok
  end

  test "loads the pods of this node on start", %{table: table, api: api, start: start} do
    respond(api, {:ok, [pod("a"), pod("b")]})
    pid = start.()
    :sys.get_state(pid)

    assert PodCache.pods(table) == [pod("a"), pod("b")]
    assert Agent.get(api, & &1.calls) == ["node-a"]
  end

  test "refresh replaces the cache", %{table: table, api: api, start: start} do
    pid = start.()
    respond(api, {:ok, [pod("a")]})
    assert PodCache.refresh(pid) == :ok
    assert PodCache.pods(table) == [pod("a")]

    respond(api, {:ok, []})
    assert PodCache.refresh(pid) == :ok
    assert PodCache.pods(table) == []
  end

  test "keeps the previous cache on errors, raises and bad replies, logging rate-limited",
       %{table: table, api: api, start: start} do
    respond(api, {:ok, [pod("a")]})
    pid = start.()
    :sys.get_state(pid)

    log =
      capture_log(fn ->
        respond(api, {:error, :timeout})
        assert PodCache.refresh(pid) == {:error, :timeout}

        respond(api, fn -> raise "connection refused" end)
        assert {:error, %RuntimeError{}} = PodCache.refresh(pid)

        respond(api, fn -> exit(:boom) end)
        assert PodCache.refresh(pid) == {:error, {:exit, :boom}}

        respond(api, :nonsense)
        assert PodCache.refresh(pid) == {:error, {:unexpected, :nonsense}}
      end)

    assert PodCache.pods(table) == [pod("a")]
    assert Process.alive?(pid)
    assert length(String.split(log, "listing pods failed")) == 2
    assert log =~ ":timeout"
  end

  @tag pod_cache: [log_interval_ms: 0]
  test "logs again once the rate limit has passed", %{api: api, start: start} do
    pid = start.()
    respond(api, {:error, :timeout})

    log =
      capture_log(fn ->
        PodCache.refresh(pid)
        PodCache.refresh(pid)
      end)

    assert length(String.split(log, "listing pods failed")) == 3
  end

  @tag pod_cache: [interval_ms: 10]
  test "refreshes periodically", %{table: table, api: api, start: start} do
    start.()
    respond(api, {:ok, [pod("late")]})

    assert eventually(fn -> PodCache.pods(table) == [pod("late")] end)
    assert eventually(fn -> calls(api) >= 3 end)
  end

  @tag pod_cache: [min_refresh_ms: 60_000]
  test "ensure_fresh is throttled", %{api: api, start: start} do
    pid = start.()
    :sys.get_state(pid)
    assert calls(api) == 1

    assert PodCache.ensure_fresh(pid) == :ok
    assert PodCache.ensure_fresh(pid) == :ok
    assert calls(api) == 1
  end

  @tag pod_cache: [min_refresh_ms: 0]
  test "ensure_fresh refreshes when allowed", %{table: table, api: api, start: start} do
    pid = start.()
    respond(api, {:ok, [pod("a")]})

    assert PodCache.ensure_fresh(pid) == :ok
    assert PodCache.pods(table) == [pod("a")]
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
