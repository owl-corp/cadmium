defmodule Cadmium.Kube.HTTP do
  @moduledoc """
  In-cluster Kubernetes client (`Cadmium.Kube.Client`) built on Req.

  By default it talks to `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`,
  authenticates with the pod's service account token and verifies the API server against
  the service account CA bundle. The token file is read on every request, because
  projected service account tokens rotate.

  Everything can be overridden with `config :cadmium, Cadmium.Kube.HTTP, ...`:

    * `:base_url` - API server URL (skips the `KUBERNETES_SERVICE_*` lookup)
    * `:token` - a fixed bearer token; `nil` sends no `authorization` header
    * `:token_path` - file to read the bearer token from when `:token` is not set
    * `:ca_path` - CA bundle used to verify the API server; `nil` uses the system store
    * `:page_limit` - `limit` used for list calls (default 500)
    * `:taint_attempts` - attempts of the taint read-modify-write loop (default 4)
    * `:req_options` - options merged last into every request, e.g. `plug: {Req.Test, Name}`
      in tests

  Errors: 404 is `{:error, :not_found}`, 409 is `{:error, :conflict}`, an eviction refused
  with 429 is `{:error, :pdb_blocked}`, any other non-2xx response is
  `{:error, {:http, status, message}}`, and transport failures are `{:error, exception}`.
  Only list calls are retried (briefly, on transient failures); mutating calls are sent once,
  apart from the conflict loop around node taints.
  """

  @behaviour Cadmium.Kube.Client

  alias Cadmium.Kube.{Decode, Lease}

  @service_account "/var/run/secrets/kubernetes.io/serviceaccount"
  @workload_paths %{
    "ReplicaSet" => "/apis/apps/v1/namespaces/:ns/replicasets/",
    "StatefulSet" => "/apis/apps/v1/namespaces/:ns/statefulsets/",
    "Deployment" => "/apis/apps/v1/namespaces/:ns/deployments/",
    "ReplicationController" => "/api/v1/namespaces/:ns/replicationcontrollers/"
  }
  @list_retry [retry: :safe_transient, max_retries: 2, retry_delay: &__MODULE__.retry_delay/1]
  @lease_timeout [receive_timeout: 5_000]

  ## Lists

  @impl true
  def list_pods(opts \\ []) do
    path =
      case opts[:namespace] do
        nil -> "/api/v1/pods"
        namespace -> "/api/v1/namespaces/#{segment(namespace)}/pods"
      end

    params =
      case opts[:node] do
        nil -> []
        node -> [fieldSelector: "spec.nodeName=#{node}"]
      end

    list(path, params, &Decode.pod/1)
  end

  @impl true
  def list_nodes, do: list("/api/v1/nodes", [], &Decode.node/1)

  @impl true
  def list_pdbs, do: list("/apis/policy/v1/poddisruptionbudgets", [], &Decode.pdb/1)

  defp list(path, params, decode) do
    limit = Keyword.get(config(), :page_limit, 500)
    list_pages(path, [limit: limit] ++ params, decode, nil, [])
  end

  defp list_pages(path, params, decode, continue, pages) do
    params = if continue, do: params ++ [continue: continue], else: params

    case request(:get, path, [params: params] ++ @list_retry) do
      {:ok, body} when is_map(body) ->
        pages = [Decode.items(body, decode) | pages]

        case Decode.continue_token(body) do
          nil -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
          token -> list_pages(path, params_without_continue(params), decode, token, pages)
        end

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      {:error, _reason} = error ->
        error
    end
  end

  defp params_without_continue(params), do: Keyword.delete(params, :continue)

  @doc false
  def retry_delay(attempt), do: 200 * (attempt + 1)

  ## Workloads

  @impl true
  def workload_replicas(namespace, kind, name) do
    case Map.fetch(@workload_paths, kind) do
      {:ok, template} ->
        path = String.replace(template, ":ns", segment(namespace)) <> segment(name)

        with {:ok, body} <- request(:get, path) do
          {:ok, Decode.replicas(body)}
        end

      :error ->
        {:error, :unsupported_kind}
    end
  end

  ## Evictions

  @impl true
  def evict_pod(namespace, name, opts \\ []) do
    eviction = %{
      "apiVersion" => "policy/v1",
      "kind" => "Eviction",
      "metadata" => %{"namespace" => namespace, "name" => name}
    }

    eviction =
      if opts[:dry_run],
        do: Map.put(eviction, "deleteOptions", %{"dryRun" => ["All"]}),
        else: eviction

    path = "/api/v1/namespaces/#{segment(namespace)}/pods/#{segment(name)}/eviction"

    case request(:post, path, json: eviction) do
      {:ok, _body} -> :ok
      {:error, {:http, 429, _message}} -> {:error, :pdb_blocked}
      {:error, _reason} = error -> error
    end
  end

  ## Node taints

  @impl true
  def add_node_taint(node, %{key: key} = taint) do
    encoded = Decode.encode_taint(taint)

    update_taints(node, fn taints ->
      if Enum.any?(taints, &(Map.take(&1, ["key", "value", "effect"]) == encoded)) and
           Enum.count(taints, &(&1["key"] == key)) == 1 do
        :unchanged
      else
        {:changed, Enum.reject(taints, &(&1["key"] == key)) ++ [encoded]}
      end
    end)
  end

  @impl true
  def remove_node_taint(node, key) do
    update_taints(node, fn taints ->
      case Enum.reject(taints, &(&1["key"] == key)) do
        ^taints -> :unchanged
        remaining -> {:changed, remaining}
      end
    end)
  end

  # Read-modify-write guarded by a JSON patch `test` op, so that a taint change made by
  # someone else between our read and our write fails the patch instead of being lost.
  defp update_taints(node, change) do
    attempts = Keyword.get(config(), :taint_attempts, 4)
    update_taints(node, change, max(attempts, 1))
  end

  defp update_taints(node, change, attempts_left) do
    path = "/api/v1/nodes/#{segment(node)}"

    with {:ok, body} <- request(:get, path) do
      current = get_in(body, ["spec", "taints"])

      case change.(current || []) do
        :unchanged ->
          :ok

        {:changed, taints} ->
          guard =
            if is_list(current) do
              %{"op" => "test", "path" => "/spec/taints", "value" => current}
            else
              %{
                "op" => "test",
                "path" => "/metadata/resourceVersion",
                "value" => get_in(body, ["metadata", "resourceVersion"])
              }
            end

          patch = [guard, %{"op" => "add", "path" => "/spec/taints", "value" => taints}]

          options = [
            body: Jason.encode!(patch),
            headers: [{"content-type", "application/json-patch+json"}]
          ]

          case request(:patch, path, options) do
            {:ok, _body} ->
              :ok

            # a failed `test` op is reported as 409 or 422 depending on the server version
            {:error, :conflict} when attempts_left > 1 ->
              update_taints(node, change, attempts_left - 1)

            {:error, {:http, 422, _message}} when attempts_left > 1 ->
              update_taints(node, change, attempts_left - 1)

            {:error, _reason} = error ->
              error
          end
      end
    end
  end

  ## Leases

  @impl true
  def get_lease(namespace, name) do
    with {:ok, body} <- request(:get, lease_path(namespace, name), @lease_timeout) do
      {:ok, Decode.lease(body)}
    end
  end

  @impl true
  def create_lease(%Lease{} = lease) do
    body = Decode.encode_lease(%{lease | resource_version: nil})
    options = [json: body] ++ @lease_timeout

    with {:ok, body} <- request(:post, lease_path(lease.namespace), options) do
      {:ok, Decode.lease(body)}
    end
  end

  @impl true
  def update_lease(%Lease{} = lease) do
    options = [json: Decode.encode_lease(lease)] ++ @lease_timeout

    with {:ok, body} <- request(:put, lease_path(lease.namespace, lease.name), options) do
      {:ok, Decode.lease(body)}
    end
  end

  defp lease_path(namespace),
    do: "/apis/coordination.k8s.io/v1/namespaces/#{segment(namespace)}/leases"

  defp lease_path(namespace, name), do: lease_path(namespace) <> "/" <> segment(name)

  ## Requests

  defp request(method, path, options \\ []) do
    with {:ok, req} <- build(config()) do
      req
      |> Req.merge([method: method, url: path] ++ options)
      |> Req.merge(Keyword.get(config(), :req_options, []))
      |> Req.request()
      |> result()
    end
  rescue
    exception -> {:error, exception}
  end

  defp result({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, json(body)}

  defp result({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp result({:ok, %Req.Response{status: 409}}), do: {:error, :conflict}

  defp result({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, message(json(body))}}

  defp result({:error, reason}), do: {:error, reason}

  # Req decodes JSON by content type; cope with servers (and test plugs) that omit it.
  defp json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp json(body), do: body

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp message(body), do: inspect(body, limit: 20)

  defp build(config) do
    with {:ok, base_url} <- base_url(config),
         {:ok, token} <- token(config) do
      options = [
        base_url: base_url,
        headers: [{"accept", "application/json"}],
        retry: false,
        redirect: false,
        receive_timeout: 10_000,
        connect_options: connect_options(config, base_url)
      ]

      options = if token, do: [auth: {:bearer, token}] ++ options, else: options
      {:ok, Req.new(options)}
    end
  end

  defp config, do: Application.get_env(:cadmium, __MODULE__, [])

  defp base_url(config) do
    case config[:base_url] do
      nil -> in_cluster_url(System.get_env("KUBERNETES_SERVICE_HOST"), service_port())
      url -> {:ok, url}
    end
  end

  defp service_port, do: System.get_env("KUBERNETES_SERVICE_PORT", "443")

  @doc false
  def in_cluster_url(host, port) when host in [nil, ""] or port in [nil, ""],
    do: {:error, :not_in_cluster}

  def in_cluster_url(host, port) do
    # IPv6 literals must be bracketed in a URL
    host =
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host

    {:ok, "https://#{host}:#{port}"}
  end

  defp token(config) do
    case Keyword.fetch(config, :token) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        path = Keyword.get(config, :token_path, Path.join(@service_account, "token"))

        case File.read(path) do
          {:ok, token} -> {:ok, String.trim(token)}
          {:error, reason} -> {:error, {:service_account_token, reason}}
        end
    end
  end

  defp connect_options(config, base_url) do
    ca_path = Keyword.get(config, :ca_path, Path.join(@service_account, "ca.crt"))

    if ca_path && String.starts_with?(base_url, "https://") do
      [timeout: 5_000, transport_opts: [cacertfile: ca_path]]
    else
      [timeout: 5_000]
    end
  end

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
