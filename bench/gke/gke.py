#!/usr/bin/env python3
"""The parts of the GKE Autopilot run of the release benchmark that need no
cloud: scripts/gke-bench.sh calls it, and so does the load generator
(bench/gke/generator.py) for the steps of its profile.

usage:
  python3 bench/gke/gke.py plan [options]        the profiles a run runs, with their steps
  python3 bench/gke/gke.py estimate [options]    how long a run takes and what it costs
  python3 bench/gke/gke.py manifests [options]   the Kubernetes objects of one profile
  python3 bench/gke/gke.py pod-info [options] PODS NODES   what to keep of the Pods and their nodes
  python3 bench/gke/gke.py node-cpu [options]     what to keep of the CPU of the node it runs on
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


def smock_name(profile_name, variant=None):
    """The name of smock's Pod and Service under a profile, and of a
    variant's when it is given: each profile has its own, so that a lookup
    of its name cannot get the address of the previous profile's Service,
    deleted just before, as under autopilot-min on 2026-10-14 (its load
    went to the address of autopilot-burst-min's Service, and nothing
    answered)."""
    return f"smock-{profile_name}" + (f"-{variant}" if variant else "")


# A variant of smock, which a run can measure against others on one node:
# a label, which names its Pod and Service, and the image of its binary.
# The label is short enough that smock-<profile>-<label> still names a
# Service under most profiles.
VARIANT_LABEL = re.compile(r"[a-z]([-a-z0-9]{0,14}[a-z0-9])?")

# How many times the load generator measures each variant's ladder, unless
# told otherwise.
DEFAULT_ROUNDS = 4


# What a variant may do otherwise than the others: run without the init
# container that prints its node's CPU, and without the load generator's
# scrape of its /metrics a second into each step.
VARIANT_OPTIONS = ("no-init", "no-first-second")

# How many variants a run can compare on one node: the namespace's quota
# and the load generator's time grow with each.
MIN_VARIANTS, MAX_VARIANTS = 2, 4


def parse_variant(text):
    """A variant as --variant gives it, LABEL=IMAGE[,no-init][,no-first-second]:
    {label, image, init, first_second}."""
    label, equals, rest = text.partition("=")
    image, *options = rest.split(",")
    if not equals or not image:
        raise GkeError(f"--variant {text}: give it as LABEL=IMAGE[,no-init][,no-first-second]")
    if not VARIANT_LABEL.fullmatch(label):
        raise GkeError(f"variant label {label}: use 1 to 16 lowercase letters, digits and hyphens, starting with a "
                       "letter and ending with a letter or digit")
    for option in options:
        if option not in VARIANT_OPTIONS:
            raise GkeError(f"variant {label}: no option {option}; there are {' and '.join(VARIANT_OPTIONS)}")
    return {"label": label, "image": image, "init": "no-init" not in options,
            "first_second": "no-first-second" not in options}


def parse_variants(texts):
    """The variants --variant gives, in its order, the first the baseline:
    parse_variant's, each with its own label; [] without any."""
    variants = [parse_variant(text) for text in texts or []]
    if variants and not MIN_VARIANTS <= len(variants) <= MAX_VARIANTS:
        raise GkeError(f"a run compares {MIN_VARIANTS} to {MAX_VARIANTS} variants, not {len(variants)}")
    labels = [variant["label"] for variant in variants]
    for label in dict.fromkeys(labels):
        if labels.count(label) > 1:
            raise GkeError(f"variant {label} is given twice: give each its own label")
    return variants


# The load generator's Pod, by the nodes' architecture: oha used at most
# about 1 vCPU at 50,000 requests a second over plain HTTP in the arm64
# probe of 2026-10-14; TLS needs more. On x86 a vCPU is a hyperthread, and
# with 4 the load generator fell behind its schedule at 20,000 requests a
# second and above (the amd64 run of 2026-10-14), so it has 6 there. Either
# fits an 8-vCPU node (7910m allocatable on ek-standard-8 and
# e4a-standard-8 in those runs) with at least 1 vCPU left for Autopilot's
# own Pods on it, so that the quotas the run checks, of nodes of 8 vCPUs
# (four by default: GKE_BENCH_NEEDED_CPUS in scripts/gke-bench.sh), hold.
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
# With variants, how long the load generator may take to scrape the
# /metrics of an idle variant, a neighbour of the one under load, before
# and after each run: an idle smock on the node answers in milliseconds.
NEIGHBOUR_SCRAPE_S = 1


