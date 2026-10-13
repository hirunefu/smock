#!/usr/bin/env python3
"""The release benchmark of smock.

It runs smock with the benchmark's definition set (bench/definitions/) under
resource profiles, each a CPU limit and an optional memory limit, and sends
it the request mix (bench/requests.json) at a fixed arrival rate, an open
model: requests go out on schedule whether or not earlier ones have been
answered. Each request's latency counts from the time it was scheduled to be
sent, so a server that stalls cannot hide the queue that builds up behind
it, even when the load generator falls behind with it. The latency from the
time the load generator released each request, and how late it released
them, are reported beside it, and so are smock's peak memory and any OOM
kills. A plan (bench/plan.json by default, or bench/plan-autopilot.json for
the smallest GKE Autopilot Pods) says which profiles and cases run, at which
rates and for how long.

usage:
  python3 bench/bench.py run [options]    run the benchmark (--help lists the options)

It needs Linux, python3 (3.10 or later), oha, openssl, taskset, and a systemd
user manager that may set CPU quotas and memory limits. The README's
Benchmark section says how to run it and how to read what it writes.
"""

import argparse
import array
import contextlib
import datetime
import hashlib
import http.client
import itertools
import json
import math
import os
import platform
import resource
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent

# The version of the layout of the files a run writes. A change that a
# program reading them would notice increments it. 2: latency_ms counts
# from each request's due time, latency_from_release_ms from its release.
# 3: cases run under resource profiles, at ladders of rates, and idle_rss
# is a list, one for each profile it was measured under.
FORMAT = 3

# How long smock may take to start listening, and to exit after SIGTERM.
START_TIMEOUT_S = 30
STOP_TIMEOUT_S = 30

# About how long starting smock until it is ready and stopping it takes,
# for the estimate a run prints: a few tenths of a second under a 1-CPU
# limit, about a second under 50m.
SMOCK_START_STOP_S = 1.5

# The CFS period systemd gives a CPU quota, as Kubernetes does.
CFS_PERIOD_US = 100_000

# How late after their due times the load generator may release a case's
# requests, at p99.9 and at most, over the measured window. oha's 1 ms
# timer releases them about a millisecond late, and the scheduler adds a
# few milliseconds now and then. A case whose generator was later than
# this fell behind its schedule: smock did not get the fixed arrival rate,
# and the generator's own wait is a large part of the latencies, so the
# case's latency targets are not measured. p99.9 may be at most the p99.9
# target, 5 ms. The maximum catches a single stop of the generator that
# delays fewer than one request in a thousand: at a fixed rate, a stop
# shorter than a thousandth of the window (20 ms of a 20 s window) does not
# reach p99.9.
GENERATOR_LAG_LIMITS_MS = {"p99_9": 5, "max": 10}


class BenchError(Exception):
    """A problem that stops the run, with what to do about it."""


class OomKilledAtStartup(Exception):
    """smock was OOM-killed before it was ready: an outcome the run
    records, not a problem that stops it."""

    def __init__(self, oom_kills):
        super().__init__(f"smock was OOM-killed {oom_kills} times before it was ready")
        self.oom_kills = oom_kills


def log(message):
    print(f"bench: {message}", file=sys.stderr, flush=True)


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def number(text):
    """A number from the command line, as an int when it is whole."""
    value = float(text)
    return int(value) if value.is_integer() else value


def shown_path(path):
    """`path` relative to the repository when it is in it, else with the
    home directory as `~`, so that what a run writes names no user."""
    path = Path(path).resolve()
    for base, prefix in ((ROOT, ""), (Path.home(), "~/")):
        try:
            return prefix + str(path.relative_to(base))
        except ValueError:
            continue
    return str(path)


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def cpu_quota_percent(limit):
    """The systemd CPUQuota percentage of a Kubernetes-style CPU limit:
    250m is 25 %, 2 is 200 %."""
    if limit.endswith("m"):
        return int(limit[:-1]) // 10
    return int(float(limit) * 100)


def cpus_needed(limit):
    """How many CPUs a Kubernetes-style CPU limit can keep busy: 250m needs
    one, 2 needs two."""
    return math.ceil(cpu_quota_percent(limit) / 100)


MEMORY_UNITS = {"Ki": 1 << 10, "Mi": 1 << 20, "Gi": 1 << 30}


def memory_bytes(limit):
    """The bytes of a Kubernetes-style memory limit: 52Mi is 54525952, 4Gi
    is 4294967296, and a plain number is bytes."""
    number, factor = limit, 1
    for suffix, unit in MEMORY_UNITS.items():
        if limit.endswith(suffix):
            number, factor = limit[:-len(suffix)], unit
    if not number.isdigit() or not int(number):
        raise BenchError(f"memory limit {limit!r}: use a whole number of bytes, or of Ki, Mi or Gi")
    return int(number) * factor


