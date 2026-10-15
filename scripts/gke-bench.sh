#!/usr/bin/env bash
# Runs the release benchmark on GKE Autopilot, end to end, before an
# integration branch is merged into main (docs/merging-into-main.md):
#
# 1. checks, reading only: the tools, the project, the APIs it needs, the
#    CPU quota for the nodes of the run, and nothing left by an earlier run;
#    then prints how long the run takes and what it costs;
# 2. with --yes, builds two images on this machine (smock with the
#    benchmark's definitions, and the load generator) for the architecture
#    of the run (--arch, this machine's by default), with the release binary
#    it builds or is given: the images only copy files, so this machine
#    builds them for the other architecture too, with no emulation, from
#    binaries of that architecture (the one CI built for smock);
# 3. pushes them to a new Artifact Registry repository, makes a new
#    Autopilot cluster, both labelled purpose=smock-bench, and runs each
#    profile of the plan (bench/plan-autopilot.json by default): smock in a
#    Pod with the profile's limits as its requests behind a ClusterIP
#    Service, both named for the profile (smock-<profile>), the load
#    generator (bench/gke/generator.py) in a Job on another node in smock's
#    zone, both on nodes of the run's architecture and in GKE_BENCH_ZONE
#    when it is set, and both with a deadline that ends them within minutes
#    of the time limit at the latest, so that they stop being billed even if
#    nothing is left to delete the cluster; the next profile starts once
#    they are gone, also after a profile that the load generator stopped
#    early because smock's traffic ports did not answer, before the first
#    step or after a step that got no response;
# 4. writes the load generator's lines, the Pods' state, smock's log and
#    its Service with the Service's EndpointSlices under the results
#    directory, and summary.json, summary.md and conditions.json, which
#    bench/compare.py compares;
# 5. always deletes the cluster and the repository: when it ends, fails or
#    is interrupted, and from a watchdog in its own session when the time
#    limit (80 minutes by default) has passed, even if this script was
#    killed; then lists clusters, repositories, VM instances, disks,
#    addresses and forwarding rules, and fails if anything the run made is
#    left.
#
# It never makes a LoadBalancer, a static IP or a volume claim: the
# namespace's quota forbids them. kubectl authenticates with an access token
# from gcloud in a kubeconfig of its own (mode 600, deleted at the end), so
# gke-gcloud-auth-plugin is not needed, and ~/.kube/config is not touched.
#
# usage: scripts/gke-bench.sh [--dry-run | --yes] [options]
#
#   --dry-run        print every command a run would run; run only those that read
#   --yes            make the resources and run (after the checks and the estimate)
#   --enable-apis    enable the APIs the run needs (otherwise print the command and stop)
#   --plan FILE      the plan (default: bench/plan-autopilot.json)
#   --profiles A,B   only these profiles of the plan
#   --cases A,B      only these cases of the plan
#   --targets FILE   the targets to check, those of --arch (default: bench/targets.json)
#   --out DIR        where the results go (default: bench/results/gke-<date>-<time>)
#   --time-limit T   when the watchdog deletes the cluster, with its unit: 80m (default), 4800s; at most 240m
#   --arch ARCH      the nodes' architecture, amd64 or arm64 (default: this machine's)
#   --smock FILE     use this release binary, built from the commit checked out, instead of
#                    building one; needed for another architecture than this machine's:
#                    gh run download <run-id> -R hirunefu/smock -n smock-linux-<arch> gets the
#                    one CI built (CI's run on the push of that commit)
#   --oha FILE       use this oha (of the run's architecture) instead of the pinned one
#
# Environment:
#   GKE_BENCH_PROJECT       the Google Cloud project (required)
#   GKE_BENCH_REGION        the region, such as us-central1 or asia-northeast1 (required); an
#                           arm64 run needs one with Arm Pods (ARM_REGIONS below)
#   GKE_BENCH_ZONE          the zone smock and the load generator run in (default: the one
#                           Autopilot chooses for smock, which the load generator follows)
#   GKE_BENCH_NEEDED_CPUS   the vCPUs of quota the run needs (default: 32, four nodes of 8)
#   GKE_BENCH_NODE_SERVICE_ACCOUNT
#                           the service account the nodes run as, which may read the images
#                           (default: the project's Compute Engine default service account)
#   GCLOUD, KUBECTL, DOCKER, PYTHON
#                           the commands to use (default: gcloud, kubectl, docker, python3 on PATH)
#
# Exit status: 0 when every profile ran all of its steps and nothing is
# left, 1 otherwise, 2 for a wrong command line or environment.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/gke-bench.sh"
GKE_PY="$ROOT/bench/gke/gke.py"

GCLOUD=${GCLOUD:-gcloud}
KUBECTL=${KUBECTL:-kubectl}
DOCKER=${DOCKER:-docker}
PYTHON=${PYTHON:-python3}
# Turns gcloud's JSON listing of repositories into one line each:
# repository, its name and its location.
REPOSITORY_LINES='
import json, sys
for repository in json.loads(sys.stdin.read() or "[]"):
    parts = repository["name"].split("/")
    print("repository", parts[-1], parts[3] if len(parts) == 6 else "", sep="\t")
'
# Prints how many times smock's Pod (the second argument) restarted, from
# what gke.py pod-info kept of the Pods (the first); fails when that is not
# known.
SMOCK_RESTARTS='
import json, sys
print(next(pod["restarts"] for pod in json.load(open(sys.argv[1]))["smock"] if pod["name"] == sys.argv[2]))
'
# Prints the profiles of summary.json (the argument) that are not complete,
# space-separated.
INCOMPLETE_PROFILES='
import json, sys
print(*(name for name, profile in json.load(open(sys.argv[1]))["gke"]["profiles"].items() if not profile["complete"]))
'
PROJECT=${GKE_BENCH_PROJECT:-}
REGION=${GKE_BENCH_REGION:-}
ZONE=${GKE_BENCH_ZONE:-}
NEEDED_CPUS=${GKE_BENCH_NEEDED_CPUS:-32}
POLL_S=${GKE_BENCH_POLL_S:-10}

NAMESPACE=smock-bench
APIS=(artifactregistry.googleapis.com compute.googleapis.com container.googleapis.com)
# The regions where Autopilot runs Arm Pods (the built-in autopilot-arm
# compute class), as GKE's documentation listed them on 2026-10-14. x86
# Pods run in every region.
ARM_REGIONS=" us-central1 us-east1 us-west1 europe-west1 europe-west2 europe-west4 asia-southeast1 "
# The Dockerfiles of the two images, from the repository's root.
DOCKERFILES=(Dockerfile bench/gke/smock-definitions.dockerfile bench/gke/generator.Dockerfile)
# How long the load generator's Pod may wait for a node, smock to become
# ready, and an access token may be used before a new one is fetched.
PENDING_LIMIT_S=900
READY_LIMIT_S=900
TOKEN_REFRESH_S=2700
# How long deleting the cluster may take before the script gives up on it.
DELETE_LIMIT_S=1800
# The longest time limit: a full run takes under an hour, and a limit far
# beyond it, such as 4800 taken as minutes, would keep a stuck run billed.
MAX_TIME_LIMIT_S=14400

