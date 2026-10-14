#!/usr/bin/env python3
"""The parts of the GKE Autopilot run of the release benchmark that need no
cloud: scripts/gke-bench.sh calls it, and so does the load generator
(bench/gke/generator.py) for the steps of its profile.

usage:
  python3 bench/gke/gke.py plan [options]        the profiles a run runs, with their steps
  python3 bench/gke/gke.py estimate [options]    how long a run takes and what it costs
  python3 bench/gke/gke.py manifests [options]   the Kubernetes objects of one profile
  python3 bench/gke/gke.py pod-info PODS NODES    what to keep of the Pods and their nodes
  python3 bench/gke/gke.py summarize [options] OUT   summary.json, summary.md and conditions.json
  python3 bench/gke/gke.py stopped LOG            why the load generator stopped its profile early, if it did
  python3 bench/gke/gke.py elf-arch FILE          the architecture of an executable, amd64 or arm64
  python3 bench/gke/gke.py names-commit FILE COMMIT   fail if smock's build information does not name COMMIT
  python3 bench/gke/gke.py check-dockerfiles FILE...   fail if a Dockerfile has a RUN instruction
"""

import argparse
import importlib.util
import json
import re
import struct
import sys
from pathlib import Path
from types import SimpleNamespace

GKE = Path(__file__).resolve().parent
BENCH = GKE.parent

# bench/bench.py, for the plan's profiles, cases and steps.
_spec = importlib.util.spec_from_file_location("bench_harness", BENCH / "bench.py")
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

# The namespace everything of the run lives in, and the label of smock's
# Pods in it.
NAMESPACE = "smock-bench"
SMOCK = "smock-bench"

# What a name in Kubernetes may be: a Service's (a DNS label of RFC 1035).
DNS_LABEL = re.compile(r"[a-z]([-a-z0-9]{0,61}[a-z0-9])?")


def smock_name(profile_name):
    """The name of smock's Pod and Service under a profile: each profile has
    its own, so that a lookup of its name cannot get the address of the
    previous profile's Service, deleted just before, as under autopilot-min
    on 2026-10-14 (its load went to the address of autopilot-burst-min's
    Service, and nothing answered)."""
    return f"smock-{profile_name}"


# The load generator's Pod, by the nodes' architecture: oha used at most
# about 1 vCPU at 50,000 requests a second over plain HTTP in the arm64
# probe of 2026-10-14; TLS needs more. On x86 a vCPU is a hyperthread, and
# with 4 the load generator fell behind its schedule at 20,000 requests a
# second and above (the amd64 run of 2026-10-14), so it has 6 there. Either
# fits an 8-vCPU node (7910m allocatable on ek-standard-8 and
# e4a-standard-8 in those runs) with at least 1 vCPU left for Autopilot's
# own Pods on it, so that the run's CPU quota of three such nodes holds.
# oha's worker threads and the split of the connections between the
# requests of the mix do not depend on the number of CPUs. Its ephemeral
# storage holds oha's databases of one step.
GENERATOR_RESOURCES = {
    "amd64": {"cpu": "6", "memory": "6Gi", "ephemeral-storage": "2Gi"},
    "arm64": {"cpu": "4", "memory": "4Gi", "ephemeral-storage": "2Gi"},
}

# What smock may write: nothing but its log.
SMOCK_EPHEMERAL_STORAGE = "64Mi"

# How long the load generator may take for each step beyond its load (to
# read oha's databases), to start and wait for smock, and for smock's
# traffic ports to answer: before the first step, and once more after a
# step with no response (a check that passes after such a step takes about
# as long as one request).
STEP_ANALYSIS_S = 15
GENERATOR_START_S = 300
TRAFFIC_CHECK_S = 60
TRAFFIC_CHECKS = 2


# What a run costs: on-demand prices of general-purpose (x86) Autopilot
# Pods, which are billed for their requests, in USD an hour before tax, from
# https://cloud.google.com/kubernetes-engine/pricing on 2026-10-14, and the
# cluster management fee, the same in every region. A billing account's
# free tier ($74.40 a month) covers the fee of one Autopilot or zonal
# cluster. Arm Pods are priced here as x86 ones.
PRICES_DATE = "2026-10-14"
PRICES_URL = "https://cloud.google.com/kubernetes-engine/pricing"
CLUSTER_FEE_PER_HOUR = 0.10
POD_PRICES_PER_HOUR = {
    "us-central1": {"vcpu": 0.0445, "memory_gib": 0.0049225, "ephemeral_gib": 0.0001389},
    "asia-northeast1": {"vcpu": 0.0571, "memory_gib": 0.0063215, "ephemeral_gib": 0.0001784},
}
UNKNOWN_REGION_MARGIN = 1.3

# How long the parts of a run take, from the probe of 2026-10-14: creating
# the cluster took 9 minutes and deleting it 4; a new node was ready about
# 75 s after its Pod was made; reading oha's databases took a few seconds a
# step.
CLUSTER_CREATE_S = 540
CLUSTER_DELETE_S = 300
PROFILE_START_S = 180
EXPECTED_ANALYSIS_S = 5
# A run must be done this long before its time limit.
TIME_LIMIT_MARGIN_S = 600


