"""Tests of the GKE Autopilot run's helper, bench/gke/gke.py: the manifests
it renders for each profile, its plan of the run and cost estimate, the
summary it makes of what the load generator and the cluster reported, and,
for a run of variants of smock on one node, its samples and the comparison
of the variants.

They run the helper through its command line, as scripts/gke-bench.sh does,
and need python3 alone, but for the test of the load generator
(bench/gke/generator.py), which runs it against smock on this machine and
needs what the benchmark's own tests need: a release build of smock
(dist/smock, or SMOCK_BENCH_SMOCK), oha (on PATH, or OHA), and a systemd
user manager that can set CPU quotas and memory limits, since smock runs
in a scope of its own there, as in a container under a profile's limits.

usage: python3 -m unittest discover -s bench -v
"""

import importlib.util
import json
import os
import platform
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

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

    def manifests(self, profile="autopilot-min", arch="arm64", plan=BENCH / "plan-autopilot.json", cases=None,
                  smock_deadline_s=3000, zone="us-central1-a", variants=(), rounds=None):
        """The manifests rendered for one profile: {file name: objects}.
        With `variants` (each as --variant takes it), smock's images are
        theirs."""
        out = self.directory()
        images = [arg for variant in variants for arg in ("--variant", variant)] or ["--smock-image", SMOCK_IMAGE]
        args = ["manifests", "--plan", plan, "--profile", profile, "--arch", arch, *(["--zone", zone] if zone else []),
                *images, "--generator-image", GENERATOR_IMAGE,
                "--smock-deadline-s", smock_deadline_s, "--out", out]
        if cases:
            args += ["--cases", cases]
        if rounds is not None:
            args += ["--rounds", rounds]
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
    """The Pod spec of a Pod, or of a Job's Pods."""
    return item["spec"] if item["kind"] == "Pod" else item["spec"]["template"]["spec"]