dry_run=0 yes=0 enable_apis=0
plan="$ROOT/bench/plan-autopilot.json" targets="$ROOT/bench/targets.json"
profiles="" cases="" out="" time_limit=80m smock_binary="" oha_binary="" arch="" smock_sha256=""
project_number="" account_pattern="" problems=() apis_to_enable=()
work="" resources_may_exist=0 watchdog_pid="" built_images=() log_pid="" token_at=0

say() {
  printf 'gke-bench: %s\n' "$*" >&2
}

die() {
  say "$*"
  exit 1
}

usage() {
  sed -n '/^# usage:/,/^# Exit status/p' "$SCRIPT" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# A command as people read it: quoted for the shell, with the project and
# its number as the variables that hold them.
# shellcheck disable=SC2016 # The variables' names, unexpanded.
shown() {
  local arg text="" plain='^[A-Za-z0-9_@%+=:,./-]+$'
  for arg in "$@"; do
    if [[ $arg =~ $plain ]]; then
      text+=" $arg"
    else
      text+=" '${arg//\'/\'\\\'\'}'"
    fi
  done
  text=${text# }
  if [ -n "$PROJECT" ]; then
    text=${text//"$PROJECT"/'"$GKE_BENCH_PROJECT"'}
  fi
  if [ -n "$project_number" ]; then
    text=${text//"$project_number"/'"$PROJECT_NUMBER"'}
  fi
  printf '%s' "$text"
}

# Copies its input with the project and its number replaced by the
# variables that hold them, and gcloud's account by <account>, as gcloud and
# kubectl name them in their messages.
masked() {
  local rules=(-e "s/$PROJECT/\$GKE_BENCH_PROJECT/g")
  [ -z "$project_number" ] || rules+=(-e "s/$project_number/\$PROJECT_NUMBER/g")
  [ -z "$account_pattern" ] || rules+=(-e "s/$account_pattern/<account>/g")
  sed -u "${rules[@]}"
}

# Learns the account gcloud uses, for masked: Kubernetes names it when it
# forbids something, and gcloud in some of its errors.
learn_account() {
  local account
  account=$("$GCLOUD" config get-value account 2>/dev/null) || account=""
  account_pattern=$(printf '%s' "$account" | sed 's/[][\.*^$/]/\\&/g')
}

# Whether process $1 is still a run of this script (its watchdog when $2 is
# --watchdog): a process that has ended may have left its number to another.
is_this_script() {
  local args
  if [ -r "/proc/$1/cmdline" ]; then
    args=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)
  else
    args=$(ps -o args= -p "$1" 2>/dev/null)
  fi
  [[ $args == *gke-bench.sh* && $args == *"${2:-}"* ]]
}

# Runs a command that changes something, in the background so that a signal
# is handled at once, with what it prints masked; in a dry run, prints it
# instead.
changes() {
  if [ "$dry_run" = 1 ]; then
    say "would run: $(shown "$@")"
    return 0
  fi
  say "+ $(shown "$@")"
  "$@" > >(masked) 2> >(masked >&2) &
  wait $!
}

# Runs a command that only reads, also in a dry run, where it says so. Its
# output is the script's to read; its messages are masked.
reads() {
  if [ "$dry_run" = 1 ]; then
    say "reads: $(shown "$@")"
  fi
  "$@" 2> >(masked >&2)
}

pause() {
  sleep "$POLL_S" &
  wait $!
}

now() {
  date +%s
}

problem() {
  problems+=("$*")
}

# --- The watchdog --------------------------------------------------------

# Deletes the cluster, waiting while it is being made or deleted, until it
# is gone or DELETE_LIMIT_S has passed.
delete_cluster() {
  local listing status deadline=$(($(now) + DELETE_LIMIT_S))
  if [ "$dry_run" = 1 ]; then
    changes "$GCLOUD" container clusters delete "$cluster" --region="$REGION" --project="$PROJECT" --quiet --async
    return 0
  fi
  while :; do
    # The region's clusters, by their whole names: a listing of every
    # location leaves out those of a zone that does not answer, and
    # succeeds.
    if ! listing=$(reads "$GCLOUD" container clusters list --project="$PROJECT" --region="$REGION" \
      --format='value(name,status)'); then
      say "cannot list the clusters; trying again"
    else
      status=$(awk -F '\t' -v name="$cluster" '$1 == name { print $2 }' <<<"$listing")
      if [ -z "$status" ]; then
        say "cluster $cluster: deleted"
        return 0
      elif [ "$status" != STOPPING ]; then
        changes "$GCLOUD" container clusters delete "$cluster" --region="$REGION" --project="$PROJECT" --quiet \
          --async || say "cluster $cluster ($status) could not be deleted yet; trying again"
      fi
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      say "cluster $cluster still exists after $((DELETE_LIMIT_S / 60)) minutes"
      return 1
    fi
    pause
  done
}

# Deletes the repository. Whether it is gone is read from describing it by
# name, which answers NOT_FOUND then: a listing would not do, since gcloud
# shows repositories there by their short names, and lists a location that
# fails with a server error as empty.
delete_repository() {
  local attempt answer
  if [ "$dry_run" = 1 ]; then
    changes "$GCLOUD" artifacts repositories delete "$repository" --location="$REGION" --project="$PROJECT" --quiet
    return 0
  fi
  for attempt in 1 2 3 4 5 6; do
    if answer=$("$GCLOUD" artifacts repositories describe "$repository" --location="$REGION" --project="$PROJECT" \
      --format='value(name)' 2>&1); then
      changes "$GCLOUD" artifacts repositories delete "$repository" --location="$REGION" --project="$PROJECT" \
        --quiet || say "repository $repository could not be deleted (attempt $attempt)"
    elif [[ $answer == *NOT_FOUND* ]]; then
      say "repository $repository: deleted"
      return 0
    else
      say "cannot read the repository $repository; trying again"
      masked <<<"$answer" >&2
    fi
    pause
  done
  return 1
}

# The watchdog's own process (scripts/gke-bench.sh --watchdog): in its own
# session, deaf to the terminal, it waits for the deadline, then stops the
# run and deletes the cluster and the repository, and, once the run has
# gone, its temporary directory with the kubeconfig. The run stops it when
# it has cleaned up, through the stop file.
watchdog() {
  trap '' INT HUP
  trap 'say "watchdog: stopped by the run"; exit 0' TERM
  local deadline=$GKE_BENCH_WATCHDOG_DEADLINE parent=$GKE_BENCH_WATCHDOG_PARENT stop=$GKE_BENCH_WATCHDOG_STOP
  cluster=$GKE_BENCH_CLUSTER repository=$GKE_BENCH_REPOSITORY
  say "watchdog: deletes the cluster $cluster and the repository $repository at" \
    "$(date -u -d "@$deadline" +%FT%TZ) unless the run has"
  while [ "$(now)" -lt "$deadline" ]; do
    if [ -e "$stop" ]; then
      say "watchdog: the run cleaned up; stopping"
      exit 0
    fi
    pause
  done
  if [ -e "$stop" ]; then
    exit 0
  fi
  say "watchdog: the time limit has passed; stopping the run and deleting what it made"
  learn_account
  if is_this_script "$parent"; then
    kill -TERM "$parent" 2>/dev/null
  fi
  delete_cluster
  delete_repository
  if ! is_this_script "$parent" && [[ $GKE_BENCH_WORK == */smock-gke-bench.* ]]; then
    rm -rf "$GKE_BENCH_WORK"
  fi
  say "watchdog: done"
}

if [ "${1:-}" = --watchdog ]; then
  watchdog
  exit 0
fi

# --- The command line and the environment --------------------------------

option_value() {
  [ $# -ge 2 ] || {
    say "$1 needs a value"
    usage
  }
}

while [ $# -gt 0 ]; do
  case $1 in
  --dry-run) dry_run=1 ;;
  --yes) yes=1 ;;
  --enable-apis) enable_apis=1 ;;
  --plan | --profiles | --cases | --targets | --out | --time-limit | --arch | --smock | --oha)
    option_value "$@"
    case $1 in
    --arch) arch=$2 ;;
    --plan) plan=$2 ;;
    --profiles) profiles=$2 ;;
    --cases) cases=$2 ;;
    --targets) targets=$2 ;;
    --out) out=$2 ;;
    --time-limit) time_limit=$2 ;;
    --smock) smock_binary=$2 ;;
    --oha) oha_binary=$2 ;;
    esac
    shift
    ;;
  -h | --help) usage ;;
  *)
    say "unknown argument: $1"
    usage
    ;;
  esac
  shift