class GkeError(Exception):
    """A problem with the plan or the files, with what to change."""


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise GkeError(f"cannot read {path}: {error}") from error


def plan_profiles(plan, names=None):
    """The profiles of the plan to run, all of them by default, in the
    plan's order. A Pod on GKE needs a memory limit."""
    profiles = harness.plan_profiles(plan)
    for name in names or []:
        if name not in [profile["name"] for profile in profiles]:
            raise GkeError(f"the plan has no profile {name}")
    profiles = [profile for profile in profiles if names is None or profile["name"] in names]
    for profile in profiles:
        if not DNS_LABEL.fullmatch(smock_name(profile["name"])) or \
                not DNS_LABEL.fullmatch(f"generator-{profile['name']}"):
            raise GkeError(f"profile {profile['name']} cannot name a Kubernetes Service ({smock_name(profile['name'])}) "
                           "or Job: name it with lowercase letters, digits and hyphens, in 53 characters at most")
        if profile["memory_limit"] is None:
            raise GkeError(f"profile {profile['name']} has no memory limit, which a Pod on GKE Autopilot needs: "
                           "run a plan whose profiles have one, such as bench/plan-autopilot.json")
    return profiles


def plan_cases(plan, names=None):
    """The cases of the plan to run, all of them by default. Only the
    harness on one machine can hold idle connections."""
    for name in names or []:
        if name not in [case["name"] for case in plan["cases"]]:
            raise GkeError(f"the plan has no case {name}")
    cases = [case for case in plan["cases"] if names is None or case["name"] in names]
    for case in cases:
        if case.get("idle_connections"):
            raise GkeError(f"case {case['name']} holds idle connections, which the GKE run cannot: "
                           "leave it out with --cases")
    return cases


def comma_list(text):
    """The items of a comma-separated list from the command line, or None."""
    return text.split(",") if text else None


def steps(plan, profile, cases):
    """The steps of `cases` under `profile`, in the order bench/bench.py runs
    them: each case of the plan, each rate of its ladder from the lowest,
    with the same ids."""
    run = SimpleNamespace(args=SimpleNamespace(duration=None), ramp_s=plan["ramp_s"],
                          duration_s=plan["duration_s"], tail_s=plan["tail_s"], plan=plan)
    specs = []
    for case in cases:
        rates = case["rates"].get(profile["name"]) if isinstance(case["rates"], dict) else None
        if rates is None:
            continue
        ladder = sorted(rates) if isinstance(rates, list) else [rates]
        specs += [harness.case_spec(run, case, profile, rate, ladder) for rate in ladder]
    return specs


def load_s(plan, specs):
    """How long the steps' load lasts, with the pauses between them."""
    return sum(spec["ramp_s"] + spec["duration_s"] + spec["tail_s"] for spec in specs) + \
        max(0, len(specs) - 1) * plan["cooldown_s"]


def job_deadline_s(plan, specs):
    """The load generator Job's activeDeadlineSeconds."""
    return round(load_s(plan, specs) + len(specs) * STEP_ANALYSIS_S + GENERATOR_START_S +
                 TRAFFIC_CHECKS * TRAFFIC_CHECK_S)


# The compute class of each architecture's Pods: the built-in autopilot-arm
# for arm64, and Autopilot's default general-purpose x86 Pods for amd64,
# which no class selects.
COMPUTE_CLASSES = {"arm64": "autopilot-arm", "amd64": "general-purpose"}


def node_selector(arch, zone=None):
    """Pins a Pod to the architecture, its compute class, and the zone
    when there is one."""
    selector = {"kubernetes.io/arch": arch}
    if arch == "arm64":
        selector["cloud.google.com/compute-class"] = COMPUTE_CLASSES[arch]
    if zone:
        selector["topology.kubernetes.io/zone"] = zone
    return selector


