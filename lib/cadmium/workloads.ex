defmodule Cadmium.Workloads do
  @moduledoc """
  Request-vs-reality view of pods: Kubernetes pod metadata joined with Isotope pod samples.

  `local/0` covers pods on this host; `cluster/0` fans out to every connected agent.

  Pod metadata comes from `Cadmium.Workloads.PodCache` (never a blocking API call on the
  read path, except an on-demand refresh while the cache is still empty).
  """

  alias Cadmium.Isotope.PodSample
  alias Cadmium.Kube.Pod
  alias Cadmium.Workload
  alias Cadmium.Workloads.PodCache

  @rpc_timeout_ms 2_000

  @doc """
  Workloads running on this agent's host.

  Options (for tests): `:cache` (PodCache server), `:cache_table`, `:pod_samples`
  (0-arity fun), `:node_name`.
  """
  @spec local(keyword()) :: [Workload.t()]
  def local(opts \\ []) do
    table = Keyword.get(opts, :cache_table, PodCache)

    pods =
      case PodCache.pods(table) do
        [] ->
          PodCache.ensure_fresh(Keyword.get(opts, :cache, PodCache))
          PodCache.pods(table)

        pods ->
          pods
      end

    samples = safe_samples(Keyword.get(opts, :pod_samples, &Cadmium.Isotope.pod_samples/0))
    join(pods, samples, Keyword.get_lazy(opts, :node_name, &Cadmium.node_name/0))
  end

  @doc """
  Workloads across all reachable agents (unreachable nodes are skipped).

  Options (for tests): `:nodes`, `:timeout`.
  """
  @spec cluster(keyword()) :: [Workload.t()]
  def cluster(opts \\ []) do
    nodes = Keyword.get_lazy(opts, :nodes, fn -> [node() | Node.list()] end)
    timeout = Keyword.get(opts, :timeout, @rpc_timeout_ms)

    nodes
    |> :erpc.multicall(__MODULE__, :local, [], timeout)
    |> Enum.flat_map(fn
      {:ok, workloads} when is_list(workloads) -> workloads
      _failed -> []
    end)
  end

  @doc """
  Workloads on one Kubernetes node, fetched from the agent running there.

  Options (for tests): `:beam_node_for` (1-arity fun), `:timeout`.
  """
  @spec on_node(String.t(), keyword()) :: [Workload.t()]
  def on_node(k8s_node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @rpc_timeout_ms)
    resolve = Keyword.get(opts, :beam_node_for, &Cadmium.Valence.beam_node_for/1)

    if k8s_node == Cadmium.node_name() do
      local()
    else
      case resolve.(k8s_node) do
        nil -> []
        beam_node when beam_node == node() -> local()
        beam_node -> remote_local(beam_node, timeout)
      end
    end
  end

  @doc """
  Pure join of API pods with pod samples by UID. Every pod yields a workload; pods
  without a sample get `sample: nil` and `nil` drifts; samples without a pod are dropped.
  """
  @spec join([Pod.t()], [PodSample.t()], String.t()) :: [Workload.t()]
  def join(pods, samples, k8s_node) do
    by_uid = Map.new(samples, &{&1.pod_uid, &1})

    Enum.map(pods, fn %Pod{} = pod ->
      sample = Map.get(by_uid, pod.uid)

      %Workload{
        pod: pod,
        k8s_node: k8s_node,
        sample: sample,
        cpu_drift: drift(sample && sample.cpu_usage_millis, pod.cpu_request_millis),
        memory_drift: drift(sample && sample.memory_bytes, pod.memory_request_bytes)
      }
    end)
  end

  defp drift(actual, request)
       when is_number(actual) and is_number(request) and request > 0,
       do: actual / request

  defp drift(_actual, _request), do: nil

  defp remote_local(beam_node, timeout) do
    case :erpc.call(beam_node, __MODULE__, :local, [], timeout) do
      workloads when is_list(workloads) -> workloads
      _ -> []
    end
  catch
    _, _ -> []
  end

  defp safe_samples(fun) do
    fun.()
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
