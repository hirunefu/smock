# smock Helm chart

Installs [smock](https://github.com/hirunefu/smock), a mock server for
HTTP/1.1, HTTPS and Server-Sent Events, as a Deployment with a traffic
Service and an admin Service. Its Definition files come from a ConfigMap by
default, or from a Git repository through a git-sync sidecar, or from an OCI
image mounted as a volume. The Pods meet the Restricted Pod Security
Standard in every delivery mode.

Each release of smock publishes the chart at
`oci://ghcr.io/hirunefu/charts/smock`, with the release's version as both its
version and its app version, so it runs `ghcr.io/hirunefu/smock:<version>`.

The chart needs Kubernetes 1.30 or later, for the `sleep` action of the
preStop hook that smock's container runs before it stops (see
[Scaling and shutdown](#scaling-and-shutdown)). On an older cluster, set
`lifecycle.preStopSleepSeconds=0` to leave the hook out.

## Install

The Admin API needs a token, from a Secret:

```sh
kubectl create namespace mocks
kubectl --namespace mocks create secret generic smock-admin-token \
  --from-literal=token="$(openssl rand -hex 32)"
helm install smock oci://ghcr.io/hirunefu/charts/smock --version <version> \
  --namespace mocks \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.users\.yaml=mocks/users.yaml'
```

Without a token Secret, rendering fails with a message that says so, rather
than creating a Pod that smock refuses to start. For local use only,
`--set adminAuth.enabled=false` turns authentication off.

Requests reach the Mocks through the Service `smock` (ports 80 and 443), and
the Admin API through `smock-admin` (port 9090): for example
`kubectl --namespace mocks port-forward service/smock-admin 9090` and
`curl -H "Authorization: Bearer $TOKEN" localhost:9090/v1/status`.

## Definition files

### From a ConfigMap (the default)

The ConfigMap is mounted as a whole volume at the definitions directory,
never with `subPath`, so Kubernetes swaps updated files in and smock reloads
them, without a restart: `helm upgrade` with new Definition files changes
the ConfigMap and leaves the Deployment as it is. The kubelet refreshes
mounted ConfigMaps periodically, so an update takes up to a minute or two to
arrive. The definition set digest in each replica's `GET /v1/status` shows
which files it serves.

The values can carry the files, by name in `definitions.configMap.files`,
and the body files, by path in `definitions.configMap.bodyFiles`. Body files
go into the same ConfigMap and appear under the body-file subdirectory,
`definitions.bodyFileDir` (`files` by default):

```yaml
definitions:
  configMap:
    files:
      users.yaml: |
        mocks:
          - name: users
            hosts: [users.example.com]
        stubs:
          - id: get-user-1
            mock: users
            request: { method: GET, path: /users/1 }
            response: { status: 200, bodyFile: users/1.json }
    bodyFiles:
      users/1.json: '{"id": 1, "name": "Ada"}'
```

Definition file names must end in `.json`, `.yaml` or `.yml` and must not
start with `.`; body file paths must stay inside the body-file
subdirectory. The chart refuses others, since smock would not read them.
Values hold text only, and a ConfigMap holds at most 1 MiB.

ConfigMap keys cannot hold `/`, so with body files the volume lists every
file in its `items`, and those are part of the Pod template. New content for
the same files still reaches smock by reload, but adding, removing or
renaming a file, a Definition file included, changes the Pod template:
`helm upgrade` then rolls out new Pods, which start without the Ephemeral
Stubs and the Journal of the old ones. Without body files there are no
items, and any change reloads in place.

Or `definitions.configMap.name` names a ConfigMap you manage yourself, and
the chart mounts it. Each of its keys is then a file at the top level of the
definitions directory. To place body files under the body-file
subdirectory, list every key in `definitions.configMap.items`, as in a
ConfigMap volume:

```yaml
definitions:
  configMap:
    name: team-mocks
    items:
      - { key: users.yaml, path: users.yaml }
      - { key: user-1, path: files/users/1.json }
```

As with body files in the values, `items` are part of the Pod template:
changing them restarts the Pods, while new content for the listed keys
reloads in place.

### From a Git repository (git-sync)

With `definitions.source=gitSync`, a [git-sync](https://github.com/kubernetes/git-sync)
init container clones `definitions.gitSync.repo` before smock starts, so
smock never starts without its files, and a git-sync sidecar then checks for
new commits every `definitions.gitSync.period`. git-sync publishes each new
commit by swapping a symlink and removing the worktree it replaced, and smock
reloads the files it finds there as soon as that worktree goes. A
`--stale-worktree-timeout` in `definitions.gitSync.extraArgs` keeps old
worktrees for a while; smock then finds each new commit with its poll of the
directory, within 10 s. `definitions.gitSync.path` is the definitions
directory inside the repository.

```yaml
definitions:
  source: gitSync
  gitSync:
    repo: https://github.com/team/mocks.git
    ref: main
    path: mocks/staging
    # A private repository over HTTPS:
    env:
      - name: GITSYNC_USERNAME
        value: mocks-reader
      - name: GITSYNC_PASSWORD
        valueFrom:
          secretKeyRef: { name: mocks-git, key: token }
```

The git-sync containers also run with the restricted security context, as
their image's own numeric UID (`definitions.gitSync.uid`), with their home
directory in a volume of their own. More git-sync flags go in
`definitions.gitSync.extraArgs`.

### From an OCI image

With `definitions.source=image`, the Definition files come from an OCI
image mounted read-only as a volume, with `definitions.image.path` as the
definitions directory inside it. This uses the Kubernetes `image` volume:

- Kubernetes 1.35 or later, where the `ImageVolume` feature is on by default
  (it is stable from 1.36). On 1.33 and 1.34 the `ImageVolume` feature gate
  must be turned on; before 1.33 the Restricted Pod Security Standard does
  not admit `image` volumes.
- A container runtime that supports image volumes, such as containerd 2.1 or
  later, or CRI-O.

The image is resolved when a Pod starts, so smock does not reload it. A new
`definitions.image.reference` changes the Pod template, and `helm upgrade`
rolls out new Pods that mount it. A new image pushed under the same tag
reaches only Pods created after it, so prefer a new tag or a digest for
each change. The files in the image must be readable by UID 65532.

## Admin API token and TLS

- The token Secret (`adminAuth.tokenSecret`) reaches smock as a mounted file
  (`adminAuth.tokenAs=file`, the default) or as the variable
  `SMOCK_ADMIN_TOKEN` (`adminAuth.tokenAs=env`), never both: smock refuses
  to start when both are set, so the chart also refuses
  `SMOCK_ADMIN_TOKEN` and `SMOCK_ADMIN_TOKEN_FILE` in `env`. smock reads
  the token at startup, so after rotating it, restart the Pods
  (`kubectl rollout restart deployment/smock`).
- `tls.secretName` names a `kubernetes.io/tls` Secret (`tls.crt` and
  `tls.key`), such as cert-manager makes. It is mounted as a whole volume
  and passed to smock's certificate settings, so a renewed certificate
  reaches smock without a restart. Without it, smock serves HTTPS with a
  self-signed certificate it generates.
- `tls.mockSecrets` gives single Mocks certificates of their own, chosen by
  SNI: it maps each Mock name to a `kubernetes.io/tls` Secret. Each Secret
  is mounted as a whole volume of its own and passed to smock's
  `SMOCK_TLS_MOCK_CERTS`, so its renewals reach smock without a restart
  too. A handshake whose SNI is a Host of a listed Mock gets that Mock's
  certificate; any other gets the default one, from `tls.secretName` or
  self-signed.

  ```yaml
  tls:
    mockSecrets:
      users: users-tls
      orders: orders-tls
  ```

## Ports, Services and probes

smock's plain, TLS and admin ports (8080, 8443 and 9090) are container
ports. The traffic Service exposes the plain and TLS ports, and the admin
port has a Service of its own, so that each can get its own network policy:
callers reach the Mocks, and only tests and monitoring reach the Admin API
and `/metrics`. The startup, readiness and liveness probes call `/startupz`,
`/readyz` and `/livez` on the admin port, which need no token.

## Security

The Pod and each container meet the Restricted Pod Security Standard in
every delivery mode: a numeric non-root UID (65532 for smock), a read-only
root filesystem, no privilege escalation, every capability dropped and the
runtime default seccomp profile. The Pod mounts no service account token
and gets no Service-link variables, which would collide with smock's
`SMOCK_*` settings. Mounted Secrets are readable by smock's group only.

## Resources

By default smock's container requests and limits one CPU core and 1 GiB of
memory (`resources`). Requests equal to limits give the Pod the Guaranteed
QoS class: it never uses more than the scheduler reserved for it, and it is
among the last Pods evicted when a node runs short of memory. With
`definitions.source=gitSync`, the git-sync containers, whose memory limit
is above their request, make the Pod Burstable.

The defaults are valid on GKE Autopilot as they are. A general-purpose
Autopilot Pod needs a CPU:memory ratio from 1:1 to 1:6.5 (GiB per vCPU), and
Autopilot raises the CPU or the memory of a Pod outside that range; 1 CPU
to 1 GiB is 1:1. Autopilot bills a Pod for its requests, and on clusters
without bursting it sets each limit to its request: that changes nothing
for smock's container, but it lowers git-sync's memory limit to its
request, so raise `definitions.gitSync.resources.requests.memory` there if
git-sync runs out of memory. On a Standard cluster, each Pod needs a node
with one CPU and 1 GiB that no other Pod requests.

Values merge with these defaults, so a smaller Pod sets both requests and
limits: requests alone keep the limits of 1 CPU and 1 GiB. For the smallest
general-purpose Autopilot Pod on a cluster without bursting:

```yaml
resources:
  requests: { cpu: 250m, memory: 512Mi }
  limits: { cpu: 250m, memory: 512Mi }
```

### Sizing

Three sets of measurements follow, all under the profiles of
`bench/plan-autopilot.json` in smock's repository: smock ran under each
row's CPU quota and memory limit, with the 1161 Stubs of
`bench/definitions`, the request mix of `bench/requests.json`, the Journal
on, and 64 keep-alive connections, at fixed rates that climbed from step to
step. Latency counts from each
request's scheduled send time, so it includes about 2 ms at p99 from the
load generator's timer.

**On GKE Autopilot, Arm**, one run in October 2026: smock ran in us-central1,
in arm64 general-purpose Pods on e4a nodes, each with the row's requests
and limits, and the load generator (oha) ran in a Pod on another node,
sending plain HTTP over the Pod network to smock's Service.

| Requests and limits | Which Pod | Kept up with, p99 about 3 ms | Ran out of CPU at | Memory under load | OOM kills |
|---|---|---|---|---|---|
| 50m, 52Mi | The smallest on Autopilot with bursting | 250 requests/s: p99 2.6 ms, p99.9 40 ms | 1,700 to 1,900 requests/s | 11 to 13 MiB | None |
| 250m, 512Mi | The smallest on Autopilot without bursting | 5,000 requests/s: p99 2.2 ms, p99.9 2.9 ms | 11,000 to 12,000 requests/s | 12 to 14 MiB | None |
| 1, 1Gi | The chart's default | 40,000 requests/s: p99 2.7 ms, p99.9 6.8 ms | about 50,000 requests/s | 10 to 14 MiB | None |

- One step higher, at 500, 10,000 and 50,000 requests/s, p99 was 29 ms,
  47 ms and 3 s.
- The Ran out of CPU at column is the most each Pod served. Past it the
  load generator kept sending at its fixed rate, so requests queued,
  latency grew to seconds and some got no answer, but smock kept running:
  no restarts, no failed readiness probes. Per CPU that is about 36,000 to
  50,000 requests/s, roughly half what the laptop below served; the CPU,
  the network path and CPU pinning all differ, and the run did not tell
  them apart.
- 50m and 52Mi suit light traffic only. Even at 125 and 250 requests/s,
  when smock used far less CPU than its quota, its p99.9 was 30 to 40 ms
  (about 2 ms on the laptop), likely from the CFS quota of 5 ms in every
  100 ms, though the run could not confirm it. For latency-sensitive
  tests, use 250m or more.
- Memory under load is the container's working set as `kubectl top`
  sampled it during the load, since the run could not read `memory.peak`
  on Autopilot; idle, it was 8 MiB. Under 52Mi the Journal filled its
  13 MiB bound and evicted its oldest entries, and the kernel never killed
  smock.

**On GKE Autopilot, x86**, two runs in October 2026: as above, but in
general-purpose x86 Pods on ek-standard-8 nodes in us-central1-a, where a
vCPU is a hyperthread; the 250m row is from one of them. smock's x86
performance targets (`bench/targets.json`) come from these runs.

| Requests and limits | Kept up with | Ran out of CPU at | OOM kills |
|---|---|---|---|
| 50m, 52Mi | 125 requests/s: p99 18 to 45 ms, p99.9 80 to 138 ms | about 500 requests/s | None |
| 250m, 512Mi | 1,250 requests/s: p99 3.7 ms, p99.9 8.3 ms | about 3,500 requests/s | None |
| 1, 1Gi | 5,000 requests/s: p99 3.0 ms, p99.9 3.5 to 4.5 ms | about 19,000 requests/s over plain HTTP, 14,000 over HTTPS | None |

- Per vCPU, Arm served about 2.5 times what x86 did (under 1 CPU, 50,000
  against 19,000 requests/s): size x86 Pods by these rows.
- The CFS quota shows more on x86: under 250m, p99 was 69 ms at 625
  requests/s and 3.7 ms at 1,250; under 50m the slowest requests took 80
  to 140 ms at 125 requests/s, and varied from run to run. The advice
  above holds: 50m for light traffic only, 250m or more for
  latency-sensitive tests.

**On a laptop**: smock ran on an M1 MacBook Air, and the load generator on
the same machine sent plain HTTP and HTTPS alike over loopback, at rates
that doubled from step to step. smock serves more there than on GKE:
compare these rows with each other, and size Pods by the GKE numbers
above.

| Requests and limits | Which Pod | Kept up with, p99 about 2 ms | Most served | Peak memory | Idle RSS | Journal bound |
|---|---|---|---|---|---|---|
| 50m, 52Mi | The smallest on Autopilot with bursting | 2,000 requests/s | 4,000 requests/s | 24 MiB | 14.5 MiB | 13 MiB |
| 250m, 512Mi | The smallest on Autopilot without bursting | 10,000 requests/s; 20,000 over plain HTTP | 20,000 requests/s | 25 MiB | 16.4 MiB | 64 MiB |
| 1, 1Gi | The chart's default | 40,000 requests/s; 80,000 over plain HTTP | 80,000 requests/s | 23 MiB, under a 4 GiB limit | 16.5 MiB | 64 MiB |

- Each Pod answered every request up to the highest rate it was sent, the
  Most served column, but there it was at the limit of its CPU over HTTPS:
  p99 was 109 ms at 50m, 21 ms at 250m and 458 ms at 1 CPU (18 ms, 2 ms
  and 2 ms over plain HTTP). So the most a Pod keeps up with lies between
  the two columns, and the most it serves is about the last. From 10,000
  requests/s up, smock took about 10 µs of CPU per request over plain HTTP
  and about 13 µs over HTTPS.
- Most of the 2 ms p99 is the load generator's timer, but near the top a
  small CPU quota shows in the slowest requests: at 50m and 2,000
  requests/s, p99.9 was 29 ms over plain HTTP and 61 ms over HTTPS (2 ms
  and 28 ms at 1,000 requests/s). Under 1 CPU at 80,000 requests/s over
  plain HTTP, the load generator itself fell behind now and then.
- Peak memory is the most the container's cgroup used under load
  (`memory.peak`), the Journal at its bound and socket buffers included,
  and Idle RSS is smock's resident memory 5 s after startup, before any
  load.

More Stubs, more connections or larger bodies in the Journal take more
memory, and the kernel kills a container that goes over its limit. smock
bounds its Journal by default at the smaller of 64 MiB and a quarter of its
memory limit (the laptop table's last column), so a small Pod keeps a small
Journal. `SMOCK_JOURNAL_MAX_BYTES` in `env` sets another bound.

## Scaling and shutdown

Each Pod runs one single-threaded smock process, so a CPU limit above one
core would not make it faster: scale with `replicas` instead
([ADR 0003](https://github.com/hirunefu/smock/blob/main/docs/adr/0003-one-process-per-pod.md)).
Replicas share no state: tests that use Ephemeral Stubs or the Journal need
one replica, or session affinity from a gateway or mesh.

The chart passes `replicas` to smock's replica-count setting, so that each
Admin API response warns when state is per replica. The value goes stale
when something else changes the replica count, such as a
HorizontalPodAutoscaler or `kubectl scale`.

When Kubernetes stops a Pod, during a rolling update for example, it takes
the Pod out of its Services' endpoints, but kube-proxy and load balancers
notice a moment later and may still send it new connections. So Kubernetes
first runs smock's preStop hook, which sleeps for
`lifecycle.preStopSleepSeconds` (5 s by default) while smock keeps serving
and accepting connections. Only then does Kubernetes send SIGTERM, and
smock closes its listeners and drains for at most `drainTimeoutMs`. The
hook uses the Kubernetes `sleep` action, which needs Kubernetes 1.30 or
later; `lifecycle.preStopSleepSeconds=0` leaves the hook out, so SIGTERM
comes at once.

The sleep and the drain both run within `terminationGracePeriodSeconds`,
which is always above their sum: by default it is the sleep plus the drain
timeout plus 10 s (35 s), and the chart refuses a shorter one, so that
Kubernetes does not kill a draining Pod.

## Logs

smock writes its logs to stderr, one JSON object per line: JSON is its only
log format, so a log collector can parse every entry. Only a usage error,
such as an invalid value in `env`, is plain text: smock writes it before
any log entry and exits with status 2.

## Other settings

Every other smock setting can be set in `env`, as its `SMOCK_<NAME>`
variable (`smock serve --help` lists them):

```yaml
env:
  SMOCK_IDLE_TIMEOUT_MS: "120000"
  SMOCK_SEED: "42"
```

The chart refuses the variables it sets itself, `SMOCK_TLS_MOCK_CERTS`
among them, and names the value to use instead.

## Values

| Value | Default | Description |
|---|---|---|
| `replicas` | `1` | How many smock Pods to run; also smock's replica count for the Admin API warning. Stale under an autoscaler or `kubectl scale`. |
| `image.repository` | `"ghcr.io/hirunefu/smock"` | The smock image. |
| `image.tag` | `""` | The image tag. Empty: the chart's appVersion. |
| `image.pullPolicy` | `"IfNotPresent"` | The image pull policy. |
| `imagePullSecrets` | `[]` | Secrets for pulling the images. |
| `definitions.source` | `"configMap"` | Where the Definition files come from: `configMap`, `gitSync` or `image`. |
| `definitions.bodyFileDir` | `"files"` | The body-file subdirectory of the definitions directory (smock's `SMOCK_BODY_FILE_DIR`). |
| `definitions.configMap.name` | `""` | An existing ConfigMap to mount. Empty: the chart makes one from `files` and `bodyFiles`. |
| `definitions.configMap.items` | `[]` | With `name`: where its keys go (`key`, `path`), as in a ConfigMap volume. Empty: every key at the top level. A change to it restarts the Pods. |
| `definitions.configMap.files` | `{}` | Definition files, by file name. |
| `definitions.configMap.bodyFiles` | `{}` | Body files, by path inside `definitions.bodyFileDir`. With them, a file added, removed or renamed restarts the Pods. |
| `definitions.gitSync.repo` | `""` | The Git repository URL. Required with `source: gitSync`. |
| `definitions.gitSync.ref` | `"HEAD"` | The branch, tag or commit to sync. |
| `definitions.gitSync.path` | `""` | The definitions directory inside the repository. Empty: its top. |
| `definitions.gitSync.period` | `"10s"` | How often git-sync checks for a new commit. |
| `definitions.gitSync.depth` | `1` | How many commits of history to fetch (0: all). |
| `definitions.gitSync.env` | `[]` | Environment variables of the git-sync containers, such as credentials from a Secret. |
| `definitions.gitSync.extraArgs` | `[]` | More git-sync flags. |
| `definitions.gitSync.image.repository` | `"registry.k8s.io/git-sync/git-sync"` | The git-sync image. |
| `definitions.gitSync.image.tag` | `"v4.7.1"` | The git-sync image tag. |
| `definitions.gitSync.image.digest` | `"sha256:c5e1976da735bf0b53979f079a07475d77174c51863cd084e928ff6074480717"` | The git-sync image digest. Empty: the tag alone. |
| `definitions.gitSync.image.pullPolicy` | `"IfNotPresent"` | The git-sync image pull policy. |
| `definitions.gitSync.uid` | `65533` | The numeric UID git-sync runs as. |
| `definitions.gitSync.resources` | `{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"256Mi"}}` | Resources of each git-sync container. |
| `definitions.image.reference` | `""` | The OCI image with the Definition files. Required with `source: image`. |
| `definitions.image.pullPolicy` | `"IfNotPresent"` | Its pull policy. |
| `definitions.image.path` | `""` | The definitions directory inside the image. Empty: its top. |
| `adminAuth.enabled` | `true` | Whether the Admin API needs the token. Turn it off for local use only. |
| `adminAuth.tokenSecret.name` | `""` | The Secret that holds the token. Required while `adminAuth.enabled`. |
| `adminAuth.tokenSecret.key` | `"token"` | The key of the token in that Secret. |
| `adminAuth.tokenAs` | `"file"` | How smock gets the token: `file` (mounted) or `env` (`SMOCK_ADMIN_TOKEN`). |
| `tls.secretName` | `""` | A `kubernetes.io/tls` Secret for the TLS port. Empty: a generated self-signed certificate. |
| `tls.mockSecrets` | `{}` | Certificates of single Mocks, chosen by SNI: a `kubernetes.io/tls` Secret by Mock name. |
| `ports.plain` | `8080` | smock's plain port. |
| `ports.tls` | `8443` | smock's TLS port. |
| `ports.admin` | `9090` | smock's admin port: the Admin API, probes and metrics. |
| `service.type` | `"ClusterIP"` | The traffic Service type. |
| `service.plainPort` | `80` | The traffic Service's plain port. |
| `service.tlsPort` | `443` | The traffic Service's TLS port. |
| `service.annotations` | `{}` | Annotations of the traffic Service. |
| `adminService.type` | `"ClusterIP"` | The admin Service type. |
| `adminService.port` | `9090` | The admin Service's port. |
| `adminService.annotations` | `{}` | Annotations of the admin Service. |
| `lifecycle.preStopSleepSeconds` | `5` | How long smock's container sleeps in its preStop hook before SIGTERM, in seconds, while Services stop sending it connections. Needs Kubernetes 1.30 or later. 0: no hook. |
| `drainTimeoutMs` | `20000` | How long smock drains after SIGTERM, in milliseconds (`SMOCK_DRAIN_TIMEOUT_MS`). |
| `terminationGracePeriodSeconds` | `null` | The Pod's grace period, which the preStop sleep and the drain share; must be above their sum. Empty: the sleep plus the drain timeout plus 10 s. |
| `resources` | `{"requests":{"cpu":"1","memory":"1Gi"},"limits":{"cpu":"1","memory":"1Gi"}}` | Resources of the smock container: one CPU core and 1 GiB, requests equal to limits, valid on GKE Autopilot as they are ([Resources](#resources)). Scale with `replicas`, not with a larger CPU limit. |
| `env` | `{}` | Other smock settings, as `SMOCK_<NAME>` variables. |
| `podAnnotations` | `{}` | Annotations of the Pods. |
| `nodeSelector` | `{}` | The Pods' node selector. |
| `tolerations` | `[]` | The Pods' tolerations. |
| `affinity` | `{}` | The Pods' affinity. |