# What a run costs: on-demand prices of Autopilot Pods, which are billed for
# their requests, in USD an hour before tax, from PRICES_URL on PRICES_DATE;
# and the cluster management fee, the same in every region. A billing
# account's free tier ($74.40 a month) covers the fee of one Autopilot or
# zonal cluster. Both architectures' Pods run on Autopilot's
# container-optimized compute platform: x86 ones by default, Arm ones
# through the built-in autopilot-arm compute class (GKE's documentation of
# the built-in compute classes, 2026-10-13). The pricing page bills that
# platform's Pods at one rate table for both architectures ("Pods that use
# the Autopilot container-optimized compute platform"); its Scale-Out Arm
# Pod rates are those of another compute class, on other machines. The
# prices are those of the regions with Arm Pods (ARM_REGIONS in
# scripts/gke-bench.sh) and of Tokyo; another region's are us-central1's
# plus UNKNOWN_REGION_MARGIN.
PRICES_URL = "https://cloud.google.com/kubernetes-engine/pricing"
PRICES_DATE = "2026-10-16"
CLUSTER_FEE_PER_HOUR = 0.10
POD_PRICES_PER_HOUR = {
    "us-central1": {"vcpu": 0.0445, "memory_gib": 0.0049225, "ephemeral_gib": 0.0001389},
    "us-east1": {"vcpu": 0.0445, "memory_gib": 0.0049225, "ephemeral_gib": 0.0001389},
    "us-west1": {"vcpu": 0.0445, "memory_gib": 0.0049225, "ephemeral_gib": 0.0001389},
    "europe-west1": {"vcpu": 0.049, "memory_gib": 0.0054202, "ephemeral_gib": 0.0001529},
    "europe-west2": {"vcpu": 0.0573, "memory_gib": 0.0063421, "ephemeral_gib": 0.0001789},
    "europe-west4": {"vcpu": 0.049, "memory_gib": 0.0054202, "ephemeral_gib": 0.0001529},
    "asia-southeast1": {"vcpu": 0.0549, "memory_gib": 0.0060729, "ephemeral_gib": 0.0001713},
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
# With variants, about how long each after the first takes to start on the
# node of the first, whose images that node has but its own, and to be
# checked there; and to scrape an idle neighbour's /metrics.
VARIANT_START_S = 30
EXPECTED_NEIGHBOUR_SCRAPE_S = 0.1
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


def idle_settle_s(plan, profile):
    """How long the load generator lets smock idle, once it is ready, before
    it reads smock's idle RSS under `profile`: the plan's settle time when
    the plan measures idle RSS under the profile, as bench/bench.py does
    (under each profile its idle_rss names, or each without names); else
    None, and it does not read it."""
    idle = plan.get("idle_rss")
    if not idle or profile["name"] not in idle.get("profiles", [profile["name"]]):
        return None
    return idle["settle_s"]


def check_counts(variants, rounds):
    """Fails unless a run can have `variants` (1, or as many as it compares)
    and `rounds`."""
    if not 1 <= variants <= MAX_VARIANTS:
        raise GkeError(f"a run measures 1 to {MAX_VARIANTS} variants, not {variants}")
    if rounds < 1:
        raise GkeError(f"the load generator measures each variant in at least 1 round, not {rounds}")


def runs(specs, variants=1, rounds=1):
    """Each run of the steps `specs`, in the order the load generator makes
    them, as far as their time goes: with `variants`, each variant's run of
    each step in each of `rounds` rounds."""
    return specs * (variants * rounds)


def job_deadline_s(plan, profile, specs, variants=1, rounds=1):
    """The load generator Job's activeDeadlineSeconds under `profile`, with
    as many `variants` and `rounds` as it runs: each run's load and
    analysis, and, beside the run of one variant, the scrapes of each other
    one, idle, before and after it; its start and the settle time once; and
    the traffic check of each variant before the first step, with one after
    a step."""
    made = runs(specs, variants, rounds)
    return round(load_s(plan, made) + len(made) * (STEP_ANALYSIS_S + 2 * (variants - 1) * NEIGHBOUR_SCRAPE_S) +
                 GENERATOR_START_S + (idle_settle_s(plan, profile) or 0) +
                 (variants + TRAFFIC_CHECKS - 1) * TRAFFIC_CHECK_S)


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


# How smock's Pods and the load generator's run: as a user of no
# privilege, with nothing to write but what they print.
POD_SECURITY = {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532,
                "seccompProfile": {"type": "RuntimeDefault"}}
SMOCK_SECURITY = {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                  "capabilities": {"drop": ["ALL"]}}


def smock_objects(profile, arch, zone, generator_image, smock_deadline_s, image, variant=None):
    """smock's Service and Pod under `profile`, from `image`; a variant's,
    {label, init, ...}, when it is given."""
    name = smock_name(profile["name"], variant and variant["label"])
    labels = {"app": SMOCK}
    pod_labels = {**labels, "profile": profile["name"], **({"variant": variant["label"]} if variant else {})}
    limits = {"cpu": profile["cpu_limit"], "memory": profile["memory_limit"],
              "ephemeral-storage": SMOCK_EPHEMERAL_STORAGE}
    service = {
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels},
        "spec": {"type": "ClusterIP", "selector": pod_labels,
                 "ports": [{"name": "plain", "port": 80, "targetPort": 8080},
                           {"name": "tls", "port": 443, "targetPort": 8443},
                           {"name": "admin", "port": 9090, "targetPort": 9090}]},
    }
    pod = {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": pod_labels},
        "spec": {
            # Restarted in place after an OOM kill, as a Deployment's Pod
            # would be, until the deadline.
            "restartPolicy": "Always",
            "activeDeadlineSeconds": smock_deadline_s,
            "nodeSelector": node_selector(arch, zone),
            # A variant's Pod on the node of the profile's others, so that
            # they differ in nothing but themselves: through the hostname,
            # which Autopilot allows as a topology key, where a nodeSelector
            # on it is restricted. The first matches its own labels, so it
            # may go anywhere. No anti-affinity: Autopilot rejects it below
            # 0.5 vCPU.
            **({"affinity": {"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{
                "labelSelector": {"matchLabels": {**labels, "profile": profile["name"]}},
                "topologyKey": "kubernetes.io/hostname"}]}}} if variant else {}),
            "enableServiceLinks": False,
            "automountServiceAccountToken": False,
            "terminationGracePeriodSeconds": 5,
            "securityContext": POD_SECURITY,
            # With smock's limits, so that the Pod asks for no more than
            # smock does: Autopilot bills a Pod for the larger of its init
            # containers and the sum of its containers. A no-init variant
            # has none, and the same limits.
            **({} if variant and not variant["init"] else {"initContainers": [{
                "name": "node-cpu", "image": generator_image, "command": ["python3", "/bench/gke/gke.py", "node-cpu"],
                "resources": {"requests": limits, "limits": limits},
                "securityContext": SMOCK_SECURITY,
            }]}),
            "containers": [{
                "name": "smock", "image": image, "args": ["serve"],
                "env": [{"name": "SMOCK_DIR", "value": "/definitions"},
                        {"name": "SMOCK_ADMIN_AUTH", "value": "off"}],
                "ports": [{"name": "plain", "containerPort": 8080}, {"name": "tls", "containerPort": 8443},
                          {"name": "admin", "containerPort": 9090}],
                "resources": {"requests": limits, "limits": limits},
                "readinessProbe": {"httpGet": {"path": "/readyz", "port": 9090}, "periodSeconds": 5,
                                   "failureThreshold": 2},
                "securityContext": SMOCK_SECURITY,
            }],
        },
    }
    return [service, pod]


