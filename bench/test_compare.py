"""Tests of the benchmark comparison, bench/compare.py.

Each test writes two small summaries, as bench/bench.py run (or
scripts/gke-bench.sh) writes summary.json, and runs the comparison through
its command line. They need python3 alone.

usage: python3 -m unittest discover -s bench -v
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent

# The rule of the tests: worse by more than 20% and by more than 1 ms, and
# p99.9 only where both runs measured at least 10,000 requests.
RULE = {"more_than_percent": 20, "more_than_ms": 1, "p99_9_min_requests": 10000}

# The heading of the steps shown for reference.
REFERENCE = "## For reference: steps above the target rate"


def step(profile="small", case="http-keep-alive", rate=1000, p99=10.0, p99_9=20.0, errors=0, late=False,
         cpu_limit="250m", memory_limit="512Mi", smock_ready=True, requests=None):
    """One step of a summary: a case under a profile at a rate, with these
    latencies (ms), failed requests, whether the load generator fell
    behind, and the requests it scheduled (20 seconds' worth unless
    given)."""
    scheduled = rate * 20 if requests is None else requests
    return {
        "id": f"{case}@{profile}@{rate}", "case": case, "profile": profile, "cpu_limit": cpu_limit,
        "memory_limit": memory_limit, "rate": rate, "achieved_rate": (scheduled - errors) / 20, "errors": errors,
        "latency_ms": {"p50": 1.0, "p90": 1.5, "p99": p99, "p99_9": p99_9, "max": 30.0},
        "generator_lag_ms": {"p50": 1.0, "p99": 2.0, "p99_9": 25.0 if late else 2.1, "max": 26.0 if late else 3.0},
        "load_generator_late": late,
        "requests": {"scheduled": scheduled, "ok": scheduled - errors, "unexpected_status": 0, "no_response": errors},
        "memory": {"peak_bytes": None, "oom_kills": 0},
        "smock_ready": smock_ready,
    }


def capacity(profile="small", rate=1000, case="http-keep-alive"):
    """A profile's entry of a targets file, whose target holds at `rate`."""
    return {"profile": profile, "cpu_limit": "250m", "memory_limit": "512Mi", "case": case, "rate": rate,
            "at_most": {"p99_ms": 3}}


def target(target_id="small/p99", verdict="met", measured=2.0, maximum=3, reason=None, about=None):
    """A checked target of a summary."""
    profile, metric = target_id.split("/")
    return {"id": target_id, "about": about or f"{metric} latency, http-keep-alive at 1,000 requests/s",
            "profile": profile, "cpu_limit": "250m", "memory_limit": "512Mi", "case": "http-keep-alive",
            "rate": 1000, "metric": metric, "max": maximum, "unit": "ms", "verdict": verdict, "measured": measured,
            "reason": reason}


