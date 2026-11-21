"""Confirms the mutation runner's kills and time-outs against flaky tests,
and keeps each test's flake rate (CONTRIBUTING.md, "Outcomes and kill
credit" and "Mutation runner"). scripts/mutation/run.py makes one Judge for
a run, and asks it about each run of tests without a mutant and about each
kill and time-out.

A kill counts only when the tests that failed fail again with the mutant
on and pass with it off. A time-out counts only when the mutant times out
again and the run without it finishes within the limit. Otherwise the
mutant is unconfirmed: it counts neither as killed nor as survived, and
the record says why. The tests without a mutant run twice before any
mutant, and a test that fails in either run gives no kill credit in that
run. Nor does a test whose flake rate, over the latest runs whose flake
records the runner reads, is above the flake threshold.

A test's flake rate is the share of its runs that gave a flaky result: a
failure without a mutant, in a run without a mutant or in the run without
the mutant that confirms a kill, or a pass when a kill is run again with
the mutant on. Every test of a package runs whenever its package's tests
run without a mutant, so a run's record counts those runs per package, and
per test its failures, its reruns with a mutant on, and its flaky results
among them. The threshold and the number of recent runs are the
maintainer's, in mutation/flakes.toml.

A test is named by its package, its file and its name, as moon names it;
a test with no name, by `#` and its index in the file instead.

usage: python3 scripts/mutation/confirm.py merge <flakes.json>...

merges the flake records that the shards of one run wrote, each with the
records of the same earlier runs, into one: the earlier runs, and this
run's counts summed over the shards. It prints them, as the runner writes
flakes.json.
"""

import json
import sys
import threading
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The flake threshold and the number of recent runs it is taken over.
POLICY = HERE.parent.parent / "mutation" / "flakes.toml"
# The version of the flake records' format.
VERSION = 1


def load_policy(path=POLICY):
    """The flake threshold and the number of recent runs, from the policy
    file."""
    with open(path, "rb") as f:
        policy = tomllib.load(f)
    threshold, recent = policy["threshold"], policy["recent_runs"]
    if not 0 <= threshold < 1 or not isinstance(recent, int) or recent < 1:
        raise ValueError(f"{path}: the threshold must be from 0 to below 1, and recent_runs at least 1")
    return threshold, recent


def key(test):
    """A test's name: its package, its file and its name, or, for a test
    that has none, `#` and its index in the file, by which alone moon tells
    such tests apart."""
    name = test.get("name") or f"#{test.get('index')}"
    return test.get("package"), test.get("file"), name


def named(test_key):
    """A test's fields, from its name."""
    return dict(zip(("package", "file", "name"), test_key))


def ended(status, timed_out, failed):
    """How a run of tests ended, as a record keeps it ("ended"): its exit
    status, whether the time limit stopped it, and how many failed tests
    it named."""
    return {"exit_status": status, "timed_out": timed_out, "failed_tests": len(failed)}


