# Deploying Cadmium

Cadmium runs as a single DaemonSet, `cadmium-agent`. Each agent reads its node's
cgroup v2 tree and `/proc`, the agents mesh over distributed Erlang through a headless
Service, and the agent holding the `cadmium-catalyst` Lease taints hot nodes and evicts
pods from them. Every agent serves the same dashboard.

It installs in **dry-run**: nothing is tainted or evicted until you opt in.

## Requirements

- Kubernetes >= 1.25, Helm >= 3.8, Linux nodes.
- **cgroups v2** (unified hierarchy) on every node: `stat -fc %T /sys/fs/cgroup` prints
  `cgroup2fs`.
- **PSI enabled**: `cat /proc/pressure/cpu` works on the node. Some distro kernels are
  built with PSI off by default (`CONFIG_PSI_DEFAULT_DISABLED=y`) and need `psi=1` on
  the kernel command line; a few kernels (some VM/desktop ones) have no PSI at all.
- A namespace that admits `hostPath` volumes. Under Pod Security Admission that means
  the `privileged` level (`baseline` forbids hostPath), even though the container
  itself is not privileged:

  ```sh
  kubectl create namespace cadmium
  kubectl label namespace cadmium pod-security.kubernetes.io/enforce=privileged
  ```

- Single-stack IPv4 or IPv4-primary dual-stack pod networking. IPv6-primary clusters
  need a code change, see [IPv6](#ipv6).

## 1. Image

The Docker workflow publishes a new image to GHCR on every push to `main`:

```
ghcr.io/owl-corp/cadmium:latest          # always the most recent main build
ghcr.io/owl-corp/cadmium:<short-sha>     # immutable; pin this for production
```

The image is public. No pull secret is required.

**Production — pin to a specific SHA:**

```sh
# Find the SHA from the commit list or the Actions run
helm install cadmium charts/cadmium -n cadmium --create-namespace \
  --set image.tag=abc1234
```

**Development — build and load locally:**

```sh
docker build -t cadmium:dev .
kind load docker-image cadmium:dev          # kind
minikube image load cadmium:dev             # minikube
k3d image import cadmium:dev               # k3d
```

Then set `--set image.repository=cadmium --set image.tag=dev` in the Helm commands below.


## 2. Install (dry-run)

```sh
helm install cadmium charts/cadmium -n cadmium --create-namespace
kubectl -n cadmium rollout status daemonset/cadmium-agent
```

`agent.dryRun` defaults to `true`. All tunables (thresholds, cooldowns, intervals,
excluded namespaces, lease name, ...) are documented in
[`charts/cadmium/values.yaml`](../charts/cadmium/values.yaml). Consider adding the
install namespace to `agent.excludedNamespaces`.

The chart generates `SECRET_KEY_BASE` and the Erlang cookie on first install and keeps
them across upgrades. `helm template | kubectl apply` and GitOps tools that render
without cluster access cannot do that (they would produce new secrets on every
render): create the Secret yourself and pass `secret.existingSecret`:

```sh
kubectl -n cadmium create secret generic cadmium-secrets \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -hex 24)"
```

## 3. Verify

One agent per node, all Ready:

```sh
kubectl -n cadmium get pods -o wide
```

The mesh formed (each agent should list every other agent as `cadmium@<pod ip>`):

```sh
kubectl -n cadmium exec ds/cadmium-agent -- /app/bin/cadmium rpc 'IO.inspect(Node.list())'
```

Who the leader is (`HOLDER` is a Kubernetes node name):

```sh
kubectl -n cadmium get lease cadmium-catalyst
```

If the mesh is empty: check that `kubectl -n cadmium get endpointslices` lists every
pod IP for `cadmium-headless`, that all pods share the same cookie (same Secret), and
that nothing blocks TCP 4369 and 9100 between pods.

## 4. Dashboard

```sh
kubectl -n cadmium port-forward svc/cadmium 4000:80
# http://localhost:4000
```

## 5. Go live

When the dry-run plans in the dashboard look right:

```sh
helm upgrade cadmium charts/cadmium -n cadmium --reuse-values --set agent.dryRun=false
```

The dashboard switch does the same cluster-wide without a restart, but the Helm value
is what agents start with, so it is the durable setting. To stop acting immediately,
set `agent.dryRun=true` (or `agent.enabled=false` to pause the coordinator).

## 6. Uninstall

```sh
helm uninstall cadmium -n cadmium
kubectl -n cadmium delete lease cadmium-catalyst --ignore-not-found   # created by the app, not Helm
```

Nodes that were in cooldown when the agents stopped may still carry the temporary
`PreferNoSchedule` taint. List and clear them:

```sh
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key' | grep cadmium.owl-corp.io/hot
kubectl taint nodes --all cadmium.owl-corp.io/hot-
```

(`taint ... key-` reports an error for nodes that do not carry the taint; that is
harmless.)

## Security notes

- **Erlang distribution is not encrypted** and is authenticated only by the shared
  cookie. Anyone inside the cluster network who obtains the cookie and can reach a
  pod's port 9100 gets remote code execution in the agents, and with it the agents'
  RBAC (evict any pod, patch any node). Enable the bundled NetworkPolicy
  (`--set networkPolicy.enabled=true`; needs a CNI that enforces policies) so that
  epmd (4369) and distribution (9100) accept connections from agent pods only, and
  restrict who can read the Secret.
- **The dashboard has no authentication and can switch live mode on.** Keep the
  Service `ClusterIP` and use a port-forward. If you enable the Ingress, put it behind
  an authenticating proxy and never on a public address. With the NetworkPolicy
  enabled, in-cluster clients (including an ingress controller) are blocked unless
  listed in `networkPolicy.dashboardFrom`.
- **The agent runs as root, with nothing else.** uid 0 owns the host's cgroup and proc
  files, so it can read them without any capability. All capabilities are dropped,
  privilege escalation is off, the root filesystem and both hostPath mounts are
  read-only, seccomp is `RuntimeDefault`, and there is no `hostPID`/`hostNetwork`.
  Do not set `hostUsers: false`: in a user namespace uid 0 no longer owns those files.
- RBAC is cluster-wide for reads of pods, nodes, PDBs and workload controllers, plus
  `create pods/eviction` and `patch nodes`; Lease access is limited to the one named
  Lease in the release namespace (`create` cannot be limited by name in RBAC).

## Operational notes

- **No CPU limit by default.** A CFS quota would throttle the agent, which is the very
  condition it measures, and can make a leader miss Lease renewals. It has a small CPU
  request and a memory limit.
- **Changing the Erlang cookie** needs all agents restarted together; during a rolling
  restart old and new pods cannot talk to each other and the dashboard shows a partial
  cluster until it finishes.
- `priorityClassName: system-node-critical` is the default. On platforms that restrict
  system priority classes to `kube-system` (GKE, unless a ResourceQuota allows it),
  install there or set `priorityClassName=""`.
- The distribution port is pinned in `rel/env.sh.eex` (`CADMIUM_DIST_PORT`, chart value
  `distribution.port`). `bin/cadmium remote` and `rpc` keep working inside the pod
  because only the long-running node binds it.

### IPv6

The release names itself `cadmium@<POD_IP>` and switches distribution to
`inet6_tcp` automatically when `POD_IP` is an IPv6 address. Discovery does not follow:
`config/runtime.exs` uses libcluster's default resolver, which queries `A` records
only. For an IPv6-primary cluster add
a `resolver:` that looks up `:aaaa` records (libcluster's `Kubernetes.DNS` option) to
the topology config there. Only the node naming and `inet6_tcp` switch have been
exercised; discovery over IPv6 is untested.
