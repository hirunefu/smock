"""Tests of the GKE Autopilot run's helper, bench/gke/gke.py: the manifests
it renders for each profile, its plan of the run and cost estimate, and the
summary it makes of what the load generator and the cluster reported.

They run the helper through its command line, as scripts/gke-bench.sh does,
and need python3 alone, but for the test of the load generator
(bench/gke/generator.py), which runs it against smock on this machine and
needs what the benchmark's own tests need: a release build of smock
(dist/smock, or SMOCK_BENCH_SMOCK) and oha (on PATH, or OHA).

usage: python3 -m unittest discover -s bench -v
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
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

    def manifests(self, profile="autopilot-min", arch="arm64", plan=BENCH / "plan-autopilot.json", cases=None):
        """The manifests rendered for one profile: {file name: objects}."""
        out = self.directory()
        args = ["manifests", "--plan", plan, "--profile", profile, "--arch", arch, "--zone", "us-central1-a",
                "--smock-image", SMOCK_IMAGE, "--generator-image", GENERATOR_IMAGE, "--out", out]
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
    return item["spec"]["template"]["spec"]


class Manifests(Helper):
    """Each profile runs smock in a Deployment whose requests are its
    limits, behind a ClusterIP Service, and the load generator in a Job on
    another node, both pinned to one zone, in a namespace that cannot have a
    LoadBalancer or a volume claim."""

    def test_smock_runs_under_the_profiles_limits_as_requests_behind_a_cluster_ip_service(self):
        rendered = self.manifests(profile="autopilot-burst-min")
        [deployment] = objects(rendered, "Deployment")
        [container] = pod_spec(deployment)["containers"]
        self.assertEqual(container["image"], SMOCK_IMAGE)
        resources = container["resources"]
        self.assertEqual((resources["limits"]["cpu"], resources["limits"]["memory"]), ("50m", "52Mi"))
        self.assertEqual(resources["requests"], resources["limits"])
        self.assertEqual(deployment["spec"]["replicas"], 1)
        [service] = objects(rendered, "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual({port["port"]: port["targetPort"] for port in service["spec"]["ports"]},
                         {80: 8080, 443: 8443, 9090: 9090})
        self.assertEqual(service["spec"]["selector"], deployment["spec"]["selector"]["matchLabels"])

    def test_the_load_generator_is_a_job_with_a_deadline_on_another_node_than_smock(self):
        rendered = self.manifests(profile="chart-default")
        [deployment] = objects(rendered, "Deployment")
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
        self.assertEqual(term["labelSelector"]["matchLabels"], deployment["spec"]["selector"]["matchLabels"])
        [container] = spec["containers"]
        self.assertEqual(container["image"], GENERATOR_IMAGE)
        self.assertEqual(container["resources"]["requests"], container["resources"]["limits"])
        env = {variable["name"]: variable["value"] for variable in container["env"]}
        self.assertEqual((env["PROFILE"], env["CASES"]), ("chart-default", "http-keep-alive,https-keep-alive"))

    def test_both_are_pinned_to_the_zone_and_to_the_compute_class_of_the_architecture(self):
        for arch, compute_class in (("arm64", "autopilot-arm"), ("amd64", None)):
            rendered = self.manifests(arch=arch)
            for item in [*objects(rendered, "Deployment"), *objects(rendered, "Job")]:
                selector = pod_spec(item)["nodeSelector"]
                self.assertEqual(selector["topology.kubernetes.io/zone"], "us-central1-a")
                self.assertEqual(selector["kubernetes.io/arch"], arch)
                self.assertEqual(selector.get("cloud.google.com/compute-class"), compute_class)

    def test_nothing_billed_outside_the_pods_can_be_made_in_the_namespace(self):
        rendered = self.manifests()
        kinds = {item["kind"] for items in rendered.values() for item in items}
        self.assertEqual(kinds, {"Namespace", "ResourceQuota", "Service", "Deployment", "Job"})
        for item in [*objects(rendered, "Deployment"), *objects(rendered, "Job")]:
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


def small_targets(directory):
    path = directory / "targets.json"
    path.write_text(json.dumps({"profiles": [{
        "profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "case": "http-keep-alive", "rate": 1000,
        "at_most": {"p99_ms": 3, "p99_9_ms": 5, "oom_kills": 0, "peak_memory_mib": 32, "idle_rss_mib": 20}}]}))
    return path


def generator_step(rate, p99=2.0, p99_9=2.5, errors=0):
    """A step line of the load generator for http-keep-alive under small."""
    scheduled = rate * 20
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
        "tcp_passive_opens": None, "idle_connections_open_at_end": None, "pinning": None, "smock_cpu": None,
        "memory": {"peak_bytes": None, "oom_kills": None}, "rss_kib": {"first": None, "last": None, "max": None},
        "smock_ready": True, "smock_exit_status": None, "per_request": []}}


START = {"kind": "start", "profile": "small", "oha": "oha 1.16.0", "cpus": 8, "affinity": 4,
         "status": {"version": "0.2.0", "commit": "a21fe97d59c6", "toolchain": "moonc v0.10.14+7d59c7ec9",
                    "digest": "48f7ce9715f0", "mocks": [{"name": "catalog"}]}}

NODE = {"instance_type": "e4a-standard-8", "arch": "arm64", "zone": "us-central1-a", "machine_family": "e4a",
        "compute_class": "autopilot-arm", "kernel": "6.12.94+", "kubelet": "v1.35.8-gke.1225000",
        "os_image": "Container-Optimized OS from Google", "cpus": "8", "allocatable_cpu": "7910m"}


def pods(restarts=0, reason=None):
    """What gke.py pod-info keeps of the profile's Pods and their nodes."""
    return {"smock": [{"name": "smock-bench-1", "node": "node-a", "ready": True, "restarts": restarts,
                       "last_termination": reason}],
            "generator": [{"name": "generator-small-1", "node": "node-b", "phase": "Succeeded", "reason": None}],
            "nodes": {"node-a": NODE, "node-b": NODE}}