class Judge:
    """What a run knows of flaky tests: the flake records it read, which
    tests give no kill credit, and what this run has seen."""

    def __init__(self, runs, threshold, recent, failed_tests, error):
        self.runs = runs[-recent:]
        self.threshold = threshold
        self.recent = recent
        self.failed_tests = failed_tests
        self.error = error
        self.lock = threading.Lock()
        # This run's record: runs without a mutant per package, and per
        # test its failures without a mutant, its reruns with a mutant on,
        # and its passes among them.
        self.suites = {}
        self.tests = {}
        self.above = {k: r for k, r in self.rates(self.runs).items() if r["rate"] > threshold}
        self.no_credit = set(self.above)

    @classmethod
    def read(cls, path, failed_tests, error, policy=POLICY):
        """A judge with the flake records of path, the runner's flakes.json
        of an earlier run, or none."""
        try:
            threshold, recent = load_policy(policy)
        except (OSError, ValueError, KeyError) as problem:
            raise error(f"cannot read the flake threshold in {policy}: {problem}") from problem
        runs = []
        if path is not None:
            try:
                data = json.loads(Path(path).read_text(encoding="utf-8"))
            except (OSError, ValueError) as problem:
                raise error(f"cannot read the flake records {path}: {problem}") from problem
            if not isinstance(data, dict) or data.get("version") != VERSION:
                raise error(f"{path} holds no flake records of version {VERSION}")
            runs = data["runs"]
        return cls(runs, threshold, recent, failed_tests, error)

    @staticmethod
    def rates(runs):
        """Each test's flaky results, runs and flake rate over runs, for the
        tests with a flaky result."""
        suites, tests = {}, {}
        for one in runs:
            for package, n in one["suites"].items():
                suites[package] = suites.get(package, 0) + n
            for test in one["tests"]:
                counts = tests.setdefault(key(test), [0, 0])
                counts[0] += test["flaked"]
                counts[1] += test["reruns"]
        rates = {}
        for test_key, (flaked, reruns) in tests.items():
            observed = suites.get(test_key[0], 0) + reruns
            if flaked:
                rates[test_key] = {"flaked": flaked, "observed": observed,
                                   "rate": round(flaked / observed, 6) if observed else 1.0}
        return rates

    def split(self, tests):
        """The tests that give kill credit, and those that give none."""
        return ([t for t in tests if key(t) not in self.no_credit],
                [t for t in tests if key(t) in self.no_credit])

    def suite(self, packages, failed):
        """Counts a run without a mutant of the tests of packages, in which
        the tests failed."""
        with self.lock:
            for package in packages:
                self.suites[package] = self.suites.get(package, 0) + 1
            for test in failed:
                self.tests.setdefault(key(test), [0, 0])[0] += 1

    def baseline(self, packages, runs):
        """Counts the two runs without a mutant before any mutant, each one's
        failed tests given: each test that failed, with the runs it failed
        in. Those tests give no kill credit in this run."""
        failed = {}
        for number, tests in enumerate(runs, start=1):
            self.suite(packages, tests)
            for test in tests:
                failed.setdefault(key(test), []).append(number)
        with self.lock:
            self.no_credit |= set(failed)
        return [dict(named(k), runs=numbers) for k, numbers in sorted(failed.items(), key=str)]

    def rerun(self, tests, again):
        """Counts a kill's run again with the mutant on: tests failed the
        first time, and the names in again failed this time."""
        with self.lock:
            for test in tests:
                counts = self.tests.setdefault(key(test), [0, 0])
                counts[1] += 1
                if key(test) not in again:
                    counts[0] += 1

    def run_with(self, worker, package, path, content, limit):
        """Builds and runs the tests of package with path holding content:
        (exit status, output, seconds, whether it timed out)."""
        path.write_text(content, encoding="utf-8")
        status, output, _ = worker.build(package)
        if status != 0:
            raise self.error(f"{path} does not build again as it built before:\n{output}")
        return worker.moon_test(package, limit, build_only=False)

    def confirm(self, worker, package, path, text, mutated, record, limit):
        """Confirms a record's kill or time-out, or makes it unconfirmed,
        and leaves path holding text. A kill whose failed tests all give no
        kill credit is a survivor."""
        packages = [package] if isinstance(package, str) else package
        if record["outcome"] == "killed":
            credited, uncredited = self.split(record["killing_tests"])
            if uncredited:
                record["no_credit"] = uncredited
            if uncredited and not credited:
                record.update(outcome="survived", killing_tests=[],
                              confirmation="only tests that give no kill credit failed")
                return
        elif record["outcome"] != "timed out":
            return
        timings = record["timings"]
        runs = record.setdefault("ended", {})
        try:
            status, output, seconds, timed_out = self.run_with(worker, package, path, mutated, limit)
        finally:
            path.write_text(text, encoding="utf-8")
        timings["again_s"] = round(seconds, 3)
        failed = self.failed_tests(output)
        runs["again"] = ended(status, timed_out, failed)
        if record["outcome"] == "killed":
            if timed_out or status != 0 and not failed:
                # A run again that the limit stopped, or that failed
                # without naming a test, did not pass: it repeats the kill,
                # and no test is flaky by it.
                repeated = credited
            else:
                again = {key(t) for t in failed}
                self.rerun(credited, again)
                repeated = [t for t in credited if key(t) in again]
                if credited and not repeated or not credited and status == 0:
                    return self.unconfirmed(record, "the tests that failed passed when run again with the mutant on")
        elif not timed_out:
            return self.unconfirmed(record, "the mutant did not time out again")
        status, output, seconds, timed_out = self.run_with(worker, package, path, text, limit)
        timings["without_s"] = round(seconds, 3)
        failed = self.failed_tests(output)
        runs["without"] = ended(status, timed_out, failed)
        if timed_out:
            return self.unconfirmed(record, "the run without the mutant did not finish within the limit")
        self.suite(packages, failed)
        if record["outcome"] == "killed":
            without = {key(t) for t in failed}
            confirmed = [t for t in repeated if key(t) not in without]
            if credited and not confirmed or not credited and status != 0:
                return self.unconfirmed(record, "the tests that failed fail without the mutant too")
            record["killing_tests"] = confirmed
        record["confirmation"] = "confirmed"

    @staticmethod
    def unconfirmed(record, reason):
        """Makes a record's kill or time-out unconfirmed, for a reason."""
        record.update(outcome="unconfirmed", first_outcome=record["outcome"], confirmation=reason,
                      failed_first=record.pop("killing_tests"), killing_tests=[])

    def this_run(self):
        """This run's flake record."""
        with self.lock:
            tests = [dict(named(k), flaked=c[0], reruns=c[1]) for k, c in sorted(self.tests.items(), key=str)]
            return {"suites": dict(sorted(self.suites.items())), "tests": tests}

    def records(self):
        """The flake records to keep for the next run: the latest runs, this
        one included, and each test's rate over them."""
        return records_of((self.runs + [self.this_run()])[-self.recent:], self.threshold, self.recent)

    def summary(self):
        """What the summary says of flaky tests: the threshold, the runs read,
        the tests above it, and the tests with a flaky result in this run."""
        mine = self.rates([self.this_run()])
        return {
            "threshold": self.threshold,
            "recent_runs": self.recent,
            "runs_read": len(self.runs),
            "above": [dict(named(k), **r) for k, r in sorted(self.above.items(), key=str)],
            "flaked": [dict(named(k), **r) for k, r in sorted(mine.items(), key=str)],
        }

    @staticmethod
    def baseline_lines(summary):
        """The line of a package's report that names the tests that failed
        without a mutant in its runs, if any did."""
        failed = summary.get("baseline", {}).get("failed", [])
        found = summary.get("importers", {}).get("baseline", {}).get("failed", [])
        out = []
        for title, tests in (("Tests that failed without a mutant", failed),
                             ("Its importers' tests that failed without a mutant", found)):
            if tests:
                named_tests = ", ".join(f"`{t['name']}` ({t['package']}, {t['file']}, "
                                        f"{'run' if len(t['runs']) == 1 else 'runs'}"
                                        f" {' and '.join(map(str, t['runs']))})" for t in tests)
                out += [f"{title}, which give no kill credit in this run: {named_tests}.", ""]
        return out

    def report_lines(self):
        """The report's section on flaky tests."""
        return summary_lines(self.summary())


