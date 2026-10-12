"""Tests of the release benchmark, bench/bench.py, through its command line.

Each test runs the benchmark against the real smock binary, at a few hundred
requests per second for a few seconds, and reads the files it writes. They
need what a benchmark run needs (see the README): a release build of smock
(dist/smock, or SMOCK_BENCH_SMOCK), oha (on PATH, or OHA), openssl, taskset,
and a systemd user manager that can set CPU quotas.

usage: python3 -m unittest discover -s bench -v
"""

import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
SMOCK = os.environ.get("SMOCK_BENCH_SMOCK", str(ROOT / "dist" / "smock"))
OHA = os.environ.get("OHA", "oha")

# A short run: smock idles for half a second before its idle RSS is read;
# in each case, requests scheduled in the first half second are not counted,
# then 4 s are measured, then 2 s let the last requests finish; no pause
# between cases.
SHORT = ["--ramp", "0.5", "--duration", "4", "--tail", "2", "--settle", "0.5", "--cooldown", "0"]


def bench(test, *args, on_line=None):
    """Runs `bench.py run` with `args` into a new directory, checks that it
    succeeds, and returns the directory. `on_line` sees each line the run
    writes to stderr as it comes."""
    out = Path(tempfile.mkdtemp(prefix="smock-bench-test-"))
    test.addCleanup(shutil.rmtree, out, ignore_errors=True)
    command = [sys.executable, str(BENCH / "bench.py"), "run", "--smock", SMOCK, "--oha", OHA, "--out", str(out), *args]
    process = subprocess.Popen(command, stderr=subprocess.PIPE, text=True)
    lines = []
    for line in process.stderr:
        lines.append(line)
        if on_line:
            on_line(line)
    process.stderr.close()
    test.assertEqual(process.wait(), 0, "".join(lines))
    return out


def load_started(line):
    """The smock PID and the load generator PIDs of a case's `load started`
    progress line, or None."""
    match = re.search(r"load started \(smock pid (\d+), load generator pids ([\d ]+)\)", line)
    if not match:
        return None
    return int(match.group(1)), [int(pid) for pid in match.group(2).split()]


def later(after_s, action):
    """Runs `action` `after_s` seconds from now, in the background."""

    def run():
        time.sleep(after_s)
        action()

    thread = threading.Thread(target=run)
    thread.start()
    return thread


def stall(pids, for_s):
    """Stops the processes `pids` with SIGSTOP for `for_s` seconds."""
    for pid in pids:
        os.kill(pid, signal.SIGSTOP)
    time.sleep(for_s)
    for pid in pids:
        os.kill(pid, signal.SIGCONT)


def read(out, name):
    return json.loads((Path(out) / name).read_text())


def case(out, case_id):
    found = [c for c in read(out, "summary.json")["cases"] if c["id"] == case_id]
    if len(found) != 1:
        raise AssertionError(f"{case_id}: {len(found)} results")
    return found[0]