def manifests(plan, profile, cases, arch, zone, smock_image, generator_image, smock_deadline_s):
    """The objects of one profile: {file name: object}. namespace.json holds
    the namespace and its quota, smock.json smock's Service and Pod,
    generator.json the load generator's Job. Both Pods run on nodes of
    `arch`, in `zone` when it is given; else Autopilot chooses smock's zone,
    and the load generator runs in the same one, on another node.

    smock runs in a Pod of its own, not a Deployment, so that it can have a
    deadline (`smock_deadline_s`, the time left until the run's time limit,
    which counts from when its node accepts it): like the load generator's
    Job, it stops being billed by itself even when neither the run nor its
    watchdog is left to delete the cluster."""
    if smock_deadline_s < 1:
        raise GkeError(f"smock's Pod needs a deadline of at least 1 s, not {smock_deadline_s}")
    name = smock_name(profile["name"])
    labels = {"app": SMOCK}
    limits = {"cpu": profile["cpu_limit"], "memory": profile["memory_limit"],
              "ephemeral-storage": SMOCK_EPHEMERAL_STORAGE}
    pod_security = {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532,
                    "seccompProfile": {"type": "RuntimeDefault"}}
    container_security = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                          "capabilities": {"drop": ["ALL"]}}
    namespace = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NAMESPACE}}
    # Nothing billed apart from the Pods: no load balancer, node port or
    # volume claim, and no more Pods than the run needs.
    quota = {
        "apiVersion": "v1", "kind": "ResourceQuota",
        "metadata": {"name": "smock-bench", "namespace": NAMESPACE},
        "spec": {"hard": {"services.loadbalancers": "0", "services.nodeports": "0", "persistentvolumeclaims": "0",
                          "pods": "4"}},
    }
    service = {
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels},
        "spec": {"type": "ClusterIP", "selector": {**labels, "profile": profile["name"]},
                 "ports": [{"name": "plain", "port": 80, "targetPort": 8080},
                           {"name": "tls", "port": 443, "targetPort": 8443},
                           {"name": "admin", "port": 9090, "targetPort": 9090}]},
    }
    pod = {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": {**labels, "profile": profile["name"]}},
        "spec": {
            # Restarted in place after an OOM kill, as a Deployment's Pod
            # would be, until the deadline.
            "restartPolicy": "Always",
            "activeDeadlineSeconds": smock_deadline_s,
            "nodeSelector": node_selector(arch, zone),
            "enableServiceLinks": False,
            "automountServiceAccountToken": False,
            "terminationGracePeriodSeconds": 5,
            "securityContext": pod_security,
            "containers": [{
                "name": "smock", "image": smock_image, "args": ["serve"],
                "env": [{"name": "SMOCK_DIR", "value": "/definitions"},
                        {"name": "SMOCK_ADMIN_AUTH", "value": "off"}],
                "ports": [{"name": "plain", "containerPort": 8080}, {"name": "tls", "containerPort": 8443},
                          {"name": "admin", "containerPort": 9090}],
                "resources": {"requests": limits, "limits": limits},
                "readinessProbe": {"httpGet": {"path": "/readyz", "port": 9090}, "periodSeconds": 5,
                                   "failureThreshold": 2},
                "securityContext": container_security,
            }],
        },
    }
    specs = steps(plan, profile, cases)
    job = {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": f"generator-{profile['name']}", "namespace": NAMESPACE,
                     "labels": {"app": "smock-bench-generator", "profile": profile["name"]}},
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": job_deadline_s(plan, specs),
            "template": {
                "metadata": {"labels": {"app": "smock-bench-generator", "profile": profile["name"]}},
                "spec": {
                    "restartPolicy": "Never",
                    "nodeSelector": node_selector(arch, zone),
                    "enableServiceLinks": False,
                    "automountServiceAccountToken": False,
                    "securityContext": pod_security,
                    # Never on smock's node, so that smock's CPU is its own
                    # and the load crosses the Pod network; in smock's zone,
                    # which the zone given or this affinity sees to, so
                    # that the load does not cross zones.
                    "affinity": {
                        **({} if zone else {"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{
                            "labelSelector": {"matchLabels": labels},
                            "topologyKey": "topology.kubernetes.io/zone"}]}}),
                        "podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{
                            "labelSelector": {"matchLabels": labels},
                            "topologyKey": "kubernetes.io/hostname"}]},
                    },
                    "containers": [{
                        "name": "generator", "image": generator_image,
                        "env": [{"name": "TARGET", "value": f"{name}.{NAMESPACE}.svc.cluster.local"},
                                {"name": "PROFILE", "value": profile["name"]},
                                {"name": "CASES", "value": ",".join(case["name"] for case in cases)}],
                        "resources": {"requests": GENERATOR_RESOURCES[arch], "limits": GENERATOR_RESOURCES[arch]},
                        "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                    }],
                },
            },
        },
    }
    return {
        "namespace.json": {"apiVersion": "v1", "kind": "List", "items": [namespace, quota]},
        "smock.json": {"apiVersion": "v1", "kind": "List", "items": [service, pod]},
        "generator.json": job,
    }


def cpus(limit):
    return int(limit[:-1]) / 1000 if limit.endswith("m") else float(limit)


def gib(limit):
    return harness.memory_bytes(limit) / (1 << 30)


def pod_price(prices, cpu, memory, ephemeral):
    """What a Pod with these requests costs an hour."""
    return cpus(cpu) * prices["vcpu"] + gib(memory) * prices["memory_gib"] + gib(ephemeral) * prices["ephemeral_gib"]


def region_prices(region):
    """The Pod prices of a region, and how they were found."""
    if region in POD_PRICES_PER_HOUR:
        return POD_PRICES_PER_HOUR[region], f"{region}, on-demand prices of {PRICES_DATE}, before tax"
    base = POD_PRICES_PER_HOUR["us-central1"]
    prices = {name: price * UNKNOWN_REGION_MARGIN for name, price in base.items()}
    margin = round((UNKNOWN_REGION_MARGIN - 1) * 100)
    return prices, (f"{region}: us-central1's prices plus {margin}%, on-demand prices of {PRICES_DATE}, before tax; "
                    "this region's own are not here")


