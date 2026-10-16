#!/usr/bin/env python3
"""The parts of the GKE Autopilot run of the release benchmark that need no
cloud: scripts/gke-bench.sh calls it, and so does the load generator
(bench/gke/generator.py) for the steps of its profile.

usage:
  python3 bench/gke/gke.py plan [options]        the profiles a run runs, with their steps
  python3 bench/gke/gke.py estimate [options]    how long a run takes and what it costs
  python3 bench/gke/gke.py manifests [options]   the Kubernetes objects of one profile
  python3 bench/gke/gke.py pod-info [options] PODS NODES   what to keep of the Pods and their nodes
  python3 bench/gke/gke.py placement PODS [options]   fail unless a profile's smock Pods share a node, at its limits
  python3 bench/gke/gke.py node-cpu [options]     what to keep of the CPU of the node it runs on
  python3 bench/gke/gke.py summarize [options] OUT   summary.json, summary.md and conditions.json
  python3 bench/gke/gke.py samples [options] OUT     split a run of variants into one run of each sample
  python3 bench/gke/gke.py same-node [options] OUT   compare the variants: same-node.json and same-node.md
  python3 bench/gke/gke.py stopped LOG            why the load generator stopped its profile early, if it did
  python3 bench/gke/gke.py elf-arch FILE          the architecture of an executable, amd64 or arm64
  python3 bench/gke/gke.py names-commit FILE COMMIT   fail if smock's build information does not name COMMIT
  python3 bench/gke/gke.py check-dockerfiles FILE...   fail if a Dockerfile has a RUN instruction

A run measures one smock, or compares 2 to 4 variants of it, each in a Pod
of its own on one node, which one load generator measures in turn, round
after round: manifests then takes --variant LABEL=IMAGE[,no-init][,no-first-second]
for each, the first the baseline, and --rounds N; plan and estimate take
--variants N and --rounds N. Its results split into samples, one
variant's pass over the steps in one round each, which summarize
summarizes as runs of smock alone, and same-node compares them.
"""

import argparse
import functools
import importlib.util
import json
import math
import re
import shutil
import statistics
import struct
import sys
from fractions import Fraction
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


# A variant of smock, which a run can measure against others on one node,
# each in turn: a label, which names its Pod and Service, the image of its
# binary, and its options. The label is short enough (16 characters at
# most) that smock-<profile>-<label> still names a Service under most
# profiles; manifests checks it does under the profile it renders.
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
# With variants: about how long each variant after the first takes to
# start on the first one's node, which has every image but its own, and to
# be checked there; and how long a scrape of an idle neighbour's /metrics
# takes.
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


def run_steps(specs, variants=1, rounds=1):
    """The step of each run the load generator makes of `specs`: each step
    once for each of `variants` in each of `rounds` rounds. They are not in
    the order the runs are made (generator.run_order's), which
    job_deadline_s and estimate do not need: a run's time does not depend
    on its place."""
    return specs * (variants * rounds)


def job_deadline_s(plan, profile, specs, variants=1, rounds=1):
    """The load generator Job's activeDeadlineSeconds under `profile`, with
    as many `variants` and `rounds` as it runs: each run's load and
    analysis, and, beside the run of one variant, the scrapes of each other
    one, idle, before and after it; its start and the settle time once; and
    the traffic check of each variant before the first step, with one after
    a step."""
    made = run_steps(specs, variants, rounds)
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

    With `variants` (parse_variants', the first the baseline), each has
    smock-<label>.json in place of smock.json: its own Service and Pod,
    from its image, on the node of the profile's other variants (a no-init
    variant without the init container); the quota counts each one's Pod,
    and the load generator measures each in turn over `rounds` rounds (its
    VARIANTS and ROUNDS), with time for them all. `smock_image` is not used
    then."""
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
        made = run_steps(specs, variants, rounds)
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
    and a run that stops before then keeps what it read earlier. A smock
    Pod of a variant also keeps its variant and the requests and limits
    its container named smock was admitted with (None without such a
    container), which Autopilot may have changed; any other smock Pod keeps
    neither, as before there were variants."""
    info = {"smock": [], "generator": [], "nodes": {}}
    for pod in pod_list["items"]:
        labels = pod["metadata"].get("labels", {})
        status = pod.get("status", {})
        if labels.get("app") == SMOCK:
            statuses = status.get("containerStatuses") or [{}]
            container = next((container for container in statuses if container.get("name") == "smock"), statuses[0])
            terminated = container.get("lastState", {}).get("terminated") or {}
            entry = {"name": pod["metadata"]["name"], "node": pod["spec"].get("nodeName"),
                     "ready": any(condition["type"] == "Ready" and condition["status"] == "True"
                                  for condition in status.get("conditions", [])),
                     "restarts": container.get("restartCount", 0) if restarts else None,
                     "last_termination": terminated.get("reason")}
            if labels.get("variant"):
                spec = next((container for container in pod["spec"].get("containers", [])
                             if container.get("name") == "smock"), None)
                admitted = None if spec is None else spec.get("resources", {})
                entry["variant"] = labels["variant"]
                entry["resources"] = None if admitted is None else {"requests": admitted.get("requests"),
                                                                    "limits": admitted.get("limits")}
            info["smock"].append(entry)
        elif labels.get("app") == "smock-bench-generator":
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


# What each suffix of a Kubernetes quantity multiplies its number by.
QUANTITY_SUFFIXES = {"Ki": 1 << 10, "Mi": 1 << 20, "Gi": 1 << 30, "Ti": 1 << 40, "Pi": 1 << 50, "Ei": 1 << 60,
                     "n": Fraction(1, 10 ** 9), "u": Fraction(1, 10 ** 6), "m": Fraction(1, 1000), "k": 10 ** 3,
                     "M": 10 ** 6, "G": 10 ** 9, "T": 10 ** 12, "P": 10 ** 15, "E": 10 ** 18}
QUANTITY = re.compile(r"(\d+\.?\d*|\.\d+)(?:[eE]([-+]?\d+)|(" + "|".join(QUANTITY_SUFFIXES) + r"))?")


def quantity(text):
    """The exact value of a Kubernetes quantity, such as 250m, 0.25, 512Mi
    or 536870912, which the API may write otherwise than the plan does; or
    None when `text` is not one."""
    match = QUANTITY.fullmatch(str(text))
    if not match:
        return None
    value = Fraction(match[1])
    if match[2]:
        return value * Fraction(10) ** int(match[2])
    return value * QUANTITY_SUFFIXES[match[3]] if match[3] else value


def and_list(items):
    """`items` for people: a, b and c."""
    return " and ".join([", ".join(items[:-1]), items[-1]] if len(items) > 1 else items)


