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
commit by swapping a symlink, and smock reloads the files it finds there.
`definitions.gitSync.path` is the definitions directory inside the
repository.

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
  `SMOCK_ADMIN_TOKEN` (`adminAuth.tokenAs=env`). smock reads it at startup,
  so after rotating it, restart the Pods
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

## Scaling and shutdown

Each Pod runs one single-threaded smock process, so the Pod requests about
one CPU core, and a CPU limit above one core would not make it faster: scale
with `replicas` instead
([ADR 0003](https://github.com/hirunefu/smock/blob/main/docs/adr/0003-one-process-per-pod.md)).
Replicas share no state: tests that use Ephemeral Stubs or the Journal need
one replica, or session affinity from a gateway or mesh.

The chart passes `replicas` to smock's replica-count setting, so that each
Admin API response warns when state is per replica. The value goes stale
when something else changes the replica count, such as a
HorizontalPodAutoscaler or `kubectl scale`.

On SIGTERM smock drains for at most `drainTimeoutMs`.
`terminationGracePeriodSeconds` is always above it (by default the drain
timeout plus 10 s, and the chart refuses a shorter one), so that Kubernetes
does not kill a draining Pod.

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
| `drainTimeoutMs` | `20000` | How long smock drains after SIGTERM, in milliseconds (`SMOCK_DRAIN_TIMEOUT_MS`). |
| `terminationGracePeriodSeconds` | `null` | The Pod's grace period; must be above the drain timeout. Empty: the drain timeout plus 10 s. |
| `resources` | `{"requests":{"cpu":"1","memory":"128Mi"},"limits":{"memory":"512Mi"}}` | Resources of the smock container: about one CPU core. Scale with `replicas`, not with a larger CPU limit. |
| `env` | `{}` | Other smock settings, as `SMOCK_<NAME>` variables. |
| `podAnnotations` | `{}` | Annotations of the Pods. |
| `nodeSelector` | `{}` | The Pods' node selector. |
| `tolerations` | `[]` | The Pods' tolerations. |
| `affinity` | `{}` | The Pods' affinity. |
