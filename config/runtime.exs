import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cadmium start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cadmium, CadmiumWeb.Endpoint, server: true
end

config :cadmium, CadmiumWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if node_name = System.get_env("NODE_NAME") do
  config :cadmium, node_name: node_name
end

if config_env() == :prod do
  env_int = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  env_float = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value -> value |> Float.parse() |> elem(0)
    end
  end

  env_bool = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value -> value in ~w(1 true TRUE yes on)
    end
  end

  namespace = System.get_env("POD_NAMESPACE", "default")

  # CADMIUM_KUBE_CLIENT=fake and CADMIUM_SOURCE=synthetic run the release without a cluster.
  if System.get_env("CADMIUM_KUBE_CLIENT") == "fake" do
    config :cadmium, kube_client: Cadmium.Kube.Fake
  end

  config :cadmium, Cadmium.Isotope,
    source:
      if(System.get_env("CADMIUM_SOURCE") == "synthetic",
        do: Cadmium.Isotope.Source.Synthetic,
        else: Cadmium.Isotope.Source.Cgroup
      ),
    interval_ms: env_int.("CADMIUM_SAMPLE_INTERVAL_MS", 1_000),
    cgroup_root: System.get_env("CADMIUM_CGROUP_ROOT", "/sys/fs/cgroup"),
    proc_root: System.get_env("CADMIUM_PROC_ROOT", "/proc")

  # Agents find each other through the A records of a headless Service; the release
  # node name must be cadmium@<pod ip> (see rel/env.sh.eex).
  topologies =
    case System.get_env("CADMIUM_HEADLESS_SERVICE") do
      nil ->
        []

      service ->
        [
          cadmium: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [service: service, application_name: "cadmium", polling_interval: 5_000]
          ]
        ]
    end

  config :cadmium, Cadmium.Valence,
    broadcast_interval_ms: env_int.("CADMIUM_BROADCAST_INTERVAL_MS", 2_000),
    stale_after_ms: env_int.("CADMIUM_STALE_AFTER_MS", 15_000),
    topologies: topologies

  config :cadmium, Cadmium.Catalyst,
    enabled: env_bool.("CADMIUM_ENABLED", true),
    dry_run: env_bool.("CADMIUM_DRY_RUN", true),
    evaluate_interval_ms: env_int.("CADMIUM_EVALUATE_INTERVAL_MS", 15_000),
    hot_threshold: env_float.("CADMIUM_HOT_THRESHOLD", 70.0),
    spread_threshold: env_float.("CADMIUM_SPREAD_THRESHOLD", 25.0),
    sustained_ms: env_int.("CADMIUM_SUSTAINED_MS", 120_000),
    node_cooldown_ms: env_int.("CADMIUM_NODE_COOLDOWN_MS", 300_000),
    workload_cooldown_ms: env_int.("CADMIUM_WORKLOAD_COOLDOWN_MS", 900_000),
    max_evictions_per_cycle: env_int.("CADMIUM_MAX_EVICTIONS_PER_CYCLE", 1),
    excluded_namespaces:
      "CADMIUM_EXCLUDED_NAMESPACES"
      |> System.get_env("kube-system")
      |> String.split(",", trim: true),
    lease_namespace: namespace,
    lease_name: System.get_env("CADMIUM_LEASE_NAME", "cadmium-catalyst"),
    lease_duration_s: env_int.("CADMIUM_LEASE_DURATION_S", 15),
    discord_webhook_url: System.get_env("CADMIUM_DISCORD_WEBHOOK_URL")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  config :cadmium, CadmiumWeb.Endpoint,
    url: [host: host],
    # reached via port-forward, Service or ingress under arbitrary hostnames
    check_origin: false,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cadmium, CadmiumWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cadmium, CadmiumWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
