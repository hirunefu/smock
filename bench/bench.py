#!/usr/bin/env python3
"""The release benchmark of smock.

It runs smock with the benchmark's definition set (bench/definitions/) under
CPU limits and sends it the request mix (bench/requests.json) at a fixed
arrival rate, an open model: requests go out on schedule whether or not
earlier ones have been answered. Each request's latency counts from the time
it was scheduled to be sent, so a server that stalls cannot hide the queue
that builds up behind it. bench/plan.json says which cases run, at which
rates and for how long.

usage:
  python3 bench/bench.py run [options]    run the benchmark (--help lists the options)

It needs Linux, python3 (3.10 or later), oha, openssl, taskset, and a systemd
user manager that may set CPU quotas. The README's Benchmark section says how
to run it and how to read what it writes.
"""

import argparse
import array
import http.client
import itertools
import json
import math
import os
import resource
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent

# How long smock may take to start listening, and to exit after SIGTERM.
START_TIMEOUT_S = 30
STOP_TIMEOUT_S = 30


class BenchError(Exception):
    """A problem that stops the run, with what to do about it."""


def log(message):
    print(f"bench: {message}", file=sys.stderr, flush=True)


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def cpu_quota_percent(limit):
    """The systemd CPUQuota percentage of a Kubernetes-style CPU limit:
    250m is 25 %, 2 is 200 %."""
    if limit.endswith("m"):
        return int(limit[:-1]) // 10
    return int(float(limit) * 100)


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


def percentile(ordered, fraction):
    """The nearest-rank percentile of sorted values, or None for none."""
    if not ordered:
        return None
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def ms(seconds):
    return None if seconds is None else round(seconds * 1000, 3)