def summary_lines(summary):
    """The report's section on flaky tests, from what the summary says of
    them."""
    out = ["## Flaky tests", "",
           f"Flake threshold {summary['threshold']:.2%} of a test's runs, over the latest {summary['recent_runs']}"
           f" runs; this run read the records of {summary['runs_read']}.", ""]
    for title, tests in (("Above the threshold, so they give no kill credit in this run", summary["above"]),
                         ("A flaky result in this run", summary["flaked"])):
        out += [f"{title}: {'none' if not tests else len(tests)}.", ""]
        out += [f"- `{t['name']}` ({t['package']}, {t['file']}): {t['flaked']} of {t['observed']} runs,"
                f" {t['rate']:.2%}" for t in tests]
        if tests:
            out += [""]
    return out


def records_of(runs, threshold, recent):
    """The flake records of runs, as flakes.json holds them, with each
    test's rate over them."""
    rates = Judge.rates(runs)
    return {
        "version": VERSION,
        "threshold": threshold,
        "recent_runs": recent,
        "runs": runs,
        "rates": [dict(named(k), **r) for k, r in sorted(rates.items(), key=lambda i: (-i[1]["rate"], str(i[0])))],
    }


def merge(shards):
    """One run's flake records, from those its shards wrote: the earlier
    runs, which every shard read alike, and this run's counts summed."""
    first = shards[0]
    for shard in shards:
        if shard.get("version") != VERSION:
            raise ValueError(f"a shard holds no flake records of version {VERSION}")
        if (shard["runs"][:-1], shard["threshold"], shard["recent_runs"]) != (
                first["runs"][:-1], first["threshold"], first["recent_runs"]):
            raise ValueError("the shards did not read the same flake records, so they are not one run")
    suites, tests = {}, {}
    for shard in shards:
        mine = shard["runs"][-1]
        for package, n in mine["suites"].items():
            suites[package] = suites.get(package, 0) + n
        for test in mine["tests"]:
            counts = tests.setdefault(key(test), [0, 0])
            counts[0] += test["flaked"]
            counts[1] += test["reruns"]
    this = {"suites": dict(sorted(suites.items())),
            "tests": [dict(named(k), flaked=c[0], reruns=c[1]) for k, c in sorted(tests.items(), key=str)]}
    return records_of(first["runs"][:-1] + [this], first["threshold"], first["recent_runs"])


def merged_summary(summaries, records):
    """What the summary of a run in shards says of flaky tests, from its
    shards' summaries and its merged flake records (merge): the threshold,
    the runs read and the tests above it, which every shard read alike,
    and the flaky results of this run over all its shards."""
    mine = Judge.rates([records["runs"][-1]])
    return dict(summaries[0], flaked=[dict(named(k), **r) for k, r in sorted(mine.items(), key=str)])


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "merge":
        print("usage: python3 scripts/mutation/confirm.py merge <flakes.json>...", file=sys.stderr)
        sys.exit(2)
    try:
        shards = [json.loads(Path(path).read_text(encoding="utf-8")) for path in sys.argv[2:]]
        print(json.dumps(merge(shards), indent=2, ensure_ascii=False))
    except (OSError, ValueError, KeyError) as problem:
        print(f"confirm: {problem}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
