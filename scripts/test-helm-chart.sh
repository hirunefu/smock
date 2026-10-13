#!/bin/sh
# Rendering tests of the Helm chart (charts/smock). Each test renders the
# chart with `helm template` for some values and checks the manifests with a
# jq filter, or checks that rendering fails with a clear message. Together
# they cover every delivery mode of the Definition files and the Admin API
# authentication and TLS options. scripts/test-helm-chart-on-kind.sh installs
# the chart on a real cluster.
#
# It needs helm (v3.8 or later, or v4), yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-helm-chart.sh
#
# shellcheck disable=SC2016 # jq filters and Markdown are in single quotes on purpose
set -eu
cd "$(dirname "$0")/.."

chart=charts/smock
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# Every value the tests do not set is the chart's default, except the Admin
# API token Secret, which smock needs while authentication is on: most
# tests add these values.
cat >"$tmp/values-token.yaml" <<'YAML'
adminAuth:
  tokenSecret:
    name: smock-admin-token
YAML

# render <name> [helm template flags...]: renders the chart, as release
# "smock" in namespace "mocks", into $tmp/<name>.json, an array of every
# manifest.
render() {
  name=$1
  shift
  if helm template smock "$chart" --namespace mocks "$@" >"$tmp/$name.yaml" 2>"$tmp/$name.err"; then
    yq --output-format=json eval-all '[.] | map(select(. != null))' "$tmp/$name.yaml" >"$tmp/$name.json"
  else
    fail "$name: rendering failed: $(cat "$tmp/$name.err")"
    echo '[]' >"$tmp/$name.json"
  fi
}

