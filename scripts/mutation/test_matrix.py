"""Tests of the mutation runner's kill-matrix mode (run.py --matrix) and of
the tool that reads the matrix (scripts/mutation/matrix.py), through their
command lines, on the fixture module scripts/mutation/fixture (#306).

In kill-matrix mode, each mutant runs against its own package's tests and
all its importers' tests at once, whatever kills it first, with no early
stop, and its record lists every test that kills it, with its package and
layer (#306, first criterion; #275, "Kill credit, pure packages": "Only
kill-matrix mode ... runs every covering test for every mutant"). Kill
confirmation applies to each test in the matrix: a test credited with a
kill fails with the mutant on and passes with it off (#306, second
criterion; #275, "Kill confirmation"). The tool answers which tests alone
kill some mutant, and which mutants a given set of tests kills (#306, third
criterion); with one test left out of a run, the mutants only it killed
are survivors (#306, fourth criterion). It draws the tests of a snapshot
audit as the first three audits were drawn, on small git workspaces of
their own (#306, #275, "Snapshot audits").

The fixture's package units has the importers meter, and dial through
meter, whose tests build on wasm-gc, and probe, which builds only natively
(its comments, and test_mutation.py's ImportersTest). The matrix below is
worked out by hand from what each test checks and what each mutant of
units.mbt changes, as the comments beside units.mbt's sites give it.

They need python3, git, moon and moonc (the toolchain of
.moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixture"
RUN = HERE / "run.py"
MATRIX_TOOL = HERE / "matrix.py"

# The tests of units and of its importers that build on wasm-gc, as moon
# names them: package, file, index in the file, name.
DIAL_HIGH = ("mutation/fixture/dial", "dial_test.mbt", 0, "a reading at the high end of a scale from 0 to 10 is on it")
METER_LOW = ("mutation/fixture/meter", "meter_test.mbt", 0, "a reading at the low end of the scale is on it")
INSIDE = ("mutation/fixture/units", "units_test.mbt", 0, "a number inside the range is in it")
BELOW = ("mutation/fixture/units", "units_test.mbt", 1, "a number below the range is not in it")
PAST = ("mutation/fixture/units", "units_test.mbt", 2, "a number beyond the end of a range is past it")
# units' two tests with no name: 5 in 1 to 9, and 4 in 0 to 8.
FIVE = ("mutation/fixture/units", "units_test.mbt", 3, "")
FOUR = ("mutation/fixture/units", "units_test.mbt", 4, "")

# units' kill matrix: each mutant of the pinned set, its outcome, and every
# test that kills it, in moon's order of the tests.
# - within's BODY `{ false }` fails every test that needs a number in a
#   range: 2 in 1 to 3, 5 in 1 to 9 and 4 in 0 to 8 (units), 1 on a scale
#   from 1 to 3 (meter), and 10 on a scale from 0 to 10 (dial); 0 below 1
#   to 3 still is not in it. No other mutant changes whether a number well
#   inside a range is in it.
# - `low < n` fails only meter's 1 on a scale from 1.
# - `||` fails only units' 0 below the range, which `0 <= 3` lets in.
# - `n < high` fails only dial's 10 on a scale to 10.
# - past's BODY `{ false }` fails only units' 5 past 3.
# - `n >= high` survives: only probe's test has a number at the end, and
#   probe builds only natively.
MATRIX = [
    ("units/units.mbt,within,BODY,{…},{ false },0", "killed", [DIAL_HIGH, METER_LOW, INSIDE, FIVE, FOUR]),
    ("units/units.mbt,within,ROR,<=,<,0", "killed", [METER_LOW]),
    ("units/units.mbt,within,LCR,&&,||,0", "killed", [BELOW]),
    ("units/units.mbt,within,ROR,<=,<,1", "killed", [DIAL_HIGH]),
    ("units/units.mbt,past,BODY,{…},{ false },0", "killed", [PAST]),
    ("units/units.mbt,past,ROR,>,>=,0", "survived", []),
]


def logging_moon(directory):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


def run_runner(root, work, out, moon, *args):
    """Runs run.py on root, writing into out."""
    return subprocess.run([sys.executable, str(RUN), "--root", str(root), "--work", str(work), "--out", str(out),
                           "--moon", str(moon), *args], capture_output=True, text=True)


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in path.read_text(encoding="utf-8").split("\n") if line.strip()]


def matrix_name(test):
    """A test's name in a matrix (CONTRIBUTING.md, "The kill matrix"): its
    package, `/` and file, then `:` and its name, or `#` and its index when
    it has no name."""
    package, file, index, name = test
    return f"{package}/{file}:{name}" if name else f"{package}/{file}#{index}"


def fields(test):
    """A test's fields, as a record gives them, from the tuples above."""
    package, file, index, name = test
    return {"package": package, "file": file, "index": index, "name": name}