class LatencyFromScheduledSendTime(unittest.TestCase):
    """Requests go out at a fixed arrival rate, and each one's latency counts
    from the time it was scheduled to be sent, so a stall shows up in the
    tail however few requests were in flight when it began."""

    ARGS = ["--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "400", *SHORT]

    def run_with(self, action, after_s):
        """Runs one case at 400 requests per second, and calls `action` with
        the smock PID and the load generator PIDs `after_s` seconds after
        the load has started."""
        threads = []

        def on_line(line):
            pids = load_started(line)
            if pids:
                threads.append(later(after_s, lambda: action(*pids)))

        out = bench(self, *self.ARGS, on_line=on_line)
        for thread in threads:
            thread.join()
        self.assertEqual(len(threads), 1)
        return case(out, "http-keep-alive@1")

    def test_a_stalled_smock_shows_in_p99_and_p999_and_every_request_still_counts(self):
        # 0.5 s of the 4 s window are stalled: 12.5 % of the requests wait,
        # the first of them for nearly 0.5 s.
        result = self.run_with(lambda smock, generators: stall([smock], 0.5), after_s=1.5)
        self.assertGreaterEqual(result["latency_ms"]["p99"], 300)
        self.assertGreaterEqual(result["latency_ms"]["p99_9"], 400)
        self.assertEqual(result["errors"], 0)
        self.assertGreaterEqual(result["achieved_rate"], 400 * 0.95)

    def test_a_stalled_load_generator_shows_as_its_lag_not_as_smocks_latency(self):
        # The load generator's own lateness is not smock's: it is reported
        # apart, and the case says that the generator fell behind.
        result = self.run_with(lambda smock, generators: stall(generators, 0.5), after_s=1.5)
        self.assertGreaterEqual(result["generator_lag_ms"]["max"], 400)
        self.assertTrue(result["load_generator_late"])
        self.assertLess(result["latency_ms"]["p99"], 100)
        self.assertEqual(result["errors"], 0)

    def test_a_load_generator_on_schedule_is_not_late(self):
        result = self.run_with(lambda smock, generators: None, after_s=0)
        self.assertFalse(result["load_generator_late"])
        self.assertLess(result["generator_lag_ms"]["p99"], 5)

    def test_requests_that_get_no_response_count_as_errors_once(self):
        # smock dies 1.5 s into the 4 s window: the rest of its requests fail.
        result = self.run_with(lambda smock, generators: os.kill(smock, signal.SIGKILL), after_s=2)
        requests = result["requests"]
        self.assertEqual(requests["ok"] + result["errors"], requests["scheduled"])
        self.assertGreaterEqual(result["errors"], requests["scheduled"] * 0.5)
        self.assertLessEqual(result["achieved_rate"], 400 * 0.5)


class RawData(unittest.TestCase):
    """Each case keeps its latencies and smock's RSS over time, besides the
    summary, in files a program can read."""

    def test_each_case_writes_its_latencies_as_a_histogram_and_smocks_rss_over_time(self):
        out = bench(self, "--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "300", *SHORT)
        result = case(out, "http-keep-alive@1")
        raw = out / "raw" / "1" / "http-keep-alive"

        histogram = read(raw, "latency.json")
        self.assertEqual(histogram["unit"], "us")
        bounds = [bound for bound, _ in histogram["counts"]]
        self.assertEqual(bounds, sorted(set(bounds)))
        total = sum(count for _, count in histogram["counts"])
        self.assertEqual(total, result["requests"]["ok"] + result["requests"]["unexpected_status"])
        self.assertGreaterEqual(total, 1100)
        # The p99 read off the histogram is the summary's, up to the
        # histogram's precision of three significant digits.
        seen = 0
        bound = next(bound for bound, count in histogram["counts"] if (seen := seen + count) >= 0.99 * total)
        p99 = result["latency_ms"]["p99"]
        self.assertGreaterEqual(bound / 1000, p99 - 0.001)
        self.assertLessEqual(bound / 1000, p99 * 1.01 + 0.001)

        rss = read(raw, "rss.json")
        self.assertEqual(rss["unit"], "KiB")
        times = [t for t, _ in rss["samples"]]
        values = [kib for _, kib in rss["samples"]]
        self.assertEqual(times, sorted(times))
        # Sampled every half second from before the load until after it.
        self.assertEqual(rss["interval_s"], 0.5)
        self.assertGreaterEqual(len(values), 12)
        self.assertGreaterEqual(times[-1], 6)
        self.assertTrue(all(1024 < kib < 1024 * 1024 for kib in values), values)
        self.assertEqual(result["rss_kib"], {"first": values[0], "last": values[-1], "max": max(values)})


def definition_set_digest(directory):
    """The definition set digest of a definitions directory, as
    definitions/definitions.mbt defines it: the first 12 hex digits of the
    SHA-256 of every file framed as its kind (D for a Definition file, B for
    a body file), its name's length and name, and its length and bytes."""
    directory = Path(directory)
    definitions = [(p.name.encode(), p.read_bytes()) for p in directory.iterdir()
                   if p.is_file() and p.suffix in (".json", ".yaml", ".yml") and not p.name.startswith(".")]
    bodies = [(str(p.relative_to(directory / "files")).encode(), p.read_bytes())
              for p in (directory / "files").rglob("*") if p.is_file()]
    framed = bytearray()
    for kind, files in ((b"D", definitions), (b"B", bodies)):
        for name, data in sorted(files):
            framed += kind + len(name).to_bytes(8, "big") + name + len(data).to_bytes(8, "big") + data
    return hashlib.sha256(framed).hexdigest()[:12]


class Conditions(unittest.TestCase):
    """Each run writes the conditions it ran under."""

    def test_a_run_writes_what_ran_where_and_how(self):
        out = bench(self, "--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "200", *SHORT)
        conditions = read(out, "conditions.json")

        smock = conditions["smock"]
        version = subprocess.run([SMOCK, "--version"], capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(f"smock {smock['version']} (commit {smock['commit']}, {smock['toolchain']})", version)
        self.assertEqual(conditions["definitions"]["digest"], definition_set_digest(BENCH / "definitions"))

        machine = conditions["machine"]
        self.assertEqual(machine["architecture"], platform.machine())
        self.assertIn(os.uname().release, machine["kernel"])
        self.assertRegex(machine["cpu_model"], r"\w")

        oha = subprocess.run([OHA, "--version"], capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(conditions["load_generator"], {"name": "oha", "version": oha})

        cpus = conditions["cpus"]
        self.assertEqual(cpus["limits"], ["1"])
        self.assertTrue(cpus["smock"] and cpus["load_generator"], cpus)
        self.assertFalse(set(cpus["smock"]) & set(cpus["load_generator"]), cpus)

        plan = read(BENCH, "plan.json")
        connections = next(c["connections"] for c in plan["cases"] if c["name"] == "http-keep-alive")
        self.assertEqual(conditions["cases"], [{
            "id": "http-keep-alive@1",
            "protocol": "http",
            "connection": "keep-alive",
            "cpu_limit": "1",
            "rate": 200,
            "ramp_s": 0.5,
            "duration_s": 4,
            "tail_s": 2,
            "connections": connections,
            "idle_connections": 0,
        }])


class CpuLimits(unittest.TestCase):
    """smock runs under CPU limits of 250m, 500m, 1 and 2 cores, on CPUs of
    its own, apart from the load generator's."""

    def test_by_default_each_case_runs_under_each_limit_pinned_apart_from_the_load_generator(self):
        out = bench(self, "--cases", "http-keep-alive", "--rate", "100",
                    "--ramp", "0.5", "--duration", "1", "--tail", "1", "--settle", "0.5", "--cooldown", "0")
        cases = read(out, "summary.json")["cases"]
        # What smock's cgroup had in cpu.max while it ran: the quota per
        # 100 ms period, in microseconds.
        self.assertEqual({c["cpu_limit"]: c["pinning"]["smock_cpu_max"] for c in cases}, {
            "250m": "25000 100000",
            "500m": "50000 100000",
            "1": "100000 100000",
            "2": "200000 100000",
        })
        for result in cases:
            smock = set(result["pinning"]["smock_cpus"])
            generator = set(result["pinning"]["load_generator_cpus"])
            self.assertGreaterEqual(len(smock), 2, result["pinning"])
            self.assertTrue(generator, result["pinning"])
            self.assertFalse(smock & generator, result["pinning"])
            self.assertEqual(result["errors"], 0)


class Cases(unittest.TestCase):
    """The cases cover plain HTTP and TLS, keep-alive connections and a new
    connection per request, many idle connections held open during the load,
    and a long run that records RSS over time."""

    def test_each_kind_of_case_sends_the_mix_the_way_it_says(self):
        out = bench(self, "--cpu-limits", "1", "--rate", "100",
                    "--ramp", "0.5", "--duration", "2", "--tail", "1", "--settle", "0.5", "--cooldown", "0")
        cases = {c["case"]: c for c in read(out, "summary.json")["cases"]}
        self.assertEqual({name: (c["protocol"], c["connection"]) for name, c in cases.items()}, {
            "http-keep-alive": ("http", "keep-alive"),
            "https-keep-alive": ("https", "keep-alive"),
            "http-new-connection": ("http", "new-per-request"),
            "https-new-connection": ("https", "new-per-request"),
            "http-keep-alive-idle-connections": ("http", "keep-alive"),
            "long-run": ("http", "keep-alive"),
        })
        for result in cases.values():
            self.assertEqual(result["errors"], 0, result["id"])
            self.assertGreaterEqual(result["requests"]["ok"], 190, result["id"])

        # Connections accepted during the load (by any process on this
        # machine, so others may add a few): one per request with a new
        # connection per request, the load generator's few otherwise.
        for name, result in cases.items():
            sent = result["requests"]["scheduled"]
            if result["connection"] == "new-per-request":
                self.assertGreaterEqual(result["tcp_passive_opens"], sent, name)
            else:
                self.assertLess(result["tcp_passive_opens"], result["connections"] + sent / 4, name)

        plan = {c["name"]: c for c in read(BENCH, "plan.json")["cases"]}
        idle = cases["http-keep-alive-idle-connections"]
        held = plan["http-keep-alive-idle-connections"]["idle_connections"]
        self.assertGreaterEqual(held, 1000)
        self.assertEqual(idle["idle_connections"], held)
        self.assertEqual(idle["idle_connections_open_at_end"], held)

        # The long run samples RSS at its own interval, over the whole run.
        self.assertGreaterEqual(plan["long-run"]["duration_s"], 600)
        rss = read(out / "raw" / "1" / "long-run", "rss.json")
        self.assertEqual(rss["interval_s"], plan["long-run"]["rss_interval_s"])
        self.assertGreaterEqual(rss["samples"][-1][0], 3)


class IdleRss(unittest.TestCase):
    """Idle RSS is measured after startup with the benchmark's definitions."""

    def test_smocks_rss_once_it_has_loaded_the_definitions_and_settled_before_any_load(self):
        out = bench(self, "--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "100",
                    "--ramp", "0.5", "--duration", "1", "--tail", "1", "--settle", "1.5")
        idle = read(out, "summary.json")["idle_rss"]
        samples = read(out / "raw", "idle-rss.json")["samples"]
        self.assertEqual(idle["cpu_limit"], "1")
        self.assertEqual(idle["settle_s"], 1.5)
        # The last sample, taken once smock was ready and had settled.
        self.assertGreaterEqual(samples[-1][0], 1.5)
        self.assertEqual(idle["rss_kib"], samples[-1][1])
        # 1161 Stubs take more than a bare process and far less than 1 GiB.
        self.assertTrue(2048 < idle["rss_kib"] < 1024 * 1024, idle)
        self.assertEqual(idle["digest"], definition_set_digest(BENCH / "definitions"))


def targets_file(test, targets):
    """Writes a targets file with `targets` into a new directory, and
    returns its path."""
    directory = Path(tempfile.mkdtemp(prefix="smock-bench-test-targets-"))
    test.addCleanup(shutil.rmtree, directory, ignore_errors=True)
    path = directory / "targets.json"
    path.write_text(json.dumps({"targets": targets}))
    return path


def latency_target(target_id, metric, max_ms, rate):
    return {"id": target_id, "about": f"{metric} at {rate} requests/s", "case": "http-keep-alive",
            "cpu_limit": "1", "rate": rate, "metric": metric, "max": max_ms, "unit": "ms"}


def rss_target(target_id, max_mib):
    return {"id": target_id, "about": f"idle RSS at most {max_mib} MiB", "metric": "idle_rss",
            "max": max_mib, "unit": "MiB"}


class Targets(unittest.TestCase):
    """Each run checks the provisional targets, kept in bench/targets.json,
    and states for each whether it was met."""

    ARGS = ["--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "200",
            "--ramp", "0.5", "--duration", "2", "--tail", "1", "--settle", "0.5"]

    def test_the_targets_are_the_specs_and_a_run_at_another_rate_does_not_measure_the_latency_ones(self):
        out = bench(self, *self.ARGS)
        targets = {t["id"]: t for t in read(out, "summary.json")["targets"]}
        self.assertEqual({i: (t.get("case"), t.get("cpu_limit"), t.get("rate"), t["metric"], t["max"], t["unit"])
                          for i, t in targets.items()}, {
            "p99": ("http-keep-alive", "1", 50000, "p99", 1, "ms"),
            "p99.9": ("http-keep-alive", "1", 50000, "p99_9", 5, "ms"),
            "idle-rss": (None, None, None, "idle_rss", 20, "MiB"),
        })
        for target_id in ("p99", "p99.9"):
            self.assertEqual(targets[target_id]["verdict"], "not measured")
            self.assertIn("200 requests/s", targets[target_id]["reason"])
        # Idle RSS does not depend on the rate: every run measures it.
        self.assertIn(targets["idle-rss"]["verdict"], ("met", "missed"))

    def test_each_target_is_met_or_missed_by_what_the_run_measured(self):
        path = targets_file(self, [
            latency_target("loose-p99", "p99", 1000, 200),
            latency_target("tight-p99.9", "p99_9", 0.001, 200),
            rss_target("loose-idle-rss", 1024),
            rss_target("tight-idle-rss", 1),
        ])
        out = bench(self, *self.ARGS, "--targets", str(path))
        summary = read(out, "summary.json")
        targets = {t["id"]: t for t in summary["targets"]}
        self.assertEqual({i: t["verdict"] for i, t in targets.items()}, {
            "loose-p99": "met",
            "tight-p99.9": "missed",
            "loose-idle-rss": "met",
            "tight-idle-rss": "missed",
        })
        result = case(out, "http-keep-alive@1")
        self.assertEqual(targets["loose-p99"]["measured"], result["latency_ms"]["p99"])
        self.assertEqual(targets["tight-p99.9"]["measured"], result["latency_ms"]["p99_9"])
        self.assertEqual(targets["tight-idle-rss"]["measured"], round(summary["idle_rss"]["rss_kib"] / 1024, 2))
        # The human-readable summary states each verdict too.
        lines = (out / "summary.md").read_text().splitlines()
        for target in targets.values():
            self.assertTrue([line for line in lines if target["about"] in line and target["verdict"] in line],
                            target["id"])

    def test_a_latency_target_is_missed_when_requests_fail_whatever_the_latencies(self):
        path = targets_file(self, [latency_target("loose-p99", "p99", 1000, 200)])
        threads = []

        def on_line(line):
            pids = load_started(line)
            if pids:
                threads.append(later(1.5, lambda: os.kill(pids[0], signal.SIGKILL)))

        out = bench(self, *self.ARGS, "--targets", str(path), on_line=on_line)
        for thread in threads:
            thread.join()
        target = read(out, "summary.json")["targets"][0]
        self.assertEqual(target["verdict"], "missed")
        self.assertIn("errors", target["reason"])


if __name__ == "__main__":
    unittest.main()
