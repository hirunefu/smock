"""Tests of the GKE Autopilot run's helper, bench/gke/gke.py: the manifests
it renders for each profile, its plan of the run and cost estimate, and the
summary it makes of what the load generator and the cluster reported.

They run the helper through its command line, as scripts/gke-bench.sh does,
and need python3 alone, but for the test of the load generator
(bench/gke/generator.py), which runs it against smock on this machine and
needs what the benchmark's own tests need: a release build of smock
(dist/smock, or SMOCK_BENCH_SMOCK), oha (on PATH, or OHA), and a systemd
user manager that can set CPU quotas and memory limits, since smock runs
in a scope of its own there, as in a container under a profile's limits.

usage: python3 -m unittest discover -s bench -v
"""

import importlib.util
import json
import os
import platform
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
GKE = BENCH / "gke" / "gke.py"
SMOCK = os.environ.get("SMOCK_BENCH_SMOCK", str(ROOT / "dist" / "smock"))
OHA = os.environ.get("OHA", "oha")

SMOCK_IMAGE = "registry.example/smock-bench/smock@sha256:" + "1" * 64
GENERATOR_IMAGE = "registry.example/smock-bench/generator@sha256:" + "2" * 64


def helper(*args):
    """Runs bench/gke/gke.py with `args`; returns the exit status and what
    it wrote to stdout and stderr."""
    result = subprocess.run([sys.executable, str(GKE), *map(str, args)], capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


class Helper(unittest.TestCase):
    def directory(self):
        path = Path(tempfile.mkdtemp(prefix="smock-gke-test-"))
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def manifests(self, profile="autopilot-min", arch="arm64", plan=BENCH / "plan-autopilot.json", cases=None,
                  smock_deadline_s=3000, zone="us-central1-a"):
        """The manifests rendered for one profile: {file name: objects}."""
        out = self.directory()
        args = ["manifests", "--plan", plan, "--profile", profile, "--arch", arch, *(["--zone", zone] if zone else []),
                "--smock-image", SMOCK_IMAGE, "--generator-image", GENERATOR_IMAGE,
                "--smock-deadline-s", smock_deadline_s, "--out", out]
        if cases:
            args += ["--cases", cases]
        status, stdout, stderr = helper(*args)
        self.assertEqual(status, 0, stderr)
        rendered = {}
        for path in sorted(out.iterdir()):
            document = json.loads(path.read_text())
            rendered[path.name] = document["items"] if document["kind"] == "List" else [document]
        return rendered


def objects(rendered, kind):
    return [item for items in rendered.values() for item in items if item["kind"] == kind]


def pod_spec(item):
    """The Pod spec of a Pod, or of a Job's Pods."""
    return item["spec"] if item["kind"] == "Pod" else item["spec"]["template"]["spec"]


class Manifests(Helper):
    """Each profile runs smock in a Pod whose requests are its limits, with
    a deadline, behind a ClusterIP Service, and the load generator in a Job
    with a deadline on another node in smock's zone, both on nodes of the
    run's architecture, in a namespace that cannot have a LoadBalancer or a
    volume claim."""

    def test_smock_runs_under_the_profiles_limits_as_requests_behind_a_cluster_ip_service(self):
        rendered = self.manifests(profile="autopilot-burst-min")
        [pod] = objects(rendered, "Pod")
        [container] = pod_spec(pod)["containers"]
        self.assertEqual(container["image"], SMOCK_IMAGE)
        resources = container["resources"]
        self.assertEqual((resources["limits"]["cpu"], resources["limits"]["memory"]), ("50m", "52Mi"))
        self.assertEqual(resources["requests"], resources["limits"])
        self.assertEqual(pod_spec(pod)["restartPolicy"], "Always")
        [service] = objects(rendered, "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual({port["port"]: port["targetPort"] for port in service["spec"]["ports"]},
                         {80: 8080, 443: 8443, 9090: 9090})
        # The Service selects smock's Pod.
        self.assertLessEqual(service["spec"]["selector"].items(), pod["metadata"]["labels"].items())

    def test_an_init_container_prints_the_cpu_of_smocks_node_asking_for_no_more_than_smock(self):
        # From the load generator's image, which has Python and gke.py;
        # smock's own has no shell. Autopilot bills a Pod for the larger of
        # its init containers and the sum of its containers: with smock's
        # limits, the Pod asks for what smock does.
        for profile in ("autopilot-burst-min", "chart-default"):
            [pod] = objects(self.manifests(profile=profile), "Pod")
            [container] = pod_spec(pod)["containers"]
            [init] = pod_spec(pod)["initContainers"]
            self.assertEqual((init["name"], init["image"], init["command"]),
                             ("node-cpu", GENERATOR_IMAGE, ["python3", "/bench/gke/gke.py", "node-cpu"]))
            self.assertEqual(init["resources"], container["resources"])
            self.assertEqual(init["securityContext"], container["securityContext"])

    def test_each_profile_has_its_own_service_and_pod_which_the_load_generator_targets(self):
        # A new name for each profile: no ClusterIP or datapath entry of the
        # previous profile's Service, just deleted, is reused.
        for profile in ("autopilot-min", "chart-default"):
            rendered = self.manifests(profile=profile)
            [pod] = objects(rendered, "Pod")
            [service] = objects(rendered, "Service")
            self.assertEqual((pod["metadata"]["name"], service["metadata"]["name"]),
                             (f"smock-{profile}", f"smock-{profile}"))
            # The Service selects this profile's Pod only.
            self.assertEqual(service["spec"]["selector"]["profile"], profile)
            self.assertLessEqual(service["spec"]["selector"].items(), pod["metadata"]["labels"].items())
            [job] = objects(rendered, "Job")
            [container] = pod_spec(job)["containers"]
            env = {variable["name"]: variable["value"] for variable in container["env"]}
            self.assertEqual(env["TARGET"], f"smock-{profile}.smock-bench.svc.cluster.local")

    def test_a_profile_whose_name_cannot_name_a_service_is_refused(self):
        plan = json.loads((BENCH / "plan-autopilot.json").read_text())
        plan["profiles"][0]["name"] = "Burst_Min"
        plan["cases"] = [{**case, "rates": {"Burst_Min": [125]}} for case in plan["cases"]]
        path = self.directory() / "plan.json"
        path.write_text(json.dumps(plan))
        status, _, stderr = helper("plan", "--plan", path)
        self.assertEqual(status, 1)
        self.assertIn("profile Burst_Min cannot name a Kubernetes Service", stderr)

    def test_smocks_pod_stops_by_itself_at_the_deadline_it_is_given(self):
        # Even when neither the run nor its watchdog is left to delete the
        # cluster, smock is billed until the run's time limit at most.
        [pod] = objects(self.manifests(smock_deadline_s=2400), "Pod")
        self.assertEqual(pod_spec(pod)["activeDeadlineSeconds"], 2400)
        status, _, stderr = helper("manifests", "--plan", BENCH / "plan-autopilot.json", "--profile", "autopilot-min",
                                   "--arch", "arm64", "--zone", "us-central1-a", "--smock-image", SMOCK_IMAGE,
                                   "--generator-image", GENERATOR_IMAGE, "--smock-deadline-s", 0,
                                   "--out", self.directory())
        self.assertEqual(status, 1)
        self.assertIn("deadline of at least 1 s", stderr)

    def test_the_load_generator_is_a_job_with_a_deadline_on_another_node_than_smock(self):
        rendered = self.manifests(profile="chart-default")
        [pod] = objects(rendered, "Pod")
        [job] = objects(rendered, "Job")
        self.assertEqual(job["spec"]["backoffLimit"], 0)
        # 8 steps of plain HTTP and 6 of TLS, each of 2 + 20 + 3 s, with a
        # pause of 2 s between them: the deadline leaves room for each
        # step's analysis and the start, but not for a run left behind.
        load_s = 14 * 25 + 13 * 2
        self.assertGreaterEqual(job["spec"]["activeDeadlineSeconds"], load_s + 300)
        self.assertLessEqual(job["spec"]["activeDeadlineSeconds"], load_s + 900)
        spec = pod_spec(job)
        self.assertEqual(spec["restartPolicy"], "Never")
        [term] = spec["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        self.assertEqual(term["topologyKey"], "kubernetes.io/hostname")
        self.assertLessEqual(term["labelSelector"]["matchLabels"].items(), pod["metadata"]["labels"].items())
        [container] = spec["containers"]
        self.assertEqual(container["image"], GENERATOR_IMAGE)
        self.assertEqual(container["resources"]["requests"], container["resources"]["limits"])
        env = {variable["name"]: variable["value"] for variable in container["env"]}
        self.assertEqual((env["PROFILE"], env["CASES"]), ("chart-default", "http-keep-alive,https-keep-alive"))

    def test_the_load_generator_has_6_vcpus_on_amd64_and_4_on_arm64_and_fits_an_8_vcpu_node(self):
        # An x86 vCPU is a hyperthread: 4 of them fell behind the schedule
        # at 20,000 requests a second and above.
        for arch, expected in (("amd64", ("6", "6Gi")), ("arm64", ("4", "4Gi"))):
            [job] = objects(self.manifests(arch=arch), "Job")
            [container] = pod_spec(job)["containers"]
            resources = container["resources"]
            self.assertEqual((resources["requests"]["cpu"], resources["requests"]["memory"]), expected)
            self.assertEqual(resources["requests"], resources["limits"])
            # An 8-vCPU Autopilot node had 7910m allocatable in the runs of
            # 2026-10-14 (ek-standard-8, e4a-standard-8); at least 1 vCPU of
            # it stays for Autopilot's own Pods there.
            self.assertLessEqual(float(resources["requests"]["cpu"]) + 1, 7.910)

    def test_both_are_pinned_to_the_zone_and_to_the_compute_class_of_the_architecture(self):
        # arm64 in the built-in autopilot-arm compute class; amd64 in
        # Autopilot's default general-purpose Pods, which have no class to
        # select.
        for arch, expected in (
                ("arm64", {"kubernetes.io/arch": "arm64", "cloud.google.com/compute-class": "autopilot-arm",
                           "topology.kubernetes.io/zone": "us-central1-a"}),
                ("amd64", {"kubernetes.io/arch": "amd64", "topology.kubernetes.io/zone": "us-central1-a"})):
            rendered = self.manifests(arch=arch)
            for item in [*objects(rendered, "Pod"), *objects(rendered, "Job")]:
                self.assertEqual(pod_spec(item)["nodeSelector"], expected)
            # The zone keeps them together; the load generator needs no
            # affinity to smock's for that.
            [job] = objects(rendered, "Job")
            self.assertEqual(set(pod_spec(job)["affinity"]), {"podAntiAffinity"})

    def test_without_a_zone_autopilot_chooses_it_and_the_load_generator_follows_smock_there(self):
        rendered = self.manifests(arch="amd64", zone=None)
        [pod] = objects(rendered, "Pod")
        [job] = objects(rendered, "Job")
        for item in (pod, job):
            self.assertEqual(pod_spec(item)["nodeSelector"], {"kubernetes.io/arch": "amd64"})
        affinity = pod_spec(job)["affinity"]
        [term] = affinity["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        self.assertEqual(term["topologyKey"], "topology.kubernetes.io/zone")
        self.assertLessEqual(term["labelSelector"]["matchLabels"].items(), pod["metadata"]["labels"].items())
        # And still on another node than smock.
        [term] = affinity["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        self.assertEqual(term["topologyKey"], "kubernetes.io/hostname")

    def test_nothing_billed_outside_the_pods_can_be_made_in_the_namespace(self):
        rendered = self.manifests()
        kinds = {item["kind"] for items in rendered.values() for item in items}
        self.assertEqual(kinds, {"Namespace", "ResourceQuota", "Service", "Pod", "Job"})
        for item in [*objects(rendered, "Pod"), *objects(rendered, "Job")]:
            for volume in pod_spec(item).get("volumes", []):
                self.assertEqual(set(volume) - {"name"}, {"emptyDir"}, volume)
        [quota] = objects(rendered, "ResourceQuota")
        hard = quota["spec"]["hard"]
        self.assertEqual((hard["services.loadbalancers"], hard["services.nodeports"], hard["persistentvolumeclaims"]),
                         ("0", "0", "0"))
        namespaces = {item["metadata"].get("namespace") for items in rendered.values() for item in items
                      if item["kind"] != "Namespace"}
        [namespace] = objects(rendered, "Namespace")
        self.assertEqual(namespaces, {namespace["metadata"]["name"]})


class Plan(Helper):
    """The plan of a GKE run: the profiles it runs, each with its steps, and
    only what a Pod on GKE can run."""

    def plan(self, *args, plan=BENCH / "plan-autopilot.json"):
        return helper("plan", "--plan", plan, *args)

    def test_each_profile_of_the_plan_is_listed_with_its_steps_and_its_jobs_deadline(self):
        status, stdout, stderr = self.plan()
        self.assertEqual(status, 0, stderr)
        lines = [line.split() for line in stdout.splitlines()]
        self.assertEqual([line[:2] for line in lines],
                         [["autopilot-burst-min", "14"], ["autopilot-min", "14"], ["chart-default", "14"]])
        deadlines = {line[0]: int(line[2]) for line in lines}
        self.assertEqual(deadlines["chart-default"],
                         self.manifests("chart-default")["generator.json"][0]["spec"]["activeDeadlineSeconds"])

    def test_some_profiles_and_cases_can_be_chosen(self):
        status, stdout, stderr = self.plan("--profiles", "chart-default,autopilot-min", "--cases", "https-keep-alive")
        self.assertEqual(status, 0, stderr)
        self.assertEqual([line.split()[:2] for line in stdout.splitlines()],
                         [["autopilot-min", "6"], ["chart-default", "6"]])
        for args, expected in ((["--profiles", "huge"], "no profile huge"), (["--cases", "grpc"], "no case grpc")):
            status, _, stderr = self.plan(*args)
            self.assertEqual(status, 1)
            self.assertIn(expected, stderr)

    def test_a_plan_a_pod_cannot_run_is_refused_with_what_to_change(self):
        # bench/plan.json's profiles have no memory limit, which Autopilot
        # needs, and one case holds idle connections from the harness.
        status, _, stderr = self.plan(plan=BENCH / "plan.json")
        self.assertEqual(status, 1)
        self.assertIn("profile 250m has no memory limit", stderr)
        plan = json.loads((BENCH / "plan-autopilot.json").read_text())
        plan["cases"][0]["idle_connections"] = 1000
        path = self.directory() / "plan.json"
        path.write_text(json.dumps(plan))
        status, _, stderr = self.plan(plan=path)
        self.assertEqual(status, 1)
        self.assertIn("case http-keep-alive holds idle connections", stderr)


def small_plan(directory, rates=(500, 1000)):
    """A plan with one profile, small (250m, 512Mi), and one case at a
    ladder of rates."""
    path = directory / "plan.json"
    path.write_text(json.dumps({
        "profiles": [{"name": "small", "cpu_limit": "250m", "memory_limit": "512Mi"}],
        "ramp_s": 2, "duration_s": 20, "tail_s": 3, "cooldown_s": 2, "rss_interval_s": 0.5,
        "idle_rss": {"settle_s": 5}, "load_generator": {"name": "oha", "version": "1.16.0"},
        "cases": [{"name": "http-keep-alive", "protocol": "http", "connection": "keep-alive", "connections": 64,
                   "rates": {"small": list(rates)}}]}))
    return path


# The targets of profile small, at http-keep-alive's 1,000 requests/s.
SMALL_TARGETS = {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "case": "http-keep-alive",
                 "rate": 1000,
                 "at_most": {"p99_ms": 3, "p99_9_ms": 5, "oom_kills": 0, "peak_memory_mib": 32, "idle_rss_mib": 20}}


def small_targets(directory, architectures=None):
    """A targets file with the entries of each architecture of
    `architectures` ({architecture: entries}); by default, small's targets
    for arm64 and for amd64 alike."""
    path = directory / "targets.json"
    by_architecture = architectures or {"arm64": [SMALL_TARGETS], "amd64": [SMALL_TARGETS]}
    path.write_text(json.dumps({"architectures": {architecture: {"profiles": entries}
                                                  for architecture, entries in by_architecture.items()}}))
    return path


def generator_step(rate, p99=2.0, p99_9=2.5, errors=0, peak_mib=20.0, scraped=True):
    """A step line of the load generator for http-keep-alive under small:
    with what smock used during it, from its /metrics (smock's CPU at 30 µs
    a request, its peak memory `peak_mib`), or, when not `scraped`, as from
    a smock without process metrics."""
    scheduled = rate * 20
    requests = rate * 25 - errors
    usage_s = requests * 30e-6
    smock_cpu = {"usage_s": round(usage_s, 3), "periods": 250, "throttled_periods": 3, "throttled_s": 0.012,
                 "source": "cgroup", "process_s": round(usage_s, 2), "wall_s": 25.004, "requests": requests,
                 "us_per_request": 30.0, "utilization": round(usage_s / (25.004 * 0.25), 4)}
    return {"kind": "step", "result": {
        "id": f"http-keep-alive@small@{rate}", "case": "http-keep-alive", "profile": "small", "cpu_limit": "250m",
        "memory_limit": "512Mi", "raw": f"raw/small/http-keep-alive@{rate}", "protocol": "http",
        "connection": "keep-alive", "connections": 64, "idle_connections": 0, "rate": rate, "ramp_s": 2,
        "duration_s": 20, "tail_s": 3, "rss_interval_s": 0.5,
        "achieved_rate": (scheduled - errors) / 20, "errors": errors,
        "latency_ms": {"p50": 1.2, "p90": 1.6, "p99": p99, "p99_9": p99_9, "max": 4.0},
        "latency_from_release_ms": {"p50": 0.3, "p90": 0.5, "p99": 1.0, "p99_9": 1.5, "max": 3.0},
        "generator_lag_ms": {"p50": 1.0, "p99": 1.9, "p99_9": 2.0, "max": 3.1}, "load_generator_late": False,
        "requests": {"scheduled": scheduled, "ok": scheduled - errors, "unexpected_status": 0, "no_response": errors},
        "tcp_passive_opens": None, "idle_connections_open_at_end": None, "pinning": None,
        "smock_cpu": smock_cpu if scraped else None,
        "memory": {"peak_bytes": round(peak_mib * (1 << 20)) if scraped else None, "oom_kills": None},
        "rss_kib": {"first": 17000, "last": 18000, "max": 18000} if scraped else {"first": None, "last": None,
                                                                                   "max": None},
        "smock_ready": True, "smock_exit_status": None, "per_request": []}}


# What the load generator says of smock idle under small, from its
# /metrics, 5 s after it was ready.
IDLE = {"kind": "idle-rss", "profile": "small", "idle": {
    "profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "settle_s": 5, "smock_ready": True,
    "digest": "48f7ce9715f0", "rss_kib": 16384, "memory": {"peak_bytes": 15 << 20, "oom_kills": None}}}


START = {"kind": "start", "profile": "small", "oha": "oha 1.16.0", "cpus": 8, "affinity": 4,
         "status": {"version": "0.2.0", "commit": "a21fe97d59c6", "toolchain": "moonc v0.10.14+7d59c7ec9",
                    "digest": "48f7ce9715f0", "mocks": [{"name": "catalog"}]}}

NODE = {"instance_type": "e4a-standard-8", "arch": "arm64", "zone": "us-central1-a", "machine_family": "e4a",
        "compute_class": "autopilot-arm", "boot_disk": "hyperdisk-balanced", "kernel": "6.12.94+",
        "kubelet": "v1.35.8-gke.1225000", "os_image": "Container-Optimized OS from Google", "cpus": "8",
        "allocatable_cpu": "7910m"}


# An amd64 node of Autopilot's general-purpose Pods, which have no compute
# class label.
X86_NODE = {**NODE, "instance_type": "ek-standard-8", "arch": "amd64", "zone": "asia-northeast1-b",
            "machine_family": "ek", "compute_class": None, "boot_disk": "pd-balanced"}


def pods(restarts=0, reason=None, node=NODE, generator_node=None, generator_cpu="4"):
    """What gke.py pod-info keeps of the profile's Pods and their nodes."""
    return {"smock": [{"name": "smock-small", "node": "node-a", "ready": True, "restarts": restarts,
                       "last_termination": reason}],
            "generator": [{"name": "generator-small-1", "node": "node-b", "phase": "Succeeded", "reason": None,
                           "cpu_request": generator_cpu}],
            "nodes": {"node-a": node, "node-b": generator_node or node}}


# What the load generator says of the traffic ports before the first step:
# both answered.
TRAFFIC_CHECK = {"kind": "traffic-check", "profile": "small", "ok": True, "host": "catalog.bench.internal",
                 "method": "GET", "target": "/catalog/items/SKU-00317", "window_s": 60,
                 "ports": {"plain": {"port": 80, "answered": True, "status": 200, "attempts": 1, "seconds": 0.004,
                                     "error": None},
                           "tls": {"port": 443, "answered": True, "status": 200, "attempts": 1, "seconds": 0.011,
                                   "error": None}}}


class Summary(Helper):
    """A GKE run's results become a summary of the same layout as a run on
    a machine writes, which bench/compare.py reads, with its targets
    checked, and the conditions it ran under."""

    def results(self, lines, pod_info, rates=(500, 1000), where=("--region", "us-central1", "--zone", "us-central1-a",
                                                                 "--arch", "arm64"), targets=None, smock_node_cpu=None,
                stopped=(), plan=None):
        """A results directory as scripts/gke-bench.sh leaves it, with the
        load generator's log, the Pods of profile small, and, when given,
        what smock's init container printed (`smock_node_cpu`, a text),
        summarized against `targets` ({architecture: entries}, by default
        small's targets for both); `stopped` says why and where the run
        stopped early, if it did. The plan is small_plan's at `rates`,
        unless `plan` names another."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        text = "".join(line if isinstance(line, str) else json.dumps(line) + "\n" for line in lines)
        (raw / "generator.log").write_text(text)
        (raw / "pods.json").write_text(json.dumps(pod_info))
        if smock_node_cpu is not None:
            (raw / "smock-node-cpu.log").write_text(smock_node_cpu)
        status, _, stderr = helper(
            "summarize", "--plan", plan or small_plan(self.directory(), rates),
            "--targets", small_targets(self.directory(), targets), *where,
            "--started-at", "2026-10-14T03:28:50+00:00", "--finished-at", "2026-10-14T04:01:56+00:00",
            "--cluster-version", "1.35.8-gke.1225000", "--smock-image", "sha256:" + "1" * 64,
            "--generator-image", "sha256:" + "2" * 64, *stopped, out)
        self.assertEqual(status, 0, stderr)
        return out

    def test_each_step_the_load_generator_reported_is_a_case_and_the_targets_are_checked(self):
        out = self.results([START, IDLE, "generator: step 500 requests/s\n", generator_step(500),
                            generator_step(1000, p99=2.5, p99_9=6.0, peak_mib=21.5),
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual(summary["format"], 4)
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@small@500", "http-keep-alive@small@1000"])
        # smock never restarted, so the kernel never OOM-killed it.
        self.assertEqual(summary["idle_rss"], [{**IDLE["idle"], "memory": {"peak_bytes": 15 << 20, "oom_kills": 0}}])
        verdicts = {target["id"]: (target["verdict"], target["measured"]) for target in summary["targets"]}
        self.assertEqual(verdicts, {
            "small/p99": ("met", 2.5),
            "small/p99_9": ("missed", 6.0),
            "small/oom_kills": ("met", 0),
            # From smock's /metrics: its cgroup's memory.peak by the end of
            # the step, and its RSS idle.
            "small/peak_memory": ("met", 21.5),
            "small/idle_rss": ("met", 16.0),
        })
        markdown = (out / "summary.md").read_text()
        self.assertIn("Idle RSS: 16.0 MiB, 5 s after startup; peak memory 15.0 MiB, 0 OOM kills.", markdown)
        # The CPU time a request and the share of the CPU limit, then how
        # long smock was throttled.
        self.assertIn("| 0 | 30.0 | 12.0 | 0.012 | 17.6 | 21.5 | 0 |", markdown)
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(out), str(out)],
                                  capture_output=True, text=True)
        self.assertIn("| small | http-keep-alive | 1,000 | 2.5 → 2.5 | 0% |", compared.stdout, compared.stderr)

    def test_a_smock_without_process_metrics_measures_no_idle_rss_peak_memory_or_cpu(self):
        # As a smock built before /metrics had them: the load generator
        # reports no idle RSS, and nothing of what smock used at a step.
        out = self.results([START, generator_step(500, scraped=False), generator_step(1000, scraped=False),
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual(summary["idle_rss"], [])
        verdicts = {target["id"]: (target["verdict"], target["reason"]) for target in summary["targets"]}
        self.assertEqual(verdicts["small/peak_memory"],
                         ("not measured",
                          "the kernel kept no peak memory in http-keep-alive@small@1000 (no memory.peak)"))
        self.assertEqual(verdicts["small/idle_rss"], ("not measured", "the run did not measure idle RSS under small"))
        self.assertIn("| 0 | - | - | - | - | - | 0 |", (out / "summary.md").read_text())

    def test_the_targets_of_the_runs_architecture_are_checked(self):
        # amd64's p99 at 1,000 requests/s is at most 2 ms, which the run's
        # 2.5 ms misses; arm64's is at most 3 ms.
        amd64 = {**SMALL_TARGETS, "at_most": {**SMALL_TARGETS["at_most"], "p99_ms": 2}}
        lines = [START, generator_step(500), generator_step(1000, p99=2.5, p99_9=4.0), {"kind": "done"}]
        for arch, verdict, maximum in (("amd64", "missed", 2), ("arm64", "met", 3)):
            out = self.results(lines, pods(), where=("--region", "us-central1", "--arch", arch),
                               targets={"arm64": [SMALL_TARGETS], "amd64": [amd64]})
            summary = json.loads((out / "summary.json").read_text())
            p99 = next(target for target in summary["targets"] if target["id"] == "small/p99")
            self.assertEqual((p99["architecture"], p99["max"], p99["verdict"]), (arch, maximum, verdict))
            self.assertIn(f"for {arch}, the architecture the run ran on.", (out / "summary.md").read_text())
        # A targets file with none for the run's architecture: none is
        # measured, and the summary says so.
        out = self.results(lines, pods(), where=("--region", "us-central1", "--arch", "amd64"),
                           targets={"arm64": [SMALL_TARGETS]})
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual({target["verdict"] for target in summary["targets"]}, {"not measured"})
        self.assertIn("has no targets for amd64, the architecture the run ran on", (out / "summary.md").read_text())

    def test_the_conditions_say_what_ran_where_without_the_project(self):
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        conditions = json.loads((out / "conditions.json").read_text())
        self.assertEqual((conditions["smock"]["version"], conditions["smock"]["commit"]), ("0.2.0", "a21fe97d59c6"))
        self.assertEqual(conditions["definitions"]["digest"], "48f7ce9715f0")
        self.assertEqual(conditions["machine"]["architecture"], "arm64")
        self.assertIn("e4a-standard-8", conditions["machine"]["cpu_model"])
        self.assertEqual(conditions["load_generator"]["version"], "oha 1.16.0")
        self.assertEqual((conditions["gke"]["region"], conditions["gke"]["zone"], conditions["gke"]["compute_class"]),
                         ("us-central1", "us-central1-a", "autopilot-arm"))
        self.assertEqual(conditions["profiles"], [{"name": "small", "cpu_limit": "250m", "memory_limit": "512Mi"}])
        markdown = (out / "summary.md").read_text()
        self.assertIn("GKE Autopilot", markdown)
        self.assertIn("| http-keep-alive | 1000 |", markdown)

    def test_the_conditions_record_a_hash_of_the_plan_that_leaves_out_its_description(self):
        lines = [START, generator_step(500), generator_step(1000), {"kind": "done"}]

        def recorded(**changes):
            """What conditions.json records of small_plan's plan, changed."""
            path = small_plan(self.directory())
            path.write_text(json.dumps({**json.loads(path.read_text()), **changes}))
            out = self.results(lines, pods(), plan=path)
            return json.loads((out / "conditions.json").read_text())["plan"]

        first, second = recorded(about="What the plan runs."), recorded(about="What the plan runs, said otherwise.")
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual(first["sha256_without_about"], second["sha256_without_about"])
        # Anything else is a different plan.
        other = recorded(about="What the plan runs.", cooldown_s=5)
        self.assertNotEqual(other["sha256_without_about"], first["sha256_without_about"])

    def test_the_conditions_record_the_architecture_region_zone_and_machine_types(self):
        # An amd64 run with no zone pinned: Autopilot chose it.
        generator_node = {**X86_NODE, "instance_type": "ek-standard-16"}
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(node=X86_NODE, generator_node=generator_node),
                           where=("--region", "asia-northeast1", "--arch", "amd64", "--smock-sha256", "3" * 64))
        conditions = json.loads((out / "conditions.json").read_text())
        # The binary in smock's image, such as one CI built.
        self.assertEqual(conditions["smock"]["sha256"], "3" * 64)
        gke = conditions["gke"]
        self.assertEqual(
            {key: gke[key] for key in ("arch", "region", "zone", "pinned_zone", "compute_class", "machine_type",
                                       "generator_machine_type")},
            {"arch": "amd64", "region": "asia-northeast1", "zone": "asia-northeast1-b", "pinned_zone": None,
             "compute_class": "general-purpose", "machine_type": "ek-standard-8",
             "generator_machine_type": "ek-standard-16"})
        self.assertEqual(conditions["machine"]["architecture"], "amd64")
        self.assertIn("asia-northeast1-b", conditions["note"])
        self.assertIn("amd64", conditions["note"])

    def test_the_conditions_name_the_cpu_of_smocks_node_and_of_the_load_generators(self):
        # smock's, from what its init container printed; the load
        # generator's, from its start line.
        out = self.results([{**START, "node_cpu": INTEL_CPU}, generator_step(500), generator_step(1000),
                            {"kind": "done"}], pods(node=X86_NODE),
                           where=("--region", "us-central1", "--arch", "amd64"),
                           smock_node_cpu=json.dumps({"kind": "node-cpu", "cpu": AMD_CPU}) + "\n")
        conditions = json.loads((out / "conditions.json").read_text())
        nodes = conditions["gke"]["profiles"]["small"]["nodes"]
        self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (AMD_CPU, INTEL_CPU))
        # The machine is smock's: the CPU model its nodes had.
        self.assertEqual(conditions["machine"]["cpu_model"], "GKE Autopilot ek-standard-8, AMD EPYC 7B13")
        markdown = (out / "summary.md").read_text()
        self.assertIn("on amd64 (GKE Autopilot ek-standard-8, AMD EPYC 7B13, 8 CPUs)", markdown)
        self.assertIn("| small | ek-standard-8 (amd64, asia-northeast1-b), AMD EPYC 7B13 | "
                      "ek-standard-8 (amd64, asia-northeast1-b), Intel(R) Xeon(R) CPU @ 2.20GHz |", markdown)

    def test_a_node_whose_cpu_was_not_recorded_has_none(self):
        # As a run before its nodes' CPUs were recorded, or one whose init
        # container's log could not be read: kubectl's error is no line.
        for smock_node_cpu in (None, "Error from server (NotFound): pods \"smock-small\" not found\n"):
            out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                               pods(node=X86_NODE), where=("--region", "us-central1", "--arch", "amd64"),
                               smock_node_cpu=smock_node_cpu)
            conditions = json.loads((out / "conditions.json").read_text())
            nodes = conditions["gke"]["profiles"]["small"]["nodes"]
            self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (None, None))
            self.assertEqual(conditions["machine"]["cpu_model"], "GKE Autopilot ek-standard-8")

    def test_a_profile_cut_short_leaves_the_run_incomplete(self):
        out = self.results([START, generator_step(500), "generator: the deadline passed\n"], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])

    def test_a_run_that_stopped_early_says_where_and_why_at_the_top_of_its_summary(self):
        out = self.results([START, IDLE, generator_step(500)], pods(),
                           stopped=("--stopped", "stopped by SIGTERM", "--stopped-under", "small"))
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])
        self.assertEqual(summary["gke"]["stopped"],
                         {"reason": "stopped by SIGTERM", "profile": "small", "after": "http-keep-alive@small@500"})
        markdown = (out / "summary.md").read_text()
        note = ("**Stopped early:** the run stopped under profile small, after its step http-keep-alive@small@500: "
                "stopped by SIGTERM. Nothing after that was measured.")
        self.assertIn(note, markdown)
        # Right below the line that says what ran, in place of the note
        # that the run is incomplete.
        self.assertLess(markdown.index("Started 2026-10-14T03:28:50+00:00"), markdown.index(note))
        self.assertLess(markdown.index(note), markdown.index("**Note:**"))
        self.assertNotIn("**Incomplete:**", markdown)
        # Before the profile's first step.
        out = self.results([START, IDLE], pods(), stopped=("--stopped", "the load generator's Pod did not start "
                                                           "under small", "--stopped-under", "small"))
        self.assertIn("**Stopped early:** the run stopped under profile small, before its first step: the load "
                      "generator's Pod did not start under small.", (out / "summary.md").read_text())
        # A run that did not stop says nothing of it.
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        self.assertIsNone(json.loads((out / "summary.json").read_text())["gke"]["stopped"])
        self.assertNotIn("Stopped early", (out / "summary.md").read_text())

    def test_a_run_stopped_before_anything_was_reported_says_what_is_unknown(self):
        # smock never became ready under the first profile, on no node: the
        # load generator printed nothing, so smock's version, the
        # definition set and oha's version are unknown, as is the machine.
        out = self.results([], {"smock": [{"name": "smock-small", "node": None, "ready": False, "restarts": 0,
                                           "last_termination": None}], "generator": [], "nodes": {}},
                           stopped=("--stopped", "smock did not become ready under small", "--stopped-under", "small"))
        markdown = (out / "summary.md").read_text()
        self.assertIn("Started 2026-10-14T03:28:50+00:00: smock of an unknown version (commit unknown, toolchain "
                      "unknown), definition set unknown, on arm64 (GKE Autopilot node, CPUs unknown), oha of an "
                      "unknown version, plan ", markdown)
        self.assertNotIn("None", markdown)
        # conditions.json records them as null.
        conditions = json.loads((out / "conditions.json").read_text())
        self.assertEqual((conditions["smock"]["version"], conditions["machine"]["cpus"]), (None, None))
        # So does the comparison with a run that knew them.
        older = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(older), str(out)],
                                  capture_output=True, text=True)
        self.assertIn("- Newer: smock of an unknown version (commit unknown) on GKE Autopilot (us-central1-a, "
                      "autopilot-arm), arm64 (GKE Autopilot node, CPUs unknown)", compared.stdout, compared.stderr)
        self.assertIn("definition set (48f7ce9715f0 → unknown)", compared.stdout)
        self.assertNotIn("None", compared.stdout)

    def test_steps_a_profile_did_not_run_after_it_stopped_early_are_not_measured_with_the_reason(self):
        # The step at 500 got no response at all, so the load generator ran
        # none after it.
        reason = "http-keep-alive@small@500 got no response to any of its 10,000 requests (oha: timeout)"
        out = self.results([START, TRAFFIC_CHECK, generator_step(500, errors=10000),
                            {"kind": "stopped", "profile": "small", "reason": reason,
                             "after": "http-keep-alive@small@500", "steps": ["http-keep-alive@small@1000"]},
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])
        # The targets at 1000 requests/s say why they were not measured.
        for target in summary["targets"]:
            if target["metric"] in ("p99", "p99_9", "oom_kills"):
                self.assertEqual(target["verdict"], "not measured")
                self.assertEqual(target["reason"], f"http-keep-alive@small@1000 was not run: {reason}")
        ended = {"reason": reason, "after": "http-keep-alive@small@500", "not_measured": ["http-keep-alive@small@1000"]}
        self.assertEqual(summary["gke"]["profiles"]["small"]["ended_early"], ended)
        conditions = json.loads((out / "conditions.json").read_text())
        self.assertEqual(conditions["gke"]["profiles"]["small"]["ended_early"], ended)
        markdown = (out / "summary.md").read_text()
        self.assertIn(f"small ended early: {reason}. Not measured: http-keep-alive@small@1000.", markdown)

    def test_a_profile_whose_traffic_ports_did_not_answer_measures_nothing_and_says_why(self):
        check = {**TRAFFIC_CHECK, "ok": False, "ports": {
            "plain": TRAFFIC_CHECK["ports"]["plain"],
            "tls": {"port": 443, "answered": False, "status": None, "attempts": 12, "seconds": 60.2,
                    "error": "timed out"}}}
        reason = "smock did not answer through its Service in 60 s: TLS port 443 (timed out)"
        steps = ["http-keep-alive@small@500", "http-keep-alive@small@1000"]
        out = self.results([START, check, {"kind": "stopped", "profile": "small", "reason": reason, "after": None,
                                           "steps": steps}, {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual((summary["complete"], summary["cases"]), (False, []))
        verdict = next(target for target in summary["targets"] if target["id"] == "small/p99")
        self.assertEqual((verdict["verdict"], verdict["reason"]),
                         ("not measured", f"http-keep-alive@small@1000 was not run: {reason}"))
        recorded = json.loads((out / "conditions.json").read_text())["gke"]["profiles"]["small"]
        self.assertEqual(recorded["traffic_check"]["ports"]["tls"]["error"], "timed out")
        self.assertFalse(recorded["traffic_check"]["ok"])
        self.assertEqual(recorded["ended_early"]["not_measured"], steps)
        markdown = (out / "summary.md").read_text()
        self.assertIn("| small | e4a-standard-8 (arm64, us-central1-a) | e4a-standard-8 (arm64, us-central1-a) | 4 | "
                      "plain HTTP 200, TLS no answer (timed out) | 0 | yes |", markdown)

    def test_the_traffic_check_and_the_load_generators_cpu_request_are_recorded_for_each_profile(self):
        out = self.results([START, TRAFFIC_CHECK, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(generator_cpu="6"))
        summary = json.loads((out / "summary.json").read_text())
        conditions = json.loads((out / "conditions.json").read_text())
        for recorded in (summary["gke"]["profiles"]["small"], conditions["gke"]["profiles"]["small"]):
            self.assertEqual(recorded["traffic_check"], {key: value for key, value in TRAFFIC_CHECK.items()
                                                         if key not in ("kind", "profile")})
            self.assertIsNone(recorded["ended_early"])
            # As the Pod had it.
            self.assertEqual(recorded["generator_cpu_request"], "6")
        self.assertIn("| 6 | plain HTTP 200, TLS HTTP 200 | 0 | no |", (out / "summary.md").read_text())
        # From an earlier load generator, which checked nothing: unknown.
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        recorded = json.loads((out / "summary.json").read_text())["gke"]["profiles"]["small"]
        self.assertIsNone(recorded["traffic_check"])
        self.assertIn("| 4 | - | 0 | no |", (out / "summary.md").read_text())

    def test_a_smock_that_restarted_measures_no_oom_kills_and_the_summary_says_why(self):
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(restarts=1, reason="OOMKilled"))
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual({case["memory"]["oom_kills"] for case in summary["cases"]}, {None})
        verdict = next(target for target in summary["targets"] if target["id"] == "small/oom_kills")
        self.assertEqual(verdict["verdict"], "not measured")
        self.assertIn("smock restarted 1 time under small (last: OOMKilled)", (out / "summary.md").read_text())


class Estimate(Helper):
    """Before anything is made, a run says how long it takes and what it
    costs, expected and at most."""

    def estimate(self, *args, plan=BENCH / "plan-autopilot.json", region="us-central1", time_limit_s=4800,
                 arch="arm64"):
        return helper("estimate", "--plan", plan, "--region", region, "--arch", arch, "--time-limit-s", time_limit_s,
                      *args)

    def test_it_states_the_expected_cost_and_the_most_a_run_cut_off_at_the_time_limit_costs(self):
        status, stdout, stderr = self.estimate(time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for arm64 Pods (us-central1, on-demand prices of 2026-10-16, before tax", stdout)
        self.assertRegex(stdout, r"Expected: about \$0\.\d\d, the cluster existing for about \d+ minutes\.")
        # Until the watchdog deletes it at the time limit, and for the 5
        # minutes the deletion takes: the cluster's fee ($0.10 an hour), the
        # load generator (4 vCPU and 4Gi at $0.0445 and $0.0049225 an hour,
        # 2Gi of ephemeral storage at $0.0001389) and the largest smock (1
        # vCPU, 1Gi, 64Mi), $0.3474 an hour for 65 minutes.
        self.assertIn("At most: $0.38, if it ran until the time limit (60 minutes)", stdout)
        self.assertIn("Arm Pods are priced as x86 ones: autopilot-arm runs them on Autopilot's container-optimized "
                      "compute platform, which the pricing page bills at one rate for both architectures.", stdout)
        self.assertNotIn("Scale-Out", stdout)
        # What is billed when nothing is left to delete the cluster.
        self.assertIn("its Pods still stop within minutes of the time limit, and the cluster costs its fee, "
                      "$0.10 an hour", stdout)

    def test_x86_pods_in_tokyo_are_estimated_at_tokyos_prices(self):
        status, stdout, stderr = self.estimate(region="asia-northeast1", arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for amd64 (x86) Pods (asia-northeast1, on-demand prices of 2026-10-16", stdout)
        # The fee ($0.10 an hour), the load generator on amd64 (6 vCPU and
        # 6Gi at $0.0571 and $0.0063215 an hour, 2Gi of ephemeral storage at
        # $0.0001784) and the largest smock (1 vCPU, 1Gi, 64Mi): $0.5443 an
        # hour for 65 minutes.
        self.assertIn("At most: $0.59, if it ran until the time limit (60 minutes)", stdout)
        self.assertIn("The load generator's Pod (6 vCPU, 6Gi)", stdout)
        self.assertNotIn("Arm", stdout)

    def test_both_architectures_pods_are_estimated_at_the_same_rates_of_their_region(self):
        # amd64 in us-central1: the fee, the load generator (6 vCPU and 6Gi
        # at $0.0445 and $0.0049225 an hour, 2Gi of ephemeral storage at
        # $0.0001389) and the largest smock (1 vCPU, 1Gi, 64Mi): $0.4462 an
        # hour for 65 minutes, as before Arm Pods were priced apart.
        status, stdout, stderr = self.estimate(arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for amd64 (x86) Pods (us-central1, on-demand prices of 2026-10-16", stdout)
        self.assertIn("At most: $0.48, if it ran until the time limit (60 minutes)", stdout)
        self.assertNotIn("Arm", stdout)
        # The same run on arm64 costs less only for its smaller load
        # generator (4 vCPU, 4Gi): $0.3474 an hour.
        _, stdout, _ = self.estimate(arch="arm64", time_limit_s=3600)
        self.assertIn("At most: $0.38, if it ran until the time limit (60 minutes)", stdout)
        # Every region with Arm Pods at its own rates, such as Singapore's:
        # the load generator at $0.0549 and $0.0060729 an hour, ephemeral
        # storage at $0.0001713, and the fee, $0.4052 an hour.
        for region in ("us-central1", "us-east1", "us-west1", "europe-west1", "europe-west2", "europe-west4",
                       "asia-southeast1"):
            _, stdout, _ = self.estimate(region=region, arch="arm64", time_limit_s=3600)
            self.assertIn(f"Cost estimate for arm64 Pods ({region}, on-demand prices of 2026-10-16", stdout)
            if region == "asia-southeast1":
                self.assertIn("At most: $0.44, if it ran until the time limit (60 minutes)", stdout)

    def test_a_region_without_prices_here_is_estimated_from_us_central1s_with_a_margin(self):
        # An amd64 run in Frankfurt: us-central1's Pod prices plus 30% and
        # the fee, $0.5501 an hour for 65 minutes.
        status, stdout, _ = self.estimate(region="europe-west3", arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0)
        self.assertIn("europe-west3: us-central1's prices plus 30%", stdout)
        self.assertIn("At most: $0.60, if it ran until the time limit (60 minutes)", stdout)

    def test_a_run_longer_than_the_time_limit_is_refused(self):
        status, stdout, stderr = self.estimate(time_limit_s=1200)
        self.assertEqual(status, 1)
        self.assertIn("more than the time limit of 20 minutes", stderr)


class LocalSmock:
    """smock serving the benchmark's definitions on this machine, on free
    ports, as the GKE run's image does, and as in a container of its own
    under profile small's limits: in a systemd scope of its own, which
    only smock is in, with a CPU quota of 250m and a memory limit of
    512Mi, as bench/bench.py runs it. It becomes smock by exec."""

    SCOPE = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "-p", "CPUQuota=25%",
             "-p", f"MemoryMax={512 << 20}", "--"]

    def __enter__(self):
        self.process = subprocess.Popen(
            [*self.SCOPE, SMOCK, "serve", "--dir", str(BENCH / "definitions"), "--port", "0", "--tls-port", "0",
             "--admin-port", "0", "--admin-auth", "off"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True,
            env={name: value for name, value in os.environ.items() if not name.startswith("SMOCK_")})
        self.ports = {}
        listening = threading.Event()

        def read():
            for line in self.process.stderr:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry, dict) and entry.get("msg") == "listening":
                    self.ports[entry["listener"]] = entry["address"].rsplit(":", 1)[1]
                    if {"plain", "tls", "admin"} <= set(self.ports):
                        listening.set()

        threading.Thread(target=read, daemon=True).start()
        if not listening.wait(30):
            self.__exit__()
            raise AssertionError("smock did not start listening")
        return self

    def __exit__(self, *_):
        self.process.terminate()
        self.process.wait(30)
        self.process.stderr.close()


class SilentPort:
    """A port on this machine that takes connections and answers nothing on
    them. With `answer_first`, it answers the first request it gets with an
    empty 200, then closes every connection unanswered: no response either,
    without oha waiting for its requests to time out."""

    def __init__(self, answer_first=False):
        self.answer_first = answer_first

    def __enter__(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        # Room for every connection of a step, never accepted.
        self.listener.listen(256)
        self.port = self.listener.getsockname()[1]
        if self.answer_first:
            threading.Thread(target=self.answer_first_only, daemon=True).start()
        return self

    def answer_first_only(self):
        connection, _ = self.listener.accept()
        with connection:
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                request += chunk
            connection.sendall(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            connection.close()

    def __exit__(self, *_):
        self.listener.close()


class Generator(Helper):
    """The load generator sends a profile's steps the way bench/bench.py
    does, and reports each as summarize reads it."""

    def generator_plan(self, rates=(200,)):
        """The small plan with short steps, at `rates`, over plain HTTP and
        then TLS."""
        plan = json.loads(small_plan(self.directory(), rates=rates).read_text())
        plan.update(ramp_s=0.5, duration_s=2, tail_s=1, cooldown_s=0, idle_rss={"settle_s": 0.5})
        plan["cases"].append({**plan["cases"][0], "name": "https-keep-alive", "protocol": "https"})
        path = self.directory() / "plan.json"
        path.write_text(json.dumps(plan))
        return path

    def generate(self, plan_path, smock, **ports):
        """Runs the load generator for profile small against `smock`, with
        `ports` instead of smock's own; returns its exit status, its JSON
        lines and its output."""
        environment = {**os.environ, "TARGET": "localhost", "PROFILE": "small",
                       "CASES": "http-keep-alive,https-keep-alive", "PLAN": str(plan_path),
                       "PLAIN_PORT": str(ports.get("plain", smock.ports["plain"])),
                       "TLS_PORT": str(ports.get("tls", smock.ports["tls"])),
                       "ADMIN_PORT": smock.ports["admin"], "OHA": shutil.which(OHA) or OHA, "TRAFFIC_CHECK_S": "2"}
        generator = subprocess.run([sys.executable, str(BENCH / "gke" / "generator.py")], env=environment,
                                   capture_output=True, text=True, timeout=120)
        lines = [json.loads(line) for line in generator.stdout.splitlines()]
        return generator.returncode, lines, generator.stdout + generator.stderr

    def summarize(self, plan_path, log):
        """summarize's summary and conditions of a run of profile small whose
        load generator wrote `log`."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        (raw / "generator.log").write_text(log)
        (raw / "pods.json").write_text(json.dumps(pods()))
        status, _, stderr = helper(
            "summarize", "--plan", plan_path, "--targets", small_targets(self.directory()), "--region", "us-central1",
            "--zone", "us-central1-a", "--arch", "arm64", "--started-at", "2026-10-14T03:28:50+00:00",
            "--finished-at", "2026-10-14T04:01:56+00:00", out)
        self.assertEqual(status, 0, stderr)
        return (json.loads((out / "summary.json").read_text()), json.loads((out / "conditions.json").read_text()),
                (out / "summary.md").read_text())

    def test_each_step_of_the_profile_is_reported_and_summarized_as_a_case(self):
        plan_path = self.generator_plan()
        with LocalSmock() as smock:
            status, lines, output = self.generate(plan_path, smock)
        self.assertEqual(status, 0, output)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "step", "step", "metrics-after",
                          "done"])
        self.assertRegex(lines[0]["status"]["digest"], "^[0-9a-f]{12}$")
        # The CPU of the load generator's node, this machine's here.
        self.assertIsNotNone(lines[0]["node_cpu"]["model_name"])
        self.assertIn("aes", lines[0]["node_cpu"]["flags"])
        # smock's idle RSS and peak memory, from its /metrics, before any
        # load.
        idle = lines[1]["idle"]
        self.assertEqual({key: idle[key] for key in ("profile", "cpu_limit", "memory_limit", "settle_s",
                                                     "smock_ready", "digest")},
                         {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "settle_s": 0.5,
                          "smock_ready": True, "digest": lines[0]["status"]["digest"]})
        self.assertGreater(idle["rss_kib"], 1024)
        self.assertGreater(idle["memory"]["peak_bytes"], 0)
        # Both traffic ports answered the first request of the mix before
        # the first step.
        check = lines[2]
        self.assertTrue(check["ok"], check)
        self.assertEqual((check["host"], check["target"]), ("catalog.bench.internal", "/catalog/items/SKU-00317"))
        for port in ("plain", "tls"):
            self.assertEqual((check["ports"][port]["answered"], check["ports"][port]["status"]), (True, 200))
        for step, protocol in zip([line["result"] for line in lines if line["kind"] == "step"], ("http", "https")):
            self.assertEqual((step["profile"], step["protocol"], step["rate"]), ("small", protocol, 200))
            self.assertEqual((step["errors"], step["smock_ready"]), (0, True))
            self.assertEqual(step["requests"]["ok"], step["requests"]["scheduled"])
            self.assertGreater(step["requests"]["scheduled"], 350)
            self.assertIsNotNone(step["latency_ms"]["p99_9"])
            self.assertEqual(len(step["per_request"]), 9)
            self.assert_smock_use(step)

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]], ["http-keep-alive@small", "https-keep-alive@small"])
        # smock never restarted, so the kernel never OOM-killed it.
        self.assertEqual(summary["idle_rss"], [{**idle, "memory": {**idle["memory"], "oom_kills": 0}}])
        verdict = next(target for target in summary["targets"] if target["id"] == "small/idle_rss")
        self.assertEqual((verdict["verdict"] in ("met", "missed"), verdict["measured"]),
                         (True, round(idle["rss_kib"] / 1024, 2)))
        self.assertIn(f"Idle RSS: {idle['rss_kib'] / 1024:.1f} MiB, 0.5 s after startup", markdown)
        self.assertTrue(conditions["gke"]["profiles"]["small"]["traffic_check"]["ok"])
        self.assertIsNone(conditions["gke"]["profiles"]["small"]["ended_early"])

    def assert_smock_use(self, step):
        """What a step says smock used, from its /metrics around the step,
        is what the cgroup of smock's scope, which holds only smock, and
        its process counted: its CPU time, throttling, RSS and peak
        memory, and the requests it answered."""
        cpu = step["smock_cpu"]
        self.assertEqual(cpu["source"], "cgroup", step["id"])
        # Every request of the step's load, ramp and tail included, and
        # none other: at most the rate for the whole load from each oha.
        total_s = step["ramp_s"] + step["duration_s"] + step["tail_s"]
        self.assertGreaterEqual(cpu["requests"], step["requests"]["ok"])
        self.assertLessEqual(cpu["requests"], step["rate"] * total_s + len(step["per_request"]))
        self.assertGreaterEqual(cpu["wall_s"], total_s)
        self.assertLess(cpu["wall_s"], total_s + 30)
        self.assertAlmostEqual(cpu["us_per_request"], cpu["usage_s"] * 1e6 / cpu["requests"],
                               delta=0.0005 * 1e6 / cpu["requests"] + 0.01)
        self.assertAlmostEqual(cpu["utilization"], cpu["usage_s"] / (cpu["wall_s"] * 0.25), delta=0.01)
        self.assertGreater(cpu["usage_s"], 0)
        self.assertLessEqual(cpu["utilization"], 1.05)
        # The process's CPU time, in ticks of 1/100 s, is the cgroup's.
        self.assertAlmostEqual(cpu["process_s"], cpu["usage_s"], delta=0.03)
        self.assertGreater(cpu["periods"], 0)
        self.assertGreaterEqual(cpu["throttled_periods"], 0)
        self.assertGreaterEqual(cpu["throttled_s"], 0)
        # How long smock waited for a CPU, from its /metrics: on this
        # machine, which is no virtual machine, no steal.
        self.assertGreaterEqual(cpu["scheduling_delay_s"], 0)
        self.assertGreaterEqual(cpu["involuntary_context_switches"], 0)
        self.assertGreaterEqual(cpu["node_steal_s"], 0)
        # What smock used in the step's first second, from a scrape a
        # second into the load, in the same layout: some of the requests,
        # and some of the CPU time.
        first = cpu["first_second"]
        self.assertEqual(first["source"], "cgroup")
        self.assertGreaterEqual(first["wall_s"], 1)
        self.assertLess(first["wall_s"], 3)
        self.assertGreater(first["requests"], 0)
        self.assertLess(first["requests"], cpu["requests"])
        self.assertGreater(first["usage_s"], 0)
        self.assertLessEqual(first["usage_s"], cpu["usage_s"])
        self.assertIsNotNone(first["scheduling_delay_s"])
        # Each second of the load, ramp and tail included (3.5 s), with the
        # requests due in it that got a response.
        seconds = step["per_second"]
        self.assertEqual(len(seconds["requests"]), 4)
        self.assertGreaterEqual(sum(seconds["requests"]), step["requests"]["ok"])
        self.assertEqual([p99 is None for p99 in seconds["p99_ms"]], [count == 0 for count in seconds["requests"]])
        rss = step["rss_kib"]
        self.assertGreater(rss["first"], 1024)
        self.assertEqual(rss["max"], max(rss["first"], rss["last"]))
        self.assertGreater(step["memory"]["peak_bytes"], 0)

    def test_a_traffic_port_that_never_answers_stops_the_profile_before_its_first_step(self):
        # As smock's Service did under autopilot-min: connections open, and
        # no request gets a response.
        plan_path = self.generator_plan()
        with LocalSmock() as smock, SilentPort() as silent:
            started = time.monotonic()
            status, lines, output = self.generate(plan_path, smock, tls=silent.port)
        self.assertEqual(status, 0, output)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "stopped", "metrics-after", "done"])
        check = lines[2]
        self.assertFalse(check["ok"])
        self.assertEqual((check["ports"]["plain"]["answered"], check["ports"]["plain"]["status"]), (True, 200))
        self.assertEqual((check["ports"]["tls"]["answered"], check["ports"]["tls"]["port"]), (False, silent.port))
        self.assertEqual(check["ports"]["tls"]["error"], "timed out")
        stopped = lines[4]
        self.assertEqual(stopped["reason"], f"smock did not answer through its Service in 2 s: TLS port {silent.port} "
                                            "(timed out)")
        self.assertEqual((stopped["after"], stopped["steps"]),
                         (None, ["http-keep-alive@small", "https-keep-alive@small"]))

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertEqual((summary["complete"], summary["cases"]), (False, []))
        self.assertEqual(conditions["gke"]["profiles"]["small"]["ended_early"]["not_measured"],
                         ["http-keep-alive@small", "https-keep-alive@small"])
        self.assertIn(f"small ended early: {stopped['reason']}.", markdown)

    def test_a_step_with_no_response_at_all_stops_the_profiles_remaining_steps_when_smock_is_gone(self):
        # The plain port answers the traffic check, then hangs up on every
        # connection: the step and the check after it get no response.
        plan_path = self.generator_plan()
        with LocalSmock() as smock, SilentPort(answer_first=True) as gate:
            status, lines, output = self.generate(plan_path, smock, plain=gate.port)
        self.assertEqual(status, 0, output)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "step", "traffic-check", "stopped",
                          "metrics-after", "done"])
        self.assertTrue(lines[2]["ok"], lines[2])
        self.assertEqual(lines[2]["address"], "127.0.0.1")
        step = lines[4]["result"]
        self.assertEqual((step["id"], step["requests"]["ok"]), ("http-keep-alive@small", 0))
        self.assertEqual(step["requests"]["no_response"], step["requests"]["scheduled"])
        # smock itself was there, and answered none of the step's
        # requests, which went elsewhere: no CPU time a request.
        self.assertEqual((step["smock_cpu"]["requests"], step["smock_cpu"]["us_per_request"]), (0, None))
        check = lines[5]
        self.assertEqual((check["after"], check["ok"], check["ports"]["plain"]["answered"]),
                         ("http-keep-alive@small", False, False))
        self.assertEqual(check["resolves_now"], "127.0.0.1")
        stopped = lines[6]
        self.assertRegex(stopped["reason"], r"^http-keep-alive@small got no response to any of its \d+ requests")
        self.assertIn(f", and smock did not answer through its Service in 2 s after it: plain port {gate.port} (",
                      stopped["reason"])
        self.assertEqual((stopped["after"], stopped["steps"]), ("http-keep-alive@small", ["https-keep-alive@small"]))

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertFalse(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]], ["http-keep-alive@small"])
        self.assertEqual(summary["gke"]["profiles"]["small"]["ended_early"],
                         {"reason": stopped["reason"], "after": "http-keep-alive@small",
                          "not_measured": ["https-keep-alive@small"]})
        self.assertIn("Not measured: https-keep-alive@small.", markdown)



def load_generator_module():
    """bench/gke/generator.py as a module, for its functions."""
    spec = importlib.util.spec_from_file_location("generator", BENCH / "gke" / "generator.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def no_response_step(step_id, scheduled=12500, ok=0, errors=None):
    """A step's result as the load generator reports it, with `ok` of its
    `scheduled` requests answered and the others not."""
    return {"id": step_id, "smock_ready": True,
            "requests": {"scheduled": scheduled, "ok": ok, "unexpected_status": 0, "no_response": scheduled - ok},
            "per_request": [{"oha_errors": errors or {}}]}


def check_result(ok, address="34.118.229.110", resolves_now=None):
    """A traffic check's result: both ports answered, or the TLS port did
    not."""
    tls = ({"port": 443, "answered": True, "status": 200, "attempts": 1, "seconds": 0.01, "error": None} if ok
           else {"port": 443, "answered": False, "status": None, "attempts": 12, "seconds": 60.1, "error": "timed out"})
    return {"ok": ok, "address": address, **({} if ok else {"resolves_now": resolves_now or address}),
            "host": "catalog.bench.internal", "method": "GET", "target": "/catalog/items/SKU-00317", "window_s": 60,
            "ports": {"plain": {"port": 80, "answered": True, "status": 200, "attempts": 1, "seconds": 0.01,
                                "error": None}, "tls": tls}}


class StopAfterAStep(unittest.TestCase):
    """A step with no response stops the rest of its profile only when
    smock does not answer a traffic check right after it: an overloaded
    smock can answer none of a step's measured requests, busy with those of
    its ramp until the step ends (https-keep-alive@autopilot-burst-min@4000
    answered 1,271 of 80,000 on 2026-10-14), and still be there."""

    generator = load_generator_module()
    spec = {"id": "http-keep-alive@autopilot-min@4000"}
    later = [{"id": "https-keep-alive@autopilot-min@625"}, {"id": "https-keep-alive@autopilot-min@1250"}]

    def stop_after(self, result, later, check):
        checks = []

        def check_again():
            checks.append(check)
            return check

        stopped, made = self.generator.stop_after(self.spec, result, later, check_again)
        return stopped, made, len(checks)

    def test_an_overloaded_smock_that_still_answers_goes_on(self):
        stopped, check, checks = self.stop_after(no_response_step(self.spec["id"]), self.later, check_result(True))
        self.assertIsNone(stopped)
        self.assertEqual((check["ok"], checks), (True, 1))

    def test_a_smock_that_does_not_answer_after_the_step_stops_the_rest(self):
        stopped, check, _ = self.stop_after(no_response_step(self.spec["id"], errors={"timeout": 12500}),
                                            self.later, check_result(False))
        self.assertFalse(check["ok"])
        self.assertEqual(stopped["reason"],
                         "http-keep-alive@autopilot-min@4000 got no response to any of its 12,500 requests "
                         "(oha: timeout), and smock did not answer through its Service in 60 s after it: "
                         "TLS port 443 (timed out)")
        self.assertEqual((stopped["after"], stopped["steps"]),
                         (self.spec["id"], ["https-keep-alive@autopilot-min@625", "https-keep-alive@autopilot-min@1250"]))

    def test_a_name_that_now_resolves_elsewhere_is_named(self):
        stopped, _, _ = self.stop_after(no_response_step(self.spec["id"]), self.later,
                                        check_result(False, resolves_now="34.118.228.162"))
        self.assertTrue(stopped["reason"].endswith("; the address checked was 34.118.229.110, and smock's name now "
                                                   "resolves to 34.118.228.162"), stopped["reason"])

    def test_a_step_with_a_response_or_the_last_step_checks_nothing(self):
        for result, later in ((no_response_step(self.spec["id"], ok=1), self.later),
                              (no_response_step(self.spec["id"]), [])):
            self.assertEqual(self.stop_after(result, later, check_result(False)), (None, None, 0))

def elf_header(machine, elf_class=2, data=1, elf_type=2):
    """The first 20 bytes of an ELF file: its identification, type and
    machine."""
    order = "<" if data == 1 else ">"
    return b"\x7fELF" + bytes([elf_class, data, 1]) + bytes(9) + struct.pack(order + "HH", elf_type, machine)


class BinaryArchitecture(Helper):
    """A binary that goes into an image is checked for the run's
    architecture before anything is made, by its ELF header: a binary of
    another architecture is not run to find out."""

    def arch_of(self, content):
        path = self.directory() / "binary"
        path.write_bytes(content + bytes(64))
        return helper("elf-arch", path)

    def test_the_architecture_is_read_from_the_elf_header(self):
        for machine, arch in ((62, "amd64"), (183, "arm64")):
            for elf_type in (2, 3):  # an executable, a position-independent one
                status, stdout, stderr = self.arch_of(elf_header(machine, elf_type=elf_type))
                self.assertEqual((status, stdout), (0, f"{arch}\n"), stderr)
        # This machine's python3, whatever it runs on.
        status, stdout, _ = helper("elf-arch", Path(sys.executable).resolve())
        self.assertEqual((status, stdout.strip()), (0, {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]))

    def test_what_is_not_a_64_bit_executable_of_either_architecture_is_refused(self):
        for content, expected in ((b"#!/bin/sh\necho smock\n", "not an ELF file"),
                                  (b"PK\x03\x04", "not an ELF file"),
                                  (b"\x7fEL", "not an ELF file"),
                                  (elf_header(40, elf_class=1), "not a 64-bit little-endian ELF file"),
                                  (elf_header(62, data=2), "not a 64-bit little-endian ELF file"),
                                  (elf_header(62, elf_type=1), "not an executable"),
                                  (elf_header(243), "machine 243, neither amd64 nor arm64")):
            status, stdout, stderr = self.arch_of(content)
            self.assertEqual((status, stdout), (1, ""), content)
            self.assertIn(expected, stderr)
        status, _, stderr = helper("elf-arch", self.directory() / "missing")
        self.assertEqual(status, 1)
        self.assertIn("cannot read", stderr)


class BuildCommit(Helper):
    """A smock binary that this machine cannot run is checked to be built
    from the commit checked out by its build information, which holds the
    commit that `smock --version` says."""

    def names(self, content, commit="0123456789ab"):
        path = self.directory() / "smock"
        path.write_bytes(elf_header(62) + bytes(64) + content + bytes(16))
        return helper("names-commit", path, commit)

    def test_the_commit_is_found_as_a_native_moonbit_build_keeps_it(self):
        for content in ("0123456789ab".encode("utf-16-le"), b"0123456789ab"):
            status, _, stderr = self.names(content)
            self.assertEqual(status, 0, stderr)
        # A release binary built here, which says its commit when run.
        version = subprocess.run([SMOCK, "--version"], capture_output=True, text=True, check=True).stdout
        commit = version.split("(commit ", 1)[1].split(",", 1)[0]
        status, _, stderr = helper("names-commit", SMOCK, commit)
        self.assertEqual(status, 0, stderr)

    def test_a_binary_of_another_commit_is_refused(self):
        status, _, stderr = self.names("ba988d7938dc".encode("utf-16-le"))
        self.assertEqual(status, 1)
        self.assertIn("does not name commit 0123456789ab in its build information", stderr)
        status, _, stderr = helper("names-commit", self.directory() / "missing", "0123456789ab")
        self.assertEqual(status, 1)
        self.assertIn("cannot read", stderr)


class Dockerfiles(Helper):
    """The images are built for the run's architecture, which may not be
    this machine's: a RUN instruction would need emulation, which this
    machine may not have, so the Dockerfiles may only copy."""

    DOCKERFILES = (ROOT / "Dockerfile", BENCH / "gke" / "smock-definitions.dockerfile",
                   BENCH / "gke" / "generator.Dockerfile")

    def check(self, text):
        path = self.directory() / "Dockerfile"
        path.write_text(text)
        return helper("check-dockerfiles", path)

    def test_the_images_dockerfiles_have_no_run_instruction(self):
        status, _, stderr = helper("check-dockerfiles", *self.DOCKERFILES)
        self.assertEqual(status, 0, stderr)

    def test_a_run_instruction_in_any_form_is_refused_with_its_line(self):
        for text, line in (("FROM scratch\nRUN true\n", 2),
                           ("FROM scratch\n  run apk add curl\n", 2),
                           ("FROM scratch\nCOPY a /a\nRUN set -e; \\\n  make\n", 3),
                           ("FROM scratch\nONBUILD RUN true\n", 2),
                           ("# escape=`\nFROM scratch\nCOPY a `\n  /a\nRUN true\n", 5)):
            status, _, stderr = self.check(text)
            self.assertEqual(status, 1, text)
            self.assertIn(f"Dockerfile:{line}: ", stderr)
            self.assertIn("RUN", stderr)

    def test_run_in_a_comment_or_in_another_instructions_arguments_is_no_instruction(self):
        status, _, stderr = self.check("# RUN apt-get install curl\nFROM scratch\nLABEL note=\"RUN nothing\"\n"
                                       "COPY a \\\n  # a comment in the middle\n  RUN /b\n")
        self.assertEqual(status, 0, stderr)


def cpuinfo_block(processor, model_name="AMD EPYC 7B13", family=25, model=1, stepping=0, microcode="0xffffffff",
                  flags="aes avx2 sha_ni vaes"):
    """A processor of /proc/cpuinfo as Linux writes it on an x86 virtual
    machine, with the flags of `flags` among others."""
    return (f"processor\t: {processor}\nvendor_id\t: {'AuthenticAMD' if 'AMD' in model_name else 'GenuineIntel'}\n"
            f"cpu family\t: {family}\nmodel\t\t: {model}\nmodel name\t: {model_name}\nstepping\t: {stepping}\n"
            f"microcode\t: {microcode}\ncpu MHz\t\t: 2449.998\ncache size\t: 512 KB\nphysical id\t: 0\n"
            f"siblings\t: 8\ncore id\t\t: {processor // 2}\ncpu cores\t: 4\nfpu\t\t: yes\n"
            f"flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic sep sse sse2 ht syscall nx lm constant_tsc "
            f"pni pclmulqdq ssse3 fma cx16 sse4_1 sse4_2 movbe popcnt xsave avx f16c rdrand hypervisor {flags} "
            f"bmi1 bmi2 adx clflushopt\n"
            f"bugs\t\t: sysret_ss_attrs spectre_v1 spectre_v2 spec_store_bypass srso\n"
            f"bogomips\t: 4899.99\naddress sizes\t: 48 bits physical, 48 bits virtual\npower management:\n\n")


# What Linux says of an AMD and of an Intel x86 CPU's vulnerabilities.
AMD_VULNERABILITIES = {
    "meltdown": "Not affected",
    "retbleed": "Not affected",
    "spec_rstack_overflow": "Vulnerable: Safe RET, no microcode",
    "spectre_v2": "Mitigation: Retpolines; IBPB: conditional; IBRS_FW; STIBP: always-on; RSB filling; "
                  "PBRSB-eIBRS: Not affected; BHI: Not affected",
}

INTEL_VULNERABILITIES = {
    "meltdown": "Mitigation: PTI",
    "retbleed": "Mitigation: IBRS",
    "spec_rstack_overflow": "Not affected",
    "spectre_v2": "Mitigation: IBRS; IBPB: conditional; STIBP: conditional; RSB filling; PBRSB-eIBRS: Not affected; "
                  "BHI: SW loop, KVM: SW loop",
}

# What gke.py node-cpu keeps of an AMD EPYC 7B13 (Zen 3) node's CPU.
AMD_CPU = {"model_name": "AMD EPYC 7B13", "vendor_id": "AuthenticAMD", "cpu_family": "25", "model": "1",
           "stepping": "0", "microcode": "0xffffffff",
           "flags": {"aes": True, "avx2": True, "sha_ni": True, "vaes": True},
           "vulnerabilities": AMD_VULNERABILITIES}

# And of an Intel Broadwell node's: no SHA or vector AES instructions.
INTEL_CPU = {"model_name": "Intel(R) Xeon(R) CPU @ 2.20GHz", "vendor_id": "GenuineIntel", "cpu_family": "6",
             "model": "79", "stepping": "0", "microcode": "0xffffffff",
             "flags": {"aes": True, "avx2": True, "sha_ni": False, "vaes": False},
             "vulnerabilities": INTEL_VULNERABILITIES}


class NodeCpu(Helper):
    """What smock's init container and the load generator say of the CPU
    of the node they run on: its model, microcode, the flags that make TLS
    fast and the kernel's mitigations of its vulnerabilities, from
    /proc/cpuinfo and /sys/devices/system/cpu/vulnerabilities."""

    def node_cpu(self, cpuinfo, vulnerabilities):
        """What gke.py node-cpu prints for a /proc/cpuinfo of `cpuinfo` (None:
        no file) and the vulnerabilities `vulnerabilities` ({name: text}, None:
        no directory): its exit status and its one JSON line."""
        directory = self.directory()
        args = ["node-cpu", "--cpuinfo", directory / "cpuinfo", "--vulnerabilities", directory / "vulnerabilities"]
        if cpuinfo is not None:
            (directory / "cpuinfo").write_text(cpuinfo)
        if vulnerabilities is not None:
            (directory / "vulnerabilities").mkdir()
            for name, text in vulnerabilities.items():
                (directory / "vulnerabilities" / name).write_text(text + "\n")
        status, stdout, stderr = helper(*args)
        return status, [json.loads(line) for line in stdout.splitlines()], stderr

    def test_an_x86_nodes_model_microcode_tls_flags_and_mitigations_are_printed(self):
        status, lines, stderr = self.node_cpu(cpuinfo_block(0) + cpuinfo_block(1), AMD_VULNERABILITIES)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": AMD_CPU}])
        status, lines, stderr = self.node_cpu(
            cpuinfo_block(0, model_name="Intel(R) Xeon(R) CPU @ 2.20GHz", family=6, model=79, flags="aes avx2"),
            INTEL_VULNERABILITIES)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": INTEL_CPU}])

    def test_an_arm64_node_is_named_by_its_implementer_and_part_with_its_own_tls_flags(self):
        # As Linux writes it on arm64, which has no model name or microcode.
        cpuinfo = ("processor\t: 0\nBogoMIPS\t: 48.00\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics "
                   "fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sha512\nCPU implementer\t: 0x41\n"
                   "CPU architecture: 8\nCPU variant\t: 0x0\nCPU part\t: 0xd4f\nCPU revision\t: 1\n\n")
        status, lines, stderr = self.node_cpu(cpuinfo, {"spectre_v2": "Not affected"})
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": {
            "model_name": "implementer 0x41, part 0xd4f", "cpu_implementer": "0x41", "cpu_architecture": "8",
            "cpu_variant": "0x0", "cpu_part": "0xd4f", "cpu_revision": "1", "microcode": None,
            "flags": {"aes": True, "pmull": True, "sha2": True}, "vulnerabilities": {"spectre_v2": "Not affected"}}}])

    def test_what_it_cannot_read_it_says_and_still_succeeds_so_that_smock_starts(self):
        # An init container that failed would keep smock's Pod from starting.
        status, lines, stderr = self.node_cpu(None, None)
        self.assertEqual(status, 0, stderr)
        [line] = lines
        self.assertEqual((line["kind"], line["cpu"]), ("node-cpu", None))
        self.assertIn("cpuinfo", line["error"])
        status, lines, stderr = self.node_cpu(cpuinfo_block(0), None)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": {**AMD_CPU, "vulnerabilities": None}}])


class PodInfo(Helper):
    def test_only_what_says_where_and_how_the_pods_ran_is_kept(self):
        directory = self.directory()
        image = "us-central1-docker.pkg.dev/a-private-project-123/smock-bench-1/smock@sha256:" + "1" * 64
        pod_list = {"items": [
            {"metadata": {"name": "smock-bench-1", "labels": {"app": "smock-bench"}},
             "spec": {"nodeName": "node-a", "containers": [{"image": image}]},
             "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                        "containerStatuses": [{"image": image, "imageID": image, "restartCount": 2,
                                               "lastState": {"terminated": {"reason": "OOMKilled"}}}]}},
            {"metadata": {"name": "generator-small-1", "labels": {"app": "smock-bench-generator"}},
             "spec": {"nodeName": "node-b", "containers": [{"image": image, "resources": {
                 "requests": {"cpu": "6", "memory": "6Gi", "ephemeral-storage": "2Gi"},
                 "limits": {"cpu": "6", "memory": "6Gi", "ephemeral-storage": "2Gi"}}}]},
             "status": {"phase": "Failed", "reason": "DeadlineExceeded", "containerStatuses": []}}]}
        labels = {"node.kubernetes.io/instance-type": "e4a-standard-8", "kubernetes.io/arch": "arm64",
                  "topology.kubernetes.io/zone": "us-central1-a", "cloud.google.com/machine-family": "e4a",
                  "cloud.google.com/compute-class": "autopilot-arm",
                  # The type of its boot disk, whose quota the run's checks
                  # take it to draw on.
                  "cloud.google.com/gke-boot-disk": "hyperdisk-balanced"}
        node_list = {"items": [{
            "metadata": {"name": "node-a", "labels": labels,
                         "annotations": {"container.googleapis.com/instance_id": "1234"}},
            "spec": {"providerID": "gce://a-private-project-123/us-central1-a/node-a"},
            "status": {"capacity": {"cpu": "8"}, "allocatable": {"cpu": "7910m"},
                       "nodeInfo": {"kernelVersion": "6.12.94+", "kubeletVersion": "v1.35.8-gke.1225000",
                                    "osImage": "Container-Optimized OS from Google"}}}]}
        (directory / "pods.json").write_text(json.dumps(pod_list))
        (directory / "nodes.json").write_text(json.dumps(node_list))
        status, stdout, stderr = helper("pod-info", directory / "pods.json", directory / "nodes.json")
        self.assertEqual(status, 0, stderr)
        self.assertNotIn("a-private-project-123", stdout)
        info = json.loads(stdout)
        self.assertEqual(info["smock"], [{"name": "smock-bench-1", "node": "node-a", "ready": True, "restarts": 2,
                                          "last_termination": "OOMKilled"}])
        self.assertEqual(info["generator"], [{"name": "generator-small-1", "node": "node-b", "phase": "Failed",
                                              "reason": "DeadlineExceeded", "cpu_request": "6"}])
        self.assertEqual(info["nodes"], {"node-a": NODE})


if __name__ == "__main__":
    unittest.main()
