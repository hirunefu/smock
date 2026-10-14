"""Tests of the release benchmark, bench/bench.py.

Most tests run the benchmark through its command line against the real smock
binary, at a few hundred requests per second for a few seconds, and read the
files it writes. They need what a benchmark run needs (see the README): a
release build of smock (dist/smock, or SMOCK_BENCH_SMOCK), oha (on PATH, or
OHA), openssl, taskset, and a systemd user manager that can set CPU quotas.
The tests of the targets read a targets file with bench.py's read_targets and
check its targets against a summary as summary.json has it, with
check_targets, or run `bench.py check-targets` on a results directory they
write; they need nothing else.

usage: python3 -m unittest discover -s bench -v
"""

import hashlib
import importlib.util
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

# bench/bench.py, loaded from its path, however these tests are run.
_spec = importlib.util.spec_from_file_location("bench_harness", BENCH / "bench.py")
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

SMOCK = os.environ.get("SMOCK_BENCH_SMOCK", str(ROOT / "dist" / "smock"))
OHA = os.environ.get("OHA", "oha")

# This machine's CPU architecture as Kubernetes and the targets file name it,
# and the other one smock is built for.
LOCAL_ARCHITECTURE = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine(), platform.machine())
OTHER_ARCHITECTURE = "amd64" if LOCAL_ARCHITECTURE == "arm64" else "arm64"

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
    tail however few requests were in flight when it began, and even when
    the load generator falls behind with it. The latency from the time the
    load generator released each request, and how late it released them,
    are reported beside it."""

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

    def test_a_stall_that_holds_up_the_load_generator_too_still_shows_in_p99_and_p999(self):
        # The requests due while both are stopped go out late, all at once,
        # and smock answers them quickly: only the time since they were due
        # shows the wait.
        result = self.run_with(lambda smock, generators: stall([smock, *generators], 0.5), after_s=1.5)
        self.assertGreaterEqual(result["latency_ms"]["p99"], 300)
        self.assertGreaterEqual(result["latency_ms"]["p99_9"], 400)
        self.assertLess(result["latency_from_release_ms"]["p99"], 100)
        self.assertEqual(result["errors"], 0)

    def test_a_stalled_load_generator_shows_as_its_lag_and_the_case_says_it_fell_behind(self):
        # The load generator's own lateness counts in the latency, but the
        # latency from release and the lag tell it apart from smock's, and
        # the case says that the generator fell behind.
        result = self.run_with(lambda smock, generators: stall(generators, 0.5), after_s=1.5)
        self.assertGreaterEqual(result["generator_lag_ms"]["max"], 400)
        self.assertTrue(result["load_generator_late"])
        self.assertGreaterEqual(result["latency_ms"]["p99"], 300)
        self.assertLess(result["latency_from_release_ms"]["p99"], 100)
        self.assertEqual(result["errors"], 0)

    def test_a_load_generator_late_for_fewer_than_one_in_a_hundred_requests_fell_behind(self):
        # About 10 of the 1,600 requests in the window go out up to 25 ms
        # late: p99 of the lag does not see them, p99.9 and the maximum do.
        result = self.run_with(lambda smock, generators: stall(generators, 0.025), after_s=1.5)
        self.assertGreaterEqual(result["generator_lag_ms"]["p99_9"], 10)
        self.assertTrue(result["load_generator_late"])

    def test_a_load_generator_on_schedule_is_not_late(self):
        result = self.run_with(lambda smock, generators: None, after_s=0)
        self.assertFalse(result["load_generator_late"])
        # oha's timer and the scheduler: within the limits of bench.py,
        # GENERATOR_LAG_LIMITS_MS.
        lag = result["generator_lag_ms"]
        self.assertLessEqual(lag["p99_9"], 5)
        self.assertLessEqual(lag["max"], 10)
        # Each latency is the lag plus the latency from release.
        self.assertGreaterEqual(result["latency_ms"]["p99"], result["latency_from_release_ms"]["p99"])

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
            "profile": "1",
            "protocol": "http",
            "connection": "keep-alive",
            "cpu_limit": "1",
            "memory_limit": None,
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
    """Idle RSS is measured after startup with the benchmark's definitions,
    under the profiles the plan names for it: in bench/plan.json, a 1-CPU
    limit and no memory limit."""

    def test_smocks_rss_once_it_has_loaded_the_definitions_and_settled_before_any_load(self):
        out = bench(self, "--cases", "http-keep-alive", "--cpu-limits", "250m", "--rate", "100",
                    "--ramp", "0.5", "--duration", "1", "--tail", "1", "--settle", "1.5")
        [idle] = read(out, "summary.json")["idle_rss"]
        samples = read(out / "raw" / "1", "idle-rss.json")["samples"]
        self.assertEqual((idle["profile"], idle["cpu_limit"], idle["memory_limit"]), ("1", "1", None))
        self.assertEqual(idle["settle_s"], 1.5)
        # The last sample, taken once smock was ready and had settled.
        self.assertGreaterEqual(samples[-1][0], 1.5)
        self.assertEqual(idle["rss_kib"], samples[-1][1])
        # About 1,200 Stubs take more than a bare process and far less than 1 GiB.
        self.assertTrue(2048 < idle["rss_kib"] < 1024 * 1024, idle)
        self.assertEqual(idle["digest"], definition_set_digest(BENCH / "definitions"))


def plan_file(test, profiles, rates, **changes):
    """Writes a plan into a new directory, and returns its path: bench/plan.json
    with `profiles` instead of its CPU limits, only its http-keep-alive
    case, at `rates` (by profile name), and `changes` to its top level."""
    plan = read(BENCH, "plan.json")
    plan.pop("cpu_limits")
    case = next(c for c in plan["cases"] if c["name"] == "http-keep-alive")
    plan.update(profiles=profiles, cases=[{**case, "rates": rates}], **changes)
    directory = Path(tempfile.mkdtemp(prefix="smock-bench-test-plan-"))
    test.addCleanup(shutil.rmtree, directory, ignore_errors=True)
    path = directory / "plan.json"
    path.write_text(json.dumps(plan))
    return path


MiB = 1024 * 1024


class MemoryLimits(unittest.TestCase):
    """A resource profile can limit smock's memory as well as its CPU, as a
    Kubernetes memory limit does: smock's cgroup gets the limit and may not
    swap, and the run records smock's peak memory and whether the kernel
    OOM-killed it."""

    def test_a_memory_limit_applies_to_smocks_cgroup_without_swap_and_the_case_records_peak_memory(self):
        plan = plan_file(self, [{"name": "small", "cpu_limit": "1", "memory_limit": "256Mi"}], {"small": 200},
                         idle_rss={"settle_s": 5})
        out = bench(self, "--plan", str(plan), *SHORT)
        result = case(out, "http-keep-alive@small")
        self.assertEqual((result["profile"], result["cpu_limit"], result["memory_limit"]), ("small", "1", "256Mi"))
        # What smock's cgroup had in memory.max and memory.swap.max while it
        # ran, in bytes.
        self.assertEqual(result["pinning"]["smock_memory_max"], "268435456")
        self.assertEqual(result["pinning"]["smock_memory_swap_max"], "0")
        self.assertEqual(result["memory"]["oom_kills"], 0)
        # About 1,200 Stubs and a Journal of 800 entries take more than a
        # bare process and far less than the limit.
        self.assertTrue(4 * MiB < result["memory"]["peak_bytes"] < 256 * MiB, result["memory"])
        self.assertEqual(result["errors"], 0)

    def test_smock_oom_killed_under_a_memory_limit_too_small_for_it_is_recorded_and_the_run_goes_on(self):
        plan = plan_file(self, [{"name": "tiny", "cpu_limit": "1", "memory_limit": "4Mi"},
                                {"name": "roomy", "cpu_limit": "1", "memory_limit": "256Mi"}],
                         {"tiny": 200, "roomy": 200}, idle_rss={"settle_s": 5})
        out = bench(self, "--plan", str(plan), *SHORT)
        summary = read(out, "summary.json")
        self.assertTrue(summary["complete"])

        idle = {i["profile"]: i for i in summary["idle_rss"]}
        self.assertFalse(idle["tiny"]["smock_ready"])
        self.assertGreaterEqual(idle["tiny"]["memory"]["oom_kills"], 1)
        self.assertIsNone(idle["tiny"]["rss_kib"])
        self.assertTrue(idle["roomy"]["smock_ready"])
        self.assertEqual(idle["roomy"]["memory"]["oom_kills"], 0)

        # smock never got ready, so no load was sent: each of the about 800
        # requests due in the window (200 a second for 4 s) is an error.
        tiny = case(out, "http-keep-alive@tiny")
        self.assertFalse(tiny["smock_ready"])
        self.assertGreaterEqual(tiny["memory"]["oom_kills"], 1)
        self.assertEqual(tiny["achieved_rate"], 0)
        self.assertAlmostEqual(tiny["errors"], 800, delta=9)
        self.assertEqual(tiny["requests"]["no_response"], tiny["errors"])

        roomy = case(out, "http-keep-alive@roomy")
        self.assertEqual(roomy["memory"]["oom_kills"], 0)
        self.assertEqual(roomy["errors"], 0)


class Ladders(unittest.TestCase):
    """A case may run at a ladder of rates under a profile: one step for each
    rate, from the lowest, each with results of its own."""

    def test_a_case_runs_once_for_each_rate_of_its_ladder_from_the_lowest(self):
        plan = plan_file(self, [{"name": "small", "cpu_limit": "1"}], {"small": [300, 100]},
                         idle_rss={"settle_s": 5})
        out = bench(self, "--plan", str(plan), *SHORT)
        cases = read(out, "summary.json")["cases"]
        self.assertEqual([(c["id"], c["rate"]) for c in cases],
                         [("http-keep-alive@small@100", 100), ("http-keep-alive@small@300", 300)])
        for result in cases:
            self.assertAlmostEqual(result["achieved_rate"], result["rate"], delta=result["rate"] * 0.05)
            # A profile without a memory limit leaves smock's memory unlimited.
            self.assertEqual(result["pinning"]["smock_memory_max"], "max")
            histogram = read(out / "raw" / "small" / f"http-keep-alive@{result['rate']}", "latency.json")
            self.assertEqual(sum(count for _, count in histogram["counts"]), result["requests"]["ok"])


def markdown_sections(text):
    """The `## ` sections of a Markdown text: {heading: [line, ...]}."""
    sections, lines = {}, None
    for line in text.splitlines():
        if line.startswith("## "):
            lines = sections.setdefault(line[3:], [])
        elif lines is not None:
            lines.append(line)
    return sections


def markdown_table(lines):
    """The rows of the first table among `lines`, as dicts by column."""
    rows = [[cell.strip() for cell in line.strip().strip("|").split("|")] for line in lines if line.startswith("|")]
    return [dict(zip(rows[0], row, strict=True)) for row in rows[2:]]


class SummaryByProfile(unittest.TestCase):
    """summary.md shows each profile apart, with its limits: smock's idle
    RSS under it, and for each case at each rate the achieved rate, the
    latencies, the errors, how long smock was throttled, its peak memory
    and its OOM kills. It says what the plan says about reading them."""

    def test_the_summary_shows_each_profile_with_its_limits_and_what_smock_used_under_it(self):
        note = "Absolute numbers on this machine differ from those on GKE's CPUs."
        plan = plan_file(self, [{"name": "small", "cpu_limit": "1", "memory_limit": "256Mi"},
                                {"name": "tiny", "cpu_limit": "250m", "memory_limit": "4Mi"}],
                         {"small": [100, 200], "tiny": 100}, idle_rss={"settle_s": 5}, note=note)
        out = bench(self, "--plan", str(plan), *SHORT)
        text = (out / "summary.md").read_text()
        self.assertIn(note, text)
        summary = read(out, "summary.json")
        sections = markdown_sections(text)
        headings = {heading.split(":")[0]: heading for heading in sections}
        self.assertIn("CPU limit 1, memory limit 256Mi", headings["small"])
        self.assertIn("CPU limit 250m, memory limit 4Mi", headings["tiny"])

        rows = markdown_table(sections[headings["small"]])
        for row, result in zip(rows, [c for c in summary["cases"] if c["profile"] == "small"], strict=True):
            # A step whose load generator fell behind says so.
            name = "http-keep-alive" + (" (late)" if result["load_generator_late"] else "")
            self.assertEqual((row["Case"], row["Rate"], row["Achieved"]),
                             (name, str(result["rate"]), str(result["achieved_rate"])))
            self.assertEqual([row[f"{name} ms"] for name in ("p50", "p99", "p99.9", "Max")],
                             [str(result["latency_ms"][name]) for name in ("p50", "p99", "p99_9", "max")])
            self.assertEqual(row["Errors"], "0")
            self.assertEqual(row["Throttled s"], str(result["smock_cpu"]["throttled_s"]))
            self.assertEqual(row["Peak memory MiB"], f"{result['memory']['peak_bytes'] / MiB:.1f}")
            self.assertEqual(row["OOM kills"], "0")
        # Idle RSS under the profile, in MiB.
        idle = next(i for i in summary["idle_rss"] if i["profile"] == "small")
        self.assertTrue([line for line in sections[headings["small"]]
                         if line.startswith("Idle RSS") and f"{idle['rss_kib'] / 1024:.1f} MiB" in line])

        [row] = markdown_table(sections[headings["tiny"]])
        self.assertIn("OOM-killed before it was ready", row["Case"])
        self.assertGreaterEqual(int(row["OOM kills"]), 1)
        self.assertTrue([line for line in sections[headings["tiny"]]
                         if line.startswith("Idle RSS") and "OOM-killed before it was ready" in line])


class Estimate(unittest.TestCase):
    """Before it starts smock, a run says how long it will take."""

    def test_a_run_says_how_long_it_will_take_before_it_starts(self):
        plan = plan_file(self, [{"name": "small", "cpu_limit": "1"}], {"small": [100, 200]},
                         idle_rss={"settle_s": 5})
        lines = []
        started = time.monotonic()
        bench(self, "--plan", str(plan), *SHORT, on_line=lines.append)
        elapsed = time.monotonic() - started
        estimates = [i for i, line in enumerate(lines) if re.search(r"about [\d.]+ minutes \(\d+ s\)", line)]
        self.assertEqual(len(estimates), 1, lines)
        first_smock = next(i for i, line in enumerate(lines) if "idle RSS:" in line)
        self.assertLess(estimates[0], first_smock)
        estimate_s = int(re.search(r"\((\d+) s\)", lines[estimates[0]]).group(1))
        # At least what the plan runs: 0.5 s of idling, then two steps of
        # 0.5 + 4 + 2 s; and near what the run took.
        self.assertGreaterEqual(estimate_s, 13.5)
        self.assertLessEqual(abs(estimate_s - elapsed), elapsed / 2, (estimate_s, elapsed))


class AutopilotProfiles(unittest.TestCase):
    """bench/plan-autopilot.json simulates on this machine the smallest
    general-purpose GKE Autopilot Pods, 50m CPU and 52 MiB where Pods may
    burst and 250m and 512 MiB where they may not, and the Helm chart's
    default, 1 CPU and 1 GiB. smock runs with its defaults under each."""

    PLAN = str(BENCH / "plan-autopilot.json")

    def test_each_profile_runs_smock_under_its_cpu_quota_and_memory_limit_and_measures_idle_rss(self):
        out = bench(self, "--plan", self.PLAN, "--cases", "http-keep-alive", "--rate", "100", *SHORT)
        summary = read(out, "summary.json")
        cases = {c["profile"]: c for c in summary["cases"]}
        # cpu.max: the quota per 100 ms period in microseconds; memory.max
        # in bytes.
        self.assertEqual({name: (c["pinning"]["smock_cpu_max"], c["pinning"]["smock_memory_max"],
                                 c["pinning"]["smock_memory_swap_max"]) for name, c in cases.items()}, {
            "autopilot-burst-min": ("5000 100000", "54525952", "0"),
            "autopilot-min": ("25000 100000", "536870912", "0"),
            "chart-default": ("100000 100000", "1073741824", "0"),
        })
        for result in cases.values():
            self.assertEqual(result["errors"], 0, result["id"])
            self.assertEqual(result["memory"]["oom_kills"], 0, result["id"])
            self.assertIsNotNone(result["smock_cpu"]["throttled_s"], result["id"])
        self.assertEqual([idle["profile"] for idle in summary["idle_rss"]],
                         ["autopilot-burst-min", "autopilot-min", "chart-default"])
        # smock's defaults, whatever SMOCK_* variables the shell has: no
        # argument shrinks the Journal.
        args = read(out, "conditions.json")["smock"]["args"]
        self.assertFalse([arg for arg in args if arg.startswith("--journal")], args)
        # Idle RSS is measured against each profile's target; the run's
        # rate of 100 is not the latency targets'.
        idle_targets = [t for t in summary["targets"] if t["metric"] == "idle_rss"]
        self.assertEqual(len(idle_targets), 3)
        for target in idle_targets:
            self.assertIn(target["verdict"], ("met", "missed"), target["id"])

    def test_each_case_climbs_a_ladder_scaled_to_the_cpu_limit_through_the_rate_of_each_profiles_targets(self):
        plan = read(BENCH, "plan-autopilot.json")
        profiles = {profile["name"]: profile for profile in plan["profiles"]}
        self.assertEqual({name: (p["cpu_limit"], p["memory_limit"]) for name, p in profiles.items()}, {
            "autopilot-burst-min": ("50m", "52Mi"),
            "autopilot-min": ("250m", "512Mi"),
            "chart-default": ("1", "1Gi"),
        })
        cases = {c["name"]: c for c in plan["cases"]}
        self.assertEqual({name: (c["protocol"], c["connection"]) for name, c in cases.items()}, {
            "http-keep-alive": ("http", "keep-alive"),
            "https-keep-alive": ("https", "keep-alive"),
        })
        for case in cases.values():
            for name, rates in case["rates"].items():
                self.assertEqual(rates, sorted(rates), (case["name"], name))
                self.assertGreaterEqual(len(rates), 3, (case["name"], name))
            # The same ladder for each profile, in proportion to its CPU
            # limit: 50m gets a twentieth of what 1 CPU gets.
            ladder = case["rates"]["chart-default"]
            self.assertEqual(case["rates"]["autopilot-burst-min"], [rate // 20 for rate in ladder])
            self.assertEqual(case["rates"]["autopilot-min"], [rate // 4 for rate in ladder])
            # Under 50m smock used up its CPU quota at about 4,000 requests
            # a second over HTTPS on this kind of machine; the top of the
            # ladder reaches it.
            self.assertGreaterEqual(case["rates"]["autopilot-burst-min"][-1], 4000)
        # Each target of each architecture is measured by a full run: its
        # profile has its limits, and its case climbs through its rate
        # under it.
        for target in [t for targets in harness.read_targets(BENCH / "targets.json").values() for t in targets]:
            profile = profiles[target["profile"]]
            self.assertEqual((profile["cpu_limit"], profile["memory_limit"]),
                             (target["cpu_limit"], target["memory_limit"]), target["id"])
            if target["rate"] is not None:
                self.assertIn(target["rate"], cases[target["case"]]["rates"][target["profile"]], target["id"])


def targets_file(test, profiles=(), architectures=None):
    """Writes a targets file into a new directory, and returns its path: the
    entries `profiles` as the targets of arm64, or the entries of each
    architecture of `architectures` ({architecture: entries}) as its
    targets."""
    directory = Path(tempfile.mkdtemp(prefix="smock-bench-test-targets-"))
    test.addCleanup(shutil.rmtree, directory, ignore_errors=True)
    path = directory / "targets.json"
    by_architecture = architectures if architectures is not None else {"arm64": list(profiles)}
    path.write_text(json.dumps({"architectures": {architecture: {"profiles": entries}
                                                  for architecture, entries in by_architecture.items()}}))
    return path


class Targets(unittest.TestCase):
    """Each run checks the provisional targets, kept in bench/targets.json,
    and states for each, in summary.json and summary.md, whether it was met,
    missed or not measured, and why when that is not plain."""

    def test_a_run_of_bench_plan_json_measures_none_of_the_targets_and_says_why(self):
        # The targets hold under the profiles of bench/plan-autopilot.json;
        # those of bench/plan.json, which CI runs, are CPU limits alone.
        out = bench(self, "--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "200",
                    "--ramp", "0.5", "--duration", "2", "--tail", "1", "--settle", "0.5")
        targets = read(out, "summary.json")["targets"]
        self.assertEqual({t["id"] for t in targets},
                         {t["id"] for t in harness.read_targets(BENCH / "targets.json")[LOCAL_ARCHITECTURE]})
        for target in targets:
            self.assertEqual(target["verdict"], "not measured", target["id"])
            self.assertIn(f"did not run profile {target['profile']}", target["reason"])

    def test_a_run_under_a_targets_profile_states_each_verdict_in_both_summaries(self):
        plan = plan_file(self, [{"name": "small", "cpu_limit": "1", "memory_limit": "256Mi"}], {"small": 200},
                         idle_rss={"settle_s": 5})
        entry = {"profile": "small", "cpu_limit": "1", "memory_limit": "256Mi", "case": "http-keep-alive", "rate": 200,
                 "at_most": {"p99_ms": 1000, "p99_9_ms": 0.001, "oom_kills": 0, "peak_memory_mib": 1,
                             "idle_rss_mib": 1024}}
        # The other architecture's p99.9 would be met: the run checks its
        # own architecture's.
        other = {**entry, "at_most": {**entry["at_most"], "p99_9_ms": 1000}}
        path = targets_file(self, architectures={OTHER_ARCHITECTURE: [other], LOCAL_ARCHITECTURE: [entry]})
        out = bench(self, "--plan", str(plan), "--targets", str(path), *SHORT)
        summary = read(out, "summary.json")
        targets = {t["id"]: t for t in summary["targets"]}
        self.assertEqual({i: t["verdict"] for i, t in targets.items()}, {
            "small/p99": "met",
            "small/p99_9": "missed",
            "small/oom_kills": "met",
            "small/peak_memory": "missed",
            "small/idle_rss": "met",
        })
        self.assertEqual({t["architecture"] for t in summary["targets"]}, {LOCAL_ARCHITECTURE})
        result = case(out, "http-keep-alive@small")
        self.assertEqual(targets["small/p99"]["measured"], result["latency_ms"]["p99"])
        self.assertEqual(targets["small/peak_memory"]["measured"], round(result["memory"]["peak_bytes"] / MiB, 2))
        self.assertEqual(targets["small/idle_rss"]["measured"], round(summary["idle_rss"][0]["rss_kib"] / 1024, 2))
        # summary.md says which architecture's targets it checked, and has
        # a row for each, with its profile, what it is and its verdict.
        section = markdown_sections((out / "summary.md").read_text())["Targets"]
        targets_path = read(out, "conditions.json")["targets"]["file"]
        self.assertIn(f"The targets of {targets_path} for {LOCAL_ARCHITECTURE}, the architecture the run ran on.",
                      section)
        rows = markdown_table(section)
        self.assertEqual([(row["Profile"], row["Target"], row["Verdict"]) for row in rows],
                         [("small (1 CPU, 256Mi)", t["about"], t["verdict"]) for t in summary["targets"]])


class TargetsFile(unittest.TestCase):
    """bench/targets.json holds the maintainer's provisional targets for each
    CPU architecture, one entry for each resource profile of
    bench/plan-autopilot.json: the load its latency targets hold at, and the
    most smock may use under it."""

    def test_the_targets_are_the_maintainers_decision_for_each_architecture_and_profile(self):
        targets = harness.read_targets(BENCH / "targets.json")
        # Each profile's rate, and the most p99 and p99.9 may be at it: for
        # arm64 from the GKE Autopilot probe on Arm, for amd64 from the runs
        # on x86 nodes, where a vCPU is a hyperthread and the CFS quota of
        # 250m and 50m shows in the slowest requests at any load.
        loads = {
            "arm64": {"chart-default": ("1", "1Gi", 30000, 3, 10),
                      "autopilot-min": ("250m", "512Mi", 5000, 3, 5),
                      "autopilot-burst-min": ("50m", "52Mi", 250, 3, 50)},
            "amd64": {"chart-default": ("1", "1Gi", 5000, 5, 20),
                      "autopilot-min": ("250m", "512Mi", 1250, 100, 200),
                      "autopilot-burst-min": ("50m", "52Mi", 125, 100, 300)},
        }
        self.assertEqual(list(targets), ["arm64", "amd64"])
        for architecture, load in loads.items():
            shown = {t["id"]: (t["architecture"], t["profile"], t["cpu_limit"], t["memory_limit"], t["case"],
                               t["rate"], t["metric"], t["max"], t["unit"]) for t in targets[architecture]}
            expected = {}
            for profile, (cpu, memory, rate, p99, p99_9) in load.items():
                at_load = (architecture, profile, cpu, memory, "http-keep-alive", rate)
                expected |= {
                    f"{profile}/p99": (*at_load, "p99", p99, "ms"),
                    f"{profile}/p99_9": (*at_load, "p99_9", p99_9, "ms"),
                    f"{profile}/peak_memory": (*at_load, "peak_memory", 32, "MiB"),
                    f"{profile}/idle_rss": (architecture, profile, cpu, memory, None, None, "idle_rss", 20, "MiB"),
                }
                if profile == "autopilot-burst-min":
                    expected[f"{profile}/oom_kills"] = (*at_load, "oom_kills", 0, "OOM kills")
            self.assertEqual(shown, expected, architecture)

    def test_each_set_says_where_it_comes_from_and_that_it_is_provisional(self):
        document = read(BENCH, "targets.json")
        self.assertIn("provisional", document["about"])
        self.assertIn("regression", document)
        for architecture, words in (("arm64", ("arm64", "e4a")), ("amd64", ("x86", "ek-standard-8"))):
            about = document["architectures"][architecture]["about"]
            for word in words:
                self.assertIn(word, about, architecture)
            self.assertIn("provisional", about.lower(), architecture)

    def test_a_targets_file_that_cannot_be_checked_is_refused_with_what_to_change(self):
        idle_only = {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "at_most": {"idle_rss_mib": 20}}
        harness.read_targets(targets_file(self, [idle_only]))
        for entry, expected in (
                ({**SMALL, "at_most": {"p95_ms": 3}}, "arm64: small: p95_ms cannot be checked"),
                ({**idle_only, "at_most": {"p99_ms": 3}}, "give the case and the rate"),
                ({**SMALL, "memory_limit": "52MB"}, "memory limit '52MB'"),
                ({**SMALL, "at_most": {"p99_ms": "3"}}, "must be a number")):
            with self.assertRaises(harness.BenchError) as raised:
                harness.read_targets(targets_file(self, [entry]))
            self.assertIn(expected, str(raised.exception))
        # An architecture with no entries, and the layouts before
        # architectures: one set of entries for every architecture, and
        # before that a flat list of targets.
        with self.assertRaises(harness.BenchError) as raised:
            harness.read_targets(targets_file(self, architectures={"arm64": [SMALL], "amd64": []}))
        self.assertIn("amd64: needs a list of profiles", str(raised.exception))
        for layout in ({"profiles": [SMALL]}, {"targets": [{"id": "p99", "metric": "p99", "max": 1, "unit": "ms"}]}):
            old = targets_file(self, [])
            old.write_text(json.dumps(layout))
            with self.assertRaises(harness.BenchError) as raised:
                harness.read_targets(old)
            self.assertIn("needs the targets of each architecture", str(raised.exception))


# A profile's entry of a targets file, as the tests of the targets use it:
# 250m and 512Mi, http-keep-alive at 1,000 requests/s.
SMALL = {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "case": "http-keep-alive", "rate": 1000,
         "at_most": {"p99_ms": 3, "p99_9_ms": 10, "oom_kills": 0, "peak_memory_mib": 32, "idle_rss_mib": 20}}


def idle_measured(profile="small", cpu_limit="250m", memory_limit="512Mi", rss_kib=16 * 1024, oom_killed=False):
    """What summary.json has for smock's idle RSS under a profile."""
    return {"profile": profile, "cpu_limit": cpu_limit, "memory_limit": memory_limit, "settle_s": 5,
            "smock_ready": not oom_killed, "digest": "48f7ce9715f0", "rss_kib": None if oom_killed else rss_kib,
            "memory": {"peak_bytes": None if oom_killed else 9 * MiB, "oom_kills": 1 if oom_killed else 0}}