class KillMatrixTest(unittest.TestCase):
    """One kill-matrix run of units' pinned set, which the tests read."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.out = cls.tmp / "out"
        cls.result = run_runner(FIXTURE, cls.tmp / "work", cls.out, cls.moon, "--matrix", "units")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = read_lines(cls.out / "mutants.jsonl")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_record_lists_every_test_that_kills_its_mutant_with_its_package_and_layer(self):
        self.assertEqual(
            [(r["id"], r["outcome"], r["killing_tests"]) for r in self.records],
            [(i, outcome, [dict(fields(t), layer="in-process") for t in tests]) for i, outcome, tests in MATRIX])
        # Each record is units' own, whichever package's test killed it.
        self.assertEqual({r["package"] for r in self.records}, {"mutation/fixture/units"})

    def test_a_native_only_importers_tests_never_run(self):
        # probe's test would kill `n >= high`; moon is only asked whether
        # probe builds on wasm-gc.
        runs = [line.split() for line in self.log.read_text().splitlines()
                if "mutation/fixture/probe" in line.split()]
        self.assertTrue(runs)
        for words in runs:
            self.assertIn("--dry-run", words)

    def test_the_matrix_is_written_per_package(self):
        matrix = json.loads((self.out / "matrix" / "units.json").read_text())
        self.assertEqual({k: v for k, v in matrix.items() if k not in ("tests", "mutants")}, {
            "version": 1,
            "package": "mutation/fixture/units",
            "directory": "units",
            "operator_set": "v1",
            "set": "pinned",
            "backend": "wasm-gc",
            "packages": ["mutation/fixture/units", "mutation/fixture/dial", "mutation/fixture/meter"],
            "native_only": ["mutation/fixture/probe"],
        })
        # Every test that ran, in moon's order, each named by its package
        # and file and its name, or its index when it has none.
        self.assertEqual([(t["test"], t["layer"]) for t in matrix["tests"]], [
            (f"mutation/fixture/dial/dial_test.mbt:{DIAL_HIGH[3]}", "in-process"),
            (f"mutation/fixture/meter/meter_test.mbt:{METER_LOW[3]}", "in-process"),
            (f"mutation/fixture/units/units_test.mbt:{INSIDE[3]}", "in-process"),
            (f"mutation/fixture/units/units_test.mbt:{BELOW[3]}", "in-process"),
            (f"mutation/fixture/units/units_test.mbt:{PAST[3]}", "in-process"),
            ("mutation/fixture/units/units_test.mbt#3", "in-process"),
            ("mutation/fixture/units/units_test.mbt#4", "in-process"),
        ])
        self.assertEqual([{k: t[k] for k in ("package", "file", "index", "name")} for t in matrix["tests"]],
                         [fields(t) for t in (DIAL_HIGH, METER_LOW, INSIDE, BELOW, PAST, FIVE, FOUR)])
        names = {t["test"]: (t["package"], t["file"], t["index"], t["name"]) for t in matrix["tests"]}
        self.assertEqual([(m["id"], m["outcome"], [names[t] for t in m["killing_tests"]]) for m in matrix["mutants"]],
                         MATRIX)

    def test_the_summary_and_the_report_count_the_tests_that_kill_and_those_that_alone_kill(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertIs(summary["kill_matrix"], True)
        package = summary["packages"][0]
        self.assertEqual({k: package[k] for k in ("mutants", "killed", "timed_out", "survived", "unviable")},
                         {"mutants": 6, "killed": 5, "timed_out": 0, "survived": 1, "unviable": 0})
        self.assertEqual(package["baseline"]["tests"], 7)
        found = dict(package["matrix"], tests=len(package["matrix"]["tests"]))
        # All seven tests kill some mutant; four alone kill one: meter's,
        # dial's, units' 0 below a range and 5 past 3.
        self.assertEqual(found, {
            "packages": ["mutation/fixture/units", "mutation/fixture/dial", "mutation/fixture/meter"],
            "native_only": ["mutation/fixture/probe"],
            "tests": 7, "killing": 7, "alone": 4,
            "killed_by": {"mutation/fixture/dial": 2, "mutation/fixture/meter": 2, "mutation/fixture/units": 3},
        })
        # A run in this mode has no run of its own tests alone.
        self.assertNotIn("own", package)
        self.assertNotIn("importers", package)
        report = (self.out / "report.md").read_text()
        self.assertIn("Kill matrix: each mutant ran against the 7 tests of mutation/fixture/units,"
                      " mutation/fixture/dial and mutation/fixture/meter at once, with no early stop.\n"
                      "- 7 of these tests kill some mutant, and 4 of them alone kill some mutant.\n"
                      "- Mutants killed by the tests of each package: mutation/fixture/dial 2,"
                      " mutation/fixture/meter 2, mutation/fixture/units 3.\n"
                      "- Importers that build only natively, whose tests did not run: mutation/fixture/probe.\n",
                      report)
        self.assertIn("### Survivors (1)", report)

    def tool(self, *args):
        """What matrix.py prints for args, as a list of objects."""
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_the_tool_lists_the_tests_that_alone_kill_some_mutant(self):
        # From MATRIX: four tests are each the only one that kills a mutant.
        self.assertEqual([(t["test"], t["layer"], t["alone"]) for t in self.tool("alone", self.out)], [
            (matrix_name(DIAL_HIGH), "in-process", ["units/units.mbt,within,ROR,<=,<,1"]),
            (matrix_name(METER_LOW), "in-process", ["units/units.mbt,within,ROR,<=,<,0"]),
            (matrix_name(BELOW), "in-process", ["units/units.mbt,within,LCR,&&,||,0"]),
            (matrix_name(PAST), "in-process", ["units/units.mbt,past,BODY,{…},{ false },0"]),
        ])
        # The others kill only what other tests kill too: candidates for
        # removal, under removal rule (A).
        self.assertEqual([(t["test"], t["kills"]) for t in self.tool("alone", "--none", self.out / "matrix" / "units.json")],
                         [(matrix_name(t), ["units/units.mbt,within,BODY,{…},{ false },0"]) for t in (INSIDE, FIVE, FOUR)])

    def test_the_tool_gives_the_mutants_that_a_set_of_tests_kills(self):
        def outcomes(*args):
            return [(m["id"], m["outcome"], m["matrix"], m["killing_tests"]) for m in self.tool("kills", *args)]

        # With every test but meter's, the mutant that only meter's killed
        # survives; the rest are as in the matrix.
        without = [(i, "survived" if tests == [METER_LOW] else outcome, outcome,
                    [matrix_name(t) for t in tests if t != METER_LOW]) for i, outcome, tests in MATRIX]
        self.assertEqual(outcomes("--without", "--test", matrix_name(METER_LOW), self.out), without)
        # units' own tests alone kill what ImportersTest finds they kill
        # without the importers' tests: within's BODY, `||` and past's BODY.
        own = {"units/units.mbt,within,BODY,{…},{ false },0", "units/units.mbt,within,LCR,&&,||,0",
               "units/units.mbt,past,BODY,{…},{ false },0"}
        self.assertEqual([(i, o) for i, o, _, _ in outcomes("--package", "mutation/fixture/units", self.out)],
                         [(i, "killed" if i in own else "survived") for i, _, _ in MATRIX])
        # One test alone kills only within's BODY.
        self.assertEqual([(i, o, tests) for i, o, _, tests in outcomes("--test", matrix_name(INSIDE), self.out)],
                         [(i, "killed" if tests == MATRIX[0][2] else "survived",
                           [matrix_name(INSIDE)] if tests == MATRIX[0][2] else []) for i, _, tests in MATRIX])

    def test_the_tool_refuses_a_test_the_matrix_does_not_hold(self):
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), "kills", "--test", "mutation/fixture/units/x.mbt:y",
                                 str(self.out)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no test of the matrix is mutation/fixture/units/x.mbt:y", result.stderr)

    def test_a_run_that_is_no_kill_matrix_leaves_none_behind(self):
        out = self.tmp / "again"
        shutil.copytree(self.out, out)
        result = run_runner(FIXTURE, self.tmp / "work", out, self.moon, "--sites-only", "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((out / "matrix").exists())
        # Nor does a run with totals only, which keeps no file that names a
        # mutant (CONTRIBUTING.md, "Shards, samples and listed sets"); its
        # one key here no longer applies, so nothing runs.
        out = self.tmp / "totals"
        shutil.copytree(self.out, out)
        listed = self.tmp / "gone.jsonl"
        listed.write_text(json.dumps({"file": "units/units.mbt", "definition": "gone", "operator": "ROR",
                                      "original": "<=", "replacement": "<", "ordinal": 0}) + "\n")
        result = run_runner(FIXTURE, self.tmp / "work-totals", out, self.moon, "--list", listed, "--totals-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((out / "matrix").exists())

    def test_with_one_test_left_out_of_the_run_the_mutants_only_it_killed_survive(self):
        # meter's only test left out: `low < n`, which only it killed,
        # survives, and within's BODY loses only that one of its killers;
        # the tool, reading the whole matrix, says the same.
        root = self.tmp / "without-meter"
        shutil.copytree(FIXTURE, root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        (root / "meter" / "meter_test.mbt").unlink()
        mutants = [MATRIX[0][0], MATRIX[1][0]]
        out = self.tmp / "without-meter-out"
        result = run_runner(root, self.tmp / "work-without-meter", out, self.moon, "--matrix",
                            *[a for m in mutants for a in ("--mutant", m)], "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        run = {r["id"]: (r["outcome"], [matrix_name(tuple(t[k] for k in ("package", "file", "index", "name")))
                                        for t in r["killing_tests"]]) for r in read_lines(out / "mutants.jsonl")}
        self.assertEqual(run, {MATRIX[0][0]: ("killed", [matrix_name(t) for t in (DIAL_HIGH, INSIDE, FIVE, FOUR)]),
                               MATRIX[1][0]: ("survived", [])})
        told = {m["id"]: (m["outcome"], m["killing_tests"])
                for m in self.tool("kills", "--without", "--test", matrix_name(METER_LOW), self.out)}
        self.assertEqual({i: told[i] for i in mutants}, run)

    def test_the_shards_of_a_kill_matrix_merge_into_the_matrix_of_the_run_without_shards(self):
        shards = []
        for k in (1, 2):
            shards.append(self.tmp / f"shard-{k}")
            result = run_runner(FIXTURE, self.tmp / f"work-shard-{k}", shards[-1], self.moon, "--matrix", "--shard",
                                f"{k}/2", "units")
            self.assertEqual(result.returncode, 0, result.stderr)
        merged = self.tmp / "merged"
        result = subprocess.run([sys.executable, str(HERE / "merge.py"), "--out", str(merged), *map(str, shards)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((merged / "matrix" / "units.json").read_text(),
                         (self.out / "matrix" / "units.json").read_text())
        whole = json.loads((self.out / "summary.json").read_text())["packages"][0]["matrix"]
        self.assertEqual(json.loads((merged / "summary.json").read_text())["packages"][0]["matrix"], whole)
        self.assertIn("- 7 of these tests kill some mutant, and 4 of them alone kill some mutant.",
                      (merged / "report.md").read_text())
        # A shard of a run that is no kill matrix is of another run.
        other = self.tmp / "shard-2-other"
        result = run_runner(FIXTURE, self.tmp / "work-shard-2", other, self.moon, "--shard", "2/2", "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([sys.executable, str(HERE / "merge.py"), "--out", str(self.tmp / "mixed"),
                                 str(shards[0]), str(other)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is of another run", result.stderr)

    def test_a_shard_with_no_mutant_of_a_kill_matrix_merges_too(self):
        # A bulk run may have more shards than mutants (#313): one mutant in
        # two shards leaves the second with none, and no package to run.
        shards = []
        for k in (1, 2):
            shards.append(self.tmp / f"one-{k}")
            result = run_runner(FIXTURE, self.tmp / "work", shards[-1], self.moon, "--matrix", "--mutant",
                                MATRIX[1][0], "--shard", f"{k}/2", "units")
            self.assertEqual(result.returncode, 0, result.stderr)
        merged = self.tmp / "one-merged"
        result = subprocess.run([sys.executable, str(HERE / "merge.py"), "--out", str(merged), *map(str, shards)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        matrix = json.loads((merged / "matrix" / "units.json").read_text())
        self.assertEqual(matrix["mutants"], [{"id": MATRIX[1][0], "outcome": "killed",
                                              "killing_tests": [matrix_name(METER_LOW)]}])

    def test_a_kill_matrix_runs_over_the_full_set_too(self):
        # For removal proofs (#306, first criterion). units' full set has
        # no alternatives beyond the pinned set's, so within's BODY stands
        # for it.
        out = self.tmp / "full"
        result = run_runner(FIXTURE, self.tmp / "work", out, self.moon, "--matrix", "--set", "full", "--mutant",
                            MATRIX[0][0], "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        matrix = json.loads((out / "matrix" / "units.json").read_text())
        self.assertEqual((matrix["set"], [(m["id"], m["outcome"], len(m["killing_tests"])) for m in matrix["mutants"]]),
                         ("full", [(MATRIX[0][0], "killed", 5)]))

    def test_a_run_stops_when_moons_outline_does_not_list_every_test_it_ran(self):
        # A moon whose outline leaves out its last test, as one whose
        # outline the runner no longer reads would.
        moon = self.tmp / "short-outline"
        moon.write_text('#!/bin/sh\ncase " $* " in *" --outline "*) "$0.real" "$@" | sed \'$d\';;'
                        ' *) exec "$0.real" "$@";; esac\n')
        moon.chmod(moon.stat().st_mode | stat.S_IXUSR)
        Path(f"{moon}.real").symlink_to(self.moon)
        result = run_runner(FIXTURE, self.tmp / "work", self.tmp / "short", moon, "--matrix", "--mutant",
                            MATRIX[1][0], "units")
        self.assertEqual(result.returncode, 1)
        self.assertIn("moon lists 6 tests of mutation/fixture/units, mutation/fixture/dial, mutation/fixture/meter,"
                      " but ran 7", result.stderr)

    def test_a_kill_matrix_runs_alone(self):
        for other in (["--totals-only", "--list", "x.jsonl"], ["--self-test-only"]):
            result = run_runner(FIXTURE, self.tmp / "work", self.tmp / "refused", self.moon, "--matrix", *other,
                                "units")
            self.assertEqual(result.returncode, 2, other)
            self.assertIn("--matrix takes no --totals-only or --self-test-only", result.stderr)


class MatrixToolTest(unittest.TestCase):
    """The tool on a matrix written by hand, with an e2e test, a duplicate
    and a time-out, which the fixture's matrix has not."""

    TESTS = [
        {"test": "p/q/a_test.mbt:a", "package": "p/q", "file": "a_test.mbt", "line": 1, "index": 0, "name": "a",
         "layer": "in-process"},
        {"test": "p/q/b_test.mbt#0", "package": "p/q", "file": "b_test.mbt", "line": 1, "index": 0, "name": "",
         "layer": "in-process"},
        {"test": "p/e2e/c_test.mbt:c", "package": "p/e2e", "file": "c_test.mbt", "line": 1, "index": 0, "name": "c",
         "layer": "e2e"},
    ]
    MUTANTS = [
        {"id": "q.mbt,f,ROR,<,<=,0", "outcome": "killed", "killing_tests": ["p/q/a_test.mbt:a", "p/e2e/c_test.mbt:c"]},
        {"id": "q.mbt,f,INT,1,2,0", "outcome": "killed", "killing_tests": ["p/e2e/c_test.mbt:c"]},
        {"id": "q.mbt,g,INT,1,2,0", "outcome": "duplicate", "duplicate_of": "q.mbt,f,INT,1,2,0", "killing_tests": []},
        {"id": "q.mbt,h,BODY,{…},{ 0 },0", "outcome": "timed out", "killing_tests": []},
        {"id": "q.mbt,h,NOT,!,,0", "outcome": "killed", "killing_tests": ["p/q/b_test.mbt#0"]},
    ]

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-tool-"))
        self.file = self.tmp / "q.json"
        self.file.write_text(json.dumps({"version": 1, "package": "p/q", "directory": "q", "operator_set": "v1",
                                         "set": "full", "backend": "wasm-gc", "packages": ["p/q"], "native_only": [],
                                         "tests": self.TESTS, "mutants": self.MUTANTS}))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tool(self, *args):
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_an_e2e_kill_does_not_count_for_the_in_process_layer(self):
        # Removal rule (A): only tests in the same layer or a lower one
        # count, so an e2e kill never justifies removing an in-process test.
        self.assertEqual([(m["id"], m["outcome"], m["killing_tests"])
                          for m in self.tool("kills", "--layer", "in-process", self.file)], [
            ("q.mbt,f,ROR,<,<=,0", "killed", ["p/q/a_test.mbt:a"]),
            ("q.mbt,f,INT,1,2,0", "survived", []),
            ("q.mbt,g,INT,1,2,0", "survived", []),
            ("q.mbt,h,BODY,{…},{ 0 },0", "timed out", []),
            ("q.mbt,h,NOT,!,,0", "killed", ["p/q/b_test.mbt#0"]),
        ])

    def test_a_duplicate_counts_as_the_mutant_it_compiles_as_and_a_time_out_names_no_test(self):
        self.assertEqual([(t["test"], t["alone"]) for t in self.tool("alone", self.tmp)], [
            ("p/q/b_test.mbt#0", ["q.mbt,h,NOT,!,,0"]),
            ("p/e2e/c_test.mbt:c", ["q.mbt,f,INT,1,2,0", "q.mbt,g,INT,1,2,0"]),
        ])
        [duplicate] = [m for m in self.tool("kills", "--without", "--test", "p/q/a_test.mbt:a", self.file)
                       if m["id"] == "q.mbt,g,INT,1,2,0"]
        self.assertEqual(duplicate, {"package": "p/q", "id": "q.mbt,g,INT,1,2,0", "outcome": "killed",
                                     "matrix": "killed", "killing_tests": ["p/e2e/c_test.mbt:c"],
                                     "duplicate_of": "q.mbt,f,INT,1,2,0"})

    def test_a_file_that_is_no_kill_matrix_is_refused(self):
        (self.tmp / "summary.json").write_text(json.dumps({"operator_set": "v1", "packages": []}))
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), "alone", self.tmp], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("summary.json is no kill matrix of version 1", result.stderr)

    def test_the_tests_of_smocks_e2e_package_are_e2e_tests(self):
        sys.path.insert(0, str(HERE))
        import matrix
        self.assertEqual([matrix.layer(p) for p in ("smock/smock/e2e", "smock/smock/engine", "smock/yaml")],
                         ["e2e", "in-process", "in-process"])