class Summary(Helper):
    """A GKE run's results become a summary of the same layout as a run on
    a machine writes, which bench/compare.py reads, with its targets
    checked, and the conditions it ran under."""

    def results(self, lines, pod_info, rates=(500, 1000)):
        """A results directory as scripts/gke-bench.sh leaves it, with the
        load generator's log and the Pods of profile small, summarized."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        text = "".join(line if isinstance(line, str) else json.dumps(line) + "\n" for line in lines)
        (raw / "generator.log").write_text(text)
        (raw / "pods.json").write_text(json.dumps(pod_info))
        status, _, stderr = helper(
            "summarize", "--plan", small_plan(self.directory(), rates), "--targets", small_targets(self.directory()),
            "--region", "us-central1", "--zone", "us-central1-a", "--arch", "arm64",
            "--started-at", "2026-10-14T03:28:50+00:00", "--finished-at", "2026-10-14T04:01:56+00:00",
            "--cluster-version", "1.35.8-gke.1225000", "--smock-image", "sha256:" + "1" * 64,
            "--generator-image", "sha256:" + "2" * 64, out)
        self.assertEqual(status, 0, stderr)
        return out

    def test_each_step_the_load_generator_reported_is_a_case_and_the_targets_are_checked(self):
        out = self.results([START, "generator: step 500 requests/s\n", generator_step(500),
                            generator_step(1000, p99=2.5, p99_9=6.0), {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual(summary["format"], 4)
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@small@500", "http-keep-alive@small@1000"])
        self.assertEqual(summary["idle_rss"], [])
        verdicts = {target["id"]: (target["verdict"], target["measured"]) for target in summary["targets"]}
        self.assertEqual(verdicts, {
            "small/p99": ("met", 2.5),
            "small/p99_9": ("missed", 6.0),
            # smock never restarted, so the kernel never OOM-killed it.
            "small/oom_kills": ("met", 0),
            "small/peak_memory": ("not measured", None),
            "small/idle_rss": ("not measured", None),
        })
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(out), str(out)],
                                  capture_output=True, text=True)
        self.assertIn("| small | http-keep-alive | 1,000 | 2.5 → 2.5 | 0% |", compared.stdout, compared.stderr)

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

    def test_a_profile_cut_short_leaves_the_run_incomplete(self):
        out = self.results([START, generator_step(500), "generator: the deadline passed\n"], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])

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

    def estimate(self, *args, plan=BENCH / "plan-autopilot.json", region="us-central1", time_limit_s=4800):
        return helper("estimate", "--plan", plan, "--region", region, "--time-limit-s", time_limit_s, *args)

    def test_it_states_the_expected_cost_and_the_most_a_run_cut_off_at_the_time_limit_costs(self):
        status, stdout, stderr = self.estimate(time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("us-central1, on-demand prices of 2026-10-14, before tax", stdout)
        self.assertRegex(stdout, r"Expected: about \$0\.\d\d, the cluster existing for about \d+ minutes\.")
        # Until the watchdog deletes it at the time limit, and for the 5
        # minutes the deletion takes: the cluster's fee ($0.10 an hour), the
        # load generator (4 vCPU and 4Gi at $0.0445 and $0.0049225 an hour,
        # 2Gi of ephemeral storage at $0.0001389) and the largest smock (1
        # vCPU, 1Gi, 64Mi), $0.3474 an hour for 65 minutes.
        self.assertIn("At most: $0.38, if it ran until the time limit (60 minutes)", stdout)

    def test_a_region_without_prices_here_is_estimated_from_us_central1s_with_a_margin(self):
        status, stdout, _ = self.estimate(region="europe-west4")
        self.assertEqual(status, 0)
        self.assertIn("europe-west4: us-central1's prices plus 30%", stdout)

    def test_a_run_longer_than_the_time_limit_is_refused(self):
        status, stdout, stderr = self.estimate(time_limit_s=1200)
        self.assertEqual(status, 1)
        self.assertIn("more than the time limit of 20 minutes", stderr)


class LocalSmock:
    """smock serving the benchmark's definitions on this machine, on free
    ports, as the GKE run's image does."""

    def __enter__(self):
        self.process = subprocess.Popen(
            [SMOCK, "serve", "--dir", str(BENCH / "definitions"), "--port", "0", "--tls-port", "0", "--admin-port", "0",
             "--admin-auth", "off"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True, env={name: value for name, value in os.environ.items() if not name.startswith("SMOCK_")})
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


class Generator(Helper):
    """The load generator sends a profile's steps the way bench/bench.py
    does, and reports each as summarize reads it."""

    def test_each_step_of_the_profile_is_reported_and_summarized_as_a_case(self):
        plan = json.loads(small_plan(self.directory(), rates=(200,)).read_text())
        plan.update(ramp_s=0.5, duration_s=2, tail_s=1, cooldown_s=0)
        plan["cases"].append({**plan["cases"][0], "name": "https-keep-alive", "protocol": "https"})
        plan_path = self.directory() / "plan.json"
        plan_path.write_text(json.dumps(plan))
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        with LocalSmock() as smock:
            environment = {**os.environ, "TARGET": "localhost", "PROFILE": "small",
                           "CASES": "http-keep-alive,https-keep-alive", "PLAN": str(plan_path),
                           "PLAIN_PORT": smock.ports["plain"], "TLS_PORT": smock.ports["tls"],
                           "ADMIN_PORT": smock.ports["admin"], "OHA": shutil.which(OHA) or OHA}
            generator = subprocess.run([sys.executable, str(BENCH / "gke" / "generator.py")], env=environment,
                                       capture_output=True, text=True, timeout=120)
        self.assertEqual(generator.returncode, 0, generator.stderr)
        lines = [json.loads(line) for line in generator.stdout.splitlines()]
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "metrics-before", "step", "step", "metrics-after", "done"])
        self.assertRegex(lines[0]["status"]["digest"], "^[0-9a-f]{12}$")
        for step, protocol in zip([line["result"] for line in lines if line["kind"] == "step"], ("http", "https")):
            self.assertEqual((step["profile"], step["protocol"], step["rate"]), ("small", protocol, 200))
            self.assertEqual((step["errors"], step["smock_ready"]), (0, True))
            self.assertEqual(step["requests"]["ok"], step["requests"]["scheduled"])
            self.assertGreater(step["requests"]["scheduled"], 350)
            self.assertIsNotNone(step["latency_ms"]["p99_9"])
            self.assertEqual(len(step["per_request"]), 9)

        (raw / "generator.log").write_text(generator.stdout + generator.stderr)
        (raw / "pods.json").write_text(json.dumps(pods()))
        status, _, stderr = helper(
            "summarize", "--plan", plan_path, "--targets", small_targets(self.directory()), "--region", "us-central1",
            "--zone", "us-central1-a", "--arch", "arm64", "--started-at", "2026-10-14T03:28:50+00:00",
            "--finished-at", "2026-10-14T04:01:56+00:00", out)
        self.assertEqual(status, 0, stderr)
        summary = json.loads((out / "summary.json").read_text())
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]], ["http-keep-alive@small", "https-keep-alive@small"])


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
             "spec": {"nodeName": "node-b", "containers": [{"image": image}]},
             "status": {"phase": "Failed", "reason": "DeadlineExceeded", "containerStatuses": []}}]}
        labels = {"node.kubernetes.io/instance-type": "e4a-standard-8", "kubernetes.io/arch": "arm64",
                  "topology.kubernetes.io/zone": "us-central1-a", "cloud.google.com/machine-family": "e4a",
                  "cloud.google.com/compute-class": "autopilot-arm"}
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
                                              "reason": "DeadlineExceeded"}])
        self.assertEqual(info["nodes"], {"node-a": NODE})


if __name__ == "__main__":
    unittest.main()