def service_host(profile, variant=None):
    """The host name of smock's Service under `profile`, or of a variant's
    (its label)."""
    return f"{smock_name(profile['name'], variant)}.{NAMESPACE}.svc.cluster.local"


def generator_env(profile, cases, variants, rounds):
    """The load generator's environment (generator.py's): smock's Service
    as TARGET; or, with `variants`, VARIANTS, each one's label, Service and
    whether to scrape smock a second into each step, in order, and the
    number of ROUNDS."""
    common = [{"name": "PROFILE", "value": profile["name"]},
              {"name": "CASES", "value": ",".join(case["name"] for case in cases)}]
    if not variants:
        return [{"name": "TARGET", "value": service_host(profile)}, *common]
    return [*common,
            {"name": "VARIANTS", "value": json.dumps([{"label": variant["label"],
                                                       "target": service_host(profile, variant["label"]),
                                                       "first_second": variant["first_second"]}
                                                      for variant in variants])},
            {"name": "ROUNDS", "value": str(rounds)}]


def manifests(plan, profile, cases, arch, zone, smock_image, generator_image, smock_deadline_s, variants=None,
              rounds=DEFAULT_ROUNDS):
    """The objects of one profile: {file name: object}. namespace.json holds
    the namespace and its quota, smock.json smock's Service and Pod,
    generator.json the load generator's Job. Both Pods run on nodes of
    `arch`, in `zone` when it is given; else Autopilot chooses smock's zone,
    and the load generator runs in the same one, on another node. Before
    smock starts, an init container from the load generator's image prints
    the CPU of smock's node (gke.py node-cpu), which the run keeps.

    smock runs in a Pod of its own, not a Deployment, so that it can have a
    deadline (`smock_deadline_s`, the time left until the run's time limit,
    which counts from when its node accepts it): like the load generator's
    Job, it stops being billed by itself even when neither the run nor its
    watchdog is left to delete the cluster.

    With `variants` (parse_variant's, the first the baseline), smock-<label>.json
    holds each variant's Service and Pod, from its image, in place of
    smock.json."""
    if smock_deadline_s < 1:
        raise GkeError(f"smock's Pod needs a deadline of at least 1 s, not {smock_deadline_s}")
    if variants:
        check_counts(len(variants), rounds)
    for variant in variants or []:
        name = smock_name(profile["name"], variant["label"])
        if not DNS_LABEL.fullmatch(name):
            raise GkeError(f"variant {variant['label']} under profile {profile['name']} cannot name a Kubernetes "
                           f"Service ({name}): give it a shorter label")
    labels = {"app": SMOCK}
    namespace = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NAMESPACE}}
    # Nothing billed apart from the Pods: no load balancer, node port or
    # volume claim, and no more Pods than the run needs: each smock Pod and
    # the load generator's, with two to spare.
    quota = {
        "apiVersion": "v1", "kind": "ResourceQuota",
        "metadata": {"name": "smock-bench", "namespace": NAMESPACE},
        "spec": {"hard": {"services.loadbalancers": "0", "services.nodeports": "0", "persistentvolumeclaims": "0",
                          "pods": str(len(variants or [None]) + 3)}},
    }
    if variants:
        smock = {f"smock-{variant['label']}.json": smock_objects(profile, arch, zone, generator_image,
                                                                 smock_deadline_s, variant["image"], variant)
                 for variant in variants}
    else:
        smock = {"smock.json": smock_objects(profile, arch, zone, generator_image, smock_deadline_s, smock_image)}
    specs = steps(plan, profile, cases)
    job = {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": f"generator-{profile['name']}", "namespace": NAMESPACE,
                     "labels": {"app": "smock-bench-generator", "profile": profile["name"]}},
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": job_deadline_s(plan, profile, specs, len(variants or [None]),
                                                    rounds if variants else 1),
            "template": {
                "metadata": {"labels": {"app": "smock-bench-generator", "profile": profile["name"]}},
                "spec": {
                    "restartPolicy": "Never",
                    "nodeSelector": node_selector(arch, zone),
                    "enableServiceLinks": False,
                    "automountServiceAccountToken": False,
                    "securityContext": POD_SECURITY,
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
                        "env": generator_env(profile, cases, variants, rounds),
                        "resources": {"requests": GENERATOR_RESOURCES[arch], "limits": GENERATOR_RESOURCES[arch]},
                        "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
                    }],
                },
            },
        },
    }
    return {
        "namespace.json": {"apiVersion": "v1", "kind": "List", "items": [namespace, quota]},
        **{file: {"apiVersion": "v1", "kind": "List", "items": items} for file, items in smock.items()},
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
    """The prices of the Pods in a region, and how they were found."""
    if region in POD_PRICES_PER_HOUR:
        return POD_PRICES_PER_HOUR[region], f"{region}, on-demand prices of {PRICES_DATE}, before tax"
    base = POD_PRICES_PER_HOUR["us-central1"]
    prices = {name: price * UNKNOWN_REGION_MARGIN for name, price in base.items()}
    margin = round((UNKNOWN_REGION_MARGIN - 1) * 100)
    return prices, (f"{region}: us-central1's prices plus {margin}%, on-demand prices of {PRICES_DATE}, before "
                    "tax; this region's own are not here")


# The Pods of each architecture, for people.
POD_KINDS = {"amd64": "amd64 (x86) Pods", "arm64": "arm64 Pods"}


def estimate(plan, profiles, cases, region, arch, time_limit_s, variants=1, rounds=1):
    """How long a run on `arch` takes and what it costs, for people, and why
    it does not fit in its time limit, or None; with as many `variants` of
    smock, each in a Pod of its own under each profile's limits all through
    the profile, and `rounds`, as it measures."""
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
        made = runs(specs, variants, rounds)
        load = load_s(plan, made) + \
            len(made) * (EXPECTED_ANALYSIS_S + 2 * (variants - 1) * EXPECTED_NEIGHBOUR_SCRAPE_S) + \
            (idle_settle_s(plan, profile) or 0) + 60
        start = PROFILE_START_S + (variants - 1) * VARIANT_START_S
        generator_s += load
        profiles_s += start + load
        smock_cost += variants * smock_prices[profile["name"]] * (start + load) / 3600
        generator_cost += generator_price * load / 3600
    lifetime_s = CLUSTER_CREATE_S + profiles_s + CLUSTER_DELETE_S
    fee = CLUSTER_FEE_PER_HOUR * lifetime_s / 3600
    expected = fee + smock_cost + generator_cost
    at_most = (CLUSTER_FEE_PER_HOUR + generator_price + variants * max(smock_prices.values())) * \
        (time_limit_s + CLUSTER_DELETE_S) / 3600
    profiles_text = f"{len(profiles)} profile{'' if len(profiles) == 1 else 's'} one after the other"
    text = "\n".join([
        f"Cost estimate for {POD_KINDS[arch]} ({source}; {PRICES_URL}):",
        f"- The cluster: about {round(lifetime_s / 60)} minutes, from its creation to its deletion. Its management "
        f"fee of ${CLUSTER_FEE_PER_HOUR:.2f} an hour comes to ${fee:.2f}, or $0 while the billing account's free "
        "tier covers it (one Autopilot or zonal cluster).",
        (f"- smock's Pods, {profiles_text}: ${smock_cost:.2f}." if variants == 1 else
         f"- smock's Pods, one for each of {variants} variants on one node, {profiles_text}: ${smock_cost:.2f}."),
        f"- The load generator's Pod ({generator['cpu']} vCPU, {generator['memory']}): about "
        f"{round(generator_s / 60)} minutes, ${generator_cost:.2f}.",
        ("- Artifact Registry: two images of about 100 MB for under an hour, within the free 0.5 GB a month."
         if variants == 1 else
         f"- Artifact Registry: up to {variants + 1} images of about 100 MB while the run lasts (the load "
         "generator's, and smock's for each distinct binary, which share all but its layer), within the free 0.5 GB "
         "a month."),
        "- No load balancer, static IP or volume: the run never makes one.",
        f"Expected: about ${expected:.2f}, the cluster existing for about {round(lifetime_s / 60)} minutes.",
        f"At most: ${at_most:.2f}, if it ran until the time limit ({round(time_limit_s / 60)} minutes), when the "
        "watchdog deletes the cluster, and during the deletion.",
        "If neither the run nor its watchdog could delete the cluster (the machine running them went down), its "
        f"Pods still stop within minutes of the time limit, and the cluster costs its fee, "
        f"${CLUSTER_FEE_PER_HOUR:.2f} an hour, "
        "until it is deleted: the next run's checks name it.",
        *(["Arm Pods are priced as x86 ones: autopilot-arm runs them on Autopilot's container-optimized compute "
           "platform, which the pricing page bills at one rate for both architectures."] if arch == "arm64" else []),
    ])
    needed_s = lifetime_s + TIME_LIMIT_MARGIN_S
    if needed_s <= time_limit_s:
        return text, None
    fewer = "profiles or cases" if variants == 1 else "profiles, cases, variants or rounds"
    return text, (f"the run needs about {round(needed_s / 60)} minutes with a margin, more than the time limit of "
                  f"{round(time_limit_s / 60)} minutes: run fewer {fewer}, or raise the limit")


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


# The labels of a node that say what it is and where, and the type of its
# boot disk, whose regional quota scripts/gke-bench.sh checks.
NODE_LABELS = {"instance_type": "node.kubernetes.io/instance-type", "arch": "kubernetes.io/arch",
               "zone": "topology.kubernetes.io/zone", "machine_family": "cloud.google.com/machine-family",
               "compute_class": "cloud.google.com/compute-class", "boot_disk": "cloud.google.com/gke-boot-disk"}


def pod_info(pod_list, node_list, restarts=True):
    """What a run keeps of its Pods and of the nodes they ran on: where and
    how they ran, the load generator's CPU request, and nothing that names
    the project, such as image references or provider IDs. smock's
    restarts are None (unknown) unless `restarts`: the OOM kills of a
    profile come from them, so only those read at the profile's end count,
    and a run that stops before then keeps what it read earlier."""
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
                "restarts": container.get("restartCount", 0) if restarts else None,
                "last_termination": terminated.get("reason")})
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