def step_measured(profile="small", cpu_limit="250m", memory_limit="512Mi", case_name="http-keep-alive", rate=1000,
                  p99=1.9, p99_9=2.1, peak_mib=20, oom_kills=0, errors=0, lag=(2.0, 2.1)):
    """What summary.json has for one step: a case under a profile at a
    rate, with these latencies (ms), peak memory (MiB), OOM kills, failed
    requests, and generator lag (p99.9 and max, ms)."""
    scheduled = rate * 20
    late = lag[0] > 5 or lag[1] > 10
    return {
        "id": f"{case_name}@{profile}@{rate}", "case": case_name, "profile": profile, "cpu_limit": cpu_limit,
        "memory_limit": memory_limit, "rate": rate, "achieved_rate": (scheduled - errors) / 20, "errors": errors,
        "latency_ms": {"p50": 1.0, "p90": 1.5, "p99": p99, "p99_9": p99_9, "max": 9.0},
        "generator_lag_ms": {"p50": 1.0, "p99": 2.0, "p99_9": lag[0], "max": lag[1]},
        "load_generator_late": late,
        "requests": {"scheduled": scheduled, "ok": scheduled - errors, "unexpected_status": 0, "no_response": errors},
        "memory": {"peak_bytes": None if peak_mib is None else int(peak_mib * MiB), "oom_kills": oom_kills},
        "smock_ready": True,
    }