# The Pods of each architecture, for people.
POD_KINDS = {"amd64": "amd64 (x86) Pods", "arm64": "arm64 Pods"}


def estimate(plan, profiles, cases, region, arch, time_limit_s):
    """How long a run on `arch` takes and what it costs, for people, and why
    it does not fit in its time limit, or None."""
    prices, source = region_prices(region)
    generator = GENERATOR_RESOURCES[arch]
    generator_price = pod_price(prices, generator["cpu"], generator["memory"], generator["ephemeral-storage"])
    smock_prices = {profile["name"]: pod_price(prices, profile["cpu_limit"], profile["memory_limit"],
                                               SMOCK_EPHEMERAL_STORAGE) for profile in profiles}
    smock_cost = generator_cost = generator_s = profiles_s = 0
    for profile in profiles:
        specs = steps(plan, profile, cases)
        if not specs:
            continue
        load = load_s(plan, specs) + len(specs) * EXPECTED_ANALYSIS_S + 60
        generator_s += load
        profiles_s += PROFILE_START_S + load
        smock_cost += smock_prices[profile["name"]] * (PROFILE_START_S + load) / 3600
        generator_cost += generator_price * load / 3600
    lifetime_s = CLUSTER_CREATE_S + profiles_s + CLUSTER_DELETE_S
    fee = CLUSTER_FEE_PER_HOUR * lifetime_s / 3600
    expected = fee + smock_cost + generator_cost
    at_most = (CLUSTER_FEE_PER_HOUR + generator_price + max(smock_prices.values())) * \
        (time_limit_s + CLUSTER_DELETE_S) / 3600
    text = "\n".join([
        f"Cost estimate for {POD_KINDS[arch]} ({source}; {PRICES_URL}):",
        f"- The cluster: about {round(lifetime_s / 60)} minutes, from its creation to its deletion. Its management "
        f"fee of ${CLUSTER_FEE_PER_HOUR:.2f} an hour comes to ${fee:.2f}, or $0 while the billing account's free "
        "tier covers it (one Autopilot or zonal cluster).",
        f"- smock's Pods, {len(profiles)} profile{'' if len(profiles) == 1 else 's'} one after the other: "
        f"${smock_cost:.2f}.",
        f"- The load generator's Pod ({generator['cpu']} vCPU, {generator['memory']}): about "
        f"{round(generator_s / 60)} minutes, ${generator_cost:.2f}.",
        "- Artifact Registry: two images of about 100 MB for under an hour, within the free 0.5 GB a month.",
        "- No load balancer, static IP or volume: the run never makes one.",
        f"Expected: about ${expected:.2f}, the cluster existing for about {round(lifetime_s / 60)} minutes.",
        f"At most: ${at_most:.2f}, if it ran until the time limit ({round(time_limit_s / 60)} minutes), when the "
        "watchdog deletes the cluster, and during the deletion.",
        "If neither the run nor its watchdog could delete the cluster (the machine running them went down), its "
        f"Pods still stop within minutes of the time limit, and the cluster costs its fee, "
        f"${CLUSTER_FEE_PER_HOUR:.2f} an hour, "
        "until it is deleted: the next run's checks name it.",
        *(["Arm Pods are priced here as general-purpose x86 Pods: see the pricing page for autopilot-arm."]
          if arch == "arm64" else []),
    ])
    needed_s = lifetime_s + TIME_LIMIT_MARGIN_S
    if needed_s <= time_limit_s:
        return text, None
    return text, (f"the run needs about {round(needed_s / 60)} minutes with a margin, more than the time limit of "
                  f"{round(time_limit_s / 60)} minutes: run fewer profiles or cases, or raise the limit")


# The e_machine of an ELF executable of each architecture.
ELF_MACHINES = {62: "amd64", 183: "arm64"}


def elf_arch(path):
    """The architecture an executable is for, from its ELF header, without
    running it: amd64 or arm64."""
    try:
        with open(path, "rb") as file:
            header = file.read(20)
    except OSError as error:
        raise GkeError(f"cannot read {path}: {error}") from error
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise GkeError(f"{path} is not an ELF file")
    if header[4:6] != b"\x02\x01":
        raise GkeError(f"{path} is not a 64-bit little-endian ELF file")
    elf_type, machine = struct.unpack("<HH", header[16:20])
    if elf_type not in (2, 3):
        raise GkeError(f"{path} is an ELF file but not an executable (type {elf_type})")
    if machine not in ELF_MACHINES:
        raise GkeError(f"{path} is an ELF executable for machine {machine}, neither amd64 nor arm64")
    return ELF_MACHINES[machine]


