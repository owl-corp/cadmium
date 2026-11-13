# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cadmium,
  generators: [timestamp_type: :utc_datetime],
  # Kubernetes node this agent runs on; set from NODE_NAME at runtime.
  node_name: nil,
  kube_client: Cadmium.Kube.HTTP,
  start_subsystems: true

config :cadmium, Cadmium.Isotope,
  source: Cadmium.Isotope.Source.Cgroup,
  interval_ms: 1_000,
  # samples kept per ring buffer (10 minutes at 1s)
  history_size: 600,
  cgroup_root: "/sys/fs/cgroup",
  proc_root: "/proc"

config :cadmium, Cadmium.Valence,
  broadcast_interval_ms: 2_000,
  # a node whose last score is older than this is dropped from the cluster view
  stale_after_ms: 15_000,
  # scores kept per node
  history_size: 300,
  # libcluster topologies; set in runtime.exs for prod
  topologies: []

config :cadmium, Cadmium.Catalyst,
  enabled: true,
  dry_run: true,
  evaluate_interval_ms: 15_000,
  # a node is hot at or above this score...
  hot_threshold: 70.0,
  # ...when it is also this far above the coolest node...
  spread_threshold: 25.0,
  # ...continuously for this long.
  sustained_ms: 120_000,
  # after acting on a node, leave it (and its taint) alone for this long
  node_cooldown_ms: 300_000,
  # never move pods of the same controller more often than this
  workload_cooldown_ms: 900_000,
  max_evictions_per_cycle: 1,
  taint_key: "cadmium.owl-corp.io/hot",
  # pods with this annotation set to "false" are never moved
  opt_out_annotation: "cadmium.owl-corp.io/rebalance",
  excluded_namespaces: ["kube-system"],
  audit_log_size: 500,
  lease_namespace: "default",
  lease_name: "cadmium-catalyst",
  lease_duration_s: 15,
  lease_renew_interval_ms: 5_000

# Configure the endpoint
config :cadmium, CadmiumWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CadmiumWeb.ErrorHTML, json: CadmiumWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cadmium.PubSub,
  live_view: [signing_salt: "ZQKbGCDH"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cadmium: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  cadmium: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
