# Cadmium

**Cadmium** is a runtime-aware Kubernetes cluster rebalancer. It runs as a DaemonSet, reads
kernel-level pressure metrics directly from each node's cgroups v2 and `/proc` interfaces,
propagates those scores through a BEAM mesh, and—when it holds the leader lease—evicts
overloaded workloads automatically and safely.

---

## How it works

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Each Kubernetes node runs one Cadmium agent (pod)                           │
│                                                                              │
│   ┌─────────────┐  samples   ┌──────────────┐  scores  ┌──────────────────┐ │
│   │   Isotope   │──────────▶ │   Valence    │─────────▶│    Catalyst      │ │
│   │ cgroup / PSI│            │  BEAM mesh   │          │ leader evaluates │ │
│   │ /proc reads │            │ cluster view │          │ evicts hot nodes │ │
│   └─────────────┘            └──────────────┘          └──────────────────┘ │
│                                     │                                        │
│                              Phoenix LiveView dashboard (port 4000)          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Subsystems

| Module | Role |
|---|---|
| **`Cadmium.Isotope`** | Reads cgroups v2 (`cpu.stat`, `memory.*`, PSI) and `/proc` every second, stores a ring-buffer of `NodeSample` and per-pod `PodSample` structs in ETS, and publishes to `isotope:samples` via PubSub. |
| **`Cadmium.Valence`** | Derives a `NodeScore` (0–100) from local Isotope samples and broadcasts it cluster-wide using Phoenix PubSub over the distributed BEAM mesh (libcluster Kubernetes.DNS). Every agent keeps the latest scores and a history for every peer; stale nodes are automatically pruned. |
| **`Cadmium.Catalyst`** | The leader (determined by `Cadmium.Leader`) evaluates whether any node has been hot (`score ≥ hot_threshold` and at least `spread_threshold` above the coolest node) for `sustained_ms`. If so it: puts a `PreferNoSchedule` taint on the hot node, evicts the most disruptive movable workloads via the Kubernetes Eviction API, and removes the taint after the node cooldown. Settings and the audit log are replicated to every agent. |
| **`Cadmium.Leader`** | Kubernetes Lease-based leader election. The lease is renewed every `lease_renew_interval_ms`; loss is detected quickly via a local deadline timer. |
| **`Cadmium.Workloads`** | Joins Kubernetes pod metadata (`Cadmium.Workloads.PodCache`) with Isotope pod samples to produce a `Workload` with CPU/memory drift ratios. `cluster/0` fans out over ERPC to all connected agents. |
| **`Cadmium.Kube`** | Kubernetes API client backed by `Req`. In production it reads the in-cluster service-account token; `Cadmium.Kube.Fake` is a fully self-contained in-memory substitute for demos and dev. |

### Dashboard

The Phoenix LiveView dashboard is accessible on port `4000`:

| Route | Description |
|---|---|
| `/` | Cluster heatmap — one tile per node, hottest first, live-updated |
| `/nodes/:name` | Node detail — score history sparklines, workloads, raw Isotope series |
| `/workloads` | All pods across the cluster with CPU/memory drift |
| `/rebalancer` | Catalyst status, dry-run toggle, simulate, enable/disable |
| `/audit` | Audit log of every eviction and setting change |
| `/healthz` | Liveness / readiness probe (no auth) |

---

## Running locally (demo mode)

```bash
mix setup
mix phx.server
```

No Kubernetes cluster is required. The app starts with `Cadmium.Kube.Fake` and
`Cadmium.Isotope.Source.Synthetic` which generate a realistic multi-node cluster with
synthetic metrics.