# Functions the filters of `check` can use, on the array of manifests.
defs='
def kind($k): .[] | select(.kind == $k);
def deployment: kind("Deployment");
def pod: deployment | .spec.template.spec;
def containers: pod | (.initContainers // []) + .containers | .[];
def container($n): containers | select(.name == $n);
def smock: container("smock");
def env($n): [smock | .env[]? | select(.name == $n)] | first;
def envs: [smock | .env[]? | .name];
def volume($n): pod | .volumes[] | select(.name == $n);
def mount($c; $n): [container($c) | .volumeMounts[]? | select(.name == $n)] | first;
def configmaps: [kind("ConfigMap")];
def service($n): kind("Service") | select(.metadata.name == $n);

# Why the Pod does not meet the Restricted Pod Security Standard (and the
# Baseline rules it includes) as far as the chart can break them, or why a
# container lacks a numeric non-root UID or a read-only root filesystem.
# scripts/test-helm-chart-on-kind.sh checks the same Pods with Kubernetes
# own Pod Security admission.
def restricted_violations:
  pod as $p | ($p.securityContext // {}) as $ps
  | ["configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "image",
     "persistentVolumeClaim", "projected", "secret"] as $allowed
  | def effective($s; $field): if $s | has($field) then $s[$field] else $ps[$field] end;
  [ (if $p.hostNetwork or $p.hostPID or $p.hostIPC then "the Pod shares a host namespace" else empty end),
    (if $ps.sysctls then "the Pod sets sysctls" else empty end),
    ($p.volumes[]? | select((keys - ["name"] - $allowed) != [])
      | "volume \(.name) is of a type the Restricted standard forbids"),
    (($p.initContainers // []) + $p.containers | .[] | .name as $c | (.securityContext // {}) as $s
      | (if $s.privileged == true then "\($c) is privileged" else empty end),
        (if $s.allowPrivilegeEscalation != false then "\($c) allows privilege escalation" else empty end),
        (if ($s.capabilities.drop // []) | index("ALL") | not then "\($c) keeps capabilities" else empty end),
        (if ($s.capabilities.add // []) != [] then "\($c) adds capabilities" else empty end),
        (if $s.readOnlyRootFilesystem != true then "\($c) has a writable root filesystem" else empty end),
        (if effective($s; "runAsNonRoot") != true then "\($c) may run as root" else empty end),
        (effective($s; "runAsUser") as $u
          | if ($u | type) != "number" or $u == 0 then "\($c) has no numeric non-root UID" else empty end),
        (if effective($s; "seccompProfile").type != "RuntimeDefault"
          then "\($c) does not use the runtime default seccomp profile" else empty end),
        (if ($s.procMount // "Default") != "Default" then "\($c) unmasks /proc" else empty end),
        (.ports[]? | select(.hostPort) | "\($c) uses a host port"))
  ];
'

# check <name> <description> <jq filter>: the filter, run on the manifests
# rendered as <name>, must give true.
check() {
  if jq -e "$defs $3" "$tmp/$1.json" >/dev/null 2>"$tmp/jq.err"; then
    pass "$1: $2"
  else
    fail "$1: $2"
    echo "     filter: $3"
    if [ -s "$tmp/jq.err" ]; then
      sed 's/^/     /' "$tmp/jq.err"
    fi
  fi
}

# restricted <name>: the Pod rendered as <name> and each of its containers
# meet the Restricted Pod Security Standard.
restricted() {
  violations=$(jq -c "$defs restricted_violations" "$tmp/$1.json" 2>&1) || true
  if [ "$violations" = "[]" ]; then
    pass "$1: the Pod and every container meet the Restricted Pod Security Standard"
  else
    fail "$1: the Pod or a container does not meet the Restricted Pod Security Standard: $violations"
  fi
}

# refuse <name> <description> <message> [helm template flags...]: rendering
# must fail, and its error must contain <message>.
refuse() {
  name=$1 description=$2 message=$3
  shift 3
  if helm template smock "$chart" --namespace mocks "$@" >/dev/null 2>"$tmp/$name.err"; then
    fail "$name: $description: rendering should fail"
  elif grep -qF -- "$message" "$tmp/$name.err"; then
    pass "$name: $description"
  else
    fail "$name: $description: the error does not say \"$message\": $(cat "$tmp/$name.err")"
  fi
}

# --- Default delivery: a ConfigMap ------------------------------------------

cat >"$tmp/values-files.yaml" <<'YAML'
definitions:
  configMap:
    files:
      users.json: '{"mocks":[{"name":"users"}]}'
      orders.yaml: 'mocks: [{name: orders}]'
YAML
render configmap --values "$tmp/values-token.yaml" --values "$tmp/values-files.yaml"
check configmap "the chart makes a ConfigMap of the Definition files" \
  'configmaps | length == 1 and .[0].metadata.name == "smock-definitions"
   and .[0].data == {"users.json": "{\"mocks\":[{\"name\":\"users\"}]}", "orders.yaml": "mocks: [{name: orders}]"}'
check configmap "the ConfigMap is mounted as a whole volume, without items" \
  'volume("definitions").configMap == {"name": "smock-definitions"}'
check configmap "it is mounted read-only at the definitions directory, without subPath" \
  'mount("smock"; "definitions") == {"name": "definitions", "mountPath": "/definitions", "readOnly": true}
   and env("SMOCK_DIR").value == "/definitions"'

# An update of the Definition files changes the ConfigMap but not the
# Deployment, so no Pod restarts: smock reloads the swapped files.
cat >"$tmp/values-files-updated.yaml" <<'YAML'
definitions:
  configMap:
    files:
      users.json: '{"mocks":[{"name":"users","hosts":["users.example.com"]}]}'
YAML
render configmap-updated --values "$tmp/values-token.yaml" --values "$tmp/values-files-updated.yaml"
if [ "$(jq -S '[.[] | select(.kind == "Deployment")]' "$tmp/configmap.json")" = \
  "$(jq -S '[.[] | select(.kind == "Deployment")]' "$tmp/configmap-updated.json")" ]; then
  pass "configmap-updated: new Definition files leave the Deployment as it was, so no Pod restarts"
else
  fail "configmap-updated: new Definition files change the Deployment, which restarts the Pods"
fi

render existing-configmap --values "$tmp/values-token.yaml" --set definitions.configMap.name=team-definitions
check existing-configmap "an existing ConfigMap is mounted, and the chart makes none" \
  'configmaps == [] and volume("definitions").configMap == {"name": "team-definitions"}'
refuse existing-configmap-and-files "Definition files in the values and an existing ConfigMap" \
  "definitions.configMap.name names an existing ConfigMap, so definitions.configMap.files and definitions.configMap.bodyFiles must be empty" \
  --values "$tmp/values-token.yaml" --values "$tmp/values-files.yaml" --set definitions.configMap.name=team-definitions

# --- Body files in the same ConfigMap ---------------------------------------

# The files the definitions volume of <name> shows, as {path: content}: each
# item of the volume puts a key of the chart's ConfigMap at its path.
layout='([volume("definitions").configMap.items[] as $i
          | {key: $i.path, value: (configmaps[0].data[$i.key])}] | from_entries)'

cat >"$tmp/values-body-files.yaml" <<'YAML'
definitions:
  configMap:
    files:
      users.json: '{"stubs":[]}'
    bodyFiles:
      users/1.json: '{"id":1}'
      README.txt: 'not a Definition file'
YAML
render body-files --values "$tmp/values-token.yaml" --values "$tmp/values-body-files.yaml"
check body-files "body files appear under the body-file subdirectory, Definition files at the top" \
  "$layout"' == {"users.json": "{\"stubs\":[]}", "files/users/1.json": "{\"id\":1}", "files/README.txt": "not a Definition file"}'
check body-files "smock reads body files from that subdirectory" \
  'env("SMOCK_BODY_FILE_DIR").value == "files"'
check body-files "the volume is still mounted whole, without subPath" \
  'mount("smock"; "definitions") == {"name": "definitions", "mountPath": "/definitions", "readOnly": true}'

render body-file-dir --values "$tmp/values-token.yaml" --values "$tmp/values-body-files.yaml" --set definitions.bodyFileDir=bodies
check body-file-dir "the body-file subdirectory follows definitions.bodyFileDir" \
  "$layout"' == {"users.json": "{\"stubs\":[]}", "bodies/users/1.json": "{\"id\":1}", "bodies/README.txt": "not a Definition file"}
   and env("SMOCK_BODY_FILE_DIR").value == "bodies"'

for path in ../escape.json /etc/passwd users/../../x .hidden/1.json users/.1.json users//1.json; do
  printf 'definitions:\n  configMap:\n    bodyFiles:\n      "%s": x\n' "$path" >"$tmp/values-bad.yaml"
  refuse body-file-path "a body file path $path that leaves the subdirectory or that smock skips" \
    "definitions.configMap.bodyFiles: \"$path\" is not a relative path" \
    --values "$tmp/values-token.yaml" --values "$tmp/values-bad.yaml"
done
for name in notes.txt .hidden.json sub/users.json; do
  printf 'definitions:\n  configMap:\n    files:\n      "%s": x\n' "$name" >"$tmp/values-bad.yaml"
  refuse definition-file-name "a Definition file named $name, which smock would not read" \
    "definitions.configMap.files: \"$name\" is not the name of a Definition file" \
    --values "$tmp/values-token.yaml" --values "$tmp/values-bad.yaml"
done

cat >"$tmp/values-items.yaml" <<'YAML'
definitions:
  configMap:
    name: team-definitions
    items:
      - key: users.json
        path: users.json
      - key: users-1
        path: files/users/1.json
YAML
render existing-configmap-items --values "$tmp/values-token.yaml" --values "$tmp/values-items.yaml"
check existing-configmap-items "the items of an existing ConfigMap place its body files" \
  'volume("definitions").configMap == {"name": "team-definitions",
     "items": [{"key": "users.json", "path": "users.json"}, {"key": "users-1", "path": "files/users/1.json"}]}'

# --- git-sync alternative -----------------------------------------------------

cat >"$tmp/values-git-sync.yaml" <<'YAML'
definitions:
  source: gitSync
  gitSync:
    repo: https://example.com/team/mocks.git
    ref: main
    path: mocks/dev
YAML
render git-sync --values "$tmp/values-token.yaml" --values "$tmp/values-git-sync.yaml"
check git-sync "no ConfigMap: the Definition files come from the Git repository" \
  'configmaps == [] and volume("definitions") == {"name": "definitions", "emptyDir": {}}'
check git-sync "a sidecar keeps the repository synced into the shared volume" \
  '[pod | .containers[] | .name] == ["smock", "git-sync"]
   and mount("git-sync"; "definitions") == {"name": "definitions", "mountPath": "/git"}
   and (container("git-sync") | .args | index("--repo=https://example.com/team/mocks.git") and index("--ref=main")
     and index("--root=/git") and index("--link=current") and index("--period=10s") and (index("--one-time") | not))'
check git-sync "an init container syncs once before smock starts, so smock never starts without its files" \
  '[pod | .initContainers[] | .name] == ["git-sync-init"]
   and mount("git-sync-init"; "definitions") == {"name": "definitions", "mountPath": "/git"}
   and (container("git-sync-init") | .args | index("--repo=https://example.com/team/mocks.git") and index("--one-time"))'
check git-sync "smock reads its definitions directory from the synced tree, read-only" \
  'mount("smock"; "definitions") == {"name": "definitions", "mountPath": "/git", "readOnly": true}
   and env("SMOCK_DIR").value == "/git/current/mocks/dev"'
check git-sync "git-sync writes its home in a volume of its own, since its root filesystem is read-only" \
  'mount("git-sync"; "git-sync-home") == {"name": "git-sync-home", "mountPath": "/tmp"}
   and mount("git-sync-init"; "git-sync-home") == {"name": "git-sync-home", "mountPath": "/tmp"}
   and volume("git-sync-home") == {"name": "git-sync-home", "emptyDir": {}}'

render git-sync-root --values "$tmp/values-token.yaml" --set definitions.source=gitSync --set definitions.gitSync.repo=https://example.com/m.git
check git-sync-root "without a path, the Definition files are at the top of the repository" \
  'env("SMOCK_DIR").value == "/git/current"'
refuse git-sync-no-repo "git-sync without a repository" \
  "definitions.gitSync.repo is empty, but definitions.source is gitSync" \
  --values "$tmp/values-token.yaml" --set definitions.source=gitSync
refuse unknown-source "a delivery mode the chart does not know" \
  'definitions.source must be "configMap", "gitSync" or "image", not "s3"' \
  --values "$tmp/values-token.yaml" --set definitions.source=s3

# --- OCI image volume alternative ---------------------------------------------

render image --values "$tmp/values-token.yaml" --set definitions.source=image \
  --set definitions.image.reference=ghcr.io/team/mocks:v1 --set definitions.image.path=mocks/dev
check image "no ConfigMap: the Definition files come from an image mounted as a volume" \
  'configmaps == []
   and volume("definitions") == {"name": "definitions", "image": {"reference": "ghcr.io/team/mocks:v1", "pullPolicy": "IfNotPresent"}}'
check image "smock reads its definitions directory from the image, read-only" \
  'mount("smock"; "definitions") == {"name": "definitions", "mountPath": "/definitions", "readOnly": true}
   and env("SMOCK_DIR").value == "/definitions/mocks/dev"'

render image-v2 --values "$tmp/values-token.yaml" --set definitions.source=image \
  --set definitions.image.reference=ghcr.io/team/mocks:v2 --set definitions.image.path=mocks/dev
if [ "$(jq -S '[.[] | select(.kind == "Deployment") | .spec.template]' "$tmp/image.json")" != \
  "$(jq -S '[.[] | select(.kind == "Deployment") | .spec.template]' "$tmp/image-v2.json")" ]; then
  pass "image-v2: a new image reference changes the Pod template, which rolls out new Pods"
else
  fail "image-v2: a new image reference leaves the Pod template as it was, so no new Pod gets it"
fi
refuse image-no-reference "an image volume without a reference" \
  "definitions.image.reference is empty, but definitions.source is image" \
  --values "$tmp/values-token.yaml" --set definitions.source=image

# --- Admin API token ----------------------------------------------------------

refuse no-token "authentication on and no token Secret, which smock would refuse to start with" \
  "adminAuth.tokenSecret.name is empty, but Admin API authentication is on (adminAuth.enabled)"

render token-file --set adminAuth.tokenSecret.name=smock-admin-token
check token-file "authentication stays on" 'env("SMOCK_ADMIN_AUTH").value == "on"'
check token-file "the token Secret is mounted read-only as a file" \
  'volume("admin-token").secret.secretName == "smock-admin-token"
   and mount("smock"; "admin-token") == {"name": "admin-token", "mountPath": "/etc/smock/admin", "readOnly": true}'
check token-file "smock reads the token from that file, not from a variable" \
  'env("SMOCK_ADMIN_TOKEN_FILE").value == "/etc/smock/admin/token" and env("SMOCK_ADMIN_TOKEN") == null'

render token-key --set adminAuth.tokenSecret.name=smock-admin-token --set adminAuth.tokenSecret.key=admin
check token-key "the file is the Secret's key adminAuth.tokenSecret.key" \
  'env("SMOCK_ADMIN_TOKEN_FILE").value == "/etc/smock/admin/admin"'

render token-env --set adminAuth.tokenSecret.name=smock-admin-token --set adminAuth.tokenAs=env
check token-env "the token can come from the Secret as the variable SMOCK_ADMIN_TOKEN" \
  'env("SMOCK_ADMIN_TOKEN").valueFrom == {"secretKeyRef": {"name": "smock-admin-token", "key": "token"}}
   and env("SMOCK_ADMIN_TOKEN_FILE") == null
   and ([pod | .volumes[] | select(.name == "admin-token")] == [])'
refuse token-as "the token passed in a way smock does not read" \
  'adminAuth.tokenAs must be "file" or "env", not "header"' \
  --set adminAuth.tokenSecret.name=smock-admin-token --set adminAuth.tokenAs=header

render auth-off --set adminAuth.enabled=false
check auth-off "a value turns authentication off through smock's setting, and no token is needed" \
  'env("SMOCK_ADMIN_AUTH").value == "off"
   and env("SMOCK_ADMIN_TOKEN") == null and env("SMOCK_ADMIN_TOKEN_FILE") == null
   and ([pod | .volumes[] | select(.name == "admin-token")] == [])'

# --- TLS ------------------------------------------------------------------------

render no-tls --values "$tmp/values-token.yaml"
check no-tls "without a TLS Secret, smock gets no certificate files and generates its own" \
  'env("SMOCK_TLS_CERT_FILE") == null and env("SMOCK_TLS_KEY_FILE") == null
   and ([pod | .volumes[] | select(.name == "tls")] == [])'

render tls --values "$tmp/values-token.yaml" --set tls.secretName=smock-tls
check tls "the TLS Secret is mounted read-only as a whole volume, so renewals reach smock" \
  'volume("tls").secret.secretName == "smock-tls"
   and mount("smock"; "tls") == {"name": "tls", "mountPath": "/etc/smock/tls", "readOnly": true}'
check tls "smock's certificate settings name the Secret's tls.crt and tls.key" \
  'env("SMOCK_TLS_CERT_FILE").value == "/etc/smock/tls/tls.crt"
   and env("SMOCK_TLS_KEY_FILE").value == "/etc/smock/tls/tls.key"'

# --- Ports, Services and probes ---------------------------------------------

render ports --values "$tmp/values-token.yaml"
check ports "the plain, TLS and admin ports are container ports" \
  '[smock | .ports[] | {name, containerPort, protocol}] == [
     {"name": "plain", "containerPort": 8080, "protocol": "TCP"},
     {"name": "tls", "containerPort": 8443, "protocol": "TCP"},
     {"name": "admin", "containerPort": 9090, "protocol": "TCP"}]'
check ports "smock listens on those ports" \
  'env("SMOCK_PORT").value == "8080" and env("SMOCK_TLS_PORT").value == "8443"
   and env("SMOCK_ADMIN_PORT").value == "9090"'
check ports "the traffic Service has the plain and TLS ports and not the admin port" \
  '[service("smock") | .spec.ports[] | {name, port, targetPort}] == [
     {"name": "http", "port": 80, "targetPort": "plain"},
     {"name": "https", "port": 443, "targetPort": "tls"}]'
check ports "the admin port has a Service of its own" \
  '[service("smock-admin") | .spec.ports[] | {name, port, targetPort}] == [
     {"name": "admin", "port": 9090, "targetPort": "admin"}]'
check ports "both Services select the Pods, and only them" \
  '([deployment | .spec.template.metadata.labels] | first) as $labels
   | [kind("Service") | .spec.selector | to_entries | all(.[]; $labels[.key] == .value)] == [true, true]
   and ([kind("Service") | .spec.selector] | unique) == [deployment | .spec.selector.matchLabels]'

render custom-ports --values "$tmp/values-token.yaml" --set ports.plain=8081 --set ports.tls=8444 --set ports.admin=9091 \
  --set service.plainPort=8080 --set service.tlsPort=8443 --set adminService.port=9999
check custom-ports "ports from the values reach smock, the Pod and the Services" \
  'env("SMOCK_PORT").value == "8081" and env("SMOCK_TLS_PORT").value == "8444"
   and env("SMOCK_ADMIN_PORT").value == "9091"
   and [smock | .ports[] | .containerPort] == [8081, 8444, 9091]
   and [service("smock") | .spec.ports[] | .port] == [8080, 8443]
   and [service("smock-admin") | .spec.ports[] | .port] == [9999]'

check ports "the probes call /startupz, /readyz and /livez on the admin port, without a token" \
  '[smock | .startupProbe, .readinessProbe, .livenessProbe | .httpGet] == [
     {"path": "/startupz", "port": "admin"},
     {"path": "/readyz", "port": "admin"},
     {"path": "/livez", "port": "admin"}]'

# --- Replicas, CPU, drain and other settings --------------------------------

render defaults --values "$tmp/values-token.yaml"
check defaults "one replica by default" 'deployment | .spec.replicas == 1'
check defaults "the Pod requests about one CPU core, and no CPU limit above it" \
  'smock | .resources.requests.cpu == "1" and ((.resources.limits.cpu // "1") | tostring | IN("1", "1000m"))'
check defaults "smock is told the replica count, for the Admin API replica warning" \
  'env("SMOCK_REPLICAS").value == "1"'
check defaults "smock drains for 20 s, and Kubernetes waits longer before it kills the Pod" \
  'env("SMOCK_DRAIN_TIMEOUT_MS").value == "20000" and pod.terminationGracePeriodSeconds == 30'
check defaults "no Service-link variables reach the environment, where smock reads its settings" \
  'pod.enableServiceLinks == false'

render replicas --values "$tmp/values-token.yaml" --set replicas=3
check replicas "the replicas value sets the Deployment and smock's replica count" \
  'deployment.spec.replicas == 3 and env("SMOCK_REPLICAS").value == "3"'

render drain --values "$tmp/values-token.yaml" --set drainTimeoutMs=45500
check drain "a longer drain timeout reaches smock and lengthens the grace period" \
  'env("SMOCK_DRAIN_TIMEOUT_MS").value == "45500" and pod.terminationGracePeriodSeconds == 56'
printf 'drainTimeoutMs: 1200000\n' >"$tmp/values-drain.yaml"
render drain-long --values "$tmp/values-token.yaml" --values "$tmp/values-drain.yaml"
check drain-long "a drain timeout from a values file is written out in full" \
  'env("SMOCK_DRAIN_TIMEOUT_MS").value == "1200000" and pod.terminationGracePeriodSeconds == 1210'
render grace --values "$tmp/values-token.yaml" --set terminationGracePeriodSeconds=90
check grace "a grace period above the drain timeout is kept" 'pod.terminationGracePeriodSeconds == 90'
for seconds in 20 5; do
  refuse grace-too-short "a grace period of ${seconds} s, not above the drain timeout of 20 s" \
    "terminationGracePeriodSeconds ($seconds) must be above the drain timeout, drainTimeoutMs (20000 ms)" \
    --values "$tmp/values-token.yaml" --set terminationGracePeriodSeconds="$seconds"
done

cat >"$tmp/values-env.yaml" <<'YAML'
env:
  SMOCK_IDLE_TIMEOUT_MS: "120000"
  SMOCK_SEED: 9007199254740991
  SMOCK_BODY_LIMIT: 10485760
YAML
render env --values "$tmp/values-token.yaml" --values "$tmp/values-env.yaml"
check env "other smock settings are set as SMOCK_<NAME> variables, numbers written out in full" \
  'env("SMOCK_IDLE_TIMEOUT_MS").value == "120000" and env("SMOCK_SEED").value == "9007199254740991"
   and env("SMOCK_BODY_LIMIT").value == "10485760"'
check env "each variable is set once" 'envs | length == (unique | length)'
refuse env-name "a variable that is not a smock setting" \
  'env: "HTTP_PROXY" is not a smock setting: its name must be SMOCK_ and the setting' \
  --values "$tmp/values-token.yaml" --set env.HTTP_PROXY=x
# Every variable the Deployment sets in any of the chart's own modes (the
# token as a file or as a variable, with and without TLS) is refused in
# env, so the list _validate.tpl refuses cannot fall behind the Deployment.
own=$(for name in token-file token-env tls; do
  jq -r "$defs envs | .[]" "$tmp/$name.json"
done | sort -u)
if [ -n "$own" ]; then
  pass "env-chart: the Deployment sets variables of its own: $(printf "%s" "$own" | tr "\n" " ")"
else
  fail "env-chart: no variables found in the Deployment"
fi
for name in $own; do
  refuse env-chart "$name, which the chart sets from its own values" \
    "env: the chart sets $name itself" \
    --values "$tmp/values-token.yaml" --set "env.$name=1"
done

cat >"$tmp/values-pod.yaml" <<'YAML'
image:
  repository: registry.example.com/smock
  tag: "1.0.0"
  pullPolicy: Always
imagePullSecrets:
  - name: registry
podAnnotations:
  prometheus.io/scrape: "true"
nodeSelector:
  pool: mocks
tolerations:
  - key: mocks
    operator: Exists
    effect: NoSchedule
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: smock
YAML
render pod --values "$tmp/values-token.yaml" --values "$tmp/values-pod.yaml"
check pod "the image, pull Secrets, annotations and scheduling come from the values" \
  'smock.image == "registry.example.com/smock:1.0.0" and smock.imagePullPolicy == "Always"
   and pod.imagePullSecrets == [{"name": "registry"}]
   and (deployment | .spec.template.metadata.annotations) == {"prometheus.io/scrape": "true"}
   and pod.nodeSelector == {"pool": "mocks"}
   and pod.tolerations == [{"key": "mocks", "operator": "Exists", "effect": "NoSchedule"}]
   and pod.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight == 1'

# --- The released chart -------------------------------------------------------

# The release workflow packages the chart with the release's version, so the
# chart's app version and default image tag match the release.
if scripts/package-helm-chart.sh 1.2.3-rc.1 "$tmp/package" >"$tmp/package.log" 2>&1; then
  chart=$tmp/package/smock-1.2.3-rc.1.tgz
  render released --values "$tmp/values-token.yaml"
  chart=charts/smock
  check released "the packaged chart has the release's version and app version" \
    '(deployment | .metadata.labels) as $l
     | $l["helm.sh/chart"] == "smock-1.2.3-rc.1" and $l["app.kubernetes.io/version"] == "1.2.3-rc.1"'
  check released "its default image is the release's image" \
    'smock.image == "ghcr.io/hirunefu/smock:1.2.3-rc.1"'
  if helm show readme "$tmp/package/smock-1.2.3-rc.1.tgz" | grep -q '^| `replicas` |'; then
    pass "released: the packaged chart carries its README with the values"
  else
    fail "released: the packaged chart has no README listing the values"
  fi
else
  fail "released: scripts/package-helm-chart.sh failed: $(cat "$tmp/package.log")"
fi

# --- The chart's README lists every value with its default ----------------

# A row of the values table is "| `<path>` | `<default as JSON>` | ... |".
# Every value needs a row of its own or of an object that holds it, and
# every row names a value with that default.
yq --output-format=json charts/smock/values.yaml >"$tmp/values.json"
sed -n 's/^| `\([^`]*\)` | `\([^`]*\)` |.*/\1\t\2/p' charts/smock/README.md >"$tmp/readme-rows" 2>/dev/null || true
jq -r 'paths(if type == "object" or type == "array" then length == 0 else true end) | map(tostring) | join(".")' \
  "$tmp/values.json" >"$tmp/value-paths"
missing=
while read -r path; do
  found=
  prefix=$path
  while :; do
    if cut -f1 "$tmp/readme-rows" | grep -qxF "$prefix"; then
      found=1
      break
    fi
    case $prefix in
    *.*) prefix=${prefix%.*} ;;
    *) break ;;
    esac
  done
  [ -n "$found" ] || missing="$missing $path"
