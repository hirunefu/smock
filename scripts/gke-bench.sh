#!/usr/bin/env bash
# Runs the release benchmark on GKE Autopilot, end to end, before an
# integration branch is merged into main (docs/merging-into-main.md):
#
# 1. checks, reading only: the tools, the project, the APIs it needs, the
#    quotas of the region that the run's nodes draw on (vCPUs, boot disks,
#    external IP addresses), and nothing left by an earlier run; then prints
#    how long the run takes and what it costs;
# 2. with --yes, builds the images on this machine (smock with the
#    benchmark's definitions and their Scenario and CRUD variants, one for
#    each binary a run of variants compares, and the load generator) for the architecture of the run
#    (--arch, this machine's by default), with the release binary it builds
#    or is given: the images only copy files, so this machine builds them
#    for the other architecture too, with no emulation, from binaries of
#    that architecture (the one CI built for smock);
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
#    step or after a step that got no response; with --variant, each
#    variant's smock in a Pod and Service of its own under each profile
#    (smock-<profile>-<label>), each started once the one before is ready,
#    all on the first one's node, which the run checks before the load
#    generator starts, with the profile's limits, and one load generator
#    that measures each variant in turn, round after round (--rounds);
# 4. writes the load generator's lines, the Pods' state, smock's log and
#    its Service with the Service's EndpointSlices under the results
#    directory, and summary.json, summary.md and conditions.json, which
#    bench/compare.py compares: also when the run stops once a profile has
#    started, from what it measured, with where and why it stopped; with
#    --variant, each variant's log and Service under raw/<profile>/<label>/,
#    a summary of each sample (one variant's pass over the steps in one
#    round) under samples/<round>-<label>/, and the comparison of the
#    variants in same-node.json and same-node.md, also as summary.md;
# 5. always deletes the cluster and the repository: when it ends, fails or
#    is interrupted, and from a watchdog in its own session when the time
#    limit (80 minutes by default) has passed, even if this script was
#    killed; then lists clusters, repositories, VM instances, disks,
#    addresses and forwarding rules, and fails if anything the run made is
#    left.
#
# It never makes a LoadBalancer, a static IP or a volume claim: the
# namespace's quota forbids them. kubectl authenticates with a new access
# token from gcloud, taken again before its hour ends, in a kubeconfig of
# its own (mode 600, deleted at the end), so gke-gcloud-auth-plugin is not
# needed, and ~/.kube/config is not touched.
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
#   --variant LABEL=FILE[,no-init][,no-first-second][,scenarios][,crud]
#                    compare release binaries, or one binary with other options, on one node:
#                    2 to 4 variants, the first the baseline, each in a Pod of its own under
#                    each profile, which one load generator measures in turn; LABEL (1 to 16
#                    of a-z, 0-9 and -, from a letter) names its Pod and Service, FILE is its
#                    binary, built from any commit; no-init leaves out the init container
#                    that prints its node's CPU, no-first-second the load generator's scrape
#                    of its /metrics a second into each step, scenarios serves the
#                    Scenario variant of the definitions (bench/definitions-scenarios/) in
#                    place of bench/definitions/, and crud their CRUD variant
#                    (bench/definitions-crud/), which the load generator sends its own
#                    mix (bench/requests-crud.json); not with --smock
#   --rounds N       how many times the load generator measures each variant's steps, the
#                    variants' order turned each round and step (default: 4); only with --variant
#
# Environment:
#   GKE_BENCH_PROJECT       the Google Cloud project (required)
#   GKE_BENCH_REGION        the region, such as us-central1 or asia-northeast1 (required); an
#                           arm64 run needs one with Arm Pods (ARM_REGIONS below)
#   GKE_BENCH_ZONE          the zone smock and the load generator run in (default: the one
#                           Autopilot chooses for smock, which the load generator follows)
#   GKE_BENCH_NEEDED_CPUS   the vCPUs of quota the run needs (default: 32, four nodes of 8); the
#                           nodes' boot disks and external IP addresses it needs follow from it
#   GKE_BENCH_NODE_SERVICE_ACCOUNT
#                           the service account the nodes run as, which may read the images
#                           (default: the project's Compute Engine default service account)
#   GCLOUD, KUBECTL, DOCKER, PYTHON
#                           the commands to use (default: gcloud, kubectl, docker, python3 on PATH)
#
# Exit status: 0 when every profile ran all of its steps and nothing is
# left (and with --variant, when the variants can be compared), 1
# otherwise, 2 for a wrong command line or environment.
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
# known, as when it was kept before the profile's end.
SMOCK_RESTARTS='
import json, sys
restarts = next(pod["restarts"] for pod in json.load(open(sys.argv[1]))["smock"] if pod["name"] == sys.argv[2])
if restarts is None:
    sys.exit(1)
print(restarts)
'
# Prints the node of the Pod the second argument names, from what gke.py
# pod-info kept of the Pods (the first): nothing when it has none.
POD_NODE='
import json, sys
print(next((pod["node"] or "" for pod in json.load(open(sys.argv[1]))["smock"] if pod["name"] == sys.argv[2]), ""))
'
# Keeps of kubectl's listing of Services and EndpointSlices, on its standard
# input, those of the Service the argument names.
OWN_SERVICE='
import json, sys
listing = json.load(sys.stdin)
listing["items"] = [item for item in listing["items"] if sys.argv[1] in (
    item["metadata"]["name"], item["metadata"].get("labels", {}).get("kubernetes.io/service-name"))]
print(json.dumps(listing, indent=4))
'
# Prints why gcloud could not fetch the quotas of the region whose
# description it printed (the argument, as JSON); fails when it could.
QUOTA_WARNING='
import json, sys
warning = json.load(open(sys.argv[1])).get("quotaStatusWarning")
if not warning:
    sys.exit(1)