done

if [ -z "$PROJECT" ] || [ -z "$REGION" ]; then
  say "set GKE_BENCH_PROJECT (the Google Cloud project) and GKE_BENCH_REGION (such as us-central1)"
  exit 2
fi
if ! [[ $PROJECT =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || ! [[ $REGION =~ ^[a-z]+-[a-z]+[0-9]+$ ]] ||
  { [ -n "$ZONE" ] && ! [[ $ZONE =~ ^$REGION-[a-z]$ ]]; }; then
  say "GKE_BENCH_PROJECT, GKE_BENCH_REGION or GKE_BENCH_ZONE is not a project ID, a region and a zone in it"
  exit 2
fi
if ! [[ $time_limit =~ ^0*([1-9][0-9]{0,5})(m|s)$ ]]; then
  say "--time-limit takes minutes or seconds with their unit, such as 80m or 4800s"
  exit 2
fi
time_limit_s=${BASH_REMATCH[1]}
[ "${BASH_REMATCH[2]}" = s ] || time_limit_s=$((time_limit_s * 60))
if [ "$time_limit_s" -gt "$MAX_TIME_LIMIT_S" ]; then
  say "--time-limit is at most $((MAX_TIME_LIMIT_S / 60))m: a full run takes under an hour"
  exit 2
fi
if ! [[ $NEEDED_CPUS =~ ^[1-9][0-9]{0,3}$ ]]; then
  say "GKE_BENCH_NEEDED_CPUS is a number of vCPUs, such as 32"
  exit 2
fi
case $(uname -m) in
aarch64 | arm64) host_arch=arm64 ;;
x86_64 | amd64) host_arch=amd64 ;;
*) host_arch="" ;;
esac
arch=${arch:-$host_arch}
case $arch in
amd64 | arm64) ;;
"")
  say "this machine ($(uname -m)) is neither amd64 nor arm64: give --arch"
  exit 2
  ;;
*)
  say "--arch is amd64 or arm64, not $arch"
  exit 2
  ;;
esac
if [ "$arch" != "$host_arch" ] && [ -z "$smock_binary" ]; then
  say "this machine ($(uname -m)) cannot build smock for $arch: give --smock with the release binary that CI" \
    "built for linux/$arch from the commit to measure (CI's run on its push), such as:" \
    "gh run download <run-id> -R hirunefu/smock -n smock-linux-$arch"
  exit 2
fi
for file in "$plan" "$targets" ${smock_binary:+"$smock_binary"} ${oha_binary:+"$oha_binary"}; do
  [ -f "$file" ] || {
    say "no file $file"
    exit 2
  }
done
plan=$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")
targets=$(cd "$(dirname "$targets")" && pwd)/$(basename "$targets")

run_id=$(date -u +%Y%m%d-%H%M%S)
cluster=smock-bench-$run_id
repository=smock-bench-$run_id
labels="purpose=smock-bench,run=$run_id"
registry=$REGION-docker.pkg.dev
out=${out:-$ROOT/bench/results/gke-$run_id}
selection=(${profiles:+--profiles "$profiles"} ${cases:+--cases "$cases"})

work=$(mktemp -d "${TMPDIR:-/tmp}/smock-gke-bench.XXXXXX") || die "cannot make a temporary directory"
kubeconfig=$work/kubeconfig
# gcloud writes the new cluster's credentials here, not into ~/.kube/config.
export KUBECONFIG=$work/gcloud-kubeconfig

# --- Cleaning up -----------------------------------------------------------

# shellcheck disable=SC2329 # Called by on_exit.
stop_children() {
  local pid
  for pid in $(jobs -p); do
    if [ "$pid" != "$watchdog_pid" ]; then
      kill "$pid" 2>/dev/null
    fi
  done
}