def summary_of(idle=(), steps=()):
    """A summary as summary.json has it, with these idle measurements and
    steps, before its targets are checked."""
    return {"format": harness.FORMAT, "complete": True, "idle_rss": list(idle), "cases": list(steps), "targets": []}


def checked(test, entry, idle=(), steps=()):
    """Each target of a targets file with `entry` for arm64, checked against
    a summary of a run on arm64 with these idle measurements and steps:
    {id: (verdict, measured, reason)}."""
    results = harness.check_targets(harness.read_targets(targets_file(test, [entry])), "arm64",
                                    summary_of(idle, steps))
    return {result["id"]: (result["verdict"], result["measured"], result["reason"]) for result in results}


class TargetsByArchitecture(unittest.TestCase):
    """A targets file holds a set of targets for each CPU architecture, as
    Kubernetes names it (arm64, amd64): a run is checked against the set of
    the architecture it ran on, and one on an architecture with no set
    measures none of them."""

    # Under small, arm64's p99 is at most 3 ms and amd64's at most 100 ms.
    FILE = {"arm64": [SMALL], "amd64": [{**SMALL, "at_most": {**SMALL["at_most"], "p99_ms": 100}}]}

    def test_a_run_is_checked_against_the_targets_of_its_architecture(self):
        summary = summary_of(idle=[idle_measured()], steps=[step_measured(p99=50)])
        targets = harness.read_targets(targets_file(self, architectures=self.FILE))
        for architecture, verdict, maximum in (("arm64", "missed", 3), ("amd64", "met", 100)):
            checked_targets = {t["id"]: t for t in harness.check_targets(targets, architecture, summary)}
            self.assertEqual(set(checked_targets), {"small/p99", "small/p99_9", "small/oom_kills",
                                                    "small/peak_memory", "small/idle_rss"}, architecture)
            p99 = checked_targets["small/p99"]
            self.assertEqual((p99["architecture"], p99["max"], p99["verdict"], p99["measured"]),
                             (architecture, maximum, verdict, 50), architecture)
            self.assertEqual(checked_targets["small/p99_9"]["verdict"], "met", architecture)

    def test_a_run_on_an_architecture_with_no_targets_measures_none_and_says_why(self):
        summary = summary_of(idle=[idle_measured()], steps=[step_measured(p99=1.0)])
        targets = harness.read_targets(targets_file(self, architectures=self.FILE))
        checked_targets = harness.check_targets(targets, "riscv64", summary)
        # Each target of each architecture, in the file's order.
        self.assertEqual([(t["architecture"], t["id"]) for t in checked_targets],
                         [(architecture, f"small/{metric}") for architecture in ("arm64", "amd64")
                          for metric in ("p99", "p99_9", "oom_kills", "peak_memory", "idle_rss")])
        for target in checked_targets:
            self.assertEqual((target["verdict"], target["measured"]), ("not measured", None), target["id"])
            self.assertEqual(target["reason"],
                             f"a target for {target['architecture']}, and the run ran on riscv64, which has none")