def names_commit(path, commit):
    """Whether a smock binary names `commit` in its build information, the
    commit `smock --version` says, without running it: a native build keeps
    it as a MoonBit string literal, in UTF-16 (or in UTF-8, should that
    change)."""
    try:
        data = Path(path).read_bytes()
    except OSError as error:
        raise GkeError(f"cannot read {path}: {error}") from error
    return any(commit.encode(encoding) in data for encoding in ("utf-16-le", "utf-8"))


def run_instructions(path):
    """The RUN instructions of a Dockerfile (ONBUILD RUN among them), as
    (line number, text): what a build for another architecture than the
    builder's could not run without emulation. Comments and the lines that
    continue an instruction are not instructions."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError as error:
        raise GkeError(f"cannot read {path}: {error}") from error
    escape = "\\"
    for line in lines:
        directive = re.match(r"#\s*(\w+)\s*=\s*(\S+)\s*$", line)
        if not directive:
            break
        if directive[1].lower() == "escape":
            escape = directive[2]
    found, continuing = [], False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        words = stripped.upper().split()
        if not continuing and (words[0] == "RUN" or words[:2] == ["ONBUILD", "RUN"]):
            found.append((number, stripped))
        continuing = stripped.endswith(escape)
    return found


# The labels of a node that say what it is and where.
NODE_LABELS = {"instance_type": "node.kubernetes.io/instance-type", "arch": "kubernetes.io/arch",
               "zone": "topology.kubernetes.io/zone", "machine_family": "cloud.google.com/machine-family",
               "compute_class": "cloud.google.com/compute-class"}


def pod_info(pod_list, node_list):
    """What a run keeps of its Pods and of the nodes they ran on: where and
    how they ran, the load generator's CPU request, and nothing that names
    the project, such as image references or provider IDs."""
    info = {"smock": [], "generator": [], "nodes": {}}
    for pod in pod_list["items"]:
        app = pod["metadata"].get("labels", {}).get("app")
        status = pod.get("status", {})
        if app == SMOCK:
            container = (status.get("containerStatuses") or [{}])[0]
            terminated = container.get("lastState", {}).get("terminated") or {}
            info["smock"].append({
                "name": pod["metadata"]["name"], "node": pod["spec"].get("nodeName"),
                "ready": any(condition["type"] == "Ready" and condition["status"] == "True"
                             for condition in status.get("conditions", [])),
                "restarts": container.get("restartCount", 0), "last_termination": terminated.get("reason")})
        elif app == "smock-bench-generator":
            container = (pod["spec"].get("containers") or [{}])[0]
            info["generator"].append({"name": pod["metadata"]["name"], "node": pod["spec"].get("nodeName"),
                                      "phase": status.get("phase"), "reason": status.get("reason"),
                                      "cpu_request": container.get("resources", {}).get("requests", {}).get("cpu")})
    used = {pod["node"] for pod in [*info["smock"], *info["generator"]]}
    for node in node_list["items"]:
        if node["metadata"]["name"] not in used:
            continue
        labels, status = node["metadata"].get("labels", {}), node["status"]
        info["nodes"][node["metadata"]["name"]] = {
            **{name: labels.get(label) for name, label in NODE_LABELS.items()},
            "kernel": status["nodeInfo"]["kernelVersion"], "kubelet": status["nodeInfo"]["kubeletVersion"],
            "os_image": status["nodeInfo"]["osImage"], "cpus": status["capacity"]["cpu"],
            "allocatable_cpu": status["allocatable"]["cpu"]}
    return info


def generator_lines(path):
    """The JSON lines of the load generator's log, without its progress
    messages."""
    lines = []
    try:
        text = Path(path).read_text()
    except OSError:
        return lines
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and "kind" in value:
            lines.append(value)
    return lines


def profile_results(out, plan, profile, cases, arch):
    """What one profile's run left: its steps, whether it ran each step of
    the plan, what the load generator said at its start, its Pods, whether
    smock's traffic ports answered before the first step, whether the load
    generator stopped the profile early and which steps it did not run,
    and the load generator Pod's CPU request (as the Pod had it, else as
    the run asked)."""
    raw = Path(out) / "raw" / profile["name"]
    lines = generator_lines(raw / "generator.log")
    pods = read_json(raw / "pods.json") if (raw / "pods.json").exists() else {"smock": [], "generator": [],
                                                                               "nodes": {}}
    results = [line["result"] for line in lines if line["kind"] == "step"]
    # smock's container restarts after an OOM kill: with none, the kernel
    # never killed it; with some, which step they came in is unknown.
    smock = pods["smock"]
    oom_kills = 0 if len(smock) == 1 and smock[0]["restarts"] == 0 else None
    for result in results:
        result["memory"]["oom_kills"] = oom_kills
    planned = [spec["id"] for spec in steps(plan, profile, cases)]
    done = any(line["kind"] == "done" for line in lines)
    start = next((line for line in lines if line["kind"] == "start"), None)
    # The check before the first step, not one after a step.
    check = next((line for line in lines if line["kind"] == "traffic-check" and "after" not in line), None)
    stopped = next((line for line in lines if line["kind"] == "stopped"), None)
    cpu_request = next((pod["cpu_request"] for pod in pods["generator"] if pod.get("cpu_request")), None)
    return {"steps": results, "complete": done and [result["id"] for result in results] == planned,
            "start": start, "pods": pods,
            "traffic_check": check and {key: value for key, value in check.items() if key not in ("kind", "profile")},
            "ended_early": stopped and {"reason": stopped["reason"], "after": stopped.get("after"),
                                        "not_measured": stopped["steps"]},
            "generator_cpu_request": cpu_request or GENERATOR_RESOURCES[arch]["cpu"]}


def profile_record(result):
    """What summary.json and conditions.json record of a profile beyond its
    steps."""
    return {"complete": result["complete"], "traffic_check": result["traffic_check"],
            "ended_early": result["ended_early"], "generator_cpu_request": result["generator_cpu_request"]}


def explain_not_run(targets, plan, profiles, cases, results):
    """Gives each target that is not measured because its step was not run
    after the load generator stopped its profile early that reason."""
    not_run = {step: result["ended_early"]["reason"] for result in results.values() if result["ended_early"]
               for step in result["ended_early"]["not_measured"]}
    step_ids = {(spec["profile"], spec["case"], spec["rate"]): spec["id"]
                for profile in profiles for spec in steps(plan, profile, cases)}
    for target in targets:
        step = step_ids.get((target["profile"], target["case"], target["rate"]))
        if target["verdict"] == "not measured" and step in not_run:
            target["reason"] = f"{step} was not run: {not_run[step]}"
    return targets


def node_text(node):
    if node is None:
        return "-"
    return f"{node['instance_type']} ({node['arch']}, {node['zone']})"


def traffic_check_text(check):
    """What the traffic check found, for people: `-` when the load generator
    did none."""
    if check is None:
        return "-"
    names = {"plain": "plain", "tls": "TLS"}
    return ", ".join(f"{names[name]} HTTP {port['status']}" if port["answered"]
                     else f"{names[name]} no answer ({port['error']})" for name, port in check["ports"].items())


def gke_markdown(results):
    """The part of summary.md that only a GKE run has: where each profile
    ran, the load generator's CPU, whether smock's traffic ports answered,
    smock's restarts, and whether the profile ended early."""
    lines = ["", "## GKE Autopilot", "",
             "| Profile | smock's node | Load generator's node | Load generator's vCPUs | Traffic check | "
             "smock restarts | Ended early |",
             "|---|---|---|---|---|---|---|"]
    notes = []
    for name, result in results.items():
        pods = result["pods"]
        smock = pods["smock"][0] if pods["smock"] else None
        generator = pods["generator"][0] if pods["generator"] else None
        restarts = "-" if smock is None else smock["restarts"]
        ended = result["ended_early"]
        lines.append(f"| {name} | {node_text(smock and pods['nodes'].get(smock['node']))} | "
                     f"{node_text(generator and pods['nodes'].get(generator['node']))} | "
                     f"{result['generator_cpu_request']} | {traffic_check_text(result['traffic_check'])} | "
                     f"{restarts} | {'yes' if ended else 'no'} |")
        if ended:
            notes.append(f"{name} ended early: {ended['reason']}. Not measured: {', '.join(ended['not_measured'])}.")
        if smock and smock["restarts"]:
            times = "time" if smock["restarts"] == 1 else "times"
            notes.append(f"smock restarted {smock['restarts']} {times} under {name} "
                         f"(last: {smock['last_termination']}): which steps its OOM kills came in is unknown, "
                         "so they are not measured.")
    if notes:
        lines += ["", *notes]
    return "\n".join(lines) + "\n"