Visit [http://localhost:4000](http://localhost:4000).

---

## Configuration

All settings are configurable via environment variables at runtime (see
[`config/runtime.exs`](config/runtime.exs)).

### Core settings

| Variable | Default | Description |
|---|---|---|
| `NODE_NAME` | hostname | Kubernetes node name this agent represents |
| `POD_NAMESPACE` | `default` | Namespace for the leader lease |
| `POD_IP` | `127.0.0.1` | Pod IP; sets the Erlang node name (`cadmium@<POD_IP>`) |
| `SECRET_KEY_BASE` | — | **Required in prod.** Generate with `mix phx.gen.secret` |
| `PORT` | `4000` | HTTP listen port |
| `PHX_HOST` | `localhost` | Canonical hostname (for LiveView origin checks) |

### Cluster discovery

| Variable | Default | Description |
|---|---|---|
| `CADMIUM_HEADLESS_SERVICE` | — | DNS name of the headless Service (`cadmium-headless.default.svc.cluster.local`). When set, libcluster resolves A records and connects peers automatically. |
| `CADMIUM_DIST_PORT` | `9100` | Single Erlang distribution port (declare as a containerPort) |
| `RELEASE_COOKIE` | build-time `releases/COOKIE` | Erlang cookie shared by all agents |

### Isotope (metrics)

| Variable | Default | Description |
|---|---|---|
| `CADMIUM_SOURCE` | `cgroup` | `synthetic` to run without real cgroup access |
| `CADMIUM_SAMPLE_INTERVAL_MS` | `1000` | Sampling interval |
| `CADMIUM_CGROUP_ROOT` | `/sys/fs/cgroup` | cgroups v2 mount point |
| `CADMIUM_PROC_ROOT` | `/proc` | Proc filesystem mount point |

### Catalyst (rebalancing)

| Variable | Default | Description |
|---|---|---|
| `CADMIUM_ENABLED` | `true` | Enable/disable rebalancing |
| `CADMIUM_DRY_RUN` | `true` | Log what would happen without acting. **Start with this on.** |
| `CADMIUM_HOT_THRESHOLD` | `70.0` | Score at or above which a node is considered hot (0–100) |
| `CADMIUM_SPREAD_THRESHOLD` | `25.0` | A hot node must be this far above the coolest node to trigger action |
| `CADMIUM_SUSTAINED_MS` | `120000` | How long a node must be hot before action is taken (ms) |
| `CADMIUM_NODE_COOLDOWN_MS` | `300000` | Minimum gap between actions on the same node (ms) |
| `CADMIUM_WORKLOAD_COOLDOWN_MS` | `900000` | Minimum gap between evictions of the same controller (ms) |
| `CADMIUM_MAX_EVICTIONS_PER_CYCLE` | `1` | Evictions allowed per evaluation cycle |
| `CADMIUM_EXCLUDED_NAMESPACES` | `kube-system` | Comma-separated namespaces never touched |
| `CADMIUM_LEASE_NAME` | `cadmium-catalyst` | Name of the leader Lease object |
| `CADMIUM_LEASE_DURATION_S` | `15` | Leader lease duration in seconds |

### Opting pods out

Automatic rebalancing can evict healthy single-replica workloads, causing downtime
until they restart, and pods using emptyDir, whose contents are lost on eviction.
PodDisruptionBudgets and replica readiness are still respected; hostPath pods remain excluded.

Add the annotation `cadmium.owl-corp.io/rebalance: "false"` to any pod or pod template
to permanently exclude it from eviction.

---

## Deploying to Kubernetes

### Docker image

The [Docker workflow](.github/workflows/docker.yml) publishes a new image to GHCR on every push to `main`:

```
ghcr.io/owl-corp/cadmium:latest          # always the most recent main build
ghcr.io/owl-corp/cadmium:<short-sha>     # immutable; pin this for production
```

The image is public — no pull secret needed.

To build locally (dev / air-gapped):

```bash
docker build -t cadmium:dev .
```

### Installing with Helm

```bash
# Production — pin to a specific short SHA from the Actions run
helm install cadmium charts/cadmium -n cadmium --create-namespace \
  --set image.tag=abc1234

# Or just use latest (not recommended for production)
helm install cadmium charts/cadmium -n cadmium --create-namespace

kubectl -n cadmium rollout status daemonset/cadmium-agent
```

See [`docs/deploy.md`](docs/deploy.md) for the full deployment guide including RBAC,
secrets, cluster mesh verification, going live, and security notes.


---

## Development

```bash
# Install dependencies and build assets
mix setup

# Run tests
mix test

# Run with auto-reload
mix phx.server

# Pre-commit checks (compile, format, unused deps, tests)
mix precommit
```

### Project layout

```
lib/
  cadmium/
    isotope/        # Kernel telemetry: cgroup reader, parser, ring buffer, sampler
    valence/        # BEAM mesh: broadcaster, cluster state, scoring
    catalyst/       # Rebalancer: policy, planner, executor, coordinator, audit log
    kube/           # Kubernetes API client, decoder, fake in-memory implementation
    leader.ex       # Lease-based leader election
    workloads/      # Pod cache + join with Isotope samples
  cadmium_web/
    live/           # LiveView pages (cluster, workloads, rebalancer, audit)
    dashboard/      # Data fetching and formatting helpers
    components/     # Shared HEEx components
test/
  fixtures/         # Recorded cgroup / proc files for deterministic tests
  support/          # Shared test helpers, stubs, fixtures
```

---

## Architecture notes

- **No external database.** All state lives in ETS (ring buffers, cluster scores, audit log)
  and is reconstructed from Kubernetes on restart.
- **Crash-safe cooldowns.** `Cadmium.Catalyst.Cooldowns` annotates acted-upon nodes with a
  Kubernetes annotation so cooldown state survives agent restarts.
- **Demo/dev mode.** When `CADMIUM_KUBE_CLIENT=fake` and `CADMIUM_SOURCE=synthetic` the
  release runs entirely self-contained with no cluster access.
- **IPv6-ready.** `rel/env.sh.eex` auto-detects IPv6 pod IPs and switches Erlang
  distribution to `inet6_tcp`.