# Where Linux describes the CPUs, and the mitigations of their
# vulnerabilities, one file each.
CPUINFO = "/proc/cpuinfo"
VULNERABILITIES = "/sys/devices/system/cpu/vulnerabilities"

# The fields of /proc/cpuinfo that say which CPU a processor is: on x86 its
# vendor, family, model and stepping (a virtual machine's model name, such
# as "Intel(R) Xeon(R) CPU @ 2.20GHz", may not tell its generation); on
# arm64, which has no model name, its implementer, architecture, variant,
# part and revision.
CPU_IDENTITY = ("vendor_id", "cpu family", "model", "stepping", "CPU implementer", "CPU architecture",
                "CPU variant", "CPU part", "CPU revision")

# The CPU flags that make TLS fast, by the line of /proc/cpuinfo that lists
# them: on x86, AES-NI and its vector form for AES-GCM, AVX2 for ChaCha20
# and the elliptic curves, and the SHA extensions for the handshake's
# hashes; on arm64, the AES, polynomial multiply and SHA-2 instructions.
TLS_FLAGS = {"flags": ("aes", "avx2", "sha_ni", "vaes"), "Features": ("aes", "pmull", "sha2")}


def read_node_cpu(cpuinfo=CPUINFO, vulnerabilities=VULNERABILITIES):
    """The CPU of the node this runs on, as node_cpu keeps it, from the
    files `cpuinfo` and `vulnerabilities`, and None; or None and why it
    could not be read."""
    try:
        return node_cpu(Path(cpuinfo).read_text(), read_vulnerabilities(vulnerabilities)), None
    except Exception as failure:  # noqa: BLE001 - whatever it is, the run goes on
        return None, f"cannot read {cpuinfo}: {failure}"