class Comparison(unittest.TestCase):
    def directory(self):
        path = Path(tempfile.mkdtemp(prefix="smock-compare-test-"))
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def summary(self, steps, targets=(), conditions=None, complete=True, fmt=4):
        """A results directory with summary.json (and conditions.json when
        given), as a run writes it."""
        path = self.directory()
        (path / "summary.json").write_text(json.dumps(
            {"format": fmt, "complete": complete, "idle_rss": [], "cases": list(steps), "targets": list(targets)}))
        if conditions is not None:
            (path / "conditions.json").write_text(json.dumps(conditions))
        return path

    def compare(self, older, newer, rule=RULE, profiles=()):
        """Runs bench/compare.py on two results directories, with a targets
        file that holds `rule` and the entries of `profiles`. Returns the
        exit status and the report."""
        targets = self.directory() / "targets.json"
        targets.write_text(json.dumps({"regression": rule, "profiles": list(profiles)}))
        result = subprocess.run([sys.executable, str(BENCH / "compare.py"), str(older), str(newer),
                                 "--targets", str(targets)], capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def row(self, report, profile, case, rate, heading="## Latency"):
        """The cells of the row for one step of the table under `heading`,
        by column."""
        section = report.split(f"\n{heading}\n", 1)[1].split("\n## ", 1)[0]
        lines = [line for line in section.splitlines() if line.startswith("|")]
        header = [cell.strip() for cell in lines[0].strip("|").split("|")]
        for line in lines[2:]:
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            row = dict(zip(header, cells))
            if (row["Profile"], row["Case"], row["Rate"]) == (profile, case, f"{rate:,}"):
                return row
        self.fail(f"no row for {case}@{profile}@{rate} in:\n{report}")


class Regressions(Comparison):
    """A regression is p99 or p99.9 worse by more than the rule's percentage
    and by more than its milliseconds, at the same profile, case and rate."""

    def test_a_p99_worse_by_more_than_the_rule_is_a_regression_and_fails_the_comparison(self):
        older = self.summary([step(p99=10.0, p99_9=20.0)])
        newer = self.summary([step(p99=12.5, p99_9=20.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        row = self.row(report, "small", "http-keep-alive", 1000)
        self.assertEqual((row["p99 ms"], row["p99 change"]), ("10.0 → 12.5", "+25%"))
        self.assertEqual(row["Verdict"], "regression")

    def test_a_p99_9_worse_by_more_than_the_rule_is_a_regression_too(self):
        older = self.summary([step(p99=10.0, p99_9=20.0)])
        newer = self.summary([step(p99=10.0, p99_9=30.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        row = self.row(report, "small", "http-keep-alive", 1000)
        self.assertEqual((row["p99.9 ms"], row["p99.9 change"], row["Verdict"]), ("20.0 → 30.0", "+50%", "regression"))
        self.assertIn("1 regression", report)

    def test_a_change_within_the_percentage_or_within_the_milliseconds_is_no_regression(self):
        # p99 is 19% worse; p99.9 is 45% worse, but by 0.9 ms, less than
        # oha's timer resolves.
        older = self.summary([step(rate=1000, p99=10.0, p99_9=2.0), step(rate=2000, p99=8.0, p99_9=9.0)])
        newer = self.summary([step(rate=1000, p99=11.9, p99_9=2.9), step(rate=2000, p99=4.0, p99_9=9.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"], "ok")
        better = self.row(report, "small", "http-keep-alive", 2000)
        self.assertEqual((better["p99 change"], better["p99.9 change"], better["Verdict"]), ("-50%", "0%", "ok"))
        self.assertIn("No regression", report)

    def test_requests_the_newer_run_failed_or_a_smock_that_never_got_ready_are_regressions(self):
        older = self.summary([step(rate=1000), step(rate=2000), step(rate=4000)])
        newer = self.summary([step(rate=1000, errors=300), step(rate=2000, p99=None, p99_9=None, errors=40000,
                                                                smock_ready=False), step(rate=4000)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        failed = self.row(report, "small", "http-keep-alive", 1000)
        self.assertEqual(failed["Verdict"], "regression: 300 of 20000 requests failed in the newer run")
        not_ready = self.row(report, "small", "http-keep-alive", 2000)
        self.assertEqual(not_ready["Verdict"], "regression: smock was not ready in the newer run")
        self.assertEqual(not_ready["p99 ms"], "10.0 → -")
        self.assertIn("2 regressions", report)


class CountedSteps(Comparison):
    """Only steps at or below their profile's target rate count. Above it,
    smock may be past its capacity, and the latencies of a queue swing from
    run to run: those steps are shown for reference, never counted."""

    def test_a_step_above_its_profiles_target_rate_is_shown_for_reference_and_does_not_fail(self):
        older = self.summary([step(rate=1000, p99=10.0), step(rate=2000, p99=10.0)])
        newer = self.summary([step(rate=1000, p99=10.5), step(rate=2000, p99=40.0)])
        status, report = self.compare(older, newer, profiles=[capacity("small", 1000)])
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"], "ok")
        above = self.row(report, "small", "http-keep-alive", 2000, heading=REFERENCE)
        self.assertEqual((above["p99 ms"], above["p99 change"], above["Verdict"]), ("10.0 → 40.0", "+300%", "worse"))
        self.assertNotIn("| 2,000 |", report.split(REFERENCE)[0])
        self.assertIn("**Result:** No regression, no target missed.", report)

    def test_a_step_at_its_profiles_target_rate_counts_whatever_its_case_and_a_profile_with_no_target_counts_at_every_rate(self):
        # small's target is http-keep-alive at 1,000 a second; its rate
        # holds for every case of small. other has no target.
        older = self.summary([step(rate=1000, p99=10.0), step(case="http-close", rate=2000, p99=10.0),
                              step(profile="other", rate=50000, p99=10.0)])
        newer = self.summary([step(rate=1000, p99=15.0), step(case="http-close", rate=2000, p99=40.0),
                              step(profile="other", rate=50000, p99=15.0)])
        status, report = self.compare(older, newer, profiles=[capacity("small", 1000)])
        self.assertEqual(status, 1, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"], "regression")
        self.assertEqual(self.row(report, "other", "http-keep-alive", 50000)["Verdict"], "regression")
        self.assertEqual(self.row(report, "small", "http-close", 2000, heading=REFERENCE)["Verdict"], "worse")
        self.assertIn("**Result:** 2 regressions, no target missed.", report)

    def test_above_the_target_rate_failed_requests_and_steps_the_newer_run_did_not_measure_do_not_fail(self):
        # The newer run failed requests at 2,000 a second, its load
        # generator fell behind at 4,000, and it stopped before 8,000.
        older = self.summary([step(rate=1000), step(rate=2000), step(rate=4000), step(rate=8000)])
        newer = self.summary([step(rate=1000), step(rate=2000, errors=300), step(rate=4000, p99=50.0, late=True)],
                             complete=False)
        status, report = self.compare(older, newer, profiles=[capacity("small", 1000)])
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 2000, heading=REFERENCE)["Verdict"],
                         "300 of 40000 requests failed in the newer run")
        self.assertEqual(self.row(report, "small", "http-keep-alive", 4000, heading=REFERENCE)["Verdict"],
                         "not compared: the load generator fell behind in the newer run")
        self.assertIn("Only in the older run: http-keep-alive@small@8000.", report.split(REFERENCE)[1])
        self.assertIn("**Result:** No regression, no target missed.", report)

    def test_a_profile_with_entries_at_several_rates_counts_up_to_the_highest(self):
        older = self.summary([step(rate=1000, p99=10.0), step(rate=2000, p99=10.0), step(rate=4000, p99=10.0)])
        newer = self.summary([step(rate=1000, p99=10.0), step(rate=2000, p99=40.0), step(rate=4000, p99=40.0)])
        for entries in ([capacity("small", 2000), capacity("small", 1000, case="https-keep-alive")],
                        [capacity("small", 1000, case="https-keep-alive"), capacity("small", 2000)]):
            status, report = self.compare(older, newer, profiles=entries)
            self.assertEqual(status, 1, report)
            self.assertEqual(self.row(report, "small", "http-keep-alive", 2000)["Verdict"], "regression")
            self.assertEqual(self.row(report, "small", "http-keep-alive", 4000, heading=REFERENCE)["Verdict"],
                             "worse")
            self.assertIn("**Result:** 1 regression, no target missed.", report)

    def test_the_report_says_which_steps_count(self):
        # unused has a target but neither run ran it.
        runs = [step(rate=1000), step(rate=2000), step(profile="other", rate=4000)]
        _, report = self.compare(self.summary(runs), self.summary(runs),
                                 profiles=[capacity("small", 1000), capacity("unused", 50)])
        self.assertIn("\nA step counts when its rate is at most its profile's target rate (small 1,000 requests/s), "
                      "or its profile has no target (other); steps above it are shown for reference and do not count. "
                      "A step is a regression when p99 or p99.9 got worse by more than 20% and by more than 1 ms; "
                      "p99.9 counts only where both runs measured at least 10,000 requests at the step.\n", report)
        _, report = self.compare(self.summary(runs), self.summary(runs))
        self.assertIn("\nEvery step counts. A step is a regression when", report)
        self.assertNotIn(REFERENCE, report)


class FewRequests(Comparison):
    """p99.9 counts only where both runs measured at least the rule's number
    of requests: with fewer, it rests on a few of the slowest requests and
    swings from run to run. Its change is still shown, for reference, and
    p99 still counts."""

    def test_a_p99_9_worse_at_a_step_with_fewer_requests_is_shown_for_reference_and_p99_still_counts(self):
        # At 250 a second for 20 seconds, a step measures 5,000 requests:
        # its p99.9 is the fifth slowest.
        older = self.summary([step(rate=250, p99=10.0, p99_9=20.0), step(rate=400, p99=10.0, p99_9=20.0)])
        newer = self.summary([step(rate=250, p99=10.0, p99_9=30.0), step(rate=400, p99=15.0, p99_9=20.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        few = self.row(report, "small", "http-keep-alive", 250)
        self.assertEqual((few["p99.9 ms"], few["p99.9 change"], few["Verdict"]),
                         ("20.0 → 30.0", "+50% (for reference)", "ok"))
        p99 = self.row(report, "small", "http-keep-alive", 400)
        self.assertEqual((p99["p99 change"], p99["p99.9 change"], p99["Verdict"]),
                         ("+50%", "0% (for reference)", "regression"))
        self.assertIn("**Result:** 1 regression, no target missed.", report)

    def test_p99_9_counts_where_both_runs_measured_at_least_the_rules_number_of_requests(self):
        older = self.summary([step(rate=1000, p99_9=20.0), step(rate=2000, p99_9=20.0, requests=10000)])
        newer = self.summary([step(rate=1000, p99_9=30.0, requests=8000), step(rate=2000, p99_9=30.0, requests=10000)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"], "ok")
        at_least = self.row(report, "small", "http-keep-alive", 2000)
        self.assertEqual((at_least["p99.9 change"], at_least["Verdict"]), ("+50%", "regression"))
        # The number is the rule's: with 5,000, both steps count.
        status, report = self.compare(older, newer, rule={**RULE, "p99_9_min_requests": 5000})
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"], "regression")


class MissedTargets(Comparison):
    """The targets the newer run missed are listed, and fail the
    comparison, whatever the older run did."""

    def test_each_target_the_newer_run_missed_is_listed_with_what_it_measured(self):
        older = self.summary([step()], targets=[target("small/p99", "met", 2.0), target("small/p99_9", "missed", 12)])
        newer = self.summary([step()], targets=[
            target("small/p99", "missed", 3.4),
            target("small/p99_9", "missed", 11, maximum=10, about="p99.9 latency, http-keep-alive at 1,000 requests/s"),
            target("small/peak_memory", "not measured", None, reason="the kernel kept no peak memory"),
            target("small/idle_rss", "met", 16.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        self.assertIn("- small/p99 (p99 latency, http-keep-alive at 1,000 requests/s): 3.4 ms, at most 3 ms; "
                      "met in the older run (2.0 ms)", report)
        self.assertIn("- small/p99_9 (p99.9 latency, http-keep-alive at 1,000 requests/s): 11 ms, at most 10 ms; "
                      "missed in the older run too (12 ms)", report)
        self.assertNotIn("small/idle_rss", report)
        self.assertIn("Not measured in the newer run: small/peak_memory.", report)
        self.assertIn("2 targets missed", report)

    def test_a_target_missed_for_failed_requests_says_why(self):
        newer = self.summary([step()], targets=[target("small/p99", "missed", 2.0, reason="300 errors")])
        status, report = self.compare(self.summary([step()]), newer)
        self.assertEqual(status, 1, report)
        self.assertIn("- small/p99 (p99 latency, http-keep-alive at 1,000 requests/s): 2.0 ms, at most 3 ms: "
                      "300 errors; not in the older run", report)

    def test_no_missed_target_and_no_regression_passes(self):
        newer = self.summary([step()], targets=[target("small/p99", "met", 2.0)])
        status, report = self.compare(self.summary([step()]), newer)
        self.assertEqual(status, 0, report)
        self.assertIn("Targets missed in the newer run: none.", report)
        self.assertIn("**Result:** No regression, no target missed.", report)


class NotCompared(Comparison):
    """Only steps that measured smock in both runs, under the same limits,
    are compared."""

    def test_steps_that_only_one_run_has_are_listed_but_not_compared(self):
        # The older run did not measure smock at 8,000 a second.
        older = self.summary([step(rate=1000), step(rate=8000, p99=900.0, errors=5)])
        newer = self.summary([step(rate=1000), step(rate=4000), step(profile="other", rate=2000, p99=50.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertIn("Only in the older run: http-keep-alive@small@8000.", report)
        self.assertIn("Only in the newer run: http-keep-alive@small@4000, http-keep-alive@other@2000.", report)

    def test_a_step_where_the_older_run_failed_requests_or_a_load_generator_fell_behind_is_not_compared(self):
        # Past its capacity, a run's latencies are its queue: they say how
        # far over capacity the step was, not how fast smock is.
        older = self.summary([step(rate=1000, p99=10.0, errors=5), step(rate=2000, p99=10.0, late=True)])
        newer = self.summary([step(rate=1000, p99=500.0, errors=900), step(rate=2000, p99=50.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"],
                         "not compared: 5 of 20000 requests failed in the older run")
        self.assertEqual(self.row(report, "small", "http-keep-alive", 2000)["Verdict"],
                         "not compared: the load generator fell behind in the older run")

    def test_a_step_the_older_run_measured_and_the_newer_did_not_fails_the_comparison(self):
        # The newer run's load generator fell behind at 2,000 a second, and
        # the run stopped before 4,000: nothing says how smock did there.
        older = self.summary([step(rate=1000), step(rate=2000), step(rate=4000)])
        newer = self.summary([step(rate=1000), step(rate=2000, p99=50.0, late=True)], complete=False)
        status, report = self.compare(older, newer)
        self.assertEqual(status, 1, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 2000)["Verdict"],
                         "not compared: the load generator fell behind in the newer run")
        self.assertIn("Only in the older run: http-keep-alive@small@4000.", report)
        self.assertIn("**Result:** No regression, no target missed, 2 steps the older run measured not measured "
                      "in the newer one.", report)

    def test_a_profile_run_under_other_limits_is_not_compared(self):
        older = self.summary([step(profile="chart-default", cpu_limit="1", memory_limit="4Gi", p99=2.0)])
        newer = self.summary([step(profile="chart-default", cpu_limit="1", memory_limit="1Gi", p99=9.0)])
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "chart-default", "http-keep-alive", 1000)["Verdict"],
                         "not compared: the older run had 1 CPU and 4Gi, the newer 1 CPU and 1Gi")


def conditions(version="0.1.0", commit="a21fe97d59c6", architecture="arm64", cpu_model="Apple M1", cpus=8,
               plan_sha="aa", oha="oha 1.16.0", gke=None):
    """The parts of conditions.json the comparison reads."""
    value = {"started_at": "2026-10-14T03:13:18+00:00",
             "smock": {"version": version, "commit": commit, "toolchain": "moonc v0.10.14"},
             "definitions": {"digest": "48f7ce9715f0"},
             "request_mix": {"file": "bench/requests.json", "sha256": "bb"},
             "plan": {"file": "bench/plan-autopilot.json", "sha256": plan_sha},
             "machine": {"architecture": architecture, "cpu_model": cpu_model, "cpus": cpus},
             "load_generator": {"name": "oha", "version": oha}, "overrides": {}}
    if gke:
        value["gke"] = gke
    return value


class Conditions(Comparison):
    """The report names each run, and says where their conditions differ
    in more than smock."""

    def test_each_run_is_named_and_conditions_beyond_smock_that_differ_are_listed(self):
        older = self.summary([step()], conditions=conditions(version="0.1.0", commit="1111"))
        newer = self.summary([step()], conditions=conditions(version="0.2.0", commit="2222", cpu_model="Apple M2",
                                                             plan_sha="cc"))
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertIn("- Older: smock 0.1.0 (commit 1111) on arm64 (Apple M1, 8 CPUs), "
                      "plan bench/plan-autopilot.json, started 2026-10-14T03:13:18+00:00.", report)
        self.assertIn("- Newer: smock 0.2.0 (commit 2222) on arm64 (Apple M2, 8 CPUs)", report)
        self.assertIn("Besides smock, the runs differ in: machine (arm64 (Apple M1, 8 CPUs) → arm64 (Apple M2, "
                      "8 CPUs)), plan (bench/plan-autopilot.json changed).", report)

    def test_a_gke_run_compared_with_a_run_on_a_machine_is_called_out(self):
        gke = {"region": "us-central1", "zone": "us-central1-a", "compute_class": "autopilot-arm"}
        older = self.summary([step()], conditions=conditions())
        newer = self.summary([step()], conditions=conditions(cpu_model="GKE Autopilot e4a-standard-8", gke=gke))
        _, report = self.compare(older, newer)
        self.assertIn("- Newer: smock 0.1.0 (commit a21fe97d59c6) on GKE Autopilot (us-central1-a, autopilot-arm), "
                      "arm64 (GKE Autopilot e4a-standard-8, 8 CPUs)", report)
        self.assertIn("One run is on GKE Autopilot and the other is not: compare runs of the same kind.", report)

    def test_runs_on_different_architectures_are_not_compared_as_regressions(self):
        # An arm64 GKE run and an amd64 one: the newer is far slower, which
        # says nothing of smock. Its missed targets still count.
        older_gke = {"region": "us-central1", "zone": "us-central1-a", "compute_class": "autopilot-arm",
                     "arch": "arm64", "machine_type": "e4a-standard-8"}
        newer_gke = {"region": "asia-northeast1", "zone": "asia-northeast1-b", "compute_class": "general-purpose",
                     "arch": "amd64", "machine_type": "ek-standard-8"}
        older = self.summary([step(p99=10.0)], conditions=conditions(cpu_model="GKE Autopilot e4a-standard-8",
                                                                     gke=older_gke))
        newer = self.summary([step(p99=30.0)], conditions=conditions(
            architecture="amd64", cpu_model="GKE Autopilot ek-standard-8", gke=newer_gke))
        status, report = self.compare(older, newer)
        self.assertEqual(status, 0, report)
        self.assertEqual(self.row(report, "small", "http-keep-alive", 1000)["Verdict"],
                         "not compared: the older run ran on arm64, the newer on amd64")
        self.assertIn("The runs ran on different architectures (arm64 → amd64): no step is compared as a regression.",
                      report)
        self.assertIn("architecture (arm64 → amd64)", report)
        self.assertIn("No regression", report)
        # A step only the older run measured does not fail it either; a
        # run on a machine names its architecture as the kernel does.
        status, report = self.compare(self.summary([step(), step(rate=2000)], conditions=conditions()),
                                      self.summary([step()], conditions=conditions(architecture="x86_64")))
        self.assertEqual(status, 0, report)
        self.assertIn("different architectures (arm64 → amd64)", report)
        missed = self.summary([step()], targets=[target(verdict="missed", measured=4.0)],
                              conditions=conditions(architecture="amd64"))
        self.assertEqual(self.compare(older, missed)[0], 1)

    def test_a_run_that_stopped_before_its_last_step_is_called_incomplete(self):
        _, report = self.compare(self.summary([step()]), self.summary([step()], complete=False))
        self.assertIn("The newer run is incomplete: it stopped before its last step.", report)

    def test_runs_without_conditions_or_with_the_same_ones_say_so(self):
        same = self.compare(self.summary([step()], conditions=conditions(commit="1111")),
                            self.summary([step()], conditions=conditions(commit="2222")))[1]
        self.assertIn("Besides smock, the runs had the same conditions.", same)
        missing = self.compare(self.summary([step()]), self.summary([step()]))[1]
        self.assertIn("- Older: no conditions.json beside its summary.", missing)


class Inputs(Comparison):
    def test_summaries_it_cannot_read_or_compare_stop_it_with_status_2(self):
        good = self.summary([step()])
        for older, expected in ((self.directory(), "cannot read"),
                                (self.summary([step()], fmt=3), "has format 3")):
            status, report = self.compare(older, good)
            self.assertEqual(status, 2, report)
            self.assertIn(expected, report)
        for rule in (None, {"more_than_percent": 20, "more_than_ms": 1}):
            status, report = self.compare(good, good, rule=rule)
            self.assertEqual(status, 2, report)
            self.assertIn("no regression rule", report)

    def test_the_rule_is_the_maintainers_decision_kept_with_the_targets(self):
        rule = json.loads((BENCH / "targets.json").read_text())["regression"]
        self.assertEqual((rule["more_than_percent"], rule["more_than_ms"], rule["p99_9_min_requests"]), (20, 1, 10000))


if __name__ == "__main__":
    unittest.main()
