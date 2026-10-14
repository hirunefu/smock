"""Tests of scripts/gke-bench.sh, the GKE Autopilot run of the release
benchmark, against fake gcloud, kubectl and docker commands.

The fakes (FAKE below) record every call, keep which clusters and
repositories exist, and answer as the real commands do for what the script
asks. Nothing reaches a cloud. They need bash, python3 and setsid.

usage: python3 -m unittest discover -s bench -v
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
SCRIPT = ROOT / "scripts" / "gke-bench.sh"

# A project that does not exist: the fakes accept any.
PROJECT = "fake-project-123456"
PROJECT_NUMBER = "987654321098"

FAKE = r'''#!/usr/bin/env python3
"""A fake gcloud, kubectl or docker (by the name it is called with) for the
tests of scripts/gke-bench.sh."""
import fcntl
import json
import os
import stat
import sys
import time
from pathlib import Path

tool = Path(sys.argv[0]).name
argv = sys.argv[1:]
state_dir = Path(os.environ["FAKE_STATE"])
config = json.loads((state_dir / "config.json").read_text())
words = [arg for arg in argv if not arg.startswith("-")]
options = dict(arg[2:].split("=", 1) for arg in argv if arg.startswith("--") and "=" in arg)

record = {"tool": tool, "argv": argv, "words": words, "time": time.time(),
          "kubeconfig_env": os.environ.get("KUBECONFIG")}
if tool == "kubectl" and "kubeconfig" in options:
    path = Path(options["kubeconfig"])
    record["kubeconfig_mode"] = oct(stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
if tool == "docker" and "login" in words:
    record["stdin"] = sys.stdin.read()
if tool == "kubectl" and words[:1] == ["apply"]:
    record["document"] = json.loads(Path(options["filename"]).read_text())
with (state_dir / "calls.jsonl").open("a") as calls:
    fcntl.flock(calls, fcntl.LOCK_EX)
    calls.write(json.dumps(record) + "\n")


def state(change=None):
    """The fake cloud's state, changed by `change` under a lock."""
    with (state_dir / "state.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = state_dir / "state.json"
        value = json.loads(path.read_text()) if path.exists() else {"clusters": {}, "repositories": []}
        if change:
            change(value)
            path.write_text(json.dumps(value))
        return value


def answer(text="", status=0):
    sys.stdout.write(text)
    sys.exit(status)


def rule(name):
    """What the test configured for a call, by its name."""
    value = config.get(name)
    if isinstance(value, dict):
        time.sleep(value.get("sleep", 0))
        if "status" in value:
            sys.stderr.write(value.get("stderr", f"fake {tool}: {name} failed\n"))
            sys.exit(value["status"])
    return value


if tool == "gcloud":
    command = tuple(words[:3])
    if words[:1] == ["version"]:
        answer("Google Cloud SDK 589.0.0\n")
    if words[:2] == ["config", "get-value"]:
        answer(config.get("account", "") + "\n")
    if words[:2] == ["projects", "describe"]:
        answer(config.get("project_number", "''' + PROJECT_NUMBER + r'''") + "\n")
    if words[:2] == ["services", "list"]:
        answer("".join(f"{api}\n" for api in config.get("services", [
            "artifactregistry.googleapis.com", "compute.googleapis.com", "container.googleapis.com"])))
    if command == ("compute", "project-info", "describe"):
        answer(json.dumps({"quotas": [{"metric": "CPUS_ALL_REGIONS", "limit": config.get("cpus_all_regions", 32.0),
                                       "usage": 0.0}]}))
    if command == ("compute", "regions", "describe"):
        answer(json.dumps({"quotas": [{"metric": "CPUS", "limit": config.get("regional_cpus", 200.0), "usage": 0.0}]}))
    if command == ("compute", "zones", "describe"):
        answer(words[3].rsplit("-", 1)[0] + "\n")
    if command == ("container", "clusters", "list"):
        clusters = state()["clusters"]
        if "status" in options.get("format", ""):
            answer("".join(f"{name}\t{status}\n" for name, status in clusters.items()))
        answer("".join(f"{name}\tus-central1\n" for name in clusters))
    if command == ("container", "clusters", "create-auto"):
        state(lambda value: value["clusters"].update({words[3]: "PROVISIONING"}))
        rule("create_cluster")
        state(lambda value: value["clusters"].update({words[3]: "RUNNING"}))
        answer("Created.\n")
    if command == ("container", "clusters", "describe"):
        answer("34.0.0.1\tQ0EK\t1.35.8-gke.1225000\n")
    if command == ("container", "clusters", "delete"):
        rule("delete_cluster")
        state(lambda value: value["clusters"].pop(words[3], None))
        answer("Deleting.\n")
    if command == ("artifacts", "repositories", "list"):
        # As the real gcloud: whole names in JSON, short ones in value(name),
        # and a location that fails with a server error listed as empty,
        # with a warning.
        names = state()["repositories"]
        if config.get("repositories_list_fails"):
            sys.stderr.write(f"WARNING: Failed to list repositories for project {options['project']}\n")
            names = []
        if options.get("format") == "json":
            answer(json.dumps([{"name": f"projects/{options['project']}/locations/us-central1/repositories/{name}"}
                               for name in names]))
        answer("".join(f"{name}\n" for name in names))
    if command == ("artifacts", "repositories", "describe"):
        rule("describe_repository")
        if words[3] in state()["repositories"]:
            answer(f"projects/{options['project']}/locations/us-central1/repositories/{words[3]}\n")
        sys.stderr.write("ERROR: (gcloud.artifacts.repositories.describe) NOT_FOUND: Requested entity was not "
                         "found.\n")
        answer("", 1)
    if command == ("artifacts", "repositories", "create"):
        state(lambda value: value["repositories"].append(words[3]))
        answer()
    if command == ("artifacts", "repositories", "delete"):
        rule("delete_repository")
        state(lambda value: value["repositories"].remove(words[3]) if words[3] in value["repositories"] else None)
        answer()
    if words[:2] == ["auth", "print-access-token"]:
        answer("fake-access-token\n")
    if words[0] == "compute" and words[-1] == "list":
        answer("".join(f"{name}\tus-central1-a\n" for name in config.get(words[1], [])))
    answer()

if tool == "docker":
    if words[:1] == ["push"]:
        answer(f"{words[1].rsplit(':', 1)[1]}: digest: sha256:{'ab' * 32} size: 1234\n")
    answer()

if tool == "kubectl":
    if words[:1] == ["version"] and config.get("kubectl_broken"):
        sys.stderr.write("mise ERROR No version is set for shim: kubectl\n")
        answer("", 1)
    if words[:1] == ["apply"]:
        if config.get("apply_fails_on") and config["apply_fails_on"] in options.get("filename", ""):
            answer("", 1)
        answer("applied\n")
    if words[:1] == ["wait"]:
        rule("smock_ready")
        answer("pod/smock-bench condition met\n")
    if words[:2] == ["get", "events"]:
        answer(config.get("events", ""))
    if words[:2] == ["get", "pods"] and "selector" in options:
        answer(config.get("job_pod_phase", "Succeeded"))
    if words[:2] == ["get", "job"]:
        answer(config.get("job_state", "Complete=True "))
    if words[:1] == ["logs"]:
        job = words[1].removeprefix("job/")
        answer(Path(config["logs"][job]).read_text() if job in config.get("logs", {}) else "")
    if words[:2] == ["get", "pods"]:
        answer(json.dumps(config.get("pods", {"items": []})))
    if words[:2] == ["get", "nodes"]:
        answer(json.dumps({"items": []}))
    answer()
'''

# A fake date: time passes FAKE_TIME_SCALE times as fast for the script as
# it does, from the first time it is asked.
FAKE_DATE = r'''#!/usr/bin/env python3
import os
import shutil
import sys
import time
from pathlib import Path

here = str(Path(sys.argv[0]).resolve().parent)
path = os.pathsep.join(entry for entry in os.environ["PATH"].split(os.pathsep) if entry != here)
real = shutil.which("date", path=path)
args = sys.argv[1:]
if any(arg.startswith(("-d", "--date")) for arg in args):
    os.execv(real, [real, *args])
base_file = Path(os.environ["FAKE_STATE"]) / "time-base"
if not base_file.exists():
    base_file.write_text(str(time.time()))
base = float(base_file.read_text())
now = base + (time.time() - base) * float(os.environ.get("FAKE_TIME_SCALE", "1"))
os.execv(real, [real, "-d", f"@{now:.0f}", *args])
'''

# What a run of the small plan sends: one profile, small, and one case at
# two rates.
SMALL_PLAN = {
    "profiles": [{"name": "small", "cpu_limit": "250m", "memory_limit": "512Mi"}],
    "ramp_s": 2, "duration_s": 20, "tail_s": 3, "cooldown_s": 2, "rss_interval_s": 0.5, "idle_rss": {"settle_s": 5},
    "load_generator": {"name": "oha", "version": "1.16.0"},
    "cases": [{"name": "http-keep-alive", "protocol": "http", "connection": "keep-alive", "connections": 64,
               "rates": {"small": [500, 1000]}}],
}


def generator_log():
    """What the load generator writes for the small plan."""
    lines = [{"kind": "start", "profile": "small", "oha": "oha 1.16.0",
              "status": {"version": "0.2.0", "commit": "a21fe97d59c6", "toolchain": "moonc", "digest": "48f7ce9715f0",
                         "mocks": []}}]
    for rate in (500, 1000):
        lines.append({"kind": "step", "result": {
            "id": f"http-keep-alive@small@{rate}", "case": "http-keep-alive", "profile": "small", "cpu_limit": "250m",
            "memory_limit": "512Mi", "rate": rate, "ramp_s": 2, "duration_s": 20, "tail_s": 3, "connections": 64,
            "protocol": "http", "connection": "keep-alive", "idle_connections": 0,
            "achieved_rate": rate, "errors": 0,
            "latency_ms": {"p50": 1.2, "p90": 1.6, "p99": 2.0, "p99_9": 2.5, "max": 4.0},
            "latency_from_release_ms": {"p50": 0.3, "p90": 0.5, "p99": 1.0, "p99_9": 1.5, "max": 3.0},
            "generator_lag_ms": {"p50": 1.0, "p99": 1.9, "p99_9": 2.0, "max": 3.1}, "load_generator_late": False,
            "requests": {"scheduled": rate * 20, "ok": rate * 20, "unexpected_status": 0, "no_response": 0},
            "smock_cpu": None, "memory": {"peak_bytes": None, "oom_kills": None},
            "rss_kib": {"first": None, "last": None, "max": None}, "smock_ready": True}})
    lines.append({"kind": "done", "profile": "small"})
    return "".join(json.dumps(line) + "\n" for line in lines)


PODS = {"items": [{"metadata": {"name": "smock-bench-1", "labels": {"app": "smock-bench"}},
                   "spec": {"nodeName": "node-a"},
                   "status": {"conditions": [{"type": "Ready", "status": "True"}],
                              "containerStatuses": [{"restartCount": 0, "lastState": {}}]}}]}

# What only reads: the gcloud commands that list, describe or print.
READ_ONLY = {"list", "describe", "version", "print-access-token", "get-value"}

# The account gcloud is logged in as, in the fakes.
ACCOUNT = "someone.else+bench@example.com"


class Script(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="smock-gke-script-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for tool in ("gcloud", "kubectl", "docker"):
            (self.bin / tool).write_text(FAKE)
            (self.bin / tool).chmod(0o755)
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.plan = self.tmp / "plan.json"
        self.plan.write_text(json.dumps(SMALL_PLAN))
        (self.tmp / "generator-small.log").write_text(generator_log())
        self.configure()
        self.smock = self.tmp / "smock"
        self.smock.write_text("not a real binary")
        self.oha = self.tmp / "oha"
        self.oha.write_text("not a real binary")
        self.out = self.tmp / "out"
        self.tmpdir = self.tmp / "tmp"
        self.tmpdir.mkdir()
        self.addCleanup(self.stop_watchdog)

    def stop_watchdog(self):
        """Stops a watchdog that a test left waiting, before the fakes and its
        stop file go."""
        log = self.out / "watchdog.log"
        if not log.exists():
            return
        (self.out / ".watchdog-stop").touch()
        deadline = time.monotonic() + 30
        while not any(end in log.read_text() for end in ("stopping", "stopped by the run", "watchdog: done")):
            if time.monotonic() > deadline:
                self.fail(f"the watchdog did not stop:\n{log.read_text()}")
            time.sleep(0.05)

    def fake_time(self, scale):
        """Makes time pass `scale` times as fast for the script."""
        (self.bin / "date").write_text(FAKE_DATE)
        (self.bin / "date").chmod(0o755)
        self.time_scale = str(scale)

    def configure(self, **config):
        config.setdefault("logs", {"generator-small": str(self.tmp / "generator-small.log")})
        config.setdefault("pods", PODS)
        config.setdefault("account", ACCOUNT)
        (self.state / "config.json").write_text(json.dumps(config))

    def environment(self, **changes):
        environment = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "FAKE_STATE": str(self.state),
                       "GKE_BENCH_PROJECT": PROJECT, "GKE_BENCH_REGION": "us-central1", "GKE_BENCH_POLL_S": "0.05",
                       "FAKE_TIME_SCALE": getattr(self, "time_scale", "1"), "TMPDIR": str(self.tmpdir)}
        for name in ("GCLOUD", "KUBECTL", "DOCKER", "GKE_BENCH_ZONE", "GKE_BENCH_NEEDED_CPUS"):
            environment.pop(name, None)
        environment.update(changes)
        return {name: value for name, value in environment.items() if value is not None}

    def arguments(self, *args):
        return [str(SCRIPT), "--plan", str(self.plan), "--smock", str(self.smock), "--oha", str(self.oha),
                "--out", str(self.out), *map(str, args)]

    def run_script(self, *args, timeout=120, **environment):
        result = subprocess.run(self.arguments(*args), env=self.environment(**environment), capture_output=True,
                                text=True, timeout=timeout)
        return result.returncode, result.stdout + result.stderr

    def start_script(self, *args, **environment):
        """Starts the script in its own process group, so that a test can
        stop it as a terminal would, or kill it."""
        process = subprocess.Popen(self.arguments(*args), env=self.environment(**environment), stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.addCleanup(self.stop_group, process)
        return process

    def stop_group(self, process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()

    def calls(self, tool=None):
        path = self.state / "calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if tool is None or call["tool"] == tool]

    def wait_for_call(self, words, timeout=30):
        """Waits until a call starting with `words` has been made."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(call["words"][:len(words)] == words for call in self.calls()):
                return
            time.sleep(0.05)
        self.fail(f"no call {words} in {[call['words'] for call in self.calls()]}")

    def changing_calls(self):
        """The calls that change something: every docker call but `version`,
        every kubectl call but `get`, `logs` and `version`, and the gcloud
        calls that do not only read."""
        changing = []
        for call in self.calls():
            words = call["words"]
            if call["tool"] == "gcloud" and not READ_ONLY & set(words):
                changing.append(call)
            elif call["tool"] == "kubectl" and words[:1] not in (["get"], ["logs"], ["version"]):
                changing.append(call)
            elif call["tool"] == "docker" and words[:1] != ["version"]:
                changing.append(call)
        return changing

    def made(self, words):
        return [call for call in self.calls() if call["words"][:len(words)] == words]

    def state_now(self):
        path = self.state / "state.json"
        return json.loads(path.read_text()) if path.exists() else {"clusters": {}, "repositories": []}

    def wait_for_nothing_left(self, timeout=60):
        deadline = time.monotonic() + timeout
        while self.state_now() != {"clusters": {}, "repositories": []}:
            if time.monotonic() > deadline:
                self.fail(f"still there: {self.state_now()}")
            time.sleep(0.1)

    def watchdog_log(self):
        path = self.out / "watchdog.log"
        return path.read_text() if path.exists() else ""


class BeforeAnything(Script):
    """Nothing is made before the project and region are known, the checks
    pass and the cost is accepted."""

    def test_without_the_project_and_region_it_says_what_to_set_and_calls_nothing(self):
        for missing in ("GKE_BENCH_PROJECT", "GKE_BENCH_REGION"):
            status, output = self.run_script("--dry-run", **{missing: None})
            self.assertEqual(status, 2, output)
            self.assertIn(missing, output)
        self.assertEqual(self.calls(), [])

    def test_without_yes_it_prints_the_estimate_and_makes_nothing(self):
        status, output = self.run_script()
        self.assertEqual(status, 0, output)
        self.assertIn("Cost estimate (us-central1", output)
        self.assertIn("At most: $", output)
        self.assertIn("Nothing was made. To make these and run the benchmark, run it again with --yes.", output)
        self.assertEqual(self.changing_calls(), [])

    def test_a_time_limit_without_its_unit_or_past_four_hours_is_refused(self):
        # 4800 meant as seconds would be 80 hours as minutes.
        for limit, expected in (("4800", "with their unit"), ("241m", "at most 240m"), ("14401s", "at most 240m")):
            status, output = self.run_script("--dry-run", "--time-limit", limit)
            self.assertEqual(status, 2, output)
            self.assertIn(expected, output)
        self.assertEqual(self.calls(), [])
        status, output = self.run_script("--dry-run", "--time-limit", "240m")
        self.assertEqual(status, 0, output)

    def test_too_little_cpu_quota_stops_it_with_what_the_run_needs(self):
        self.configure(cpus_all_regions=24.0)
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("CPUS_ALL_REGIONS: 24 of 24 vCPUs free, the run needs 32", output)
        self.assertEqual(self.changing_calls(), [])
        self.configure(regional_cpus=16.0)
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("CPUS in us-central1: 16 of 16 vCPUs free, the run needs 32", output)
        self.assertEqual(self.changing_calls(), [])

    def test_apis_not_enabled_stop_it_with_the_command_that_enables_them(self):
        self.configure(services=["compute.googleapis.com"])
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn('gcloud services enable artifactregistry.googleapis.com container.googleapis.com '
                      '--project="$GKE_BENCH_PROJECT"', output)
        self.assertEqual(self.changing_calls(), [])
        # --enable-apis enables them, once the cost is accepted.
        self.run_script("--yes", "--enable-apis")
        self.assertEqual(self.made(["services", "enable"])[0]["words"][2:4],
                         ["artifactregistry.googleapis.com", "container.googleapis.com"])

    def test_a_cluster_left_by_an_earlier_run_stops_it(self):
        (self.state / "state.json").write_text(json.dumps({"clusters": {"smock-bench-20261013-101010": "RUNNING"},
                                                           "repositories": []}))
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("smock-bench-20261013-101010", output)
        self.assertEqual(self.changing_calls(), [])


    def test_a_repository_left_by_an_earlier_run_stops_it(self):
        (self.state / "state.json").write_text(json.dumps({"clusters": {},
                                                           "repositories": ["smock-bench-20261013-101010"]}))
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("repository smock-bench-20261013-101010 (us-central1) is left from an earlier run", output)
        self.assertEqual(self.changing_calls(), [])

    def test_a_listing_of_repositories_that_failed_somewhere_stops_it(self):
        # gcloud lists a location that fails with a server error as empty,
        # and warns.
        self.configure(repositories_list_fails=True)
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("cannot list what the project has", output)
        self.assertEqual(self.changing_calls(), [])

    def test_a_kubectl_that_does_not_run_stops_it_before_anything_is_made(self):
        # As a mise shim with no version set for the directory.
        self.configure(kubectl_broken=True)
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("version --client` failed", output)
        self.assertEqual(self.changing_calls(), [])


class DryRun(Script):
    """--dry-run prints every command a run would run, and runs only those
    that read."""

    def test_it_prints_each_command_of_the_run_and_runs_only_those_that_read(self):
        status, output = self.run_script("--dry-run")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.changing_calls(), [])
        # kubectl and docker only say that they run.
        self.assertEqual([call["words"] for call in self.calls("kubectl") + self.calls("docker")],
                         [["version"], ["version"]])
        for expected in ("would run: docker build", "would run: gcloud artifacts repositories create smock-bench-",
                         "would run: gcloud container clusters create-auto smock-bench-",
                         "--labels=purpose=smock-bench,run=", "would run: kubectl", "apply --filename=",
                         "would run: gcloud container clusters delete smock-bench-",
                         "would run: gcloud artifacts repositories delete smock-bench-",
                         "Cost estimate (us-central1"):
            self.assertIn(expected, output)
        # The project shows as the variable that holds it.
        self.assertNotIn(PROJECT, output)
        self.assertIn('--project="$GKE_BENCH_PROJECT"', output)


class Run(Script):
    """A run makes a labelled repository and cluster, runs each profile,
    writes the summary, and deletes everything it made."""

    def test_a_run_writes_the_summary_and_leaves_nothing(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        [repository] = self.made(["artifacts", "repositories", "create"])
        [cluster] = self.made(["container", "clusters", "create-auto"])
        for call in (repository, cluster):
            self.assertIn("--labels=purpose=smock-bench,run=", " ".join(call["argv"]))
        self.assertTrue(cluster["words"][3].startswith("smock-bench-"))
        applied = [Path(call["argv"][-1].split("=", 1)[1]).name for call in self.made(["apply"])]
        self.assertEqual(applied, ["namespace.json", "smock.json", "generator.json"])
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertTrue(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500, 1000])
        self.assertTrue((self.out / "summary.md").exists())
        self.assertTrue((self.out / "raw" / "small" / "pods.json").exists())
        # Deleted, and checked.
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})
        self.assertIn("nothing is left", output)
        # The watchdog stops either on the run's TERM or, if it sees the
        # stop file first, by itself; both mean the run stopped it.
        stopped = ("watchdog: stopped by the run", "watchdog: the run cleaned up; stopping")
        deadline = time.monotonic() + 5
        while not any(s in self.watchdog_log() for s in stopped) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(any(s in self.watchdog_log() for s in stopped), self.watchdog_log())
        # The project is nowhere in what the run wrote.
        for path in self.out.rglob("*"):
            if path.is_file():
                self.assertNotIn(PROJECT, path.read_text(), path)
        # Whether the cluster is gone is read from the region's clusters, by
        # name; VM instances are among what is checked at the end.
        for call in self.made(["container", "clusters", "list"]):
            if "status" in " ".join(call["argv"]):
                self.assertIn("--region=us-central1", call["argv"])
        self.assertTrue(self.made(["compute", "instances", "list"]))
        # smock runs in a Pod that ends by itself by the time limit (80
        # minutes by default), as the load generator's Job does.
        [apply] = [call for call in self.made(["apply"]) if call["argv"][-1].endswith("smock.json")]
        [pod] = [item for item in apply["document"]["items"] if item["kind"] == "Pod"]
        self.assertGreater(pod["spec"]["activeDeadlineSeconds"], 70 * 60)
        self.assertLessEqual(pod["spec"]["activeDeadlineSeconds"], 80 * 60)
        self.assertEqual(self.made(["wait"])[0]["words"][1:], ["pod/smock-bench"])

    def test_kubectl_uses_its_own_kubeconfig_with_an_access_token_deleted_at_the_end(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        # Every call that reaches the cluster; `version --client` does not.
        kubectl = [call for call in self.calls("kubectl") if call["words"][:1] != ["version"]]
        self.assertEqual({call["kubeconfig_mode"] for call in kubectl}, {"0o600"})
        kubeconfigs = {call["argv"][0] for call in kubectl}
        [kubeconfig] = kubeconfigs
        self.assertFalse(Path(kubeconfig.split("=", 1)[1]).exists())
        # gcloud writes the cluster's credentials beside it, not into
        # ~/.kube/config.
        [create] = self.made(["container", "clusters", "create-auto"])
        self.assertEqual(Path(create["kubeconfig_env"]).parent, Path(kubeconfig.split("=", 1)[1]).parent)
        # The token never shows on a command line.
        for call in self.calls():
            self.assertNotIn("fake-access-token", " ".join(call["argv"]))
        [login] = self.made(["login"])
        self.assertEqual(login["stdin"].strip(), "fake-access-token")

    def test_a_run_that_fails_midway_deletes_what_it_made(self):
        self.configure(apply_fails_on="generator.json")
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertTrue(self.made(["container", "clusters", "delete"]))
        self.assertTrue(self.made(["artifacts", "repositories", "delete"]))
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})


class Interrupted(Script):
    """However a run ends, the cluster and the repository are deleted."""

    def interrupt(self, send):
        # The cluster is being made when the run is stopped.
        self.configure(create_cluster={"sleep": 60})
        process = self.start_script("--yes")
        self.wait_for_call(["container", "clusters", "create-auto"])
        send(process)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertTrue(self.made(["container", "clusters", "delete"]), output)
        self.assertTrue(self.made(["artifacts", "repositories", "delete"]), output)
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})
        return output

    def test_ctrl_c_in_the_terminal_deletes_what_the_run_made(self):
        output = self.interrupt(lambda process: os.killpg(process.pid, signal.SIGINT))
        self.assertIn("stopped by SIGINT", output)

    def test_sigterm_deletes_what_the_run_made(self):
        output = self.interrupt(lambda process: process.send_signal(signal.SIGTERM))
        self.assertIn("stopped by SIGTERM", output)

    def test_a_closed_terminal_deletes_what_the_run_made_and_logs_it_to_a_file(self):
        # Writing to a terminal that has gone fails; the clean-up writes to
        # a file instead.
        self.interrupt(lambda process: os.killpg(process.pid, signal.SIGHUP))
        log = (self.out / "after-hangup.log").read_text()
        self.assertIn("stopped by SIGHUP", log)
        self.assertIn("nothing is left", log)

    def test_the_watchdog_deletes_them_at_the_time_limit_when_the_script_was_killed(self):
        # 40 minutes pass in 20 s; smock never becomes ready, and the script
        # is killed, so that no trap of its own runs.
        self.fake_time(120)
        self.configure(smock_ready={"sleep": 300})
        process = self.start_script("--yes", "--time-limit", "40m")
        self.wait_for_call(["wait"])
        [ready] = self.made(["wait"])
        work = Path(ready["argv"][0].split("=", 1)[1]).parent
        os.killpg(process.pid, signal.SIGKILL)
        # Reaped, as a shell would.
        process.wait()
        self.assertNotEqual(self.state_now()["clusters"], {})
        self.wait_for_nothing_left()
        deadline = time.monotonic() + 10
        while "watchdog: done" not in self.watchdog_log() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertIn("watchdog: the time limit has passed", self.watchdog_log())
        # The kubeconfig and the registry login went with the script's
        # temporary directory.
        self.assertFalse(work.exists())


class Watchdog(Script):
    def test_nothing_is_made_when_the_watchdog_cannot_start(self):
        # Its log cannot be written.
        (self.out / "watchdog.log").mkdir(parents=True)
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("the watchdog did not start", output)
        self.assertEqual(self.made(["artifacts", "repositories", "create"]), [])
        self.assertEqual(self.made(["container", "clusters", "create-auto"]), [])
        (self.out / "watchdog.log").rmdir()

    def test_the_watchdog_stops_no_process_but_the_run_that_started_it(self):
        # The run has ended, and its process number now belongs to another
        # process; the run left its cluster, its repository and its
        # temporary directory.
        stranger = subprocess.Popen(["sleep", "60"])
        self.addCleanup(stranger.wait)
        self.addCleanup(stranger.kill)
        (self.state / "state.json").write_text(json.dumps({"clusters": {"smock-bench-20261014-010101": "RUNNING"},
                                                           "repositories": ["smock-bench-20261014-010101"]}))
        work = self.tmpdir / "smock-gke-bench.abc123"
        work.mkdir()
        (work / "kubeconfig").write_text("token: fake-access-token\n")
        environment = self.environment(
            GKE_BENCH_WATCHDOG_DEADLINE=str(int(time.time())), GKE_BENCH_WATCHDOG_PARENT=str(stranger.pid),
            GKE_BENCH_WATCHDOG_STOP=str(self.tmp / "stop"), GKE_BENCH_CLUSTER="smock-bench-20261014-010101",
            GKE_BENCH_REPOSITORY="smock-bench-20261014-010101", GKE_BENCH_WORK=str(work))
        result = subprocess.run([str(SCRIPT), "--watchdog"], env=environment, capture_output=True, text=True,
                                timeout=60)
        self.assertIn("watchdog: done", result.stderr)
        self.assertIsNone(stranger.poll(), "the watchdog stopped a process that was not the run")
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})
        self.assertFalse(work.exists())


class Privacy(Script):
    def test_kubernetes_events_and_errors_show_neither_the_project_nor_the_account(self):
        # smock never becomes ready, and the events name its image, in the
        # project's registry, and the account.
        image = f"us-central1-docker.pkg.dev/{PROJECT}/smock-bench-1/smock@sha256:" + "1" * 64
        self.configure(smock_ready={"status": 1, "stderr": f'error: User "{ACCOUNT}" cannot get pods\n'},
                       events=f"Warning  Failed  pod/smock-bench  Failed to pull image \"{image}\"\n")
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("Failed to pull image", output)
        self.assertIn("cannot get pods", output)
        self.assertNotIn(PROJECT, output)
        self.assertNotIn(ACCOUNT, output)
        self.assertIn("<account>", output)

    def test_the_nodes_service_account_runs_the_nodes_and_may_read_the_images(self):
        account = f"smock-bench-nodes@{PROJECT}.iam.gserviceaccount.com"
        status, output = self.run_script("--yes", GKE_BENCH_NODE_SERVICE_ACCOUNT=account)
        self.assertEqual(status, 0, output)
        [grant] = self.made(["artifacts", "repositories", "add-iam-policy-binding"])
        self.assertIn(f"--member=serviceAccount:{account}", grant["argv"])
        [cluster] = self.made(["container", "clusters", "create-auto"])
        self.assertIn(f"--service-account={account}", cluster["argv"])


class Leftovers(Script):
    def test_something_the_run_could_not_delete_fails_it_and_is_named(self):
        # The cluster cannot be deleted; its deletion is given up after 30
        # minutes, which pass in 3 s.
        self.fake_time(600)
        self.configure(delete_cluster={"status": 1})
        status, output = self.run_script("--yes", timeout=120)
        self.assertEqual(status, 1, output)
        [cluster] = self.made(["container", "clusters", "create-auto"])
        self.assertIn("LEFT AFTER THE RUN", output)
        self.assertIn(f"cluster {cluster['words'][3]} us-central1", output)


    def test_a_repository_whose_state_cannot_be_read_is_not_taken_for_deleted(self):
        # Describing it fails with a server error, never NOT_FOUND.
        self.fake_time(600)
        self.configure(describe_repository={"status": 1, "stderr": "ERROR: (gcloud.artifacts.repositories.describe) "
                                                                   "UNAVAILABLE: try again\n"})
        status, output = self.run_script("--yes", timeout=120)
        self.assertEqual(status, 1, output)
        [repository] = self.made(["artifacts", "repositories", "create"])
        self.assertNotIn(f"repository {repository['words'][3]}: deleted", output)
        self.assertIn("LEFT AFTER THE RUN", output)
        self.assertIn(f"repository {repository['words'][3]} us-central1", output)


if __name__ == "__main__":
    unittest.main()