def node_cpu(cpuinfo, vulnerabilities):
    """What a run keeps of the CPU of a node, from the text of its
    /proc/cpuinfo, of its first processor (a node's vCPUs are all of one
    model): the model name (on arm64, its implementer and part), the fields
    that say which CPU it is, the microcode (None on arm64), whether it has
    each flag of TLS_FLAGS, and `vulnerabilities`, what the kernel says of
    each of the CPU's vulnerabilities, {name: mitigation}, or None."""
    fields = {}
    for line in cpuinfo.strip().split("\n\n", 1)[0].splitlines():
        name, colon, value = line.partition(":")
        if colon:
            fields.setdefault(name.strip(), value.strip())
    model_name = fields.get("model name")
    if model_name is None and "CPU implementer" in fields and "CPU part" in fields:
        model_name = f"implementer {fields['CPU implementer']}, part {fields['CPU part']}"
    flags = next(({flag: flag in fields[line].split() for flag in wanted}
                  for line, wanted in TLS_FLAGS.items() if line in fields), None)
    return {"model_name": model_name,
            **{name.lower().replace(" ", "_"): fields[name] for name in CPU_IDENTITY if name in fields},
            "microcode": fields.get("microcode"), "flags": flags, "vulnerabilities": vulnerabilities}


def read_vulnerabilities(directory):
    """What the kernel says of each of the CPU's vulnerabilities, from the
    files of `directory`, {name: text}, or None when it cannot be read."""
    try:
        return {path.name: path.read_text().strip() for path in sorted(Path(directory).iterdir()) if path.is_file()}
    except OSError:
        return None


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
    """What one profile's run left: its steps, smock's idle RSS when the
    load generator read it, whether it ran each step of the plan, what the
    load generator said at its start, its Pods and the CPU of each node
    they ran on (`cpu` of each node, None when unknown), whether smock's
    traffic ports answered before the first step, whether the load
    generator stopped the profile early and which steps it did not run,
    and the load generator Pod's CPU request (as the Pod had it, else as
    the run asked)."""
    raw = Path(out) / "raw" / profile["name"]
    lines = generator_lines(raw / "generator.log")
    pods = read_json(raw / "pods.json") if (raw / "pods.json").exists() else {"smock": [], "generator": [],
                                                                               "nodes": {}}
    start = next((line for line in lines if line["kind"] == "start"), None)
    # smock's node's, from what its init container printed, which the run
    # kept; the load generator's, from its start line.
    printed = next((line for line in generator_lines(raw / "smock-node-cpu.log") if line["kind"] == "node-cpu"), {})
    cpus = {"smock": printed.get("cpu"), "generator": (start or {}).get("node_cpu")}
    for node in pods["nodes"].values():
        node["cpu"] = None
    for app, cpu in cpus.items():
        for pod in pods[app]:
            if cpu and pod["node"] in pods["nodes"]:
                pods["nodes"][pod["node"]]["cpu"] = cpu
    results = [line["result"] for line in lines if line["kind"] == "step"]
    idle = [line["idle"] for line in lines if line["kind"] == "idle-rss"]
    # smock's container restarts after an OOM kill: with none at the
    # profile's end, the kernel never killed it; with some, which step they
    # came in is unknown, and so is whether there were any when the run
    # did not read them at the end (None).
    smock = pods["smock"]
    oom_kills = 0 if len(smock) == 1 and smock[0]["restarts"] == 0 else None
    for result in [*results, *idle]:
        result["memory"]["oom_kills"] = oom_kills
    planned = [spec["id"] for spec in steps(plan, profile, cases)]
    done = any(line["kind"] == "done" for line in lines)
    # The check before the first step, not one after a step.
    check = next((line for line in lines if line["kind"] == "traffic-check" and "after" not in line), None)
    stopped = next((line for line in lines if line["kind"] == "stopped"), None)
    cpu_request = next((pod["cpu_request"] for pod in pods["generator"] if pod.get("cpu_request")), None)
    return {"steps": results, "idle_rss": idle, "complete": done and [result["id"] for result in results] == planned,
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


def node_text(node):
    if node is None:
        return "-"
    model = (node.get("cpu") or {}).get("model_name")
    return f"{node['instance_type']} ({node['arch']}, {node['zone']})" + (f", {model}" if model else "")


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
        restarts = harness.shown(smock and smock["restarts"])
        ended = result["ended_early"]
        lines.append(f"| {name} | {node_text(smock and pods['nodes'].get(smock['node']))} | "
                     f"{node_text(generator and pods['nodes'].get(generator['node']))} | "
                     f"{result['generator_cpu_request']} | {traffic_check_text(result['traffic_check'])} | "
                     f"{restarts} | {'yes' if ended else 'no'} |")
        if ended:
            notes.append(f"{name} ended early: {ended['reason']}. Not measured: {', '.join(ended['not_measured'])}.")
        if smock and smock["restarts"] is None:
            notes.append(f"smock's restarts under {name} are unknown, since the run did not read them at the "
                         "profile's end: its OOM kills are not measured.")
        elif smock and smock["restarts"]:
            times = "time" if smock["restarts"] == 1 else "times"
            notes.append(f"smock restarted {smock['restarts']} {times} under {name} "
                         f"(last: {smock['last_termination']}): which steps its OOM kills came in is unknown, "
                         "so they are not measured.")
    if notes:
        lines += ["", *notes]
    return "\n".join(lines) + "\n"


def stopped_record(results, reason, profile):
    """Where a run that stopped before its end stopped, and why: the
    profile it was running and the last step it measured there; or None
    when it did not stop."""
    if not reason:
        return None
    steps = results[profile]["steps"] if profile in results else []
    return {"reason": reason, "profile": profile, "after": steps[-1]["id"] if steps else None}


def stopped_markdown(stopped):
    """What summary.md says of a run that stopped before its end."""
    where = ""
    if stopped["profile"]:
        step = f"after its step {stopped['after']}" if stopped["after"] else "before its first step"
        where = f" under profile {stopped['profile']}, {step}"
    return f"**Stopped early:** the run stopped{where}: {stopped['reason']}. Nothing after that was measured."


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
    stopped = stopped_record(results, args.stopped, args.stopped_under)
    summary = {"format": harness.FORMAT, "complete": all(result["complete"] for result in results.values()),
               "idle_rss": [idle for result in results.values() for idle in result["idle_rss"]],
               "cases": [step for result in results.values() for step in result["steps"]],
               "targets": [], "gke": {"profiles": {name: profile_record(result) for name, result in results.items()},
                                      "stopped": stopped}}
    planned = [spec for profile in profiles for spec in steps(plan, profile, cases)]
    summary["targets"] = harness.explain_steps_not_run(
        harness.check_targets(harness.read_targets(targets_path), args.arch, summary), summary, planned)
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
        "plan": harness.plan_record(plan_path),
        "targets": harness.file_record(targets_path),
        "note": (f"Measured on GKE Autopilot in {zone or args.region}, on {args.arch} nodes "
                 f"({machine_type or 'of an unknown machine type'}): smock in a {compute_class} Pod with each "
                 "profile's limits as its requests, and oha in a Pod on another node in its zone, over the Pod "
                 "network. What smock used comes from its own /metrics, its process and cgroup metrics, scraped "
                 "right before and right after each step, and a second into it: its CPU time and throttling during "
                 "the step and its first second, from its container's cgroup; how long it waited for a CPU, the "
                 "time the CFS quota held it back included, and its node's steal time; its RSS at the step's start "
                 "and end, the larger as its max; and the most "
                 "memory its container had used by the step's end (memory.peak), since smock started under the "
                 "profile, earlier steps included. Idle RSS is read once smock has been ready for the settle "
                 "time, before any load. OOM kills come from smock's restarts at the profile's end."),
        # The node type, as before the nodes' CPUs were recorded, so that
        # comparing with such a run shows no other machine: each node's CPU
        # is in its own record, which compare.py reads for smock's nodes.
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
            "duration_s", "tail_s", "connections", "idle_connections")} for spec in planned],
        "overrides": {},
    }
    harness.write_json(out / "summary.json", summary)
    harness.write_json(out / "conditions.json", conditions)
    markdown = harness.summary_markdown(summary, conditions, stopped and stopped_markdown(stopped))
    (out / "summary.md").write_text(markdown + gke_markdown(results))
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
    variants, rounds = counts(args)
    for profile in profiles:
        specs = steps(plan, profile, cases)
        if specs:
            print(profile["name"], len(specs), job_deadline_s(plan, profile, specs, variants, rounds))
    return 0