def memory_max(limit):
    """What a cgroup's memory.max holds under a memory limit, or with none:
    the bytes rounded down to whole pages, or `max`."""
    if limit is None:
        return "max"
    page = os.sysconf("SC_PAGE_SIZE")
    return str(memory_bytes(limit) // page * page)


def plan_profiles(plan):
    """The resource profiles of a plan, in its order: each has a name, a
    CPU limit and a memory limit or None. A plan that lists CPU limits
    instead has a profile for each, named by it, with no memory limit."""
    if "profiles" in plan:
        profiles = [{"name": profile["name"], "cpu_limit": profile["cpu_limit"],
                     "memory_limit": profile.get("memory_limit")} for profile in plan["profiles"]]
    else:
        profiles = [{"name": limit, "cpu_limit": limit, "memory_limit": None} for limit in plan["cpu_limits"]]
    for profile in profiles:
        if profile["memory_limit"] is not None:
            memory_bytes(profile["memory_limit"])
    return profiles


def override(value, default):
    """`value`, from the command line, when it was given; else `default`."""
    return value if value is not None else default


def cpus_allowed(pid):
    """The CPUs process `pid` may run on, or None once it has gone."""
    try:
        text = Path(f"/proc/{pid}/status").read_text()
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("Cpus_allowed_list:"):
            return parse_cpu_list(line.split(":", 1)[1].strip())
    return None


def cpus_by_speed():
    """The CPUs this process may run on, fastest first (by their maximum
    frequency, where the kernel reports one), then by number."""

    def max_freq(cpu):
        try:
            return int(Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/cpuinfo_max_freq").read_text())
        except (OSError, ValueError):
            return 0

    return sorted(os.sched_getaffinity(0), key=lambda cpu: (-max_freq(cpu), cpu))


def cpu_list(cpus):
    return ",".join(str(cpu) for cpu in cpus)


def parse_cpu_list(text):
    """The CPUs of a list such as `0,2-3`."""
    cpus = []
    for part in text.split(","):
        if "-" in part:
            low, high = part.split("-")
            cpus.extend(range(int(low), int(high) + 1))
        elif part:
            cpus.append(int(part))
    return cpus


def cpu_model():
    """The CPU model names, as lscpu or /proc/cpuinfo give them."""
    models = []
    try:
        listing = json.loads(subprocess.run(["lscpu", "--json"], capture_output=True, text=True,
                                            check=True).stdout)["lscpu"]
        while listing:
            field = listing.pop(0)
            listing.extend(field.get("children", []))
            if field["field"] == "Model name:":
                models.append(field["data"])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        pass
    if not models:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name"):
                models.append(line.split(":", 1)[1].strip())
    return ", ".join(dict.fromkeys(models)) or "unknown"


def read_first(*paths):
    """The text of the first of `paths` that can be read, stripped."""
    for path in paths:
        try:
            return Path(path).read_text().replace("\0", "").strip()
        except OSError:
            continue
    return None


def machine():
    uname = os.uname()
    memory = None
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            memory = int(line.split()[1])
    return {
        "architecture": platform.machine(),
        "cpu_model": cpu_model(),
        "model": read_first("/proc/device-tree/model", "/sys/class/dmi/id/product_name"),
        "cpus": os.cpu_count(),
        "memory_kib": memory,
        "kernel": f"{uname.sysname} {uname.release} {uname.version}",
        "cpufreq_governors": {
            str(cpu): read_first(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor")
            for cpu in sorted(os.sched_getaffinity(0))
        },
    }


def percentile(ordered, fraction):
    """The nearest-rank percentile of sorted values, or None for none."""
    if not ordered:
        return None
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def ms(seconds):
    return None if seconds is None else round(seconds * 1000, 3)


def histogram(latencies):
    """Latencies in seconds as a histogram in microseconds with three
    significant digits: [[upper bound, count], ...] in ascending order of
    the bound, for the buckets that have a count. A latency counts in the
    smallest bound at or above it: 1 to 999 us in steps of 1, 1000 to
    9990 us in steps of 10, and so on."""
    counts = {}
    for seconds in latencies:
        us = max(1, math.ceil(seconds * 1e6))
        step = 10 ** max(0, len(str(us)) - 3)
        bound = -(-us // step) * step
        counts[bound] = counts.get(bound, 0) + 1
    return sorted(counts.items())


def tcp_passive_opens():
    """How many TCP connections this machine has accepted since it started
    (Tcp PassiveOpens in /proc/net/snmp), whichever process accepted them."""
    names, values = [line.split()[1:] for line in Path("/proc/net/snmp").read_text().splitlines()
                     if line.startswith("Tcp:")]
    return int(values[names.index("PassiveOpens")])


def raw_request(request):
    """A request of the mix as the bytes of an HTTP/1.1 request."""
    head = [f"{request['method']} {request['target']} HTTP/1.1", f"Host: {request['host']}"]
    head += [f"{name}: {value}" for name, value in request["headers"]]
    body = (request["body"] or "").encode()
    if request["body"] is not None:
        head.append(f"Content-Length: {len(body)}")
    return ("\r\n".join(head) + "\r\n\r\n").encode() + body


def exchange(connection, request):
    """Sends `request` on `connection` and reads its whole response, framed
    by its Content-Length. Returns the status code."""
    connection.sendall(request)
    received = b""
    while b"\r\n\r\n" not in received:
        chunk = connection.recv(65536)
        if not chunk:
            raise BenchError("smock closed an idle connection before answering its request")
        received += chunk
    head, body = received.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    length = 0
    for line in lines[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "content-length":
            length = int(value)
    while len(body) < length:
        chunk = connection.recv(65536)
        if not chunk:
            raise BenchError("smock closed an idle connection in the middle of a response")
        body += chunk
    return int(lines[0].split()[1])


class IdleConnections:
    """`count` connections to smock's plain port, opened before the load:
    each sends one request of the mix and reads its response, then stays
    open, idle, until the load has ended."""

    def __init__(self, port, count, request):
        self.port = port
        self.count = count
        self.request = raw_request(request)
        self.expected = request["expect"]["status"]
        self.connections = []

    def __enter__(self):
        try:
            for _ in range(self.count):
                connection = socket.create_connection(("127.0.0.1", self.port), timeout=10)
                self.connections.append(connection)
                status = exchange(connection, self.request)
                if status != self.expected:
                    raise BenchError(f"an idle connection's request got {status}, not {self.expected}")
        except BaseException:
            self.__exit__()
            raise
        return self

    def open_count(self):
        """How many of the connections smock still holds open."""
        count = 0
        for connection in self.connections:
            connection.setblocking(False)
            try:
                if connection.recv(1, socket.MSG_PEEK):
                    count += 1
            except BlockingIOError:
                count += 1
            except OSError:
                pass
        return count

    def __exit__(self, *_):
        for connection in self.connections:
            connection.close()


def split(total, weights):
    """`total` split in proportion to `weights`, at least 1 each, by largest
    remainder, so that the parts add up to `total` when it is enough."""
    whole = sum(weights)
    exact = [total * weight / whole for weight in weights]
    parts = [max(1, math.floor(share)) for share in exact]
    by_remainder = sorted(range(len(weights)), key=lambda i: exact[i] - math.floor(exact[i]), reverse=True)
    for i in by_remainder[:max(0, total - sum(parts))]:
        parts[i] += 1
    return parts


def control_group(unit):
    """The cgroup directory of a systemd user unit, or None when it has
    none, as a unit that has stopped."""
    path = subprocess.run(["systemctl", "--user", "show", "-P", "ControlGroup", unit],
                          capture_output=True, text=True, check=True).stdout.strip()
    return Path("/sys/fs/cgroup" + path) if path else None


class Smock:
    """One smock process serving the benchmark's definitions, started in its
    own systemd scope under the CPU quota and the memory limit of a
    resource profile, and pinned to the smock CPUs. The scope sits in a
    slice of its own, whose memory.events counts the OOM kills in it
    hierarchically and outlives the scope, which systemd removes as soon as
    smock has gone."""

    units = itertools.count(1)

    def __init__(self, run, profile, log_path):
        self.run = run
        self.cpu_limit = profile["cpu_limit"]
        self.memory_limit = profile["memory_limit"]
        self.log_path = Path(log_path)
        self.ports = {}
        self.listening = threading.Event()
        self.process = None
        self.pid = None
        self.cgroup = None
        self.slice_cgroup = None
        self.exit_status = None
        self.oom_kills = None
        self.peak_bytes = None
        self.last_cpu_stat = None

    def __enter__(self):
        number = next(Smock.units)
        self.unit = f"smock-bench-{os.getpid()}-{number}.scope"
        # A dash in a slice's name nests it in the slice named by what is
        # before the dash.
        self.slice = f"smock_bench_{os.getpid()}_{number}.slice"
        memory = []
        if self.memory_limit is not None:
            memory = ["-p", f"MemoryMax={memory_bytes(self.memory_limit)}", "-p", "MemorySwapMax=0"]
        command = [
            "systemd-run", "--user", "--scope", "--quiet", "--collect", f"--unit={self.unit}",
            f"--slice={self.slice}", "-p", f"CPUQuota={cpu_quota_percent(self.cpu_limit)}%", *memory, "--",
            "taskset", "-c", cpu_list(self.run.smock_cpus),
            self.run.smock, "serve", *self.run.smock_args,
        ]
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_file = self.log_path.open("w")
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, text=True, env=self.run.smock_env)
        self.run.processes.append(self.process)
        self.reader = threading.Thread(target=self.read_log, daemon=True)
        self.reader.start()
        try:
            self.start()
        except BaseException:
            self.close()
            raise
        return self

    def start(self):
        """Waits until smock listens and is ready, and checks its limits."""
        deadline = time.monotonic() + START_TIMEOUT_S
        while not self.listening.wait(0.05):
            if self.process.poll() is not None or time.monotonic() > deadline:
                self.not_started("did not start listening")
        self.cgroup = control_group(self.unit)
        if self.cgroup is None:
            self.not_started("stopped as it started listening")
        self.pid = self.find_pid()
        quota = f"{cpu_quota_percent(self.cpu_limit) * CFS_PERIOD_US // 100} {CFS_PERIOD_US}"
        if self.cpu_max() != quota:
            raise BenchError(
                f"smock's cgroup has cpu.max {self.cpu_max()!r}, not {quota!r}: the systemd user manager "
                "cannot set CPU quotas. It needs the cpu controller delegated to it (see the README).")
        expected = (memory_max(self.memory_limit), "0")
        if self.memory_limit is not None and (self.memory_max(), self.memory_swap_max()) != expected:
            raise BenchError(
                f"smock's cgroup has memory.max {self.memory_max()!r} and memory.swap.max "
                f"{self.memory_swap_max()!r}, not {expected[0]!r} and {expected[1]!r}: the systemd user manager "
                "cannot set memory limits. It needs the memory controller delegated to it (see the README).")
        while self.admin("GET", "/readyz")[0] != 200:
            if self.process.poll() is not None or time.monotonic() > deadline:
                self.not_started("did not become ready")
            time.sleep(0.05)

    def not_started(self, what):
        """Raises what stops smock from starting: an OOM kill, which the run
        records, or else a BenchError with smock's log."""
        if self.process.poll() is not None:
            self.reader.join(1)
            oom_kills = self.read_oom_kills()
            if oom_kills:
                raise OomKilledAtStartup(oom_kills)
        self.log_file.flush()
        raise BenchError(f"smock {what}; its log:\n{self.log_path.read_text()}")

    def read_log(self):
        expected = {"plain", "tls", "admin"}
        for line in self.process.stderr:
            self.log_file.write(line)
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict) and entry.get("msg") == "listening":
                self.ports[entry["listener"]] = int(entry["address"].rsplit(":", 1)[1])
                if expected <= set(self.ports):
                    self.listening.set()

    def find_pid(self):
        for pid in (self.cgroup / "cgroup.procs").read_text().split():
            try:
                if Path(f"/proc/{pid}/comm").read_text().startswith("smock"):
                    return int(pid)
            except OSError:
                continue
        raise BenchError(f"no smock process in {self.cgroup}")

    def __exit__(self, *_):
        self.memory_peak()
        self.close()

    def close(self):
        """Stops smock if it still runs, reads the OOM kills in its slice,
        and stops the slice."""
        if self.process.poll() is None:
            os.kill(self.pid or self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(STOP_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                subprocess.run(["systemctl", "--user", "kill", "--signal=SIGKILL", self.unit])
                self.process.wait()
        self.exit_status = self.process.returncode
        self.reader.join()
        self.log_file.close()
        self.run.processes.remove(self.process)
        self.oom_kills = self.read_oom_kills()
        subprocess.run(["systemctl", "--user", "stop", self.slice], capture_output=True)

    def read_oom_kills(self):
        """How many processes the OOM killer has killed in smock's slice, or
        None when the slice has no memory.events."""
        if self.slice_cgroup is None:
            self.slice_cgroup = control_group(self.slice)
        try:
            text = (self.slice_cgroup / "memory.events").read_text()
        except (OSError, TypeError):
            return None
        return next((int(line.split()[1]) for line in text.splitlines() if line.startswith("oom_kill ")), None)

    def admin(self, method, path):
        """Calls the admin port, and returns the status and the body."""
        connection = http.client.HTTPConnection("127.0.0.1", self.ports["admin"], timeout=5)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            return response.status, response.read()
        except OSError:
            return None, b""
        finally:
            connection.close()

    def status(self):
        """What the Admin API status operation says: the version, commit and
        toolchain smock was built with, and the definitions it serves."""
        status, body = self.admin("GET", "/v1/status")
        if status != 200:
            raise BenchError(f"the Admin API status operation answered {status}: {body!r}")
        return json.loads(body)

    def cpu_max(self):
        """The CPU quota and period of smock's cgroup, as its cpu.max has
        them, or None once smock has gone."""
        return self.read_cgroup("cpu.max")

    def memory_max(self):
        """The memory limit of smock's cgroup in bytes, as its memory.max has
        it (`max` for none), or None once smock has gone."""
        return self.read_cgroup("memory.max")

    def memory_swap_max(self):
        """How much smock's cgroup may swap, as its memory.swap.max has it,
        or None once smock has gone or where the kernel cannot tell."""
        return self.read_cgroup("memory.swap.max")

    def memory_peak(self):
        """The most memory smock's cgroup has used since it started, in
        bytes, from its memory.peak, or None once smock has gone or where
        the kernel does not keep it. Each reading is remembered, so that
        `peak_bytes` holds the last one taken while smock ran."""
        peak = self.read_cgroup("memory.peak")
        if peak is None:
            return None
        self.peak_bytes = int(peak)
        return self.peak_bytes

    def read_cgroup(self, name):
        try:
            return (self.cgroup / name).read_text().strip()
        except (OSError, TypeError):
            return None

    def cpu_stat(self):
        """The CPU use of smock's cgroup, or None once smock has gone. Each
        reading is remembered in `last_cpu_stat`."""
        text = self.read_cgroup("cpu.stat")
        if text is None:
            return None
        stat = {}
        for line in text.splitlines():
            name, value = line.split()
            stat[name] = int(value)
        self.last_cpu_stat = stat
        return stat

    def rss_kib(self):
        """smock's resident set size in KiB, or None once it has gone."""
        try:
            text = Path(f"/proc/{self.pid}/status").read_text()
        except OSError:
            return None
        for line in text.splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
        return None


class RssSampler:
    """Samples smock's resident set size every `interval` seconds, in KiB,
    from when it is started until it is stopped. It reads smock's peak
    memory and CPU use as often, so that what smock used is known up to
    shortly before it went, if it goes."""

    def __init__(self, smock, interval):
        self.smock = smock
        self.interval = interval
        self.samples = []
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        """Takes a sample at the start, every interval, and at the stop."""
        start = time.monotonic()
        while True:
            stopping = self.stopped.is_set()
            self.samples.append([round(time.monotonic() - start, 3), self.smock.rss_kib()])
            self.smock.memory_peak()
            self.smock.cpu_stat()
            if stopping:
                break
            self.stopped.wait(self.interval)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join()


class Run:
    """The settings of one benchmark run and the processes it has started."""

    def __init__(self, args):
        self.args = args
        self.plan_path = Path(args.plan).resolve()
        self.plan = read_json(self.plan_path)
        self.mix = read_json(BENCH / "requests.json")["requests"]
        self.smock = str(Path(args.smock).resolve())
        self.oha = shutil.which(args.oha) or args.oha
        self.out = Path(args.out).resolve()
        self.tmp = self.out / "tmp"
        self.processes = []
        self.started_at = now()
        self.smock_status = None
        self.ramp_s = override(args.ramp, self.plan["ramp_s"])
        self.duration_s = override(args.duration, self.plan["duration_s"])
        self.tail_s = override(args.tail, self.plan["tail_s"])
        self.rate = args.rate
        plan_name = shown_path(self.plan_path)
        all_profiles = plan_profiles(self.plan)
        self.profiles = all_profiles
        if args.profiles:
            names = args.profiles.split(",")
            for name in names:
                if name not in [profile["name"] for profile in all_profiles]:
                    raise BenchError(f"no profile {name} in {plan_name}")
            self.profiles = [profile for profile in self.profiles if profile["name"] in names]
        if args.cpu_limits:
            limits = args.cpu_limits.split(",")
            for limit in limits:
                if limit not in [profile["cpu_limit"] for profile in all_profiles]:
                    raise BenchError(f"no profile with a CPU limit of {limit} in {plan_name}")
            self.profiles = [profile for profile in self.profiles if profile["cpu_limit"] in limits]
        self.cpu_limits = list(dict.fromkeys(profile["cpu_limit"] for profile in self.profiles))
        names = [case["name"] for case in self.plan["cases"]]
        self.cases = args.cases.split(",") if args.cases else names
        for name in self.cases:
            if name not in names:
                raise BenchError(f"no case {name} in {plan_name}")
        self.cooldown_s = override(args.cooldown, self.plan["cooldown_s"])
        self.settle_s = override(args.settle, self.plan["idle_rss"]["settle_s"])
        # Idle RSS is measured under the profiles the plan names for it,
        # whichever profiles the run selects, or else under each profile the
        # run selects.
        idle_names = self.plan["idle_rss"].get("profiles")
        self.idle_profiles = self.profiles
        if idle_names is not None:
            for name in idle_names:
                if name not in [profile["name"] for profile in all_profiles]:
                    raise BenchError(f"{plan_name}: idle_rss names no profile {name}")
            self.idle_profiles = [profile for profile in all_profiles if profile["name"] in idle_names]
        self.targets_path = Path(args.targets).resolve()
        self.targets = read_targets(self.targets_path)
        ordered = cpus_by_speed()
        # smock gets as many CPUs as the largest limit of the plan needs,
        # whichever limits this run has, so that runs compare.
        needed = max(cpus_needed(profile["cpu_limit"]) for profile in all_profiles)
        self.smock_cpus = parse_cpu_list(args.smock_cpus) if args.smock_cpus else ordered[:needed]
        self.generator_cpus = (parse_cpu_list(args.generator_cpus) if args.generator_cpus
                               else [cpu for cpu in ordered if cpu not in self.smock_cpus])
        if not self.generator_cpus or set(self.smock_cpus) & set(self.generator_cpus):
            raise BenchError("smock and the load generator need CPUs of their own: "
                             f"smock has {self.smock_cpus}, the load generator {self.generator_cpus}")
        for profile in [*self.profiles, *self.idle_profiles]:
            if len(self.smock_cpus) < cpus_needed(profile["cpu_limit"]):
                raise BenchError(f"a CPU limit of {profile['cpu_limit']} needs as many CPUs for smock, "
                                 f"but it has {self.smock_cpus}")
        # A case runs under the profiles it has rates for, once for each
        # rate of its ladder, from the lowest.
        self.specs = [case_spec(self, case, profile, rate, ladder)
                      for profile in self.profiles
                      for case in self.plan["cases"]
                      if case["name"] in self.cases and profile["name"] in case["rates"]
                      for ladder in [self.ladder(case, profile)]
                      for rate in ladder]

    def estimate_s(self):
        """About how many seconds the run takes: smock's idling under each
        idle profile, each step's load, and the pauses between steps."""
        idle = len(self.idle_profiles) * (self.settle_s + SMOCK_START_STOP_S)
        steps = sum(spec["ramp_s"] + spec["duration_s"] + spec["tail_s"] + SMOCK_START_STOP_S for spec in self.specs)
        return idle + steps + max(0, len(self.specs) - 1) * self.cooldown_s

    def ladder(self, case, profile):
        """The rates `case` runs at under `profile`: the plan's rate, or its
        ladder of rates in ascending order, or the one rate of --rate."""
        if self.rate is not None:
            return [self.rate]
        rates = case["rates"][profile["name"]]
        return sorted(rates) if isinstance(rates, list) else [rates]

    def prepare(self):
        """Checks what the run needs, and makes the output directory and
        the TLS certificate."""
        if not Path(self.smock).is_file():
            raise BenchError(f"no smock binary at {self.smock}: build it with scripts/build-release.sh, "
                             "or name one with --smock")
        for tool in (self.oha, "openssl", "taskset", "lscpu", "systemd-run", "systemctl"):
            if not shutil.which(tool):
                raise BenchError(f"{tool} is not on PATH: the README's Benchmark section lists what a run needs")
        self.oha_version = subprocess.run([self.oha, "--version"], capture_output=True, text=True,
                                          check=True).stdout.strip()
        if self.oha_version.split()[-1] != self.plan["load_generator"]["version"]:
            log(f"note: {self.oha_version} is not the oha {self.plan['load_generator']['version']} "
                "that bench/plan.json names (scripts/install-oha.sh installs it)")
        self.out.mkdir(parents=True, exist_ok=True)
        self.tmp.mkdir(exist_ok=True)
        cert, key = self.tmp / "cert.pem", self.tmp / "key.pem"
        hosts = sorted({request["host"] for request in self.mix})
        names = ",".join(["DNS:localhost", "IP:127.0.0.1", *(f"DNS:{host}" for host in hosts)])
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
             "-days", "2", "-subj", "/CN=smock-bench", "-addext", f"subjectAltName={names}",
             "-keyout", str(key), "-out", str(cert)],
            check=True, capture_output=True)
        self.smock_args = [
            "--dir", str(BENCH / "definitions"), "--port", "0", "--tls-port", "0", "--admin-port", "0",
            "--admin-auth", "off", "--tls-cert-file", str(cert), "--tls-key-file", str(key),
        ]
        # smock runs with its defaults, the Journal's bound included, whatever
        # SMOCK_* variables the shell has.
        self.smock_env = {name: value for name, value in os.environ.items() if not name.startswith("SMOCK_")}
        # Every connection is a file descriptor, in smock and in oha.
        _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
        # The harness itself stays off smock's CPUs.
        os.sched_setaffinity(0, self.generator_cpus)

    def conditions(self):
        """What the run ran, where and how."""
        status = self.smock_status or {}
        return {
            "format": FORMAT,
            "started_at": self.started_at,
            "smock": {
                "binary": shown_path(self.smock),
                "sha256": sha256_file(self.smock),
                "version": status.get("version"),
                "commit": status.get("commit"),
                "toolchain": status.get("toolchain"),
                "args": ["serve", *(self.shown_arg(arg) for arg in self.smock_args)],
                "tls_certificate": "self-signed, ECDSA P-256, for localhost, 127.0.0.1 and the Hosts of the mix, "
                                   "made with openssl for the run",
            },
            "definitions": {
                "directory": shown_path(BENCH / "definitions"),
                "digest": status.get("digest"),
                "mocks": status.get("mocks"),
            },
            "request_mix": {
                "file": shown_path(BENCH / "requests.json"),
                "sha256": sha256_file(BENCH / "requests.json"),
                "weights": {request["name"]: request["weight"] for request in self.mix},
            },
            "plan": {"file": shown_path(self.plan_path), "sha256": sha256_file(self.plan_path)},
            "note": self.plan.get("note"),
            "targets": {"file": shown_path(self.targets_path), "sha256": sha256_file(self.targets_path)},
            "machine": machine(),
            "load_generator": {"name": "oha", "version": self.oha_version},
            "harness": {"python": platform.python_version()},
            "cpus": {
                "limits": self.cpu_limits,
                "cfs_period_us": CFS_PERIOD_US,
                "smock": self.smock_cpus,
                "load_generator": self.generator_cpus,
            },
            "profiles": [{**profile, "memory_max": memory_max(profile["memory_limit"]),
                          "swap": "none" if profile["memory_limit"] is not None else "as the machine allows"}
                         for profile in dict((p["name"], p) for p in [*self.profiles, *self.idle_profiles]).values()],
            "page_size": os.sysconf("SC_PAGE_SIZE"),
            "cases": [{key: spec[key] for key in (
                "id", "profile", "protocol", "connection", "cpu_limit", "memory_limit", "rate", "ramp_s",
                "duration_s", "tail_s", "connections", "idle_connections")} for spec in self.specs],
            "overrides": {name: value for name, value in (
                ("rate", self.args.rate), ("ramp_s", self.args.ramp), ("duration_s", self.args.duration),
                ("tail_s", self.args.tail), ("cooldown_s", self.args.cooldown),
                ("settle_s", self.args.settle)) if value is not None},
            "ci": {name: os.environ[name] for name in (
                "GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
                "RUNNER_NAME", "RUNNER_ARCH") if name in os.environ},
        }

    def shown_arg(self, arg):
        """An argument of smock's command line as the conditions show it."""
        if arg.startswith(str(self.tmp)):
            return "<run>/" + Path(arg).name
        return shown_path(arg) if arg.startswith("/") else arg

    def stop_everything(self):
        for process in list(self.processes):
            if process.poll() is None:
                process.kill()


def case_spec(run, case, profile, rate, ladder):
    """What one step of a case runs: the case under `profile` at `rate`,
    one of the rates of its `ladder`. The id names the rate only when the
    ladder has more than one."""
    duration_s = override(run.args.duration, case.get("duration_s", run.duration_s))
    step = f"@{rate}" if len(ladder) > 1 else ""
    return {
        "id": f"{case['name']}@{profile['name']}{step}",
        "case": case["name"],
        "profile": profile["name"],
        "cpu_limit": profile["cpu_limit"],
        "memory_limit": profile["memory_limit"],
        "raw": f"raw/{profile['name']}/{case['name']}{step}",
        "protocol": case["protocol"],
        "connection": case["connection"],
        "connections": case["connections"],
        "idle_connections": case.get("idle_connections", 0),
        "rate": rate,
        "ramp_s": run.ramp_s,
        "duration_s": duration_s,
        "tail_s": run.tail_s,
        "rss_interval_s": case.get("rss_interval_s", run.plan["rss_interval_s"]),
    }


def limits_text(profile):
    """A profile's limits, for people."""
    memory = profile["memory_limit"]
    return f"a CPU limit of {profile['cpu_limit']}" + (f" and a memory limit of {memory}" if memory else "")


def measure_idle_rss(run, profile):
    """Starts smock with the benchmark's definitions under `profile`, waits
    until it is ready, lets it settle with no load, and returns its RSS
    then, its peak memory and the OOM kills. Also learns from it what it is
    and what it serves."""
    log(f"idle RSS: {run.settle_s} s after startup under {limits_text(profile)} ({profile['name']})")
    raw = run.out / "raw" / profile["name"]
    idle = {"profile": profile["name"], "cpu_limit": profile["cpu_limit"], "memory_limit": profile["memory_limit"],
            "settle_s": run.settle_s, "smock_ready": True, "digest": None, "rss_kib": None}
    try:
        with Smock(run, profile, raw / "idle-smock.log") as smock:
            status = smock.status()
            run.smock_status = run.smock_status or status
            idle["digest"] = status.get("digest")
            with RssSampler(smock, run.plan["rss_interval_s"]) as rss:
                time.sleep(run.settle_s)
    except OomKilledAtStartup as killed:
        idle.update(smock_ready=False, memory={"peak_bytes": None, "oom_kills": killed.oom_kills})
        log(f"idle RSS: smock was OOM-killed before it was ready ({profile['name']})")
        return idle
    write_json(raw / "idle-rss.json", {
        "about": "smock's resident set size from when it is ready until it has settled, with no load: "
                 "[seconds since the first sample, KiB].",
        "unit": "KiB",
        "interval_s": run.plan["rss_interval_s"],
        "samples": rss.samples,
    })
    idle.update(rss_kib=rss.samples[-1][1], memory={"peak_bytes": smock.peak_bytes, "oom_kills": smock.oom_kills})
    log(f"idle RSS: {idle['rss_kib']} KiB, peak memory {smock.peak_bytes} bytes, "
        f"{smock.oom_kills} OOM kills ({profile['name']})")
    return idle


def request_rates(run, spec):
    """Each request of the mix with the rate it is sent at, its weight's
    share of the case's rate, as the text oha is given."""
    weights = [request["weight"] for request in run.mix]
    # oha schedules ticket i at i / rate, from the rate it parses: the
    # analysis uses the same number.
    return [(request, f"{spec['rate'] * request['weight'] / sum(weights):.6f}") for request in run.mix]


def window(spec, rate):
    """The first ticket of the measured window at `rate` and the first one
    after it."""
    return math.ceil(spec["ramp_s"] * rate), math.ceil((spec["ramp_s"] + spec["duration_s"]) * rate)


def start_load(run, smock, spec, raw):
    """Starts one oha process per request of the mix, and returns them with
    the rate each was given."""
    https = spec["protocol"] == "https"
    port = smock.ports["tls" if https else "plain"]
    total_ms = round((spec["ramp_s"] + spec["duration_s"] + spec["tail_s"]) * 1000)
    weights = [request["weight"] for request in run.mix]
    load = []
    for (request, rate), connections in zip(request_rates(run, spec), split(spec["connections"], weights),
                                            strict=True):
        command = [
            "taskset", "-c", cpu_list(run.generator_cpus), run.oha,
            "--no-tui", "--output-format", "json", "-o", str(raw / f"oha-{request['name']}.json"),
            "--db-url", str(run.tmp / f"{request['name']}.sqlite"),
            "-z", f"{total_ms}ms", "-q", rate, "--latency-correction", "-w",
            "-c", str(connections), "--worker-threads", "1", "-t", "30s", "--disable-compression",
            "--connect-to", f"{request['host']}:{443 if https else 80}:127.0.0.1:{port}",
            "-m", request["method"],
        ]
        for name, value in request["headers"]:
            command += ["-H", f"{name}: {value}"]
        if request["body"] is not None:
            command += ["-d", request["body"]]
        if https:
            command.append("--insecure")
        if spec["connection"] == "new-per-request":
            command.append("--disable-keepalive")
        command.append(f"{'https' if https else 'http'}://{request['host']}{request['target']}")
        stderr = (raw / f"oha-{request['name']}.log").open("w")
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=stderr)
        stderr.close()
        run.processes.append(process)
        load.append({"request": request, "rate": float(rate), "connections": connections, "process": process})
    return load


def analyze_request(run, item, spec, raw):
    """What one oha process measured for its request: the latencies of the
    requests scheduled in the window, counted from their due times and from
    the times oha released them, how late it released them, and what went
    wrong."""
    request, rate = item["request"], item["rate"]
    database = run.tmp / f"{request['name']}.sqlite"
    first, last = window(spec, rate)
    latencies, release_latencies, lags = array.array("d"), array.array("d"), array.array("d")
    ok = unexpected = 0
    if database.exists():
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        # With -q and --latency-correction, one task of oha releases ticket
        # k once k / rate has passed since its start, whether or not a
        # connection is free to send it, and each request records the time
        # its ticket was released. A request's latency counts from k / rate,
        # its due time, so every wait counts: for a busy or stalled smock,
        # and for oha itself when it falls behind, as it does when a stalled
        # smock answers a burst at once and oha's one thread is busy reading
        # it. oha's timer has a resolution of 1 ms, so tickets go out about
        # a millisecond after they are due, now and then a few more: the
        # lag, reported apart with the latency from release, which leaves
        # it out. Tickets are
        # released in order, so the k-th release is ticket k. oha stores only
        # the requests that got a response: when some got none, the k-th
        # stored release is ticket k or a later one, and the lag and the
        # latency of such a case are overstated.
        rows = connection.execute("SELECT start_latency_correction, end, status FROM oha "
                                  "ORDER BY start_latency_correction")
        for k, (released, ended, status) in enumerate(rows):
            if first <= k < last:
                due = k / rate
                latencies.append(ended - due)
                release_latencies.append(ended - released)
                lags.append(released - due)
                if status == request["expect"]["status"]:
                    ok += 1
                else:
                    unexpected += 1
        connection.close()
        database.unlink()
    summary_path = raw / f"oha-{request['name']}.json"
    oha_errors = {}
    if summary_path.exists() and summary_path.stat().st_size:
        oha_errors = read_json(summary_path).get("errorDistribution") or {}
    log_path = raw / f"oha-{request['name']}.log"
    if log_path.exists() and all(line.startswith("Storing results") for line in log_path.read_text().splitlines()):
        log_path.unlink()
    scheduled = last - first
    return {
        "name": request["name"],
        "rate": rate,
        "connections": item["connections"],
        "scheduled": scheduled,
        "ok": ok,
        "unexpected_status": unexpected,
        "no_response": max(0, scheduled - ok - unexpected),
        "oha_errors": oha_errors,
        "oha_exit_status": item["process"].returncode,
    }, latencies, release_latencies, lags


def cpu_use(before, after):
    """The CPU smock's cgroup used and was throttled for between two
    readings of its cpu.stat, or None when smock was gone at either."""
    if before is None or after is None:
        return None
    return {
        "usage_s": round((after["usage_usec"] - before["usage_usec"]) / 1e6, 3),
        "periods": after["nr_periods"] - before["nr_periods"],
        "throttled_periods": after["nr_throttled"] - before["nr_throttled"],
        "throttled_s": round((after["throttled_usec"] - before["throttled_usec"]) / 1e6, 3),
    }


def run_case(run, spec):
    raw = run.out / spec["raw"]
    raw.mkdir(parents=True, exist_ok=True)
    total_s = spec["ramp_s"] + spec["duration_s"] + spec["tail_s"]
    log(f"{spec['id']}: {spec['rate']} requests/s for {spec['duration_s']} s under {limits_text(spec)}")
    with contextlib.ExitStack() as stack:
        try:
            smock = stack.enter_context(Smock(run, spec, raw / "smock.log"))
        except OomKilledAtStartup as killed:
            return not_ready_result(run, spec, killed.oom_kills)
        rss = stack.enter_context(RssSampler(smock, spec["rss_interval_s"]))
        idle = stack.enter_context(IdleConnections(smock.ports["plain"], spec["idle_connections"], run.mix[0]))
        cpu_before = smock.cpu_stat()
        opens_before = tcp_passive_opens()
        load = start_load(run, smock, spec, raw)
        pids = " ".join(str(item["process"].pid) for item in load)
        log(f"{spec['id']}: load started (smock pid {smock.pid}, load generator pids {pids})")
        generator_cpus = set()
        for item in load:
            generator_cpus |= set(cpus_allowed(item["process"].pid) or [])
        pinning = {
            "smock_cpu_max": smock.cpu_max(),
            "smock_memory_max": smock.memory_max(),
            "smock_memory_swap_max": smock.memory_swap_max(),
            "smock_cpus": cpus_allowed(smock.pid),
            "load_generator_cpus": sorted(generator_cpus),
        }
        for item in load:
            item["process"].wait(total_s + 300)
            run.processes.remove(item["process"])
        # What smock used until the load ended, or until it went.
        cpu_after = smock.cpu_stat() or smock.last_cpu_stat
        opens = tcp_passive_opens() - opens_before
        idle_open = idle.open_count()
    kinds = []
    latencies, release_latencies, lags = array.array("d"), array.array("d"), array.array("d")
    for item in load:
        kind, kind_latencies, kind_release_latencies, kind_lags = analyze_request(run, item, spec, raw)
        kinds.append(kind)
        latencies.extend(kind_latencies)
        release_latencies.extend(kind_release_latencies)
        lags.extend(kind_lags)
    latencies = sorted(latencies)
    release_latencies = sorted(release_latencies)
    lags = sorted(lags)
    write_json(raw / "latency.json", {
        "about": "Latencies of the requests scheduled in the measured window that got a response, "
                 "from the times the fixed-rate schedule had them due, all request kinds together: "
                 "[upper bound, count] per bucket, three significant digits.",
        "unit": "us",
        "counts": histogram(latencies),
    })
    rss_values = [kib for _, kib in rss.samples if kib is not None]
    write_json(raw / "rss.json", {
        "about": "smock's resident set size, sampled from before the load starts until it ends: "
                 "[seconds since the first sample, KiB].",
        "unit": "KiB",
        "interval_s": spec["rss_interval_s"],
        "samples": rss.samples,
    })
    scheduled = sum(kind["scheduled"] for kind in kinds)
    ok = sum(kind["ok"] for kind in kinds)
    errors = scheduled - ok
    lag = percentiles_ms(lags, ("p50", "p99", "p99_9", "max"))
    result = {
        **spec,
        "achieved_rate": round(ok / spec["duration_s"], 1),
        "errors": errors,
        "latency_ms": percentiles_ms(latencies, LATENCY_METRICS),
        "latency_from_release_ms": percentiles_ms(release_latencies, LATENCY_METRICS),
        "generator_lag_ms": lag,
        "load_generator_late": any(lag[name] is not None and lag[name] > limit
                                   for name, limit in GENERATOR_LAG_LIMITS_MS.items()),
        "requests": {
            "scheduled": scheduled,
            "ok": ok,
            "unexpected_status": sum(kind["unexpected_status"] for kind in kinds),
            "no_response": sum(kind["no_response"] for kind in kinds),
        },
        "tcp_passive_opens": opens,
        "idle_connections_open_at_end": idle_open,
        "pinning": pinning,
        "smock_cpu": cpu_use(cpu_before, cpu_after),
        "memory": {"peak_bytes": smock.peak_bytes, "oom_kills": smock.oom_kills},
        "rss_kib": {
            "first": rss_values[0] if rss_values else None,
            "last": rss_values[-1] if rss_values else None,
            "max": max(rss_values, default=None),
        },
        "smock_ready": True,
        "smock_exit_status": smock.exit_status,
        "per_request": kinds,
    }
    log(f"{spec['id']}: p99 {result['latency_ms']['p99']} ms, p99.9 {result['latency_ms']['p99_9']} ms, "
        f"{result['achieved_rate']} requests/s, {errors} errors, "
        f"generator lag p99.9 {lag['p99_9']} ms, max {lag['max']} ms, "
        f"peak memory {smock.peak_bytes} bytes, {smock.oom_kills} OOM kills")
    return result


def not_ready_result(run, spec, oom_kills):
    """The result of a case whose smock was OOM-killed before it was ready:
    no load was sent, and every request of the window is an error, with no
    response."""
    scheduled = sum(last - first for first, last in (window(spec, float(rate)) for _, rate in request_rates(run, spec)))
    none = {metric: None for metric in LATENCY_METRICS}
    log(f"{spec['id']}: smock was OOM-killed before it was ready; no load was sent")
    return {
        **spec,
        "achieved_rate": 0,
        "errors": scheduled,
        "latency_ms": none,
        "latency_from_release_ms": none,
        "generator_lag_ms": {metric: None for metric in ("p50", "p99", "p99_9", "max")},
        "load_generator_late": False,
        "requests": {"scheduled": scheduled, "ok": 0, "unexpected_status": 0, "no_response": scheduled},
        "tcp_passive_opens": None,
        "idle_connections_open_at_end": None,
        "pinning": None,
        "smock_cpu": None,
        "memory": {"peak_bytes": None, "oom_kills": oom_kills},
        "rss_kib": {"first": None, "last": None, "max": None},
        "smock_ready": False,
        "smock_exit_status": None,
        "per_request": [],
    }


LATENCY_METRICS = ("p50", "p90", "p99", "p99_9", "max")


def percentiles_ms(ordered, metrics):
    """The `metrics` (p50, p90, p99, p99_9 or max) of sorted values in
    seconds, in milliseconds."""
    fractions = {"p50": 0.5, "p90": 0.9, "p99": 0.99, "p99_9": 0.999}
    return {metric: ms(ordered[-1] if ordered else None) if metric == "max"
            else ms(percentile(ordered, fractions[metric])) for metric in metrics}


def lag_limits_text():
    """The limits of GENERATOR_LAG_LIMITS_MS, for people."""
    return ", ".join(f"{name.replace('_', '.')} {limit} ms" for name, limit in GENERATOR_LAG_LIMITS_MS.items())


def read_targets(path):
    """The targets of a targets file, checked for what this script can
    check."""
    targets = read_json(path)["targets"]
    for target in targets:
        metric, unit = target.get("metric"), target.get("unit")
        if not (metric in LATENCY_METRICS and unit == "ms" or metric == "idle_rss" and unit == "MiB"):
            raise BenchError(f"{path}: target {target.get('id')}: metric {metric} in {unit} cannot be checked; "
                             f"use one of {', '.join(LATENCY_METRICS)} in ms, or idle_rss in MiB")
    return targets


def check_target(target, summary):
    """Whether the run met `target`: the target with its verdict (met,
    missed or not measured), what was measured, and why when it is not
    plain."""
    checked = {**target, "verdict": "not measured", "measured": None, "reason": None}
    if target["metric"] == "idle_rss":
        # Under every profile it was measured under.
        measured = [idle["rss_kib"] for idle in summary["idle_rss"] if idle["rss_kib"] is not None]
        if not measured:
            checked["reason"] = "the run did not measure idle RSS"
            return checked
        checked["measured"] = round(max(measured) / 1024, 2)
    else:
        profile = target.get("profile", target.get("cpu_limit"))
        case_id = f"{target['case']}@{profile}"
        found = [case for case in summary["cases"] if (case["case"], case["profile"]) == (target["case"], profile)]
        if not found:
            checked["reason"] = f"the run did not run {case_id}"
            return checked
        at_rate = [case for case in found if case["rate"] == target["rate"]]
        if not at_rate:
            rates = " and ".join(str(case["rate"]) for case in found)
            checked["reason"] = (f"{case_id} ran at {rates} requests/s, "
                                 f"the target is at {target['rate']} requests/s")
            return checked
        case = at_rate[0]
        case_id = case["id"]
        if case["memory"]["oom_kills"]:
            checked["verdict"] = "missed"
            checked["reason"] = f"smock was OOM-killed in {case_id}"
            return checked
        checked["measured"] = case["latency_ms"][target["metric"]]
        if case["load_generator_late"]:
            lag = case["generator_lag_ms"]
            checked["reason"] = (f"the load generator fell behind its schedule in {case_id} "
                                 f"(lag p99.9 {lag['p99_9']} ms, max {lag['max']} ms; "
                                 f"at most {lag_limits_text()})")
            return checked
        if case["errors"]:
            checked["verdict"] = "missed"
            checked["reason"] = (f"{case['errors']} errors: {case['errors']} of the "
                                 f"{case['requests']['scheduled']} requests got no expected response")
            return checked
        if checked["measured"] is None:
            checked["reason"] = f"{case_id} has no latencies"
            return checked
    checked["verdict"] = "met" if checked["measured"] <= target["max"] else "missed"
    return checked


def shown(value):
    """A value of the summary as summary.md shows it: `-` for none."""
    return "-" if value is None else str(value)


def mib(value, unit=1):
    """`value`, in units of `unit` bytes, in MiB with one decimal, or `-`."""
    return "-" if value is None else f"{value * unit / (1 << 20):.1f}"


def profile_heading(profile):
    memory = profile["memory_limit"]
    return (f"## {profile['name']}: CPU limit {profile['cpu_limit']}, "
            + (f"memory limit {memory}" if memory else "no memory limit"))


def idle_line(idle):
    """What smock used under a profile at idle, for people."""
    memory = idle.get("memory") or {}
    if not idle["smock_ready"]:
        return (f"Idle RSS: not measured, smock was OOM-killed before it was ready "
                f"({shown(memory.get('oom_kills'))} OOM kills).")
    return (f"Idle RSS: {mib(idle['rss_kib'], 1024)} MiB, {idle['settle_s']} s after startup; "
            f"peak memory {mib(memory.get('peak_bytes'))} MiB, {shown(memory.get('oom_kills'))} OOM kills.")


CASE_COLUMNS = ("Case", "Rate", "Achieved", "p50 ms", "p99 ms", "p99.9 ms", "Max ms", "From release p99.9 ms",
                "Lag p99.9 ms", "Lag max ms", "Errors", "Throttled s", "Max RSS MiB", "Peak memory MiB", "OOM kills")


def case_row(case):
    """A case's row of its profile's table in summary.md."""
    latency, release, lag = case["latency_ms"], case["latency_from_release_ms"], case["generator_lag_ms"]
    memory, cpu = case["memory"], case["smock_cpu"] or {}
    name = case["case"]
    if not case["smock_ready"]:
        name += " (smock OOM-killed before it was ready)"
    elif case["load_generator_late"]:
        name += " (late)"
    # Once smock has gone, the last peak read while it ran is a lower bound.
    peak = mib(memory["peak_bytes"])
    if memory["oom_kills"] and memory["peak_bytes"] is not None:
        peak = f">= {peak}"
    cells = [name, case["rate"], case["achieved_rate"], latency["p50"], latency["p99"], latency["p99_9"],
             latency["max"], release["p99_9"], lag["p99_9"], lag["max"], case["errors"], cpu.get("throttled_s"),
             mib(case["rss_kib"]["max"], 1024), peak, memory["oom_kills"]]
    return "| " + " | ".join(shown(cell) for cell in cells) + " |"


def summary_markdown(summary, conditions):
    """The summary for people: the targets, then for each profile idle RSS
    and the cases."""
    smock, machine = conditions["smock"], conditions["machine"]
    lines = [
        "# smock benchmark",
        "",
        f"Started {conditions['started_at']}: smock {smock['version']} (commit {smock['commit']}, "
        f"{smock['toolchain']}), definition set {conditions['definitions']['digest']}, "
        f"on {machine['architecture']} ({machine['cpu_model']}, {machine['cpus']} CPUs), "
        f"{conditions['load_generator']['version']}, plan {conditions['plan']['file']}.",
    ]
    if conditions.get("note"):
        lines += ["", f"**Note:** {conditions['note']}"]
    if conditions["overrides"]:
        shown_overrides = ", ".join(f"{name} {value}" for name, value in conditions["overrides"].items())
        lines += ["", f"**Not a full run:** the command line changed the plan ({shown_overrides})."]
    if not summary["complete"]:
        lines += ["", "**Incomplete:** the run stopped before its last case."]
    lines += ["", "## Targets", "", "| Target | At most | Measured | Verdict |", "|---|---|---|---|"]
    for target in summary["targets"]:
        measured = "-" if target["measured"] is None else f"{target['measured']} {target['unit']}"
        verdict = target["verdict"] + (f": {target['reason']}" if target["reason"] else "")
        lines.append(f"| {target['about']} | {target['max']} {target['unit']} | {measured} | {verdict} |")
    lines += ["", "## Reading the cases", "",
              "Each profile is a CPU limit, a CFS quota over a 100 ms period, and a memory limit, memory.max "
              "with no swap. Latency counts from each request's scheduled send time. *From release* counts "
              "from when the load generator released it, and *lag* is how late it released them; oha's 1 ms "
              "timer adds about a millisecond, now and then a few more. A case whose lag is over its limits "
              f"({lag_limits_text()}) fell behind its schedule and is marked *late*. *Throttled* is how long "
              "the CPU quota held smock back during the load (cpu.stat). *Peak memory* is the most memory "
              "smock's cgroup used (memory.peak: what memory.max limits, the Journal, socket buffers and page "
              "cache included), and *OOM kills* how many times the kernel killed smock for memory "
              "(memory.events)."]
    for profile in conditions["profiles"]:
        lines += ["", profile_heading(profile)]
        for idle in summary["idle_rss"]:
            if idle["profile"] == profile["name"]:
                lines += ["", idle_line(idle)]
        cases = [case for case in summary["cases"] if case["profile"] == profile["name"]]
        if cases:
            lines += ["", "| " + " | ".join(CASE_COLUMNS) + " |", "|" + "---|" * len(CASE_COLUMNS)]
            lines += [case_row(case) for case in cases]
    return "\n".join(lines) + "\n"


def write_summary(run, summary, conditions):
    summary["targets"] = [check_target(target, summary) for target in run.targets]
    write_json(run.out / "summary.json", summary)
    (run.out / "summary.md").write_text(summary_markdown(summary, conditions))


def command_run(args):
    run = Run(args)
    run.prepare()
    estimate = round(run.estimate_s())
    log(f"{len(run.idle_profiles)} idle RSS measurements and {len(run.specs)} steps under "
        f"{len(run.profiles)} profiles of {shown_path(run.plan_path)}: about {estimate / 60:.1f} minutes ({estimate} s)")
    summary = {"format": FORMAT, "complete": False, "idle_rss": [], "cases": [], "targets": []}
    conditions = None
    try:
        for profile in run.idle_profiles:
            summary["idle_rss"].append(measure_idle_rss(run, profile))
        conditions = run.conditions()
        write_json(run.out / "conditions.json", conditions)
        write_summary(run, summary, conditions)
        for i, spec in enumerate(run.specs):
            if i:
                time.sleep(run.cooldown_s)
            summary["cases"].append(run_case(run, spec))
            write_summary(run, summary, conditions)
        summary["complete"] = True
    finally:
        run.stop_everything()
        shutil.rmtree(run.tmp, ignore_errors=True)
        if conditions:
            conditions["finished_at"] = now()
            write_json(run.out / "conditions.json", conditions)
            write_summary(run, summary, conditions)
    for target in summary["targets"]:
        measured = "" if target["measured"] is None else f" ({target['measured']} {target['unit']})"
        reason = f": {target['reason']}" if target["reason"] else ""
        log(f"target {target['id']}, at most {target['max']} {target['unit']}: {target['verdict']}{measured}{reason}")
    log(f"done: {run.out}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="bench.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run the benchmark")
    run.add_argument("--smock", default=str(ROOT / "dist" / "smock"),
                     help="the smock binary (default: dist/smock, as scripts/build-release.sh builds it)")
    run.add_argument("--oha", default="oha", help="the oha binary (default: oha on PATH)")
    run.add_argument("--out", help="where to write the results (default: bench/results/<date>-<time>)")
    run.add_argument("--plan", default=str(BENCH / "plan.json"),
                     help="the plan to run (default: bench/plan.json; bench/plan-autopilot.json has the "
                          "GKE Autopilot profiles)")
    run.add_argument("--cases", help="only these cases of the plan, comma-separated")
    run.add_argument("--profiles", help="only these resource profiles of the plan, comma-separated")
    run.add_argument("--cpu-limits", help="only the profiles with these CPU limits, comma-separated, such as 250m,1")
    run.add_argument("--rate", type=number, help="send every case at this many requests per second, "
                     "instead of the plan's rate (for checking the harness, not for measuring)")
    run.add_argument("--ramp", type=number, help="seconds of load before the measured window")
    run.add_argument("--duration", type=number, help="seconds of measured window per case")
    run.add_argument("--tail", type=number, help="seconds of load after the window, for the last requests to finish")
    run.add_argument("--cooldown", type=number, help="seconds to wait between cases")
    run.add_argument("--settle", type=number, help="seconds smock idles after startup before its idle RSS is read")
    run.add_argument("--targets", default=str(BENCH / "targets.json"),
                     help="the targets to check (default: bench/targets.json)")
    run.add_argument("--smock-cpus", help="the CPUs smock runs on, such as 4,5 (default: the fastest, as many as "
                     "the largest CPU limit of the plan needs)")
    run.add_argument("--generator-cpus", help="the CPUs oha runs on (default: every other CPU)")
    args = parser.parse_args(argv)
    if args.command == "run" and not args.out:
        args.out = str(BENCH / "results" / time.strftime("%Y%m%d-%H%M%S"))
    try:
        return command_run(args)
    except BenchError as error:
        log(str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