def profile_pods(info, profile):
    """The smock Pods of `profile` of those pod-info kept (`info`)."""
    return [pod for pod in info["smock"] if pod["name"] == smock_name(profile["name"], pod.get("variant"))]


def who(pod):
    return f"variant {pod['variant']}" if pod.get("variant") else f"Pod {pod['name']}"


def placement_problems(info, profile):
    """Why the smock Pods of `profile`, as pod-info keeps them (`info`),
    cannot be compared with each other, one sentence each; none when every
    one has a node, the same, and was admitted with the profile's limits
    as its CPU and memory requests and limits."""
    pods = profile_pods(info, profile)
    if not pods:
        return [f"no smock Pod of profile {profile['name']} is in what the run read of its Pods"]
    problems = [f"{who(pod)} has no node yet" for pod in pods if not pod["node"]]
    nodes = {}
    for pod in pods:
        if pod["node"]:
            nodes.setdefault(pod["node"], []).append(pod.get("variant") or pod["name"])
    if len(nodes) > 1:
        problems.append(f"the smock Pods of {profile['name']} are on {len(nodes)} nodes, not one: "
                        + ", ".join(f"{and_list(names)} on {node}" for node, names in nodes.items()))
    return problems + limit_problems(pods, profile)


def limit_problems(pods, profile):
    """Which of smock's `pods` were not admitted with `profile`'s limits as
    their CPU and memory requests and limits, and how, one sentence each."""
    problems = []
    wanted = {"cpu": ("CPU", profile["cpu_limit"]), "memory": ("memory", profile["memory_limit"])}
    for pod in pods:
        if pod.get("resources") is None:
            problems.append(f"{who(pod)}'s admitted requests and limits are unknown")
            continue
        for kind, admitted in (("request", pod["resources"].get("requests")),
                               ("limit", pod["resources"].get("limits"))):
            for resource, (name, limit) in wanted.items():
                value = (admitted or {}).get(resource)
                if value is None or quantity(value) is None or quantity(value) != quantity(limit):
                    problems.append(f"{who(pod)}'s {name} {kind} was admitted as {value or 'none'}, not the "
                                    f"profile's {limit}")
    return problems


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


# Where a run of variants keeps what it read of each, and where samples
# writes their samples. A run of variants keeps in raw/<profile>/, as one of
# smock alone does, the load generator's log (generator.log, with each line
# about smock tagged with its variant) and the profile's Pods as pod-info
# keeps them (pods.json); and each variant's own files in
# raw/<profile>/<label>/: smock's log (smock.log) and, but for a no-init
# variant, what its init container printed of its node's CPU
# (smock-node-cpu.log). A sample, one variant's pass over the steps in one
# round, is samples/<round>-<label>/, an ordinary run's results directory.
SAMPLES = "samples"


def sample_lines(lines, round_, label):
    """The load generator's lines of a sample, `label`'s pass over the steps
    in `round_`, as the load generator prints them for smock alone: the
    variant's own lines, but its idle RSS only in round 1, when it was read,
    before any load, and of its runs and the checks after them only those
    of `round_`. A stopped line lists the steps the sample did not run,
    after the last it did, and the sample has none when it ran them all."""
    kept, last = [], None
    for line in lines:
        if line["kind"] == "stopped":
            left = [run["id"] for run in line.get("runs") or [] if (run["round"], run["variant"]) == (round_, label)]
            if left:
                kept.append({"kind": "stopped", "profile": line.get("profile"), "reason": line["reason"],
                             "after": last, "steps": left})
        elif line.get("variant") == label and not (line["kind"] == "idle-rss" and round_ != 1) and \
                line.get("round", round_) == round_:
            kept.append(line)
            if line["kind"] == "step":
                last = line["result"]["id"]
    return kept


def sample_pods(info, profile_name, label):
    """What pod-info kept of the profile's Pods (`info`), as a sample of
    `label` has it: the variant's own smock Pod alone, as in a run of smock
    alone, the load generator's, and the nodes they ran on."""
    smock = [pod for pod in info["smock"]
             if pod.get("variant") == label and pod["name"] == smock_name(profile_name, label)]
    used = {pod["node"] for pod in [*smock, *info["generator"]]}
    return {"smock": smock, "generator": info["generator"],
            "nodes": {name: node for name, node in info["nodes"].items() if name in used}}


def variants_of(lines, info):
    """The labels of the variants of a run under one profile, in the load
    generator's order, the baseline first, from its lines; then those of
    any other smock Pod of a variant, as when the load generator printed
    nothing."""
    labels = [line["variant"] for line in lines if line.get("variant")]
    return list(dict.fromkeys([*labels, *(pod["variant"] for pod in info["smock"] if pod.get("variant"))]))


def rounds_of(lines):
    """The rounds of a run of variants under one profile, as far as its
    load generator's lines tell: those of its runs, and of the runs a stop
    left out."""
    stopped = [run["round"] for line in lines if line["kind"] == "stopped" for run in line.get("runs") or []]
    return max([1, *(line["round"] for line in lines if line.get("round")), *stopped])


def write_samples(out, profiles):
    """Splits each profile's raw/<profile>/ of a run of variants under `out`
    into its samples, samples/<round>-<label>/raw/<profile>/: the sample's
    lines of the load generator's log (sample_lines), its Pods
    (sample_pods), and the files the run kept of its variant. Every sample
    of the run has each profile that the run has anything of, so that one
    a profile did not reach is incomplete there. Returns the samples, as
    (round, label, directory), by round, then in the variants' order."""
    raws = {}
    for profile in profiles:
        raw = Path(out) / "raw" / profile["name"]
        if raw.is_dir():
            info = read_json(raw / "pods.json") if (raw / "pods.json").exists() else {"smock": [], "generator": [],
                                                                                       "nodes": {}}
            raws[profile["name"]] = (raw, generator_lines(raw / "generator.log"), info)
    labels = list(dict.fromkeys(label for _, lines, info in raws.values() for label in variants_of(lines, info)))
    if not labels:
        raise GkeError(f"{Path(out) / 'raw'} holds no run of variants of smock: samples splits the results of a run "
                       "that compared variants (manifests' --variant)")
    rounds = max(rounds_of(lines) for _, lines, _ in raws.values())
    shutil.rmtree(Path(out) / SAMPLES, ignore_errors=True)
    samples = []
    for round_ in range(1, rounds + 1):
        for label in labels:
            directory = Path(out) / SAMPLES / f"{round_}-{label}"
            for name, (raw, lines, info) in raws.items():
                kept = directory / "raw" / name
                kept.mkdir(parents=True)
                if (raw / label).is_dir():
                    for path in (raw / label).iterdir():
                        if path.is_file():
                            shutil.copyfile(path, kept / path.name)
                (kept / "generator.log").write_text("".join(json.dumps(line) + "\n"
                                                            for line in sample_lines(lines, round_, label)))
                harness.write_json(kept / "pods.json", sample_pods(info, name, label))
            samples.append((round_, label, directory))
    return samples