def command_estimate(args):
    plan = read_json(args.plan)
    profiles = plan_profiles(plan, comma_list(args.profiles))
    cases = plan_cases(plan, comma_list(args.cases))
    variants, rounds = counts(args)
    text, problem = estimate(plan, profiles, cases, args.region, args.arch, args.time_limit_s, variants, rounds)
    print(text)
    if problem:
        raise GkeError(problem)
    return 0


def command_manifests(args):
    plan = read_json(args.plan)
    [profile] = plan_profiles(plan, [args.profile])
    cases = plan_cases(plan, comma_list(args.cases))
    variants = parse_variants(args.variant)
    if variants and args.smock_image:
        raise GkeError("give smock's image with --smock-image or --variant, not both")
    if not variants and not args.smock_image:
        raise GkeError("manifests needs smock's image: --smock-image, or --variant for each variant")
    if args.rounds is not None and not variants:
        raise GkeError("--rounds needs --variant: without variants, the load generator measures each step once")
    rendered = manifests(plan, profile, cases, args.arch, args.zone, args.smock_image, args.generator_image,
                         args.smock_deadline_s, variants, DEFAULT_ROUNDS if args.rounds is None else args.rounds)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, document in rendered.items():
        (out / name).write_text(json.dumps(document, indent=2) + "\n")
    return 0


