"""Tests of the release benchmark, bench/bench.py, through its command line.

Each test runs the benchmark against the real smock binary, at a few hundred
requests per second for a few seconds, and reads the files it writes. They
need what a benchmark run needs (see the README): a release build of smock
(dist/smock, or SMOCK_BENCH_SMOCK), oha (on PATH, or OHA), openssl, taskset,
and a systemd user manager that can set CPU quotas.

usage: python3 -m unittest discover -s bench -v
"""

import json
import os
import re
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


def bench(*args, out, on_line=None):
    """Runs `bench.py run` with `args`, writing to `out`, and returns its
    exit status and its stderr. `on_line` sees each stderr line as it
    comes."""
    command = [sys.executable, str(BENCH / "bench.py"), "run", "--smock", SMOCK, "--oha", OHA, "--out", str(out), *args]
    process = subprocess.Popen(command, stderr=subprocess.PIPE, text=True)
    lines = []
    for line in process.stderr:
        lines.append(line)
        if on_line:
            on_line(line)
    return process.wait(), "".join(lines)


def load_started(line):
    """The smock PID and the load generator PIDs of a case's `load started`
    progress line, or None."""
    match = re.search(r"load started \(smock pid (\d+), load generator pids ([\d ]+)\)", line)
    if not match:
        return None
    return int(match.group(1)), [int(pid) for pid in match.group(2).split()]


def stall(pids, after_s, for_s):
    """Stops the processes `pids` with SIGSTOP `after_s` seconds from now,
    for `for_s` seconds, in the background."""

    def run():
        time.sleep(after_s)
        for pid in pids:
            os.kill(pid, signal.SIGSTOP)
        time.sleep(for_s)
        for pid in pids:
            os.kill(pid, signal.SIGCONT)

    thread = threading.Thread(target=run)
    thread.start()
    return thread


def results(out):
    return json.loads((Path(out) / "results.json").read_text())


def case(out, case_id):
    found = [c for c in results(out)["cases"] if c["id"] == case_id]
    if len(found) != 1:
        raise AssertionError(f"{case_id}: {len(found)} results")
    return found[0]


class LatencyFromScheduledSendTime(unittest.TestCase):
    """Requests go out at a fixed arrival rate, and each one's latency counts
    from the time it was scheduled to be sent, so a stall shows up in the
    tail however few requests were in flight when it began."""

    # One case, 400 requests per second for 4 seconds after a 0.5 s ramp,
    # with 2 s for the last requests to finish.
    ARGS = ["--cases", "http-keep-alive", "--cpu-limits", "1", "--rate", "400",
            "--ramp", "0.5", "--duration", "4", "--tail", "2"]

    def run_with_stall(self, who):
        threads = []

        def on_line(line):
            pids = load_started(line)
            if pids:
                smock, generators = pids
                threads.append(stall([smock] if who == "smock" else generators, after_s=1.5, for_s=0.5))

        with tempfile.TemporaryDirectory(prefix="bench-test-", dir=BENCH) as out:
            status, stderr = bench(*self.ARGS, out=out, on_line=on_line)
            for thread in threads:
                thread.join()
            self.assertEqual(status, 0, stderr)
            self.assertEqual(len(threads), 1, stderr)
            return case(out, "http-keep-alive@1")

    def test_a_stalled_smock_shows_in_p99_and_p999_and_every_request_still_counts(self):
        result = self.run_with_stall("smock")
        # 0.5 s of the 4 s window are stalled: 12.5 % of the requests wait,
        # the first of them for nearly 0.5 s.
        self.assertGreaterEqual(result["latency_ms"]["p99"], 300)
        self.assertGreaterEqual(result["latency_ms"]["p99_9"], 400)
        self.assertEqual(result["errors"], 0)
        self.assertGreaterEqual(result["achieved_rps"], 400 * 0.95)

    def test_a_stalled_load_generator_shows_in_the_latencies_too_and_its_lag_says_so(self):
        result = self.run_with_stall("generator")
        self.assertGreaterEqual(result["latency_ms"]["p99"], 300)
        self.assertGreaterEqual(result["generator_lag_ms"]["max"], 400)
        self.assertEqual(result["errors"], 0)


if __name__ == "__main__":
    unittest.main()