print(warning.get("message") or warning.get("code") or "gcloud says no more")
'
# Prints the profiles of summary.json, or of a run of variants'
# same-node.json (the argument), that are not complete, space-separated.
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
# What each node of the run takes of its region's quotas, by the metric of
# Compute Engine that counts it (as gcloud compute regions describe names
# them): 8 vCPUs, a boot disk of 100 GB (the probe's nodes had 94 GiB of
# ephemeral storage on it), and an ephemeral external IP address
# (IN_USE_ADDRESSES), since the nodes are not private. The run needs as
# many nodes as GKE_BENCH_NEEDED_CPUS makes nodes of 8 vCPUs, all of them
# in CPUS_ALL_REGIONS. The first SYSTEM_NODES of them are Autopilot's own,
# its first node and its system node, which are x86 (ek-standard-8) on
# either architecture, as in the arm64 probe of 2026-10-14; the others,
# smock's and the load generator's, are of the run's architecture
# (e4a-standard-8 on arm64). An x86 node draws on the region's CPUS. GKE
# boots a node from a balanced Persistent Disk (pd-balanced, in
# SSD_TOTAL_GB) unless its machine series has only Hyperdisk (GKE's
# documentation of custom boot disks, 2026-10-13): the arm64 probe's e4a
# nodes booted from hyperdisk-balanced (HDB_TOTAL_GB). No run had recorded
# an ek node's; pods.json now records each node's (boot_disk). An Arm
# node's vCPUs draw on a CPU quota of its machine family, which gcloud
# does not list (GKE's documentation of Arm workloads asks for quota of
# the C4A, N4A or T2A machine types), so it is not checked.
NODE_CPUS=8
NODE_BOOT_DISK_GB=100
SYSTEM_NODES=2
declare -A BOOT_DISK_QUOTAS=([amd64]=SSD_TOTAL_GB [arm64]=HDB_TOTAL_GB)
# The Dockerfiles of the images, smock's and the load generator's, from the
# repository's root.
DOCKERFILES=(Dockerfile bench/gke/smock-definitions.dockerfile bench/gke/generator.Dockerfile)
# How long the load generator's Pod may wait for a node, smock to become
# ready, and an access token may be used before a new one is fetched (a
# token lasts an hour from when access_token takes it).
PENDING_LIMIT_S=900
READY_LIMIT_S=900
TOKEN_REFRESH_S=2700
# What gcloud is asked for an access token: a new one. gcloud auth
# print-access-token gives the token gcloud has cached, which may expire
# within minutes, long before TOKEN_REFRESH_S.
ACCESS_TOKEN_ARGS=(config config-helper --force-auth-refresh --format='value(credential.access_token)')
# How long deleting the cluster may take before the script gives up on it.
DELETE_LIMIT_S=1800
# The file the watchdog leaves in the results directory, beside its stop
# file, before it stops the run at the time limit, so that the run says
# why it was stopped.
TIME_LIMIT_PASSED=.time-limit-passed
# The longest time limit: a full run takes under an hour, and a limit far
# beyond it, such as 4800 taken as minutes, would keep a stuck run billed.
MAX_TIME_LIMIT_S=14400

dry_run=0 yes=0 enable_apis=0
plan="$ROOT/bench/plan-autopilot.json" targets="$ROOT/bench/targets.json"
profiles="" cases="" out="" time_limit=80m smock_binary="" oha_binary="" arch="" smock_sha256=""
# The variants of a run that compares them (--variant), in the order given,
# the first the baseline, and how many rounds the load generator measures
# them in (--rounds); none in a run of one smock. Each variant's binary,
# its options as gke.py takes them (",no-init,no-first-second,scenarios"
# or ",crud" in its place, or fewer), whether its Pod has the init container, the definitions it
# serves as the repository names them, its SHA-256, the image of its
# binary and that image's reference once pushed, by label; and the images
# of smock, one for each distinct binary, named for the first variant with
# it, with their references once pushed.
variant_args=() variants=() rounds="" smock_images=()
declare -A variant_file=() variant_options=() variant_init=() variant_definitions=() variant_sha256=()
declare -A variant_image=() variant_ref=()
declare -A image_ref=()
project_number="" account_pattern="" problems=() apis_to_enable=()
work="" resources_may_exist=0 watchdog_pid="" built_images=() log_pid="" token_at=0
# The profile running, why the run stopped, and whether the summary is written.
current_profile="" stop_reason="" summarized=0

say() {
  printf 'gke-bench: %s\n' "$*" >&2
}