def nodes_of(results, app):
    """The nodes the Pods of `app` (smock or generator) ran on, over every
    profile, as pod-info keeps them."""
    nodes = []
    for result in results.values():
        pods = result["pods"]
        nodes += [pods["nodes"][pod["node"]] for pod in pods[app] if pod["node"] in pods["nodes"]]
    return nodes


def distinct(values):
    """The values that are known, in order, once each, comma-separated; or
    None."""
    known = list(dict.fromkeys(value for value in values if value))
    return ", ".join(known) or None


def command_summarize(args):
    plan_path, targets_path = Path(args.plan), Path(args.targets)
    plan = read_json(plan_path)
    profiles = plan_profiles(plan, comma_list(args.profiles))
    cases = plan_cases(plan, comma_list(args.cases))
    out = Path(args.out)
    results = {profile["name"]: profile_results(out, plan, profile, cases, args.arch) for profile in profiles}
    summary = {"format": harness.FORMAT, "complete": all(result["complete"] for result in results.values()),
               "idle_rss": [], "cases": [step for result in results.values() for step in result["steps"]],
               "targets": [], "gke": {"profiles": {name: profile_record(result) for name, result in results.items()}}}
    summary["targets"] = explain_not_run(
        [harness.check_target(target, summary) for target in harness.read_targets(targets_path)],
        plan, profiles, cases, results)
    start = next((result["start"] for result in results.values() if result["start"]), None) or {}
    status = start.get("status") or {}
    smock_nodes, generator_nodes = nodes_of(results, "smock"), nodes_of(results, "generator")
    node = smock_nodes[0] if smock_nodes else None
    mix = BENCH / "requests.json"
    compute_class = COMPUTE_CLASSES[args.arch]
    # Where the Pods ran, as their nodes say; the zone the run pinned them
    # to when the nodes are unknown.
    zone = distinct(node["zone"] for node in [*smock_nodes, *generator_nodes]) or args.zone
    machine_type = distinct(node["instance_type"] for node in smock_nodes)
    conditions = {
        "format": harness.FORMAT,
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "smock": {"version": status.get("version"), "commit": status.get("commit"),
                  "toolchain": status.get("toolchain"), "image": args.smock_image, "sha256": args.smock_sha256},
        "definitions": {"directory": "bench/definitions", "digest": status.get("digest"),
                        "mocks": status.get("mocks")},
        "request_mix": {"file": harness.shown_path(mix), "sha256": harness.sha256_file(mix),
                        "weights": {request["name"]: request["weight"] for request in read_json(mix)["requests"]}},
        "plan": {"file": harness.shown_path(plan_path), "sha256": harness.sha256_file(plan_path)},
        "targets": {"file": harness.shown_path(targets_path), "sha256": harness.sha256_file(targets_path)},
        "note": (f"Measured on GKE Autopilot in {zone or args.region}, on {args.arch} nodes "
                 f"({machine_type or 'of an unknown machine type'}): smock in a {compute_class} Pod with each "
                 "profile's limits as its requests, and oha in a Pod on another node in its zone, over the Pod "
                 "network. A GKE run does not measure idle RSS, peak memory or CPU throttling; OOM kills come from "
                 "smock's restarts."),
        "machine": {"architecture": args.arch,
                    "cpu_model": f"GKE Autopilot {node['instance_type'] if node else 'node'}",
                    "cpus": int(node["cpus"]) if node and str(node["cpus"]).isdigit() else None,
                    "kernel": node["kernel"] if node else None},
        "gke": {"arch": args.arch, "region": args.region, "zone": zone, "pinned_zone": args.zone,
                "compute_class": compute_class, "machine_type": machine_type,
                "generator_machine_type": distinct(node["instance_type"] for node in generator_nodes),
                "cluster_version": args.cluster_version,
                "profiles": {name: {**profile_record(result), **result["pods"]}
                             for name, result in results.items()}},
        "load_generator": {"name": "oha", "version": start.get("oha"), "image": args.generator_image,
                           "resources": GENERATOR_RESOURCES[args.arch]},
        "profiles": profiles,
        "cases": [{key: spec[key] for key in (
            "id", "profile", "protocol", "connection", "cpu_limit", "memory_limit", "rate", "ramp_s",
            "duration_s", "tail_s", "connections", "idle_connections")}
            for profile in profiles for spec in steps(plan, profile, cases)],
        "overrides": {},
    }
    harness.write_json(out / "summary.json", summary)
    harness.write_json(out / "conditions.json", conditions)
    (out / "summary.md").write_text(harness.summary_markdown(summary, conditions) + gke_markdown(results))
    return 0