def command_samples(args):
    plan = read_json(args.plan)
    profiles = plan_profiles(plan, comma_list(args.profiles))
    plan_cases(plan, comma_list(args.cases))
    for round_, label, directory in write_samples(args.out, profiles):
        print(round_, label, directory)
    return 0


@functools.cache
def compare_module():
    """bench/compare.py, for what it says of a step that measured nothing
    and of the conditions of two runs, loaded as it loads bench/bench.py,
    but only when needed: the load generator's image, whose Pods run this
    file too, holds no compare.py."""
    spec = importlib.util.spec_from_file_location("bench_compare", BENCH / "compare.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# A sample's directory: its round, then its variant's label.
SAMPLE_NAME = re.compile(r"([1-9][0-9]*)-(" + VARIANT_LABEL.pattern + ")")

# The share of its CPU limit from which smock is saturated: it queues, and
# what its CPU comes to a request says less of its code.
SATURATED = 0.9

# The sign test's p at or below which a variant's CPU a request differs
# from the baseline's: the usual 5%, which 6 pairs that all agree reach.
SIGNIFICANT_P = 0.05


def read_samples(out):
    """The samples of a run of variants under `out`, as summarize left them:
    {(round, label): (summary, conditions)}, by round; None for one it did
    not summarize."""
    compare = compare_module()
    root = Path(out) / SAMPLES
    samples = {}
    for directory in root.iterdir() if root.is_dir() else []:
        match = SAMPLE_NAME.fullmatch(directory.name)
        if match and directory.is_dir():
            try:
                samples[int(match[1]), match[2]] = \
                    compare.read_run(directory) if (directory / "summary.json").exists() else None
            except compare.CompareError as error:
                raise GkeError(str(error)) from error
    return dict(sorted(samples.items(), key=lambda item: item[0][0]))


def median(values):
    return statistics.median(values) if values else None


def percent_change(before, after):
    return None if before is None or after is None or not before else (after - before) / before * 100


def percent_text(change):
    """A change in percent, for people, as compare.py shows one."""
    if change is None:
        return "-"
    change = round(change, 1)
    return "0%" if change == 0 else f"{change:+.1f}".removesuffix(".0") + "%"


def sign_test_p(higher, lower):
    """The exact two-sided p of a sign test: how likely a split of the
    pairs that differ at least as uneven as `higher` against `lower` is,
    were either as likely as the other."""
    pairs = higher + lower
    if not pairs:
        return 1.0
    return min(1.0, 2 * sum(math.comb(pairs, k) for k in range(min(higher, lower) + 1)) / 2 ** pairs)


def run_record(sample, round_, label, profile_name, step_id, line):
    """What one run, `label`'s at `step_id` in `round_`, measured, from its
    sample (summary and conditions, or None) and its step line of the load
    generator (`line`, or None): smock's CPU, throttling, waits, the node's
    steal time (another variant's count, when this one's smock has none)
    and p99; why it measured nothing, or None; and why it did not run, or
    None: left out when the load generator stopped the profile early, not
    reported by the load generator, or in a sample with no summary."""
    compare = compare_module()
    run = f"{label} round {round_}"
    record = {"round": round_, "us_per_request": None, "utilization": None, "throttled_periods": None,
              "periods": None, "scheduling_delay_s": None, "node_steal_s": None, "p99_ms": None, "not_measured": None,
              "not_run": None}
    case = sample and next((case for case in sample[0]["cases"] if case["id"] == step_id), None)
    if case is None:
        ended = sample and (sample[0]["gke"]["profiles"].get(profile_name) or {}).get("ended_early")
        record["not_run"] = "left out" if ended and step_id in ended["not_measured"] else \
            "not reported" if sample else "no summary"
        record["not_measured"] = {"left out": f"the {run} run was left out: {(ended or {}).get('reason')}",
                                  "not reported": f"the load generator did not report the {run} run",
                                  "no summary": f"the sample {round_}-{label} has no summary"}[record["not_run"]]
        return record
    cpu = case.get("smock_cpu") or {}
    steal = (line or {}).get("node_steal_s") or {label: cpu.get("node_steal_s")}
    record.update(us_per_request=cpu.get("us_per_request"), utilization=cpu.get("utilization"),
                  throttled_periods=cpu.get("throttled_periods"), periods=cpu.get("periods"),
                  scheduling_delay_s=cpu.get("scheduling_delay_s"),
                  node_steal_s=next((value for value in [steal.get(label), *steal.values()] if value is not None),
                                    None),
                  p99_ms=case["latency_ms"]["p99"],
                  not_measured=compare.not_measured(case, run) or (
                      None if cpu.get("us_per_request") is not None else
                      f"smock's /metrics gave no CPU time a request in the {run} run"))
    return record


def saturated(run):
    return (run["utilization"] or 0) >= SATURATED


def variant_at_step(runs, baseline_runs=None):
    """What a variant's `runs` of one step, one a round, measured: the
    median, lowest and highest CPU a request of those measured, how many
    there are, the CFS periods they were throttled in and their periods,
    the median waits and p99; and, against the baseline's runs
    (`baseline_runs`, None for the baseline's own), the change of the
    median and of each run against the baseline's in the same round, each
    pair saturated when either run used SATURATED of its CPU limit."""
    measured = [run for run in runs if run["not_measured"] is None]
    values = [run["us_per_request"] for run in measured]
    counted = [run for run in measured if run["throttled_periods"] is not None and run["periods"] is not None]

    def median_of(key, digits):
        known = [run[key] for run in measured if run[key] is not None]
        return None if not known else round(median(known), digits)

    record = {"runs": runs, "n": len(measured), "median_us_per_request": median_of("us_per_request", 2),
              "min_us_per_request": min(values, default=None), "max_us_per_request": max(values, default=None),
              "throttled_periods": sum(run["throttled_periods"] for run in counted) if counted else None,
              "periods": sum(run["periods"] for run in counted) if counted else None,
              "scheduling_delay_s": median_of("scheduling_delay_s", 4), "node_steal_s": median_of("node_steal_s", 2),
              "p99_ms": median_of("p99_ms", 3)}
    if baseline_runs is None:
        return {**record, "saturated": sum(saturated(run) for run in measured)}
    baseline_values = [run["us_per_request"] for run in baseline_runs if run["not_measured"] is None]
    change = percent_change(median(baseline_values), median(values))
    pairs = [{"round": run["round"], "change_percent": round(percent_change(base["us_per_request"],
                                                                             run["us_per_request"]), 2),
              "saturated": saturated(base) or saturated(run)}
             for base, run in zip(baseline_runs, runs, strict=True)
             if base["not_measured"] is None and run["not_measured"] is None]
    return {**record, "change_percent": None if change is None else round(change, 2), "pairs": pairs,
            "higher": sum(pair["change_percent"] > 0 for pair in pairs),
            "saturated": sum(pair["saturated"] for pair in pairs)}


def fewest_pairs():
    """How many pairs that differ, all one way, the sign test needs for a p
    of SIGNIFICANT_P or less."""
    return next(pairs for pairs in range(1, 64) if sign_test_p(pairs, 0) <= SIGNIFICANT_P)


def verdict(pairs, spread=None):
    """Whether a variant used more CPU a request than another (the
    baseline), over its unsaturated `pairs` of runs of a profile: the
    median change and its range, how many were higher and how many lower,
    the sign test's p of that, and the smallest p as many pairs that differ
    could give; higher or lower when p is at most SIGNIFICANT_P, no clear
    difference when it is above it but could have been at most it, and too
    few pairs to decide when it could not, as with fewer than
    fewest_pairs() pairs that differ, so that a lack of pairs does not read
    as a lack of difference. With the A/A `spread` of the profile
    (a_a_spread's), a median change inside it is no clear difference too,
    whatever p is: runs of one binary differ that much on the node."""
    changes = [pair["change_percent"] for pair in pairs if not pair["saturated"]]
    higher, lower = sum(change > 0 for change in changes), sum(change < 0 for change in changes)
    p, smallest = sign_test_p(higher, lower), sign_test_p(higher + lower, 0)
    middle = None if not changes else round(median(changes), 2)
    inside = None if spread is None or middle is None else \
        spread["min_change_percent"] <= middle <= spread["max_change_percent"]
    return {"pairs": len(changes), "higher": higher, "lower": lower, "median_change_percent": middle,
            "min_change_percent": min(changes, default=None), "max_change_percent": max(changes, default=None),
            "sign_test_p": p, "smallest_p": smallest, "a_a_spread": spread, "inside_a_a_spread": inside,
            "verdict": None if not changes else "too few pairs to decide" if smallest > SIGNIFICANT_P else
            "no clear difference" if p > SIGNIFICANT_P or inside else "higher" if higher > lower else "lower"}


def pairings(variants):
    """The variants of one binary, by its sha256, each against the first
    variant with it (the baseline when it is one of them), from
    variant_records' `variants`: [(label, against, kind)], kind "same
    binary" when they also have the same options, an A/A pair, else "other
    options"."""
    found, first = [], {}
    for variant in variants:
        if not variant["sha256"]:
            continue
        other = first.setdefault(variant["sha256"], variant)
        if other is not variant:
            found.append((variant["label"], other["label"],
                          "same binary" if variant["options"] == other["options"] else "other options"))
    return found


def within_comparison(steps, label, against, kind, spread=None):
    """How the variant `label` compares with `against`, another of its
    binary, at each of a profile's `steps` (their change, pairs, how many
    higher and how many saturated, as variant_at_step has them) and over
    them all (verdict's, with the A/A `spread`)."""
    records = [{"id": step["id"], **{key: record[key] for key in ("change_percent", "pairs", "higher", "saturated")}}
               for step in steps
               for record in [variant_at_step(step["variants"][label]["runs"], step["variants"][against]["runs"])]]
    return {"label": label, "against": against, "kind": kind, "steps": records,
            "verdict": verdict([pair for record in records for pair in record["pairs"]], spread)}


def a_a_spread(within):
    """The A/A spread of a profile: the lowest and highest change of the
    unsaturated pairs of its A/A pairs (`within`, within_comparison's), how
    far runs of one binary with the same options differ on the node; or
    None without such pairs."""
    verdicts = [entry["verdict"] for entry in within if entry["kind"] == "same binary" and entry["verdict"]["pairs"]]
    if not verdicts:
        return None
    return {"min_change_percent": min(result["min_change_percent"] for result in verdicts),
            "max_change_percent": max(result["max_change_percent"] for result in verdicts)}


def placement_record(profile, info, labels, samples):
    """Where the variants ran under `profile`, and how Autopilot admitted
    them, from what pod-info kept of the Pods (`info`): each variant's
    node, whether they shared one, that node, with its CPU as the init
    container of a variant printed it (from its samples' conditions),
    whether each was admitted with the profile's limits, and why they
    cannot be compared when they cannot. A variant without the init
    container is on the node by its name."""
    name = profile["name"]
    pods = {pod.get("variant"): pod for pod in profile_pods(info, profile)}
    nodes = {label: (pods.get(label) or {}).get("node") for label in labels}
    problems = placement_problems(info, profile)
    if pods:
        problems += [f"variant {label} has no Pod in what the run read of the Pods of {name}"
                     for label in labels if label not in pods]
    shared = next(iter(set(nodes.values()))) if len(set(nodes.values())) == 1 else None
    node = info["nodes"].get(shared) if shared else None
    cpu = next((cpu for sample in samples.values() if sample and sample[1]
                for cpu in [(((sample[1]["gke"]["profiles"].get(name) or {}).get("nodes") or {}).get(shared) or {})
                            .get("cpu")] if cpu), None)
    return {"pods_read": bool(pods), "nodes": nodes, "one_node": shared is not None,
            "node": shared and {"name": shared, "instance_type": (node or {}).get("instance_type"),
                                "zone": (node or {}).get("zone"), "cpu": cpu},
            "limits_as_planned": bool(pods) and not limit_problems(list(pods.values()), profile),
            "problems": problems}


def placement_text(result):
    """Where a profile's variants ran, and whether under its limits, for
    people."""
    node = result["node"]
    if not result["pods_read"]:
        return "The run read no smock Pod under this profile."
    if node:
        cpu = compare_module().cpu_name(node["cpu"]) if node["cpu"] else "CPU unknown"
        where = (f"Every variant ran on node {node['name']}: {harness.shown(node['instance_type'])} in "
                 f"{harness.shown(node['zone'])}, {cpu}.")
    else:
        on = {}
        for label, name in result["nodes"].items():
            on.setdefault(name or "no node known", []).append(label)
        where = f"The variants ran on {len(on)} nodes: " + ", ".join(f"{and_list(labels)} on {name}"
                                                                     for name, labels in on.items()) + "."
    admitted = "Each was" if result["limits_as_planned"] else "Not every one was"
    return f"{where} {admitted} admitted with the profile's limits as its requests and limits."


def drift(steps, label):
    """How a variant's CPU a request in round 1 differs from the median of
    its later rounds at each step that has both: the median change, its
    range, and over how many steps. A first round apart from the others is
    a node or a smock that changed with time, not a variant."""
    changes = []
    for step in steps:
        first, *later = step["variants"][label]["runs"]
        values = [run["us_per_request"] for run in later if run["not_measured"] is None]
        if first["not_measured"] is None and values:
            changes.append(percent_change(median(values), first["us_per_request"]))
    rounded = [round(change, 2) for change in changes]
    return {"steps": len(changes), "median_change_percent": None if not changes else round(median(changes), 2),
            "min_change_percent": min(rounded, default=None), "max_change_percent": max(rounded, default=None)}


def drift_text(result):
    if result["rounds"] < 2:
        return "Drift: one round alone, with none to compare round 1 with."
    return ("Drift, each variant's CPU µs/request in round 1 against the median of its later rounds, step by step: "
            + "; ".join(f"{label} -" if not record["steps"] else
                        f"{label} {percent_text(record['median_change_percent'])} "
                        f"({range_text(record['min_change_percent'], record['max_change_percent'])}, "
                        f"{record['steps']} step{'' if record['steps'] == 1 else 's'})"
                        for label, record in result["drift"].items()) + ".")


# The positions a variant can hold in a step, for people: one for each of
# MAX_VARIANTS.
ORDINALS = ("first", "second", "third", "fourth")


def order_text(result):
    """In what order the variants ran, for people."""
    if not result["order"]:
        return "The load generator ran no step."
    counts = "; ".join(f"{label} {', '.join(map(str, held))}" for label, held in result["positions"].items())
    return (f"Each step ran the variants one after another, their order turned by one for each round and step. Times "
            f"each ran {and_list(list(ORDINALS[:len(result['positions'])]))}: {counts}.")


def neighbours_text(result):
    """What the idle variants used during another's run, at most, for
    people."""
    top = result["neighbours"]
    if not top:
        return "What the idle variants used during another's run is unknown."
    return (f"The idle variants used at most {top['max_cpu_s']} s of CPU during another's run: {top['variant']}, "
            f"during {top['beside']}'s run of {top['id']} in round {top['round']}.")


def profile_comparison(profile, samples, labels, baseline, rounds, lines, pairs_of_one_binary=()):
    """How the variants compare under `profile`, from their `samples`
    ({(round, label): sample}) and the load generator's lines: whether
    every sample is complete, the order of the runs and how often each
    variant held each position in a step, the most CPU an idle variant
    used during another's run, each step's runs of each variant
    (variant_at_step), each variant of one binary against the first with
    it (`pairs_of_one_binary`, pairings'), the A/A spread of those with the
    same options, each variant's verdict against the `baseline`, read
    against that spread unless the two are an A/A pair, and its drift, and
    the runs that measured nothing."""
    name = profile["name"]
    step_lines = {(line["round"], line["variant"], line["result"]["id"]): line
                  for line in lines if line["kind"] == "step" and line.get("variant")}
    planned = next(([spec for spec in sample[1]["cases"] if spec["profile"] == name]
                    for sample in samples.values() if sample and sample[1]), [])
    steps = []
    for spec in planned:
        runs = {label: [run_record(samples.get((round_, label)), round_, label, name, spec["id"],
                                   step_lines.get((round_, label, spec["id"]))) for round_ in range(1, rounds + 1)]
                for label in labels}
        steps.append({"id": spec["id"], "case": spec["id"].split("@", 1)[0], "rate": spec["rate"],
                      "variants": {label: variant_at_step(runs[label], None if label == baseline else runs[baseline])
                                   for label in labels}})
    incomplete = [f"{round_}-{label}" for round_ in range(1, rounds + 1) for label in labels
                  if not (samples.get((round_, label)) and
                          (samples[round_, label][0]["gke"]["profiles"].get(name) or {}).get("complete"))]
    ended = next((ended for sample in samples.values() if sample
                  for ended in [(sample[0]["gke"]["profiles"].get(name) or {}).get("ended_early")] if ended), None)
    # The runs in the order the load generator made them, by step, and how
    # often each variant ran first, second and so on in a step.
    order = []
    for line in step_lines.values():
        if order and (order[-1]["round"], order[-1]["id"]) == (line["round"], line["result"]["id"]):
            order[-1]["variants"].append(line["variant"])
        else:
            order.append({"round": line["round"], "id": line["result"]["id"], "variants": [line["variant"]]})
    positions = {label: [sum(entry["variants"][index:index + 1] == [label] for entry in order)
                         for index in range(len(labels))] for label in labels}
    # The most CPU an idle variant used during another's run.
    used = [(cpu_s, label, line) for line in step_lines.values()
            for label, cpu_s in (line.get("neighbours") or {}).items() if cpu_s is not None]
    top = max(used, key=lambda item: item[0], default=None)
    unmeasured = [(step["id"], label, run) for step in steps for index in range(rounds) for label in labels
                  for run in [step["variants"][label]["runs"][index]] if run["not_measured"]]
    # The A/A pairs first, for the spread the other verdicts are read
    # against.
    a_a = [within_comparison(steps, label, against, kind) for label, against, kind in pairs_of_one_binary
           if kind == "same binary"]
    spread = a_a_spread(a_a)
    within = [next(entry for entry in a_a if entry["label"] == label) if kind == "same binary" else
              within_comparison(steps, label, against, kind, spread) for label, against, kind in pairs_of_one_binary]
    same = {(entry["label"], entry["against"]) for entry in a_a}
    return {"complete": not incomplete, "incomplete": incomplete, "rounds": rounds, "order": order,
            "positions": positions,
            "neighbours": top and {"max_cpu_s": top[0], "variant": top[1], "beside": top[2]["variant"],
                                   "round": top[2]["round"], "id": top[2]["result"]["id"]},
            "steps": steps,
            "verdicts": {label: verdict([pair for step in steps for pair in step["variants"][label]["pairs"]],
                                        None if (label, baseline) in same else spread)
                         for label in labels if label != baseline},
            "within": within, "a_a_spread": spread,
            "drift": {label: drift(steps, label) for label in labels},
            "ended_early": ended and {"reason": ended["reason"],
                                      "left_out": sum(run["not_run"] == "left out" for _, _, run in unmeasured)},
            "not_measured": [{"id": step_id, "round": run["round"], "variant": label, "reason": run["not_measured"],
                              "not_run": run["not_run"]} for step_id, label, run in unmeasured]}


def periods_text(record):
    if record["throttled_periods"] is None:
        return "-"
    return f"{record['throttled_periods']:,} of {record['periods']:,}"


def us_text(record):
    if not record["n"]:
        return "-"
    return (f"{record['median_us_per_request']:.1f} ({record['min_us_per_request']:.1f}–"
            f"{record['max_us_per_request']:.1f}, {record['n']})")


def range_text(low, high):
    if low is None:
        return "-"
    return percent_text(low) if percent_text(low) == percent_text(high) else \
        f"{percent_text(low)} to {percent_text(high)}"


def p_number(p):
    return f"{p:.3f}".rstrip("0").rstrip(".")


def p_text(p):
    """A sign test's p, for people: p = 0.008, or p < 0.001."""
    return "p < 0.001" if p < 0.001 else f"p = {p_number(p)}"


SAME_NODE_COLUMNS = ("Case", "Rate", "Variant", "CPU µs/request", "Change", "Paired", "Higher", "Throttled periods",
                     "CPU wait s", "Node steal s", "p99 ms", "Saturated")


def same_node_row(step, label, record, baseline):
    """A variant's row of a step in same-node.md."""
    if label == baseline:
        paired = ["-", "-", "-"]
        saturated_text = f"{record['saturated']} of {record['n']} runs" if record["n"] else "-"
    else:
        changes = [pair["change_percent"] for pair in record["pairs"]]
        paired = [percent_text(record["change_percent"]), range_text(min(changes, default=None),
                                                                     max(changes, default=None)),
                  f"{record['higher']} of {len(changes)}" if changes else "-"]
        saturated_text = f"{record['saturated']} of {len(changes)} pairs" if changes else "-"
    cells = [step["case"], f"{step['rate']:,}", f"{label} (baseline)" if label == baseline else label,
             us_text(record), *paired, periods_text(record), harness.shown(record["scheduling_delay_s"]),
             harness.shown(record["node_steal_s"]), harness.shown(record["p99_ms"]), saturated_text]
    return "| " + " | ".join(cells) + " |"


def verdict_line(label, against, result, note=None):
    """A variant's verdict against another, for people, with a `note` on
    what the two are."""
    named = f"- {label} against {against}" + (f" ({note})" if note else "")
    if not result["pairs"]:
        return f"{named}: no pair of runs that both measured and neither saturated."
    inside = ""
    if result["inside_a_a_spread"] and result["verdict"] == "no clear difference":
        spread = result["a_a_spread"]
        inside = f" (inside the A/A spread of {range_text(spread['min_change_percent'], spread['max_change_percent'])})"
    return (f"{named}: {percent_text(result['median_change_percent'])} "
            f"({range_text(result['min_change_percent'], result['max_change_percent'])}), higher in "
            f"{result['higher']} of {result['pairs']} pairs, sign test {p_text(result['sign_test_p'])}: "
            f"{result['verdict']}{too_few_text(result)}{inside}.")


def within_lines(result, variants):
    """What same-node.md says of a profile's variants of one binary, each
    against the first with it: the question each answers."""
    if not result["within"]:
        return []
    options = {variant["label"]: ", ".join(variant["options"]) or "no option" for variant in variants}
    return ["", "Variants of one binary, each against the first variant with it, over the same pairs:", "",
            *(verdict_line(entry["label"], entry["against"], entry["verdict"],
                           "the same options, an A/A pair" if entry["kind"] == "same binary" else
                           f"{options[entry['label']]} against {options[entry['against']]}")
              for entry in result["within"])]


def too_few_text(result):
    """Why a verdict says there are too few pairs to decide, for people."""
    if result["verdict"] != "too few pairs to decide":
        return ""
    return (f" (with {result['higher'] + result['lower']} that differ, p cannot be below "
            f"{p_number(result['smallest_p'])})")


def runs_text(count):
    return f"{count} run" + ("" if count == 1 else "s")


def not_measured_lines(result):
    """What same-node.md says of a profile's runs that measured nothing:
    those that did not run, by why, and why each other one did not
    count."""
    lines = []
    ended = result["ended_early"]
    if ended:
        lines += ["", f"**Stopped early:** {ended['reason']}. {runs_text(ended['left_out'])} "
                      f"{'was' if ended['left_out'] == 1 else 'were'} left out."]
    unreported = sum(entry["not_run"] == "not reported" for entry in result["not_measured"])
    if unreported:
        lines += ["", f"The load generator did not report {runs_text(unreported)}: its Job ended before them, or "
                      "never ran."]
    unsummarized = list(dict.fromkeys(f"{entry['round']}-{entry['variant']}" for entry in result["not_measured"]
                                      if entry["not_run"] == "no summary"))
    if unsummarized:
        count = sum(entry["not_run"] == "no summary" for entry in result["not_measured"])
        many = len(unsummarized) > 1
        lines += ["", f"The sample{'s' if many else ''} {and_list(unsummarized)} "
                      f"{'have' if many else 'has'} no summary, so {'their' if many else 'its'} {runs_text(count)} "
                      f"{'are' if count > 1 else 'is'} not counted."]
    others = [entry for entry in result["not_measured"] if not entry["not_run"]]
    if others:
        lines += ["", "Not measured, and left out of the counts:", "",
                  *(f"- {entry['id']}: {entry['reason']}." for entry in others)]
    return lines


def variants_lines(report):
    """The table of same-node.md that names each variant's binary and
    options."""
    lines = ["| Variant | Commit | Version | sha256 | Options |", "|---|---|---|---|---|"]
    for variant in report["variants"]:
        name = f"{variant['label']} (baseline)" if variant["baseline"] else variant["label"]
        lines.append(f"| {name} | {harness.shown(variant['commit'])} | {harness.shown(variant['version'])} | "
                     f"{harness.shown(variant['sha256'] and variant['sha256'][:12])} | "
                     f"{', '.join(variant['options']) or '-'} |")
    return lines


def reading_lines():
    """What same-node.md says of how to read it, with the cuts its verdicts
    are made with."""
    return [
        "## Reading the comparison", "",
        "Each variant ran in a Pod of its own on one node, and one load generator measured them in turn: each round "
        "ran the profile's steps, and each step ran every variant once, one after another, their order turned by one "
        "for each round and step. A sample is one variant's steps in one round: samples/<round>-<label>/ holds its "
        "summary, which compare.py reads as a run's.", "",
        "*CPU µs/request* is the median of a variant's runs of the step, with the lowest and highest and how many runs "
        "measured it. *Change* is that median's change from the baseline's. *Paired* is the range of the changes of "
        "each run from the baseline's run of the step in the same round, and *Higher* how many of those pairs used "
        "more. *Throttled periods* adds up the CFS periods in which the quota held smock back, out of all, over the "
        "runs. *CPU wait s*, *Node steal s* and *p99 ms* are medians; - is unknown, as from a smock too old to count "
        "it. *Saturated* counts the baseline's runs, or a variant's pairs, in which a run used "
        f"{SATURATED:.0%} of its CPU limit or more: smock then queues, and its CPU a request says less of its code.",
        "",
        "Each verdict takes the pairs of every step of the profile in which neither run saturated: their median "
        "change, lowest to highest, how many were higher, and the p of an exact two-sided sign test, ties left out. "
        f"With 8 pairs that all agree, p is {p_number(sign_test_p(8, 0))}; fewer than {fewest_pairs()} pairs that "
        f"differ cannot give a p of {SIGNIFICANT_P:g} or less, and the verdict then says there are too few pairs to "
        f"decide; above {SIGNIFICANT_P:g} is no clear difference.", "",
        "Variants of one binary (one SHA-256) are also compared with the first variant that has it, over the same "
        "pairs: with the same options, an A/A pair, whose lowest to highest paired change is the A/A spread, how far "
        "runs of one binary differ on the node; with other options, what those cost. A verdict whose median change "
        "lies inside the profile's A/A spread says no clear difference, whatever its p, which same-node.json keeps.",
    ]


def same_node_markdown(report):
    """same-node.md: what ran, where and why the run stopped when it
    stopped before its end, why the variants cannot be compared when they
    cannot, each variant's binary and options, whether the samples'
    other conditions were the same, how to read the rest; and for each
    profile, where the variants ran, in what order, what the idle ones
    used, a row for each variant at each step, the runs that measured
    nothing, each variant's verdict against the baseline, each variant of
    one binary against the first with it, and each variant's drift."""
    baseline = report["baseline"]
    run = report["run"]
    lines = ["# smock variants on one node", "",
             f"Started {run['started_at']}: {len(report['variants'])} variants of smock over {run['rounds']} "
             f"round{'' if run['rounds'] == 1 else 's'}, on {run['machine']}, "
             f"{harness.known(run['load_generator'], 'a load generator of an unknown version')}, plan {run['plan']}."]
    if report["stopped"]:
        lines += ["", run_stopped_text(report["stopped"])]
    if report["problems"]:
        lines += ["", "**Not comparable:**", "", *(f"- {problem}." for problem in report["problems"])]
    lines += ["", *variants_lines(report), "", conditions_text(report["conditions"]), "", *reading_lines()]
    for profile in report["profiles"]:
        result = report["gke"]["profiles"][profile["name"]]
        lines += ["", harness.profile_heading(profile), "", placement_text(result), "", order_text(result), "",
                  neighbours_text(result), "",
                  "| " + " | ".join(SAME_NODE_COLUMNS) + " |", "|" + "---|" * len(SAME_NODE_COLUMNS)]
        for step in result["steps"]:
            lines += [same_node_row(step, label, record, baseline) for label, record in step["variants"].items()]
        lines += not_measured_lines(result)
        lines += ["", "Verdicts, over the pairs of runs of every step in which neither run saturated:", "",
                  *(verdict_line(label, baseline, verdict_result)
                    for label, verdict_result in result["verdicts"].items()),
                  *within_lines(result, report["variants"]), "", drift_text(result)]
    return "\n".join(lines) + "\n"


def summarized(samples, labels):
    """The samples with conditions, as [(name, conditions)], by round, then
    in the variants' order (`labels`, the baseline first)."""
    return [(f"{round_}-{label}", sample[1])
            for (round_, label), sample in sorted(samples.items(), key=lambda item: (item[0][0],
                                                                                    labels.index(item[0][1])))
            if sample and sample[1]]


def conditions_record(samples, labels):
    """Whether the samples had the same conditions besides smock (those
    compare.py compares two runs by) as the first that has them, the
    baseline's first when it does, and where they did not, which samples
    differ and how."""
    compare = compare_module()
    named = summarized(samples, labels)
    (reference, first), differences = named[0], {}
    for name, conditions in named[1:]:
        for condition, shown in compare.CONDITIONS:
            before, after = shown(first), shown(conditions)
            if not compare.same(condition, before, after):
                text = compare.difference(condition, before, after)
                differences.setdefault((condition, text), []).append(name)
    return {"same": not differences, "reference": reference,
            "differences": [{"condition": condition, "text": text, "samples": names}
                            for (condition, text), names in differences.items()]}


def conditions_text(conditions):
    if conditions["same"]:
        return "Besides smock, the samples had the same conditions."
    return (f"Besides smock, the samples differ from {conditions['reference']} in: "
            + "; ".join(f"{difference['text']} in {and_list(difference['samples'])}"
                        for difference in conditions["differences"]) + ".")


def given_sha256(texts):
    """The binaries --sha256 gives, LABEL=HEX each: {label: [hex, ...]}."""
    given = {}
    for text in texts or []:
        label, equals, value = text.partition("=")
        if not equals or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise GkeError(f"--sha256 {text}: give it as LABEL=HEX, the SHA-256 of the variant's binary")
        given.setdefault(label, []).append(value)
    return given


def variant_records(labels, baseline, samples, raws, sha256, no_init):
    """Each variant's binary and options, from its samples' conditions (its
    commit and version, as its smock said at the start, and the sha256 of
    the binary summarize was given), the sha256 the run gives (`sha256`,
    {label: [hex]}), whether it ran without the init container (`no_init`,
    as the run says) and whether the load generator skipped its scrape a
    second into each run; and the problems: a variant with more than one
    sha256."""
    records, problems = [], []
    for label in labels:
        smocks = [sample[1]["smock"] for (_, other), sample in samples.items()
                  if other == label and sample and sample[1]]
        values = list(dict.fromkeys([*(smock["sha256"] for smock in smocks if smock.get("sha256")),
                                     *sha256.get(label, [])]))
        if len(values) > 1:
            problems.append(f"variant {label} has {'two' if len(values) == 2 else len(values)} sha256 values, "
                            f"{and_list(values)}: which binary it ran is unknown")
        skipped = any(line["kind"] == "start" and line.get("variant") == label and line.get("first_second") is False
                      for lines in raws.values() for line in lines)
        smock = next((smock for smock in smocks if smock.get("commit")), {})
        records.append({"label": label, "baseline": label == baseline, "commit": smock.get("commit"),
                        "version": smock.get("version"), "sha256": values[0] if len(values) == 1 else None,
                        "options": [*(["no-init"] if label in no_init else []),
                                    *(["no-first-second"] if skipped else [])]})
    return records, problems


def same_node(out, baseline=None, sha256=None, no_init=()):
    """The comparison of the variants of a run under `out`, from its
    samples, each summarized, and its raw/<profile>/, with the sha256 of
    each variant's binary the run gives ({label: [hex]}) and the variants
    it ran without the init container (where and why the run stopped, when
    it stopped before its end, as it told summarize of each sample):
    same-node.json's content,
    same-node.md's, and the exit status: 2 when a variant has two sha256,
    1 when the variants did not share a node, were admitted with other
    limits than the plan's, or a sample is incomplete, else 0."""
    samples = read_samples(out)
    known = [sample for sample in samples.values() if sample and sample[1]]
    if not known:
        raise GkeError(f"{Path(out) / SAMPLES} holds no summarized sample: split the run with gke.py samples, and "
                       "summarize each sample")
    profiles = known[0][1]["profiles"]
    raws = {profile["name"]: generator_lines(Path(out) / "raw" / profile["name"] / "generator.log")
            for profile in profiles}
    labels = list(dict.fromkeys([*(line["variant"] for lines in raws.values() for line in lines
                                   if line.get("variant")), *(label for _, label in samples)]))
    baseline = baseline or labels[0]
    for label in [baseline, *(sha256 or {}), *no_init]:
        if label not in labels:
            raise GkeError(f"the run has no variant {label}: its variants are {and_list(labels)}")
    labels = [baseline, *(label for label in labels if label != baseline)]
    variants, problems = variant_records(labels, baseline, samples, raws, sha256 or {}, no_init)
    rounds = max(round_ for round_, _ in samples)
    results = {}
    for profile in profiles:
        pods = Path(out) / "raw" / profile["name"] / "pods.json"
        info = read_json(pods) if pods.exists() else {"smock": [], "generator": [], "nodes": {}}
        result = profile_comparison(profile, samples, labels, baseline, rounds, raws[profile["name"]],
                                    pairings(variants))
        placement = placement_record(profile, info, labels, samples)
        incomplete = result["incomplete"]
        if len(incomplete) == rounds * len(labels):
            placement["problems"].append("every sample is incomplete")
        elif incomplete:
            many = len(incomplete) > 1
            placement["problems"].append(f"sample{'s' if many else ''} {and_list(incomplete)} "
                                         f"{'are' if many else 'is'} incomplete")
        results[profile["name"]] = {**result, **placement}
    placed = [f"{name}: {problem}" for name, result in results.items() for problem in result["problems"]]
    status = 2 if problems else 1 if placed else 0
    problems += placed
    reference = summarized(samples, labels)[0][1]
    report = {"format": 1, "baseline": baseline, "variants": variants, "problems": problems,
              "stopped": run_stopped(samples, raws),
              "run": {"started_at": reference["started_at"], "rounds": rounds,
                      "machine": compare_module().where(reference),
                      "load_generator": reference["load_generator"]["version"], "plan": reference["plan"]["file"]},
              "conditions": conditions_record(samples, labels),
              "complete": all(result["complete"] for result in results.values()), "profiles": profiles,
              "gke": {"profiles": results}}
    return report, same_node_markdown(report), status


def run_stopped(samples, raws):
    """Where a run of variants that stopped before its end stopped, and why,
    as the runner told summarize of each sample: the profile it was
    running and its last run there ({round, variant, id}, from the load
    generator's lines, `raws`), or None before the first; None when the
    run did not stop."""
    stopped = next((sample[0]["gke"]["stopped"] for sample in samples.values()
                    if sample and sample[0]["gke"].get("stopped")), None)
    if not stopped:
        return None
    made = [line for line in raws.get(stopped["profile"], []) if line["kind"] == "step" and line.get("variant")]
    return {"reason": stopped["reason"], "profile": stopped["profile"],
            "after": {"round": made[-1]["round"], "variant": made[-1]["variant"], "id": made[-1]["result"]["id"]}
            if made else None}


def run_stopped_text(stopped):
    """What same-node.md says of a run that stopped before its end."""
    where = ""
    if stopped["profile"]:
        after = stopped["after"]
        run = (f"after its run of {after['id']} by {after['variant']} in round {after['round']}" if after else
               "before its first run")
        where = f" under profile {stopped['profile']}, {run}"
    return f"**Stopped early:** the run stopped{where}: {stopped['reason']}. Nothing after that was measured."


def command_same_node(args):
    report, markdown, status = same_node(args.out, args.baseline, given_sha256(args.sha256), args.no_init or ())
    harness.write_json(Path(args.out) / "same-node.json", report)
    (Path(args.out) / "same-node.md").write_text(markdown)
    for problem in report["problems"]:
        print(f"gke: {problem}", file=sys.stderr)
    return status


def command_stopped(args):
    stopped = next((line for line in generator_lines(args.log) if line["kind"] == "stopped"), None)
    if stopped:
        # A run of variants lists the runs it left out, of every variant
        # in every round left, where one of smock alone lists its steps.
        what = "step" if "steps" in stopped else "run"
        count = len(stopped["steps"] if "steps" in stopped else stopped["runs"])
        print(f"{stopped['reason']}; {count} {what}{'' if count == 1 else 's'} not measured")
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


def command_placement(args):
    plan = read_json(args.plan)
    [profile] = plan_profiles(plan, [args.profile])
    problems = placement_problems(read_json(args.pods), profile)
    for problem in problems:
        print(f"gke: {problem}", file=sys.stderr)
    return 1 if problems else 0


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
                                f"of the others, from its image, by digest; {MIN_VARIANTS} to {MAX_VARIANTS} of them, "
                                "in place of --smock-image, the first the baseline")
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
    placing = commands.add_parser("placement", help="fail, saying why, unless every smock Pod of the profile is on "
                                                    "one node, admitted with the profile's limits as its requests "
                                                    "and limits")
    placing.add_argument("pods", help="what gke.py pod-info kept of the profile's Pods")
    placing.add_argument("--plan", required=True, help="the plan the run runs")
    placing.add_argument("--profile", required=True, help="the profile")
    placing.set_defaults(handler=command_placement)
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
    splitting = commands.add_parser("samples", help="split a run of variants into its samples, "
                                                    "samples/<round>-<label>/, each a run of one variant in one round "
                                                    "for summarize; print each one's round, label and directory")
    splitting.add_argument("--plan", required=True, help="the plan the run ran")
    splitting.add_argument("--profiles", help="the profiles the run ran, comma-separated (default: every profile)")
    splitting.add_argument("--cases", help="the cases the run ran, comma-separated (default: every case)")
    splitting.add_argument("out", help="the run's results: raw/<profile>/ of a run of variants")
    splitting.set_defaults(handler=command_samples)
    comparing = commands.add_parser("same-node", help="compare the variants of a run, each with the baseline, from "
                                                      "its samples, each summarized: write same-node.json and "
                                                      "same-node.md")
    comparing.add_argument("--baseline", help="the variant to compare the others with (default: the first)")
    comparing.add_argument("--sha256", action="append",
                           help="LABEL=HEX: the SHA-256 of a variant's binary, beside what each sample's summary "
                                "records; a variant with two fails the comparison")
    comparing.add_argument("--no-init", action="append",
                           help="LABEL: a variant whose Pods ran without the init container (manifests' no-init)")
    comparing.add_argument("out", help="the run's results: samples/ as gke.py samples wrote it, each sample "
                                       "summarized, and raw/")
    comparing.set_defaults(handler=command_same_node)
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
