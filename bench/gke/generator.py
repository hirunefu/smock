#!/usr/bin/env python3
"""The load generator of the GKE Autopilot run of the release benchmark.

It runs in a Job on another node than smock (scripts/gke-bench.sh), and
sends smock's Service the steps of one profile of the plan the way
bench/bench.py does on one machine, with the same functions: one oha process
for each request of the mix (bench/requests.json) at its weight's share of
the step's rate and connections, at a fixed arrival rate, latency counted
from each request's due time. It prints one JSON line for each step to
stdout, in the layout of a case of bench/bench.py's summary.json, between a
line about the start and one when it is done; progress goes to stderr.

Environment:
  TARGET      smock's host name (its Service)
  PROFILE     the profile of the plan to run
  CASES       the cases to run, comma-separated (default: every case of the plan)
  PLAN        the plan (default: plan.json in the directory of bench.py)
  PLAIN_PORT, TLS_PORT, ADMIN_PORT
              smock's ports (default: 80, 443 and 9090, its Service's)
  OHA         oha (default: oha on PATH)
"""

import importlib.util
import json
import os
import resource
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

_spec = importlib.util.spec_from_file_location("gke", Path(__file__).resolve().parent / "gke.py")
gke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gke)
harness = gke.harness

# How long smock may take to become ready: at the start, and before each
# step, when it may be restarting.
READY_AT_START_S = 300
READY_BEFORE_STEP_S = 60


def log(message):
    print(f"generator: {message}", file=sys.stderr, flush=True)


def emit(line):
    print(json.dumps(line), flush=True)


def admin(target, port, path, timeout=5):
    """GETs a path of the Admin API: its status and body, or None and the
    error."""
    try:
        with urllib.request.urlopen(f"http://{target}:{port}{path}", timeout=timeout) as response:
            return response.status, response.read().decode()
    except Exception as error:  # noqa: BLE001 - any failure means not answered
        return None, str(error)


def wait_ready(target, port, seconds):
    """Whether smock became ready within `seconds`."""
    deadline = time.monotonic() + seconds
    while True:
        if admin(target, port, "/readyz", 2)[0] == 200:
            return True
        if time.monotonic() > deadline:
            return False
        time.sleep(1)


def cpu_children_s():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def run_step(spec, mix, oha, address, ports):
    """Sends one step's load and returns what it measured, as a case of
    summary.json has it; what only a run on one machine measures is None."""
    work = Path(tempfile.mkdtemp(prefix="step-"))
    run = SimpleNamespace(mix=mix, tmp=work)
    port = ports["tls" if spec["protocol"] == "https" else "plain"]
    weights = [request["weight"] for request in mix]
    total_s = spec["ramp_s"] + spec["duration_s"] + spec["tail_s"]
    cpu_before, started = cpu_children_s(), time.monotonic()
    load = []
    try:
        for (request, rate), connections in zip(harness.request_rates(run, spec),
                                                harness.split(spec["connections"], weights), strict=True):
            command = harness.oha_command(oha, spec, request, rate, connections, work / f"oha-{request['name']}.json",
                                          work / f"{request['name']}.sqlite", address, port)
            with (work / f"oha-{request['name']}.log").open("w") as stderr:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           stderr=stderr)
            load.append({"request": request, "rate": float(rate), "connections": connections, "process": process})
        for item in load:
            item["process"].wait(total_s + 300)
        wall_s, cpu_s = time.monotonic() - started, cpu_children_s() - cpu_before
        kinds, latencies, release_latencies, lags = harness.analyze_load(run, load, spec, work)
    finally:
        for item in load:
            if item["process"].poll() is None:
                item["process"].kill()
        shutil.rmtree(work, ignore_errors=True)
    return {
        **spec,
        **harness.load_result(spec, kinds, latencies, release_latencies, lags),
        "tcp_passive_opens": None,
        "idle_connections_open_at_end": None,
        "pinning": None,
        "smock_cpu": None,
        "memory": {"peak_bytes": None, "oom_kills": None},
        "rss_kib": {"first": None, "last": None, "max": None},
        "smock_ready": True,
        "smock_exit_status": None,
        "per_request": kinds,
        "generator": {"wall_s": round(wall_s, 3), "cpu_s": round(cpu_s, 3), "cpus": os.cpu_count(),
                      "affinity": len(os.sched_getaffinity(0))},
    }


def main():
    target, profile_name = os.environ["TARGET"], os.environ["PROFILE"]
    plan = gke.read_json(os.environ.get("PLAN") or harness.BENCH / "plan.json")
    [profile] = gke.plan_profiles(plan, [profile_name])
    specs = gke.steps(plan, profile, gke.plan_cases(plan, gke.comma_list(os.environ.get("CASES"))))
    ports = {"plain": int(os.environ.get("PLAIN_PORT", "80")), "tls": int(os.environ.get("TLS_PORT", "443"))}
    admin_port = int(os.environ.get("ADMIN_PORT", "9090"))
    oha = shutil.which(os.environ.get("OHA", "oha")) or os.environ.get("OHA", "oha")
    mix = harness.read_json(harness.BENCH / "requests.json")["requests"]
    # Every connection is a file descriptor.
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    address = socket.gethostbyname(target)
    log(f"{target} is {address}; {len(specs)} steps under {profile_name}")
    if not wait_ready(target, admin_port, READY_AT_START_S):
        emit({"kind": "error", "message": f"smock at {target} did not become ready in {READY_AT_START_S} s"})
        return 1
    status, body = admin(target, admin_port, "/v1/status")
    oha_version = subprocess.run([oha, "--version"], capture_output=True, text=True, check=True).stdout.strip()
    emit({"kind": "start", "profile": profile_name, "address": address, "oha": oha_version,
          "cpus": os.cpu_count(), "affinity": len(os.sched_getaffinity(0)), "nofile": hard,
          "status": json.loads(body) if status == 200 else None})
    emit({"kind": "metrics-before", "profile": profile_name, "text": admin(target, admin_port, "/metrics")[1]})
    for index, spec in enumerate(specs):
        if index:
            time.sleep(plan["cooldown_s"])
        log(f"{spec['id']}: {spec['rate']} requests/s for {spec['duration_s']} s")
        if wait_ready(target, admin_port, READY_BEFORE_STEP_S):
            result = run_step(spec, mix, oha, address, ports)
        else:
            result = harness.not_ready_result(SimpleNamespace(mix=mix), spec, None)
        emit({"kind": "step", "result": result})
        log(f"{spec['id']}: p99 {result['latency_ms']['p99']} ms, p99.9 {result['latency_ms']['p99_9']} ms, "
            f"{result['achieved_rate']} requests/s, {result['errors']} errors, "
            f"generator lag p99.9 {result['generator_lag_ms']['p99_9']} ms")
    emit({"kind": "metrics-after", "profile": profile_name, "text": admin(target, admin_port, "/metrics")[1]})
    emit({"kind": "done", "profile": profile_name})
    return 0


if __name__ == "__main__":
    sys.exit(main())
