"""Tests of scripts/gke-bench.sh, the GKE Autopilot run of the release
benchmark, against fake gcloud, kubectl and docker commands.

The fakes (FAKE below) record every call, keep which clusters and
repositories exist, and answer as the real commands do for what the script
asks. Nothing reaches a cloud. They need bash, python3 and setsid.

usage: python3 -m unittest discover -s bench -v
"""

import hashlib
import json
import os
import platform
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent
SCRIPT = ROOT / "scripts" / "gke-bench.sh"

# This machine's architecture, as the script names it, and the other one.
HOST_ARCH = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
OTHER_ARCH = {"amd64": "arm64", "arm64": "amd64"}[HOST_ARCH]

# The commit checked out, which a release binary built here names.
HEAD = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True,
                      check=True).stdout.strip()


def elf_executable(arch, text):
    """The smallest static Linux executable for `arch` that writes `text`
    to stdout and exits 0: an ELF header, one loadable segment, the code
    of write(1, text, length) and exit(0), and the text."""
    message = text.encode()
    base, headers = 0x400000, 64 + 56
    if arch == "amd64":
        machine = 62
        after_lea = (b"\xba" + struct.pack("<I", len(message)) + b"\x0f\x05"  # mov edx, length; syscall
                     + b"\xb8\x3c\x00\x00\x00" + b"\x31\xff" + b"\x0f\x05")  # mov eax, 60; xor edi, edi; syscall
        code = (b"\xb8\x01\x00\x00\x00" + b"\xbf\x01\x00\x00\x00"  # mov eax, 1; mov edi, 1
                + b"\x48\x8d\x35" + struct.pack("<i", len(after_lea)) + after_lea)  # lea rsi, [rip + to the text]
    else:
        machine = 183
        # mov x0, 1; adr x1, text; mov x2, length; mov x8, 64; svc 0;
        # mov x0, 0; mov x8, 93; svc 0. The text is 7 instructions after
        # the adr.
        words = [0xD2800020, 0x10000000 | (7 << 5) | 1, 0xD2800002 | (len(message) << 5), 0xD2800808,
                 0xD4000001, 0xD2800000, 0xD2800BA8, 0xD4000001]
        code = b"".join(struct.pack("<I", word) for word in words)
    size = headers + len(code) + len(message)
    header = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9) + struct.pack(
        "<HHIQQQIHHHHHH", 2, machine, 1, base + headers, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    segment = struct.pack("<IIQQQQQQ", 1, 5, 0, base, base, size, size, 0x1000)
    return header + segment + code + message


def smock_version(commit=HEAD):
    return f"smock 0.0.0-dev (commit {commit}, moonc v0.10.14+7d59c7ec9)\n"

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
          "kubeconfig_env": os.environ.get("KUBECONFIG"), "platform": options.get("platform")}
if tool == "kubectl" and "kubeconfig" in options:
    path = Path(options["kubeconfig"])
    record["kubeconfig_mode"] = oct(stat.S_IMODE(path.stat().st_mode)) if path.exists() else None
if tool == "docker" and "login" in words:
    record["stdin"] = sys.stdin.read()
if tool == "kubectl" and words[:1] in (["apply"], ["delete"]):
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
    """What the test configured for a call, by its name: time moves on by
    `advance_s` for the script (with the fake date), the call sleeps for
    `sleep` and fails with `status`."""
    value = config.get(name)
    if isinstance(value, dict):
        if "advance_s" in value:
            offset = state_dir / "time-offset"
            offset.write_text(str(float(offset.read_text() if offset.exists() else 0) + value["advance_s"]))
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
        # As the real gcloud, when it could not fetch the region's quotas:
        # a warning, and none.
        if "region_quota_warning" in config:
            answer(json.dumps({"name": "us-central1", "quotaStatusWarning": config["region_quota_warning"]}))
        # The region's quotas, each [limit, usage], as configured; one
        # configured as null is not listed.
        quotas = {"CPUS": [config.get("regional_cpus", 200.0), 0.0], "SSD_TOTAL_GB": [4096.0, 0.0],
                  "HDB_TOTAL_GB": [4096.0, 0.0], "IN_USE_ADDRESSES": [8.0, 0.0], **config.get("regional_quotas", {})}
        answer(json.dumps({"quotas": [{"metric": metric, "limit": quota[0], "usage": quota[1]}
                                      for metric, quota in quotas.items() if quota is not None]}))
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
    if words[:1] == ["build"]:
        # As a builder without emulation: an image of another architecture
        # than this machine's cannot RUN anything.
        machine = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, os.uname().machine)
        dockerfile = Path(options["file"]).read_text()
        runs = any(line.strip().upper().startswith("RUN") for line in dockerfile.splitlines())
        if runs and options.get("platform", f"linux/{machine}") != f"linux/{machine}":
            sys.stderr.write("exec /bin/sh: exec format error\n")
            answer("", 1)
    if words[:1] == ["push"]:
        answer(f"{words[1].rsplit(':', 1)[1]}: digest: sha256:{'ab' * 32} size: 1234\n")
    answer()

def objects():
    """The objects applied and not yet deleted, by kind/name, in order."""
    return state().get("objects", {})


def restarts(pod):
    return config.get("restarts", {}).get(pod, 0)


def pod_list():
    """The namespace's Pods, as kubectl get pods -o json lists them: smock's
    Pod as applied, and one Pod for each Job, from its template."""
    items = []
    for item in objects().values():
        if item["kind"] == "Pod":
            name = item["metadata"]["name"]
            items.append({**item, "spec": {**item["spec"], "nodeName": "node-a"}, "status": {
                "phase": "Running", "podIP": "10.20.0.7",
                "conditions": [{"type": "Ready", "status": "True"}],
                "containerStatuses": [{"name": "smock", "ready": True, "restartCount": restarts(name),
                                       "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}}
                                       if restarts(name) else {}}]}})
        elif item["kind"] == "Job":
            template = item["spec"]["template"]
            items.append({"apiVersion": "v1", "kind": "Pod",
                          "metadata": {"name": item["metadata"]["name"] + "-x7k2p", "namespace": "smock-bench",
                                       "labels": {**template["metadata"]["labels"],
                                                  "job-name": item["metadata"]["name"]}},
                          "spec": {**template["spec"], "nodeName": "node-b"},
                          "status": {"phase": config.get("job_pod_phase", "Succeeded")}})
    return {"apiVersion": "v1", "kind": "List", "items": items, "metadata": {"resourceVersion": ""}}