def command_stopped(args):
    stopped = next((line for line in generator_lines(args.log) if line["kind"] == "stopped"), None)
    if stopped:
        count = len(stopped["steps"])
        print(f"{stopped['reason']}; {count} step{'' if count == 1 else 's'} not measured")
    return 0


def command_plan(args):
    plan = read_json(args.plan)
    profiles = plan_profiles(plan, comma_list(args.profiles))
    cases = plan_cases(plan, comma_list(args.cases))
    for profile in profiles:
        specs = steps(plan, profile, cases)
        if specs:
            print(profile["name"], len(specs), job_deadline_s(plan, specs))
    return 0


def command_estimate(args):
    plan = read_json(args.plan)
    profiles = plan_profiles(plan, comma_list(args.profiles))
    cases = plan_cases(plan, comma_list(args.cases))
    text, problem = estimate(plan, profiles, cases, args.region, args.arch, args.time_limit_s)
    print(text)
    if problem:
        raise GkeError(problem)
    return 0


def command_manifests(args):
    plan = read_json(args.plan)
    [profile] = plan_profiles(plan, [args.profile])
    cases = plan_cases(plan, comma_list(args.cases))
    rendered = manifests(plan, profile, cases, args.arch, args.zone, args.smock_image, args.generator_image,
                         args.smock_deadline_s)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, document in rendered.items():
        (out / name).write_text(json.dumps(document, indent=2) + "\n")
    return 0


def command_pod_info(args):
    print(json.dumps(pod_info(read_json(args.pods), read_json(args.nodes)), indent=2))
    return 0


def command_elf_arch(args):
    print(elf_arch(args.file))
    return 0