class Manifests(Helper):
    """Each profile runs smock in a Pod whose requests are its limits, with
    a deadline, behind a ClusterIP Service, and the load generator in a Job
    with a deadline on another node in smock's zone, both on nodes of the
    run's architecture, in a namespace that cannot have a LoadBalancer or a
    volume claim."""

    def test_smock_runs_under_the_profiles_limits_as_requests_behind_a_cluster_ip_service(self):
        rendered = self.manifests(profile="autopilot-burst-min")
        [pod] = objects(rendered, "Pod")
        [container] = pod_spec(pod)["containers"]
        self.assertEqual(container["image"], SMOCK_IMAGE)
        resources = container["resources"]
        self.assertEqual((resources["limits"]["cpu"], resources["limits"]["memory"]), ("50m", "52Mi"))
        self.assertEqual(resources["requests"], resources["limits"])
        self.assertEqual(pod_spec(pod)["restartPolicy"], "Always")
        [service] = objects(rendered, "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual({port["port"]: port["targetPort"] for port in service["spec"]["ports"]},
                         {80: 8080, 443: 8443, 9090: 9090})
        # The Service selects smock's Pod.
        self.assertLessEqual(service["spec"]["selector"].items(), pod["metadata"]["labels"].items())

    def test_an_init_container_prints_the_cpu_of_smocks_node_asking_for_no_more_than_smock(self):
        # From the load generator's image, which has Python and gke.py;
        # smock's own has no shell. Autopilot bills a Pod for the larger of
        # its init containers and the sum of its containers: with smock's
        # limits, the Pod asks for what smock does.
        for profile in ("autopilot-burst-min", "chart-default"):
            [pod] = objects(self.manifests(profile=profile), "Pod")
            [container] = pod_spec(pod)["containers"]
            [init] = pod_spec(pod)["initContainers"]
            self.assertEqual((init["name"], init["image"], init["command"]),
                             ("node-cpu", GENERATOR_IMAGE, ["python3", "/bench/gke/gke.py", "node-cpu"]))
            self.assertEqual(init["resources"], container["resources"])
            self.assertEqual(init["securityContext"], container["securityContext"])

    def test_each_profile_has_its_own_service_and_pod_which_the_load_generator_targets(self):
        # A new name for each profile: no ClusterIP or datapath entry of the
        # previous profile's Service, just deleted, is reused.
        for profile in ("autopilot-min", "chart-default"):
            rendered = self.manifests(profile=profile)
            [pod] = objects(rendered, "Pod")
            [service] = objects(rendered, "Service")
            self.assertEqual((pod["metadata"]["name"], service["metadata"]["name"]),
                             (f"smock-{profile}", f"smock-{profile}"))
            # The Service selects this profile's Pod only.
            self.assertEqual(service["spec"]["selector"]["profile"], profile)
            self.assertLessEqual(service["spec"]["selector"].items(), pod["metadata"]["labels"].items())
            [job] = objects(rendered, "Job")
            [container] = pod_spec(job)["containers"]
            env = {variable["name"]: variable["value"] for variable in container["env"]}
            self.assertEqual(env["TARGET"], f"smock-{profile}.smock-bench.svc.cluster.local")

    def test_a_profile_whose_name_cannot_name_a_service_is_refused(self):
        plan = json.loads((BENCH / "plan-autopilot.json").read_text())
        plan["profiles"][0]["name"] = "Burst_Min"
        plan["cases"] = [{**case, "rates": {"Burst_Min": [125]}} for case in plan["cases"]]
        path = self.directory() / "plan.json"
        path.write_text(json.dumps(plan))
        status, _, stderr = helper("plan", "--plan", path)
        self.assertEqual(status, 1)
        self.assertIn("profile Burst_Min cannot name a Kubernetes Service", stderr)

    def test_smocks_pod_stops_by_itself_at_the_deadline_it_is_given(self):
        # Even when neither the run nor its watchdog is left to delete the
        # cluster, smock is billed until the run's time limit at most.
        [pod] = objects(self.manifests(smock_deadline_s=2400), "Pod")
        self.assertEqual(pod_spec(pod)["activeDeadlineSeconds"], 2400)
        status, _, stderr = helper("manifests", "--plan", BENCH / "plan-autopilot.json", "--profile", "autopilot-min",
                                   "--arch", "arm64", "--zone", "us-central1-a", "--smock-image", SMOCK_IMAGE,
                                   "--generator-image", GENERATOR_IMAGE, "--smock-deadline-s", 0,
                                   "--out", self.directory())
        self.assertEqual(status, 1)
        self.assertIn("deadline of at least 1 s", stderr)

    def test_the_load_generator_is_a_job_with_a_deadline_on_another_node_than_smock(self):
        rendered = self.manifests(profile="chart-default")
        [pod] = objects(rendered, "Pod")
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
        self.assertLessEqual(term["labelSelector"]["matchLabels"].items(), pod["metadata"]["labels"].items())
        [container] = spec["containers"]
        self.assertEqual(container["image"], GENERATOR_IMAGE)
        self.assertEqual(container["resources"]["requests"], container["resources"]["limits"])
        env = {variable["name"]: variable["value"] for variable in container["env"]}
        self.assertEqual((env["PROFILE"], env["CASES"]), ("chart-default", "http-keep-alive,https-keep-alive"))

    def test_the_load_generator_has_6_vcpus_on_amd64_and_4_on_arm64_and_fits_an_8_vcpu_node(self):
        # An x86 vCPU is a hyperthread: 4 of them fell behind the schedule
        # at 20,000 requests a second and above.
        for arch, expected in (("amd64", ("6", "6Gi")), ("arm64", ("4", "4Gi"))):
            [job] = objects(self.manifests(arch=arch), "Job")
            [container] = pod_spec(job)["containers"]
            resources = container["resources"]
            self.assertEqual((resources["requests"]["cpu"], resources["requests"]["memory"]), expected)
            self.assertEqual(resources["requests"], resources["limits"])
            # An 8-vCPU Autopilot node had 7910m allocatable in the runs of
            # 2026-10-14 (ek-standard-8, e4a-standard-8); at least 1 vCPU of
            # it stays for Autopilot's own Pods there.
            self.assertLessEqual(float(resources["requests"]["cpu"]) + 1, 7.910)

    def test_both_are_pinned_to_the_zone_and_to_the_compute_class_of_the_architecture(self):
        # arm64 in the built-in autopilot-arm compute class; amd64 in
        # Autopilot's default general-purpose Pods, which have no class to
        # select.
        for arch, expected in (
                ("arm64", {"kubernetes.io/arch": "arm64", "cloud.google.com/compute-class": "autopilot-arm",
                           "topology.kubernetes.io/zone": "us-central1-a"}),
                ("amd64", {"kubernetes.io/arch": "amd64", "topology.kubernetes.io/zone": "us-central1-a"})):
            rendered = self.manifests(arch=arch)
            for item in [*objects(rendered, "Pod"), *objects(rendered, "Job")]:
                self.assertEqual(pod_spec(item)["nodeSelector"], expected)
            # The zone keeps them together; the load generator needs no
            # affinity to smock's for that.
            [job] = objects(rendered, "Job")
            self.assertEqual(set(pod_spec(job)["affinity"]), {"podAntiAffinity"})

    def test_without_a_zone_autopilot_chooses_it_and_the_load_generator_follows_smock_there(self):
        rendered = self.manifests(arch="amd64", zone=None)
        [pod] = objects(rendered, "Pod")
        [job] = objects(rendered, "Job")
        for item in (pod, job):
            self.assertEqual(pod_spec(item)["nodeSelector"], {"kubernetes.io/arch": "amd64"})
        affinity = pod_spec(job)["affinity"]
        [term] = affinity["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        self.assertEqual(term["topologyKey"], "topology.kubernetes.io/zone")
        self.assertLessEqual(term["labelSelector"]["matchLabels"].items(), pod["metadata"]["labels"].items())
        # And still on another node than smock.
        [term] = affinity["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
        self.assertEqual(term["topologyKey"], "kubernetes.io/hostname")

    def test_nothing_billed_outside_the_pods_can_be_made_in_the_namespace(self):
        rendered = self.manifests()
        kinds = {item["kind"] for items in rendered.values() for item in items}
        self.assertEqual(kinds, {"Namespace", "ResourceQuota", "Service", "Pod", "Job"})
        for item in [*objects(rendered, "Pod"), *objects(rendered, "Job")]:
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


# A second smock image, of another binary than SMOCK_IMAGE's.
OTHER_IMAGE = "registry.example/smock-bench/smock@sha256:" + "3" * 64

# Two variants of smock, as --variant takes them: R1's binary, the
# baseline, and R2's.
TWO_VARIANTS = (f"r1={SMOCK_IMAGE}", f"r2={OTHER_IMAGE}")


class Variants(Helper):
    """With variants, each variant's smock runs in a Pod and behind a
    Service of its own, under the profile's limits, every one on the node
    of the first, while one load generator on another node measures them
    in turn."""

    def test_each_variants_pod_and_service_are_named_for_it_and_its_service_selects_its_pod_alone(self):
        rendered = self.manifests(variants=TWO_VARIANTS)
        self.assertEqual(sorted(rendered), ["generator.json", "namespace.json", "smock-r1.json", "smock-r2.json"])
        pods = objects(rendered, "Pod")
        for label, image in (("r1", SMOCK_IMAGE), ("r2", OTHER_IMAGE)):
            [service, pod] = rendered[f"smock-{label}.json"]
            self.assertEqual((service["kind"], pod["kind"]), ("Service", "Pod"))
            self.assertEqual((pod["metadata"]["name"], service["metadata"]["name"]),
                             (f"smock-autopilot-min-{label}", f"smock-autopilot-min-{label}"))
            self.assertEqual(pod["metadata"]["labels"],
                             {"app": "smock-bench", "profile": "autopilot-min", "variant": label})
            self.assertEqual(service["spec"]["selector"], pod["metadata"]["labels"])
            [container] = pod_spec(pod)["containers"]
            self.assertEqual(container["image"], image)
            # The load of one variant goes to its Pod, never to another's.
            selector = service["spec"]["selector"].items()
            self.assertEqual([other["metadata"]["name"] for other in pods
                              if selector <= other["metadata"]["labels"].items()], [pod["metadata"]["name"]])

    def test_every_variants_pod_must_share_a_node_with_the_profiles_others_and_none_keeps_another_away(self):
        # Through the hostname, which Autopilot allows as a topology key; a
        # nodeSelector on it is restricted there. The first Pod matches its
        # own labels, so it may go anywhere, and the others follow it. No
        # anti-affinity: Autopilot rejects it below 0.5 vCPU.
        rendered = self.manifests(profile="autopilot-burst-min", variants=TWO_VARIANTS, zone=None)
        pods = objects(rendered, "Pod")
        self.assertEqual(len(pods), 2)
        for pod in pods:
            affinity = pod_spec(pod)["affinity"]
            self.assertEqual(set(affinity), {"podAffinity"})
            [term] = affinity["podAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
            self.assertEqual(term, {"labelSelector": {"matchLabels": {"app": "smock-bench",
                                                                      "profile": "autopilot-burst-min"}},
                                    "topologyKey": "kubernetes.io/hostname"})
            self.assertEqual(pod_spec(pod)["nodeSelector"], {"kubernetes.io/arch": "arm64",
                                                             "cloud.google.com/compute-class": "autopilot-arm"})
        # The load generator stays off that node, and in its zone.
        [job] = objects(rendered, "Job")
        affinity = pod_spec(job)["affinity"]
        for kind, key in (("podAntiAffinity", "kubernetes.io/hostname"),
                          ("podAffinity", "topology.kubernetes.io/zone")):
            [term] = affinity[kind]["requiredDuringSchedulingIgnoredDuringExecution"]
            self.assertEqual(term["topologyKey"], key)
            for pod in pods:
                self.assertLessEqual(term["labelSelector"]["matchLabels"].items(), pod["metadata"]["labels"].items())

    def test_a_no_init_variant_has_no_init_container_and_the_same_limits_as_the_others(self):
        # Its container's cpu.max and the Pod's CPU limit stay the same, so
        # that the init container alone differs.
        rendered = self.manifests(profile="autopilot-min", variants=(f"r2={OTHER_IMAGE}",
                                                                     f"r2h={OTHER_IMAGE},no-init,no-first-second"))
        [_, with_init] = rendered["smock-r2.json"]
        [_, without] = rendered["smock-r2h.json"]
        [init] = pod_spec(with_init)["initContainers"]
        self.assertEqual(init["name"], "node-cpu")
        self.assertNotIn("initContainers", pod_spec(without))
        [container] = pod_spec(without)["containers"]
        self.assertEqual(container["resources"], pod_spec(with_init)["containers"][0]["resources"])
        self.assertEqual((container["resources"]["limits"]["cpu"], container["resources"]["limits"]["memory"]),
                         ("250m", "512Mi"))
        self.assertEqual(container["resources"]["requests"], container["resources"]["limits"])

    def test_the_namespace_holds_each_variants_pod_the_load_generators_and_no_more(self):
        # Each smock Pod and the load generator's, with two to spare, as
        # without variants, whose one smock Pod gives 4.
        four = (*TWO_VARIANTS, f"r2b={OTHER_IMAGE}", f"r2h={OTHER_IMAGE},no-init")
        for variants, pods in (((), "4"), (TWO_VARIANTS, "5"), (four, "7")):
            [quota] = objects(self.manifests(variants=variants), "ResourceQuota")
            self.assertEqual(quota["spec"]["hard"]["pods"], pods)

    def test_one_load_generator_is_told_each_variants_service_in_order_and_the_rounds_in_place_of_a_target(self):
        rendered = self.manifests(profile="autopilot-min", cases="http-keep-alive",
                                  variants=(*TWO_VARIANTS, f"r2h={OTHER_IMAGE},no-init,no-first-second"))
        [job] = objects(rendered, "Job")
        [container] = pod_spec(job)["containers"]
        env = {variable["name"]: variable["value"] for variable in container["env"]}
        self.assertEqual(set(env), {"PROFILE", "CASES", "VARIANTS", "ROUNDS"})
        self.assertEqual((env["PROFILE"], env["CASES"], env["ROUNDS"]), ("autopilot-min", "http-keep-alive", "4"))
        self.assertEqual(json.loads(env["VARIANTS"]), [
            {"label": "r1", "target": "smock-autopilot-min-r1.smock-bench.svc.cluster.local", "first_second": True},
            {"label": "r2", "target": "smock-autopilot-min-r2.smock-bench.svc.cluster.local", "first_second": True},
            {"label": "r2h", "target": "smock-autopilot-min-r2h.smock-bench.svc.cluster.local",
             "first_second": False}])
        # As many rounds as asked for.
        [job] = objects(self.manifests(variants=TWO_VARIANTS, rounds=6), "Job")
        [container] = pod_spec(job)["containers"]
        self.assertIn({"name": "ROUNDS", "value": "6"}, container["env"])

    def test_the_load_generator_reads_each_variants_service_from_its_job_and_makes_the_runs_its_deadline_counts(self):
        # gke.py writes the Job and generator.py reads it: the two meet only
        # in this environment, so it is read here as the generator reads it.
        generator = load_generator_module()
        gke = generator.gke
        rendered = self.manifests(profile="autopilot-min", cases="http-keep-alive", rounds=3,
                                  variants=(*TWO_VARIANTS, f"r2h={OTHER_IMAGE},no-init,no-first-second"))
        [job] = objects(rendered, "Job")
        [container] = pod_spec(job)["containers"]
        env = {variable["name"]: variable["value"] for variable in container["env"]}
        variants = generator.read_variants(env)
        self.assertEqual([(variant.label, variant.first_second) for variant in variants],
                         [("r1", True), ("r2", True), ("r2h", False)])
        services = {service["metadata"]["name"]: service["spec"] for service in objects(rendered, "Service")}
        for variant in variants:
            # Each target is the host name of the Service that selects that
            # variant's Pod, and that Service serves every port the
            # generator sends to.
            name, domain = variant.target.split(".", 1)
            self.assertEqual(domain, "smock-bench.svc.cluster.local")
            self.assertEqual(services[name]["selector"]["variant"], variant.label)
            self.assertLessEqual({*variant.ports.values(), variant.admin_port},
                                 {port["port"] for port in services[name]["ports"]})
        # The Job's deadline is for as many runs as the generator makes.
        plan = gke.read_json(BENCH / "plan-autopilot.json")
        [profile] = gke.plan_profiles(plan, [env["PROFILE"]])
        specs = gke.steps(plan, profile, gke.plan_cases(plan, gke.comma_list(env["CASES"])))
        made = [spec for _, spec, _ in generator.run_order(specs, variants, int(env["ROUNDS"]))]
        self.assertEqual(len(made), len(gke.runs(specs, len(variants), 3)))
        self.assertGreater(job["spec"]["activeDeadlineSeconds"], gke.load_s(plan, made))

    def test_variants_and_rounds_it_cannot_run_are_refused_with_what_to_change(self):
        def render(*images, profile="autopilot-min", plan=BENCH / "plan-autopilot.json"):
            return helper("manifests", "--plan", plan, "--profile", profile, "--arch", "amd64",
                          "--generator-image", GENERATOR_IMAGE, "--smock-deadline-s", 3000, "--out", self.directory(),
                          *images)

        def variants(*texts):
            return [arg for text in texts for arg in ("--variant", text)]

        long_plan = json.loads((BENCH / "plan-autopilot.json").read_text())
        long_name = "a-profile-whose-name-is-fifty-two-characters-long-ab"
        long_plan["profiles"][0]["name"] = long_name
        long_plan["cases"] = [{**case, "rates": {long_name: [125]}} for case in long_plan["cases"]]
        long_path = self.directory() / "plan.json"
        long_path.write_text(json.dumps(long_plan))
        for images, expected in (
                (variants(TWO_VARIANTS[0]), "2 to 4 variants, not 1"),
                (variants(*TWO_VARIANTS, f"a={OTHER_IMAGE}", f"b={OTHER_IMAGE}", f"c={OTHER_IMAGE}"),
                 "2 to 4 variants, not 5"),
                (variants(*TWO_VARIANTS, f"r1={OTHER_IMAGE}"), "variant r1 is given twice"),
                (variants(TWO_VARIANTS[0], f"R2={OTHER_IMAGE}"), "variant label R2"),
                (variants(TWO_VARIANTS[0], f"r2-={OTHER_IMAGE}"), "variant label r2-"),
                (variants(TWO_VARIANTS[0], f"a-label-of-17-chr={OTHER_IMAGE}"), "variant label a-label-of-17-chr"),
                (variants(TWO_VARIANTS[0], OTHER_IMAGE), f"--variant {OTHER_IMAGE}: give it as LABEL=IMAGE"),
                (variants(TWO_VARIANTS[0], "r2="), "--variant r2=: give it as LABEL=IMAGE"),
                (variants(TWO_VARIANTS[0], f"r2={OTHER_IMAGE},no-sleep"), "variant r2: no option no-sleep"),
                ([*variants(*TWO_VARIANTS), "--rounds", 0], "at least 1 round, not 0"),
                (["--smock-image", SMOCK_IMAGE, "--rounds", 4], "--rounds needs --variant"),
                (["--smock-image", SMOCK_IMAGE, *variants(*TWO_VARIANTS)], "--smock-image or --variant, not both"),
                ([], "smock's image: --smock-image, or --variant for each variant")):
            status, _, stderr = render(*images)
            self.assertEqual(status, 1, images)
            self.assertIn(expected, stderr)
        # smock-<profile>-<label> must still name a Service.
        status, _, stderr = render(*variants(f"r1={SMOCK_IMAGE}", f"r2-bare={OTHER_IMAGE}"), profile=long_name,
                                   plan=long_path)
        self.assertEqual(status, 1)
        self.assertIn(f"variant r2-bare under profile {long_name} cannot name a Kubernetes Service "
                      f"(smock-{long_name}-r2-bare): give it a shorter label", stderr)
        status, _, stderr = render(*variants(f"r1={SMOCK_IMAGE}", f"r2={OTHER_IMAGE}"), profile=long_name,
                                   plan=long_path)
        self.assertEqual(status, 0, stderr)

    def test_the_load_generators_deadline_grows_with_each_variants_runs_and_its_neighbours_scrapes(self):
        # small_plan's two steps of 2 + 20 + 3 s with 2 s between them; the
        # plan settles 5 s before reading idle RSS. One smock: 52 s of load,
        # 15 s to analyse each step, 300 s to start, the 5 s settle, and 60
        # s for each of two traffic checks.
        plan = small_plan(self.directory())
        status, stdout, stderr = helper("plan", "--plan", plan)
        self.assertEqual((status, stdout), (0, "small 2 507\n"), stderr)
        # 2 variants over 4 rounds run each step 8 times: 16 runs of 25 s
        # with 2 s between them (430 s), each with its analysis and the
        # scrape of the idle neighbour before and after it, 1 s each (16 ×
        # 17 s), the start and settle, and a traffic check of each variant
        # before the first step and one after a step (3 × 60 s).
        status, stdout, stderr = helper("plan", "--plan", plan, "--variants", 2, "--rounds", 4)
        self.assertEqual((status, stdout), (0, "small 2 1187\n"), stderr)
        # 4 rounds unless told otherwise, as for the manifests.
        self.assertEqual(helper("plan", "--plan", plan, "--variants", 2)[1], "small 2 1187\n")
        # 4 variants in 1 round: 8 runs (214 s), each scraping 3 neighbours
        # twice (8 × 21 s), and 5 traffic checks.
        status, stdout, stderr = helper("plan", "--plan", plan, "--variants", 4, "--rounds", 1)
        self.assertEqual((status, stdout), (0, "small 2 987\n"), stderr)
        # The Job's own deadline is the plan's.
        [job] = objects(self.manifests(profile="small", plan=plan, variants=TWO_VARIANTS), "Job")
        self.assertEqual(job["spec"]["activeDeadlineSeconds"], 1187)
        for args, expected in ((["--variants", 0], "1 to 4 variants, not 0"),
                               (["--variants", 5], "1 to 4 variants, not 5"),
                               (["--variants", 2, "--rounds", 0], "at least 1 round, not 0"),
                               (["--rounds", 4], "--rounds needs --variants")):
            status, _, stderr = helper("plan", "--plan", plan, *args)
            self.assertEqual(status, 1, args)
            self.assertIn(expected, stderr)

    def test_without_variants_smocks_one_pod_runs_as_before_with_no_variant_label_or_affinity(self):
        rendered = self.manifests()
        self.assertEqual(sorted(rendered), ["generator.json", "namespace.json", "smock.json"])
        [pod] = objects(rendered, "Pod")
        self.assertEqual(pod["metadata"]["labels"], {"app": "smock-bench", "profile": "autopilot-min"})
        self.assertNotIn("affinity", pod_spec(pod))
        [job] = objects(rendered, "Job")
        self.assertEqual([variable["name"] for variable in pod_spec(job)["containers"][0]["env"]],
                         ["TARGET", "PROFILE", "CASES"])


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


class SameNodePlan(Helper):
    """bench/plan-same-node.json is the plan of a run that compares smock
    binaries on one node (scripts/gke-bench.sh --variant): HTTP keep-alive
    alone, at the lowest rates of bench/plan-autopilot.json's ladders,
    under its profiles and with its window, so that each sample compares
    with a pre-merge run's steps."""

    def test_it_measures_http_keep_alive_at_the_lowest_steps_of_the_autopilot_plans_ladders(self):
        plan = json.loads((BENCH / "plan-same-node.json").read_text())
        autopilot = json.loads((BENCH / "plan-autopilot.json").read_text())
        [case] = plan["cases"]
        self.assertEqual(case["rates"], {"autopilot-burst-min": [125, 250, 500],
                                         "autopilot-min": [625, 1250, 2500], "chart-default": [2500, 5000]})
        http = next(case for case in autopilot["cases"] if case["name"] == "http-keep-alive")
        self.assertEqual({key: value for key, value in case.items() if key != "rates"},
                         {key: value for key, value in http.items() if key != "rates"})
        for profile, rates in case["rates"].items():
            self.assertEqual(rates, http["rates"][profile][:len(rates)], profile)
        for key in ("profiles", "ramp_s", "duration_s", "tail_s", "cooldown_s", "rss_interval_s", "idle_rss",
                    "load_generator"):
            self.assertEqual(plan[key], autopilot[key], key)
        self.assertIn("scripts/gke-bench.sh --variant", plan["about"])

    def test_four_variants_in_four_rounds_give_each_profile_of_run_1_its_jobs_time(self):
        # 48 runs of three steps, each beside three idle variants: the
        # Job's deadline under autopilot-burst-min and autopilot-min.
        status, stdout, stderr = helper("plan", "--plan", BENCH / "plan-same-node.json", "--profiles",
                                        "autopilot-burst-min,autopilot-min", "--variants", 4, "--rounds", 4)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(stdout, "autopilot-burst-min 3 2907\nautopilot-min 3 2907\n")


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


# The targets of profile small, at http-keep-alive's 1,000 requests/s.
SMALL_TARGETS = {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "case": "http-keep-alive",
                 "rate": 1000,
                 "at_most": {"p99_ms": 3, "p99_9_ms": 5, "oom_kills": 0, "peak_memory_mib": 32, "idle_rss_mib": 20}}


def small_targets(directory, architectures=None):
    """A targets file with the entries of each architecture of
    `architectures` ({architecture: entries}); by default, small's targets
    for arm64 and for amd64 alike."""
    path = directory / "targets.json"
    by_architecture = architectures or {"arm64": [SMALL_TARGETS], "amd64": [SMALL_TARGETS]}
    path.write_text(json.dumps({"architectures": {architecture: {"profiles": entries}
                                                  for architecture, entries in by_architecture.items()}}))
    return path


def generator_step(rate, p99=2.0, p99_9=2.5, errors=0, peak_mib=20.0, scraped=True):
    """A step line of the load generator for http-keep-alive under small:
    with what smock used during it, from its /metrics (smock's CPU at 30 µs
    a request, its peak memory `peak_mib`), or, when not `scraped`, as from
    a smock without process metrics."""
    scheduled = rate * 20
    requests = rate * 25 - errors
    usage_s = requests * 30e-6
    smock_cpu = {"usage_s": round(usage_s, 3), "periods": 250, "throttled_periods": 3, "throttled_s": 0.012,
                 "source": "cgroup", "process_s": round(usage_s, 2), "wall_s": 25.004, "requests": requests,
                 "us_per_request": 30.0, "utilization": round(usage_s / (25.004 * 0.25), 4)}
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
        "tcp_passive_opens": None, "idle_connections_open_at_end": None, "pinning": None,
        "smock_cpu": smock_cpu if scraped else None,
        "memory": {"peak_bytes": round(peak_mib * (1 << 20)) if scraped else None, "oom_kills": None},
        "rss_kib": {"first": 17000, "last": 18000, "max": 18000} if scraped else {"first": None, "last": None,
                                                                                   "max": None},
        "smock_ready": True, "smock_exit_status": None, "per_request": []}}


# What the load generator says of smock idle under small, from its
# /metrics, 5 s after it was ready.
IDLE = {"kind": "idle-rss", "profile": "small", "idle": {
    "profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "settle_s": 5, "smock_ready": True,
    "digest": "48f7ce9715f0", "rss_kib": 16384, "memory": {"peak_bytes": 15 << 20, "oom_kills": None}}}


START = {"kind": "start", "profile": "small", "oha": "oha 1.16.0", "cpus": 8, "affinity": 4,
         "status": {"version": "0.2.0", "commit": "a21fe97d59c6", "toolchain": "moonc v0.10.14+7d59c7ec9",
                    "digest": "48f7ce9715f0", "mocks": [{"name": "catalog"}]}}

NODE = {"instance_type": "e4a-standard-8", "arch": "arm64", "zone": "us-central1-a", "machine_family": "e4a",
        "compute_class": "autopilot-arm", "boot_disk": "hyperdisk-balanced", "kernel": "6.12.94+",
        "kubelet": "v1.35.8-gke.1225000", "os_image": "Container-Optimized OS from Google", "cpus": "8",
        "allocatable_cpu": "7910m"}


# An amd64 node of Autopilot's general-purpose Pods, which have no compute
# class label.
X86_NODE = {**NODE, "instance_type": "ek-standard-8", "arch": "amd64", "zone": "asia-northeast1-b",
            "machine_family": "ek", "compute_class": None, "boot_disk": "pd-balanced"}


def pods(restarts=0, reason=None, node=NODE, generator_node=None, generator_cpu="4"):
    """What gke.py pod-info keeps of the profile's Pods and their nodes."""
    return {"smock": [{"name": "smock-small", "node": "node-a", "ready": True, "restarts": restarts,
                       "last_termination": reason}],
            "generator": [{"name": "generator-small-1", "node": "node-b", "phase": "Succeeded", "reason": None,
                           "cpu_request": generator_cpu}],
            "nodes": {"node-a": node, "node-b": generator_node or node}}


# What the load generator says of the traffic ports before the first step:
# both answered.
TRAFFIC_CHECK = {"kind": "traffic-check", "profile": "small", "ok": True, "host": "catalog.bench.internal",
                 "method": "GET", "target": "/catalog/items/SKU-00317", "window_s": 60,
                 "ports": {"plain": {"port": 80, "answered": True, "status": 200, "attempts": 1, "seconds": 0.004,
                                     "error": None},
                           "tls": {"port": 443, "answered": True, "status": 200, "attempts": 1, "seconds": 0.011,
                                   "error": None}}}


class Summary(Helper):
    """A GKE run's results become a summary of the same layout as a run on
    a machine writes, which bench/compare.py reads, with its targets
    checked, and the conditions it ran under."""

    def results(self, lines, pod_info, rates=(500, 1000), where=("--region", "us-central1", "--zone", "us-central1-a",
                                                                 "--arch", "arm64"), targets=None, smock_node_cpu=None,
                stopped=(), plan=None):
        """A results directory as scripts/gke-bench.sh leaves it, with the
        load generator's log, the Pods of profile small, and, when given,
        what smock's init container printed (`smock_node_cpu`, a text),
        summarized against `targets` ({architecture: entries}, by default
        small's targets for both); `stopped` says why and where the run
        stopped early, if it did. The plan is small_plan's at `rates`,
        unless `plan` names another."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        text = "".join(line if isinstance(line, str) else json.dumps(line) + "\n" for line in lines)
        (raw / "generator.log").write_text(text)
        (raw / "pods.json").write_text(json.dumps(pod_info))
        if smock_node_cpu is not None:
            (raw / "smock-node-cpu.log").write_text(smock_node_cpu)
        status, _, stderr = helper(
            "summarize", "--plan", plan or small_plan(self.directory(), rates),
            "--targets", small_targets(self.directory(), targets), *where,
            "--started-at", "2026-10-14T03:28:50+00:00", "--finished-at", "2026-10-14T04:01:56+00:00",
            "--cluster-version", "1.35.8-gke.1225000", "--smock-image", "sha256:" + "1" * 64,
            "--generator-image", "sha256:" + "2" * 64, *stopped, out)
        self.assertEqual(status, 0, stderr)
        return out

    def test_each_step_the_load_generator_reported_is_a_case_and_the_targets_are_checked(self):
        out = self.results([START, IDLE, "generator: step 500 requests/s\n", generator_step(500),
                            generator_step(1000, p99=2.5, p99_9=6.0, peak_mib=21.5),
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual(summary["format"], 4)
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]],
                         ["http-keep-alive@small@500", "http-keep-alive@small@1000"])
        # smock never restarted, so the kernel never OOM-killed it.
        self.assertEqual(summary["idle_rss"], [{**IDLE["idle"], "memory": {"peak_bytes": 15 << 20, "oom_kills": 0}}])
        verdicts = {target["id"]: (target["verdict"], target["measured"]) for target in summary["targets"]}
        self.assertEqual(verdicts, {
            "small/p99": ("met", 2.5),
            "small/p99_9": ("missed", 6.0),
            "small/oom_kills": ("met", 0),
            # From smock's /metrics: its cgroup's memory.peak by the end of
            # the step, and its RSS idle.
            "small/peak_memory": ("met", 21.5),
            "small/idle_rss": ("met", 16.0),
        })
        markdown = (out / "summary.md").read_text()
        self.assertIn("Idle RSS: 16.0 MiB, 5 s after startup; peak memory 15.0 MiB, 0 OOM kills.", markdown)
        # The CPU time a request and the share of the CPU limit, then how
        # long smock was throttled.
        self.assertIn("| 0 | 30.0 | 12.0 | 0.012 | 17.6 | 21.5 | 0 |", markdown)
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(out), str(out)],
                                  capture_output=True, text=True)
        self.assertIn("| small | http-keep-alive | 1,000 | 2.5 → 2.5 | 0% |", compared.stdout, compared.stderr)

    def test_a_smock_without_process_metrics_measures_no_idle_rss_peak_memory_or_cpu(self):
        # As a smock built before /metrics had them: the load generator
        # reports no idle RSS, and nothing of what smock used at a step.
        out = self.results([START, generator_step(500, scraped=False), generator_step(1000, scraped=False),
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual(summary["idle_rss"], [])
        verdicts = {target["id"]: (target["verdict"], target["reason"]) for target in summary["targets"]}
        self.assertEqual(verdicts["small/peak_memory"],
                         ("not measured",
                          "the kernel kept no peak memory in http-keep-alive@small@1000 (no memory.peak)"))
        self.assertEqual(verdicts["small/idle_rss"], ("not measured", "the run did not measure idle RSS under small"))
        self.assertIn("| 0 | - | - | - | - | - | 0 |", (out / "summary.md").read_text())

    def test_the_targets_of_the_runs_architecture_are_checked(self):
        # amd64's p99 at 1,000 requests/s is at most 2 ms, which the run's
        # 2.5 ms misses; arm64's is at most 3 ms.
        amd64 = {**SMALL_TARGETS, "at_most": {**SMALL_TARGETS["at_most"], "p99_ms": 2}}
        lines = [START, generator_step(500), generator_step(1000, p99=2.5, p99_9=4.0), {"kind": "done"}]
        for arch, verdict, maximum in (("amd64", "missed", 2), ("arm64", "met", 3)):
            out = self.results(lines, pods(), where=("--region", "us-central1", "--arch", arch),
                               targets={"arm64": [SMALL_TARGETS], "amd64": [amd64]})
            summary = json.loads((out / "summary.json").read_text())
            p99 = next(target for target in summary["targets"] if target["id"] == "small/p99")
            self.assertEqual((p99["architecture"], p99["max"], p99["verdict"]), (arch, maximum, verdict))
            self.assertIn(f"for {arch}, the architecture the run ran on.", (out / "summary.md").read_text())
        # A targets file with none for the run's architecture: none is
        # measured, and the summary says so.
        out = self.results(lines, pods(), where=("--region", "us-central1", "--arch", "amd64"),
                           targets={"arm64": [SMALL_TARGETS]})
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual({target["verdict"] for target in summary["targets"]}, {"not measured"})
        self.assertIn("has no targets for amd64, the architecture the run ran on", (out / "summary.md").read_text())

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

    def test_the_conditions_record_a_hash_of_the_plan_that_leaves_out_its_description(self):
        lines = [START, generator_step(500), generator_step(1000), {"kind": "done"}]

        def recorded(**changes):
            """What conditions.json records of small_plan's plan, changed."""
            path = small_plan(self.directory())
            path.write_text(json.dumps({**json.loads(path.read_text()), **changes}))
            out = self.results(lines, pods(), plan=path)
            return json.loads((out / "conditions.json").read_text())["plan"]

        first, second = recorded(about="What the plan runs."), recorded(about="What the plan runs, said otherwise.")
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual(first["sha256_without_about"], second["sha256_without_about"])
        # Anything else is a different plan.
        other = recorded(about="What the plan runs.", cooldown_s=5)
        self.assertNotEqual(other["sha256_without_about"], first["sha256_without_about"])

    def test_the_conditions_record_the_architecture_region_zone_and_machine_types(self):
        # An amd64 run with no zone pinned: Autopilot chose it.
        generator_node = {**X86_NODE, "instance_type": "ek-standard-16"}
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(node=X86_NODE, generator_node=generator_node),
                           where=("--region", "asia-northeast1", "--arch", "amd64", "--smock-sha256", "3" * 64))
        conditions = json.loads((out / "conditions.json").read_text())
        # The binary in smock's image, such as one CI built.
        self.assertEqual(conditions["smock"]["sha256"], "3" * 64)
        gke = conditions["gke"]
        self.assertEqual(
            {key: gke[key] for key in ("arch", "region", "zone", "pinned_zone", "compute_class", "machine_type",
                                       "generator_machine_type")},
            {"arch": "amd64", "region": "asia-northeast1", "zone": "asia-northeast1-b", "pinned_zone": None,
             "compute_class": "general-purpose", "machine_type": "ek-standard-8",
             "generator_machine_type": "ek-standard-16"})
        self.assertEqual(conditions["machine"]["architecture"], "amd64")
        self.assertIn("asia-northeast1-b", conditions["note"])
        self.assertIn("amd64", conditions["note"])

    def test_the_conditions_name_the_cpu_of_smocks_node_and_of_the_load_generators(self):
        # smock's, from what its init container printed; the load
        # generator's, from its start line.
        out = self.results([{**START, "node_cpu": INTEL_CPU}, generator_step(500), generator_step(1000),
                            {"kind": "done"}], pods(node=X86_NODE),
                           where=("--region", "us-central1", "--arch", "amd64"),
                           smock_node_cpu=json.dumps({"kind": "node-cpu", "cpu": AMD_CPU}) + "\n")
        conditions = json.loads((out / "conditions.json").read_text())
        nodes = conditions["gke"]["profiles"]["small"]["nodes"]
        self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (AMD_CPU, INTEL_CPU))
        # The machine is the node type, as in a run before the nodes' CPUs
        # were recorded, so that comparing with one does not show it as
        # changed: each node's CPU is in its own record and in the Pods
        # table.
        self.assertEqual(conditions["machine"]["cpu_model"], "GKE Autopilot ek-standard-8")
        markdown = (out / "summary.md").read_text()
        self.assertIn("on amd64 (GKE Autopilot ek-standard-8, 8 CPUs)", markdown)
        self.assertIn("| small | ek-standard-8 (amd64, asia-northeast1-b), AMD EPYC 7B13 | "
                      "ek-standard-8 (amd64, asia-northeast1-b), Intel(R) Xeon(R) CPU @ 2.20GHz |", markdown)

    def test_a_node_whose_cpu_was_not_recorded_has_none(self):
        # As a run before its nodes' CPUs were recorded, or one whose init
        # container's log could not be read: kubectl's error is no line.
        for smock_node_cpu in (None, "Error from server (NotFound): pods \"smock-small\" not found\n"):
            out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                               pods(node=X86_NODE), where=("--region", "us-central1", "--arch", "amd64"),
                               smock_node_cpu=smock_node_cpu)
            conditions = json.loads((out / "conditions.json").read_text())
            nodes = conditions["gke"]["profiles"]["small"]["nodes"]
            self.assertEqual((nodes["node-a"]["cpu"], nodes["node-b"]["cpu"]), (None, None))
            self.assertEqual(conditions["machine"]["cpu_model"], "GKE Autopilot ek-standard-8")

    def test_a_profile_cut_short_leaves_the_run_incomplete(self):
        out = self.results([START, generator_step(500), "generator: the deadline passed\n"], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])

    def test_a_run_that_stopped_early_says_where_and_why_at_the_top_of_its_summary(self):
        out = self.results([START, IDLE, generator_step(500)], pods(),
                           stopped=("--stopped", "stopped by SIGTERM", "--stopped-under", "small"))
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])
        self.assertEqual(summary["gke"]["stopped"],
                         {"reason": "stopped by SIGTERM", "profile": "small", "after": "http-keep-alive@small@500"})
        markdown = (out / "summary.md").read_text()
        note = ("**Stopped early:** the run stopped under profile small, after its step http-keep-alive@small@500: "
                "stopped by SIGTERM. Nothing after that was measured.")
        self.assertIn(note, markdown)
        # Right below the line that says what ran, in place of the note
        # that the run is incomplete.
        self.assertLess(markdown.index("Started 2026-10-14T03:28:50+00:00"), markdown.index(note))
        self.assertLess(markdown.index(note), markdown.index("**Note:**"))
        self.assertNotIn("**Incomplete:**", markdown)
        # Before the profile's first step.
        out = self.results([START, IDLE], pods(), stopped=("--stopped", "the load generator's Pod did not start "
                                                           "under small", "--stopped-under", "small"))
        self.assertIn("**Stopped early:** the run stopped under profile small, before its first step: the load "
                      "generator's Pod did not start under small.", (out / "summary.md").read_text())
        # A run that did not stop says nothing of it.
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        self.assertIsNone(json.loads((out / "summary.json").read_text())["gke"]["stopped"])
        self.assertNotIn("Stopped early", (out / "summary.md").read_text())

    def test_a_run_stopped_before_anything_was_reported_says_what_is_unknown(self):
        # smock never became ready under the first profile, on no node: the
        # load generator printed nothing, so smock's version, the
        # definition set and oha's version are unknown, as is the machine.
        out = self.results([], {"smock": [{"name": "smock-small", "node": None, "ready": False, "restarts": 0,
                                           "last_termination": None}], "generator": [], "nodes": {}},
                           stopped=("--stopped", "smock did not become ready under small", "--stopped-under", "small"))
        markdown = (out / "summary.md").read_text()
        self.assertIn("Started 2026-10-14T03:28:50+00:00: smock of an unknown version (commit unknown, toolchain "
                      "unknown), definition set unknown, on arm64 (GKE Autopilot node, CPUs unknown), oha of an "
                      "unknown version, plan ", markdown)
        self.assertNotIn("None", markdown)
        # conditions.json records them as null.
        conditions = json.loads((out / "conditions.json").read_text())
        self.assertEqual((conditions["smock"]["version"], conditions["machine"]["cpus"]), (None, None))
        # So does the comparison with a run that knew them.
        older = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(older), str(out)],
                                  capture_output=True, text=True)
        self.assertIn("- Newer: smock of an unknown version (commit unknown) on GKE Autopilot (us-central1-a, "
                      "autopilot-arm), arm64 (GKE Autopilot node, CPUs unknown)", compared.stdout, compared.stderr)
        self.assertIn("definition set (48f7ce9715f0 → unknown)", compared.stdout)
        self.assertNotIn("None", compared.stdout)

    def test_steps_a_profile_did_not_run_after_it_stopped_early_are_not_measured_with_the_reason(self):
        # The step at 500 got no response at all, so the load generator ran
        # none after it.
        reason = "http-keep-alive@small@500 got no response to any of its 10,000 requests (oha: timeout)"
        out = self.results([START, TRAFFIC_CHECK, generator_step(500, errors=10000),
                            {"kind": "stopped", "profile": "small", "reason": reason,
                             "after": "http-keep-alive@small@500", "steps": ["http-keep-alive@small@1000"]},
                            {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertFalse(summary["complete"])
        self.assertEqual([case["rate"] for case in summary["cases"]], [500])
        # The targets at 1000 requests/s say why they were not measured.
        for target in summary["targets"]:
            if target["metric"] in ("p99", "p99_9", "oom_kills"):
                self.assertEqual(target["verdict"], "not measured")
                self.assertEqual(target["reason"], f"http-keep-alive@small@1000 was not run: {reason}")
        ended = {"reason": reason, "after": "http-keep-alive@small@500", "not_measured": ["http-keep-alive@small@1000"]}
        self.assertEqual(summary["gke"]["profiles"]["small"]["ended_early"], ended)
        conditions = json.loads((out / "conditions.json").read_text())
        self.assertEqual(conditions["gke"]["profiles"]["small"]["ended_early"], ended)
        markdown = (out / "summary.md").read_text()
        self.assertIn(f"small ended early: {reason}. Not measured: http-keep-alive@small@1000.", markdown)

    def test_a_profile_whose_traffic_ports_did_not_answer_measures_nothing_and_says_why(self):
        check = {**TRAFFIC_CHECK, "ok": False, "ports": {
            "plain": TRAFFIC_CHECK["ports"]["plain"],
            "tls": {"port": 443, "answered": False, "status": None, "attempts": 12, "seconds": 60.2,
                    "error": "timed out"}}}
        reason = "smock did not answer through its Service in 60 s: TLS port 443 (timed out)"
        steps = ["http-keep-alive@small@500", "http-keep-alive@small@1000"]
        out = self.results([START, check, {"kind": "stopped", "profile": "small", "reason": reason, "after": None,
                                           "steps": steps}, {"kind": "done", "profile": "small"}], pods())
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual((summary["complete"], summary["cases"]), (False, []))
        verdict = next(target for target in summary["targets"] if target["id"] == "small/p99")
        self.assertEqual((verdict["verdict"], verdict["reason"]),
                         ("not measured", f"http-keep-alive@small@1000 was not run: {reason}"))
        recorded = json.loads((out / "conditions.json").read_text())["gke"]["profiles"]["small"]
        self.assertEqual(recorded["traffic_check"]["ports"]["tls"]["error"], "timed out")
        self.assertFalse(recorded["traffic_check"]["ok"])
        self.assertEqual(recorded["ended_early"]["not_measured"], steps)
        markdown = (out / "summary.md").read_text()
        self.assertIn("| small | e4a-standard-8 (arm64, us-central1-a) | e4a-standard-8 (arm64, us-central1-a) | 4 | "
                      "plain HTTP 200, TLS no answer (timed out) | 0 | yes |", markdown)

    def test_the_traffic_check_and_the_load_generators_cpu_request_are_recorded_for_each_profile(self):
        out = self.results([START, TRAFFIC_CHECK, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(generator_cpu="6"))
        summary = json.loads((out / "summary.json").read_text())
        conditions = json.loads((out / "conditions.json").read_text())
        for recorded in (summary["gke"]["profiles"]["small"], conditions["gke"]["profiles"]["small"]):
            self.assertEqual(recorded["traffic_check"], {key: value for key, value in TRAFFIC_CHECK.items()
                                                         if key not in ("kind", "profile")})
            self.assertIsNone(recorded["ended_early"])
            # As the Pod had it.
            self.assertEqual(recorded["generator_cpu_request"], "6")
        self.assertIn("| 6 | plain HTTP 200, TLS HTTP 200 | 0 | no |", (out / "summary.md").read_text())
        # From an earlier load generator, which checked nothing: unknown.
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}], pods())
        recorded = json.loads((out / "summary.json").read_text())["gke"]["profiles"]["small"]
        self.assertIsNone(recorded["traffic_check"])
        self.assertIn("| 4 | - | 0 | no |", (out / "summary.md").read_text())

    def test_a_smock_that_restarted_measures_no_oom_kills_and_the_summary_says_why(self):
        out = self.results([START, generator_step(500), generator_step(1000), {"kind": "done"}],
                           pods(restarts=1, reason="OOMKilled"))
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual({case["memory"]["oom_kills"] for case in summary["cases"]}, {None})
        verdict = next(target for target in summary["targets"] if target["id"] == "small/oom_kills")
        self.assertEqual(verdict["verdict"], "not measured")
        self.assertIn("smock restarted 1 time under small (last: OOMKilled)", (out / "summary.md").read_text())

    def test_smocks_restarts_read_before_the_profiles_end_measure_no_oom_kills(self):
        # The run stopped during the load generator's Job, and kept smock's
        # Pod as it was before the load, with its restarts unknown.
        out = self.results([START, IDLE, generator_step(500), generator_step(1000)], pods(restarts=None),
                           stopped=("--stopped", "stopped by SIGTERM", "--stopped-under", "small"))
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual({entry["memory"]["oom_kills"] for entry in [*summary["cases"], *summary["idle_rss"]]},
                         {None})
        verdict = next(target for target in summary["targets"] if target["id"] == "small/oom_kills")
        self.assertEqual(verdict["verdict"], "not measured")
        markdown = (out / "summary.md").read_text()
        # No traffic check, and smock's restarts unknown.
        self.assertIn("| 4 | - | - | no |", markdown)
        self.assertIn("smock's restarts under small are unknown, since the run did not read them at the profile's "
                      "end: its OOM kills are not measured.", markdown)
        self.assertNotIn("None", markdown)


class Estimate(Helper):
    """Before anything is made, a run says how long it takes and what it
    costs, expected and at most."""

    def estimate(self, *args, plan=BENCH / "plan-autopilot.json", region="us-central1", time_limit_s=4800,
                 arch="arm64"):
        return helper("estimate", "--plan", plan, "--region", region, "--arch", arch, "--time-limit-s", time_limit_s,
                      *args)

    def test_it_states_the_expected_cost_and_the_most_a_run_cut_off_at_the_time_limit_costs(self):
        status, stdout, stderr = self.estimate(time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for arm64 Pods (us-central1, on-demand prices of 2026-10-16, before tax", stdout)
        self.assertRegex(stdout, r"Expected: about \$0\.\d\d, the cluster existing for about \d+ minutes\.")
        # Until the watchdog deletes it at the time limit, and for the 5
        # minutes the deletion takes: the cluster's fee ($0.10 an hour), the
        # load generator (4 vCPU and 4Gi at $0.0445 and $0.0049225 an hour,
        # 2Gi of ephemeral storage at $0.0001389) and the largest smock (1
        # vCPU, 1Gi, 64Mi), $0.3474 an hour for 65 minutes.
        self.assertIn("At most: $0.38, if it ran until the time limit (60 minutes)", stdout)
        self.assertIn("Arm Pods are priced as x86 ones: autopilot-arm runs them on Autopilot's container-optimized "
                      "compute platform, which the pricing page bills at one rate for both architectures.", stdout)
        self.assertNotIn("Scale-Out", stdout)
        # What is billed when nothing is left to delete the cluster.
        self.assertIn("its Pods still stop within minutes of the time limit, and the cluster costs its fee, "
                      "$0.10 an hour", stdout)

    def test_x86_pods_in_tokyo_are_estimated_at_tokyos_prices(self):
        status, stdout, stderr = self.estimate(region="asia-northeast1", arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for amd64 (x86) Pods (asia-northeast1, on-demand prices of 2026-10-16", stdout)
        # The fee ($0.10 an hour), the load generator on amd64 (6 vCPU and
        # 6Gi at $0.0571 and $0.0063215 an hour, 2Gi of ephemeral storage at
        # $0.0001784) and the largest smock (1 vCPU, 1Gi, 64Mi): $0.5443 an
        # hour for 65 minutes.
        self.assertIn("At most: $0.59, if it ran until the time limit (60 minutes)", stdout)
        self.assertIn("The load generator's Pod (6 vCPU, 6Gi)", stdout)
        self.assertNotIn("Arm", stdout)

    def test_both_architectures_pods_are_estimated_at_the_same_rates_of_their_region(self):
        # amd64 in us-central1: the fee, the load generator (6 vCPU and 6Gi
        # at $0.0445 and $0.0049225 an hour, 2Gi of ephemeral storage at
        # $0.0001389) and the largest smock (1 vCPU, 1Gi, 64Mi): $0.4462 an
        # hour for 65 minutes, as before Arm Pods were priced apart.
        status, stdout, stderr = self.estimate(arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("Cost estimate for amd64 (x86) Pods (us-central1, on-demand prices of 2026-10-16", stdout)
        self.assertIn("At most: $0.48, if it ran until the time limit (60 minutes)", stdout)
        self.assertNotIn("Arm", stdout)
        # The same run on arm64 costs less only for its smaller load
        # generator (4 vCPU, 4Gi): $0.3474 an hour.
        _, stdout, _ = self.estimate(arch="arm64", time_limit_s=3600)
        self.assertIn("At most: $0.38, if it ran until the time limit (60 minutes)", stdout)
        # Every region with Arm Pods at its own rates, such as Singapore's:
        # the load generator at $0.0549 and $0.0060729 an hour, ephemeral
        # storage at $0.0001713, and the fee, $0.4052 an hour.
        for region in ("us-central1", "us-east1", "us-west1", "europe-west1", "europe-west2", "europe-west4",
                       "asia-southeast1"):
            _, stdout, _ = self.estimate(region=region, arch="arm64", time_limit_s=3600)
            self.assertIn(f"Cost estimate for arm64 Pods ({region}, on-demand prices of 2026-10-16", stdout)
            if region == "asia-southeast1":
                self.assertIn("At most: $0.44, if it ran until the time limit (60 minutes)", stdout)

    def test_a_region_without_prices_here_is_estimated_from_us_central1s_with_a_margin(self):
        # An amd64 run in Frankfurt: us-central1's Pod prices plus 30% and
        # the fee, $0.5501 an hour for 65 minutes.
        status, stdout, _ = self.estimate(region="europe-west3", arch="amd64", time_limit_s=3600)
        self.assertEqual(status, 0)
        self.assertIn("europe-west3: us-central1's prices plus 30%", stdout)
        self.assertIn("At most: $0.60, if it ran until the time limit (60 minutes)", stdout)

    def test_a_run_longer_than_the_time_limit_is_refused(self):
        status, stdout, stderr = self.estimate(time_limit_s=1200)
        self.assertEqual(status, 1)
        self.assertIn("more than the time limit of 20 minutes", stderr)

    def test_with_variants_each_ones_pod_and_runs_are_counted_and_the_images_they_need(self):
        # small_plan's one profile (250m, 512Mi: $0.01359493 an hour) and
        # two steps, 4 variants over 4 rounds on amd64 in us-central1: 32
        # runs of 25 s with 2 s between them (862 s), each analysed in about
        # 5 s and with 3 idle neighbours scraped before and after it in
        # about 0.1 s each (32 × 5.6 s), the 5 s settle and a minute to
        # start: the load generator's 1,106.2 s ($0.2968128 an hour). The
        # profile also waits 3 minutes for its first Pod and 30 s for each
        # other, 1,376.2 s for which its 4 smock Pods are billed; the
        # cluster exists 9 minutes more before it, and 5 after.
        plan = small_plan(self.directory())
        status, stdout, stderr = self.estimate("--variants", 4, "--rounds", 4, plan=plan, arch="amd64",
                                               time_limit_s=3600)
        self.assertEqual(status, 0, stderr)
        self.assertIn("- smock's Pods, one for each of 4 variants on one node, 1 profile one after the other: $0.02.",
                      stdout)
        self.assertIn("- The load generator's Pod (6 vCPU, 6Gi): about 18 minutes, $0.09.", stdout)
        self.assertIn("- Artifact Registry: up to 5 images of about 100 MB", stdout)
        self.assertIn("Expected: about $0.17, the cluster existing for about 37 minutes.", stdout)
        # The fee, the load generator and 4 smock Pods at the largest
        # profile's limits: $0.4511925 an hour for 65 minutes.
        self.assertIn("At most: $0.49, if it ran until the time limit (60 minutes)", stdout)
        status, _, stderr = self.estimate("--variants", 4, "--rounds", 4, plan=plan, arch="amd64", time_limit_s=1200)
        self.assertEqual(status, 1)
        self.assertIn("the run needs about 47 minutes with a margin, more than the time limit of 20 minutes: run "
                      "fewer profiles, cases, variants or rounds, or raise the limit", stderr)


class LocalSmock:
    """smock serving the benchmark's definitions on this machine, on free
    ports, as the GKE run's image does, and as in a container of its own
    under profile small's limits: in a systemd scope of its own, which
    only smock is in, with a CPU quota of 250m and a memory limit of
    512Mi, as bench/bench.py runs it. It becomes smock by exec."""

    SCOPE = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "-p", "CPUQuota=25%",
             "-p", f"MemoryMax={512 << 20}", "--"]

    def __enter__(self):
        self.process = subprocess.Popen(
            [*self.SCOPE, SMOCK, "serve", "--dir", str(BENCH / "definitions"), "--port", "0", "--tls-port", "0",
             "--admin-port", "0", "--admin-auth", "off"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True,
            env={name: value for name, value in os.environ.items() if not name.startswith("SMOCK_")})
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


class SilentPort:
    """A port on this machine that takes connections and answers nothing on
    them. With `answer_first`, it answers the first request it gets with an
    empty 200, then closes every connection unanswered: no response either,
    without oha waiting for its requests to time out."""

    def __init__(self, answer_first=False):
        self.answer_first = answer_first

    def __enter__(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        # Room for every connection of a step, never accepted.
        self.listener.listen(256)
        self.port = self.listener.getsockname()[1]
        if self.answer_first:
            threading.Thread(target=self.answer_first_only, daemon=True).start()
        return self

    def answer_first_only(self):
        connection, _ = self.listener.accept()
        with connection:
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                request += chunk
            connection.sendall(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            connection.close()

    def __exit__(self, *_):
        self.listener.close()


class Generator(Helper):
    """The load generator sends a profile's steps the way bench/bench.py
    does, and reports each as summarize reads it."""

    def generator_plan(self, rates=(200,)):
        """The small plan with short steps, at `rates`, over plain HTTP and
        then TLS."""
        plan = json.loads(small_plan(self.directory(), rates=rates).read_text())
        plan.update(ramp_s=0.5, duration_s=2, tail_s=1, cooldown_s=0, idle_rss={"settle_s": 0.5})
        plan["cases"].append({**plan["cases"][0], "name": "https-keep-alive", "protocol": "https"})
        path = self.directory() / "plan.json"
        path.write_text(json.dumps(plan))
        return path

    def generate(self, plan_path, smock, **ports):
        """Runs the load generator for profile small against `smock`, with
        `ports` instead of smock's own; returns its exit status, its JSON
        lines and its output."""
        environment = {**os.environ, "TARGET": "localhost", "PROFILE": "small",
                       "CASES": "http-keep-alive,https-keep-alive", "PLAN": str(plan_path),
                       "PLAIN_PORT": str(ports.get("plain", smock.ports["plain"])),
                       "TLS_PORT": str(ports.get("tls", smock.ports["tls"])),
                       "ADMIN_PORT": smock.ports["admin"], "OHA": shutil.which(OHA) or OHA, "TRAFFIC_CHECK_S": "2"}
        generator = subprocess.run([sys.executable, str(BENCH / "gke" / "generator.py")], env=environment,
                                   capture_output=True, text=True, timeout=120)
        lines = [json.loads(line) for line in generator.stdout.splitlines()]
        return generator.returncode, lines, generator.stdout + generator.stderr

    def summarize(self, plan_path, log):
        """summarize's summary and conditions of a run of profile small whose
        load generator wrote `log`."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        (raw / "generator.log").write_text(log)
        (raw / "pods.json").write_text(json.dumps(pods()))
        status, _, stderr = helper(
            "summarize", "--plan", plan_path, "--targets", small_targets(self.directory()), "--region", "us-central1",
            "--zone", "us-central1-a", "--arch", "arm64", "--started-at", "2026-10-14T03:28:50+00:00",
            "--finished-at", "2026-10-14T04:01:56+00:00", out)
        self.assertEqual(status, 0, stderr)
        return (json.loads((out / "summary.json").read_text()), json.loads((out / "conditions.json").read_text()),
                (out / "summary.md").read_text())

    def test_each_step_of_the_profile_is_reported_and_summarized_as_a_case(self):
        plan_path = self.generator_plan()
        with LocalSmock() as smock:
            status, lines, output = self.generate(plan_path, smock)
        self.assertEqual(status, 0, output)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "step", "step", "metrics-after",
                          "done"])
        self.assertRegex(lines[0]["status"]["digest"], "^[0-9a-f]{12}$")
        # The CPU of the load generator's node, this machine's here.
        self.assertIsNotNone(lines[0]["node_cpu"]["model_name"])
        self.assertIn("aes", lines[0]["node_cpu"]["flags"])
        # smock's idle RSS and peak memory, from its /metrics, before any
        # load.
        idle = lines[1]["idle"]
        self.assertEqual({key: idle[key] for key in ("profile", "cpu_limit", "memory_limit", "settle_s",
                                                     "smock_ready", "digest")},
                         {"profile": "small", "cpu_limit": "250m", "memory_limit": "512Mi", "settle_s": 0.5,
                          "smock_ready": True, "digest": lines[0]["status"]["digest"]})
        self.assertGreater(idle["rss_kib"], 1024)
        self.assertGreater(idle["memory"]["peak_bytes"], 0)
        # Both traffic ports answered the first request of the mix before
        # the first step.
        check = lines[2]
        self.assertTrue(check["ok"], check)
        self.assertEqual((check["host"], check["target"]), ("catalog.bench.internal", "/catalog/items/SKU-00317"))
        for port in ("plain", "tls"):
            self.assertEqual((check["ports"][port]["answered"], check["ports"][port]["status"]), (True, 200))
        for step, protocol in zip([line["result"] for line in lines if line["kind"] == "step"], ("http", "https")):
            self.assertEqual((step["profile"], step["protocol"], step["rate"]), ("small", protocol, 200))
            self.assertEqual((step["errors"], step["smock_ready"]), (0, True))
            self.assertEqual(step["requests"]["ok"], step["requests"]["scheduled"])
            self.assertGreater(step["requests"]["scheduled"], 350)
            self.assertIsNotNone(step["latency_ms"]["p99_9"])
            self.assertEqual(len(step["per_request"]), 9)
            self.assert_smock_use(step)

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertTrue(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]], ["http-keep-alive@small", "https-keep-alive@small"])
        # smock never restarted, so the kernel never OOM-killed it.
        self.assertEqual(summary["idle_rss"], [{**idle, "memory": {**idle["memory"], "oom_kills": 0}}])
        verdict = next(target for target in summary["targets"] if target["id"] == "small/idle_rss")
        self.assertEqual((verdict["verdict"] in ("met", "missed"), verdict["measured"]),
                         (True, round(idle["rss_kib"] / 1024, 2)))
        self.assertIn(f"Idle RSS: {idle['rss_kib'] / 1024:.1f} MiB, 0.5 s after startup", markdown)
        self.assertTrue(conditions["gke"]["profiles"]["small"]["traffic_check"]["ok"])
        self.assertIsNone(conditions["gke"]["profiles"]["small"]["ended_early"])

    def assert_smock_use(self, step):
        """What a step says smock used, from its /metrics around the step,
        is what the cgroup of smock's scope, which holds only smock, and
        its process counted: its CPU time, throttling, RSS and peak
        memory, and the requests it answered."""
        cpu = step["smock_cpu"]
        self.assertEqual(cpu["source"], "cgroup", step["id"])
        # Every request of the step's load, ramp and tail included, and
        # none other: at most the rate for the whole load from each oha.
        total_s = step["ramp_s"] + step["duration_s"] + step["tail_s"]
        self.assertGreaterEqual(cpu["requests"], step["requests"]["ok"])
        self.assertLessEqual(cpu["requests"], step["rate"] * total_s + len(step["per_request"]))
        self.assertGreaterEqual(cpu["wall_s"], total_s)
        self.assertLess(cpu["wall_s"], total_s + 30)
        self.assertAlmostEqual(cpu["us_per_request"], cpu["usage_s"] * 1e6 / cpu["requests"],
                               delta=0.0005 * 1e6 / cpu["requests"] + 0.01)
        self.assertAlmostEqual(cpu["utilization"], cpu["usage_s"] / (cpu["wall_s"] * 0.25), delta=0.01)
        self.assertGreater(cpu["usage_s"], 0)
        self.assertLessEqual(cpu["utilization"], 1.05)
        # The process's CPU time, in ticks of 1/100 s, is the cgroup's.
        self.assertAlmostEqual(cpu["process_s"], cpu["usage_s"], delta=0.03)
        self.assertGreater(cpu["periods"], 0)
        self.assertGreaterEqual(cpu["throttled_periods"], 0)
        self.assertGreaterEqual(cpu["throttled_s"], 0)
        # How long smock waited for a CPU, from its /metrics: on this
        # machine, which is no virtual machine, no steal.
        self.assertGreaterEqual(cpu["scheduling_delay_s"], 0)
        self.assertGreaterEqual(cpu["involuntary_context_switches"], 0)
        self.assertGreaterEqual(cpu["node_steal_s"], 0)
        # What smock used in the step's first second, from a scrape a
        # second into the load, in the same layout: some of the requests,
        # and some of the CPU time.
        first = cpu["first_second"]
        self.assertEqual(first["source"], "cgroup")
        self.assertGreaterEqual(first["wall_s"], 1)
        self.assertLess(first["wall_s"], 3)
        self.assertGreater(first["requests"], 0)
        self.assertLess(first["requests"], cpu["requests"])
        self.assertGreater(first["usage_s"], 0)
        self.assertLessEqual(first["usage_s"], cpu["usage_s"])
        self.assertIsNotNone(first["scheduling_delay_s"])
        # Each second of the load, ramp and tail included (3.5 s), with the
        # requests due in it that got a response.
        seconds = step["per_second"]
        self.assertEqual(len(seconds["requests"]), 4)
        self.assertGreaterEqual(sum(seconds["requests"]), step["requests"]["ok"])
        self.assertEqual([p99 is None for p99 in seconds["p99_ms"]], [count == 0 for count in seconds["requests"]])
        rss = step["rss_kib"]
        self.assertGreater(rss["first"], 1024)
        self.assertEqual(rss["max"], max(rss["first"], rss["last"]))
        self.assertGreater(step["memory"]["peak_bytes"], 0)

    def test_a_traffic_port_that_never_answers_stops_the_profile_before_its_first_step(self):
        # As smock's Service did under autopilot-min: connections open, and
        # no request gets a response.
        plan_path = self.generator_plan()
        with LocalSmock() as smock, SilentPort() as silent:
            started = time.monotonic()
            status, lines, output = self.generate(plan_path, smock, tls=silent.port)
        self.assertEqual(status, 0, output)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "stopped", "metrics-after", "done"])
        check = lines[2]
        self.assertFalse(check["ok"])
        self.assertEqual((check["ports"]["plain"]["answered"], check["ports"]["plain"]["status"]), (True, 200))
        self.assertEqual((check["ports"]["tls"]["answered"], check["ports"]["tls"]["port"]), (False, silent.port))
        self.assertEqual(check["ports"]["tls"]["error"], "timed out")
        stopped = lines[4]
        self.assertEqual(stopped["reason"], f"smock did not answer through its Service in 2 s: TLS port {silent.port} "
                                            "(timed out)")
        self.assertEqual((stopped["after"], stopped["steps"]),
                         (None, ["http-keep-alive@small", "https-keep-alive@small"]))

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertEqual((summary["complete"], summary["cases"]), (False, []))
        self.assertEqual(conditions["gke"]["profiles"]["small"]["ended_early"]["not_measured"],
                         ["http-keep-alive@small", "https-keep-alive@small"])
        self.assertIn(f"small ended early: {stopped['reason']}.", markdown)

    def test_a_step_with_no_response_at_all_stops_the_profiles_remaining_steps_when_smock_is_gone(self):
        # The plain port answers the traffic check, then hangs up on every
        # connection: the step and the check after it get no response.
        plan_path = self.generator_plan()
        with LocalSmock() as smock, SilentPort(answer_first=True) as gate:
            status, lines, output = self.generate(plan_path, smock, plain=gate.port)
        self.assertEqual(status, 0, output)
        self.assertEqual([line["kind"] for line in lines],
                         ["start", "idle-rss", "traffic-check", "metrics-before", "step", "traffic-check", "stopped",
                          "metrics-after", "done"])
        self.assertTrue(lines[2]["ok"], lines[2])
        self.assertEqual(lines[2]["address"], "127.0.0.1")
        step = lines[4]["result"]
        self.assertEqual((step["id"], step["requests"]["ok"]), ("http-keep-alive@small", 0))
        self.assertEqual(step["requests"]["no_response"], step["requests"]["scheduled"])
        # smock itself was there, and answered none of the step's
        # requests, which went elsewhere: no CPU time a request.
        self.assertEqual((step["smock_cpu"]["requests"], step["smock_cpu"]["us_per_request"]), (0, None))
        check = lines[5]
        self.assertEqual((check["after"], check["ok"], check["ports"]["plain"]["answered"]),
                         ("http-keep-alive@small", False, False))
        self.assertEqual(check["resolves_now"], "127.0.0.1")
        stopped = lines[6]
        self.assertRegex(stopped["reason"], r"^http-keep-alive@small got no response to any of its \d+ requests")
        self.assertIn(f", and smock did not answer through its Service in 2 s after it: plain port {gate.port} (",
                      stopped["reason"])
        self.assertEqual((stopped["after"], stopped["steps"]), ("http-keep-alive@small", ["https-keep-alive@small"]))

        summary, conditions, markdown = self.summarize(plan_path, output)
        self.assertFalse(summary["complete"])
        self.assertEqual([case["id"] for case in summary["cases"]], ["http-keep-alive@small"])
        self.assertEqual(summary["gke"]["profiles"]["small"]["ended_early"],
                         {"reason": stopped["reason"], "after": "http-keep-alive@small",
                          "not_measured": ["https-keep-alive@small"]})
        self.assertIn("Not measured: https-keep-alive@small.", markdown)


STEP_IDS = ["http-keep-alive@small", "https-keep-alive@small"]


def generate_variants(plan_path, variants, rounds):
    """Runs the load generator for profile small against several smocks on
    this machine as variants, `variants` [(label, smock, first_second,
    ports instead of smock's own)], for `rounds` rounds; returns its exit
    status, its JSON lines and its output."""
    entries = [{"label": label, "target": "localhost", "first_second": first_second,
                "plain_port": int(ports.get("plain", smock.ports["plain"])),
                "tls_port": int(ports.get("tls", smock.ports["tls"])), "admin_port": int(smock.ports["admin"])}
               for label, smock, first_second, ports in variants]
    environment = {**{name: value for name, value in os.environ.items() if name != "TARGET"},
                   "VARIANTS": json.dumps(entries), "ROUNDS": str(rounds), "PROFILE": "small",
                   "CASES": "http-keep-alive,https-keep-alive", "PLAN": str(plan_path),
                   "OHA": shutil.which(OHA) or OHA, "TRAFFIC_CHECK_S": "2"}
    generator = subprocess.run([sys.executable, str(BENCH / "gke" / "generator.py")], env=environment,
                               capture_output=True, text=True, timeout=240)
    lines = [json.loads(line) for line in generator.stdout.splitlines()]
    return generator.returncode, lines, generator.stdout + generator.stderr


class GeneratorWithVariants(Helper):
    """With variants, smocks kept on one node, the load generator runs each
    step of the profile against each variant in turn, one at a time, the
    variants' order turned for each round and each step, and tags every
    line about smock with its variant. It runs here against two smocks on
    this machine, a and b, for two rounds; b skips the scrape a second
    into each step."""

    generator_plan = Generator.generator_plan
    summarize = Generator.summarize

    @classmethod
    def setUpClass(cls):
        directory = Path(tempfile.mkdtemp(prefix="smock-gke-test-"))
        cls.addClassCleanup(shutil.rmtree, directory, ignore_errors=True)
        cls.plan_path = Generator.generator_plan(SimpleNamespace(directory=lambda: directory))
        with LocalSmock() as a, LocalSmock() as b:
            cls.status, cls.lines, cls.output = generate_variants(cls.plan_path, [("a", a, True, {}),
                                                                                  ("b", b, False, {})], 2)

    def test_each_step_runs_each_variant_in_turn_in_the_turned_order_and_every_line_is_tagged(self):
        self.assertEqual(self.status, 0, self.output)
        order = [(1, STEP_IDS[0], "a"), (1, STEP_IDS[0], "b"), (1, STEP_IDS[1], "b"), (1, STEP_IDS[1], "a"),
                 (2, STEP_IDS[0], "b"), (2, STEP_IDS[0], "a"), (2, STEP_IDS[1], "a"), (2, STEP_IDS[1], "b")]
        self.assertEqual([(line["kind"], line.get("variant")) for line in self.lines],
                         [("start", "a"), ("start", "b"), ("idle-rss", "a"), ("idle-rss", "b"),
                          ("traffic-check", "a"), ("traffic-check", "b"), ("metrics-before", "a"),
                          ("metrics-before", "b"), *[("step", variant) for _, _, variant in order],
                          ("metrics-after", "a"), ("metrics-after", "b"), ("done", "a"), ("done", "b")])
        self.assertEqual([(line["round"], line["result"]["id"], line["variant"])
                          for line in self.lines if line["kind"] == "step"], order)
        starts = [line for line in self.lines if line["kind"] == "start"]
        self.assertEqual([(start["address"], start["first_second"]) for start in starts],
                         [("127.0.0.1", True), ("127.0.0.1", False)])
        for start in starts:
            self.assertRegex(start["status"]["digest"], "^[0-9a-f]{12}$")
        for check in (line for line in self.lines if line["kind"] == "traffic-check"):
            self.assertTrue(check["ok"], check)
        # Each variant's own smock answered the load of its runs.
        for step in (line["result"] for line in self.lines if line["kind"] == "step"):
            self.assertEqual((step["errors"], step["smock_ready"]), (0, True))
            self.assertGreaterEqual(step["smock_cpu"]["requests"], step["requests"]["ok"])

    def test_a_variant_that_skips_the_scrape_a_second_into_each_step_records_no_first_second(self):
        for line in (line for line in self.lines if line["kind"] == "step"):
            cpu = line["result"]["smock_cpu"]
            self.assertGreater(cpu["usage_s"], 0)
            if line["variant"] == "a":
                self.assertGreaterEqual(cpu["first_second"]["wall_s"], 1)
                self.assertGreater(cpu["first_second"]["requests"], 0)
            else:
                self.assertIn("first_second", cpu)
                self.assertIsNone(cpu["first_second"])

    def test_each_run_records_what_the_idle_variant_used_meanwhile_and_the_nodes_steal_time(self):
        for line in (line for line in self.lines if line["kind"] == "step"):
            idle = "b" if line["variant"] == "a" else "a"
            self.assertEqual(list(line["neighbours"]), [idle])
            # An idle smock, scraped around the run: far less CPU than the
            # one under load.
            self.assertGreaterEqual(line["neighbours"][idle], 0)
            self.assertLess(line["neighbours"][idle], line["result"]["smock_cpu"]["usage_s"])
            # Each variant's count of the node's steal time, the loaded
            # one's from its own scrapes: none here, on no virtual machine.
            self.assertEqual(line["node_steal_s"], {"a": 0.0, "b": 0.0})
            self.assertEqual(line["node_steal_s"][line["variant"]], line["result"]["smock_cpu"]["node_steal_s"])

    def split(self):
        """What the load generator printed, kept as the runner keeps it
        with the variants' Pods, split by gke.py samples: the results
        directory, and the samples' rounds and labels as it printed them."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        (raw / "generator.log").write_text(self.output)
        (raw / "pods.json").write_text(json.dumps(variant_pods(["a", "b"])))
        status, stdout, stderr = helper("samples", out, "--plan", self.plan_path)
        self.assertEqual(status, 0, stderr)
        return out, [line.split(" ")[:2] for line in stdout.splitlines()]

    def summarize_sample(self, directory):
        """summarize over a sample's directory, as the runner calls it."""
        status, _, stderr = helper(
            "summarize", "--plan", self.plan_path, "--targets", small_targets(self.directory()), "--region",
            "us-central1", "--arch", "arm64", "--started-at", "2026-10-16T03:28:50+00:00", "--finished-at",
            "2026-10-16T03:31:02+00:00", directory)
        self.assertEqual(status, 0, stderr)

    def test_each_round_of_each_variant_splits_out_as_an_ordinary_run_that_summarizes_as_complete(self):
        out, samples = self.split()
        self.assertEqual(samples, [["1", "a"], ["1", "b"], ["2", "a"], ["2", "b"]])
        for round_, label in ((1, "a"), (2, "b")):
            directory = out / "samples" / f"{round_}-{label}"
            self.summarize_sample(directory)
            summary = json.loads((directory / "summary.json").read_text())
            conditions = json.loads((directory / "conditions.json").read_text())
            self.assertTrue(summary["complete"], (round_, label))
            self.assertEqual([case["id"] for case in summary["cases"]], STEP_IDS)
            self.assertEqual([case["smock_cpu"]["first_second"] is None for case in summary["cases"]],
                             [label == "b"] * 2)
            self.assertEqual([idle["memory"]["oom_kills"] for idle in summary["idle_rss"]], [0] if round_ == 1 else [])
            self.assertTrue(conditions["gke"]["profiles"]["small"]["traffic_check"]["ok"])
            start = next(line for line in self.lines if line["kind"] == "start" and line["variant"] == label)
            self.assertEqual(conditions["smock"]["commit"], start["status"]["commit"])

    def test_same_node_compares_the_variants_from_what_the_load_generator_printed(self):
        out, samples = self.split()
        for round_, label in samples:
            self.summarize_sample(out / "samples" / f"{round_}-{label}")
        status, _, stderr = helper("same-node", out)
        self.assertEqual(status, 0, stderr)
        report = json.loads((out / "same-node.json").read_text())
        profile = report["gke"]["profiles"]["small"]
        self.assertTrue(profile["complete"])
        self.assertEqual([(entry["round"], entry["id"], entry["variants"]) for entry in profile["order"]],
                         [(1, STEP_IDS[0], ["a", "b"]), (1, STEP_IDS[1], ["b", "a"]), (2, STEP_IDS[0], ["b", "a"]),
                          (2, STEP_IDS[1], ["a", "b"])])
        self.assertEqual(profile["positions"], {"a": [2, 2], "b": [2, 2]})
        # Each variant's run of each step in each round counts, or is listed
        # with why not, as when the load generator fell behind on this
        # machine; b has a pair with a in each round in which both count.
        unmeasured = {(entry["id"], entry["variant"], entry["round"]) for entry in profile["not_measured"]}
        for step in profile["steps"]:
            for label in ("a", "b"):
                self.assertEqual(step["variants"][label]["n"],
                                 2 - sum((step["id"], label, round_) in unmeasured for round_ in (1, 2)))
            self.assertEqual([pair["round"] for pair in step["variants"]["b"]["pairs"]],
                             [round_ for round_ in (1, 2) if not {(step["id"], "a", round_),
                                                                  (step["id"], "b", round_)} & unmeasured])
        self.assertIsNotNone(profile["neighbours"])
        self.assertEqual([variant["options"] for variant in report["variants"]], [[], ["no-first-second"]])


class VariantsStopTogether(Helper):
    """When a variant stops the profile, as one smock alone does, every
    variant stops, so that each run left has the others' to compare with,
    and the stopped line says which variant stopped it and which runs were
    left out."""

    generator_plan = Generator.generator_plan

    def test_a_variant_that_never_answers_stops_every_variant_before_the_first_run(self):
        plan_path = self.generator_plan()
        with LocalSmock() as a, LocalSmock() as b, SilentPort() as silent:
            status, lines, output = generate_variants(plan_path, [("a", a, True, {}),
                                                                  ("b", b, True, {"tls": silent.port})], 2)
        self.assertEqual(status, 0, output)
        self.assertEqual([(line["kind"], line.get("variant")) for line in lines],
                         [("start", "a"), ("start", "b"), ("idle-rss", "a"), ("idle-rss", "b"),
                          ("traffic-check", "a"), ("traffic-check", "b"), ("metrics-before", "a"),
                          ("metrics-before", "b"), ("stopped", "b"), ("metrics-after", "a"), ("metrics-after", "b"),
                          ("done", "a"), ("done", "b")])
        self.assertEqual([line["ok"] for line in lines if line["kind"] == "traffic-check"], [True, False])
        stopped = lines[8]
        self.assertEqual(stopped["reason"], f"variant b: smock did not answer through its Service in 2 s: TLS port "
                                            f"{silent.port} (timed out)")
        self.assertEqual((stopped["round"], stopped["after"]), (None, None))
        self.assertEqual(stopped["runs"],
                         [{"round": 1, "variant": "a", "id": STEP_IDS[0]}, {"round": 1, "variant": "b", "id": STEP_IDS[0]},
                          {"round": 1, "variant": "b", "id": STEP_IDS[1]}, {"round": 1, "variant": "a", "id": STEP_IDS[1]},
                          {"round": 2, "variant": "b", "id": STEP_IDS[0]}, {"round": 2, "variant": "a", "id": STEP_IDS[0]},
                          {"round": 2, "variant": "a", "id": STEP_IDS[1]}, {"round": 2, "variant": "b", "id": STEP_IDS[1]}])

    def test_a_run_with_no_response_from_a_variant_that_is_gone_stops_every_variant(self):
        # b's plain port answers its traffic check, then hangs up on every
        # connection: b's first run and the check after it get no response.
        plan_path = self.generator_plan()
        with LocalSmock() as a, LocalSmock() as b, SilentPort(answer_first=True) as gate:
            status, lines, output = generate_variants(plan_path, [("a", a, True, {}),
                                                                  ("b", b, True, {"plain": gate.port})], 2)
        self.assertEqual(status, 0, output)
        self.assertEqual([(line["kind"], line.get("variant")) for line in lines],
                         [("start", "a"), ("start", "b"), ("idle-rss", "a"), ("idle-rss", "b"),
                          ("traffic-check", "a"), ("traffic-check", "b"), ("metrics-before", "a"),
                          ("metrics-before", "b"), ("step", "a"), ("step", "b"), ("traffic-check", "b"),
                          ("stopped", "b"), ("metrics-after", "a"), ("metrics-after", "b"), ("done", "a"),
                          ("done", "b")])
        self.assertEqual(lines[8]["result"]["requests"]["ok"], lines[8]["result"]["requests"]["scheduled"])
        self.assertEqual(lines[9]["result"]["requests"]["ok"], 0)
        check = lines[10]
        self.assertEqual((check["round"], check["after"], check["ok"]), (1, STEP_IDS[0], False))
        stopped = lines[11]
        self.assertRegex(stopped["reason"], r"^variant b, round 1: http-keep-alive@small got no response to any of "
                                            r"its \d+ requests")
        self.assertEqual((stopped["round"], stopped["after"]), (1, STEP_IDS[0]))
        self.assertEqual(stopped["runs"],
                         [{"round": 1, "variant": "b", "id": STEP_IDS[1]}, {"round": 1, "variant": "a", "id": STEP_IDS[1]},
                          {"round": 2, "variant": "b", "id": STEP_IDS[0]}, {"round": 2, "variant": "a", "id": STEP_IDS[0]},
                          {"round": 2, "variant": "a", "id": STEP_IDS[1]}, {"round": 2, "variant": "b", "id": STEP_IDS[1]}])



def load_generator_module():
    """bench/gke/generator.py as a module, for its functions."""
    spec = importlib.util.spec_from_file_location("generator", BENCH / "gke" / "generator.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def no_response_step(step_id, scheduled=12500, ok=0, errors=None):
    """A step's result as the load generator reports it, with `ok` of its
    `scheduled` requests answered and the others not."""
    return {"id": step_id, "smock_ready": True,
            "requests": {"scheduled": scheduled, "ok": ok, "unexpected_status": 0, "no_response": scheduled - ok},
            "per_request": [{"oha_errors": errors or {}}]}


def check_result(ok, address="34.118.229.110", resolves_now=None):
    """A traffic check's result: both ports answered, or the TLS port did
    not."""
    tls = ({"port": 443, "answered": True, "status": 200, "attempts": 1, "seconds": 0.01, "error": None} if ok
           else {"port": 443, "answered": False, "status": None, "attempts": 12, "seconds": 60.1, "error": "timed out"})
    return {"ok": ok, "address": address, **({} if ok else {"resolves_now": resolves_now or address}),
            "host": "catalog.bench.internal", "method": "GET", "target": "/catalog/items/SKU-00317", "window_s": 60,
            "ports": {"plain": {"port": 80, "answered": True, "status": 200, "attempts": 1, "seconds": 0.01,
                                "error": None}, "tls": tls}}


class StopAfterAStep(unittest.TestCase):
    """A step with no response stops the rest of its profile only when
    smock does not answer a traffic check right after it: an overloaded
    smock can answer none of a step's measured requests, busy with those of
    its ramp until the step ends (https-keep-alive@autopilot-burst-min@4000
    answered 1,271 of 80,000 on 2026-10-14), and still be there."""

    generator = load_generator_module()
    spec = {"id": "http-keep-alive@autopilot-min@4000"}
    later = [{"id": "https-keep-alive@autopilot-min@625"}, {"id": "https-keep-alive@autopilot-min@1250"}]

    def stop_after(self, result, later, check):
        checks = []

        def check_again():
            checks.append(check)
            return check

        stopped, made = self.generator.stop_after(self.spec, result, later, check_again)
        return stopped, made, len(checks)

    def test_an_overloaded_smock_that_still_answers_goes_on(self):
        stopped, check, checks = self.stop_after(no_response_step(self.spec["id"]), self.later, check_result(True))
        self.assertIsNone(stopped)
        self.assertEqual((check["ok"], checks), (True, 1))

    def test_a_smock_that_does_not_answer_after_the_step_stops_the_rest(self):
        stopped, check, _ = self.stop_after(no_response_step(self.spec["id"], errors={"timeout": 12500}),
                                            self.later, check_result(False))
        self.assertFalse(check["ok"])
        self.assertEqual(stopped["reason"],
                         "http-keep-alive@autopilot-min@4000 got no response to any of its 12,500 requests "
                         "(oha: timeout), and smock did not answer through its Service in 60 s after it: "
                         "TLS port 443 (timed out)")
        self.assertEqual((stopped["after"], stopped["steps"]),
                         (self.spec["id"], ["https-keep-alive@autopilot-min@625", "https-keep-alive@autopilot-min@1250"]))

    def test_a_name_that_now_resolves_elsewhere_is_named(self):
        stopped, _, _ = self.stop_after(no_response_step(self.spec["id"]), self.later,
                                        check_result(False, resolves_now="34.118.228.162"))
        self.assertTrue(stopped["reason"].endswith("; the address checked was 34.118.229.110, and smock's name now "
                                                   "resolves to 34.118.228.162"), stopped["reason"])

    def test_a_step_with_a_response_or_the_last_step_checks_nothing(self):
        for result, later in ((no_response_step(self.spec["id"], ok=1), self.later),
                              (no_response_step(self.spec["id"]), [])):
            self.assertEqual(self.stop_after(result, later, check_result(False)), (None, None, 0))


class RunOrder(unittest.TestCase):
    """With variants, the load generator runs rounds outer, the steps of the
    profile in the middle and the variants inner, one at a time, the
    variants' order turned by one for each round and each step: the runs
    compared with each other come right after one another, and each
    variant runs first as often as the others."""

    generator = load_generator_module()

    def order(self, steps, variants, rounds):
        return [(round_, spec["id"], variant)
                for round_, spec, variant in self.generator.run_order([{"id": step} for step in steps], variants,
                                                                      rounds)]

    def test_with_two_variants_each_step_runs_them_ab_ba_ab_ba_over_four_rounds(self):
        runs = self.order(["s1"], ["a", "b"], 4)
        self.assertEqual(runs, [(1, "s1", "a"), (1, "s1", "b"), (2, "s1", "b"), (2, "s1", "a"),
                                (3, "s1", "a"), (3, "s1", "b"), (4, "s1", "b"), (4, "s1", "a")])

    def test_the_order_turns_by_one_with_each_round_and_each_step_the_baseline_first(self):
        runs = self.order(["s1", "s2"], ["a", "b", "c"], 3)
        self.assertEqual([variant for _, _, variant in runs],
                         ["a", "b", "c", "b", "c", "a",
                          "b", "c", "a", "c", "a", "b",
                          "c", "a", "b", "a", "b", "c"])
        self.assertEqual([(round_, step) for round_, step, _ in runs][::3],
                         [(1, "s1"), (1, "s2"), (2, "s1"), (2, "s2"), (3, "s1"), (3, "s2")])

    def test_without_variants_the_steps_run_once_in_the_plans_order(self):
        self.assertEqual(self.order(["s1", "s2"], [None], 1), [(1, "s1", None), (1, "s2", None)])


def old_smock_metrics(cpu_s, start=1760000000.0):
    """A scrape of the /metrics of smock at 0d984c8 (as metric_values reads
    it), which has its process and cgroup metrics but none of the waits
    for a CPU or its node's steal time, added in 5fb5a85."""
    return {"process_start_time_seconds": start, "process_cpu_seconds_total": round(cpu_s, 2),
            "process_resident_memory_bytes": 9 << 20, "smock_cgroup_cpu_usage_seconds_total": cpu_s,
            "smock_cgroup_cpu_periods_total": 40.0, "smock_cgroup_cpu_throttled_periods_total": 0.0,
            "smock_cgroup_cpu_throttled_seconds_total": 0.0, "smock_cgroup_memory_peak_bytes": 12 << 20,
            "smock_requests_total": 3.0}


class NeighbourGuard(unittest.TestCase):
    """Around each run, the load generator scrapes the variants left idle,
    for what they used meanwhile on the node they share with the loaded
    one: their CPU time, and the node's steal time as each counts it. A
    smock too old to count something leaves it unknown, never stops the
    run."""

    generator = load_generator_module()

    def test_an_idle_variants_cpu_comes_from_its_cgroup_and_an_old_smock_has_no_steal(self):
        self.assertEqual(self.generator.idle_use(old_smock_metrics(1.25), old_smock_metrics(1.263)), (0.013, None))

    def test_a_smock_that_counts_steal_time_says_the_nodes(self):
        before, after = old_smock_metrics(1.25), old_smock_metrics(1.263)
        before["smock_node_cpu_steal_seconds_total"], after["smock_node_cpu_steal_seconds_total"] = 30.0, 30.5
        self.assertEqual(self.generator.idle_use(before, after), (0.013, 0.5))

    def test_a_scrape_without_an_answer_or_a_restart_between_them_leaves_both_unknown(self):
        for before, after in ((None, old_smock_metrics(1.0)), (old_smock_metrics(1.0), None),
                              (old_smock_metrics(1.0), old_smock_metrics(0.1, start=1760000500.0))):
            self.assertEqual(self.generator.idle_use(before, after), (None, None))


def elf_header(machine, elf_class=2, data=1, elf_type=2):
    """The first 20 bytes of an ELF file: its identification, type and
    machine."""
    order = "<" if data == 1 else ">"
    return b"\x7fELF" + bytes([elf_class, data, 1]) + bytes(9) + struct.pack(order + "HH", elf_type, machine)


class BinaryArchitecture(Helper):
    """A binary that goes into an image is checked for the run's
    architecture before anything is made, by its ELF header: a binary of
    another architecture is not run to find out."""

    def arch_of(self, content):
        path = self.directory() / "binary"
        path.write_bytes(content + bytes(64))
        return helper("elf-arch", path)

    def test_the_architecture_is_read_from_the_elf_header(self):
        for machine, arch in ((62, "amd64"), (183, "arm64")):
            for elf_type in (2, 3):  # an executable, a position-independent one
                status, stdout, stderr = self.arch_of(elf_header(machine, elf_type=elf_type))
                self.assertEqual((status, stdout), (0, f"{arch}\n"), stderr)
        # This machine's python3, whatever it runs on.
        status, stdout, _ = helper("elf-arch", Path(sys.executable).resolve())
        self.assertEqual((status, stdout.strip()), (0, {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()]))

    def test_what_is_not_a_64_bit_executable_of_either_architecture_is_refused(self):
        for content, expected in ((b"#!/bin/sh\necho smock\n", "not an ELF file"),
                                  (b"PK\x03\x04", "not an ELF file"),
                                  (b"\x7fEL", "not an ELF file"),
                                  (elf_header(40, elf_class=1), "not a 64-bit little-endian ELF file"),
                                  (elf_header(62, data=2), "not a 64-bit little-endian ELF file"),
                                  (elf_header(62, elf_type=1), "not an executable"),
                                  (elf_header(243), "machine 243, neither amd64 nor arm64")):
            status, stdout, stderr = self.arch_of(content)
            self.assertEqual((status, stdout), (1, ""), content)
            self.assertIn(expected, stderr)
        status, _, stderr = helper("elf-arch", self.directory() / "missing")
        self.assertEqual(status, 1)
        self.assertIn("cannot read", stderr)


class BuildCommit(Helper):
    """A smock binary that this machine cannot run is checked to be built
    from the commit checked out by its build information, which holds the
    commit that `smock --version` says."""

    def names(self, content, commit="0123456789ab"):
        path = self.directory() / "smock"
        path.write_bytes(elf_header(62) + bytes(64) + content + bytes(16))
        return helper("names-commit", path, commit)

    def test_the_commit_is_found_as_a_native_moonbit_build_keeps_it(self):
        for content in ("0123456789ab".encode("utf-16-le"), b"0123456789ab"):
            status, _, stderr = self.names(content)
            self.assertEqual(status, 0, stderr)
        # A release binary built here, which says its commit when run.
        version = subprocess.run([SMOCK, "--version"], capture_output=True, text=True, check=True).stdout
        commit = version.split("(commit ", 1)[1].split(",", 1)[0]
        status, _, stderr = helper("names-commit", SMOCK, commit)
        self.assertEqual(status, 0, stderr)

    def test_a_binary_of_another_commit_is_refused(self):
        status, _, stderr = self.names("ba988d7938dc".encode("utf-16-le"))
        self.assertEqual(status, 1)
        self.assertIn("does not name commit 0123456789ab in its build information", stderr)
        status, _, stderr = helper("names-commit", self.directory() / "missing", "0123456789ab")
        self.assertEqual(status, 1)
        self.assertIn("cannot read", stderr)


class Dockerfiles(Helper):
    """The images are built for the run's architecture, which may not be
    this machine's: a RUN instruction would need emulation, which this
    machine may not have, so the Dockerfiles may only copy."""

    DOCKERFILES = (ROOT / "Dockerfile", BENCH / "gke" / "smock-definitions.dockerfile",
                   BENCH / "gke" / "generator.Dockerfile")

    def check(self, text):
        path = self.directory() / "Dockerfile"
        path.write_text(text)
        return helper("check-dockerfiles", path)

    def test_the_images_dockerfiles_have_no_run_instruction(self):
        status, _, stderr = helper("check-dockerfiles", *self.DOCKERFILES)
        self.assertEqual(status, 0, stderr)

    def test_a_run_instruction_in_any_form_is_refused_with_its_line(self):
        for text, line in (("FROM scratch\nRUN true\n", 2),
                           ("FROM scratch\n  run apk add curl\n", 2),
                           ("FROM scratch\nCOPY a /a\nRUN set -e; \\\n  make\n", 3),
                           ("FROM scratch\nONBUILD RUN true\n", 2),
                           ("# escape=`\nFROM scratch\nCOPY a `\n  /a\nRUN true\n", 5)):
            status, _, stderr = self.check(text)
            self.assertEqual(status, 1, text)
            self.assertIn(f"Dockerfile:{line}: ", stderr)
            self.assertIn("RUN", stderr)

    def test_run_in_a_comment_or_in_another_instructions_arguments_is_no_instruction(self):
        status, _, stderr = self.check("# RUN apt-get install curl\nFROM scratch\nLABEL note=\"RUN nothing\"\n"
                                       "COPY a \\\n  # a comment in the middle\n  RUN /b\n")
        self.assertEqual(status, 0, stderr)

    def test_the_load_generators_image_runs_gke_py_and_the_generator_with_the_files_it_holds(self):
        # The build context of the load generator's image (build_images in
        # scripts/gke-bench.sh), whose Pods run gke.py node-cpu and the
        # load generator: nothing of bench/ else, such as compare.py, which
        # gke.py loads only for same-node.
        image = self.directory() / "bench"
        (image / "gke").mkdir(parents=True)
        for path in ("bench.py", "requests.json", "gke/gke.py", "gke/generator.py"):
            shutil.copyfile(BENCH / path, image / path)
        shutil.copyfile(BENCH / "plan-autopilot.json", image / "plan.json")
        load = ("import importlib.util, sys; spec = importlib.util.spec_from_file_location('generator', sys.argv[1]); "
                "spec.loader.exec_module(importlib.util.module_from_spec(spec))")
        for command in ([image / "gke" / "gke.py", "node-cpu"], [image / "gke" / "gke.py", "plan", "--plan",
                                                                  image / "plan.json"],
                        ["-c", load, image / "gke" / "generator.py"]):
            result = subprocess.run([sys.executable, *map(str, command)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


def cpuinfo_block(processor, model_name="AMD EPYC 7B13", family=25, model=1, stepping=0, microcode="0xffffffff",
                  flags="aes avx2 sha_ni vaes"):
    """A processor of /proc/cpuinfo as Linux writes it on an x86 virtual
    machine, with the flags of `flags` among others."""
    return (f"processor\t: {processor}\nvendor_id\t: {'AuthenticAMD' if 'AMD' in model_name else 'GenuineIntel'}\n"
            f"cpu family\t: {family}\nmodel\t\t: {model}\nmodel name\t: {model_name}\nstepping\t: {stepping}\n"
            f"microcode\t: {microcode}\ncpu MHz\t\t: 2449.998\ncache size\t: 512 KB\nphysical id\t: 0\n"
            f"siblings\t: 8\ncore id\t\t: {processor // 2}\ncpu cores\t: 4\nfpu\t\t: yes\n"
            f"flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic sep sse sse2 ht syscall nx lm constant_tsc "
            f"pni pclmulqdq ssse3 fma cx16 sse4_1 sse4_2 movbe popcnt xsave avx f16c rdrand hypervisor {flags} "
            f"bmi1 bmi2 adx clflushopt\n"
            f"bugs\t\t: sysret_ss_attrs spectre_v1 spectre_v2 spec_store_bypass srso\n"
            f"bogomips\t: 4899.99\naddress sizes\t: 48 bits physical, 48 bits virtual\npower management:\n\n")


# What Linux says of an AMD and of an Intel x86 CPU's vulnerabilities.
AMD_VULNERABILITIES = {
    "meltdown": "Not affected",
    "retbleed": "Not affected",
    "spec_rstack_overflow": "Vulnerable: Safe RET, no microcode",
    "spectre_v2": "Mitigation: Retpolines; IBPB: conditional; IBRS_FW; STIBP: always-on; RSB filling; "
                  "PBRSB-eIBRS: Not affected; BHI: Not affected",
}

INTEL_VULNERABILITIES = {
    "meltdown": "Mitigation: PTI",
    "retbleed": "Mitigation: IBRS",
    "spec_rstack_overflow": "Not affected",
    "spectre_v2": "Mitigation: IBRS; IBPB: conditional; STIBP: conditional; RSB filling; PBRSB-eIBRS: Not affected; "
                  "BHI: SW loop, KVM: SW loop",
}

# What gke.py node-cpu keeps of an AMD EPYC 7B13 (Zen 3) node's CPU.
AMD_CPU = {"model_name": "AMD EPYC 7B13", "vendor_id": "AuthenticAMD", "cpu_family": "25", "model": "1",
           "stepping": "0", "microcode": "0xffffffff",
           "flags": {"aes": True, "avx2": True, "sha_ni": True, "vaes": True},
           "vulnerabilities": AMD_VULNERABILITIES}

# And of an Intel Broadwell node's: no SHA or vector AES instructions.
INTEL_CPU = {"model_name": "Intel(R) Xeon(R) CPU @ 2.20GHz", "vendor_id": "GenuineIntel", "cpu_family": "6",
             "model": "79", "stepping": "0", "microcode": "0xffffffff",
             "flags": {"aes": True, "avx2": True, "sha_ni": False, "vaes": False},
             "vulnerabilities": INTEL_VULNERABILITIES}


class NodeCpu(Helper):
    """What smock's init container and the load generator say of the CPU
    of the node they run on: its model, microcode, the flags that make TLS
    fast and the kernel's mitigations of its vulnerabilities, from
    /proc/cpuinfo and /sys/devices/system/cpu/vulnerabilities."""

    def node_cpu(self, cpuinfo, vulnerabilities):
        """What gke.py node-cpu prints for a /proc/cpuinfo of `cpuinfo` (None:
        no file) and the vulnerabilities `vulnerabilities` ({name: text}, None:
        no directory): its exit status and its one JSON line."""
        directory = self.directory()
        args = ["node-cpu", "--cpuinfo", directory / "cpuinfo", "--vulnerabilities", directory / "vulnerabilities"]
        if cpuinfo is not None:
            (directory / "cpuinfo").write_text(cpuinfo)
        if vulnerabilities is not None:
            (directory / "vulnerabilities").mkdir()
            for name, text in vulnerabilities.items():
                (directory / "vulnerabilities" / name).write_text(text + "\n")
        status, stdout, stderr = helper(*args)
        return status, [json.loads(line) for line in stdout.splitlines()], stderr

    def test_an_x86_nodes_model_microcode_tls_flags_and_mitigations_are_printed(self):
        status, lines, stderr = self.node_cpu(cpuinfo_block(0) + cpuinfo_block(1), AMD_VULNERABILITIES)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": AMD_CPU}])
        status, lines, stderr = self.node_cpu(
            cpuinfo_block(0, model_name="Intel(R) Xeon(R) CPU @ 2.20GHz", family=6, model=79, flags="aes avx2"),
            INTEL_VULNERABILITIES)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": INTEL_CPU}])

    def test_an_arm64_node_is_named_by_its_implementer_and_part_with_its_own_tls_flags(self):
        # As Linux writes it on arm64, which has no model name or microcode.
        cpuinfo = ("processor\t: 0\nBogoMIPS\t: 48.00\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics "
                   "fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sha512\nCPU implementer\t: 0x41\n"
                   "CPU architecture: 8\nCPU variant\t: 0x0\nCPU part\t: 0xd4f\nCPU revision\t: 1\n\n")
        status, lines, stderr = self.node_cpu(cpuinfo, {"spectre_v2": "Not affected"})
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": {
            "model_name": "implementer 0x41, part 0xd4f", "cpu_implementer": "0x41", "cpu_architecture": "8",
            "cpu_variant": "0x0", "cpu_part": "0xd4f", "cpu_revision": "1", "microcode": None,
            "flags": {"aes": True, "pmull": True, "sha2": True}, "vulnerabilities": {"spectre_v2": "Not affected"}}}])

    def test_what_it_cannot_read_it_says_and_still_succeeds_so_that_smock_starts(self):
        # An init container that failed would keep smock's Pod from starting.
        status, lines, stderr = self.node_cpu(None, None)
        self.assertEqual(status, 0, stderr)
        [line] = lines
        self.assertEqual((line["kind"], line["cpu"]), ("node-cpu", None))
        self.assertIn("cpuinfo", line["error"])
        status, lines, stderr = self.node_cpu(cpuinfo_block(0), None)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(lines, [{"kind": "node-cpu", "cpu": {**AMD_CPU, "vulnerabilities": None}}])


def kept_pod(label, node="node-a", cpu="250m", memory="512Mi", profile="autopilot-min", requests=None):
    """What gke.py pod-info keeps of a variant's smock Pod: on `node`,
    admitted with `cpu` and `memory` as its limits, and as its requests
    unless `requests` says otherwise."""
    limits = {"cpu": cpu, "memory": memory, "ephemeral-storage": "64Mi"}
    return {"name": f"smock-{profile}-{label}", "node": node, "ready": True, "restarts": None,
            "last_termination": None, "variant": label, "resources": {"requests": requests or limits, "limits": limits}}


class Placement(Helper):
    """Before the load generator starts, the run checks that every variant
    of the profile runs on one node, under the profile's limits as
    Autopilot admitted them: else the comparison would not hold."""

    def placement(self, smock, profile="autopilot-min"):
        """gke.py placement over the profile's Pods as pod-info keeps them,
        with `smock` as its smock Pods."""
        path = self.directory() / "pods.json"
        path.write_text(json.dumps({"smock": smock, "generator": [], "nodes": {}}))
        return helper("placement", path, "--plan", BENCH / "plan-autopilot.json", "--profile", profile)

    def test_variants_on_one_node_under_the_profiles_limits_pass(self):
        # The API may write a quantity otherwise than the plan does; a Pod
        # of another profile is not this one's.
        status, stdout, stderr = self.placement([
            kept_pod("r1"), kept_pod("r2", cpu="0.25", memory="536870912"), kept_pod("r2b"),
            kept_pod("r1", node="node-b", profile="chart-default", cpu="1", memory="1Gi")])
        self.assertEqual((status, stdout, stderr), (0, "", ""))
        status, _, stderr = self.placement([kept_pod("r1", cpu="1", memory="1Gi", profile="chart-default"),
                                            kept_pod("r2", cpu="1000m", memory="1Gi", profile="chart-default")],
                                           profile="chart-default")
        self.assertEqual(status, 0, stderr)

    def test_the_variants_pods_as_rendered_and_read_back_by_pod_info_pass(self):
        # As the run applies them, and kubectl lists them once each has a
        # node.
        rendered = self.manifests(profile="autopilot-burst-min",
                                  variants=(*TWO_VARIANTS, f"r2h={OTHER_IMAGE},no-init"))
        directory = self.directory()
        pod_list = {"items": [{**pod, "spec": {**pod["spec"], "nodeName": "node-a"},
                               "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                                          "containerStatuses": [{"name": "smock", "restartCount": 0}]}}
                              for pod in objects(rendered, "Pod")]}
        (directory / "pods.json").write_text(json.dumps(pod_list))
        (directory / "nodes.json").write_text(json.dumps({"items": []}))
        status, stdout, stderr = helper("pod-info", "--without-restarts", directory / "pods.json",
                                        directory / "nodes.json")
        self.assertEqual(status, 0, stderr)
        (directory / "pod-info.json").write_text(stdout)
        self.assertEqual([pod["variant"] for pod in json.loads(stdout)["smock"]], ["r1", "r2", "r2h"])
        status, _, stderr = helper("placement", directory / "pod-info.json", "--plan", BENCH / "plan-autopilot.json",
                                   "--profile", "autopilot-burst-min")
        self.assertEqual(status, 0, stderr)

    def test_variants_on_two_nodes_fail_saying_which_is_on_which(self):
        status, _, stderr = self.placement([kept_pod("r1"), kept_pod("r2", node="node-b"), kept_pod("r2b"),
                                            kept_pod("r2h", node="node-b")])
        self.assertEqual(status, 1)
        self.assertIn("the smock Pods of autopilot-min are on 2 nodes, not one: r1 and r2b on node-a, r2 and r2h on "
                      "node-b", stderr)

    def test_a_variant_admitted_with_other_requests_or_limits_than_the_profiles_fails_saying_which(self):
        # As Autopilot raises what is under its minimums for the Pods that
        # need more, such as those with anti-affinity.
        status, _, stderr = self.placement([
            kept_pod("r1", memory="1Gi", requests={"cpu": "250m", "memory": "512Mi", "ephemeral-storage": "64Mi"}),
            kept_pod("r2", cpu="500m")])
        self.assertEqual(status, 1)
        self.assertEqual(stderr.splitlines(), [
            "gke: variant r1's memory limit was admitted as 1Gi, not the profile's 512Mi",
            "gke: variant r2's CPU request was admitted as 500m, not the profile's 250m",
            "gke: variant r2's CPU limit was admitted as 500m, not the profile's 250m"])

    def test_a_variant_with_no_node_yet_or_unknown_resources_fails(self):
        status, _, stderr = self.placement([kept_pod("r1"), kept_pod("r2", node=None),
                                            {**kept_pod("r2b"), "resources": None}])
        self.assertEqual(status, 1)
        self.assertIn("gke: variant r2 has no node yet", stderr)
        self.assertIn("gke: variant r2b's admitted requests and limits are unknown", stderr)
        status, _, stderr = self.placement([kept_pod("r1", profile="chart-default")])
        self.assertEqual(status, 1)
        self.assertIn("gke: no smock Pod of profile autopilot-min is in", stderr)


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
             "spec": {"nodeName": "node-b", "containers": [{"image": image, "resources": {
                 "requests": {"cpu": "6", "memory": "6Gi", "ephemeral-storage": "2Gi"},
                 "limits": {"cpu": "6", "memory": "6Gi", "ephemeral-storage": "2Gi"}}}]},
             "status": {"phase": "Failed", "reason": "DeadlineExceeded", "containerStatuses": []}}]}
        labels = {"node.kubernetes.io/instance-type": "e4a-standard-8", "kubernetes.io/arch": "arm64",
                  "topology.kubernetes.io/zone": "us-central1-a", "cloud.google.com/machine-family": "e4a",
                  "cloud.google.com/compute-class": "autopilot-arm",
                  # The type of its boot disk, whose quota the run's checks
                  # take it to draw on.
                  "cloud.google.com/gke-boot-disk": "hyperdisk-balanced"}
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
                                          "last_termination": "OOMKilled", "variant": None, "resources": None}])
        self.assertEqual(info["generator"], [{"name": "generator-small-1", "node": "node-b", "phase": "Failed",
                                              "reason": "DeadlineExceeded", "cpu_request": "6"}])
        self.assertEqual(info["nodes"], {"node-a": NODE})
        # Read before the profile's end, smock's restarts are unknown.
        status, stdout, stderr = helper("pod-info", "--without-restarts", directory / "pods.json",
                                        directory / "nodes.json")
        self.assertEqual(status, 0, stderr)
        self.assertEqual(json.loads(stdout), {**info, "smock": [{**info["smock"][0], "restarts": None}]})

    def test_each_smock_pods_variant_and_the_resources_its_smock_container_was_admitted_with_are_kept(self):
        # As Autopilot admitted them, which may differ from what the
        # manifests asked for; from the container named smock, wherever it
        # is in the Pod.
        directory = self.directory()

        def smock_pod(label, cpu, restarts):
            admitted = {"cpu": cpu, "memory": "512Mi", "ephemeral-storage": "64Mi"}
            return {"metadata": {"name": f"smock-autopilot-min-{label}",
                                 "labels": {"app": "smock-bench", "profile": "autopilot-min", "variant": label}},
                    "spec": {"nodeName": "node-a", "containers": [
                        {"name": "other", "resources": {"requests": {"cpu": "1"}, "limits": {"cpu": "1"}}},
                        {"name": "smock", "resources": {"requests": admitted, "limits": admitted}}]},
                    "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}],
                               "containerStatuses": [{"name": "other", "restartCount": 7},
                                                     {"name": "smock", "restartCount": restarts, "lastState": {}}]}}

        (directory / "pods.json").write_text(json.dumps({"items": [smock_pod("r1", "250m", 0),
                                                                   smock_pod("r2", "500m", 1)]}))
        (directory / "nodes.json").write_text(json.dumps({"items": []}))
        status, stdout, stderr = helper("pod-info", directory / "pods.json", directory / "nodes.json")
        self.assertEqual(status, 0, stderr)
        self.assertEqual(json.loads(stdout)["smock"], [
            {"name": "smock-autopilot-min-r1", "node": "node-a", "ready": True, "restarts": 0,
             "last_termination": None, "variant": "r1",
             "resources": {"requests": {"cpu": "250m", "memory": "512Mi", "ephemeral-storage": "64Mi"},
                           "limits": {"cpu": "250m", "memory": "512Mi", "ephemeral-storage": "64Mi"}}},
            {"name": "smock-autopilot-min-r2", "node": "node-a", "ready": True, "restarts": 1,
             "last_termination": None, "variant": "r2",
             "resources": {"requests": {"cpu": "500m", "memory": "512Mi", "ephemeral-storage": "64Mi"},
                           "limits": {"cpu": "500m", "memory": "512Mi", "ephemeral-storage": "64Mi"}}}])


def variant_step(label, round_, rate, us_per_request=30.0, utilization=0.5, neighbours=None, steal=None, **changes):
    """A step line of the load generator with variants: `label`'s run of
    http-keep-alive under small at `rate` in `round_`, smock's CPU at
    `us_per_request` and `utilization`, with what the idle variants used
    (`neighbours`) and each variant's count of the node's steal time
    (`steal`, by default the loaded one's alone); and `changes` to its
    result's smock_cpu, or to the result itself (errors,
    load_generator_late)."""
    result = generator_step(rate, errors=changes.pop("errors", 0))["result"]
    result["load_generator_late"] = changes.pop("load_generator_late", False)
    result["smock_cpu"].update({"us_per_request": us_per_request, "utilization": utilization,
                                "scheduling_delay_s": 0.02, "involuntary_context_switches": 40, "node_steal_s": 0.0,
                                "first_second": None, **changes})
    return {"kind": "step", "variant": label, "round": round_, "neighbours": neighbours or {},
            "node_steal_s": steal or {label: result["smock_cpu"]["node_steal_s"]}, "result": result}


def variant_lines(us_per_request, rates=(500, 1000), runs=None, stopped=None, done=True):
    """The load generator's lines of a run of variants of smock under
    small, at `rates` of http-keep-alive, as it prints them: each variant's
    start, idle RSS and traffic check, then the runs, rounds outer, the
    rates in the middle and the variants inner, their order turned by one
    for each round and rate. `us_per_request` gives each variant's CPU a
    request at each rate in each round, {label: {rate: [round 1's, round
    2's, ...]}}, the first the baseline; `runs` what else differs in a run,
    {(label, round, rate): variant_step's keywords}. Runs after a `stopped`
    line's (its fields) are left out, and the done lines are when `done`."""
    labels = list(us_per_request)
    rounds = len(us_per_request[labels[0]][rates[0]])
    lines = []
    for label in labels:
        lines += [{**START, "variant": label, "first_second": label == labels[0]},
                  {**IDLE, "variant": label}, {**TRAFFIC_CHECK, "variant": label},
                  {"kind": "metrics-before", "profile": "small", "variant": label, "text": "# metrics\n"}]
    for round_ in range(1, rounds + 1):
        for index, rate in enumerate(rates):
            for offset in range(len(labels)):
                label = labels[(round_ - 1 + index + offset) % len(labels)]
                if stopped and {"round": round_, "variant": label, "id": f"http-keep-alive@small@{rate}"} in \
                        stopped["runs"]:
                    continue
                lines.append(variant_step(label, round_, rate, us_per_request[label][rate][round_ - 1],
                                          **(runs or {}).get((label, round_, rate), {})))
    if stopped:
        lines.append({"kind": "stopped", "profile": "small", **stopped})
    for label in labels:
        lines.append({"kind": "metrics-after", "profile": "small", "variant": label, "text": "# metrics\n"})
    if done:
        lines += [{"kind": "done", "profile": "small", "variant": label} for label in labels]
    return lines


def variant_pods(labels, nodes=None, limits=None):
    """What gke.py pod-info keeps of the Pods of a run of variants under
    small: each variant's smock Pod on its node of `nodes` ({label: node},
    node-a by default), admitted with its `limits` ({label: (cpu, memory)},
    small's by default), and the load generator's on node-b."""
    smock = []
    for label in labels:
        cpu, memory = (limits or {}).get(label, ("250m", "512Mi"))
        smock.append({**kept_pod(label, node=(nodes or {}).get(label, "node-a"), cpu=cpu, memory=memory,
                                 profile="small"), "restarts": 0})
    return {"smock": smock,
            "generator": [{"name": "generator-small-x7k2p", "node": "node-b", "phase": "Succeeded", "reason": None,
                           "cpu_request": "6"}],
            "nodes": {"node-a": X86_NODE, "node-b": X86_NODE, "node-c": X86_NODE}}


class VariantRun(Helper):
    """A run of variants as the runner leaves it, raw/small/ with the load
    generator's log, the Pods, and each variant's own files in
    raw/small/<label>/; and its samples, each summarized."""

    def variant_run(self, lines, pod_info, no_init=("b",)):
        """A results directory of a run of variants under small whose load
        generator wrote `lines`, with the Pods `pod_info`: each variant has
        its smock log, and what its init container printed of its node's
        CPU unless it is `no_init`."""
        out = self.directory()
        raw = out / "raw" / "small"
        raw.mkdir(parents=True)
        (raw / "generator.log").write_text("".join(json.dumps(line) + "\n" for line in lines))
        (raw / "pods.json").write_text(json.dumps(pod_info))
        for label in dict.fromkeys(line["variant"] for line in lines if line.get("variant")):
            (raw / label).mkdir()
            (raw / label / "smock.log").write_text(f"smock {label} listening\n")
            if label not in no_init:
                (raw / label / "smock-node-cpu.log").write_text(json.dumps({"kind": "node-cpu", "cpu": AMD_CPU}) +
                                                                "\n")
        return out

    def samples(self, out, plan=None):
        """gke.py samples over `out`, and the samples it printed: [(round,
        label, directory)]."""
        status, stdout, stderr = helper("samples", out, "--plan", plan or small_plan(self.directory()))
        self.assertEqual(status, 0, stderr)
        return [(int(round_), label, Path(directory))
                for round_, label, directory in (line.split(" ", 2) for line in stdout.splitlines())]

    def summarize_sample(self, directory, sha256=None, plan=None, stopped=None):
        """summarize over a sample's directory, as the runner calls it for
        each, with the sample's variant's binary, and where and why the run
        stopped before its end when it did (`stopped`, (reason, profile));
        its summary.json and conditions.json."""
        status, _, stderr = helper(
            "summarize", "--plan", plan or small_plan(self.directory()), "--targets", small_targets(self.directory()),
            "--region", "us-central1", "--arch", "amd64", "--started-at", "2026-10-16T03:28:50+00:00",
            "--finished-at", "2026-10-16T04:01:56+00:00", "--smock-image", "sha256:" + "1" * 64,
            *(["--smock-sha256", sha256] if sha256 else []), "--generator-image", "sha256:" + "2" * 64,
            *(["--stopped", stopped[0], "--stopped-under", stopped[1]] if stopped else []), directory)
        self.assertEqual(status, 0, stderr)
        return json.loads((directory / "summary.json").read_text()), \
            json.loads((directory / "conditions.json").read_text())

    def same_node(self, out, *options, sha256=None, plan=None, stopped=None):
        """gke.py same-node over `out` with `options`, once its samples are
        split and each summarized as the runner does it, with its variant's
        binary's sha256 of `sha256` ({label or (round, label): hex}, by
        default 64 of the label's first letter), and where and why the run
        stopped when it did (`stopped`, (reason, profile)): its exit status,
        same-node.json, same-node.md and what it wrote to stderr. The plan
        is small_plan's, unless `plan` names another."""
        plan = plan or small_plan(self.directory())
        sha256 = sha256 or {}
        for round_, label, directory in self.samples(out, plan):
            self.summarize_sample(directory, sha256.get((round_, label), sha256.get(label, label[0] * 64)), plan,
                                  stopped)
        status, _, stderr = helper("same-node", out, *options)
        report = json.loads((out / "same-node.json").read_text()) if (out / "same-node.json").exists() else None
        markdown = (out / "same-node.md").read_text() if (out / "same-node.md").exists() else None
        return status, report, markdown, stderr

    def row(self, markdown, case, rate, label, heading="## small: CPU limit 250m, memory limit 512Mi"):
        """The cells of a variant's row for a step in the table under
        `heading` of same-node.md, by column."""
        section = markdown.split(f"\n{heading}\n", 1)[1].split("\n## ", 1)[0]
        lines = [line for line in section.splitlines() if line.startswith("|")]
        header = [cell.strip() for cell in lines[0].strip("|").split("|")]
        for line in lines[2:]:
            row = dict(zip(header, (cell.strip() for cell in line.strip("|").split("|"))))
            if (row["Case"], row["Rate"], row["Variant"].split(" ")[0]) == (case, f"{rate:,}", label):
                return row
        self.fail(f"no row for {label} at {case}@{rate} in:\n{markdown}")


# Why the load generator stopped the run of stopped_in_round_2.
STOPPED_IN_ROUND_2 = ("variant b, round 2: http-keep-alive@small@500 got no response to any of its 10,000 requests, "
                      "and smock did not answer through its Service in 60 s after it: plain port 80 (timed out)")


def stopped_in_round_2():
    """The lines of a run of a and b over two rounds that the load
    generator stopped early: b's run at 500 requests/s in round 2, the
    first of that step, got no response, nor did the traffic check after
    it, so every variant stopped, round 1 whole; and why it stopped."""
    left = [{"round": 2, "variant": "a", "id": "http-keep-alive@small@500"},
            {"round": 2, "variant": "a", "id": "http-keep-alive@small@1000"},
            {"round": 2, "variant": "b", "id": "http-keep-alive@small@1000"}]
    us = {"a": {500: [30.0, 31.0], 1000: [32.0, 33.0]}, "b": {500: [40.0, 41.0], 1000: [42.0, 43.0]}}
    lines = variant_lines(us, runs={("b", 2, 500): {"errors": 10000}},
                          stopped={"variant": "b", "round": 2, "reason": STOPPED_IN_ROUND_2,
                                   "after": "http-keep-alive@small@500", "runs": left})
    check = {**TRAFFIC_CHECK, "variant": "b", "round": 2, "after": "http-keep-alive@small@500", "ok": False}
    lines.insert(next(index for index, line in enumerate(lines) if line.get("round") == 2) + 1, check)
    return lines, STOPPED_IN_ROUND_2


class Samples(VariantRun):
    """gke.py samples splits a run of variants into its samples, each one
    variant's pass over the steps in one round, as an ordinary run of
    smock alone that gke.py summarize, unchanged, summarizes."""

    def test_each_round_of_each_variant_is_a_sample_that_summarizes_as_a_run_of_smock_alone(self):
        us = {"a": {500: [30.0, 31.0], 1000: [32.0, 33.0]}, "b": {500: [40.0, 41.0], 1000: [42.0, 43.0]}}
        out = self.variant_run(variant_lines(us), variant_pods(["a", "b"]))
        samples = self.samples(out)
        self.assertEqual([(round_, label) for round_, label, _ in samples], [(1, "a"), (1, "b"), (2, "a"), (2, "b")])
        for round_, label, directory in samples:
            self.assertEqual(directory, out / "samples" / f"{round_}-{label}")
            raw = directory / "raw" / "small"
            # Its own smock Pod alone, so that its OOM kills are known, and
            # the load generator's, on the nodes they ran on.
            pod_info = json.loads((raw / "pods.json").read_text())
            self.assertEqual([pod["name"] for pod in pod_info["smock"]], [f"smock-small-{label}"])
            self.assertEqual([pod["name"] for pod in pod_info["generator"]], ["generator-small-x7k2p"])
            self.assertEqual(set(pod_info["nodes"]), {"node-a", "node-b"})
            # Its own smock log, and what its init container printed, which
            # b, without one, has not.
            self.assertEqual((raw / "smock.log").read_text(), f"smock {label} listening\n")
            self.assertEqual((raw / "smock-node-cpu.log").exists(), label == "a")
            summary, conditions = self.summarize_sample(directory)
            self.assertTrue(summary["complete"], (round_, label))
            self.assertEqual([(case["rate"], case["smock_cpu"]["us_per_request"]) for case in summary["cases"]],
                             [(rate, us[label][rate][round_ - 1]) for rate in (500, 1000)])
            # Idle RSS was read once, before any load: round 1's.
            self.assertEqual([idle["memory"]["oom_kills"] for idle in summary["idle_rss"]], [0] if round_ == 1 else [])
            self.assertEqual({case["memory"]["oom_kills"] for case in summary["cases"]}, {0})
            self.assertTrue(conditions["gke"]["profiles"]["small"]["traffic_check"]["ok"])
            self.assertEqual(conditions["gke"]["profiles"]["small"]["nodes"]["node-a"]["cpu"],
                             AMD_CPU if label == "a" else None)

    def test_a_profile_stopped_early_leaves_each_sample_the_steps_it_did_not_run(self):
        lines, reason = stopped_in_round_2()
        out = self.variant_run(lines, variant_pods(["a", "b"]))
        summaries = {(round_, label): self.summarize_sample(directory)[0]
                     for round_, label, directory in self.samples(out)}
        for sample in ((1, "a"), (1, "b")):
            self.assertTrue(summaries[sample]["complete"], sample)
            self.assertIsNone(summaries[sample]["gke"]["profiles"]["small"]["ended_early"])
        # b ran its step at 500 in round 2, and the check after it is its
        # own; a ran none.
        self.assertEqual(
            {sample: (summaries[sample]["complete"], [case["rate"] for case in summaries[sample]["cases"]],
                      summaries[sample]["gke"]["profiles"]["small"]["ended_early"]) for sample in ((2, "a"), (2, "b"))},
            {(2, "a"): (False, [], {"reason": reason, "after": None,
                                    "not_measured": ["http-keep-alive@small@500", "http-keep-alive@small@1000"]}),
             (2, "b"): (False, [500], {"reason": reason, "after": "http-keep-alive@small@500",
                                       "not_measured": ["http-keep-alive@small@1000"]})})
        # What the runner says when the profile ends, from the whole log.
        status, stdout, stderr = helper("stopped", out / "raw" / "small" / "generator.log")
        self.assertEqual((status, stdout), (0, f"{reason}; 3 runs not measured\n"), stderr)
        sample_log = (out / "samples" / "2-b" / "raw" / "small" / "generator.log").read_text()
        self.assertEqual([json.loads(line)["kind"] for line in sample_log.splitlines()],
                         ["start", "traffic-check", "metrics-before", "step", "traffic-check", "stopped",
                          "metrics-after", "done"])


# Two variants' CPU a request over four rounds at two rates: b's is higher
# than a's in every round, by 10%, 4%, 10% and 20% at 500 requests/s and by
# 10%, 5%, 15% and 2.5% at 1,000.
HIGHER = {"a": {500: [30.0, 31.0, 29.0, 30.0], 1000: [40.0, 40.0, 40.0, 40.0]},
          "b": {500: [33.0, 32.24, 31.9, 36.0], 1000: [44.0, 42.0, 46.0, 41.0]}}


class SameNode(VariantRun):
    """gke.py same-node compares the variants of a run on one node, from
    their samples' summaries and the load generator's lines: step by step,
    each variant's CPU a request against the baseline's, run by run in the
    same round, and over every step of a profile, whether a variant used
    more than the baseline beyond chance."""

    def test_each_variants_median_and_range_and_its_paired_change_against_the_baseline_are_reported(self):
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        self.assertEqual(report["baseline"], "a")
        profile = report["gke"]["profiles"]["small"]
        self.assertTrue(profile["complete"])
        b = next(step for step in profile["steps"] if step["rate"] == 500)["variants"]["b"]
        self.assertEqual({key: b[key] for key in ("n", "median_us_per_request", "min_us_per_request",
                                                  "max_us_per_request", "change_percent", "higher")},
                         {"n": 4, "median_us_per_request": 32.62, "min_us_per_request": 31.9,
                          "max_us_per_request": 36.0, "change_percent": 8.73, "higher": 4})
        self.assertEqual([(pair["round"], pair["change_percent"], pair["saturated"]) for pair in b["pairs"]],
                         [(1, 10.0, False), (2, 4.0, False), (3, 10.0, False), (4, 20.0, False)])
        # Over both rates' eight pairs, all higher: a sign test's p of
        # 2 / 2^8.
        self.assertEqual(profile["verdicts"]["b"],
                         {"pairs": 8, "higher": 8, "lower": 0, "median_change_percent": 10.0,
                          "min_change_percent": 2.5, "max_change_percent": 20.0, "sign_test_p": 0.0078125,
                          "verdict": "higher"})
        self.assertEqual(self.row(markdown, "http-keep-alive", 500, "a"),
                         {"Case": "http-keep-alive", "Rate": "500", "Variant": "a (baseline)",
                          "CPU µs/request": "30.0 (29.0–31.0, 4)", "Change": "-", "Paired": "-", "Higher": "-",
                          "Throttled periods": "12 of 1,000", "CPU wait s": "0.02", "Node steal s": "0.0",
                          "p99 ms": "2.0", "Saturated": "0 of 4 runs"})
        self.assertEqual(self.row(markdown, "http-keep-alive", 500, "b"),
                         {"Case": "http-keep-alive", "Rate": "500", "Variant": "b",
                          "CPU µs/request": "32.6 (31.9–36.0, 4)", "Change": "+8.7%", "Paired": "+4% to +20%",
                          "Higher": "4 of 4", "Throttled periods": "12 of 1,000", "CPU wait s": "0.02",
                          "Node steal s": "0.0", "p99 ms": "2.0", "Saturated": "0 of 4 pairs"})
        self.assertIn("- b against a: +10% (+2.5% to +20%), higher in 8 of 8 pairs, sign test p = 0.008: higher.",
                      markdown)
        self.assertIn("Started 2026-10-16T03:28:50+00:00: 2 variants of smock over 4 rounds, on GKE Autopilot "
                      "(asia-northeast1-b, general-purpose), amd64 (GKE Autopilot ek-standard-8, 8 CPUs), oha 1.16.0, "
                      "plan ", markdown)
        self.assertIn("\n## Reading the comparison\n", markdown)

    def test_another_variant_can_be_the_baseline(self):
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"]))
        status, report, markdown, stderr = self.same_node(out, "--baseline", "b")
        self.assertEqual(status, 0, stderr)
        self.assertEqual((report["baseline"], [variant["label"] for variant in report["variants"]]), ("b", ["b", "a"]))
        self.assertEqual(self.row(markdown, "http-keep-alive", 500, "b")["Variant"], "b (baseline)")
        self.assertIn("- a against b: -9.1% (-16.7% to -2.4%), higher in 0 of 8 pairs, sign test p = 0.008: lower.",
                      markdown)
        status, _, stderr = helper("same-node", out, "--baseline", "c")
        self.assertEqual(status, 1)
        self.assertIn("gke: the run has no variant c: its variants are a and b", stderr)

    def test_each_variants_drift_compares_its_first_round_with_the_later_ones(self):
        # b's round 1 at 500 requests/s, 33.0, against the median of its
        # later rounds, 32.24, and at 1,000, 44.0 against 42.0.
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        self.assertEqual(report["gke"]["profiles"]["small"]["drift"], {
            "a": {"steps": 2, "median_change_percent": 0.0, "min_change_percent": 0.0, "max_change_percent": 0.0},
            "b": {"steps": 2, "median_change_percent": 3.56, "min_change_percent": 2.36, "max_change_percent": 4.76}})
        self.assertIn("Drift, each variant's CPU µs/request in round 1 against the median of its later rounds, step by "
                      "step: a 0% (0%, 2 steps); b +3.6% (+2.4% to +4.8%, 2 steps).", markdown)

    def test_pairs_in_which_either_run_saturated_its_cpu_limit_are_left_out_of_the_verdict(self):
        # b used 95% of its CPU limit at 1,000 requests/s in every round,
        # and a 92% at 500 in round 2.
        runs = {("b", round_, 1000): {"utilization": 0.95} for round_ in range(1, 5)}
        runs["a", 2, 500] = {"utilization": 0.92}
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER, runs=runs),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        profile = report["gke"]["profiles"]["small"]
        self.assertEqual([[pair["saturated"] for pair in step["variants"]["b"]["pairs"]] for step in profile["steps"]],
                         [[False, True, False, False], [True, True, True, True]])
        # Each step's rows still show every pair.
        self.assertEqual([self.row(markdown, "http-keep-alive", rate, label)["Saturated"]
                          for rate in (500, 1000) for label in ("a", "b")],
                         ["1 of 4 runs", "1 of 4 pairs", "0 of 4 runs", "4 of 4 pairs"])
        self.assertEqual(self.row(markdown, "http-keep-alive", 1000, "b")["Paired"], "+2.5% to +15%")
        # Three pairs left, all higher: p = 2 / 2^3.
        self.assertEqual(profile["verdicts"]["b"],
                         {"pairs": 3, "higher": 3, "lower": 0, "median_change_percent": 10.0,
                          "min_change_percent": 10.0, "max_change_percent": 20.0, "sign_test_p": 0.25,
                          "verdict": "no clear difference"})
        self.assertIn("- b against a: +10% (+10% to +20%), higher in 3 of 3 pairs, sign test p = 0.25: no clear "
                      "difference.", markdown)

    def test_a_run_that_measured_nothing_drops_out_of_the_counts_with_why(self):
        # b's run at 500 requests/s in round 3 lost requests, and the load
        # generator fell behind in a's at 1,000 in round 4: neither counts,
        # nor does its pair.
        runs = {("b", 3, 500): {"errors": 500}, ("a", 4, 1000): {"load_generator_late": True}}
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER, runs=runs),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        self.assertEqual({(rate, label): self.row(markdown, "http-keep-alive", rate, label)["CPU µs/request"]
                          for rate in (500, 1000) for label in ("a", "b")},
                         {(500, "a"): "30.0 (29.0–31.0, 4)", (500, "b"): "33.0 (32.2–36.0, 3)",
                          (1000, "a"): "40.0 (40.0–40.0, 3)", (1000, "b"): "43.0 (41.0–46.0, 4)"})
        self.assertEqual([(self.row(markdown, "http-keep-alive", rate, "b")["Paired"],
                           self.row(markdown, "http-keep-alive", rate, "b")["Higher"]) for rate in (500, 1000)],
                         [("+4% to +20%", "3 of 3"), ("+5% to +15%", "3 of 3")])
        profile = report["gke"]["profiles"]["small"]
        self.assertEqual((profile["verdicts"]["b"]["pairs"], profile["verdicts"]["b"]["sign_test_p"]), (6, 0.03125))
        self.assertEqual(profile["not_measured"], [
            {"id": "http-keep-alive@small@500", "round": 3, "variant": "b",
             "reason": "500 of 10000 requests failed in the b round 3 run", "not_run": None},
            {"id": "http-keep-alive@small@1000", "round": 4, "variant": "a",
             "reason": "the load generator fell behind in the a round 4 run", "not_run": None}])
        self.assertIn("Not measured, and left out of the counts:\n\n"
                      "- http-keep-alive@small@500: 500 of 10000 requests failed in the b round 3 run.\n"
                      "- http-keep-alive@small@1000: the load generator fell behind in the a round 4 run.\n", markdown)

    def test_the_waits_an_old_smock_does_not_count_show_as_a_dash_and_its_node_steal_comes_from_another(self):
        # b is smock at 0d984c8, which counts neither its waits for a CPU
        # nor the node's steal time: a's count stands in for the steal.
        old = {"scheduling_delay_s": None, "involuntary_context_switches": None, "node_steal_s": None}
        runs = {}
        for round_ in range(1, 5):
            for rate in (500, 1000):
                runs["a", round_, rate] = {"node_steal_s": 0.3, "steal": {"a": 0.3, "b": None}}
                runs["b", round_, rate] = {**old, "steal": {"a": 0.5, "b": None}}
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER, runs=runs),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        self.assertEqual({label: (self.row(markdown, "http-keep-alive", 500, label)["CPU wait s"],
                                  self.row(markdown, "http-keep-alive", 500, label)["Node steal s"])
                          for label in ("a", "b")}, {"a": ("0.02", "0.3"), "b": ("-", "0.5")})
        # The rest is measured as from any smock.
        self.assertEqual(self.row(markdown, "http-keep-alive", 500, "b")["CPU µs/request"], "32.6 (31.9–36.0, 4)")
        self.assertEqual(report["gke"]["profiles"]["small"]["verdicts"]["b"]["pairs"], 8)

    def test_each_variants_binary_and_options_are_named(self):
        # b is another commit, run without the init container (as the
        # runner says) and without the scrape a second into each step (as
        # the load generator did).
        lines = variant_lines(HIGHER)
        for line in lines:
            if line["kind"] == "start" and line["variant"] == "b":
                line["status"] = {**line["status"], "commit": "4f178ef33830", "version": "0.3.0"}
        status, report, markdown, stderr = self.same_node(self.variant_run(lines, variant_pods(["a", "b"])),
                                                          "--no-init", "b", "--sha256", f"b={'b' * 64}")
        self.assertEqual(status, 0, stderr)
        self.assertEqual(report["variants"], [
            {"label": "a", "baseline": True, "commit": "a21fe97d59c6", "version": "0.2.0", "sha256": "a" * 64,
             "options": []},
            {"label": "b", "baseline": False, "commit": "4f178ef33830", "version": "0.3.0", "sha256": "b" * 64,
             "options": ["no-init", "no-first-second"]}])
        self.assertIn("| Variant | Commit | Version | sha256 | Options |\n|---|---|---|---|---|\n"
                      f"| a (baseline) | a21fe97d59c6 | 0.2.0 | {'a' * 12} | - |\n"
                      f"| b | 4f178ef33830 | 0.3.0 | {'b' * 12} | no-init, no-first-second |\n", markdown)

    def test_variants_on_one_node_are_checked_by_its_name_even_when_one_did_not_print_its_cpu(self):
        # b ran without the init container: only a's sample knows the
        # node's CPU, and both name the node.
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER),
                                                                           variant_pods(["a", "b"])), "--no-init", "b")
        self.assertEqual(status, 0, stderr)
        profile = report["gke"]["profiles"]["small"]
        self.assertEqual({key: profile[key] for key in ("pods_read", "nodes", "one_node", "limits_as_planned",
                                                        "problems")},
                         {"pods_read": True, "nodes": {"a": "node-a", "b": "node-a"}, "one_node": True,
                          "limits_as_planned": True, "problems": []})
        self.assertEqual(profile["node"], {"name": "node-a", "instance_type": "ek-standard-8",
                                           "zone": "asia-northeast1-b", "cpu": AMD_CPU})
        self.assertIn("Every variant ran on node node-a: ek-standard-8 in asia-northeast1-b, AMD EPYC 7B13 (family 25, "
                      "model 1, stepping 0). Each was admitted with the profile's limits as its requests and limits.",
                      markdown)

    def test_variants_on_two_nodes_or_under_other_limits_than_the_plans_cannot_be_compared(self):
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"], nodes={"b": "node-c"}))
        status, report, markdown, stderr = self.same_node(out)
        self.assertEqual(status, 1)
        problem = "small: the smock Pods of small are on 2 nodes, not one: a on node-a, b on node-c"
        self.assertEqual((report["problems"], report["gke"]["profiles"]["small"]["one_node"]), ([problem], False))
        self.assertIn(f"gke: {problem}", stderr)
        self.assertIn(f"**Not comparable:**\n\n- {problem}.\n", markdown)
        self.assertIn("The variants ran on 2 nodes: a on node-a, b on node-c.", markdown)
        # As Autopilot raises a Pod's resources it finds too small.
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"], limits={"b": ("500m", "512Mi")}))
        status, report, markdown, stderr = self.same_node(out)
        self.assertEqual(status, 1)
        self.assertEqual(report["problems"],
                         ["small: variant b's CPU request was admitted as 500m, not the profile's 250m",
                          "small: variant b's CPU limit was admitted as 500m, not the profile's 250m"])
        self.assertFalse(report["gke"]["profiles"]["small"]["limits_as_planned"])
        self.assertIn("Every variant ran on node node-a: ek-standard-8 in asia-northeast1-b, AMD EPYC 7B13 (family 25, "
                      "model 1, stepping 0). Not every one was admitted with the profile's limits as its requests and "
                      "limits.", markdown)

    def test_a_profile_with_an_incomplete_sample_cannot_be_compared_and_says_what_was_measured(self):
        lines, reason = stopped_in_round_2()
        status, report, markdown, stderr = self.same_node(self.variant_run(lines, variant_pods(["a", "b"])))
        self.assertEqual(status, 1)
        problem = "small: samples 2-a and 2-b are incomplete"
        self.assertEqual(report["problems"], [problem])
        self.assertIn(f"gke: {problem}", stderr)
        self.assertEqual((report["complete"], report["gke"]["profiles"]["small"]["complete"]), (False, False))
        # What ran still counts: b's run in round 2 failed, and those after
        # it were left out.
        self.assertEqual(self.row(markdown, "http-keep-alive", 500, "b")["CPU µs/request"], "40.0 (40.0–40.0, 1)")
        self.assertEqual(self.row(markdown, "http-keep-alive", 1000, "a")["CPU µs/request"], "32.0 (32.0–32.0, 1)")
        self.assertIn(f"**Stopped early:** {reason}. 3 runs were left out.", markdown)
        self.assertIn("- http-keep-alive@small@500: 10000 of 10000 requests failed in the b round 2 run.", markdown)

    def test_the_order_the_variants_ran_in_and_what_their_idle_neighbours_used_are_reported(self):
        # Three variants over two rounds, not a multiple of three: their
        # positions are not balanced. c used the most CPU idle, beside b's
        # run at 1,000 requests/s in round 2.
        us = {label: {500: [30.0, 30.0], 1000: [30.0, 30.0]} for label in ("a", "b", "c")}
        runs = {(label, round_, rate): {"neighbours": {other: 0.004 for other in us if other != label}}
                for label in us for round_ in (1, 2) for rate in (500, 1000)}
        runs["b", 2, 1000]["neighbours"]["c"] = 0.031
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(us, runs=runs),
                                                                           variant_pods(["a", "b", "c"])))
        self.assertEqual(status, 0, stderr)
        profile = report["gke"]["profiles"]["small"]
        self.assertEqual(profile["order"], [
            {"round": 1, "id": "http-keep-alive@small@500", "variants": ["a", "b", "c"]},
            {"round": 1, "id": "http-keep-alive@small@1000", "variants": ["b", "c", "a"]},
            {"round": 2, "id": "http-keep-alive@small@500", "variants": ["b", "c", "a"]},
            {"round": 2, "id": "http-keep-alive@small@1000", "variants": ["c", "a", "b"]}])
        self.assertEqual(profile["positions"], {"a": [1, 1, 2], "b": [2, 1, 1], "c": [1, 2, 1]})
        self.assertIn("Each step ran the variants one after another, their order turned by one for each round and "
                      "step. Times each ran first, second and third: a 1, 1, 2; b 2, 1, 1; c 1, 2, 1.", markdown)
        self.assertEqual(profile["neighbours"], {"max_cpu_s": 0.031, "variant": "c", "beside": "b", "round": 2,
                                                 "id": "http-keep-alive@small@1000"})
        self.assertIn("The idle variants used at most 0.031 s of CPU during another's run: c, during b's run of "
                      "http-keep-alive@small@1000 in round 2.", markdown)

    def test_conditions_besides_smock_are_compared_with_the_baselines_first_samples(self):
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER),
                                                                           variant_pods(["a", "b"])))
        self.assertEqual((status, report["conditions"]), (0, {"same": True, "reference": "1-a", "differences": []}),
                         stderr)
        self.assertIn("Besides smock, the samples had the same conditions.", markdown)
        # b's load generator said another oha, as no run of one load
        # generator does.
        lines = variant_lines(HIGHER)
        for line in lines:
            if line["kind"] == "start" and line["variant"] == "b":
                line["oha"] = "oha 1.17.0"
        status, report, markdown, stderr = self.same_node(self.variant_run(lines, variant_pods(["a", "b"])))
        self.assertEqual(status, 0, stderr)
        self.assertEqual(report["conditions"], {"same": False, "reference": "1-a", "differences": [
            {"condition": "load generator", "text": "load generator (oha 1.16.0 → oha 1.17.0)",
             "samples": ["1-b", "2-b", "3-b", "4-b"]}]})
        self.assertIn("Besides smock, the samples differ from 1-a in: load generator (oha 1.16.0 → oha 1.17.0) in "
                      "1-b, 2-b, 3-b and 4-b.", markdown)

    def test_compare_py_compares_any_two_samples_as_two_runs(self):
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"]))
        status, _, _, stderr = self.same_node(out)
        self.assertEqual(status, 0, stderr)
        for older, newer in (("1-a", "1-b"), ("2-b", "4-a")):
            compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(out / "samples" / older),
                                       str(out / "samples" / newer)], capture_output=True, text=True)
            self.assertEqual(compared.returncode, 0, compared.stdout + compared.stderr)
            self.assertIn("Besides smock, the runs had the same conditions.", compared.stdout)
            self.assertIn("| small | http-keep-alive | 1,000 | 2.0 → 2.0 | 0% |", compared.stdout)
        # Its CPU a request, run against run; b's samples, without the init
        # container, did not record the node's CPU.
        compared = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(out / "samples" / "1-a"),
                                   str(out / "samples" / "1-b")], capture_output=True, text=True).stdout
        self.assertIn("| small | http-keep-alive | 500 | 30.0 → 33.0 | +10% | 50.0 → 50.0 |", compared)
        self.assertIn("The newer run did not record the CPU of smock's nodes: whether it changed is unknown.", compared)

    def test_runs_the_load_generator_never_reported_or_that_were_not_summarized_are_counted_once(self):
        # The load generator's Job ran out of time after b's first run of
        # round 2: it reported none of the three runs after it, nor its
        # done lines.
        us = {"a": {500: [30.0, 31.0], 1000: [32.0, 33.0]}, "b": {500: [40.0, 41.0], 1000: [42.0, 43.0]}}
        lines = variant_lines(us, done=False)
        lines = lines[:next(index for index, line in enumerate(lines) if line.get("round") == 2) + 1]
        out = self.variant_run(lines, variant_pods(["a", "b"]))
        status, report, markdown, stderr = self.same_node(out)
        self.assertEqual(status, 1)
        self.assertEqual(report["problems"], ["small: every sample is incomplete"])
        self.assertEqual([(entry["round"], entry["variant"], entry["not_run"])
                          for entry in report["gke"]["profiles"]["small"]["not_measured"]],
                         [(2, "a", "not reported"), (2, "a", "not reported"), (2, "b", "not reported")])
        self.assertIn("The load generator did not report 3 runs: its Job ended before them, or never ran.", markdown)
        self.assertNotIn("- http-keep-alive", markdown)
        # A sample summarize did not summarize: its runs count as none.
        (out / "samples" / "1-b" / "summary.json").unlink()
        status, _, stderr = helper("same-node", out)
        self.assertEqual(status, 1)
        self.assertIn("The sample 1-b has no summary, so its 2 runs are not counted.",
                      (out / "same-node.md").read_text())

    def test_a_profile_the_run_did_not_reach_cannot_be_compared_and_says_so(self):
        # A second profile, big, which the run did not reach, as one that
        # did not fit in its time limit.
        plan = small_plan(self.directory())
        content = json.loads(plan.read_text())
        content["profiles"].append({"name": "big", "cpu_limit": "1", "memory_limit": "1Gi"})
        content["cases"][0]["rates"]["big"] = [5000]
        plan.write_text(json.dumps(content))
        status, report, markdown, stderr = self.same_node(self.variant_run(variant_lines(HIGHER),
                                                                           variant_pods(["a", "b"])), plan=plan)
        self.assertEqual(status, 1)
        self.assertEqual(report["problems"], ["big: no smock Pod of profile big is in what the run read of its Pods",
                                              "big: every sample is incomplete"])
        self.assertTrue(report["gke"]["profiles"]["small"]["complete"])
        big = markdown.split("\n## big: CPU limit 1, memory limit 1Gi\n", 1)[1]
        self.assertIn("The run read no smock Pod under this profile.", big)
        self.assertIn("The load generator ran no step.", big)
        self.assertIn("The load generator did not report 8 runs: its Job ended before them, or never ran.", big)
        self.assertEqual([self.row(markdown, "http-keep-alive", 5000, label, "## big: CPU limit 1, memory limit 1Gi")
                          ["Saturated"] for label in ("a", "b")], ["-", "-"])

    def test_a_run_that_stopped_before_its_end_says_where_and_why_below_what_ran(self):
        # As the runner tells summarize of each sample: here, the next
        # profile, big, no longer fitted in the time limit.
        plan = small_plan(self.directory())
        content = json.loads(plan.read_text())
        content["profiles"].append({"name": "big", "cpu_limit": "1", "memory_limit": "1Gi"})
        content["cases"][0]["rates"]["big"] = [5000]
        plan.write_text(json.dumps(content))
        reason = "profile big and those after it did not fit in the time limit of 80 minutes"
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"]))
        status, report, markdown, _ = self.same_node(out, plan=plan, stopped=(reason, "big"))
        self.assertEqual(status, 1)
        self.assertEqual(report["stopped"], {"reason": reason, "profile": "big", "after": None})
        started, stopped = markdown.split("\n\n")[1:3]
        self.assertTrue(started.startswith("Started 2026-10-16T03:28:50+00:00: 2 variants"), started)
        self.assertEqual(stopped, f"**Stopped early:** the run stopped under profile big, before its first run: "
                                  f"{reason}. Nothing after that was measured.")
        # Stopped under small after its last run, b's at 1,000 requests/s
        # in round 4.
        status, report, markdown, _ = self.same_node(out, stopped=("stopped by SIGTERM", "small"))
        self.assertEqual(status, 0)
        self.assertEqual(report["stopped"], {"reason": "stopped by SIGTERM", "profile": "small",
                                             "after": {"round": 4, "variant": "b", "id": "http-keep-alive@small@1000"}})
        self.assertIn("\n\n**Stopped early:** the run stopped under profile small, after its run of "
                      "http-keep-alive@small@1000 by b in round 4: stopped by SIGTERM. Nothing after that was measured."
                      "\n\n", markdown)
        status, report, markdown, _ = self.same_node(out)
        self.assertIsNone(report["stopped"])
        self.assertNotIn("Stopped early", markdown)

    def test_a_variant_with_two_sha256_values_exits_2_since_what_it_measured_is_unknown(self):
        out = self.variant_run(variant_lines(HIGHER), variant_pods(["a", "b"]))
        # summarize was told another binary for b in round 3.
        status, report, markdown, stderr = self.same_node(out, sha256={(3, "b"): "c" * 64})
        self.assertEqual(status, 2)
        problem = f"variant b has two sha256 values, {'b' * 64} and {'c' * 64}: which binary it ran is unknown"
        self.assertIn(f"gke: {problem}", stderr)
        self.assertIn(problem, markdown)
        self.assertEqual(report["problems"], [problem])
        # And when the run's own differs from the samples'.
        status, _, _, stderr = self.same_node(out, "--sha256", f"a={'d' * 64}")
        self.assertEqual(status, 2)
        self.assertIn(f"gke: variant a has two sha256 values, {'a' * 64} and {'d' * 64}", stderr)


if __name__ == "__main__":
    unittest.main()
