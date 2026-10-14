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

It looks up smock's address once smock answers by name, and sends the load
there. Before the first step, it sends the first request of the mix once
to each traffic port, plain and TLS, through the Service, until each
answers or TRAFFIC_CHECK_S has passed (a traffic-check line). When one
never answers, it runs no step of the profile. When a step gets no
response at all, it checks the ports the same way again: an overloaded
smock may answer none of a step's measured requests and still be there,
and the profile goes on; when smock does not answer, it runs no further
step. A stopped line says why and which steps it did not run.

Environment:
  TARGET      smock's host name (its Service)
  PROFILE     the profile of the plan to run
  CASES       the cases to run, comma-separated (default: every case of the plan)
  PLAN        the plan (default: plan.json in the directory of bench.py)
  PLAIN_PORT, TLS_PORT, ADMIN_PORT
              smock's ports (default: 80, 443 and 9090, its Service's)
  OHA         oha (default: oha on PATH)
  TRAFFIC_CHECK_S
              how long the traffic ports may take to answer (default: 60)
"""

import concurrent.futures
import functools
import http.client
import importlib.util
import json
import os
import resource
import shutil
import socket
import ssl
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


class TlsConnection(http.client.HTTPSConnection):
    """An HTTPS connection to an address that names the server by the
    request's host, as oha does with --connect-to, and verifies nothing, as
    oha with --insecure."""

    def __init__(self, address, port, server_name, timeout):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        super().__init__(address, port, timeout=timeout, context=context)
        self.server_name = server_name

    def connect(self):
        http.client.HTTPConnection.connect(self)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.server_name)


def send_once(address, port, request, tls, timeout):
    """Sends a request of the mix once to smock at `address` and `port`, as
    oha sends it: its HTTP status. Raises OSError or HTTPException when it
    gets no response."""
    connection = (TlsConnection(address, port, request["host"], timeout) if tls
                  else http.client.HTTPConnection(address, port, timeout=timeout))
    body = request["body"]
    try:
        connection.request(request["method"], request["target"],
                           body=body.encode() if isinstance(body, str) else body,
                           headers={"Host": request["host"], **dict(request["headers"])})
        response = connection.getresponse()
        response.read()
        return response.status
    finally:
        connection.close()


def check_port(address, port, request, tls, seconds):
    """Whether smock answers `request` on one port: tried again until it
    gets a response, any HTTP status, or `seconds` have passed."""
    started = time.monotonic()
    deadline, attempts = started + seconds, 0
    while True:
        attempts += 1
        try:
            status = send_once(address, port, request, tls, max(0.1, min(5.0, deadline - time.monotonic())))
            return {"port": port, "answered": True, "status": status, "attempts": attempts,
                    "seconds": round(time.monotonic() - started, 3), "error": None}
        except (OSError, http.client.HTTPException) as failure:
            # A connection or a TLS handshake that timed out alike.
            error = "timed out" if isinstance(failure, TimeoutError) else str(failure) or type(failure).__name__
        if time.monotonic() >= deadline:
            return {"port": port, "answered": False, "status": None, "attempts": attempts,
                    "seconds": round(time.monotonic() - started, 3), "error": error}
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))


def resolve(target):
    """The address `target` resolves to now, or why it does not."""
    try:
        return socket.gethostbyname(target)
    except OSError as error:
        return f"no address ({error})"


def traffic_check(target, address, ports, request, seconds):
    """Whether both traffic ports, plain and TLS, answer `request` through
    the Service at `address`, each within `seconds`, checked at the same
    time. When one does not, it says what `target` resolves to then, which
    may no longer be `address`."""
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        checks = {name: pool.submit(check_port, address, ports[name], request, name == "tls", seconds)
                  for name in ("plain", "tls")}
        found = {name: check.result() for name, check in checks.items()}
    ok = all(port["answered"] for port in found.values())
    return {"ok": ok, "address": address, **({} if ok else {"resolves_now": resolve(target)}),
            "host": request["host"], "method": request["method"], "target": request["target"], "window_s": seconds,
            "ports": found}


def silent_ports_text(check):
    """Which traffic ports did not answer, and why, for people; and what
    smock's name resolves to when that is no longer the address checked."""
    names = {"plain": "plain", "tls": "TLS"}
    text = ", ".join(f"{names[name]} port {port['port']} ({port['error']})"
                     for name, port in check["ports"].items() if not port["answered"])
    now = check.get("resolves_now")
    if now and now != check["address"]:
        text += f"; the address checked was {check['address']}, and smock's name now resolves to {now}"
    return text