def services_and_endpoint_slices():
    """kubectl get service,endpointslices -o json: each Service, then an
    EndpointSlice for each with the Pods it selects."""
    services = [item for item in objects().values() if item["kind"] == "Service"]
    pods = [item for item in objects().values() if item["kind"] == "Pod"]
    items = []
    for number, service in enumerate(services):
        items.append({**service, "metadata": {**service["metadata"], "uid": f"5e1c-{number}",
                                              "resourceVersion": "1001", "creationTimestamp": "2026-10-14T09:00:00Z"},
                      "spec": {**service["spec"], "clusterIP": f"34.118.229.{102 + number}",
                               "clusterIPs": [f"34.118.229.{102 + number}"], "ipFamilies": ["IPv4"],
                               "ipFamilyPolicy": "SingleStack", "sessionAffinity": "None",
                               "internalTrafficPolicy": "Cluster",
                               "ports": [{**port, "protocol": "TCP"} for port in service["spec"]["ports"]]},
                      "status": {"loadBalancer": {}}})
    for service in services:
        name = service["metadata"]["name"]
        selected = [pod for pod in pods
                    if service["spec"]["selector"].items() <= pod["metadata"].get("labels", {}).items()]
        items.append({
            "apiVersion": "discovery.k8s.io/v1", "kind": "EndpointSlice", "addressType": "IPv4",
            "metadata": {"name": f"{name}-8xq2v", "namespace": "smock-bench", "generateName": f"{name}-",
                         "labels": {"kubernetes.io/service-name": name,
                                    "endpointslice.kubernetes.io/managed-by": "endpointslice-controller.k8s.io"},
                         "ownerReferences": [{"apiVersion": "v1", "kind": "Service", "name": name,
                                              "controller": True, "blockOwnerDeletion": True}]},
            "endpoints": [{"addresses": ["10.20.0.7"], "conditions": {"ready": True, "serving": True,
                                                                     "terminating": False},
                           "nodeName": "node-a", "zone": "us-central1-a",
                           "targetRef": {"kind": "Pod", "name": pod["metadata"]["name"],
                                         "namespace": "smock-bench"}} for pod in selected],
            "ports": [{"name": port["name"], "port": port["targetPort"], "protocol": "TCP"}
                      for port in service["spec"]["ports"]]})
    return {"apiVersion": "v1", "kind": "List", "items": items, "metadata": {"resourceVersion": ""}}


def node_list():
    """kubectl get nodes -o json: the nodes the Pods run on, of the
    architecture smock's Pod asked for."""
    pods = [item for item in objects().values() if item["kind"] == "Pod"]
    arch = next((pod["spec"]["nodeSelector"]["kubernetes.io/arch"] for pod in pods), "amd64")
    return {"items": [{
        "metadata": {"name": name, "labels": {"node.kubernetes.io/instance-type": "ek-standard-8",
                                              "kubernetes.io/arch": arch,
                                              "topology.kubernetes.io/zone": "us-central1-a"}},
        "status": {"capacity": {"cpu": "8"}, "allocatable": {"cpu": "7910m"},
                   "nodeInfo": {"kernelVersion": "6.12.105+", "kubeletVersion": "v1.35.8-gke.1225000",
                                "osImage": "Container-Optimized OS from Google"}}} for name in ("node-a", "node-b")]}


def logs(target, previous, container):
    """kubectl logs [--previous] [--container=<name>] job/<name> or
    pod/<name>: a container other than smock's is named <pod>/<container>
    in the configured logs."""
    kind, name = target.split("/", 1)
    known = config.get("logs", {})
    if kind == "pod" and f"Pod/{name}" not in objects():
        sys.stderr.write(f'Error from server (NotFound): pods "{name}" not found\n')
        answer("", 1)
    if kind == "pod" and container is None:
        spec = objects()[f"Pod/{name}"]["spec"]
        if spec.get("initContainers"):
            # As kubectl says, on stderr, for a Pod of more than one.
            names = [item["name"] for item in spec["containers"]] + \
                [f"{item['name']} (init)" for item in spec["initContainers"]]
            sys.stderr.write(f'Defaulted container "{names[0]}" out of: {", ".join(names)}\n')
    if container not in (None, "smock"):
        name += f"/{container}"
    if previous:
        if not restarts(name):
            sys.stderr.write(f'Error from server (BadRequest): previous terminated container "smock" in pod '
                             f'"{name}" not found\n')
            answer("", 1)
        name += "/previous"
    answer(Path(known[name]).read_text() if name in known else "")


if tool == "kubectl":
    if words[:1] == ["version"] and config.get("kubectl_broken"):
        sys.stderr.write("mise ERROR No version is set for shim: kubectl\n")
        answer("", 1)
    if words[:1] == ["apply"]:
        if config.get("apply_fails_on") and config["apply_fails_on"] in options.get("filename", ""):
            answer("", 1)
        items = record["document"].get("items", [record["document"]])
        state(lambda value: value.setdefault("objects", {}).update(
            {f"{item['kind']}/{item['metadata']['name']}": item for item in items}))
        answer("".join(f"{item['kind'].lower()}/{item['metadata']['name']} created\n" for item in items))
    if words[:1] == ["delete"]:
        items = record["document"].get("items", [record["document"]])
        if config.get("delete_fails_on") and config["delete_fails_on"] in options["filename"]:
            # As kubectl does: each object is marked deleted, and is still
            # there when the wait gives up, which names the last one.
            time.sleep(0.2)
            sys.stdout.write("".join(f'{item["kind"].lower()} "{item["metadata"]["name"]}" deleted\n'
                                     for item in items))
            sys.stderr.write(f"error: timed out waiting for the condition on {items[-1]['kind'].lower()}s/"
                             f"{items[-1]['metadata']['name']}\n")
            answer("", 1)
        state(lambda value: [value.setdefault("objects", {}).pop(f"{item['kind']}/{item['metadata']['name']}", None)
                             for item in items])
        answer("".join(f'{item["kind"].lower()} "{item["metadata"]["name"]}" deleted\n' for item in items))
    if words[:1] == ["wait"]:
        if words[1] in config.get("never_ready", []):
            sys.stderr.write(f"error: timed out waiting for the condition on pods/{words[1].split('/', 1)[1]}\n")
            answer("", 1)
        rule("smock_ready")
        answer(f"{words[1]} condition met\n")
    if words[:2] == ["get", "events"]:
        answer(config.get("events", ""))
    if words[:2] == ["get", "pods"] and "selector" in options:
        answer(config.get("job_pod_phase", "Succeeded"))
    if words[:2] == ["get", "job"]:
        answer(config.get("job_state", "Complete=True "))
    if words[:1] == ["logs"]:
        logs(words[1], "--previous" in argv, options.get("container"))
    if words[:2] == ["get", "pods"]:
        answer(json.dumps(pod_list()))
    if words[:2] == ["get", "service,endpointslices"]:
        answer(json.dumps(services_and_endpoint_slices()))
    if words[:2] == ["get", "nodes"]:
        answer(json.dumps(node_list()))
    answer()