class TargetVerdicts(unittest.TestCase):
    """Each target is met, missed or not measured, by what the run measured
    under its profile, and says why when that is not plain."""

    def test_a_target_under_a_profile_the_run_did_not_run_is_not_measured(self):
        # bench/plan.json's profiles are named by their CPU limits and have
        # no memory limit.
        verdicts = checked(self, SMALL, idle=[idle_measured(profile="1", cpu_limit="1", memory_limit=None)],
                           steps=[step_measured(profile="1", cpu_limit="1", memory_limit=None, rate=50000)])
        self.assertEqual(set(verdicts), {"small/p99", "small/p99_9", "small/oom_kills", "small/peak_memory",
                                         "small/idle_rss"})
        for verdict, measured, reason in verdicts.values():
            self.assertEqual((verdict, measured), ("not measured", None))
            self.assertIn("did not run profile small", reason)

    def test_a_target_under_a_profile_the_run_ran_with_other_limits_is_not_measured(self):
        # Before the targets, the 1-CPU profile of bench/plan-autopilot.json
        # had a memory limit of 4Gi.
        verdicts = checked(self, SMALL, idle=[idle_measured(memory_limit="4Gi")],
                           steps=[step_measured(memory_limit="4Gi")])
        for verdict, measured, reason in verdicts.values():
            self.assertEqual((verdict, measured), ("not measured", None))
            self.assertIn("a memory limit of 4Gi", reason)
            self.assertIn("a memory limit of 512Mi", reason)

    def test_each_target_is_met_or_missed_by_the_step_at_its_load_and_idle_rss_under_its_profile(self):
        # The ladder's other steps and the other case are far worse, and
        # do not count.
        others = [step_measured(rate=2000, p99=50, p99_9=80, peak_mib=40),
                  step_measured(case_name="https-keep-alive", p99=50, p99_9=80, peak_mib=40)]
        within = checked(self, SMALL, idle=[idle_measured(rss_kib=16 * 1024)],
                         steps=[step_measured(p99=1.9, p99_9=2.1, peak_mib=20), *others])
        self.assertEqual(within, {
            "small/p99": ("met", 1.9, None),
            "small/p99_9": ("met", 2.1, None),
            "small/oom_kills": ("met", 0, None),
            "small/peak_memory": ("met", 20.0, None),
            "small/idle_rss": ("met", 16.0, None),
        })
        over = checked(self, SMALL, idle=[idle_measured(rss_kib=21 * 1024)],
                       steps=[step_measured(p99=3.5, p99_9=12, peak_mib=33), *others])
        self.assertEqual(over, {
            "small/p99": ("missed", 3.5, None),
            "small/p99_9": ("missed", 12, None),
            "small/oom_kills": ("met", 0, None),
            "small/peak_memory": ("missed", 33.0, None),
            "small/idle_rss": ("missed", 21.0, None),
        })

    def test_an_oom_kill_misses_every_target_of_its_step_and_one_before_smock_was_ready_misses_idle_rss(self):
        verdicts = checked(self, SMALL, idle=[idle_measured(oom_killed=True)],
                           steps=[step_measured(p99=1.9, p99_9=2.1, peak_mib=20, oom_kills=2)])
        self.assertEqual(verdicts["small/oom_kills"], ("missed", 2, None))
        for target_id in ("small/p99", "small/p99_9", "small/peak_memory"):
            verdict, measured, reason = verdicts[target_id]
            self.assertEqual(verdict, "missed", target_id)
            self.assertIn("OOM-killed in http-keep-alive@small@1000", reason)
        verdict, measured, reason = verdicts["small/idle_rss"]
        self.assertEqual((verdict, measured), ("missed", None))
        self.assertIn("OOM-killed before it was ready", reason)

    def test_a_late_load_generator_leaves_the_latency_targets_not_measured_but_not_the_memory_ones(self):
        # The generator released a request 25 ms late: the latencies hold
        # its wait, but smock's memory under the load is still its own.
        verdicts = checked(self, SMALL, steps=[step_measured(p99=1.9, p99_9=2.1, peak_mib=20, lag=(25, 26))],
                           idle=[idle_measured()])
        for target_id, measured in (("small/p99", 1.9), ("small/p99_9", 2.1)):
            verdict, shown_measured, reason = verdicts[target_id]
            self.assertEqual((verdict, shown_measured), ("not measured", measured), target_id)
            self.assertIn("fell behind", reason)
            self.assertIn("p99.9 25 ms", reason)
        self.assertEqual(verdicts["small/peak_memory"], ("met", 20.0, None))
        self.assertEqual(verdicts["small/oom_kills"], ("met", 0, None))

    def test_failed_requests_miss_the_latency_targets_and_leave_memory_within_its_bound_not_measured(self):
        # 5,000 of the 20,000 requests got no response: smock did not carry
        # the load, so memory within its bound says nothing, and memory
        # over it is a miss all the same.
        verdicts = checked(self, SMALL, idle=[idle_measured()],
                           steps=[step_measured(p99=1.9, p99_9=2.1, peak_mib=20, errors=5000)])
        for target_id in ("small/p99", "small/p99_9"):
            verdict, measured, reason = verdicts[target_id]
            self.assertEqual(verdict, "missed", target_id)
            self.assertIn("5000 of the 20000 requests got no expected response", reason)
        for target_id in ("small/peak_memory", "small/oom_kills"):
            verdict, measured, reason = verdicts[target_id]
            self.assertEqual(verdict, "not measured", target_id)
            self.assertIn("5000 of the 20000 requests got no expected response", reason)
        over = checked(self, SMALL, steps=[step_measured(peak_mib=33, errors=5000)])
        self.assertEqual(over["small/peak_memory"], ("missed", 33.0, None))

    def test_a_run_without_the_targets_rate_or_without_memory_peak_does_not_measure_them(self):
        ladder = checked(self, SMALL, steps=[step_measured(rate=500), step_measured(rate=2000)])
        verdict, measured, reason = ladder["small/p99"]
        self.assertEqual((verdict, measured), ("not measured", None))
        self.assertIn("http-keep-alive@small ran at 500 and 2000 requests/s, the target is at 1000", reason)

        # Kernels before 5.19 keep no memory.peak.
        old_kernel = step_measured(peak_mib=None)
        old_kernel["memory"]["oom_kills"] = None
        verdicts = checked(self, SMALL, steps=[old_kernel])
        for target_id, file in (("small/peak_memory", "memory.peak"), ("small/oom_kills", "memory.events")):
            verdict, measured, reason = verdicts[target_id]
            self.assertEqual((verdict, measured), ("not measured", None), target_id)
            self.assertIn(file, reason)
        self.assertEqual(verdicts["small/p99"], ("met", 1.9, None))

        # A window too short to hold a request has no latencies.
        empty = checked(self, SMALL, steps=[step_measured(p99=None, p99_9=None)])
        verdict, measured, reason = empty["small/p99"]
        self.assertEqual((verdict, measured), ("not measured", None))
        self.assertIn("no latencies", reason)