# A workspace laid out as smock's: the root module smock/smock, whose
# packages a and b sit in a/ and b/, and the module smock/proto in proto/.
# At the base, a/a_test.mbt and b/b_test.mbt; the next commit deletes a
# line of "a one", rewords the comment above "a two" and changes a line of
# its body, and adds proto/p_test.mbt. "a three" and a's test with no name
# are as they were, a line higher, and b's tests as they were.
WORKSPACE = {
    "moon.work": 'members = [\n  ".",\n  "./proto",\n]\n',
    "moon.mod": 'name = "smock/smock"\n',
    "proto/moon.mod": 'name = "smock/proto"\n',
    "a/a_test.mbt": '///|\ntest "a one" {\n  inspect(1, content="1")\n  inspect(-1, content="-1")\n}\n\n'
                    '///|\n/// What two is.\ntest "a two" {\n  inspect(2, content="2")\n}\n\n'
                    '///|\ntest "a three" {\n  inspect(3, content="3")\n}\n\n'
                    '///|\ntest {\n  inspect(4, content="4")\n}\n',
    "b/b_test.mbt": '///|\ntest "b one" {\n  inspect(true, content="true")\n}\n\n'
                    '///|\ntest "b two" {\n  inspect(false, content="false")\n}\n',
}
CHANGES = [
    ("a/a_test.mbt", '  inspect(-1, content="-1")\n', ""),
    ("a/a_test.mbt", "/// What two is.\n", "/// What two is, in words.\n"),
    ("a/a_test.mbt", '  inspect(2, content="2")\n', '  inspect(1 + 1, content="2")\n'),
]
PROTO_TESTS = '///|\ntest "p one" {\n  inspect(1, content="1")\n}\n'