def command_names_commit(args):
    if not names_commit(args.file, args.commit):
        raise GkeError(f"{args.file} does not name commit {args.commit} in its build information, so it is built "
                       "from another commit")
    return 0


def command_check_dockerfiles(args):
    found = [(path, number, text) for path in args.files for number, text in run_instructions(path)]
    for path, number, text in found:
        print(f"{path}:{number}: {text}", file=sys.stderr)
    if found:
        raise GkeError("the images may only copy: a RUN instruction would run programs of the image's architecture, "
                       "which a build for another architecture than this machine's cannot run without emulation")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="gke.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan", help="list the profiles a run runs: name, steps, the Job's deadline (s)")
    planning.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    planning.add_argument("--profiles", help="only these profiles, comma-separated (default: every profile)")
    planning.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    planning.set_defaults(handler=command_plan)
    estimating = commands.add_parser("estimate", help="say how long a run takes and what it costs")
    estimating.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    estimating.add_argument("--profiles", help="only these profiles, comma-separated (default: every profile)")
    estimating.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    estimating.add_argument("--region", required=True, help="the region, such as us-central1")
    estimating.add_argument("--arch", required=True, choices=("arm64", "amd64"), help="the nodes' architecture")
    estimating.add_argument("--time-limit-s", type=int, required=True,
                            help="seconds after which the watchdog deletes the cluster")
    estimating.set_defaults(handler=command_estimate)
    rendering = commands.add_parser("manifests", help="write the Kubernetes objects of one profile")
    rendering.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    rendering.add_argument("--profile", required=True, help="the profile")
    rendering.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    rendering.add_argument("--arch", required=True, choices=("arm64", "amd64"), help="the nodes' architecture")
    rendering.add_argument("--zone", help="the zone smock and the load generator run in (default: Autopilot "
                                          "chooses smock's, and the load generator follows it)")
    rendering.add_argument("--smock-image", required=True, help="smock's image, by digest")
    rendering.add_argument("--generator-image", required=True, help="the load generator's image, by digest")
    rendering.add_argument("--smock-deadline-s", type=int, required=True,
                           help="how long smock's Pod may run, in seconds: the time left until the run's time limit")
    rendering.add_argument("--out", required=True, help="the directory to write them to")
    rendering.set_defaults(handler=command_manifests)
    info = commands.add_parser("pod-info", help="print what to keep of the Pods and their nodes")
    info.add_argument("pods", help="kubectl get pods -o json")
    info.add_argument("nodes", help="kubectl get nodes -o json")
    info.set_defaults(handler=command_pod_info)
    summarizing = commands.add_parser("summarize", help="write summary.json, summary.md and conditions.json")
    summarizing.add_argument("--plan", required=True, help="the plan the run ran")
    summarizing.add_argument("--targets", default=str(BENCH / "targets.json"),
                             help="the targets to check (default: bench/targets.json)")
    summarizing.add_argument("--profiles",
                             help="the profiles the run ran, comma-separated (default: every profile)")
    summarizing.add_argument("--cases", help="the cases the run ran, comma-separated (default: every case)")
    summarizing.add_argument("--region", required=True)
    summarizing.add_argument("--zone", help="the zone the run pinned its Pods to, if it did")
    summarizing.add_argument("--arch", required=True, choices=("arm64", "amd64"))
    summarizing.add_argument("--started-at", required=True)
    summarizing.add_argument("--finished-at", required=True)
    summarizing.add_argument("--cluster-version")
    summarizing.add_argument("--smock-image", help="smock's image digest")
    summarizing.add_argument("--smock-sha256", help="the SHA-256 of the smock binary in the image")
    summarizing.add_argument("--generator-image", help="the load generator's image digest")
    summarizing.add_argument("out", help="the run's results: raw/<profile>/generator.log and pods.json")
    summarizing.set_defaults(handler=command_summarize)
    stopping = commands.add_parser("stopped", help="print why the load generator stopped its profile early and how "
                                                    "many steps it did not run; nothing when it did not")
    stopping.add_argument("log", help="the load generator's log: raw/<profile>/generator.log")
    stopping.set_defaults(handler=command_stopped)
    reading = commands.add_parser("elf-arch", help="print the architecture of an ELF executable: amd64 or arm64")
    reading.add_argument("file", help="the executable, which is not run")
    reading.set_defaults(handler=command_elf_arch)
    naming = commands.add_parser("names-commit", help="fail if a smock binary's build information does not "
                                                       "name the commit (the binary is not run)")
    naming.add_argument("file", help="the smock binary")
    naming.add_argument("commit", help="the commit, as `git rev-parse --short=12` prints it")
    naming.set_defaults(handler=command_names_commit)
    checking = commands.add_parser("check-dockerfiles", help="fail, naming them, if the Dockerfiles have a RUN "
                                                             "instruction")
    checking.add_argument("files", nargs="+", help="the Dockerfiles")
    checking.set_defaults(handler=command_check_dockerfiles)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (GkeError, harness.BenchError) as error:
        print(f"gke: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