die() {
  say "$*"
  stop_reason="$*"
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

# Prints a new access token from gcloud (ACCESS_TOKEN_ARGS), which lasts an
# hour from now; gcloud's messages are masked.
access_token() {
  "$GCLOUD" "${ACCESS_TOKEN_ARGS[@]}" 2> >(masked >&2)
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

# Its arguments for people: a, b and c.
and_list() {
  local text=$1 index
  for ((index = 2; index <= $#; index++)); do
    if [ "$index" = $# ]; then
      text+=" and ${!index}"
    else
      text+=", ${!index}"
    fi
  done
  printf '%s' "$text"
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
# run (with SIGTERM, having left TIME_LIMIT_PASSED beside the stop file)
# and deletes the cluster and the repository, and, once the run has gone,
# its temporary directory with the kubeconfig. The run stops it when it has
# cleaned up, through the stop file.
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
    : >"$(dirname "$stop")/$TIME_LIMIT_PASSED"
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
  --plan | --profiles | --cases | --targets | --out | --time-limit | --arch | --smock | --oha | --variant | --rounds)
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
    --variant) variant_args+=("$2") ;;
    --rounds) rounds=$2 ;;
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

# Says why the command line cannot make a run, and exits.
wrong() {
  say "$*"
  exit 2
}

# Reads the variants --variant gives,
# LABEL=FILE[,no-init][,no-first-second][,scenarios][,crud] each, into variants and the maps by label, with the SHA-256 of each one's
# binary, which a dry run needs even when the checks stop early, and the
# rounds (4 unless --rounds says otherwise); exits when they cannot make a
# run, as gke.py would refuse them once the cluster is made. gke.py plan
# checks the names each label makes under the profiles.
read_variants() {
  local text label file option options seen=" "
  if [ ${#variant_args[@]} -eq 0 ]; then
    [ -z "$rounds" ] || wrong "--rounds needs --variant: smock alone is measured once"
    return 0
  fi
  [ -z "$smock_binary" ] || wrong "give the binaries with --smock or with --variant, not both"
  if [ ${#variant_args[@]} -lt 2 ] || [ ${#variant_args[@]} -gt 4 ]; then
    wrong "a run compares 2 to 4 variants, not ${#variant_args[@]}"
  fi
  for text in "${variant_args[@]}"; do
    [[ $text == *=?* ]] || wrong "--variant $text: give it as LABEL=FILE[,no-init][,no-first-second][,scenarios][,crud]"
    label=${text%%=*}
    IFS=, read -r -a options <<<"${text#*=}"
    file=${options[0]}
    if ! [[ $label =~ ^[a-z]([-a-z0-9]{0,14}[a-z0-9])?$ ]]; then
      wrong "variant label $label: use 1 to 16 lowercase letters, digits and hyphens, starting with a letter and" \
        "ending with a letter or digit"
    fi
    [[ $seen != *" $label "* ]] || wrong "variant $label is given twice: give each its own label"
    seen+="$label "
    variant_init[$label]=1 variant_options[$label]="" variant_definitions[$label]=bench/definitions
    for option in "${options[@]:1}"; do
      case $option in
      no-init) variant_init[$label]=0 ;;
      no-first-second) ;;
      scenarios) variant_definitions[$label]=bench/definitions-scenarios ;;
      crud) variant_definitions[$label]=bench/definitions-crud ;;
      *) wrong "variant $label: no option $option; there are no-init, no-first-second, scenarios and crud" ;;
      esac
      [[ ${variant_options[$label]}, == *",$option,"* ]] || variant_options[$label]+=",$option"
    done
    if [[ ${variant_options[$label]}, == *",scenarios,"* && ${variant_options[$label]}, == *",crud,"* ]]; then
      wrong "variant $label: scenarios and crud serve other definitions: give one of them"
    fi
    [ -f "$file" ] || wrong "no file $file"
    variants+=("$label")
    variant_file[$label]=$file
    variant_sha256[$label]=$(sha256sum "$file" | cut -d ' ' -f 1)
  done
  rounds=${rounds:-4}
  [[ $rounds =~ ^[1-9][0-9]{0,2}$ ]] || wrong "--rounds is a number of rounds, at least 1, not $rounds"
}

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
read_variants
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
if [ "$arch" != "$host_arch" ] && [ -z "$smock_binary" ] && [ ${#variants[@]} -eq 0 ]; then
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
  summarize_stopped "${stop_reason:-the script ended with status $status}"
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
  stop_reason="stopped by SIG$1"
  if [ "$1" = TERM ] && [ -e "$out/$TIME_LIMIT_PASSED" ]; then
    stop_reason="the time limit of $((time_limit_s / 60)) minutes passed, and the watchdog stopped the run"
  fi
  say "$stop_reason"
  exit "$2"
}

trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP

# --- Checks ----------------------------------------------------------------

# Checks that quota METRIC of FILE (gcloud's description of the project or
# of the region) has NEEDED free, and says how much: LABEL names the quota,
# UNIT is its unit, and WHY what the run needs it for. A quota gcloud does
# not list cannot be checked, which stops the run all the same.
check_quota() {
  local file=$1 metric=$2 label=$3 needed=$4 unit=$5 why=$6 text status
  text=$("$PYTHON" - "$file" "$metric" "$label" "$needed" "$unit" "$why" <<'EOF'
import json
import sys

path, metric, label, needed, unit, why = sys.argv[1:7]
quotas = {quota["metric"]: quota for quota in json.load(open(path)).get("quotas", [])}
quota = quotas.get(metric)
if quota is None:
    print(f"{label}: not among the quotas gcloud lists, so the run cannot check it")
    sys.exit(2)
free = quota["limit"] - quota["usage"]
print(f"{label}: {free:g} of {quota['limit']:g} {unit} free, the run needs {float(needed):g} {why}")
sys.exit(0 if free >= float(needed) else 1)
EOF
  )
  status=$?
  case $status in
  0) say "$text" ;;
  1) problem "$text: ask for more on the console's Quotas page (IAM & Admin), or, to accept that the load" \
    "generator's node may wait for Autopilot to remove its first node, set GKE_BENCH_NEEDED_CPUS lower" ;;
  *) problem "${text:-$label: cannot be read}" ;;
  esac
}