def test_entry(package, file, line, index, name):
    """A test as a matrix lists it."""
    test = {"package": package, "file": file, "line": line, "index": index, "name": name, "layer": "in-process"}
    return dict(test=f"{package}/{file}:{name}" if name else f"{package}/{file}#{index}", **test)


# The tests at HEAD, at the lines moon's outline would give.
A_ONE = test_entry("smock/smock/a", "a_test.mbt", 2, 0, "a one")
A_TWO = test_entry("smock/smock/a", "a_test.mbt", 8, 1, "a two")
A_THREE = test_entry("smock/smock/a", "a_test.mbt", 13, 2, "a three")
A_NAMELESS = test_entry("smock/smock/a", "a_test.mbt", 18, 3, "")
B_ONE = test_entry("smock/smock/b", "b_test.mbt", 2, 0, "b one")
B_TWO = test_entry("smock/smock/b", "b_test.mbt", 7, 1, "b two")
P_ONE = test_entry("smock/proto", "p_test.mbt", 2, 0, "p one")

# What the script that drew the first three snapshot audits gives on this
# workspace with the seed 44737193027 (SnapshotDrawTest): each test drawn,
# in order, and whether it is the work's. Four with the base before the
# work, and three, of which half rounded up, two, are the work's; all six
# when ten are asked; four with HEAD as the base.
DRAWN_4 = [(P_ONE["test"], True), (A_ONE["test"], True), (A_NAMELESS["test"], False), (A_TWO["test"], True)]
DRAWN_3 = [(P_ONE["test"], True), (A_ONE["test"], True), (A_NAMELESS["test"], False)]
DRAWN_ALL = [(P_ONE["test"], True), (A_ONE["test"], True), (A_TWO["test"], True), (B_ONE["test"], False),
             (A_NAMELESS["test"], False), (A_THREE["test"], False)]
