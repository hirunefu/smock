#!/bin/sh
# Installs the Helm chart (charts/smock) on a kind cluster and checks it
# there. CI runs it with the image it has just built. It:
#
# 1. creates a kind cluster and loads the image into it;
# 2. makes a namespace that enforces the Restricted Pod Security Standard
#    and also warns about it, and checks, with a server-side dry run that
#    fails on any warning, that Kubernetes' own Pod Security admission
#    accepts the Pods of every delivery mode (ConfigMap, git-sync and OCI
#    image), with each Admin API authentication and TLS option;
# 3. installs the chart with a ConfigMap of Definition files and an Admin API
#    token Secret, and waits until the Pod is ready;
# 4. checks that a request to a Stub gets its response;
# 5. updates the Definition files with `helm upgrade`, which changes only
#    the ConfigMap, and checks that the Pod serves the new definition set
#    without a restart: the definition set digest in the Admin API status
#    becomes the digest of the new files, the Stub answers with the new
#    response, and the Pod is the same one, with a restart count of 0.
#
# It deletes the cluster when it ends. It needs docker, kind, kubectl, helm,
# curl, jq and python3.
#
# usage: scripts/test-helm-chart-on-kind.sh <image>
# example: scripts/test-helm-chart-on-kind.sh smock:ci
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <image>" >&2
  exit 2