done <"$tmp/value-paths"
if [ -z "$missing" ]; then
  pass "readme: every value has a row in the README's values table"
else
  fail "readme: values without a row in charts/smock/README.md:$missing"
fi
wrong=
while IFS="$(printf '\t')" read -r path documented; do
  actual=$(jq -c --arg path "$path" 'getpath($path | split("."))' "$tmp/values.json")
  if ! jq -e --arg path "$path" '[paths] | any(. == ($path | split(".")))' "$tmp/values.json" >/dev/null; then
    wrong="$wrong $path (no such value)"
  elif [ "$(printf '%s' "$documented" | jq -c . 2>/dev/null)" != "$actual" ]; then
    wrong="$wrong $path (README: $documented, values.yaml: $actual)"
  fi
done <"$tmp/readme-rows"
if [ -z "$wrong" ]; then
  pass "readme: every row of the values table gives the value's default"
else
  fail "readme: rows of charts/smock/README.md that do not match values.yaml:$wrong"
fi

# --- Restricted Pod Security Standard ---------------------------------------

# Every delivery mode, with each authentication and TLS option.
render git-sync-tls --values "$tmp/values-token.yaml" --values "$tmp/values-git-sync.yaml" --set tls.secretName=smock-tls
render git-sync-env --values "$tmp/values-git-sync.yaml" \
  --set adminAuth.tokenSecret.name=smock-admin-token --set adminAuth.tokenAs=env
render git-sync-off --values "$tmp/values-git-sync.yaml" --set adminAuth.enabled=false
render image-tls --set definitions.source=image --set definitions.image.reference=ghcr.io/team/mocks:v1 \
  --set adminAuth.tokenSecret.name=smock-admin-token --set adminAuth.tokenAs=env --set tls.secretName=smock-tls
render image-off --set definitions.source=image --set definitions.image.reference=ghcr.io/team/mocks:v1 \
  --set adminAuth.enabled=false
for name in configmap body-files existing-configmap-items token-file token-env auth-off tls pod \
  git-sync git-sync-tls git-sync-env git-sync-off image image-tls image-off; do
  restricted "$name"
done

# The check itself finds a container that breaks the standard.
jq 'map(if .kind == "Deployment" then del(.spec.template.spec.containers[0].securityContext) else . end)' \
  "$tmp/configmap.json" >"$tmp/broken.json"
if [ "$(jq -c "$defs restricted_violations | length > 0" "$tmp/broken.json")" = true ]; then
  pass "broken: the Restricted check finds a container without a security context"
else
  fail "broken: the Restricted check misses a container without a security context"
fi

echo
echo "test-helm-chart: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