DRAWN_4_NO_WORK = [(A_NAMELESS["test"], False), (A_ONE["test"], False), (P_ONE["test"], False),
                   (A_TWO["test"], False)]


def git(root, *args):
    """The output of a git command in root, with a fixed author and dates."""
    environment = {**os.environ, "GIT_AUTHOR_DATE": "2026-11-21T00:00:00Z", "GIT_COMMITTER_DATE": "2026-11-21T00:00:00Z"}
    return subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                           "-c", "commit.gpgsign=false", "-C", str(root), *args], check=True, capture_output=True,
                          text=True, env=environment).stdout


def committed(root, files, message):
    """Writes files into root, a git repository made on the first call,
    and commits them: the commit's id."""
    if not root.is_dir():
        root.mkdir(parents=True)
        git(root, "init", "-q", "-b", "main")
    for path, text in files.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(text)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)
    return git(root, "rev-parse", "HEAD").strip()


def write_matrix(path, package, tests, mutants):
    """Writes a package's kill matrix, of the tests and mutants given."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 1, "package": package, "directory": path.stem, "operator_set": "v1",
                                "set": "pinned", "backend": "wasm-gc",
                                "packages": sorted({t["package"] for t in tests}), "native_only": [],
                                "tests": tests, "mutants": mutants}))


class SnapshotDrawTest(unittest.TestCase):
    """`draw` draws the tests of a snapshot audit (CONTRIBUTING.md,
    "Snapshot audits"; #306, #275): about ten among the tests that alone
    kill some mutant in the kill matrices, at least half of them from the
    tests that the work added or changed since a base, with the kill-matrix
    run's ID as the seed. The draws it must give are those that the script
    which drew the first three audits (#327, #328, #329) gives for the same
    matrices, seed and base; the expected orders below are that script's
    output on this workspace."""

    SEED = "44737193027"

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-draw-"))
        cls.root = cls.tmp / "workspace"
        cls.base = committed(cls.root, WORKSPACE, "base")
        changes = {}
        for path, old, new in CHANGES:
            changes[path] = changes.get(path, WORKSPACE[path]).replace(old, new, 1)
        committed(cls.root, {**changes, "proto/p_test.mbt": PROTO_TESTS}, "the work")
        # Two matrices: a's, whose tests are a's and b's, and proto's, whose
        # tests are proto's and a's first test.
        cls.matrices = cls.tmp / "matrices"
        write_matrix(cls.matrices / "a.json", "smock/smock/a", [A_ONE, A_TWO, A_THREE, A_NAMELESS, B_ONE, B_TWO], [
            {"id": "a/a.mbt,f,INT,1,2,0", "outcome": "killed", "killing_tests": [A_ONE["test"]]},
            {"id": "a/a.mbt,f,INT,2,3,0", "outcome": "killed", "killing_tests": [A_TWO["test"]]},
            {"id": "a/a.mbt,g,INT,2,3,0", "outcome": "duplicate", "duplicate_of": "a/a.mbt,f,INT,2,3,0",
             "killing_tests": []},
            {"id": "a/a.mbt,f,ROR,<,<=,0", "outcome": "killed", "killing_tests": [A_THREE["test"]]},
            {"id": "a/a.mbt,h,NOT,!,,0", "outcome": "killed", "killing_tests": [A_NAMELESS["test"]]},
            {"id": "a/a.mbt,h,INT,0,1,0", "outcome": "killed", "killing_tests": [B_ONE["test"]]},
            {"id": "a/a.mbt,h,BOOL,true,false,0", "outcome": "killed", "killing_tests": [B_ONE["test"], B_TWO["test"]]},
            {"id": "a/a.mbt,k,INT,7,8,0", "outcome": "survived", "killing_tests": []},
        ])
        write_matrix(cls.matrices / "proto.json", "smock/proto", [P_ONE, A_ONE], [
            {"id": "proto/p.mbt,p,INT,1,2,0", "outcome": "killed", "killing_tests": [P_ONE["test"]]},
            {"id": "proto/p.mbt,p,INT,2,3,0", "outcome": "killed", "killing_tests": [A_ONE["test"]]},
        ])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def draw(self, *args, base=None):
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), "draw", "--root", str(self.root), "--seed",
                                 self.SEED, "--base", base or self.base, *map(str, args), self.matrices],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()], result.stderr

    def test_half_is_drawn_from_the_works_tests_then_the_rest_from_every_test_not_yet_drawn(self):
        drawn, said = self.draw("--size", "4")
        self.assertEqual([(t["test"], t["work"]) for t in drawn], DRAWN_4)
        self.assertIn("6 tests alone kill some mutant, 3 of them the work's", said)
        # The same matrices, seed and base draw the same tests.
        self.assertEqual(self.draw("--size", "4")[0], drawn)
        self.assertEqual([(t["test"], t["work"]) for t in self.draw("--size", "3")[0]], DRAWN_3)

    def test_a_test_is_the_works_when_its_block_holds_a_line_that_differs_from_the_base(self):
        # Ten asked, six there: every one is drawn, the work's three first.
        drawn, _ = self.draw()
        self.assertEqual([(t["test"], t["work"]) for t in drawn], DRAWN_ALL)
        by_test = {t["test"]: t for t in drawn}
        # Each line is the test as the matrix lists it, its file in the
        # checkout, and the mutants it alone kills, in every matrix.
        self.assertEqual(by_test[A_ONE["test"]], dict(A_ONE, path="a/a_test.mbt", work=True,
                                                      alone=["a/a.mbt,f,INT,1,2,0", "proto/p.mbt,p,INT,2,3,0"]))
        self.assertEqual(by_test[A_TWO["test"]]["alone"], ["a/a.mbt,f,INT,2,3,0", "a/a.mbt,g,INT,2,3,0"])
        self.assertEqual(by_test[P_ONE["test"]]["path"], "proto/p_test.mbt")
        self.assertNotIn(B_TWO["test"], by_test)

    def test_with_none_of_the_works_tests_every_test_is_drawn_from_the_rest(self):
        drawn, said = self.draw("--size", "4", base="HEAD")
        self.assertEqual([(t["test"], t["work"]) for t in drawn], DRAWN_4_NO_WORK)
        self.assertIn("6 tests alone kill some mutant, 0 of them the work's", said)

    def test_a_checkout_that_is_not_the_runs_commit_is_refused(self):
        def refused(matrices):
            result = subprocess.run([sys.executable, str(MATRIX_TOOL), "draw", "--root", str(self.root), "--seed",
                                     self.SEED, "--base", self.base, matrices], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout)
            return result.stderr

        # A test whose line is past the end of its file.
        moved = dict(P_ONE, line=99)
        write_matrix(self.tmp / "moved" / "proto.json", "smock/proto", [moved], [
            {"id": "proto/p.mbt,p,INT,1,2,0", "outcome": "killed", "killing_tests": [moved["test"]]}])
        self.assertIn("HEAD's proto/p_test.mbt has no line 99", refused(self.tmp / "moved"))
        # A test whose file is gone.
        git(self.root, "rm", "-q", "proto/p_test.mbt")
        git(self.root, "commit", "-q", "-m", "drop proto's tests")
        try:
            self.assertIn("proto/p_test.mbt", refused(self.matrices))
        finally:
            git(self.root, "reset", "-q", "--hard", "HEAD~1")

    def test_a_package_is_found_in_the_directory_of_its_module(self):
        # moon.work names each module's directory, and its moon.mod the
        # module's name: here a root module of one part, whose package
        # top/a/b is in a/b/, and the module smock/proto in wire/.
        root = self.tmp / "modules"
        committed(root, {"moon.work": 'members = [".", "./wire"]\n', "moon.mod": 'name = "top"\n',
                         "wire/moon.mod.json": '{\n  "name": "smock/proto"\n}\n', "a/b/b_test.mbt": PROTO_TESTS,
                         "wire/w_test.mbt": PROTO_TESTS}, "two modules")
        nested = test_entry("top/a/b", "b_test.mbt", 2, 0, "p one")
        wired = test_entry("smock/proto", "w_test.mbt", 2, 0, "p one")
        matrices = self.tmp / "modules-matrices"
        write_matrix(matrices / "b.json", "top/a/b", [nested, wired], [
            {"id": "a/b/b.mbt,f,INT,1,2,0", "outcome": "killed", "killing_tests": [nested["test"]]},
            {"id": "a/b/b.mbt,f,INT,2,3,0", "outcome": "killed", "killing_tests": [wired["test"]]},
        ])
        result = subprocess.run([sys.executable, str(MATRIX_TOOL), "draw", "--root", str(root), "--seed", self.SEED,
                                 "--base", "HEAD", matrices], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(json.loads(line)["path"] for line in result.stdout.splitlines()),
                         ["a/b/b_test.mbt", "wire/w_test.mbt"])


class OutlineTest(unittest.TestCase):
    """Every test of a kill matrix comes from moon's outline, which a fake
    moon prints here as moon 0.1.20261104 does: a name escapes each `\\`
    and `"` once more than moon's failures and the test's file write it,
    and a test with no name has none."""

    class Problem(Exception):
        pass

    def outline(self, text):
        sys.path.insert(0, str(HERE))
        import matrix
        tmp = Path(tempfile.mkdtemp(prefix="test-matrix-outline-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "outline.txt").write_text(text)
        worker = types.SimpleNamespace(moon=["sh", "-c", 'cat "$0"', str(tmp / "outline.txt")], tree=tmp,
                                         target=tmp / "target")
        return matrix.outline(worker, ["p/q"], self.Problem)

    def test_a_name_is_read_as_the_tests_file_writes_it(self):
        tests = self.outline('   1. p/q q_test.mbt:2 index=0 name="a \\\\\\"b\\\\\\" c\\\\\\\\d é"\n'
                             '   2. p/q q.mbt:5 index=0\n'
                             '   3. p/q q.mbt:9 index=0 name="x"\n'
                             'Warning: a line that names no test\n')
        self.assertEqual([(t["file"], t["line"], t["index"], t["name"], t["layer"]) for t in tests], [
            ("q_test.mbt", 2, 0, 'a \\"b\\" c\\\\d é', "in-process"),
            ("q.mbt", 5, 0, "", "in-process"),
            ("q.mbt", 9, 0, "x", "in-process"),
        ])

    def test_two_tests_by_one_name_stop_the_run(self):
        with self.assertRaisesRegex(self.Problem, "two tests by one name.*p/q/q.mbt#0"):
            self.outline("   1. p/q q.mbt:5 index=0\n   2. p/q q.mbt:9 index=0\n")


# A moon that answers the runs of tests, but not their builds, dry runs or
# outlines, from a script: a JSON list of answers, taken in turn. "real"
# runs the real moon; {"fail": [test, ...]} prints what moon prints when
# those tests fail, and exits as it does. Once the script is used up, the
# real moon answers. Its arguments: the script, the real moon, then moon's
# own.
SCRIPTED_MOON = '''\
import json, os, sys
script, real, args = sys.argv[1], sys.argv[2], sys.argv[3:]
if args[:1] == ["test"] and not {"--build-only", "--dry-run", "--outline"} & set(args):
    with open(script) as f:
        answers = json.load(f)
    if answers:
        answer = answers.pop(0)
        with open(script, "w") as f:
            json.dump(answers, f)
        if isinstance(answer, dict) and "fail" in answer:
            for package, filename, index, name in answer["fail"]:
                print(json.dumps({"package": package, "filename": filename, "index": str(index),
                                  "test_name": name, "message": "a scripted failure"}))
            print(f"Total tests: 7, passed: {7 - len(answer['fail'])}, failed: {len(answer['fail'])}.")
            sys.exit(2)
os.execv(real, [real, *args])
'''


class MatrixConfirmationTest(unittest.TestCase):
    """Kill-matrix runs of within's BODY `{ false }`, which three tests of
    three packages kill, with a moon that answers from a script, so that
    one of them fails only once, or fails without the mutant too."""

    MUTANT = MATRIX[0][0]

    @classmethod
    def setUpClass(cls):
        moon = shutil.which("moon")
        if moon is None:
            raise unittest.SkipTest("moon is not on PATH")
        cls.real = moon
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-matrix-confirm-"))
        cls.fake = cls.tmp / "scripted_moon.py"
        cls.fake.write_text(SCRIPTED_MOON)
        cls.runs = 0

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_scripted(self, answers):
        """Runs the runner in kill-matrix mode on the mutant, with the moon
        that answers from the script: its record and its flake records."""
        type(self).runs += 1
        script = self.tmp / f"run-{self.runs}.json"
        script.write_text(json.dumps(answers))
        moon = f"{sys.executable} {self.fake} {script} {self.real}"
        out = self.tmp / f"run-{self.runs}"
        result = run_runner(FIXTURE, self.tmp / "work", out, moon, "--matrix", "--mutant", self.MUTANT, "units")
        self.assertEqual(result.returncode, 0, result.stderr)
        [record] = read_lines(out / "mutants.jsonl")
        return record, json.loads((out / "flakes.json").read_text())["runs"][-1]

    # The runs of tests, in turn: the two runs without a mutant, the
    # self-test's run, the mutant's run, its run again with the mutant on,
    # and the run without it.

    def test_a_test_that_passes_when_the_kill_runs_again_is_not_credited(self):
        killed = [list(DIAL_HIGH), list(METER_LOW), list(INSIDE)]
        record, flakes = self.run_scripted(["real", "real", "real", {"fail": killed},
                                            {"fail": [list(DIAL_HIGH), list(INSIDE)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"], [dict(fields(t), layer="in-process") for t in (DIAL_HIGH, INSIDE)])
        # meter's test passed the one time it ran again with the mutant on.
        self.assertIn({"package": METER_LOW[0], "file": METER_LOW[1], "name": METER_LOW[3], "flaked": 1,
                       "reruns": 1}, flakes["tests"])

    def test_a_test_that_fails_without_the_mutant_too_is_not_credited(self):
        record, flakes = self.run_scripted(["real", "real", "real", "real", "real", {"fail": [list(METER_LOW)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"],
                         [dict(fields(t), layer="in-process") for t in (DIAL_HIGH, INSIDE, FIVE, FOUR)])
        self.assertIn({"package": METER_LOW[0], "file": METER_LOW[1], "name": METER_LOW[3], "flaked": 1,
                       "reruns": 1}, flakes["tests"])

    def test_tests_with_no_name_are_confirmed_each_on_its_own(self):
        # Both fail with the mutant on; run again, only the second does, so
        # only the second is credited, though neither has a name.
        record, flakes = self.run_scripted(["real", "real", "real", {"fail": [list(FIVE), list(FOUR)]},
                                            {"fail": [list(FOUR)]}])
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual(record["killing_tests"], [dict(fields(FOUR), layer="in-process")])
        # The flake records name a test with no name by its index.
        self.assertEqual([t for t in flakes["tests"] if t["package"] == FIVE[0]], [
            {"package": FIVE[0], "file": FIVE[1], "name": "#3", "flaked": 1, "reruns": 1},
            {"package": FOUR[0], "file": FOUR[1], "name": "#4", "flaked": 0, "reruns": 1}])


if __name__ == "__main__":
    unittest.main()