fi
image=$1
repository=${image%:*}
tag=${image##*:}

# The node image kind v0.33.0 was released with, by digest as kind asks.
node_image=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
cluster=smock-chart-$$
namespace=mocks
release=smock

tmp=$(mktemp -d)
pids=
cleanup() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

say() {
  echo "test-helm-chart-on-kind: $*"
}
fail() {
  echo "test-helm-chart-on-kind: $*" >&2
  echo "test-helm-chart-on-kind: the Pods and their logs:" >&2
  kubectl --namespace "$namespace" get pods -o wide >&2 || true
  kubectl --namespace "$namespace" describe pods >&2 || true
  kubectl --namespace "$namespace" logs --all-containers --prefix \
    --selector app.kubernetes.io/name=smock >&2 || true
  exit 1
}

kind create cluster --name "$cluster" --image "$node_image" --wait 120s
kind load docker-image "$image" --name "$cluster"

kubectl create namespace "$namespace"
kubectl label namespace "$namespace" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
kubectl --namespace "$namespace" create secret generic smock-admin-token \
  --from-literal=token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
kubectl --namespace "$namespace" get secret smock-admin-token -o jsonpath='{.data.token}' |
  base64 -d >"$tmp/token"
printf 'Authorization: Bearer %s\n' "$(cat "$tmp/token")" >"$tmp/admin-header"

# Kubernetes' own Pod Security admission, on every delivery mode. On a
# Deployment it only warns, which --warnings-as-errors makes fatal.
token="--set adminAuth.tokenSecret.name=smock-admin-token"
for mode in \
  "configmap|$token" \
  "configmap-env-tls|$token --set adminAuth.tokenAs=env --set tls.secretName=smock-tls" \
  "configmap-auth-off|--set adminAuth.enabled=false" \
  "git-sync|$token --set definitions.source=gitSync --set definitions.gitSync.repo=https://example.com/mocks.git --set tls.secretName=smock-tls" \
  "image|$token --set definitions.source=image --set definitions.image.reference=ghcr.io/hirunefu/mocks:v1 --set tls.secretName=smock-tls"; do
  name=${mode%%|*}
  flags=${mode#*|}
  # shellcheck disable=SC2086 # $flags is a list of flags
  helm template "$release" charts/smock --namespace "$namespace" $flags >"$tmp/$name.yaml"
  if ! kubectl --namespace "$namespace" apply --dry-run=server --warnings-as-errors \
    -f "$tmp/$name.yaml" >"$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    fail "Pod Security admission does not accept the $name Pods under the Restricted standard"
  fi
  say "Pod Security admission accepts the $name Pods under the Restricted standard"
done

# definitions <response body>: a Definition file with one Stub, GET /hello.
definitions() {
  printf '{"mocks":[{"name":"hello"}],"stubs":[{"id":"hello","mock":"hello","request":{"method":"GET","path":"/hello"},"response":{"status":200,"body":"%s"}}]}' "$1"
}
definitions "hello v1" >"$tmp/v1.json"
definitions "hello v2" >"$tmp/v2.json"

helm install "$release" charts/smock --namespace "$namespace" \
  --set image.repository="$repository" --set image.tag="$tag" --set image.pullPolicy=Never \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.hello\.json='"$tmp/v1.json" \
  --wait --timeout 5m || fail "the chart did not install"
kubectl --namespace "$namespace" rollout status deployment/"$release" --timeout 2m ||
  fail "the Pod did not become ready"
say "installed into a namespace that enforces the Restricted standard, and the Pod is ready"

# forward <service> <port>: forwards a free local port to the Service's
# port, and prints the local port.
forward() {
  kubectl --namespace "$namespace" port-forward "service/$1" ":$2" >"$tmp/forward-$1" 2>&1 &
  pids="$pids $!"
  for _ in $(seq 50); do
    local_port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$tmp/forward-$1")
    if [ -n "$local_port" ]; then
      echo "$local_port"
      return
    fi
    sleep 0.2
  done
  cat "$tmp/forward-$1" >&2
  fail "could not forward a port to service/$1"
}
plain_port=$(forward "$release" 80)
admin_port=$(forward "$release-admin" 9090)

hello() {
  curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:$plain_port/hello"
}
status() {
  curl --silent --show-error --fail --max-time 5 --header "@$tmp/admin-header" \
    "http://127.0.0.1:$admin_port/v1/status"
}

body=$(hello) || fail "no answer from the Stub"
[ "$body" = "hello v1" ] || fail "the Stub answered \"$body\", not \"hello v1\""
say "a request to a Stub gets its response"

pod=$(kubectl --namespace "$namespace" get pods --selector app.kubernetes.io/name=smock \
  -o jsonpath='{.items[0].metadata.name}')
uid=$(kubectl --namespace "$namespace" get pod "$pod" -o jsonpath='{.metadata.uid}')
generation=$(kubectl --namespace "$namespace" get deployment "$release" -o jsonpath='{.metadata.generation}')
before=$(status | jq -r .digest) || fail "no answer from the Admin API status operation"

# The digest smock reports for a definition set of one Definition file, as
# docs/definition-files.md defines it.
expected=$(python3 -c '
import hashlib, sys
name = sys.argv[1].encode()
content = open(sys.argv[2], "rb").read()
frame = b"D" + len(name).to_bytes(8, "big") + name + len(content).to_bytes(8, "big") + content
print(hashlib.sha256(frame).hexdigest()[:12])' hello.json "$tmp/v2.json")
[ "$before" != "$expected" ] || fail "the digests of the old and the new files are the same"

helm upgrade "$release" charts/smock --namespace "$namespace" --reuse-values \
  --set-file 'definitions.configMap.files.hello\.json='"$tmp/v2.json" ||
  fail "helm upgrade with new Definition files failed"
[ "$(kubectl --namespace "$namespace" get deployment "$release" -o jsonpath='{.metadata.generation}')" = "$generation" ] ||
  fail "new Definition files changed the Deployment, which rolls out new Pods"

# The kubelet refreshes ConfigMap volumes periodically: allow it 3 minutes.
digest=$before
for _ in $(seq 90); do
  digest=$(status | jq -r .digest) || fail "no answer from the Admin API status operation"
  [ "$digest" = "$before" ] || break
  sleep 2
done
[ "$digest" = "$expected" ] ||
  fail "after the ConfigMap update the replica serves the digest $digest, not $expected of the new files"
[ "$(status | jq -r .lastReload.result)" = swapped ] || fail "the last reload did not swap the new files in"
body=$(hello) || fail "no answer from the Stub after the update"
[ "$body" = "hello v2" ] || fail "after the update the Stub answered \"$body\", not \"hello v2\""

[ "$(kubectl --namespace "$namespace" get pods --selector app.kubernetes.io/name=smock \
  -o jsonpath='{.items[*].metadata.uid}')" = "$uid" ] || fail "the Pod was replaced"
restarts=$(kubectl --namespace "$namespace" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
[ "$restarts" = 0 ] || fail "smock restarted $restarts times"
say "after a ConfigMap update the same Pod serves the new definition set ($before -> $digest) with 0 restarts"

say "passed"