def command_pod_info(args):
    print(json.dumps(pod_info(read_json(args.pods), read_json(args.nodes), not args.without_restarts), indent=2))
    return 0


def command_node_cpu(args):
    """Prints a node-cpu line: the CPU of the node it runs on, as node_cpu
    keeps it, or None and why. It succeeds whatever it reads, since smock's
    Pod runs it in an init container, which must succeed for smock to
    start."""
    cpu, error = read_node_cpu(args.cpuinfo, args.vulnerabilities)
    print(json.dumps({"kind": "node-cpu", "cpu": cpu, **({"error": error} if error else {})}), flush=True)
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


def counts(args):
    """How many variants and rounds the options of add_counts give, checked."""
    if args.rounds is not None and args.variants == 1:
        raise GkeError("--rounds needs --variants: smock alone is measured once")
    rounds = 1 if args.variants == 1 else DEFAULT_ROUNDS if args.rounds is None else args.rounds
    check_counts(args.variants, rounds)
    return args.variants, rounds


def add_counts(parser):
    """The options of how many variants a run measures, and in how many
    rounds."""
    parser.add_argument("--variants", type=int, default=1,
                        help=f"how many variants of smock the run measures on one node, 2 to {MAX_VARIANTS} "
                             "(default: 1, smock alone)")
    parser.add_argument("--rounds", type=int,
                        help="how many times the load generator measures each variant's steps (default: "
                             f"{DEFAULT_ROUNDS}); only with --variants")