# A number (the first argument) of a thing (the second), as people read
# it: "1 node", "4 nodes".
count() {
  if [ "$1" = 1 ]; then
    printf '1 %s' "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

# The checks that need the Compute Engine API: the zone, the quotas the
# run's nodes draw on, and what the project has before the run.
check_project() {
  local region line warning nodes=$(((NEEDED_CPUS + NODE_CPUS - 1) / NODE_CPUS)) x86 x86_nodes arm arm_nodes
  # The x86 nodes: on amd64 every node; on arm64 Autopilot's own, the
  # others being Arm nodes.
  x86=$nodes x86_nodes="its $(count "$nodes" node)" arm=0
  if [ "$arch" = arm64 ]; then
    x86=$((nodes < SYSTEM_NODES ? nodes : SYSTEM_NODES))
    x86_nodes="Autopilot's $(count "$x86" "x86 node")" arm=$((nodes - x86))
  fi
  if [ -n "$ZONE" ]; then
    region=$(reads "$GCLOUD" compute zones describe "$ZONE" --project="$PROJECT" --format='value(region.basename())')
    [ "$region" = "$REGION" ] || problem "zone $ZONE is not a zone of $REGION: set GKE_BENCH_ZONE to one, or unset it"
  fi
  if reads "$GCLOUD" compute project-info describe --project="$PROJECT" --format=json >"$work/project-info.json"; then
    check_quota "$work/project-info.json" CPUS_ALL_REGIONS CPUS_ALL_REGIONS "$NEEDED_CPUS" vCPUs \
      "for its $(count "$nodes" node)"
  else
    problem "cannot read the project's CPU quota"
  fi
  if reads "$GCLOUD" compute regions describe "$REGION" --project="$PROJECT" --format=json >"$work/region.json"; then
    if warning=$("$PYTHON" -c "$QUOTA_WARNING" "$work/region.json" | masked); then
      problem "cannot read the quotas of $REGION ($warning): try again"
    else
      check_quota "$work/region.json" CPUS "CPUS in $REGION" \
        $((x86 * NODE_CPUS < NEEDED_CPUS ? x86 * NODE_CPUS : NEEDED_CPUS)) vCPUs "for $x86_nodes"
      check_quota "$work/region.json" "${BOOT_DISK_QUOTAS[amd64]}" "${BOOT_DISK_QUOTAS[amd64]} in $REGION" \
        $((x86 * NODE_BOOT_DISK_GB)) GB "for the boot disks of $x86_nodes, $NODE_BOOT_DISK_GB GB each"
      if [ "$arm" -gt 0 ]; then
        arm_nodes="its $(count "$arm" "Arm node")"
        check_quota "$work/region.json" "${BOOT_DISK_QUOTAS[arm64]}" "${BOOT_DISK_QUOTAS[arm64]} in $REGION" \
          $((arm * NODE_BOOT_DISK_GB)) GB "for the boot disks of $arm_nodes, $NODE_BOOT_DISK_GB GB each"
        say "not checked: the CPU quota of the Arm nodes' machine family, of which the run needs" \
          "$((arm * NODE_CPUS)) vCPUs for $arm_nodes, since gcloud does not list it: see the console's Quotas" \
          "page (IAM & Admin)"
      fi
      check_quota "$work/region.json" IN_USE_ADDRESSES "IN_USE_ADDRESSES in $REGION" "$nodes" addresses \
        "for the external IP addresses of its $(count "$nodes" node)"
    fi
  else
    problem "cannot read the quotas of $REGION"
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
  check_variants
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

# Checks that each variant's binary is for the run's architecture, and
# says which binary it is: its SHA-256, which the summary records, and the
# commit it says it is built from when this machine can run it (smock
# --version). Unlike --smock, a variant's binary may be built from any
# commit: the harness is the commit checked out, and the binaries are what
# the run compares. Of one this machine cannot run, the summary has the
# commit smock says once it runs on its node.
check_variants() {
  local label file text version commit
  for label in "${variants[@]}"; do
    file=${variant_file[$label]}
    text=$(binary_problem "variant $label" "$file")
    if [ -n "$text" ]; then
      problem "$text"
    elif [ "$arch" != "$host_arch" ]; then
      say "variant $label: $file is for $arch, which this machine cannot run; its SHA-256 is" \
        "${variant_sha256[$label]}; the summary has the commit it says it is built from"
    elif [ -x "$file" ] && version=$("$file" --version 2>&1) &&
      commit=$(sed -n 's/.*(commit \([0-9a-f]*\),.*/\1/p' <<<"$version") && [ -n "$commit" ]; then
      say "variant $label: $file says it is built from commit $commit; its SHA-256 is ${variant_sha256[$label]}"
    else
      say "variant $label: $file does not say its commit here (\`$file --version\`); its SHA-256 is" \
        "${variant_sha256[$label]}; the summary has the commit it says it is built from"
    fi
  done
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
  if [ -z "$smock_binary" ] && [ ${#variants[@]} -eq 0 ] && ! command -v moon >/dev/null 2>&1; then
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
    say "the zone, the quotas and what the project has are checked once the APIs are enabled"
  fi
}

# --- The run -----------------------------------------------------------------

# Gives each variant the image of its binary: one image of smock for each
# distinct binary, by its SHA-256, named for the first variant with it,
# which those after it with the same binary share; and says which binary
# each image holds.
share_images() {
  local label image sharing
  smock_images=()
  for label in "${variants[@]}"; do
    variant_image[$label]=smock-$label
    for image in "${smock_images[@]}"; do
      if [ "${variant_sha256[${image#smock-}]}" = "${variant_sha256[$label]}" ]; then
        variant_image[$label]=$image
        break
      fi
    done
    [ "${variant_image[$label]}" != "smock-$label" ] || smock_images+=("smock-$label")
  done
  for image in "${smock_images[@]}"; do
    sharing=()
    for label in "${variants[@]}"; do
      [ "${variant_image[$label]}" != "$image" ] || sharing+=("$label")
    done
    say "smock's image $image holds the binary of $(and_list "${sharing[@]}")" \
      "(SHA-256 ${variant_sha256[${image#smock-}]})"
  done
}

# Writes the build context of an image of smock into DIRECTORY (the first
# argument): the binary (the second), LICENSE and NOTICE, which the
# Dockerfile copies too, the benchmark's definitions and their Scenario
# and CRUD variants, which a scenarios and a crud variant serve.
smock_context() {
  mkdir -p "$1/dist"
  cp "$2" "$1/dist/smock"
  cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$1/"
  cp -r "$ROOT/bench/definitions" "$1/definitions"
  cp -r "$ROOT/bench/definitions-scenarios" "$1/definitions-scenarios"
  cp -r "$ROOT/bench/definitions-crud" "$1/definitions-crud"
}

build_images() {
  smock_image=smock-gke-bench/smock:$run_id
  generator_image=smock-gke-bench/generator:$run_id
  local text image
  if [ -z "$smock_binary" ] && [ ${#variants[@]} -eq 0 ]; then
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
  [ ${#variants[@]} -eq 0 ] || share_images
  if [ "$dry_run" = 0 ]; then
    mkdir -p "$work/generator-image/bench/gke"
    cat "$ROOT/Dockerfile" "$ROOT/bench/gke/smock-definitions.dockerfile" >"$work/smock.Dockerfile"
    if [ ${#variants[@]} -eq 0 ]; then
      smock_sha256=$(sha256sum "$smock_binary" | cut -d ' ' -f 1)
      smock_context "$work/smock-image" "$smock_binary"
      built_images=("$smock_image")
    else
      for image in "${smock_images[@]}"; do
        smock_context "$work/$image-image" "${variant_file[${image#smock-}]}"
        built_images+=("smock-gke-bench/$image:$run_id")
      done
    fi
    built_images+=("$generator_image")
    cp "$oha_binary" "$work/generator-image/oha"
    cp "$ROOT/bench/bench.py" "$ROOT/bench/requests.json" "$ROOT/bench/requests-crud.json" \
      "$work/generator-image/bench/"
    cp "$plan" "$work/generator-image/bench/plan.json"
    cp "$ROOT/bench/gke/gke.py" "$ROOT/bench/gke/generator.py" "$work/generator-image/bench/gke/"
  fi
  [ "$dry_run" = 0 ] || say "would write $work/smock.Dockerfile: the repository's Dockerfile and" \
    "bench/gke/smock-definitions.dockerfile"
  if [ ${#variants[@]} -eq 0 ]; then
    changes "$DOCKER" build --platform="linux/$arch" --file="$work/smock.Dockerfile" --tag="$smock_image" \
      "$work/smock-image" || die "building smock's image failed"
  fi
  for image in "${smock_images[@]}"; do
    changes "$DOCKER" build --platform="linux/$arch" --file="$work/smock.Dockerfile" \
      --tag="smock-gke-bench/$image:$run_id" "$work/$image-image" || die "building smock's image $image failed"
  done
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
  rm -f "$out/.watchdog-stop" "$out/$TIME_LIMIT_PASSED"
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
    say "would run: $(shown "$GCLOUD" "${ACCESS_TOKEN_ARGS[@]}") | $(shown env DOCKER_CONFIG="$work/docker" \
      "$DOCKER" login --username=oauth2accesstoken --password-stdin "https://$registry")"
  else
    say "+ $(shown "$GCLOUD" "${ACCESS_TOKEN_ARGS[@]}") | $(shown env DOCKER_CONFIG="$work/docker" "$DOCKER" login \
      --username=oauth2accesstoken --password-stdin "https://$registry")"
    { access_token | env DOCKER_CONFIG="$work/docker" "$DOCKER" login \
      --username=oauth2accesstoken --password-stdin "https://$registry" >/dev/null; } &
    wait $! || die "logging in to $registry failed"
  fi
  local image label
  if [ ${#variants[@]} -eq 0 ]; then
    [ "$dry_run" = 1 ] || built_images+=("$registry/$PROJECT/$repository/smock:$run_id"
      "$registry/$PROJECT/$repository/generator:$run_id")
    smock_ref=$(push_image "$smock_image" smock) || exit 1
  else
    for image in "${smock_images[@]}" generator; do
      [ "$dry_run" = 1 ] || built_images+=("$registry/$PROJECT/$repository/$image:$run_id")
    done
    for image in "${smock_images[@]}"; do
      image_ref[$image]=$(push_image "smock-gke-bench/$image:$run_id" "$image") || exit 1
    done
    for label in "${variants[@]}"; do
      variant_ref[$label]=${image_ref[${variant_image[$label]}]}
    done
  fi
  generator_ref=$(push_image "$generator_image" generator) || exit 1
}

# Writes the kubeconfig: the cluster's endpoint and CA, and a new access
# token from gcloud, readable by this user only. The token's hour starts
# when it is taken, which token_at records.
write_kubeconfig() {
  local token
  token_at=$(now)
  token=$(access_token) || die "gcloud did not give a new access token"
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
    say "would write a kubeconfig (mode 600) with the cluster's endpoint and a new access token from" \
      "$(shown "$GCLOUD" "${ACCESS_TOKEN_ARGS[@]}"): $kubeconfig"
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

# Keeps what the run knows of the profile's Pods and of the nodes they run
# on, as gke.py pod-info keeps them, in pods.json under RAW (the first
# argument): as soon as each Pod has a node, so that a run that stops under
# the profile has them, with --without-restarts (the other arguments go to
# pod-info), since smock's OOM kills come from its restarts at the
# profile's end; and again at the profile's end, with them. A pods.json
# kept before stays when they cannot be read, and its restarts stay
# unknown.
keep_pods() {
  local raw=$1
  [ "$dry_run" = 0 ] || return 0
  mkdir -p "$raw"
  refresh_token
  if kube get pods --output=json >"$work/pods.json" && kube get nodes --output=json >"$work/nodes.json" &&
    "$PYTHON" "$GKE_PY" pod-info "${@:2}" "$work/pods.json" "$work/nodes.json" >"$work/pod-info.json"; then
    mv "$work/pod-info.json" "$raw/pods.json"
  fi
}

# Keeps what the init container of smock's Pod printed of the CPU of its
# node, masked, with kubectl's errors in its place, as smock-node-cpu.log:
# it has printed it once smock has started.
keep_smock_node_cpu() {
  local smock_pod=$1 raw=$2
  if [ "$dry_run" = 1 ]; then
    say "would keep what smock's init container printed of the CPU of its node as $raw/smock-node-cpu.log"
    return 0
  fi
  mkdir -p "$raw"
  refresh_token
  "$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" logs --container=node-cpu "pod/$smock_pod" 2>&1 |
    masked >"$raw/smock-node-cpu.log"
}

# Keeps what smock left under a profile while its Pod and Service are still
# there, masked: its log as smock.log (when it restarted, or that is not
# known, its container before the last restart first), with kubectl's
# errors in their place, and its Service with the Service's EndpointSlices
# as service.json. Its restarts come from the pods.json the third argument
# names (by default the one under RAW, the second); a variant's Service is
# named for it (the fourth), and only it and its EndpointSlices are kept.
keep_smock_state() {
  local smock_pod=$1 raw=$2 pods=${3:-$2/pods.json} service=${4:-} restarts
  # kubectl itself, not the function kube, so that its errors stay in order
  # with what it prints. smock's container by name: kubectl says on stderr
  # which one it chose for a Pod with an init container.
  local logs=("$KUBECTL" --kubeconfig="$kubeconfig" --namespace="$NAMESPACE" logs --container=smock)
  if [ "$dry_run" = 1 ]; then
    say "would keep smock's log as $raw/smock.log, and its Service and EndpointSlices as $raw/service.json"
    return 0
  fi
  mkdir -p "$raw"
  refresh_token
  restarts=$("$PYTHON" -c "$SMOCK_RESTARTS" "$pods" "$smock_pod" 2>/dev/null) || restarts=unknown
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
  if [ -z "$service" ]; then
    kube get service,endpointslices --output=json | masked >"$raw/service.json" ||
      say "cannot read smock's Service and its EndpointSlices; $raw/service.json may be empty"
  else
    kube get service,endpointslices --output=json | "$PYTHON" -c "$OWN_SERVICE" "$service" | masked \
      >"$raw/service.json" || say "cannot read the Service $service and its EndpointSlices; $raw/service.json may" \
      "be empty"
  fi
}

# Keeps what each variant whose Pod was applied under profile NAME (the
# first argument; the others are those variants) left in RAW/<label>/
# (keep_smock_state), and of one with the init container what it printed
# of its node's CPU, as when it never became ready.
keep_variants_state() {
  local name=$1 label
  for label in "${@:2}"; do
    [ "${variant_init[$label]}" = 0 ] || keep_smock_node_cpu "smock-$name-$label" "$out/raw/$name/$label"
    keep_smock_state "smock-$name-$label" "$out/raw/$name/$label" "$out/raw/$name/pods.json" "smock-$name-$label"
  done
}

# Starts the variants under profile NAME (the first argument), from the
# manifests in the second: each Pod once the one before is ready, so that
# each joins the node of the first, which matches its own affinity and may
# go anywhere. Then keeps the Pods, and checks that they share one node
# with the plan's limits as their requests and limits (gke.py placement),
# since a comparison across nodes or under other limits would compare
# them; and keeps what the init container of each that has one printed of
# its node's CPU. Dies, having kept the evidence, when a variant does not
# become ready (Pending, as when its node has no room for it) or the check
# fails, before the load generator starts.
start_variants() {
  local name=$1 manifests=$2 raw=$out/raw/$1 first=${variants[0]} label pod node text line why="" started=()
  for label in "${variants[@]}"; do
    pod=smock-$name-$label
    started+=("$label")
    kube_run apply --filename="$manifests/smock-$label.json" || die "applying the Pod of variant $label failed"
    if ! kube_run wait --for=condition=Ready "pod/$pod" --timeout="${READY_LIMIT_S}s"; then
      kube get events --field-selector=involvedObject.kind=Pod | masked >&2
      mkdir -p "$raw/$label"
      kube describe "pod/$pod" 2>&1 | masked >"$raw/$label/describe.txt"
      keep_pods "$raw"
      keep_variants_state "$name" "${started[@]}"
      node=$("$PYTHON" -c "$POD_NODE" "$raw/pods.json" "$pod" 2>/dev/null)
      if [ "$label" = "$first" ]; then
        die "variant $label did not become ready under $name"
      elif [ -z "$node" ]; then
        die "variant $label could not join the node of variant $first under $name: its Pod had no node after" \
          "$((READY_LIMIT_S / 60)) minutes (its events are above, and in $raw/$label/describe.txt)"
      fi
      die "variant $label did not become ready under $name, on the node of variant $first"
    fi
  done
  keep_pods "$raw" --without-restarts
  if [ "$dry_run" = 1 ]; then
    say "would check that the variants share a node, with the limits of $name as their requests and limits:" \
      "$(shown "$PYTHON" "$GKE_PY" placement "$raw/pods.json" --plan "$plan" --profile "$name")"
  elif ! text=$("$PYTHON" "$GKE_PY" placement "$raw/pods.json" --plan "$plan" --profile "$name" 2>&1); then
    keep_variants_state "$name" "${variants[@]}"
    while IFS= read -r line; do
      why+="${why:+; }${line#gke: }"
    done <<<"$text"
    die "the variants cannot be compared under $name, so the load generator was not started: $why"
  fi
  for label in "${variants[@]}"; do
    [ "${variant_init[$label]}" = 0 ] || keep_smock_node_cpu "smock-$name-$label" "$raw/$label"
  done
}

# Runs one profile: smock, or each variant (start_variants), then the load
# generator, then what they left, then deletes them. Fails when smock, a
# variant or the load generator could not start, or the variants cannot be
# compared (which the next profile would hit too). Returns 3 when the
# profile ran but not all of its steps (its Job did not complete, or the
# load generator stopped it early), and 4 when the load generator's Job or
# smock's Pods and Services were not deleted, so that no later profile may
# run beside them (stop_reason then says which).
run_profile() {
  local name=$1 deadline_s=$2 job=generator-$1 manifests=$work/manifests/$1 raw=$out/raw/$1 status=0 waited ended
  local left="" label undeleted=() smock_options=(--smock-image "${smock_ref:-}")
  local generator_ref_shown=${generator_ref:-}
  # smock's Pod and Service, as gke.py names them: their own under each
  # profile, so that a lookup of the name cannot get the address of the
  # previous profile's Service.
  local smock_pod=smock-$1
  # smock's Pod ends by itself at the time limit, counted from when its
  # node accepts it.
  local smock_deadline_s=$((deadline - $(now)))
  if [ ${#variants[@]} -eq 0 ]; then
    say "profile $name: $3 steps; the load generator's Job may take $((deadline_s / 60)) minutes"
  else
    say "profile $name: $3 steps for each of ${#variants[@]} variants in each of $rounds rounds," \
      "$(($3 * ${#variants[@]} * rounds)) runs; the load generator's Job may take $((deadline_s / 60)) minutes"
    smock_options=(--rounds "$rounds")
    for label in "${variants[@]}"; do
      smock_options+=(--variant "$label=${variant_ref[$label]:-}${variant_options[$label]}")
    done
  fi
  "$PYTHON" "$GKE_PY" manifests --plan "$plan" --profile "$name" ${cases:+--cases "$cases"} --arch "$arch" \
    ${ZONE:+--zone "$ZONE"} "${smock_options[@]}" --generator-image "$generator_ref_shown" \
    --smock-deadline-s "$smock_deadline_s" --out "$manifests" || die "rendering the manifests of $name failed"
  kube_run apply --filename="$manifests/namespace.json" || die "applying the namespace failed"
  if [ ${#variants[@]} -eq 0 ]; then
    kube_run apply --filename="$manifests/smock.json" || die "applying smock's Pod failed"
    kube_run wait --for=condition=Ready "pod/$smock_pod" --timeout="${READY_LIMIT_S}s" || {
      kube get events --field-selector=involvedObject.kind=Pod | masked >&2
      keep_pods "$raw"
      keep_smock_node_cpu "$smock_pod" "$raw"
      keep_smock_state "$smock_pod" "$raw"
      die "smock did not become ready under $name"
    }
    keep_pods "$raw" --without-restarts
    keep_smock_node_cpu "$smock_pod" "$raw"
  else
    start_variants "$name" "$manifests"
  fi
  kube_run apply --filename="$manifests/generator.json" || die "applying the load generator's Job failed"
  if [ "$dry_run" = 1 ]; then
    say "would wait for the Job $job, keep its log as $raw/generator.log and its Pods as $raw/pods.json, then" \
      "delete it and smock"
  else
    mkdir -p "$raw"
    wait_for_generator "$job" || die "the load generator's Pod did not start under $name"
    keep_pods "$raw" --without-restarts
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
    keep_pods "$raw"
    ended=$("$PYTHON" "$GKE_PY" stopped "$raw/generator.log")
    if [ -n "$ended" ]; then
      say "profile $name ended early: $ended"
      status=3
    fi
  fi
  if [ ${#variants[@]} -eq 0 ]; then
    keep_smock_state "$smock_pod" "$raw"
  else
    for label in "${variants[@]}"; do
      keep_smock_state "smock-$name-$label" "$raw/$label" "$raw/pods.json" "smock-$name-$label"
    done
  fi
  # The next profile starts once the load generator's Job and Pod, and
  # smock's Pods and Services, are gone.
  kube_run delete --filename="$manifests/generator.json" --ignore-not-found --cascade=foreground --wait=true \
    --timeout=300s || left="the load generator's Job"
  if [ ${#variants[@]} -eq 0 ]; then
    kube_run delete --filename="$manifests/smock.json" --ignore-not-found --wait=true --timeout=300s ||
      left="${left:+$left, and }smock's Pod and Service"
  else
    for label in "${variants[@]}"; do
      kube_run delete --filename="$manifests/smock-$label.json" --ignore-not-found --wait=true --timeout=300s ||
        undeleted+=("$label")
    done
    if [ ${#undeleted[@]} = 1 ]; then
      left="${left:+$left, and }the Pod and Service of variant ${undeleted[0]}"
    elif [ ${#undeleted[@]} -gt 1 ]; then
      left="${left:+$left, and }the Pods and Services of variants $(and_list "${undeleted[@]}")"
    fi
  fi
  if [ -n "$left" ]; then
    say "not deleted in 5 minutes under $name: $left; no later profile runs beside them"
    stop_reason="$left $([[ $left == *" and "* ]] && echo were || echo was) not deleted in 5 minutes, so no"
    stop_reason+=" later profile ran"
    return 4
  fi
  return "$status"
}

# Writes summary.json, summary.md and conditions.json from what the profiles
# left in the results directory, with the options of gke.py summarize given.
summarize() {
  summarized=1
  summarize_into "$out" "${smock_ref:-}" "$smock_sha256" "$@"
}

# Writes summary.json, summary.md and conditions.json into DIRECTORY (the
# first argument) from what its raw/ holds, a run of smock whose image and
# binary the second and third arguments name (its reference and its
# SHA-256), with the options of gke.py summarize given after them.
summarize_into() {
  local directory=$1 smock_image_ref=$2 sha256=$3 generator_image_ref=${generator_ref:-}
  "$PYTHON" "$GKE_PY" summarize --plan "$plan" --targets "$targets" "${selection[@]}" --region "$REGION" \
    ${ZONE:+--zone "$ZONE"} --arch "$arch" --started-at "$started_at" --finished-at "$finished_at" \
    --cluster-version "${cluster_version:-}" --smock-image "${smock_image_ref##*@}" \
    --generator-image "${generator_image_ref##*@}" --smock-sha256 "$sha256" "${@:4}" "$directory"
}

# Of a run of variants, splits what the profiles left in the results
# directory into its samples (gke.py samples: samples/<round>-<label>/, one
# variant's pass over the steps in one round, each a run of smock alone, of
# every round the run planned, which the load generator may not have said),
# writes each sample's summary with its variant's image, binary and
# definitions and the options of gke.py summarize given, and compares the
# variants (gke.py
# same-node: same-node.json and same-node.md, which is also summary.md), in
# the order given, the first the baseline, which neither the Pods nor the
# samples say when the load generator never started. Fails when a sample
# could not be summarized, or the variants cannot be compared: on more
# than one node, under other limits than the plan's, or with a sample
# incomplete.
summarize_variants() {
  local label directory status=0 compared=() sampled=" "
  summarized=1
  "$PYTHON" "$GKE_PY" samples --plan "$plan" "${selection[@]}" --rounds "$rounds" "$out" >"$work/samples.txt" ||
    return 1
  while read -r _ label directory; do
    summarize_into "$directory" "${variant_ref[$label]:-}" "${variant_sha256[$label]:-}" \
      --definitions "${variant_definitions[$label]:-bench/definitions}" "$@" || status=1
    sampled+="$label "
  done <"$work/samples.txt"
  # Only the variants with samples: one whose Pod was never applied has
  # none. The first was applied first, so it has them.
  for label in "${variants[@]}"; do
    [[ $sampled == *" $label "* ]] || continue
    compared+=(--sha256 "$label=${variant_sha256[$label]}")
    [ "${variant_init[$label]}" = 1 ] || compared+=(--no-init "$label")
  done
  "$PYTHON" "$GKE_PY" same-node --baseline "${variants[0]}" "${compared[@]}" "$out" || status=1
  [ ! -f "$out/same-node.md" ] || cp "$out/same-node.md" "$out/summary.md"
  return "$status"
}

# When the run stops once a profile has started but before it wrote its
# summary, writes the summary from what was measured, saying where it
# stopped and why (the argument). Of the profile it was running, the load
# generator's log may be only what was streamed.
# shellcheck disable=SC2329 # Called by on_exit.
summarize_stopped() {
  local raw=$out/raw/$current_profile
  if [ "$dry_run" = 1 ] || [ "$summarized" = 1 ] || [ -z "$current_profile" ]; then
    return 0
  fi
  if [ ! -s "$raw/generator.log" ] && [ -f "$raw/generator-stream.log" ]; then
    mv "$raw/generator-stream.log" "$raw/generator.log"
  fi
  finished_at=$(date -u +%FT%TZ)
  if [ ${#variants[@]} -gt 0 ]; then
    say "the run stopped under profile $current_profile: summarizing each sample, and comparing the variants, from" \
      "what it measured"
    summarize_variants --stopped "$1" --stopped-under "$current_profile"
    [ ! -f "$out/summary.md" ] || say "results: $out (summary.md says where and why the run stopped)"
    return 0
  fi
  say "the run stopped under profile $current_profile: writing summary.json, summary.md and conditions.json from" \
    "what it measured"
  summarize --stopped "$1" --stopped-under "$current_profile" &&
    say "results: $out (summary.md says where and why the run stopped)"
}

# --- Main --------------------------------------------------------------------

# How many variants and rounds gke.py times and prices the run for: none
# for smock alone. The plan also checks that each variant's label can name
# its Pod and Service under each profile, as gke.py manifests would refuse
# it once the cluster is made.
counts=() named=()
if [ ${#variants[@]} -gt 0 ]; then
  counts=(--variants "${#variants[@]}" --rounds "$rounds")
  named=(--labels "$(IFS=,; echo "${variants[*]}")")
fi
if ! profile_lines=$("$PYTHON" "$GKE_PY" plan --plan "$plan" "${selection[@]}" "${counts[@]}" "${named[@]}"); then
  exit 1
fi
say "run $run_id: project \$GKE_BENCH_PROJECT, $REGION, zone ${ZONE:-chosen by Autopilot}, $arch, plan" \
  "${plan#"$ROOT"/}"
preflight
"$PYTHON" "$GKE_PY" estimate --plan "$plan" "${selection[@]}" "${counts[@]}" --region "$REGION" --arch "$arch" \
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

# Where and why the profiles stopped before the last, which summary.md
# says, when they did; and the last profile, after which none is left to
# stop.
run_status=0 stopped=() last_profile=${profile_lines##*$'\n'}
last_profile=${last_profile%% *}
while read -r name steps deadline_s <&3; do
  # Each profile needs its Job's time, smock's start, and the deletion:
  # 600 s is gke.py's TIME_LIMIT_MARGIN_S, with which its estimate refuses
  # a run of variants whose profile would be skipped here.
  if [ $(($(now) + deadline_s + 600)) -gt "$deadline" ]; then
    say "profile $name and those after it do not fit in the time limit; skipping them"
    stop_reason="profile $name and those after it did not fit in the time limit of $((time_limit_s / 60)) minutes"
    stopped=(--stopped "$stop_reason" --stopped-under "$name")
    run_status=1
    break
  fi
  current_profile=$name
  run_profile "$name" "$deadline_s" "$steps"
  case $? in
  0) ;;
  3) run_status=1 ;;
  4)
    # What was not deleted keeps only the later profiles from running.
    [ "$name" = "$last_profile" ] || stopped=(--stopped "$stop_reason" --stopped-under "$name")
    run_status=1
    break
    ;;
  *) exit 1 ;;
  esac
done 3<<<"$profile_lines"
finished_at=$(date -u +%FT%TZ)

if [ "$dry_run" = 1 ] && [ ${#variants[@]} -gt 0 ]; then
  say "would split the results in $out into samples/<round>-<label>/, write each sample's summary.json, summary.md" \
    "and conditions.json, and compare the variants in same-node.json and same-node.md, also as summary.md"
elif [ "$dry_run" = 1 ]; then
  say "would write summary.json, summary.md and conditions.json into $out"
else
  report=$out/summary.json
  if [ ${#variants[@]} -gt 0 ]; then
    report=$out/same-node.json
    summarize_variants "${stopped[@]}" || run_status=1
  else
    summarize "${stopped[@]}" || run_status=1
  fi
  # Whatever the Jobs said: a log that lost lines leaves steps unmeasured.
  if ! incomplete=$("$PYTHON" -c "$INCOMPLETE_PROFILES" "$report" 2>/dev/null); then
    run_status=1
  elif [ -n "$incomplete" ]; then
    say "not every step was measured under: $incomplete (summary.md says why)"
    run_status=1
  fi
  if [ ${#variants[@]} -gt 0 ]; then
    say "results: $out (summary.md, the comparison, also as same-node.md; same-node.json; samples/; raw/)"
    say "compare two samples with: python3 bench/compare.py $out/samples/1-${variants[0]} $out/samples/1-${variants[1]}"
  else
    say "results: $out (summary.md, summary.json, conditions.json, raw/)"
    say "compare them with the previous pre-merge run's: python3 bench/compare.py <previous> $out"
  fi
fi
if [ ${#problems[@]} -gt 0 ]; then
  run_status=1
fi
exit "$run_status"
