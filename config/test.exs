import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cadmium, CadmiumWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xKiO/2lVFi0tV19jL7b7hNk0M5NDdGR580ETTRTqhb1hF3aIdzHWsnDJZWfMbKwP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# No cgroups or API server on a dev machine: synthetic telemetry and an in-memory cluster.
config :cadmium, kube_client: Cadmium.Kube.Fake
config :cadmium, Cadmium.Isotope, source: Cadmium.Isotope.Source.Synthetic
config :cadmium, start_subsystems: false, node_name: "test-node"