def check_targets_command(*args):
    """Runs `bench.py check-targets` with `args`: its exit status, stdout and
    stderr."""
    result = subprocess.run([sys.executable, str(BENCH / "bench.py"), "check-targets", *map(str, args)],
                            capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def snapshot(directory):
    """Every file under `directory` with its content and modification time."""
    return {path.relative_to(directory): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in sorted(Path(directory).rglob("*")) if path.is_file()}


class CheckTargets(unittest.TestCase):
    """`bench.py check-targets` checks a finished run's summary.json against
    the targets file as it is now, for the architecture the run ran on, and
    prints the Targets section of summary.md, without running anything or
    changing the run's directory. It exits with 1 when a target is missed,
    and with 2 when it cannot check."""

    def results(self, architecture="aarch64", steps=None, idle=None, fmt=None, conditions=True, **summary):
        """A results directory as a run leaves it, of a run on `architecture`
        (as the kernel or Kubernetes names it) with these steps and idle
        measurements, by default http-keep-alive under small at 1,000
        requests/s with p99 1.9 ms and p99.9 2.1 ms."""
        out = Path(tempfile.mkdtemp(prefix="smock-bench-test-results-"))
        self.addCleanup(shutil.rmtree, out, ignore_errors=True)
        steps = [step_measured()] if steps is None else steps
        content = {**summary_of([idle_measured()] if idle is None else idle, steps), **summary}
        if fmt is not None:
            content["format"] = fmt
        (out / "summary.json").write_text(json.dumps(content))
        (out / "summary.md").write_text("# smock benchmark\n")
        if conditions:
            (out / "conditions.json").write_text(json.dumps({
                "machine": {"architecture": architecture},
                "targets": {"file": "bench/targets.json", "sha256": "aa"},
                "cases": [{"id": step["id"], "profile": step["profile"], "rate": step["rate"]} for step in steps]}))
        return out

    def test_a_run_is_checked_against_the_targets_as_they_are_now_and_its_directory_is_left_as_it_was(self):
        out = self.results()
        before = snapshot(out)
        status, stdout, stderr = check_targets_command(out, "--targets", targets_file(self, [SMALL]))
        self.assertEqual(status, 0, stderr)
        lines = stdout.splitlines()
        self.assertEqual(lines[:2], ["## Targets", ""])
        self.assertTrue(lines[2].endswith("targets.json for arm64, the architecture the run ran on."), lines[2])
        self.assertEqual(lines[3:], [
            "",
            "| Profile | Target | At most | Measured | Verdict |",
            "|---|---|---|---|---|",
            "| small (250m CPU, 512Mi) | p99 latency, http-keep-alive at 1,000 requests/s | 3 ms | 1.9 ms | met |",
            "| small (250m CPU, 512Mi) | p99.9 latency, http-keep-alive at 1,000 requests/s | 10 ms | 2.1 ms | met |",
            "| small (250m CPU, 512Mi) | OOM kills, http-keep-alive at 1,000 requests/s | 0 OOM kills | 0 OOM kills | "
            "met |",
            "| small (250m CPU, 512Mi) | peak memory, http-keep-alive at 1,000 requests/s | 32 MiB | 20.0 MiB | met |",
            "| small (250m CPU, 512Mi) | idle RSS after startup | 20 MiB | 16.0 MiB | met |",
        ])
        # Tighter targets now: p99 is missed. The summary.json itself, as
        # well as its directory, will do.
        tighter = {**SMALL, "at_most": {**SMALL["at_most"], "p99_ms": 1.5}}
        status, stdout, stderr = check_targets_command(out / "summary.json", "--targets",
                                                       targets_file(self, [tighter]))
        self.assertEqual(status, 1, stderr)
        self.assertIn("| small (250m CPU, 512Mi) | p99 latency, http-keep-alive at 1,000 requests/s | 1.5 ms | 1.9 ms "
                      "| missed |", stdout)
        self.assertEqual(snapshot(out), before)

    def test_the_targets_of_the_architecture_the_run_ran_on_are_checked_and_none_for_another(self):
        # amd64's p99 is at most 1.5 ms, which the run's 1.9 ms misses;
        # arm64's 3 ms, which it meets.
        path = targets_file(self, architectures={
            "arm64": [SMALL], "amd64": [{**SMALL, "at_most": {**SMALL["at_most"], "p99_ms": 1.5}}]})
        for architecture, expected in (("x86_64", 1), ("amd64", 1), ("aarch64", 0), ("arm64", 0)):
            status, stdout, stderr = check_targets_command(self.results(architecture), "--targets", path)
            self.assertEqual(status, expected, (architecture, stdout, stderr))
        status, stdout, stderr = check_targets_command(self.results("riscv64"), "--targets", path)
        self.assertEqual(status, 0, stderr)
        self.assertIn("targets.json has no targets for riscv64, the architecture the run ran on: each target below "
                      "is for another architecture, and not measured.", stdout)
        rows = markdown_table(stdout.splitlines())
        self.assertEqual(len(rows), 10)
        for row in rows:
            self.assertRegex(row["Verdict"], r"^not measured: a target for (arm64|amd64), and the run ran on "
                                             r"riscv64, which has none$")

    def test_a_step_a_gke_run_did_not_run_after_its_profile_ended_early_says_why(self):
        reason = "http-keep-alive@small@500 got no response to any of its 10,000 requests (oha: timeout)"
        ended = {"reason": reason, "after": "http-keep-alive@small@500", "not_measured": ["http-keep-alive@small@1000"]}
        out = self.results("amd64", steps=[step_measured(rate=500, errors=10000)], idle=[],
                           gke={"profiles": {"small": {"complete": False, "traffic_check": None, "ended_early": ended,
                                                       "generator_cpu_request": "6"}}})
        conditions = read(out, "conditions.json")
        conditions["cases"].append({"id": "http-keep-alive@small@1000", "profile": "small", "rate": 1000})
        (out / "conditions.json").write_text(json.dumps(conditions))
        status, stdout, stderr = check_targets_command(out, "--targets", targets_file(self, architectures={
            "amd64": [SMALL]}))
        self.assertEqual(status, 0, stderr)
        verdicts = {row["Target"]: row["Verdict"] for row in markdown_table(stdout.splitlines())}
        for about in ("p99 latency", "p99.9 latency", "OOM kills", "peak memory"):
            self.assertEqual(verdicts[f"{about}, http-keep-alive at 1,000 requests/s"],
                             f"not measured: http-keep-alive@small@1000 was not run: {reason}")
        self.assertEqual(verdicts["idle RSS after startup"],
                         "not measured: the run did not measure idle RSS under small")

    def test_what_it_cannot_check_stops_it_with_status_2(self):
        targets = targets_file(self, [SMALL])
        missing = Path(tempfile.mkdtemp(prefix="smock-bench-test-results-"))
        self.addCleanup(shutil.rmtree, missing, ignore_errors=True)
        broken = targets_file(self, [])
        broken.write_text(json.dumps({"profiles": [SMALL]}))
        for results, path, expected in (
                (missing, targets, "cannot read"),
                (self.results(fmt=3), targets, "has format 3"),
                (self.results(conditions=False), targets, "no conditions.json"),
                (self.results(), broken, "needs the targets of each architecture"),
                (self.results(), missing / "targets.json", "cannot read")):
            status, stdout, stderr = check_targets_command(results, "--targets", path)
            self.assertEqual((status, stdout), (2, ""), stderr)
            self.assertIn(expected, stderr)


if __name__ == "__main__":
    unittest.main()