def stop_after(spec, result, later, check_again):
    """Whether a step stops the rest of its profile, `later`: when it got no
    response at all, and smock does not answer through its Service right
    after it either (`check_again`, a traffic check). An overloaded smock
    can answer none of a step's measured requests, busy with those of the
    ramp until the step ends, and still be there. Returns the stopped
    line's fields, or None, and the check made, or None."""
    reason = no_response_reason(result)
    if not reason or not later:
        return None, None
    check = check_again()
    if check["ok"]:
        return None, check
    return {"reason": f"{reason}, and smock did not answer through its Service in {check['window_s']:g} s after it: "
                      f"{silent_ports_text(check)}",
            "after": spec["id"], "steps": [step["id"] for step in later]}, check


def no_response_reason(result):
    """Why a step stops its profile when it got no response at all, or
    None: smock answered none of its requests, not even with another
    status."""
    requests = result["requests"]
    if requests["scheduled"] == 0 or requests["ok"] or requests["unexpected_status"]:
        return None
    if not result["smock_ready"]:
        return f"smock was not ready within {READY_BEFORE_STEP_S} s before {result['id']}"
    errors = sorted({error for kind in result["per_request"] for error in kind.get("oha_errors") or {}})
    return (f"{result['id']} got no response to any of its {requests['scheduled']:,} requests"
            + (f" (oha: {', '.join(errors)})" if errors else ""))


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
    log(f"{len(specs)} steps under {profile_name}; waiting for smock at {target}")
    if not wait_ready(target, admin_port, READY_AT_START_S):
        emit({"kind": "error", "message": f"smock at {target} did not become ready in {READY_AT_START_S} s"})
        return 1
    # Looked up once smock answers by name, not before: a Service just made
    # may not resolve at first, and under autopilot-min on 2026-10-14 the
    # name of a Service just made again resolved at first to the address of
    # the one before it, which the load went to and nothing answered.
    try:
        address = socket.gethostbyname(target)
    except OSError as error:
        emit({"kind": "error", "message": f"smock answered at {target}, whose address could not be looked up then: "
                                          f"{error}"})
        return 1
    log(f"{target} is {address}")
    status, body = admin(target, admin_port, "/v1/status")
    oha_version = subprocess.run([oha, "--version"], capture_output=True, text=True, check=True).stdout.strip()
    emit({"kind": "start", "profile": profile_name, "address": address, "oha": oha_version,
          "cpus": os.cpu_count(), "affinity": len(os.sched_getaffinity(0)), "nofile": hard,
          "status": json.loads(body) if status == 200 else None})
    check_s = float(os.environ.get("TRAFFIC_CHECK_S", gke.TRAFFIC_CHECK_S))
    # The traffic check, before the first step and after a step with no
    # response.
    check_again = functools.partial(traffic_check, target, address, ports, mix[0], check_s)
    check = check_again()
    emit({"kind": "traffic-check", "profile": profile_name, **check})
    stopped = None
    if not check["ok"]:
        stopped = {"reason": f"smock did not answer through its Service in {check_s:g} s: {silent_ports_text(check)}",
                   "after": None, "steps": [spec["id"] for spec in specs]}
    log(f"traffic check: {'both ports answered' if check['ok'] else stopped['reason']}")
    emit({"kind": "metrics-before", "profile": profile_name, "text": admin(target, admin_port, "/metrics")[1]})
    for index, spec in enumerate(specs):
        if stopped:
            break
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
        stopped, check = stop_after(spec, result, specs[index + 1:], check_again)
        if check:
            emit({"kind": "traffic-check", "profile": profile_name, "after": spec["id"], **check})
            log(f"{spec['id']} got no response; traffic check after it: "
                f"{'both ports answered, going on' if check['ok'] else silent_ports_text(check)}")
    if stopped:
        emit({"kind": "stopped", "profile": profile_name, **stopped})
        log(f"stopped: {stopped['reason']}; {len(stopped['steps'])} steps not run")
    emit({"kind": "metrics-after", "profile": profile_name, "text": admin(target, admin_port, "/metrics")[1]})
    emit({"kind": "done", "profile": profile_name})
    return 0


if __name__ == "__main__":
    sys.exit(main())