def main(argv):
    parser = argparse.ArgumentParser(prog="gke.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan", help="list the profiles a run runs: name, steps, the Job's deadline (s)")
    planning.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    planning.add_argument("--profiles", help="only these profiles, comma-separated (default: every profile)")
    planning.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    add_counts(planning)
    planning.set_defaults(handler=command_plan)
    estimating = commands.add_parser("estimate", help="say how long a run takes and what it costs")
    estimating.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    estimating.add_argument("--profiles", help="only these profiles, comma-separated (default: every profile)")
    estimating.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    estimating.add_argument("--region", required=True, help="the region, such as us-central1")
    estimating.add_argument("--arch", required=True, choices=("arm64", "amd64"), help="the nodes' architecture")
    estimating.add_argument("--time-limit-s", type=int, required=True,
                            help="seconds after which the watchdog deletes the cluster")
    add_counts(estimating)
    estimating.set_defaults(handler=command_estimate)
    rendering = commands.add_parser("manifests", help="write the Kubernetes objects of one profile")
    rendering.add_argument("--plan", required=True, help="the plan, such as bench/plan-autopilot.json")
    rendering.add_argument("--profile", required=True, help="the profile")
    rendering.add_argument("--cases", help="only these cases, comma-separated (default: every case)")
    rendering.add_argument("--arch", required=True, choices=("arm64", "amd64"), help="the nodes' architecture")
    rendering.add_argument("--zone", help="the zone smock and the load generator run in (default: Autopilot "
                                          "chooses smock's, and the load generator follows it)")
    rendering.add_argument("--smock-image", help="smock's image, by digest")
    rendering.add_argument("--variant", action="append",
                           help="LABEL=IMAGE[,no-init][,no-first-second]: a variant of smock to measure on the node "
                                "of the others, from its image, by digest; 2 to 4 of them, in place of --smock-image, "
                                "the first the baseline")
    rendering.add_argument("--generator-image", required=True, help="the load generator's image, by digest")
    rendering.add_argument("--rounds", type=int,
                           help=f"how many times to measure each variant's steps (default: {DEFAULT_ROUNDS}); only "
                                "with --variant")
    rendering.add_argument("--smock-deadline-s", type=int, required=True,
                           help="how long smock's Pod may run, in seconds: the time left until the run's time limit")
    rendering.add_argument("--out", required=True, help="the directory to write them to")
    rendering.set_defaults(handler=command_manifests)
    info = commands.add_parser("pod-info", help="print what to keep of the Pods and their nodes")
    info.add_argument("pods", help="kubectl get pods -o json")
    info.add_argument("nodes", help="kubectl get nodes -o json")
    info.add_argument("--without-restarts", action="store_true",
                      help="keep smock's restarts as unknown (null), as read before the profile's end")
    info.set_defaults(handler=command_pod_info)
    cpu = commands.add_parser("node-cpu", help="print, as a JSON line, what to keep of the CPU of the node it runs on; "
                                              "it succeeds whatever it can read")
    cpu.add_argument("--cpuinfo", default=CPUINFO, help=f"the CPUs' description (default: {CPUINFO})")
    cpu.add_argument("--vulnerabilities", default=VULNERABILITIES,
                     help=f"the kernel's mitigations of the CPU's vulnerabilities (default: {VULNERABILITIES})")
    cpu.set_defaults(handler=command_node_cpu)
    summarizing = commands.add_parser("summarize", help="write summary.json, summary.md and conditions.json")
    summarizing.add_argument("--plan", required=True, help="the plan the run ran")
    summarizing.add_argument("--targets", default=str(BENCH / "targets.json"),
                             help="the targets to check, those of --arch (default: bench/targets.json)")
    summarizing.add_argument("--profiles",
                             help="the profiles the run ran, comma-separated (default: every profile)")
    summarizing.add_argument("--cases", help="the cases the run ran, comma-separated (default: every case)")
    summarizing.add_argument("--region", required=True)
    summarizing.add_argument("--zone", help="the zone the run pinned its Pods to, if it did")
    summarizing.add_argument("--arch", required=True, choices=("arm64", "amd64"),
                             help="the nodes' architecture, whose targets are checked")
    summarizing.add_argument("--started-at", required=True)
    summarizing.add_argument("--finished-at", required=True)
    summarizing.add_argument("--cluster-version")
    summarizing.add_argument("--smock-image", help="smock's image digest")
    summarizing.add_argument("--smock-sha256", help="the SHA-256 of the smock binary in the image")
    summarizing.add_argument("--generator-image", help="the load generator's image digest")
    summarizing.add_argument("--stopped", help="why the run stopped before its end, when it did")
    summarizing.add_argument("--stopped-under", help="the profile the run was running when it stopped")
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