class Smock:
    """One smock process serving the benchmark's definitions, started in its
    own systemd scope under a CPU quota and pinned to the smock CPUs."""

    units = itertools.count(1)

    def __init__(self, run, cpu_limit, log_path):
        self.run = run
        self.cpu_limit = cpu_limit
        self.log_path = Path(log_path)
        self.ports = {}
        self.listening = threading.Event()
        self.process = None
        self.pid = None
        self.cgroup = None
        self.exit_status = None

    def __enter__(self):
        self.unit = f"smock-bench-{os.getpid()}-{next(Smock.units)}"
        command = [
            "systemd-run", "--user", "--scope", "--quiet", "--collect", f"--unit={self.unit}",
            "-p", f"CPUQuota={cpu_quota_percent(self.cpu_limit)}%", "--",
            "taskset", "-c", cpu_list(self.run.smock_cpus),
            self.run.smock, "serve", *self.run.smock_args,
        ]
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_file = self.log_path.open("w")
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, text=True)
        self.run.processes.append(self.process)
        self.reader = threading.Thread(target=self.read_log, daemon=True)
        self.reader.start()
        deadline = time.monotonic() + START_TIMEOUT_S
        while not self.listening.wait(0.05):
            if self.process.poll() is not None or time.monotonic() > deadline:
                self.reader.join(1)
                self.log_file.flush()
                raise BenchError(f"smock did not start listening; its log:\n{self.log_path.read_text()}")
        self.cgroup = Path("/sys/fs/cgroup" + subprocess.run(
            ["systemctl", "--user", "show", "-P", "ControlGroup", f"{self.unit}.scope"],
            capture_output=True, text=True, check=True).stdout.strip())
        self.pid = self.find_pid()
        while self.admin("GET", "/readyz")[0] != 200:
            if time.monotonic() > deadline:
                raise BenchError("smock did not become ready")
            time.sleep(0.05)
        return self

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
        if self.process.poll() is None:
            os.kill(self.pid, signal.SIGTERM)
            try:
                self.process.wait(STOP_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                subprocess.run(["systemctl", "--user", "kill", "--signal=SIGKILL", f"{self.unit}.scope"])
                self.process.wait()
        self.exit_status = self.process.returncode
        self.reader.join()
        self.log_file.close()
        self.run.processes.remove(self.process)

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

    def cpu_stat(self):
        stat = {}
        for line in (self.cgroup / "cpu.stat").read_text().splitlines():
            name, value = line.split()
            stat[name] = int(value)
        return stat

    def rss_kib(self):
        for line in Path(f"/proc/{self.pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
        return None


class RssSampler:
    """Samples smock's resident set size every `interval` seconds, in KiB,
    from when it is started until it is stopped."""

    def __init__(self, smock, interval):
        self.smock = smock
        self.interval = interval
        self.samples = []
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        start = time.monotonic()
        while True:
            self.samples.append([round(time.monotonic() - start, 3), self.smock.rss_kib()])
            if self.stopped.wait(self.interval):
                break

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join()


class Run:
    """The settings of one benchmark run and the processes it has started."""

    def __init__(self, args):
        self.plan = read_json(BENCH / "plan.json")
        self.mix = read_json(BENCH / "requests.json")["requests"]
        self.total_weight = sum(request["weight"] for request in self.mix)
        self.smock = str(Path(args.smock).resolve())
        self.oha = shutil.which(args.oha) or args.oha
        self.out = Path(args.out).resolve()
        self.tmp = self.out / "tmp"
        self.processes = []
        self.ramp_s = args.ramp if args.ramp is not None else self.plan["ramp_s"]
        self.duration_s = args.duration if args.duration is not None else self.plan["duration_s"]
        self.tail_s = args.tail if args.tail is not None else self.plan["tail_s"]
        self.rate = args.rate
        self.cpu_limits = args.cpu_limits.split(",") if args.cpu_limits else self.plan["cpu_limits"]
        names = [case["name"] for case in self.plan["cases"]]
        self.cases = args.cases.split(",") if args.cases else names
        for name in self.cases:
            if name not in names:
                raise BenchError(f"no case {name} in bench/plan.json")
        ordered = cpus_by_speed()
        self.smock_cpus = parse_cpu_list(args.smock_cpus) if args.smock_cpus else ordered[:2]
        self.generator_cpus = (parse_cpu_list(args.generator_cpus) if args.generator_cpus
                               else [cpu for cpu in ordered if cpu not in self.smock_cpus])
        if not self.generator_cpus or set(self.smock_cpus) & set(self.generator_cpus):
            raise BenchError("smock and the load generator need CPUs of their own: "
                             f"smock has {self.smock_cpus}, the load generator {self.generator_cpus}")

    def prepare(self):
        """Makes the output directory and the TLS certificate."""
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
        # Every connection is a file descriptor, in smock and in oha.
        _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
        # The harness itself stays off smock's CPUs.
        os.sched_setaffinity(0, self.generator_cpus)

    def stop_everything(self):
        for process in list(self.processes):
            if process.poll() is None:
                process.kill()


def case_spec(run, case, cpu_limit):
    rate = run.rate if run.rate is not None else case["rates"][cpu_limit]
    return {
        "id": f"{case['name']}@{cpu_limit}",
        "case": case["name"],
        "cpu_limit": cpu_limit,
        "protocol": case["protocol"],
        "connection": case["connection"],
        "connections": case["connections"],
        "idle_connections": case.get("idle_connections", 0),
        "rate": rate,
        "ramp_s": run.ramp_s,
        "duration_s": run.duration_s,
        "tail_s": run.tail_s,
        "rss_interval_s": run.plan["rss_interval_s"],
    }


def start_load(run, smock, spec, raw):
    """Starts one oha process per request of the mix, and returns them with
    the rate each was given."""
    https = spec["protocol"] == "https"
    port = smock.ports["tls" if https else "plain"]
    total_ms = round((spec["ramp_s"] + spec["duration_s"] + spec["tail_s"]) * 1000)
    load = []
    for request in run.mix:
        share = request["weight"] / run.total_weight
        # oha schedules ticket i at i / rate, from the rate it parses: give
        # it the same number the analysis uses.
        rate = f"{spec['rate'] * share:.6f}"
        connections = max(1, round(spec["connections"] * share))
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
    requests scheduled in the window, counted from their scheduled send
    times, and the counts of what went wrong."""
    request, rate = item["request"], item["rate"]
    database = run.tmp / f"{request['name']}.sqlite"
    first = math.ceil(spec["ramp_s"] * rate)
    last = math.ceil((spec["ramp_s"] + spec["duration_s"]) * rate)
    latencies, lags = array.array("d"), array.array("d")
    ok = unexpected = completed = 0
    if database.exists():
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        # oha releases ticket i at i / rate after its start (or later, when
        # it falls behind) and records the release time. Tickets are
        # released in order, so the k-th release is ticket k.
        rows = connection.execute("SELECT start_latency_correction, end, status FROM oha "
                                  "ORDER BY start_latency_correction")
        for k, (released, ended, status) in enumerate(rows):
            due = k / rate
            lags.append(released - due)
            if first <= k < last:
                completed += 1
                latencies.append(ended - due)
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
        "not_completed": max(0, scheduled - completed),
        "transport_errors": sum(oha_errors.values()),
        "oha_exit_status": item["process"].returncode,
    }, latencies, lags


def run_case(run, spec):
    raw = run.out / "raw" / spec["cpu_limit"] / spec["case"]
    raw.mkdir(parents=True, exist_ok=True)
    total_s = spec["ramp_s"] + spec["duration_s"] + spec["tail_s"]
    log(f"{spec['id']}: {spec['rate']} requests/s for {spec['duration_s']} s "
        f"under a CPU limit of {spec['cpu_limit']}")
    with Smock(run, spec["cpu_limit"], raw / "smock.log") as smock:
        with RssSampler(smock, spec["rss_interval_s"]):
            cpu_before = smock.cpu_stat()
            load = start_load(run, smock, spec, raw)
            pids = " ".join(str(item["process"].pid) for item in load)
            log(f"{spec['id']}: load started (smock pid {smock.pid}, load generator pids {pids})")
            for item in load:
                item["process"].wait(total_s + 300)
                run.processes.remove(item["process"])
            cpu_after = smock.cpu_stat()
    kinds, latencies, lags = [], array.array("d"), array.array("d")
    for item in load:
        kind, kind_latencies, kind_lags = analyze_request(run, item, spec, raw)
        kinds.append(kind)
        latencies.extend(kind_latencies)
        lags.extend(kind_lags)
    latencies = sorted(latencies)
    lags = sorted(lags)
    ok = sum(kind["ok"] for kind in kinds)
    errors = sum(kind["unexpected_status"] + kind["not_completed"] + kind["transport_errors"] for kind in kinds)
    result = {
        **spec,
        "achieved_rps": round(ok / spec["duration_s"], 1),
        "errors": errors,
        "latency_ms": {
            "p50": ms(percentile(latencies, 0.5)),
            "p90": ms(percentile(latencies, 0.9)),
            "p99": ms(percentile(latencies, 0.99)),
            "p99_9": ms(percentile(latencies, 0.999)),
            "max": ms(latencies[-1] if latencies else None),
        },
        "generator_lag_ms": {
            "p50": ms(percentile(lags, 0.5)),
            "p99": ms(percentile(lags, 0.99)),
            "max": ms(lags[-1] if lags else None),
        },
        "requests": {
            "scheduled": sum(kind["scheduled"] for kind in kinds),
            "ok": ok,
            "unexpected_status": sum(kind["unexpected_status"] for kind in kinds),
            "not_completed": sum(kind["not_completed"] for kind in kinds),
            "transport_errors": sum(kind["transport_errors"] for kind in kinds),
        },
        "smock_cpu": {
            "usage_s": round((cpu_after["usage_usec"] - cpu_before["usage_usec"]) / 1e6, 3),
            "periods": cpu_after["nr_periods"] - cpu_before["nr_periods"],
            "throttled_periods": cpu_after["nr_throttled"] - cpu_before["nr_throttled"],
            "throttled_s": round((cpu_after["throttled_usec"] - cpu_before["throttled_usec"]) / 1e6, 3),
        },
        "smock_exit_status": smock.exit_status,
        "per_request": kinds,
    }
    log(f"{spec['id']}: p99 {result['latency_ms']['p99']} ms, p99.9 {result['latency_ms']['p99_9']} ms, "
        f"{result['achieved_rps']} requests/s, {errors} errors")
    return result


def command_run(args):
    run = Run(args)
    run.prepare()
    results = {"cases": []}
    try:
        for cpu_limit in run.cpu_limits:
            for case in run.plan["cases"]:
                if case["name"] in run.cases:
                    results["cases"].append(run_case(run, case_spec(run, case, cpu_limit)))
                    write_json(run.out / "results.json", results)
    finally:
        run.stop_everything()
        shutil.rmtree(run.tmp, ignore_errors=True)
    log(f"done: {run.out}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="bench.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run the benchmark")
    run.add_argument("--smock", default=str(ROOT / "dist" / "smock"),
                     help="the smock binary (default: dist/smock, as scripts/build-release.sh builds it)")
    run.add_argument("--oha", default="oha", help="the oha binary (default: oha on PATH)")
    run.add_argument("--out", help="where to write the results (default: bench/results/<run id>)")
    run.add_argument("--cases", help="only these cases of bench/plan.json, comma-separated")
    run.add_argument("--cpu-limits", help="only these CPU limits, comma-separated, such as 250m,1")
    run.add_argument("--rate", type=float, help="send every case at this many requests per second, "
                     "instead of the plan's rate (for checking the harness, not for measuring)")
    run.add_argument("--ramp", type=float, help="seconds of load before the measured window")
    run.add_argument("--duration", type=float, help="seconds of measured window per case")
    run.add_argument("--tail", type=float, help="seconds of load after the window, for the last requests to finish")
    run.add_argument("--smock-cpus", help="the CPUs smock runs on, such as 4,5 (default: the two fastest)")
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
