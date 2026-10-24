# Getting started on GKE

This guide takes a reader who is new to smock from nothing to smock
answering requests on GKE Autopilot. It installs a release: the Helm
chart that each release publishes runs the image of the same release,
which the cluster pulls from ghcr.io.
[Appendix: an unreleased commit](#appendix-an-unreleased-commit) runs a
commit that no release holds yet, from CI's binary and a checkout of the
repository.

- The steps run in order, in one shell: each block works as it is after
  the blocks before it, once placeholders such as `<project ID>` and
  `<version>` are filled in.
- Nothing costs money until the cluster is created, in
  [Create an Autopilot cluster](#create-an-autopilot-cluster). From
  there on, the project is billed for the cluster and smock's Pod until
  [Clean up](#clean-up) deletes them; Google's GKE pricing page gives
  the rates.
- smock itself runs on GKE Autopilot in the benchmark, and the Helm
  chart is tested on kind. The GKE commands below follow GKE's
  documentation of 2026-10-13. On 2026-10-17, before the first release,
  the guide ran in us-central1, on GKE Autopilot and on a Standard
  cluster, in a project whose node service account had no roles, with
  every one of its [Next steps](#next-steps). Those runs took the image
  and the chart from CI's binary and a checkout, as the
  [appendix](#appendix-an-unreleased-commit) does, and the outputs the
  guide shows are from them. The steps with the published image and
  chart have not run on GKE yet.

## Contents

- [What you need](#what-you-need)
- [How smock serves requests](#how-smock-serves-requests)
- [Choose a release](#choose-a-release)
- [Write and check a Definition file](#write-and-check-a-definition-file)
- [Create an Autopilot cluster](#create-an-autopilot-cluster)
- [Install smock](#install-smock)
- [Send a request and call the Admin API](#send-a-request-and-call-the-admin-api)
- [Clean up](#clean-up)
- [Next steps](#next-steps)
- [Troubleshooting](#troubleshooting)
- [Appendix: an unreleased commit](#appendix-an-unreleased-commit)

## What you need

A machine with a POSIX shell (Linux, macOS, or Windows with WSL), and:

- A Google Cloud project with billing turned on, and the gcloud CLI
  logged in (`gcloud auth login`). Owner on the project is simplest.
  Otherwise the steps need roles that enable services (Service Usage
  Admin), grant a role on the project (Project IAM Admin), create a
  cluster and install into it (Kubernetes Engine Admin), and let the
  cluster's nodes run as the Compute Engine default service account
  (Service Account User on that account).
- docker and a running Docker daemon, to check Definition files with
  smock's image. On Linux with glibc 2.34 or later and OpenSSL 3, the
  release binary checks them without docker.
- kubectl (CI uses 1.37.1) and helm 3.8 or later (CI uses 4.3.0), which
  installs charts from OCI registries such as ghcr.io.
- curl, jq, openssl and base64.

The guide assumes the basics of Kubernetes and Helm: Pods, Services,
Secrets, ConfigMaps, namespaces, `kubectl port-forward`, and installing
a chart as a release.

## How smock serves requests

smock answers HTTP requests with the responses declared in *Definition
files*: YAML or JSON files in one directory, the definitions directory.
A Definition file declares *Mocks* and *Stubs*:

- A Mock stands in for one service. The request's Host, the name in its
  URL, picks the Mock that lists it in `hosts`. The *Default Mock*
  answers requests whose Host no Mock lists, and a lone Mock is the
  Default Mock, so it answers every Host.
- A Stub is a set of request conditions, such as a method and a path,
  plus the response to send. smock tries a Mock's Stubs in the order
  they are declared, unless a `priority` says otherwise, and the first
  whose conditions all hold answers
  ([Which Stub answers](definition-files.md#which-stub-answers)).

smock listens on three ports, and the Helm chart puts two Services in
front of them:

| Port | Serves | Service and port |
|---|---|---|
| 8080 | Requests for the Mocks, over HTTP | `smock`, 80 |
| 8443 | The same, over HTTPS | `smock`, 443 |
| 9090 | The *Admin API*, the health probes and the metrics | `smock-admin`, 9090 |

The Admin API inspects and changes a running smock. It needs a bearer
token, which the chart reads from a Secret. smock watches the
definitions directory and reloads the files when they change, so new
Definition files are served without a restart.

## Choose a release

smock is built for Linux, for amd64 and arm64. Each release publishes,
under the same version:

- the container image `ghcr.io/hirunefu/smock:<version>`, for
  linux/amd64 and linux/arm64;
- the Helm chart `oci://ghcr.io/hirunefu/charts/smock`, whose version
  and app version are the release's, so that it runs the image of the
  same release;
- the binaries `smock-<version>-linux-amd64` and
  `smock-<version>-linux-arm64`, the ones in the image, on the release's
  page under [Releases](https://github.com/hirunefu/smock/releases).

The version is the release's tag without its `v`. Take the latest
release:

```sh
curl -fsSL https://api.github.com/repos/hirunefu/smock/releases/latest | jq -r .tag_name   # v<version>
export VERSION=<version>
export IMAGE=ghcr.io/hirunefu/smock:$VERSION
```

The image and the chart are signed. The README's
[Verify the image](../README.md#verify-the-image) says how to check the
image's signature and fetch its SBOM, and
[Verify the Helm chart](../README.md#verify-the-helm-chart) how to check
the chart's signature. The README's
[Container image and release binaries](../README.md#container-image-and-release-binaries)
and [charts/smock/README.md](../charts/smock/README.md) describe the
image and the chart.

## Write and check a Definition file

Make a directory for the guide's files, with a directory `defs` in it,
and work there (`mkdir -p smock-on-gke/defs && cd smock-on-gke`). Save
this Definition file as `defs/users.yaml`:

```yaml
mocks:
  - name: users

stubs:
  - id: get-user
    mock: users
    request: { method: GET, path: /users/1 }
    response:
      status: 200
      json: { id: 1, name: Alice }
```

It declares one Mock, `users`, and one Stub, `get-user`, which answers
`GET /users/1` with status 200 and a JSON body; `json` sends the value
as compact JSON with `Content-Type: application/json`.
[definition-files.md](definition-files.md) describes every field.

smock does not start with Definition files that are not valid, so check
them before installing. `smock check` reads a definitions directory as
`smock serve` does. The image's entrypoint is smock, so the image checks
the directory, mounted read-only:

```sh
docker run --rm -v "$PWD/defs:/defs:ro" "$IMAGE" check /defs   # prints nothing and exits with status 0
```

A problem is printed with the file and the JSON Pointer of the value,
such as `users.yaml: /stubs/0/response/status: must be an integer from
200 to 599`, and the exit status is 1. docker pulls the image of this
machine's architecture, so it runs without emulation on x86 and on Arm
machines, an Arm Mac included.

On Linux with glibc 2.34 or later and OpenSSL 3, such as Ubuntu 22.04 or
later, the release binary checks the directory too:

```sh
arch=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
curl -fsSL -o smock "https://github.com/hirunefu/smock/releases/download/v$VERSION/smock-$VERSION-linux-$arch"
chmod +x smock
./smock check defs                # prints nothing and exits with status 0
```

## Create an Autopilot cluster

An Autopilot cluster has no nodes to size: GKE adds nodes for the Pods
it is asked to run, and bills the Pods' resource requests. The chart's
defaults, one CPU and 1 GiB with requests equal to limits, are valid
there as they are, and Autopilot keeps them unchanged.

Name the project and a region, and enable GKE in the project. The
variables serve the later steps too; `us-central1` is an example:

```sh
export PROJECT=<project ID> LOCATION=us-central1
gcloud services enable container.googleapis.com --project="$PROJECT"
```

The nodes pull smock's image from ghcr.io, so they need a route to the
internet: private nodes, which have no external addresses, need Cloud
NAT for it. They send their logs and metrics as the Compute Engine
default service account, `<project number>-compute@developer.gserviceaccount.com`.
In a project whose organisation turns off the automatic Editor grant to
that account, as organisations created on or after 2024-05-03 do by
default, it has no roles. Grant it GKE's default node role on the
project, which GKE's documentation asks for (2026-10-13), so that the
nodes can send them. A role the account already has changes nothing:

```sh
N=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "$PROJECT" --condition=None \
  --member="serviceAccount:$N-compute@developer.gserviceaccount.com" --role=roles/container.defaultNodeServiceAccount
```

Right after the service is enabled, the account may not exist yet; then
wait a minute and run the grant again.

From here on, the project is billed. Create the cluster and point
kubectl at it:

```sh
gcloud components install gke-gcloud-auth-plugin
gcloud container clusters create-auto smock --location="$LOCATION" --project="$PROJECT"
gcloud container clusters get-credentials smock --location="$LOCATION" --project="$PROJECT"
kubectl get namespaces            # default, kube-system and others
```

- Creating the cluster takes several minutes, seven to nine in
  us-central1 on 2026-10-17.
- kubectl reaches GKE through `gke-gcloud-auth-plugin`. When gcloud came
  from a package manager such as apt or dnf, `gcloud components install`
  refuses; the package `google-cloud-cli-gke-gcloud-auth-plugin` installs
  the plugin instead.
- `get-credentials` adds the cluster to kubectl's configuration and makes
  it the current context.

## Install smock

Install the release's chart into a namespace of its own, `mocks`. The
chart reads the Admin API token from a Secret, and puts the Definition
file into a ConfigMap that it mounts as smock's definitions directory:

```sh
kubectl create namespace mocks
kubectl --namespace mocks create secret generic smock-admin-token \
  --from-literal=token="$(openssl rand -hex 32)"
helm upgrade --install smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.users\.yaml=defs/users.yaml' \
  --wait --timeout 10m
kubectl --namespace mocks get pods          # smock-<hash>   1/1   Running
```

- helm pulls the chart from ghcr.io. Its app version, the release's
  version, picks the image, so the Pod runs `$IMAGE`,
  `ghcr.io/hirunefu/smock:<version>`.
- `--set-file` puts `defs/users.yaml` into the ConfigMap as the file
  `users.yaml`; the `\.` keeps the dot inside the key.
- `helm upgrade --install` installs the release the first time and
  upgrades it afterwards, so the same command also repairs a failed
  install. `--wait` returns once the Pod is ready, after Autopilot adds
  a node for it, which took about a minute on 2026-10-17.
- helm then prints the chart's notes, which name the release,
  `smock <version>`.

## Send a request and call the Admin API

Forward two local ports to the Services, in the background:

```sh
kubectl --namespace mocks port-forward service/smock 8080:80 >/dev/null &
kubectl --namespace mocks port-forward service/smock-admin 9090 >/dev/null &
```

Then send the Stub's request:

```sh
curl -i localhost:8080/users/1
```

```http
HTTP/1.1 200 OK
Content-Type: application/json
Smock-Mock: users; via=default
Content-Length: 23

{"id":1,"name":"Alice"}
```

`Smock-Mock` names the Mock that answered, and `via=default` says that
it answered as the Default Mock, since no Mock lists the Host
`localhost`. A request that no Stub matches gets 404, with a
`Smock-Near-Miss` header that names the closest Stub and the conditions
it failed, its *Near miss*:

```sh
curl -i localhost:8080/users/2
```

```http
HTTP/1.1 404 Not Found
Content-Type: application/json
Smock-Near-Miss: get-user; failed=path
Smock-Mock: users; via=default
Content-Length: 27

{"error":"no Stub matched"}
```

The Admin API needs the token from the Secret:

```sh
TOKEN=$(kubectl --namespace mocks get secret smock-admin-token --output jsonpath='{.data.token}' | base64 --decode)
curl -H "Authorization: Bearer $TOKEN" localhost:9090/v1/status
# {"version":"<version>","commit":"<commit>","toolchain":"moonc v<MoonBit version>","digest":"<digest>","lastReload":null,"mocks":[{"name":"users","hosts":[],"default":true}],"warnings":[]}
```

`version`, `commit` and `toolchain` name the release's build, as
`smock --version` does, and `digest` names the definition set, the set
of Definition files that smock serves; `lastReload` stays `null` until
the files change.
[openapi/admin.json](../openapi/admin.json) describes every operation of
the Admin API.

## Clean up

When you are done with this guide and its [Next steps](#next-steps),
stop the port-forwards, delete the release and the namespace, then the
cluster, which ends the charges:

```sh
jobs                              # [1] and [2]: the two port-forwards
kill %1 %2
helm uninstall smock --namespace mocks
kubectl delete namespace mocks    # also deletes the token Secret
gcloud container clusters delete smock --location="$LOCATION" --project="$PROJECT"
```

gcloud asks for confirmation, and deleting the cluster takes several
minutes. The project's grant of `roles/container.defaultNodeServiceAccount`
stays, and `gcloud projects remove-iam-policy-binding` with the same
flags removes it. `docker image rm "$IMAGE"` removes the local copy of
the image, and `rm smock` the binary, if you downloaded it.

## Next steps

Each of these builds on the install above, so try them before cleaning
up. [On a Standard cluster](#on-a-standard-cluster) is the exception: it
repeats the path from
[Create an Autopilot cluster](#create-an-autopilot-cluster) on a cluster
of another type.
[migrating-from-mockoon.md](migrating-from-mockoon.md) turns Mockoon
environments into Definition files, and
[serves its example](migrating-from-mockoon.md#running-it-where-mockoon-ran)
on this install too.

### Change the definitions and watch the reload

Add a second Stub at the end of `defs/users.yaml`, under `stubs`. Its
path is an RE2 pattern, which must match the whole path, and its
response is a template: `${number(path[1])}` is the second segment of
the path as a JSON number, and `${fake.name()}` makes up a name.

```yaml
  - id: get-any-user
    mock: users
    request: { method: GET, path: { pattern: "/users/[0-9]+" } }
    response:
      status: 200
      template: true
      json:
        id: ${number(path[1])}
        name: ${fake.name()}
```

Check the directory, then upgrade the release with the new file. Only
the ConfigMap changes, so the Pod keeps running, and smock reloads the
file once the kubelet refreshes the mounted ConfigMap, within a minute
or two. Repeat the status call until it shows `"swapped"`:

```sh
docker run --rm -v "$PWD/defs:/defs:ro" "$IMAGE" check /defs
helm upgrade smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks --reuse-values \
  --set-file 'definitions.configMap.files.users\.yaml=defs/users.yaml'
curl -s -H "Authorization: Bearer $TOKEN" localhost:9090/v1/status | jq '.lastReload.result'   # null, then "swapped"
curl localhost:8080/users/42      # {"id":42,"name":"<a made-up name>"}
```

`"failed"` means that the new files are not valid: `.lastReload.errors`
lists the problems, and the running Pod keeps serving the previous
definition set. A Pod that starts while the ConfigMap holds the invalid
files, such as after `kubectl rollout restart` or when GKE moves the Pod
to another node, crash-loops with `invalid definitions`, so fix the
file and upgrade again.
[definition-files.md](definition-files.md#templates) describes
templates, and the rest of that file describes conditions, responses
and Faults.

### Call it from other Pods

Inside the cluster, the Service `smock` serves the Mocks at
`http://smock.mocks.svc.cluster.local/`, and over HTTPS on port 443 with
a certificate that smock generates and signs itself, unless
`tls.secretName` names a Secret with one. A throwaway Pod in the
namespace `default` shows it:

```sh
kubectl run curl --restart=Never --image=curlimages/curl:8.22.0 -- curl -s http://smock.mocks.svc.cluster.local/users/1
kubectl wait pod/curl --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
kubectl logs pod/curl             # {"id":1,"name":"Alice"}
kubectl delete pod curl
```

On Autopilot, `kubectl run` first prints a warning that
`autopilot-default-resources-mutator` gave the Pod default resources,
since it asks for none; that is expected.

Every client of that URL sends the same Host, so one Mock answers them
all. With several Mocks, each needs a Host of its own: give each Mock a
Service named after it that selects the same Pods, and list the names
its clients use in its `hosts`. For a Mock `orders`, make its Service:

```sh
kubectl --namespace mocks expose deployment smock --name orders --port 80 --target-port plain
```

Then save its Definition file as `defs/orders.yaml`:

```yaml
mocks:
  - name: orders
    hosts: [orders.mocks, orders.mocks.svc.cluster.local]

stubs:
  - id: get-order
    mock: orders
    request: { method: GET, path: /orders/1 }
    response:
      status: 200
      json: { id: 1, item: book }
```

With more than one Mock, none is the Default Mock unless one is marked
`default: true`, and `smock check` does not warn about it. Without the
mark, `users`, which lists no `hosts`, answers nothing, and a request
for any other Host, `localhost` included, gets 404
`no Mock for this Host`. So mark `users` at the top of
`defs/users.yaml`:

```yaml
mocks:
  - name: users
    default: true
```

Check the directory, and upgrade the release with both files:

```sh
docker run --rm -v "$PWD/defs:/defs:ro" "$IMAGE" check /defs
helm upgrade smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks --reuse-values \
  --set-file 'definitions.configMap.files.users\.yaml=defs/users.yaml' \
  --set-file 'definitions.configMap.files.orders\.yaml=defs/orders.yaml'
```

After the reload, the throwaway Pod above, with
`http://orders.mocks.svc.cluster.local/orders/1` as its URL, prints
`{"id":1,"item":"book"}`, and `curl localhost:8080/users/1` still gets
Alice from `users`. Deleting the namespace deletes the Service `orders`
too. [definition-files.md](definition-files.md#hosts-and-the-default-mock)
describes Hosts and the Default Mock.

### Reach it from the VPC

To reach the Mocks from VMs or other clusters in the same VPC network
and region, give the Service `smock` an internal passthrough load
balancer:

```sh
helm upgrade smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks --reuse-values \
  --set service.type=LoadBalancer \
  --set-string 'service.annotations.networking\.gke\.io/load-balancer-type=Internal'
kubectl --namespace mocks get service smock    # EXTERNAL-IP: an address inside the VPC
```

Without the annotation, GKE makes an external load balancer, and the
Mocks are public. Clients in other regions of the network also need
global access (GKE's documentation, 2026-10-13), which this flag on the
same upgrade turns on:

```sh
  --set-string 'service.annotations.networking\.gke\.io/internal-load-balancer-allow-global-access=true'
```

On Autopilot on 2026-10-17, the address came within about a minute,
and GKE made a forwarding rule with the scheme `INTERNAL`, for ports 80
and 443, with global access on when the flag was given.
`helm uninstall` deletes it with the Service.

Never expose `smock-admin` this way: `/metrics` needs no token, and the
token travels over plain HTTP. The chart has no Ingress or Gateway
template.

### Check what was called

smock records every request in its *Journal*, so that a test can check
what its system sent. Verify that `/users/1` was called; the count
includes every such request sent so far:

```sh
curl -H "Authorization: Bearer $TOKEN" -d '{"filter":{"path":"/users/1"},"atLeast":1}' \
  localhost:9090/v1/journal/verify
# {"ok":true,"count":<n>,"evicted":0,"reason":null,"warnings":[]}
curl -s -H "Authorization: Bearer $TOKEN" localhost:9090/v1/journal/unmatched |
  jq --compact-output '.entries[] | {target: .request.target, nearMiss}'
```

The second call lists the requests that no Stub answered, such as
`/users/2`, each with its Near miss in full. Tests keep their requests
apart with a *Session*, named in the header
`baggage: smock-session=<key>`, and can add *Ephemeral Stubs* that only
their Session sees. The README's
[Sessions and Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs)
and [The Journal](../README.md#the-journal) describe both. Each Pod
keeps its own Ephemeral Stubs, Scenario state, Variables, copies of Data
buckets and Journal, so tests that use them need one replica.

### Logs and metrics

smock logs JSON lines to stderr, such as its startup and each reload; it
logs no requests. `/metrics` on the admin port serves Prometheus
metrics, labelled by Mock and Stub:

```sh
kubectl --namespace mocks logs deployment/smock
curl -s localhost:9090/metrics | grep '^smock_requests_total'
# smock_requests_total{mock="users",stub="get-user"} <n>
# smock_requests_total{mock="users",stub=""} <n>
# smock_requests_total{mock="users",stub="get-any-user"} <n>
# smock_requests_total{mock="orders",stub="get-order"} <n>
```

`stub=""` counts the requests that no Stub answered, and `mock=""`
those that no Mock answered.

On GKE, Cloud Logging also collects these logs, through the node role
granted in [Create an Autopilot cluster](#create-an-autopilot-cluster),
with each line's fields under `jsonPayload`. The chart makes no
PodMonitoring for Google Cloud Managed Service for Prometheus, which
Autopilot runs, so scraping `/metrics` there takes one of your own:

```yaml
apiVersion: monitoring.googleapis.com/v1
kind: PodMonitoring
metadata:
  name: smock
  namespace: mocks
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: smock
  endpoints:
    - port: admin
      interval: 30s
```

Save it as `podmonitoring.yaml` and run
`kubectl apply -f podmonitoring.yaml`. On 2026-10-17 the metrics could
be queried about two minutes later. Managed Service for Prometheus
counts from its first scrape, so `smock_requests_total` starts there at
0 and counts the requests after it.

### On a Standard cluster

On a Standard cluster the nodes are yours to size, and GKE does not
change the Pods' resources. GKE reserves 1060m of the two shared vCPUs
of an `e2-medium` node, the default machine type (GKE's documentation,
2026-10-13), so such a node cannot take smock's one-CPU Pod, which stays
Pending. In place of `create-auto`, create a zonal cluster with a larger
machine type, after the same grant, and use the zone for
`get-credentials` and for deleting it too:

```sh
gcloud container clusters create smock --location=us-central1-a --project="$PROJECT" \
  --machine-type=e2-standard-2 --num-nodes=1
gcloud container clusters get-credentials smock --location=us-central1-a --project="$PROJECT"
```

For a smaller Pod instead, add these flags to the install; values merge
with the chart's defaults, so set both the requests and the limits:

```sh
  --set resources.requests.cpu=250m --set resources.requests.memory=512Mi \
  --set resources.limits.cpu=250m --set resources.limits.memory=512Mi
```

The chart README's [Resources](../charts/smock/README.md#resources)
section has more.

On 2026-10-17, with GKE 1.36.4, the cluster took about eight minutes to
create, and deleting it about five. Its `e2-standard-2` node had 1930m
of CPU to allocate, of which GKE's own Pods requested 648m, so smock's
one-CPU Pod was running 13 seconds after the install started, and it
answered as above. An `e2-medium` node had 940m, and the same Pod on it
stayed Pending with `Insufficient cpu`. With the flags above, the Pod
got 250m and 512Mi as both its requests and its limits.

### Arm nodes

Autopilot also runs Arm (arm64) Pods, in us-central1, us-east1,
us-west1, europe-west1, europe-west2, europe-west4 and asia-southeast1
(GKE's documentation, 2026-10-13). The image is for linux/arm64 too, so
this flag on the install is all it takes:

```sh
  --set-string 'nodeSelector.cloud\.google\.com/compute-class=autopilot-arm'
```

- The compute class needs GKE 1.35.3-gke.1389000 or later. This prints
  the cluster's version:

  ```sh
  gcloud container clusters describe smock --location="$LOCATION" --project="$PROJECT" \
    --format='value(currentMasterVersion)'
  ```

- Before 1.36.0-gke.3302001, GKE's documentation asks for the
  architecture label too:
  `--set-string 'nodeSelector.kubernetes\.io/arch=arm64'`. From that
  version on, Autopilot adds the label itself. Giving it as well makes
  helm print a warning,
  `Key 'kubernetes.io/arch' is not recommended with node selector`, and
  the Pod runs on an Arm node all the same.
- Without the compute class, the Pod runs on an x86 node.

On 2026-10-17, with GKE 1.36.4, the Pod ran on a `c4a-standard-4` node
about a minute and a half after the install started, and answered as
above.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `helm upgrade --install` cannot pull the chart, and says `not found`. | `$VERSION` names no release. It is a release's tag without its `v`; [Choose a release](#choose-a-release) prints the latest tag. |
| kubectl says that `gke-gcloud-auth-plugin` is not found. | Install the plugin, as in [Create an Autopilot cluster](#create-an-autopilot-cluster), then run `get-credentials` again. |
| helm says `adminAuth.tokenSecret.name is empty, but Admin API authentication is on`. | Create the token Secret and pass its name with `--set adminAuth.tokenSecret.name=smock-admin-token`. |
| `helm upgrade --install` waits the whole `--timeout`, then fails with `resource Deployment/mocks/smock not ready. status: InProgress, message: Available: 0/1` and `context deadline exceeded`. | The Pod did not become ready. `kubectl --namespace mocks get pods` shows its status; find it in the rows below. |
| The Pod stays in `ContainerCreating`, and `kubectl --namespace mocks describe pod` says `MountVolume.SetUp failed for volume "admin-token" : secret "smock-admin-token" not found`. | The token Secret is not in the namespace `mocks`, for example because it was created without `--namespace mocks`. Create it as in [Install smock](#install-smock): the Pod then starts by itself, and running `helm upgrade --install` again marks the release `deployed`. |
| helm says `cannot reuse a name that is still in use`. | A failed `helm install` left the release behind. Use `helm upgrade --install`, as in [Install smock](#install-smock). |
| The Pod is in `ErrImagePull` or `ImagePullBackOff`. | `kubectl --namespace mocks describe pod` names the image and the error. When the error says that the node cannot reach `ghcr.io`, the nodes have no route to the internet: see [Create an Autopilot cluster](#create-an-autopilot-cluster). The kubelet keeps retrying the pull. With an image of an unreleased commit, see [Troubleshooting an unreleased commit](#troubleshooting-an-unreleased-commit). |
| The Pod is in `CrashLoopBackOff`, and its log says `invalid definitions`. | smock does not start with Definition files that are not valid, and `helm --wait` fails after its timeout. The log entry names the file, the JSON Pointer and the error: fix the file, check it, and run `helm upgrade --install` again. |
| The Pod is `Pending`. | On Autopilot, for a few minutes while GKE adds a node. On a Standard cluster, `Insufficient cpu` in `kubectl --namespace mocks describe pod` means that the node is too small: see [On a Standard cluster](#on-a-standard-cluster). |
| curl gets `Empty reply from server` or `Connection refused`, and kubectl printed `error: lost connection to pod`; or, just after an upgrade, curl still gets the previous files' answers. | A port-forward follows one Pod. When that Pod is replaced, such as by `kubectl rollout restart` or an upgrade that restarts the Pods, the port-forward reaches the old Pod while it shuts down, then ends. Stop the port-forward (`kill %1 %2`) and start it again. |
| curl gets an answer that the guide does not show, such as 404 `{"error":"no Stub matched"}` with `Smock-Mock: default; via=default` and no `Smock-Near-Miss`, or the Admin API answers 401; or a port-forward prints `unable to listen on any of the requested ports`. | Something else on the machine, such as a local smock, already listens on 8080 or 9090. When it listens on IPv4 only, as smock does, kubectl forwards on `[::1]` alone and says so only on its standard output, which the commands above discard, so curl can reach the other program. `ss -ltnp \| grep -E ':(8080\|9090)'` (`lsof -i :8080` on macOS) shows it. Forward other local ports, such as `18080:80` and `19090:9090`, and send the requests there. |
| A request gets 404 `{"error":"no Stub matched"}`. | If the response also says `Smock-Mock: default` and has no `Smock-Near-Miss`, another program answered: see the row above. Otherwise `Smock-Near-Miss` names the closest Stub and the conditions it failed; `/v1/journal/unmatched` shows what each condition expected. |
| A request gets 404 `no Mock for this Host`. | There are several Mocks, and none lists the request's Host or is `default: true`: see [Call it from other Pods](#call-it-from-other-pods). |
| A changed file is not served. | The kubelet refreshes the ConfigMap within a minute or two. If `.lastReload.result` is `"failed"`, `.lastReload.errors` lists the problems, and the running Pod keeps serving the previous definition set; a new Pod does not start until the file is fixed and upgraded. |
| Ephemeral Stubs and the Journal are empty after an upgrade. | They live in the Pod, and the upgrade replaced it: with body files in the chart's values, adding, removing or renaming a file restarts the Pods, as does a new image. |

## Appendix: an unreleased commit

The steps above install a release. To run a commit that no release
holds yet, such as the head of `main`, take the binary that CI builds
from it, pack it into an image, push the image to Artifact Registry in
the project, and install the chart from a checkout of that commit. The
runs of 2026-10-17 took this path. Besides
[What you need](#what-you-need), it needs:

- read access to the repository `hirunefu/smock`, and the GitHub CLI,
  gh, logged in (`gh auth login`): it clones the repository and
  downloads CI's binary;
- docker with BuildKit, which Docker 23 or later uses by default;
- without Owner on the project, Artifact Registry Administrator, to
  create a repository and grant access to it.

The guide then changes in four places:

1. In place of [Choose a release](#choose-a-release), get CI's binary
   and check out its commit, as below. Make `defs` at the top of the
   checkout (`mkdir defs`). On Linux x86_64 with glibc 2.34 or later and
   OpenSSL 3, `"$dir/smock" check defs` checks it; on any other machine,
   the image does, once it is built.
2. After [Create an Autopilot cluster](#create-an-autopilot-cluster),
   build the image and push it to Artifact Registry.
3. In [Install smock](#install-smock), install the chart from the
   checkout. In the later steps, `charts/smock` takes the place of
   `oci://ghcr.io/hirunefu/charts/smock --version "$VERSION"`.
4. After [Clean up](#clean-up), delete the repository in Artifact
   Registry too.

### Get CI's binary

smock is built for Linux only. CI builds a release binary for
linux/amd64 and for linux/arm64 on every push, and keeps each for seven
days after the run. GKE Autopilot runs x86 (amd64) nodes by default, so
take the amd64 binary from the latest successful run on `main`, and
check out the commit it was built from, so that the chart matches the
binary:

```sh
gh repo clone hirunefu/smock
cd smock
run=$(gh run list -R hirunefu/smock --workflow CI --branch main --event push --status success \
  --limit 1 --json databaseId --jq '.[0].databaseId')
commit=$(gh run view "$run" -R hirunefu/smock --json headSha --jq .headSha)
git switch --detach "$commit"     # HEAD is now at <commit> <subject>
dir=$(mktemp -d)
gh run download "$run" -R hirunefu/smock -n smock-linux-amd64 --dir "$dir"   # writes $dir/smock
file "$dir/smock"                 # ELF 64-bit LSB pie executable, x86-64, ...
```

If `gh run download` finds no artifact, see
[Troubleshooting an unreleased commit](#troubleshooting-an-unreleased-commit).

On a Linux x86_64 machine, the binary can also be built from source. It
needs OpenSSL 3 (`libssl-dev`), python3, git and a C compiler, and
`scripts/install-moonbit.sh` installs the pinned MoonBit toolchain into
`~/.moon`, replacing any toolchain there:

```sh
scripts/install-moonbit.sh
export PATH="$HOME/.moon/bin:$PATH"
moon update
scripts/build-release.sh          # writes dist/smock
```

Then `dist/smock check defs` checks the directory, and the image step
below skips its `cp` line. macOS cannot build the Linux binary.

For [Arm nodes](#arm-nodes), download `smock-linux-arm64` in place of
`smock-linux-amd64`, and build the image with `--platform linux/arm64`.
Without the compute class, a Pod of that image runs on an x86 node,
restarts, and its log says `exec /usr/local/bin/smock: exec format error`.

### Build the image and push it to Artifact Registry

The Dockerfile copies `dist/smock`, LICENSE and NOTICE onto a distroless
base and runs nothing, so any machine builds the amd64 image without
emulation, an Arm Mac included. The image's name says where it goes in
Artifact Registry: `<location>-docker.pkg.dev/<project ID>/<repository>/smock`.
The tag is the commit, so that it names the build, and `IMAGE` names
this image in the later steps:

```sh
mkdir -p dist
cp "$dir/smock" dist/smock
export REPO=smock TAG=$(git rev-parse --short=12 HEAD)
export IMAGE=$LOCATION-docker.pkg.dev/$PROJECT/$REPO/smock:$TAG
docker build --platform linux/amd64 --provenance=false --tag "$IMAGE" .
docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}} {{.Config.User}}'   # linux/amd64 65532:65532
docker run --rm -v "$PWD/defs:/defs:ro" "$IMAGE" check /defs   # prints nothing and exits with status 0
```

docker runs the amd64 image natively on an x86 machine, and Docker
Desktop runs it under emulation on an Arm Mac.

Enable Artifact Registry in the project, make a Docker repository, let
docker log in to it through gcloud, and push the image. Then let the
nodes' service account read the repository, which GKE's documentation
asks for (2026-10-13): without that grant, in a project where the
account has no roles, the nodes cannot pull the image.

```sh
gcloud services enable artifactregistry.googleapis.com --project="$PROJECT"
gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$LOCATION" --project="$PROJECT"
gcloud auth configure-docker "$LOCATION-docker.pkg.dev"
docker push "$IMAGE"
gcloud artifacts repositories add-iam-policy-binding "$REPO" --location="$LOCATION" --project="$PROJECT" \
  --member="serviceAccount:$N-compute@developer.gserviceaccount.com" --role=roles/artifactregistry.reader
```

The project is billed for the stored image too, until the repository
is deleted.

### Install the chart from the checkout

The install names the chart in the checkout and the image pushed above:

```sh
kubectl create namespace mocks
kubectl --namespace mocks create secret generic smock-admin-token \
  --from-literal=token="$(openssl rand -hex 32)"
helm upgrade --install smock charts/smock --namespace mocks \
  --set image.repository="$LOCATION-docker.pkg.dev/$PROJECT/$REPO/smock" --set image.tag="$TAG" \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.users\.yaml=defs/users.yaml' \
  --wait --timeout 10m
```

- `image.repository` and `image.tag` name the image pushed above.
  Without them, the chart asks for `ghcr.io/hirunefu/smock:0.0.0-dev`,
  which does not exist. The later upgrades keep them, with
  `--reuse-values`.
- helm prints the chart's notes, which name the chart's app version,
  `smock 0.0.0-dev` in a checkout. The Pod runs the image pushed above
  all the same.
- The Admin API's status names CI's build, with a `version` such as
  `0.0.0-ci.<n>` and the commit.

### Delete the repository

After [Clean up](#clean-up), delete the repository in Artifact Registry,
which ends its charges:

```sh
gcloud artifacts repositories delete "$REPO" --location="$LOCATION" --project="$PROJECT"
```

gcloud asks for confirmation. Deleting the repository also deletes its
grant. `rm -r "$dir"` removes CI's binary.

### Troubleshooting an unreleased commit

| Symptom | Cause and fix |
|---|---|
| `gh run download` says `no valid artifacts found to download` or `no artifact matches any of the names or patterns provided`. | CI keeps the binaries for seven days after the run, and only when the run's build passed. A collaborator with write access can run CI on `main` again within 30 days of the run (`gh run rerun <run-id> -R hirunefu/smock`). They can also start the release workflow by hand (`gh workflow run release.yml -R hirunefu/smock --ref main`): it publishes nothing, and keeps the artifact `build-linux-amd64`, which holds `smock-0.0.0-dev.<n>-linux-amd64`, for 90 days. Take it from that run with `--workflow release.yml --event workflow_dispatch` in the run lookup and `-n build-linux-amd64`, and copy the file to `dist/smock`. Otherwise build from source on Linux x86_64, as in [Get CI's binary](#get-cis-binary). |
| `docker build` says `unknown flag: --provenance` or `the --chmod option requires BuildKit`. | The legacy builder is in use. Use Docker 23 or later, or buildx, without `DOCKER_BUILDKIT=0`. |
| `docker run ... check /defs` says `exec format error`. | docker cannot run amd64 images on this Arm machine. On Linux arm64, download `smock-linux-arm64` into another directory the same way and run that binary's `check defs`. |
| `docker push` is denied. | Run `gcloud auth configure-docker "$LOCATION-docker.pkg.dev"`, and check that the account may write to the repository. |
| The Pod is in `ErrImagePull` or `ImagePullBackOff`. | `kubectl --namespace mocks describe pod` names the image and the error. When it says `failed to fetch oauth token` and `403 Forbidden` for an image in Artifact Registry, the node service account may not read the repository: make the grant in [Build the image and push it to Artifact Registry](#build-the-image-and-push-it-to-artifact-registry); the kubelet keeps retrying the pull. When it names `ghcr.io/hirunefu/smock:0.0.0-dev`, `image.repository` or `image.tag` is missing, and that image does not exist. |
| The Pod is in `CrashLoopBackOff`, and its log says `exec format error`. | The image holds a binary of another architecture than the node: `file dist/smock` must say x86-64 for x86 nodes, and ARM aarch64 for Arm nodes, which also need the compute class in [Arm nodes](#arm-nodes). |