'''

# A fake date: time passes FAKE_TIME_SCALE times as fast for the script as
# it does, from the first time it is asked, and jumps forward by what the
# fakes wrote to time-offset.
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
offset_file = Path(os.environ["FAKE_STATE"]) / "time-offset"
offset = float(offset_file.read_text()) if offset_file.exists() else 0
now = base + (time.time() - base) * float(os.environ.get("FAKE_TIME_SCALE", "1")) + offset
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


# A plan of two profiles, one after the other.
TWO_PROFILES_PLAN = {
    **SMALL_PLAN,
    "profiles": [*SMALL_PLAN["profiles"], {"name": "large", "cpu_limit": "1", "memory_limit": "1Gi"}],
    "cases": [{**SMALL_PLAN["cases"][0], "rates": {"small": [500, 1000], "large": [1000, 2000]}}],
}

# The reason the load generator gives when smock's TLS port never answered.
SILENT_TLS = "smock did not answer through its Service in 60 s: TLS port 443 (timed out)"


def limit_cpus(cpu_limit):
    """The CPUs a Kubernetes-style CPU limit gives: 250m is 0.25."""
    return int(cpu_limit[:-1]) / 1000 if cpu_limit.endswith("m") else float(cpu_limit)


def generator_log(profile="small", cpu_limit="250m", memory_limit="512Mi", rates=(500, 1000), tls_answers=True):
    """What the load generator writes for a profile of the small plans: when
    smock's TLS port does not answer, it runs no step."""
    lines = [{"kind": "start", "profile": profile, "oha": "oha 1.16.0",
              "status": {"version": "0.2.0", "commit": "a21fe97d59c6", "toolchain": "moonc", "digest": "48f7ce9715f0",
                         "mocks": []}},
             {"kind": "idle-rss", "profile": profile, "idle": {
                 "profile": profile, "cpu_limit": cpu_limit, "memory_limit": memory_limit, "settle_s": 5,
                 "smock_ready": True, "digest": "48f7ce9715f0", "rss_kib": 16384,
                 "memory": {"peak_bytes": 15 << 20, "oom_kills": None}}},
             {"kind": "traffic-check", "profile": profile, "ok": tls_answers, "host": "catalog.bench.internal",
              "method": "GET", "target": "/catalog/items/SKU-00317", "window_s": 60,
              "ports": {"plain": {"port": 80, "answered": True, "status": 200, "attempts": 1, "seconds": 0.004,
                                  "error": None},
                        "tls": {"port": 443, "answered": tls_answers, "status": 200 if tls_answers else None,
                                "attempts": 1 if tls_answers else 12, "seconds": 0.011 if tls_answers else 60.2,
                                "error": None if tls_answers else "timed out"}}}]
    for rate in rates if tls_answers else ():
        lines.append({"kind": "step", "result": {
            "id": f"http-keep-alive@{profile}@{rate}", "case": "http-keep-alive", "profile": profile,
            "cpu_limit": cpu_limit, "memory_limit": memory_limit, "rate": rate, "ramp_s": 2, "duration_s": 20,
            "tail_s": 3, "connections": 64, "protocol": "http", "connection": "keep-alive", "idle_connections": 0,
            "achieved_rate": rate, "errors": 0,
            "latency_ms": {"p50": 1.2, "p90": 1.6, "p99": 2.0, "p99_9": 2.5, "max": 4.0},
            "latency_from_release_ms": {"p50": 0.3, "p90": 0.5, "p99": 1.0, "p99_9": 1.5, "max": 3.0},
            "generator_lag_ms": {"p50": 1.0, "p99": 1.9, "p99_9": 2.0, "max": 3.1}, "load_generator_late": False,
            "requests": {"scheduled": rate * 20, "ok": rate * 20, "unexpected_status": 0, "no_response": 0},
            "smock_cpu": {"usage_s": round(rate * 25 * 30e-6, 3), "periods": 250, "throttled_periods": 0,
                          "throttled_s": 0.0, "source": "cgroup", "process_s": round(rate * 25 * 30e-6, 2),
                          "wall_s": 25.004, "requests": rate * 25, "us_per_request": 30.0,
                          "utilization": round(rate * 25 * 30e-6 / (25.004 * limit_cpus(cpu_limit)), 4)},
            "memory": {"peak_bytes": 20 << 20, "oom_kills": None},
            "rss_kib": {"first": 17000, "last": 18000, "max": 18000}, "smock_ready": True}})
    if not tls_answers:
        lines.append({"kind": "stopped", "profile": profile, "reason": SILENT_TLS, "after": None,
                      "steps": [f"http-keep-alive@{profile}@{rate}" for rate in rates]})
    lines.append({"kind": "done", "profile": profile})
    return "".join(json.dumps(line) + "\n" for line in lines)


# What smock's init container prints of the CPU of its node, as gke.py
# node-cpu keeps it.
NODE_CPU = {"model_name": "AMD EPYC 7B13", "vendor_id": "AuthenticAMD", "cpu_family": "25", "model": "1",
            "stepping": "0", "microcode": "0xffffffff",
            "flags": {"aes": True, "avx2": True, "sha_ni": True, "vaes": True},
            "vulnerabilities": {"spectre_v2": "Mitigation: Retpolines; IBPB: conditional; STIBP: always-on"}}

# What smock logs, as JSON lines.
SMOCK_LOG = ('{"time":"2026-10-14T09:00:01.000Z","level":"info","msg":"listening","listener":"plain",'
             '"address":"0.0.0.0:8080"}\n')

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
        (self.tmp / "smock-small.log").write_text(SMOCK_LOG)
        self.configure()
        # Binaries of this machine's architecture: smock says the commit
        # checked out.
        self.smock = self.smock_for(HOST_ARCH)
        self.oha = self.binary("oha", HOST_ARCH, "oha 1.16.0\n")
        self.out = self.tmp / "out"
        self.tmpdir = self.tmp / "tmp"
        self.tmpdir.mkdir()
        self.addCleanup(self.stop_watchdog)

    def binary(self, name, arch, text, data=b""):
        """An executable for `arch` that prints `text`, followed by `data`,
        in a directory of its own."""
        directory = Path(tempfile.mkdtemp(prefix=f"{name}-{arch}-", dir=self.tmp))
        path = directory / name
        path.write_bytes(elf_executable(arch, text) + data)
        path.chmod(0o755)
        return path

    def smock_for(self, arch, commit=HEAD):
        """A release binary of smock for `arch`, built from `commit`: it says
        the commit when run, and holds it in its build information as a
        native MoonBit build does, in UTF-16."""
        return self.binary("smock", arch, smock_version(commit), commit.encode("utf-16-le"))

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
        config.setdefault("logs", {"generator-small": str(self.tmp / "generator-small.log"),
                                   "smock-small": str(self.tmp / "smock-small.log")})
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

    def for_arch(self, arch):
        """The options of a run for `arch`, with binaries for it."""
        return ["--arch", arch, "--smock", self.smock_for(arch), "--oha", self.binary("oha", arch, "oha 1.16.0\n")]

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
        """The fake cloud's clusters and repositories."""
        path = self.state / "state.json"
        value = json.loads(path.read_text()) if path.exists() else {}
        return {"clusters": value.get("clusters", {}), "repositories": value.get("repositories", [])}

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
        self.assertIn(f"Cost estimate for {HOST_ARCH}", output)
        self.assertIn("(us-central1, on-demand prices", output)
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
        self.assertIn("set GKE_BENCH_NEEDED_CPUS lower", output)
        self.assertEqual(self.changing_calls(), [])
        # The region's CPUS counts every node of an amd64 run, but only
        # Autopilot's two x86 nodes of an arm64 one.
        self.configure(regional_cpus=16.0)
        status, output = self.run_script("--yes", *self.for_arch("amd64"))
        self.assertEqual(status, 1, output)
        self.assertIn("CPUS in us-central1: 16 of 16 vCPUs free, the run needs 32 for its 4 nodes", output)
        self.assertEqual(self.changing_calls(), [])
        status, output = self.run_script(*self.for_arch("arm64"))
        self.assertEqual(status, 0, output)
        self.assertIn("CPUS in us-central1: 16 of 16 vCPUs free, the run needs 16 for Autopilot's 2 x86 nodes",
                      output)
        self.configure(regional_cpus=8.0)
        status, output = self.run_script("--yes", *self.for_arch("arm64"))
        self.assertEqual(status, 1, output)
        self.assertIn("CPUS in us-central1: 8 of 8 vCPUs free, the run needs 16 for Autopilot's 2 x86 nodes", output)
        self.assertEqual(self.changing_calls(), [])

    def test_a_short_regional_quota_the_nodes_draw_on_stops_it_and_is_named(self):
        # Two of the 8 in-use addresses are free, and each of the 4 nodes
        # takes one.
        self.configure(regional_quotas={"IN_USE_ADDRESSES": [8.0, 6.0]})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("the run cannot start", output)
        self.assertIn("IN_USE_ADDRESSES in us-central1: 2 of 8 addresses free, the run needs 4", output)
        self.assertEqual(self.changing_calls(), [])
        # The nodes' boot disks, of 100 GB each: on amd64, all four in
        # SSD_TOTAL_GB.
        self.configure(regional_quotas={"SSD_TOTAL_GB": [500.0, 250.0]})
        status, output = self.run_script("--yes", *self.for_arch("amd64"))
        self.assertEqual(status, 1, output)
        self.assertIn("SSD_TOTAL_GB in us-central1: 250 of 500 GB free, the run needs 400", output)
        self.assertEqual(self.changing_calls(), [])

    def test_an_arm64_runs_boot_disks_are_checked_in_the_quota_of_each_nodes_architecture(self):
        # Autopilot's own two nodes are x86, with pd-balanced boot disks in
        # SSD_TOTAL_GB; smock's and the load generator's are Arm nodes, with
        # hyperdisk-balanced ones in HDB_TOTAL_GB.
        for metric, owner in (("SSD_TOTAL_GB", "Autopilot's 2 x86 nodes"), ("HDB_TOTAL_GB", "its 2 Arm nodes")):
            self.configure(regional_quotas={metric: [500.0, 350.0]})
            status, output = self.run_script("--yes", *self.for_arch("arm64"))
            self.assertEqual(status, 1, output)
            self.assertIn(f"{metric} in us-central1: 150 of 500 GB free, the run needs 200 for the boot disks of "
                          f"{owner}, 100 GB each", output)
            self.assertEqual(self.changing_calls(), [])
        self.configure(regional_quotas={"SSD_TOTAL_GB": [200.0, 0.0], "HDB_TOTAL_GB": [200.0, 0.0]})
        status, output = self.run_script(*self.for_arch("arm64"))
        self.assertEqual(status, 0, output)

    def test_quotas_that_cannot_be_read_stop_it_with_their_own_reason(self):
        # gcloud could not fetch the region's quotas: one problem, which
        # more quota would not solve.
        self.configure(region_quota_warning={"code": "QUOTA_STATUS_UNAVAILABLE",
                                             "message": "Quota information is temporarily unavailable."})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("cannot read the quotas of us-central1 (Quota information is temporarily unavailable.): try "
                      "again", output)
        self.assertNotIn("in us-central1:", output)
        self.assertNotIn("GKE_BENCH_NEEDED_CPUS lower", output)
        self.assertEqual(self.changing_calls(), [])
        # A quota the region does not list cannot be checked.
        self.configure(regional_quotas={"IN_USE_ADDRESSES": None})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("IN_USE_ADDRESSES in us-central1: not among the quotas gcloud lists, so the run cannot check "
                      "it", output)
        self.assertNotIn("no such quota", output)
        self.assertNotIn("GKE_BENCH_NEEDED_CPUS lower", output)
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
                         f"--platform=linux/{HOST_ARCH}", "(us-central1, on-demand prices"):
            self.assertIn(expected, output)
        # The project shows as the variable that holds it.
        self.assertNotIn(PROJECT, output)
        self.assertIn('--project="$GKE_BENCH_PROJECT"', output)

    def test_it_names_each_regional_quota_the_nodes_draw_on_with_what_is_free_and_what_the_run_needs(self):
        # Four nodes by default, each with 8 vCPUs, a boot disk of 100 GB
        # and an external IP address; three for 24 vCPUs. Autopilot's first
        # node and its system node are x86 on either architecture; smock's
        # and the load generator's are of the run's.
        for arch, cpus, nodes in (("amd64", None, 4), ("amd64", "24", 3)):
            status, output = self.run_script("--dry-run", *self.for_arch(arch), GKE_BENCH_NEEDED_CPUS=cpus)
            self.assertEqual(status, 0, output)
            self.assertIn(f"CPUS_ALL_REGIONS: 32 of 32 vCPUs free, the run needs {nodes * 8} for its {nodes} nodes",
                          output)
            self.assertIn(f"CPUS in us-central1: 200 of 200 vCPUs free, the run needs {nodes * 8} for its {nodes} "
                          "nodes", output)
            self.assertIn(f"SSD_TOTAL_GB in us-central1: 4096 of 4096 GB free, the run needs {nodes * 100} for the "
                          f"boot disks of its {nodes} nodes, 100 GB each", output)
            self.assertIn(f"IN_USE_ADDRESSES in us-central1: 8 of 8 addresses free, the run needs {nodes} for the "
                          f"external IP addresses of its {nodes} nodes", output)
            self.assertNotIn("HDB_TOTAL_GB", output)
            self.assertNotIn("Arm nodes", output)
        for cpus, nodes, arm in ((None, 4, "2 Arm nodes"), ("24", 3, "1 Arm node")):
            status, output = self.run_script("--dry-run", *self.for_arch("arm64"), GKE_BENCH_NEEDED_CPUS=cpus)
            self.assertEqual(status, 0, output)
            self.assertIn(f"CPUS_ALL_REGIONS: 32 of 32 vCPUs free, the run needs {nodes * 8} for its {nodes} nodes",
                          output)
            self.assertIn("CPUS in us-central1: 200 of 200 vCPUs free, the run needs 16 for Autopilot's 2 x86 nodes",
                          output)
            self.assertIn("SSD_TOTAL_GB in us-central1: 4096 of 4096 GB free, the run needs 200 for the boot disks of "
                          "Autopilot's 2 x86 nodes, 100 GB each", output)
            self.assertIn(f"HDB_TOTAL_GB in us-central1: 4096 of 4096 GB free, the run needs {(nodes - 2) * 100} for "
                          f"the boot disks of its {arm}, 100 GB each", output)
            self.assertIn(f"IN_USE_ADDRESSES in us-central1: 8 of 8 addresses free, the run needs {nodes} for the "
                          f"external IP addresses of its {nodes} nodes", output)
            # Not the CPU quota of the Arm nodes' machine family, which
            # gcloud does not list.
            self.assertIn(f"not checked: the CPU quota of the Arm nodes' machine family, of which the run needs "
                          f"{(nodes - 2) * 8} vCPUs for its {arm}", output)
            self.assertIn("console's Quotas page", output)
            # Each quota once.
            for metric in ("CPUS_ALL_REGIONS:", "CPUS in", "SSD_TOTAL_GB in", "HDB_TOTAL_GB in", "IN_USE_ADDRESSES in"):
                self.assertEqual(output.count(metric), 1, metric)


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
        self.assertEqual(self.made(["wait"])[0]["words"][1:], ["pod/smock-small"])

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


class Diagnostics(Script):
    """Before smock's Pod is deleted, the run keeps its log and its Service
    with the Service's EndpointSlices, masked."""

    def test_smocks_log_and_its_service_with_its_endpoint_slices_are_kept_before_it_is_deleted(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        raw = self.out / "raw" / "small"
        self.assertEqual((raw / "smock.log").read_text(), SMOCK_LOG)
        kept = json.loads((raw / "service.json").read_text())
        [service] = [item for item in kept["items"] if item["kind"] == "Service"]
        [endpoints] = [item for item in kept["items"] if item["kind"] == "EndpointSlice"]
        self.assertEqual(service["metadata"]["name"], "smock-small")
        self.assertEqual(endpoints["metadata"]["labels"]["kubernetes.io/service-name"], "smock-small")
        self.assertEqual([endpoint["targetRef"]["name"] for endpoint in endpoints["endpoints"]], ["smock-small"])
        # Read while smock's Pod and Service were there, before they were
        # deleted; smock never restarted, so it had no previous container.
        kubectl = self.calls("kubectl")
        deleted = next(index for index, call in enumerate(kubectl)
                       if call["words"][:1] == ["delete"] and any(item["kind"] == "Pod"
                                                                   for item in call["document"].get("items", [])))
        for read in (["logs", "pod/smock-small"], ["get", "service,endpointslices"]):
            self.assertLess([call["words"] for call in kubectl].index(read), deleted, read)
        self.assertEqual([call for call in self.calls("kubectl") if "--previous" in call["argv"]], [])

    def test_a_smock_that_restarted_keeps_its_previous_containers_log_too_masked(self):
        # What smock logged names whatever reached it; here the project and
        # the account.
        (self.tmp / "smock-previous.log").write_text(
            f'{{"level":"info","msg":"request","host":"{PROJECT}.example","user":"{ACCOUNT}"}}\n')
        self.configure(restarts={"smock-small": 1},
                       logs={"generator-small": str(self.tmp / "generator-small.log"),
                             "smock-small": str(self.tmp / "smock-small.log"),
                             "smock-small/previous": str(self.tmp / "smock-previous.log")})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        log = (self.out / "raw" / "small" / "smock.log").read_text()
        self.assertNotIn(PROJECT, log)
        self.assertNotIn(ACCOUNT, log)
        self.assertIn('"host":"$GKE_BENCH_PROJECT.example","user":"<account>"', log)
        # The previous container's first, then the one at the end.
        self.assertLess(log.index("$GKE_BENCH_PROJECT"), log.index('"msg":"listening"'))
        self.assertTrue(self.made(["logs", "pod/smock-small"]))
        self.assertTrue([call for call in self.calls("kubectl") if "--previous" in call["argv"]])

    def test_a_smock_that_never_became_ready_keeps_its_logs_its_pod_and_its_service(self):
        # It restarted, as when the kernel kills it for memory as it
        # starts: its Pod, kept first, says so, and the log of its
        # container before the last restart is kept before the last one's.
        (self.tmp / "smock-previous.log").write_text('{"level":"error","msg":"out of memory"}\n')
        self.configure(smock_ready={"status": 1, "stderr": "error: timed out waiting for the condition on "
                                                           "pods/smock-small\n"},
                       restarts={"smock-small": 3},
                       logs={"generator-small": str(self.tmp / "generator-small.log"),
                             "smock-small": str(self.tmp / "smock-small.log"),
                             "smock-small/previous": str(self.tmp / "smock-previous.log")})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("smock did not become ready under small", output)
        raw = self.out / "raw" / "small"
        self.assertEqual([(pod["name"], pod["node"], pod["restarts"])
                          for pod in json.loads((raw / "pods.json").read_text())["smock"]],
                         [("smock-small", "node-a", 3)])
        log = (raw / "smock.log").read_text()
        self.assertIn("(restarts: 3)", log)
        self.assertLess(log.index("out of memory"), log.index('"msg":"listening"'))
        self.assertTrue(log.endswith(SMOCK_LOG), log)
        kept = json.loads((raw / "service.json").read_text())
        self.assertEqual([item["metadata"]["name"] for item in kept["items"] if item["kind"] == "Service"],
                         ["smock-small"])
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})

    def test_the_cpu_of_smocks_node_that_its_init_container_printed_is_kept_and_summarized(self):
        line = {"kind": "node-cpu", "cpu": NODE_CPU}
        (self.tmp / "smock-node-cpu.log").write_text(json.dumps(line) + "\n")
        self.configure(logs={"generator-small": str(self.tmp / "generator-small.log"),
                             "smock-small": str(self.tmp / "smock-small.log"),
                             "smock-small/node-cpu": str(self.tmp / "smock-node-cpu.log")})
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        raw = self.out / "raw" / "small"
        self.assertEqual([json.loads(text) for text in (raw / "smock-node-cpu.log").read_text().splitlines()], [line])
        # smock's log is its own container's, with no word of the other.
        self.assertEqual((raw / "smock.log").read_text(), SMOCK_LOG)
        conditions = json.loads((self.out / "conditions.json").read_text())
        nodes = conditions["gke"]["profiles"]["small"]["nodes"]
        self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (NODE_CPU, None))
        self.assertEqual(conditions["machine"]["cpu_model"], "GKE Autopilot ek-standard-8")
        # Read while smock's Pod was there.
        kubectl = self.calls("kubectl")
        deleted = next(index for index, call in enumerate(kubectl)
                       if call["words"][:1] == ["delete"] and any(item["kind"] == "Pod"
                                                                   for item in call["document"].get("items", [])))
        [read] = [index for index, call in enumerate(kubectl) if "--container=node-cpu" in call["argv"]]
        self.assertLess(read, deleted)

    def test_a_dry_run_says_what_it_would_keep(self):
        status, output = self.run_script("--dry-run")
        self.assertEqual(status, 0, output)
        self.assertIn("smock.log", output)
        self.assertIn("smock-node-cpu.log", output)
        self.assertIn("service.json", output)


class Profiles(Script):
    """Each profile has its own smock, by name, which is gone before the next
    profile's starts; a profile that the load generator stopped early is
    reported, and the next one still runs."""

    def setUp(self):
        super().setUp()
        self.plan.write_text(json.dumps(TWO_PROFILES_PLAN))
        (self.tmp / "generator-large.log").write_text(generator_log("large", "1", "1Gi", (1000, 2000)))

    def configure(self, **config):
        config.setdefault("logs", {"generator-small": str(self.tmp / "generator-small.log"),
                                   "generator-large": str(self.tmp / "generator-large.log"),
                                   "smock-small": str(self.tmp / "smock-small.log")})
        super().configure(**config)

    def smock_calls(self):
        """The applies and deletes of smock's Pod and Service, in order:
        (verb, the Pod's name, the call)."""
        calls = []
        for call in self.calls("kubectl"):
            items = call.get("document", {}).get("items", [])
            if call["words"][:1] in (["apply"], ["delete"]) and any(item["kind"] == "Pod" for item in items):
                [pod] = [item for item in items if item["kind"] == "Pod"]
                calls.append((call["words"][0], pod["metadata"]["name"], call))
        return calls

    def test_each_profile_has_its_own_smock_and_the_next_starts_once_the_previous_is_gone(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        calls = self.smock_calls()
        self.assertEqual([(verb, name) for verb, name, _ in calls],
                         [("apply", "smock-small"), ("delete", "smock-small"), ("apply", "smock-large"),
                          ("delete", "smock-large")])
        # Deleting waits until the Pod and the Service are gone, for a time.
        for verb, _, call in calls:
            if verb == "delete":
                self.assertIn("--wait=true", call["argv"])
                self.assertTrue(any(arg.startswith("--timeout=") for arg in call["argv"]), call["argv"])
        # Each load generator targets its profile's Service.
        targets = {}
        for call in self.made(["apply"]):
            if call["document"]["kind"] == "Job":
                env = call["document"]["spec"]["template"]["spec"]["containers"][0]["env"]
                targets[call["document"]["metadata"]["name"]] = next(v["value"] for v in env if v["name"] == "TARGET")
        self.assertEqual(targets, {"generator-small": "smock-small.smock-bench.svc.cluster.local",
                                   "generator-large": "smock-large.smock-bench.svc.cluster.local"})
        self.assertEqual([wait["words"][1] for wait in self.made(["wait"])], ["pod/smock-small", "pod/smock-large"])
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertTrue(summary["complete"])
        self.assertEqual({name: profile["generator_cpu_request"]
                          for name, profile in summary["gke"]["profiles"].items()},
                         {"small": {"amd64": "6", "arm64": "4"}[HOST_ARCH],
                          "large": {"amd64": "6", "arm64": "4"}[HOST_ARCH]})

    def stopped(self):
        """Why the run stopped early, as summary.json and summary.md say."""
        summary = json.loads((self.out / "summary.json").read_text())
        markdown = (self.out / "summary.md").read_text()
        return summary["gke"]["stopped"], next((line for line in markdown.splitlines()
                                                if line.startswith("**Stopped early:**")), None)

    def test_a_smock_not_deleted_in_time_stops_the_later_profiles_and_the_run_still_cleans_up(self):
        self.configure(delete_fails_on="manifests/small/smock.json")
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("timed out waiting for the condition", output)
        self.assertEqual([(verb, name) for verb, name, _ in self.smock_calls()],
                         [("apply", "smock-small"), ("delete", "smock-small")])
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual({case["profile"] for case in summary["cases"]}, {"small"})
        # summary.md says why large was not run.
        reason = "smock's Pod and Service were not deleted in 5 minutes, so no later profile ran"
        self.assertEqual(self.stopped(), (
            {"reason": reason, "profile": "small", "after": "http-keep-alive@small@1000"},
            f"**Stopped early:** the run stopped under profile small, after its step http-keep-alive@small@1000: "
            f"{reason}. Nothing after that was measured."))
        self.assertEqual(self.state_now()["clusters"], {})
        self.assertIn("nothing is left", output)

    def test_a_load_generator_not_deleted_in_time_stops_the_later_profiles_too(self):
        # Its Pod could hold the node, or the quota, the next one needs.
        self.configure(delete_fails_on="manifests/small/generator.json")
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("not deleted in 5 minutes under small: the load generator's Job; no later profile runs", output)
        self.assertEqual([(verb, name) for verb, name, _ in self.smock_calls()],
                         [("apply", "smock-small"), ("delete", "smock-small")])
        self.assertFalse(json.loads((self.out / "summary.json").read_text())["complete"])
        self.assertEqual(self.stopped()[0]["reason"],
                         "the load generator's Job was not deleted in 5 minutes, so no later profile ran")
        self.assertIn("nothing is left", output)

    def test_a_profile_that_does_not_fit_in_the_time_limit_is_skipped_and_summary_md_says_so(self):
        # The plan fits in 35 minutes as estimated, but 1,000 s pass while
        # smock becomes ready under small: large, with its Job's 507 s and
        # 600 s for smock's start and the deletion, no longer fits.
        self.fake_time(1)
        self.configure(smock_ready={"advance_s": 1000})
        status, output = self.run_script("--yes", "--time-limit", "35m")
        self.assertEqual(status, 1, output)
        self.assertIn("profile large and those after it do not fit in the time limit; skipping them", output)
        self.assertEqual([(verb, name) for verb, name, _ in self.smock_calls()],
                         [("apply", "smock-small"), ("delete", "smock-small")])
        reason = "profile large and those after it did not fit in the time limit of 35 minutes"
        self.assertEqual(self.stopped(), (
            {"reason": reason, "profile": "large", "after": None},
            f"**Stopped early:** the run stopped under profile large, before its first step: {reason}. Nothing "
            "after that was measured."))
        self.assertIn("not every step was measured under: large (summary.md says why)", output)
        self.assertIn("nothing is left", output)

    def test_a_log_that_lost_steps_fails_the_run_although_every_job_completed(self):
        # The Job completed, and its log has the step at 500 requests/s
        # only: no stopped line says why the other is missing.
        (self.tmp / "generator-small.log").write_text(generator_log(rates=(500,)).replace(
            '{"kind": "done", "profile": "small"}\n', ""))
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertNotIn("ended early", output)
        self.assertIn("not every step was measured under: small (summary.md says why)", output)
        self.assertFalse(json.loads((self.out / "summary.json").read_text())["complete"])
        self.assertIn("nothing is left", output)

    def test_a_profile_the_load_generator_stopped_early_is_reported_and_the_next_one_runs(self):
        (self.tmp / "generator-small.log").write_text(generator_log(tls_answers=False))
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn(f"profile small ended early: {SILENT_TLS}; 2 steps not measured", output)
        self.assertEqual([(verb, name) for verb, name, _ in self.smock_calls()],
                         [("apply", "smock-small"), ("delete", "smock-small"), ("apply", "smock-large"),
                          ("delete", "smock-large")])
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@large@1000", "http-keep-alive@large@2000"])
        self.assertEqual(summary["gke"]["profiles"]["small"]["ended_early"]["reason"], SILENT_TLS)
        self.assertIsNone(summary["gke"]["profiles"]["large"]["ended_early"])
        self.assertFalse(summary["gke"]["profiles"]["small"]["traffic_check"]["ok"])
        # smock's log and Service under the profile are kept all the same.
        self.assertTrue((self.out / "raw" / "small" / "smock.log").exists())
        self.assertTrue((self.out / "raw" / "small" / "service.json").exists())
        self.assertIn("nothing is left", output)


class StoppedEarly(Script):
    """A run that stops after it has measured steps still writes its summary
    from them, and says where it stopped and why; and it keeps the nodes of
    the profile it stopped under, with the CPU of smock's."""

    def setUp(self):
        super().setUp()
        self.plan.write_text(json.dumps(TWO_PROFILES_PLAN))
        (self.tmp / "generator-large.log").write_text(generator_log("large", "1", "1Gi", (1000, 2000)))
        (self.tmp / "smock-node-cpu.log").write_text(json.dumps({"kind": "node-cpu", "cpu": NODE_CPU}) + "\n")

    def configure(self, **config):
        config.setdefault("logs", {"generator-small": str(self.tmp / "generator-small.log"),
                                   "generator-large": str(self.tmp / "generator-large.log"),
                                   "smock-small": str(self.tmp / "smock-small.log"),
                                   "smock-small/node-cpu": str(self.tmp / "smock-node-cpu.log"),
                                   "smock-large/node-cpu": str(self.tmp / "smock-node-cpu.log")})
        super().configure(**config)

    def written(self):
        """summary.json, conditions.json and summary.md, as the run left
        them."""
        return (json.loads((self.out / "summary.json").read_text()),
                json.loads((self.out / "conditions.json").read_text()), (self.out / "summary.md").read_text())

    def test_a_run_that_dies_under_a_later_profile_summarizes_the_steps_it_measured_and_says_where_it_stopped(self):
        # small measures both of its steps; then smock never becomes ready
        # under large.
        self.configure(never_ready=["pod/smock-large"])
        status, output = self.run_script("--yes")
        self.assertEqual(status, 1, output)
        self.assertIn("smock did not become ready under large", output)
        summary, conditions, markdown = self.written()
        self.assertFalse(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@small@500", "http-keep-alive@small@1000"])
        self.assertEqual(conditions["gke"]["arch"], HOST_ARCH)
        self.assertIn("**Stopped early:** the run stopped under profile large, before its first step: smock did not "
                      "become ready under large.", markdown)
        # smock's node under large, with its CPU, which its init container
        # printed before smock started.
        self.assertEqual(conditions["gke"]["profiles"]["large"]["nodes"]["node-a"]["cpu"], NODE_CPU)
        self.assertEqual(conditions["gke"]["profiles"]["large"]["smock"][0]["node"], "node-a")
        self.assertIn("| large | ek-standard-8 (", markdown)
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})
        self.assertIn("nothing is left", output)
        for path in self.out.rglob("*"):
            if path.is_file():
                self.assertNotIn(PROJECT, path.read_text(), path)

    def test_a_run_stopped_during_a_profile_summarizes_the_steps_its_load_generator_reported(self):
        # The Job never completes; the run is stopped once the load
        # generator's log has reported both steps of small.
        self.configure(job_state="")
        process = self.start_script("--yes")
        stream = self.out / "raw" / "small" / "generator-stream.log"
        deadline = time.monotonic() + 60
        while not (stream.exists() and '"kind": "done"' in stream.read_text()):
            if time.monotonic() > deadline:
                self.fail(f"the load generator's log was not streamed to {stream}")
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        summary, conditions, markdown = self.written()
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@small@500", "http-keep-alive@small@1000"])
        self.assertIn("**Stopped early:** the run stopped under profile small, after its step "
                      "http-keep-alive@small@1000: stopped by SIGTERM.", markdown)
        # The nodes smock and the load generator ran on, kept as soon as
        # each Pod had one, and the CPU of smock's.
        nodes = conditions["gke"]["profiles"]["small"]["nodes"]
        self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (NODE_CPU, None))
        self.assertEqual((conditions["machine"]["cpu_model"], conditions["machine"]["cpus"]),
                         ("GKE Autopilot ek-standard-8, AMD EPYC 7B13", 8))
        self.assertEqual(self.state_now(), {"clusters": {}, "repositories": []})

    def test_a_run_the_watchdog_stopped_at_the_time_limit_says_so(self):
        # The time limit passes while smock becomes ready under small, and
        # the watchdog stops the run with SIGTERM.
        self.fake_time(1)
        self.configure(smock_ready={"advance_s": 2500, "sleep": 60})
        process = self.start_script("--yes", "--time-limit", "40m")
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        reason = "the time limit of 40 minutes passed, and the watchdog stopped the run"
        self.assertIn(f"gke-bench: {reason}", output)
        summary, _, markdown = self.written()
        self.assertEqual(summary["gke"]["stopped"], {"reason": reason, "profile": "small", "after": None})
        self.assertIn(f"**Stopped early:** the run stopped under profile small, before its first step: {reason}.",
                      markdown)
        self.wait_for_nothing_left()

    def test_a_run_that_ends_normally_says_nothing_of_stopping(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        summary, _, markdown = self.written()
        self.assertTrue(summary["complete"])
        self.assertNotIn("Stopped early", markdown)


def copy_repository(destination):
    """The files of the repository that a GKE run reads, copied, so that a
    test can change them."""
    for name in ("scripts/gke-bench.sh", "scripts/install-oha.sh", "scripts/build-release.sh", "Dockerfile",
                 "bench/bench.py", "bench/requests.json", "bench/targets.json", "bench/plan-autopilot.json"):
        (destination / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, destination / name)
    shutil.copytree(ROOT / "bench" / "gke", destination / "bench" / "gke",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(ROOT / "bench" / "definitions", destination / "bench" / "definitions")
    return destination / "scripts" / "gke-bench.sh"


class Architectures(Script):
    """A run is for one architecture, this machine's by default. Its images
    are built for it with no emulation: they only copy, and the binaries
    they copy, smock and oha, are checked to be for it before anything is
    made."""

    def built_platforms(self):
        return [call["platform"] for call in self.made(["build"])]

    def nodes_architectures(self):
        selectors = []
        for call in self.made(["apply"]):
            for item in call["document"].get("items", [call["document"]]):
                spec = item.get("spec", {})
                spec = spec.get("template", {}).get("spec", spec)
                if "nodeSelector" in spec:
                    selectors.append(spec["nodeSelector"]["kubernetes.io/arch"])
        return selectors

    def test_a_run_is_for_this_machines_architecture_by_default(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.built_platforms(), [f"linux/{HOST_ARCH}"] * 2)
        self.assertEqual(set(self.nodes_architectures()), {HOST_ARCH})
        conditions = json.loads((self.out / "conditions.json").read_text())
        self.assertEqual(conditions["gke"]["arch"], HOST_ARCH)
        self.assertEqual(conditions["smock"]["sha256"], hashlib.sha256(self.smock.read_bytes()).hexdigest())

    def test_a_run_for_the_other_architecture_builds_and_runs_everything_for_it(self):
        smock = self.smock_for(OTHER_ARCH)
        oha = self.binary("oha", OTHER_ARCH, "oha 1.16.0\n")
        status, output = self.run_script("--yes", "--arch", OTHER_ARCH, "--smock", smock, "--oha", oha)
        self.assertEqual(status, 0, output)
        self.assertEqual(self.built_platforms(), [f"linux/{OTHER_ARCH}"] * 2)
        self.assertEqual(set(self.nodes_architectures()), {OTHER_ARCH})
        # This machine cannot run smock to ask its commit: it reads it from
        # the binary, and says which binary it took.
        digest = hashlib.sha256(smock.read_bytes()).hexdigest()
        self.assertIn(f"its build information names commit {HEAD}, which is checked out; its SHA-256 is {digest}",
                      output)
        conditions = json.loads((self.out / "conditions.json").read_text())
        self.assertEqual((conditions["gke"]["arch"], conditions["smock"]["sha256"]), (OTHER_ARCH, digest))

    def test_the_other_architecture_needs_the_release_binary_ci_built_for_it(self):
        status, output = self.run_script("--dry-run", "--arch", OTHER_ARCH, "--smock", "")
        self.assertEqual(status, 2, output)
        self.assertIn(f"gh run download <run-id> -R hirunefu/smock -n smock-linux-{OTHER_ARCH}", output)
        self.assertEqual(self.calls(), [])
        status, output = self.run_script("--dry-run", "--arch", "riscv64")
        self.assertEqual(status, 2, output)
        self.assertEqual(self.calls(), [])

    def test_the_pinned_oha_of_the_other_architecture_is_installed_for_it(self):
        smock = self.smock_for(OTHER_ARCH)
        status, output = self.run_script("--dry-run", "--arch", OTHER_ARCH, "--smock", smock, "--oha", "")
        self.assertEqual(status, 0, output)
        self.assertRegex(output, rf"would run: \S+/scripts/install-oha.sh \S+/bin {OTHER_ARCH}\n")

    def test_binaries_not_for_the_runs_architecture_are_refused_before_anything_is_made(self):
        script = self.tmp / "smock.sh"
        script.write_text("#!/bin/sh\necho smock\n")
        script.chmod(0o755)
        for args, expected in (
                (["--arch", OTHER_ARCH], f"is for {HOST_ARCH}, not for linux/{OTHER_ARCH}"),
                (["--smock", script], "smock: " + str(script) + " is not an ELF file"),
                (["--oha", self.binary("oha", OTHER_ARCH, "oha 1.16.0\n")],
                 f"oha: {self.tmp}")):
            status, output = self.run_script("--yes", *args)
            self.assertEqual(status, 1, output)
            self.assertIn(expected, output)
            self.assertEqual(self.changing_calls(), [])

    def test_a_smock_of_this_machine_must_say_the_commit_checked_out(self):
        smock = self.smock_for(HOST_ARCH, "0123456789ab")
        status, output = self.run_script("--yes", "--smock", smock)
        self.assertEqual(status, 1, output)
        self.assertIn(f"smock: {smock} is built from commit 0123456789ab, not from {HEAD}, which is checked out",
                      output)
        self.assertEqual(self.changing_calls(), [])

    def test_a_smock_of_the_other_architecture_must_name_the_commit_checked_out(self):
        # Such as one CI built for a pull request, from its merge commit.
        smock = self.smock_for(OTHER_ARCH, "0123456789ab")
        oha = self.binary("oha", OTHER_ARCH, "oha 1.16.0\n")
        status, output = self.run_script("--yes", "--arch", OTHER_ARCH, "--smock", smock, "--oha", oha)
        self.assertEqual(status, 1, output)
        self.assertIn(f"smock: {smock} does not name commit {HEAD} in its build information", output)
        self.assertEqual(self.changing_calls(), [])

    def test_images_that_run_something_are_refused_for_the_other_architecture(self):
        script = copy_repository(self.tmp / "repository")
        dockerfile = self.tmp / "repository" / "bench" / "gke" / "generator.Dockerfile"
        dockerfile.write_text(dockerfile.read_text() + "RUN pip install something\n")
        smock = self.smock_for(OTHER_ARCH)
        oha = self.binary("oha", OTHER_ARCH, "oha 1.16.0\n")
        command = [str(script), *self.arguments("--yes", "--arch", OTHER_ARCH, "--smock", smock, "--oha", oha)[1:]]
        result = subprocess.run(command, env=self.environment(), capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("bench/gke/generator.Dockerfile:", output)
        self.assertIn("RUN pip install something", output)
        self.assertEqual(self.changing_calls(), [])
        # A builder without emulation would have failed it anyway, as the
        # fake docker does.
        fake = subprocess.run([str(self.bin / "docker"), "build", f"--platform=linux/{OTHER_ARCH}",
                               f"--file={dockerfile}", str(self.tmp)], env=self.environment(), capture_output=True,
                              text=True)
        self.assertEqual(fake.returncode, 1)
        self.assertIn("exec format error", fake.stderr)


class Zones(Script):
    """Autopilot chooses the zone unless GKE_BENCH_ZONE pins one."""

    def selectors(self):
        selectors = []
        for call in self.made(["apply"]):
            for item in call["document"].get("items", [call["document"]]):
                spec = item.get("spec", {})
                spec = spec.get("template", {}).get("spec", spec)
                if "nodeSelector" in spec:
                    selectors.append(spec["nodeSelector"])
        return selectors

    def test_without_a_zone_none_is_pinned(self):
        status, output = self.run_script("--yes")
        self.assertEqual(status, 0, output)
        self.assertEqual(len(self.selectors()), 2)
        for selector in self.selectors():
            self.assertNotIn("topology.kubernetes.io/zone", selector)
        self.assertEqual(self.made(["compute", "zones", "describe"]), [])
        self.assertIn("zone chosen by Autopilot", output)

    def test_a_zone_given_pins_both_pods_to_it_once_it_is_found_in_the_region(self):
        status, output = self.run_script("--yes", GKE_BENCH_ZONE="us-central1-f")
        self.assertEqual(status, 0, output)
        self.assertEqual({selector["topology.kubernetes.io/zone"] for selector in self.selectors()},
                         {"us-central1-f"})
        self.assertEqual(self.made(["compute", "zones", "describe"])[0]["words"][3], "us-central1-f")
        status, output = self.run_script("--dry-run", GKE_BENCH_ZONE="europe-west4-a")
        self.assertEqual(status, 2, output)


class Regions(Script):
    def test_only_an_arm64_run_is_warned_of_a_region_without_arm_pods(self):
        smock = self.smock_for("amd64")
        oha = self.binary("oha", "amd64", "oha 1.16.0\n")
        status, output = self.run_script("--dry-run", "--arch", "amd64", "--smock", smock, "--oha", oha,
                                         GKE_BENCH_REGION="asia-northeast1")
        self.assertEqual(status, 0, output)
        self.assertIn("Cost estimate for amd64 (x86) Pods (asia-northeast1, on-demand prices", output)
        self.assertNotIn("Arm", output)
        smock = self.smock_for("arm64")
        oha = self.binary("oha", "arm64", "oha 1.16.0\n")
        status, output = self.run_script("--dry-run", "--arch", "arm64", "--smock", smock, "--oha", oha,
                                         GKE_BENCH_REGION="asia-northeast1")
        self.assertEqual(status, 0, output)
        self.assertIn("warning: asia-northeast1 is not among the regions with Arm Pods", output)
        self.assertIn("--arch amd64", output)


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