# Lists everything billable in the project that a run could leave, one line
# each: what it is, its name and where.
take_inventory() {
  local file=$1 status=0
  : >"$file"
  reads "$GCLOUD" container clusters list --project="$PROJECT" --format='value(name,location)' |
    sed 's/^/cluster\t/' >>"$file" || status=1
  # As JSON, whose names are whole (projects/<p>/locations/<l>/repositories/<r>),
  # and failed when gcloud warns that a location could not be listed: it
  # then lists that location as empty.
  reads "$GCLOUD" artifacts repositories list --project="$PROJECT" --format=json 2>"$file.err" |
    "$PYTHON" -c "$REPOSITORY_LINES" >>"$file" || status=1
  if grep -q 'Failed to list' "$file.err"; then
    status=1
  fi
  cat "$file.err" >&2
  rm -f "$file.err"
  reads "$GCLOUD" compute instances list --project="$PROJECT" --format='value(name,zone.basename())' |
    sed 's/^/instance\t/' >>"$file" || status=1
  reads "$GCLOUD" compute disks list --project="$PROJECT" --format='value(name,zone.basename())' |
    sed 's/^/disk\t/' >>"$file" || status=1
  reads "$GCLOUD" compute addresses list --project="$PROJECT" --format='value(name,region.basename())' |
    sed 's/^/address\t/' >>"$file" || status=1
  reads "$GCLOUD" compute forwarding-rules list --project="$PROJECT" --format='value(name,region.basename())' |
    sed 's/^/forwarding rule\t/' >>"$file" || status=1
  sed -i '/^[^\t]*\t*$/d' "$file"
  sort -o "$file" "$file"
  return "$status"
}

# Checks that the project has nothing billable the run did not find there
# before it: no cluster, repository, VM instance, disk, address or
# forwarding rule. The cluster's nodes may take a little longer to go.
# shellcheck disable=SC2329,SC2016 # Called by on_exit; prints the variable's name.
verify_nothing_left() {
  local attempt left
  for attempt in 1 2 3 4 5 6; do
    if take_inventory "$work/inventory-after"; then
      left=$(comm -13 "$work/inventory-before" "$work/inventory-after")
      if [ -z "$left" ]; then
        say "nothing is left: the project has the clusters, repositories, VM instances, disks, addresses and" \
          "forwarding rules it had before the run ($(wc -l <"$work/inventory-after") of them)"
        return 0
      fi
    else
      left="(the listing failed)"
    fi
    [ "$attempt" = 6 ] || pause
  done
  say "LEFT AFTER THE RUN, still billed until deleted:"
  printf '  %s\n' "$left" | tr '\t' ' ' >&2
  say "delete them, such as with: gcloud container clusters delete $cluster --region=$REGION" \
    '--project="$GKE_BENCH_PROJECT"; gcloud artifacts repositories delete' \
    "$repository --location=$REGION"' --project="$GKE_BENCH_PROJECT"'
  return 1
}

# shellcheck disable=SC2329 # Called by on_exit.
stop_watchdog() {
  if [ -n "$watchdog_pid" ]; then
    : >"$out/.watchdog-stop"
    if is_this_script "$watchdog_pid" --watchdog; then
      kill "$watchdog_pid" 2>/dev/null
    fi
    watchdog_pid=""
  fi
}

# shellcheck disable=SC2329 # The EXIT trap.
on_exit() {
  local status=$? image
  trap '' INT TERM HUP
  trap - EXIT
  stop_children
  if [ "$resources_may_exist" = 1 ]; then
    say "deleting the cluster and the repository"
    delete_cluster || status=1
    delete_repository || status=1
  fi
  for image in "${built_images[@]}"; do
    "$DOCKER" image rm "$image" >/dev/null 2>&1
  done
  if [ "$resources_may_exist" = 1 ] && [ ! -f "$work/inventory-before" ]; then
    say "would list the clusters, repositories, VM instances, disks, addresses and forwarding rules, and compare" \
      "them with what the project had before"
  elif [ "$resources_may_exist" = 1 ]; then
    if verify_nothing_left; then
      stop_watchdog
    else
      [ "$status" != 0 ] || status=1
      [ -z "$watchdog_pid" ] || say "the watchdog (process $watchdog_pid) tries again at the time limit"
    fi
  fi
  rm -rf "$work"
  exit "$status"
}

# shellcheck disable=SC2329 # The trap of INT, TERM and HUP.
on_signal() {
  if [ "$1" = HUP ]; then
    # The terminal has gone, and writing to it fails: what the clean-up
    # prints goes to a file instead, so that none of its commands stops
    # early for want of somewhere to write.
    if [ -d "$out" ]; then
      exec >>"$out/after-hangup.log" 2>&1
    else
      exec >/dev/null 2>&1
    fi
  fi
  say "stopped by SIG$1"
  exit "$2"
}

trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP

# --- Checks ----------------------------------------------------------------

check_quota() {
  local file=$1 metric=$2 label=$3 text
  if text=$("$PYTHON" - "$file" "$metric" "$label" "$NEEDED_CPUS" <<'EOF'
import json
import sys

path, metric, label, needed = sys.argv[1:5]
quotas = {quota["metric"]: quota for quota in json.load(open(path)).get("quotas", [])}
quota = quotas.get(metric)
if quota is None:
    print(f"{label}: the project has no such quota")
    sys.exit(1)
free = quota["limit"] - quota["usage"]
print(f"{label}: {free:g} of {quota['limit']:g} vCPUs free, the run needs {float(needed):g}")
sys.exit(0 if free >= float(needed) else 1)
EOF
  ); then
    say "$text"
  else
    problem "$text: ask for more on the console's Quotas page (IAM & Admin), or, to accept that the load" \
      "generator's node may wait for Autopilot to remove its first node, set GKE_BENCH_NEEDED_CPUS lower"
  fi
}

# The checks that need the Compute Engine API: the zone, the CPU quota,
# and what the project has before the run.
check_project() {
  local region line
  if [ -n "$ZONE" ]; then
    region=$(reads "$GCLOUD" compute zones describe "$ZONE" --project="$PROJECT" --format='value(region.basename())')
    [ "$region" = "$REGION" ] || problem "zone $ZONE is not a zone of $REGION: set GKE_BENCH_ZONE to one, or unset it"
  fi
  if reads "$GCLOUD" compute project-info describe --project="$PROJECT" --format=json >"$work/project-info.json"; then
    check_quota "$work/project-info.json" CPUS_ALL_REGIONS CPUS_ALL_REGIONS
  else
    problem "cannot read the project's CPU quota"
  fi
  if reads "$GCLOUD" compute regions describe "$REGION" --project="$PROJECT" --format=json >"$work/region.json"; then
    check_quota "$work/region.json" CPUS "CPUS in $REGION"
  else
    problem "cannot read the CPU quota of $REGION"
  fi
  if ! take_inventory "$work/inventory-before"; then
    problem "cannot list what the project has, which the end of the run compares with"
    return
  fi
  while IFS=$'\t' read -r kind name where; do
    case $kind/$name in
    cluster/smock-bench-* | repository/smock-bench-*)
      problem "$kind $name ($where) is left from an earlier run and is billed: delete it first" ;;
    esac
  done <"$work/inventory-before"
  line=$(grep -c . "$work/inventory-before")
  say "the project has $line clusters, repositories, VM instances, disks, addresses and forwarding rules before" \
    "the run"
}

# Why FILE, the binary NAME, cannot go into an image for the run's
# architecture; nothing when it can. Its ELF header says: it is not run.
binary_problem() {
  local name=$1 file=$2 found
  if ! found=$("$PYTHON" "$GKE_PY" elf-arch "$file" 2>&1); then
    printf '%s: %s; give one for linux/%s' "$name" "${found#gke: }" "$arch"
  elif [ "$found" != "$arch" ]; then
    printf '%s: %s is for %s, not for linux/%s, which the run is for' "$name" "$file" "$found" "$arch"
  fi
}

# Checks the binaries given for the images: that they are for the run's
# architecture, and that smock is built from the commit checked out: as it
# says (smock --version) when this machine can run it, else as its build
# information names it, read without running it. Of a smock this machine
# cannot run, it prints the SHA-256 too, which the conditions record.
check_binaries() {
  local text version commit head
  if [ -n "$smock_binary" ]; then
    text=$(binary_problem smock "$smock_binary")
    if [ -n "$text" ]; then
      problem "$text"
    elif ! head=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null); then
      problem "cannot read the commit checked out, which smock should be built from: is $ROOT a git checkout?"
    elif [ "$arch" != "$host_arch" ]; then
      if text=$("$PYTHON" "$GKE_PY" names-commit "$smock_binary" "$head" 2>&1); then
        say "smock: $smock_binary is for $arch, which this machine cannot run; its build information names" \
          "commit $head, which is checked out; its SHA-256 is $(sha256sum "$smock_binary" | cut -d ' ' -f 1)"
      else
        problem "smock: ${text#gke: }: take the release binary CI built for linux/$arch on the push of $head," \
          "or check out the commit it is built from"
      fi
    elif [ ! -x "$smock_binary" ]; then
      problem "smock: $smock_binary is not executable, so its commit cannot be checked: chmod +x it"
    elif ! version=$("$smock_binary" --version 2>&1); then
      problem "smock: \`$smock_binary --version\` failed: $version"
    else
      commit=$(sed -n 's/.*(commit \([0-9a-f]*\),.*/\1/p' <<<"$version")
      [ "$commit" = "$head" ] || problem "smock: $smock_binary is built from commit ${commit:-unknown}, not from" \
        "$head, which is checked out: build it from this commit, or check out the one it is built from"
    fi
  fi
  if [ -n "$oha_binary" ]; then
    text=$(binary_problem oha "$oha_binary")
    [ -z "$text" ] || problem "$text"
  fi
}

# Checks that the images only copy: an image for another architecture than
# this machine's cannot RUN anything here, with no emulation.
check_dockerfiles() {
  local found
  if ! found=$(cd "$ROOT" && "$PYTHON" "$GKE_PY" check-dockerfiles "${DOCKERFILES[@]}" 2>&1); then
    problem "this machine ($(uname -m)) cannot build images for $arch that run anything:" \
      "$(paste -sd ' ' <<<"${found//gke: /}")"
  fi
}

preflight() {
  local tool enabled api missing=() arm_regions=${ARM_REGIONS:1:-1}
  if [ "$arch" = arm64 ] && [[ $ARM_REGIONS != *" $REGION "* ]]; then
    say "warning: $REGION is not among the regions with Arm Pods (${arm_regions// /, } in GKE's documentation" \
      "of 2026-10-14), so its Pods may not start: run in one of them, or with --arch amd64"
  fi
  for tool in "$GCLOUD" "$KUBECTL" "$DOCKER" "$PYTHON" setsid; do
    command -v "$tool" >/dev/null 2>&1 || problem "$tool is not on PATH (GCLOUD, KUBECTL, DOCKER and PYTHON name others)"
  done
  [ ${#problems[@]} -eq 0 ] || return
  # On PATH is not enough: a mise shim with no version set for the
  # directory is on PATH and fails, which once stopped a run after its
  # cluster was made.
  "$KUBECTL" version --client >/dev/null 2>&1 ||
    problem "$KUBECTL does not run (\`$KUBECTL version --client\` failed); with mise, give" \
      "KUBECTL=\"\$(mise where kubectl@<version>)/bin/kubectl\""
  "$DOCKER" version >/dev/null 2>&1 || problem "$DOCKER does not reach its daemon (\`$DOCKER version\` failed)"
  if [ -z "$smock_binary" ] && ! command -v moon >/dev/null 2>&1; then
    problem "moon is not on PATH to build the release binary: install the pinned MoonBit, or give --smock"
  fi
  if [ -z "$oha_binary" ] && ! command -v curl >/dev/null 2>&1; then
    problem "curl is not on PATH to download oha: install it, or give --oha"
  fi
  check_binaries
  [ "$arch" = "$host_arch" ] || check_dockerfiles
  [ ${#problems[@]} -eq 0 ] || return
  learn_account
  if ! project_number=$(reads "$GCLOUD" projects describe "$PROJECT" --format='value(projectNumber)') ||
    [ -z "$project_number" ]; then
    problem "cannot read the project \$GKE_BENCH_PROJECT: log in with gcloud auth login, and check the project ID"
    return
  fi
  if ! enabled=$(reads "$GCLOUD" services list --enabled --project="$PROJECT" --format='value(config.name)'); then
    problem "cannot list the project's enabled APIs"
    return
  fi
  for api in "${APIS[@]}"; do
    grep -qx "$api" <<<"$enabled" || missing+=("$api")
  done
  if [ ${#missing[@]} -gt 0 ] && [ "$enable_apis" = 1 ]; then
    apis_to_enable=("${missing[@]}")
    say "not enabled, and enabled by the run (no charge): ${missing[*]}"
  elif [ ${#missing[@]} -gt 0 ]; then
    problem "the run needs these APIs, which are not enabled: ${missing[*]}. Enable them (no charge) with:" \
      "gcloud services enable ${missing[*]} --project=\"\$GKE_BENCH_PROJECT\", or run with --enable-apis"
  fi
  if [ ${#missing[@]} -eq 0 ]; then
    check_project
  else
    say "the zone, the CPU quota and what the project has are checked once the APIs are enabled"
  fi
}

# --- The run -----------------------------------------------------------------

build_images() {
  smock_image=smock-gke-bench/smock:$run_id
  generator_image=smock-gke-bench/generator:$run_id
  local text
  if [ -z "$smock_binary" ]; then
    changes "$ROOT/scripts/build-release.sh" || die "the release build failed"
    smock_binary=$ROOT/dist/smock
  fi
  if [ -z "$oha_binary" ]; then
    changes "$ROOT/scripts/install-oha.sh" "$work/bin" "$arch" || die "installing oha failed"
    oha_binary=$work/bin/oha
    if [ "$dry_run" = 0 ]; then
      text=$(binary_problem oha "$oha_binary")
      [ -z "$text" ] || die "$text"
    fi
  fi
  if [ "$dry_run" = 0 ]; then
    smock_sha256=$(sha256sum "$smock_binary" | cut -d ' ' -f 1)
    mkdir -p "$work/smock-image/dist" "$work/generator-image/bench/gke"
    cat "$ROOT/Dockerfile" "$ROOT/bench/gke/smock-definitions.dockerfile" >"$work/smock.Dockerfile"
    cp "$smock_binary" "$work/smock-image/dist/smock"
    cp -r "$ROOT/bench/definitions" "$work/smock-image/definitions"
    cp "$oha_binary" "$work/generator-image/oha"
    cp "$ROOT/bench/bench.py" "$ROOT/bench/requests.json" "$work/generator-image/bench/"
    cp "$plan" "$work/generator-image/bench/plan.json"
    cp "$ROOT/bench/gke/gke.py" "$ROOT/bench/gke/generator.py" "$work/generator-image/bench/gke/"
  fi
  [ "$dry_run" = 1 ] || built_images=("$smock_image" "$generator_image")
  [ "$dry_run" = 0 ] || say "would write $work/smock.Dockerfile: the repository's Dockerfile and" \
    "bench/gke/smock-definitions.dockerfile"
  changes "$DOCKER" build --platform="linux/$arch" --file="$work/smock.Dockerfile" --tag="$smock_image" \
    "$work/smock-image" || die "building smock's image failed"
  changes "$DOCKER" build --platform="linux/$arch" --file="$ROOT/bench/gke/generator.Dockerfile" \
    --tag="$generator_image" "$work/generator-image" || die "building the load generator's image failed"
}

start_watchdog() {
  local deadline=$(($(now) + time_limit_s)) tenths
  if [ "$dry_run" = 1 ]; then
    say "would start the watchdog, which deletes the cluster and the repository $cluster after" \
      "$((time_limit_s / 60)) minutes"
    return
  fi
  mkdir -p "$out" || die "cannot make the results directory $out"
  rm -f "$out/.watchdog-stop"
  GKE_BENCH_WATCHDOG_DEADLINE=$deadline GKE_BENCH_WATCHDOG_PARENT=$$ GKE_BENCH_WATCHDOG_STOP=$out/.watchdog-stop \
    GKE_BENCH_CLUSTER=$cluster GKE_BENCH_REPOSITORY=$repository GKE_BENCH_WORK=$work \
    setsid "$SCRIPT" --watchdog </dev/null >>"$out/watchdog.log" 2>&1 &
  watchdog_pid=$!
  # Nothing is made until the watchdog says that it is waiting.
  for ((tenths = 0; tenths < 100; tenths++)); do
    if grep -q 'watchdog: deletes' "$out/watchdog.log" 2>/dev/null; then
      say "the watchdog (process $watchdog_pid, log $out/watchdog.log) deletes the cluster and the repository at" \
        "$(date -u -d "@$deadline" +%FT%TZ) if they still exist"
      return
    fi
    sleep 0.1
  done
  die "the watchdog did not start (see $out/watchdog.log), so nothing was made"
}

push_image() {
  local image=$1 name=$2 remote=$registry/$PROJECT/$repository/$2:$run_id digest
  changes "$DOCKER" tag "$image" "$remote" || die "tagging $image failed"
  if [ "$dry_run" = 1 ]; then
    changes env DOCKER_CONFIG="$work/docker" "$DOCKER" push "$remote"
    printf '%s@sha256:<digest>' "${remote%:*}"
    return
  fi
  # Not through changes: its output, masked by another process, may still
  # be on its way to the file when docker has ended.
  say "+ $(shown env DOCKER_CONFIG="$work/docker" "$DOCKER" push "$remote")"
  env DOCKER_CONFIG="$work/docker" "$DOCKER" push "$remote" >"$work/push-$name.txt" 2> >(masked >&2) &
  wait $! || die "pushing $image failed"
  masked <"$work/push-$name.txt" >&2
  digest=$(grep -o 'digest: sha256:[0-9a-f]\{64\}' "$work/push-$name.txt" | head -n 1 | cut -d ' ' -f 2)
  [ -n "$digest" ] || die "docker push did not say the digest of $image"
  printf '%s@%s' "${remote%:*}" "$digest"
}

push_images() {
  local service_account=${GKE_BENCH_NODE_SERVICE_ACCOUNT:-$project_number-compute@developer.gserviceaccount.com}
  changes "$GCLOUD" artifacts repositories create "$repository" --repository-format=docker --location="$REGION" \
    --project="$PROJECT" --labels="$labels" --description="smock benchmark images; deleted by its run" ||
    die "making the repository failed"
  # The nodes pull the images as this account: it may read this repository
  # only, and the grant goes with the repository.
  changes "$GCLOUD" artifacts repositories add-iam-policy-binding "$repository" --location="$REGION" \
    --project="$PROJECT" --member="serviceAccount:$service_account" --role=roles/artifactregistry.reader ||
    die "letting the nodes read the repository failed"
  if [ "$dry_run" = 1 ]; then
    say "would run: $(shown "$GCLOUD" auth print-access-token) | $(shown env DOCKER_CONFIG="$work/docker" \
      "$DOCKER" login --username=oauth2accesstoken --password-stdin "https://$registry")"
  else
    say "+ $(shown "$GCLOUD" auth print-access-token) | $(shown env DOCKER_CONFIG="$work/docker" "$DOCKER" login \
      --username=oauth2accesstoken --password-stdin "https://$registry")"
    { "$GCLOUD" auth print-access-token 2> >(masked >&2) | env DOCKER_CONFIG="$work/docker" "$DOCKER" login \
      --username=oauth2accesstoken --password-stdin "https://$registry" >/dev/null; } &
    wait $! || die "logging in to $registry failed"
  fi
  [ "$dry_run" = 1 ] || built_images+=("$registry/$PROJECT/$repository/smock:$run_id"
    "$registry/$PROJECT/$repository/generator:$run_id")
  smock_ref=$(push_image "$smock_image" smock) || exit 1
  generator_ref=$(push_image "$generator_image" generator) || exit 1
}

# Writes the kubeconfig: the cluster's endpoint and CA, and an access token
# from gcloud, readable by this user only.
write_kubeconfig() {
  local token
  token=$("$GCLOUD" auth print-access-token 2> >(masked >&2)) || die "gcloud auth print-access-token failed"
  (
    umask 077
    cat >"$kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: smock-bench
  cluster:
    server: https://$endpoint
    certificate-authority-data: $ca
users:
- name: smock-bench
  user:
    token: $token
contexts:
- name: smock-bench
  context:
    cluster: smock-bench
    user: smock-bench
    namespace: $NAMESPACE
current-context: smock-bench
EOF
  )
  chmod 600 "$kubeconfig"
  token_at=$(now)
}

# Writes a new access token into the kubeconfig before the one in it
# expires (after an hour). Called in the script's own shell, not in a
# command substitution, so that it remembers when.
refresh_token() {
  if [ "$dry_run" = 0 ] && [ $(($(now) - token_at)) -ge "$TOKEN_REFRESH_S" ]; then
    write_kubeconfig
  fi
}

kube() {
  "$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" "$@" 2> >(masked >&2)
}

# A kubectl command that changes something or waits long: in the
# background, or printed in a dry run.
kube_run() {
  refresh_token
  changes "$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" "$@"
}

make_cluster() {
  local info service_account=()
  # The account the run let read the repository, when it is not the
  # default one.
  [ -z "${GKE_BENCH_NODE_SERVICE_ACCOUNT:-}" ] ||
    service_account=(--service-account="$GKE_BENCH_NODE_SERVICE_ACCOUNT")
  changes "$GCLOUD" container clusters create-auto "$cluster" --region="$REGION" --project="$PROJECT" \
    --release-channel=regular --labels="$labels" "${service_account[@]}" --quiet || die "making the cluster failed"
  if [ "$dry_run" = 1 ]; then
    say "would write a kubeconfig (mode 600) with the cluster's endpoint and an access token: $kubeconfig"
    cluster_version="<version>"
    return
  fi
  info=$(reads "$GCLOUD" container clusters describe "$cluster" --region="$REGION" --project="$PROJECT" \
    --format='value(endpoint,masterAuth.clusterCaCertificate,currentMasterVersion)') ||
    die "cannot read the cluster's endpoint"
  IFS=$'\t' read -r endpoint ca cluster_version <<<"$info"
  write_kubeconfig
}

wait_for_generator() {
  local job=$1 phase since
  since=$(now)
  while :; do
    refresh_token
    phase=$(kube get pods --selector=job-name="$job" --output='jsonpath={.items[*].status.phase}' 2>/dev/null)
    case $phase in
    *Running* | *Succeeded* | *Failed*) return 0 ;;
    esac
    if [ $(($(now) - since)) -ge "$PENDING_LIMIT_S" ]; then
      say "the load generator's Pod is ${phase:-not made} after $((PENDING_LIMIT_S / 60)) minutes; its events:"
      kube get events --field-selector=involvedObject.kind=Pod | masked >&2
      return 1
    fi
    pause
  done
}

wait_for_job() {
  local job=$1 limit_s=$2 state since
  since=$(now)
  while :; do
    refresh_token
    state=$(kube get job "$job" --output='jsonpath={range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)
    case $state in
    *Complete=True*) return 0 ;;
    *Failed=True*)
      say "the load generator's Job failed: $state"
      return 1
      ;;
    esac
    if [ $(($(now) - since)) -ge "$limit_s" ]; then
      say "the load generator's Job is not done after $((limit_s / 60)) minutes"
      return 1
    fi
    pause
  done
}

# Keeps what smock left under a profile while its Pod and Service are still
# there, masked: its log as smock.log (when it restarted, or that is not
# known, its container before the last restart first), and what its init
# container printed of the CPU of its node as smock-node-cpu.log, each with
# kubectl's errors in their place, and its Service with the Service's
# EndpointSlices as service.json.
keep_smock_state() {
  local smock_pod=$1 raw=$2 restarts
  # kubectl itself, not the function kube, so that its errors stay in order
  # with what it prints. smock's container by name: kubectl says on stderr
  # which one it chose for a Pod with an init container.
  local logs=("$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" logs --container=smock)
  if [ "$dry_run" = 1 ]; then
    say "would keep smock's log as $raw/smock.log, what its init container printed of the CPU of its node as" \
      "$raw/smock-node-cpu.log, and its Service and EndpointSlices as $raw/service.json"
    return 0
  fi
  mkdir -p "$raw"
  refresh_token
  restarts=$("$PYTHON" -c "$SMOCK_RESTARTS" "$raw/pods.json" "$smock_pod" 2>/dev/null) || restarts=unknown
  if [ "$restarts" = 0 ]; then
    "${logs[@]}" "pod/$smock_pod" 2>&1 | masked >"$raw/smock.log"
  else
    {
      printf '# kubectl logs --previous: the container before the last restart (restarts: %s)\n' "$restarts"
      "${logs[@]}" --previous "pod/$smock_pod"
      printf '# kubectl logs: the container at the end\n'
      "${logs[@]}" "pod/$smock_pod"
    } 2>&1 | masked >"$raw/smock.log"
  fi
  "$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" logs --container=node-cpu "pod/$smock_pod" 2>&1 |
    masked >"$raw/smock-node-cpu.log"
  kube get service,endpointslices --output=json | masked >"$raw/service.json" ||
    say "cannot read smock's Service and its EndpointSlices; $raw/service.json may be empty"
}

# Runs one profile: smock, then the load generator, then what they left,
# then deletes both. Fails when smock or the load generator could not start
# (which the next profile would hit too). Returns 3 when the profile ran
# but not all of its steps (its Job did not complete, or the load generator
# stopped it early), and 4 when the load generator's Job or smock's Pod and
# Service were not deleted, so that no later profile may run beside them.
run_profile() {
  local name=$1 deadline_s=$2 job=generator-$1 manifests=$work/manifests/$1 raw=$out/raw/$1 status=0 waited ended
  local left=""
  local smock_ref_shown=${smock_ref:-} generator_ref_shown=${generator_ref:-}
  # smock's Pod and Service, as gke.py names them: their own under each
  # profile, so that a lookup of the name cannot get the address of the
  # previous profile's Service.
  local smock_pod=smock-$1
  # smock's Pod ends by itself at the time limit, counted from when its
  # node accepts it.
  local smock_deadline_s=$((deadline - $(now)))
  say "profile $name: $3 steps; the load generator's Job may take $((deadline_s / 60)) minutes"
  "$PYTHON" "$GKE_PY" manifests --plan "$plan" --profile "$name" ${cases:+--cases "$cases"} --arch "$arch" \
    ${ZONE:+--zone "$ZONE"} --smock-image "$smock_ref_shown" --generator-image "$generator_ref_shown" \
    --smock-deadline-s "$smock_deadline_s" --out "$manifests" || die "rendering the manifests of $name failed"
  kube_run apply --filename="$manifests/namespace.json" || die "applying the namespace failed"
  kube_run apply --filename="$manifests/smock.json" || die "applying smock's Pod failed"
  kube_run wait --for=condition=Ready "pod/$smock_pod" --timeout="${READY_LIMIT_S}s" || {
    kube get events --field-selector=involvedObject.kind=Pod | masked >&2
    keep_smock_state "$smock_pod" "$raw"
    die "smock did not become ready under $name"
  }
  kube_run apply --filename="$manifests/generator.json" || die "applying the load generator's Job failed"
  if [ "$dry_run" = 1 ]; then
    say "would wait for the Job $job, keep its log as $raw/generator.log and its Pods as $raw/pods.json, then" \
      "delete it and smock"
  else
    mkdir -p "$raw"
    wait_for_generator "$job" || die "the load generator's Pod did not start under $name"
    # kubectl itself, not the function kube, so that log_pid is its own.
    "$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" logs --follow "job/$job" \
      >"$raw/generator-stream.log" 2>>"$work/kubectl.log" &
    log_pid=$!
    wait_for_job "$job" $((deadline_s + 120)) || status=3
    for waited in 1 2 3 4 5 6; do
      kill -0 "$log_pid" 2>/dev/null || break
      [ "$waited" = 6 ] || pause
    done
    kill "$log_pid" 2>/dev/null
    log_pid=""
    # The whole log, when the Pod is still there; else what was streamed.
    refresh_token
    if kube logs "job/$job" >"$raw/generator.log" 2>>"$work/kubectl.log" && [ -s "$raw/generator.log" ]; then
      rm -f "$raw/generator-stream.log"
    else
      mv "$raw/generator-stream.log" "$raw/generator.log"
    fi
    if kube get pods --output=json >"$work/pods.json" && kube get nodes --output=json >"$work/nodes.json"; then
      "$PYTHON" "$GKE_PY" pod-info "$work/pods.json" "$work/nodes.json" >"$raw/pods.json"
    fi
    ended=$("$PYTHON" "$GKE_PY" stopped "$raw/generator.log")
    if [ -n "$ended" ]; then
      say "profile $name ended early: $ended"
      status=3
    fi
  fi
  keep_smock_state "$smock_pod" "$raw"
  # The next profile starts once the load generator's Job and Pod, and
  # smock's Pod and Service, are gone.
  kube_run delete --filename="$manifests/generator.json" --ignore-not-found --cascade=foreground --wait=true \
    --timeout=300s || left="the load generator's Job"
  kube_run delete --filename="$manifests/smock.json" --ignore-not-found --wait=true --timeout=300s ||
    left="${left:+$left, and }smock's Pod and Service"
  if [ -n "$left" ]; then
    say "not deleted in 5 minutes under $name: $left; no later profile runs beside them"
    return 4
  fi
  return "$status"
}

# --- Main --------------------------------------------------------------------

if ! profile_lines=$("$PYTHON" "$GKE_PY" plan --plan "$plan" "${selection[@]}"); then
  exit 1
fi
say "run $run_id: project \$GKE_BENCH_PROJECT, $REGION, zone ${ZONE:-chosen by Autopilot}, $arch, plan" \
  "${plan#"$ROOT"/}"
preflight
"$PYTHON" "$GKE_PY" estimate --plan "$plan" "${selection[@]}" --region "$REGION" --arch "$arch" \
  --time-limit-s "$time_limit_s" \
  >&2 2>"$work/estimate.txt" || problem "$(sed 's/^gke: //' "$work/estimate.txt")"
if [ ${#problems[@]} -gt 0 ]; then
  say "the run cannot start:"
  printf '  - %s\n' "${problems[@]}" >&2
  if [ "$dry_run" = 0 ]; then
    exit 1
  fi
fi
if [ "$dry_run" = 0 ] && [ "$yes" = 0 ]; then
  say "Nothing was made. To make these and run the benchmark, run it again with --yes."
  exit 0
fi
[ "$dry_run" = 0 ] || say "dry run: what a run would do from here on"

if [ ${#apis_to_enable[@]} -gt 0 ]; then
  changes "$GCLOUD" services enable "${apis_to_enable[@]}" --project="$PROJECT" || die "enabling the APIs failed"
  if [ "$dry_run" = 0 ]; then
    check_project
    if [ ${#problems[@]} -gt 0 ]; then
      printf '  - %s\n' "${problems[@]}" >&2
      die "the run cannot start"
    fi
  fi
fi

build_images
started_at=$(date -u +%FT%TZ)
deadline=$(($(now) + time_limit_s))
resources_may_exist=1
start_watchdog
push_images
make_cluster

run_status=0
while read -r name steps deadline_s <&3; do
  # Each profile needs its Job's time, smock's start, and the deletion.
  if [ $(($(now) + deadline_s + 600)) -gt "$deadline" ]; then
    say "profile $name and those after it do not fit in the time limit; skipping them"
    run_status=1
    break
  fi
  run_profile "$name" "$deadline_s" "$steps"
  case $? in
  0) ;;
  3) run_status=1 ;;
  4)
    run_status=1
    break
    ;;
  *) exit 1 ;;
  esac
done 3<<<"$profile_lines"
finished_at=$(date -u +%FT%TZ)

if [ "$dry_run" = 1 ]; then
  say "would write summary.json, summary.md and conditions.json into $out"
else
  "$PYTHON" "$GKE_PY" summarize --plan "$plan" --targets "$targets" "${selection[@]}" --region "$REGION" \
    ${ZONE:+--zone "$ZONE"} --arch "$arch" --started-at "$started_at" --finished-at "$finished_at" \
    --cluster-version "$cluster_version" --smock-image "${smock_ref##*@}" --generator-image "${generator_ref##*@}" \
    --smock-sha256 "$smock_sha256" "$out" || run_status=1
  # Whatever the Jobs said: a log that lost lines leaves steps unmeasured.
  if ! incomplete=$("$PYTHON" -c "$INCOMPLETE_PROFILES" "$out/summary.json" 2>/dev/null); then
    run_status=1
  elif [ -n "$incomplete" ]; then
    say "not every step was measured under: $incomplete (summary.md says why)"
    run_status=1
  fi
  say "results: $out (summary.md, summary.json, conditions.json, raw/)"
  say "compare them with the previous pre-merge run's: python3 bench/compare.py <previous> $out"
fi
if [ ${#problems[@]} -gt 0 ]; then
  run_status=1
fi
exit "$run_status"
