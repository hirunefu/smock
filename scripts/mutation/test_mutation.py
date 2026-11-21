"""Tests of the mutation runner, scripts/mutation/run.py, and of its site
finder, scripts/mutation/sites.py, through their command lines, on the
fixture module scripts/mutation/fixture. In the fixture's package calc,
each site's mutant in the pinned set has a known outcome, which a comment
beside the site gives with its reason, and so does each site of the
package log in both sets; the package shapes holds one site in each kind
of definition, and look-alikes that are not sites; the package forms holds
each form of each operator. In the package units, each mutant of the
pinned set has a known outcome with units' own tests and, for those that
survive them, with the tests of the packages that import units (meter,
and dial through meter; probe imports it too, but builds only natively).

The operators, their alternatives and the pinned rule are those of
operator set v1 (#275, ADR 0006 and CONTRIBUTING.md, "Operator set v1"),
which #299 completes: BODY, ROR, IFC, LCR, NOT, DEL, BOOL, AOR, INT and
STR. The expected sites below are v1's, worked out by hand from those
rules; a change to the rules is a new version, and these tables change
with it. The time limit, 1.25 times the baseline run plus 4 s, is #298's.
Kill credit for a pure package (#275, "Kill credit, pure packages", and
#300): the package's own tests run first, and the survivors run again
with the wasm-gc tests of every package that imports it, directly or
through another package; e2e tests and the tests of other native-only
packages give none. Kill confirmation (#275, "Kill confirmation", and
#301): the tests run twice without a mutant before any mutant; a kill
counts only when the tests that failed fail again with the mutant on and
pass with it off, and a time-out only when it happens again and the run
without the mutant finishes within the limit; a test that failed without
a mutant in this run, or whose flake rate is above the flake threshold of
mutation/flakes.toml, gives no kill credit. A run that the time limit
stops, or that fails without naming a test, did not pass and names no
test: run again, it repeats the kill, and when the first run ended so,
the run again decides (#431, the maintainer's twentieth round, point 3).
A fake moon answers the runs of tests from a script, so that a flaky
failure, a time-out that does not repeat and a test program that stops
happen every time.

In the fixture's package same, each mutant of the pinned set has a known
outcome and a known result of the comparison of the compiler's output,
which compare.py makes before any test runs (#303); a comment beside each
site gives both, with the reasons.

They need python3, git, moon and moonc (the toolchain of .moonbit-version),
and take about a minute and a half: one mutant of the fixture times out,
and the scripted time-outs each take a time limit.

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
SITES = HERE / "sites.py"
RUN = HERE / "run.py"
VERSION = "v1"

# The sites of calc's pinned set, from calc/calc.mbt: each one's id, line
# and column, and the outcome that the comment beside it gives.
CALC = [
    ("calc/calc.mbt,in_range,BODY,{…},{ false },0", 10, 63, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,0", 17, 7, "killed"),
    ("calc/calc.mbt,in_range,LCR,&&,||,0", 17, 12, "killed"),
    ("calc/calc.mbt,in_range,ROR,<=,<,1", 17, 17, "survived"),
    ("calc/calc.mbt,halve_until,BODY,{…},{ 0 },0", 22, 55, "survived"),
    ("calc/calc.mbt,halve_until,IFC,x > limit,false,0", 29, 9, "killed"),
    ("calc/calc.mbt,halve_until,ROR,>,>=,0", 29, 11, "timed out"),
    ("calc/calc.mbt,halve_until,DEL,x = x / 2,,0", 36, 5, "unviable"),
    ("calc/calc.mbt,halve_until,AOR,/,*,0", 36, 11, "killed"),
    ("calc/calc.mbt,halve_until,INT,2,3,0", 36, 13, "survived"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,0", 44, 49, "survived"),
    ("calc/calc.mbt,is_blank,BODY,{…},{ false },0", 44, 63, "killed"),
    ("calc/calc.mbt,is_blank,IFC,!spaces,false,0", 50, 6, "survived"),
    ("calc/calc.mbt,is_blank,NOT,!,,0", 50, 6, "survived"),
    ("calc/calc.mbt,is_blank,INT,0,1,0", 53, 29, "survived"),
    ("calc/calc.mbt,is_blank,INT,0,-1,0", 53, 29, "survived"),
    ("calc/calc.mbt,is_blank,IFC,c != ' ',false,0", 58, 8, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,false,true,0", 60, 14, "killed"),
    ("calc/calc.mbt,is_blank,BOOL,true,false,1", 64, 3, "killed"),
    ("calc/calc.mbt,is_odd,BODY,{…},{ false },0", 69, 34, "killed"),
    ("calc/calc.mbt,is_odd,NOT,!,,0", 75, 3, "killed"),
    ("calc/calc.mbt,is_odd,INT,2,3,0", 75, 9, "killed"),
    ("calc/calc.mbt,is_odd,INT,2,1,0", 75, 9, "killed"),
    ("calc/calc.mbt,is_odd,INT,0,1,0", 75, 14, "killed"),
    ("calc/calc.mbt,is_odd,INT,0,-1,0", 75, 14, "survived"),
]

# The other alternatives that the full set adds in calc: IFC's other value,
# INT's n-1 and 0 outside a comparison, and 0 in one.
CALC_OTHERS = [
    ("calc/calc.mbt,halve_until,IFC,x > limit,true,0", 29, 9),
    ("calc/calc.mbt,halve_until,INT,2,1,0", 36, 13),
    ("calc/calc.mbt,halve_until,INT,2,0,0", 36, 13),
    ("calc/calc.mbt,is_blank,IFC,!spaces,true,0", 50, 6),
    ("calc/calc.mbt,is_blank,IFC,c != ' ',true,0", 58, 8),
    ("calc/calc.mbt,is_odd,INT,2,0,0", 75, 9),
]

# The sites of log, in the full set: each one's id, whether the pinned set
# takes it, and the outcome that the comment beside it gives.
LOG = [
    ('log/lines.mbt,line,BODY,{…},{ "" },0', True, "killed"),
    ('log/lines.mbt,line,STR,"info: ","_nfo: ",0', True, "killed"),
    ('log/lines.mbt,line,STR,"info: ","",0', False, "killed"),
    ("log/lines.mbt,is_comment,BODY,{…},{ false },0", True, "killed"),
    ('log/lines.mbt,is_comment,STR,"#","_",0', True, "killed"),
    ('log/lines.mbt,is_comment,STR,"#","",0', False, "survived"),
    ('log/lines.mbt,cut_mark,BODY,{…},{ "" },0', True, "killed"),
    ('log/lines.mbt,cut_mark,STR,"~","_",0', True, "survived"),
]

# The sites of units' pinned set, from units/units.mbt: each one's id, the
# outcome that the comment beside it gives with units' own tests, the
# outcome after the importers' tests, and the packages of the tests that
# killed it.
UNITS = [
    ("units/units.mbt,within,BODY,{…},{ false },0", "killed", "killed", ["mutation/fixture/units"]),
    ("units/units.mbt,within,ROR,<=,<,0", "survived", "killed", ["mutation/fixture/meter"]),
    ("units/units.mbt,within,LCR,&&,||,0", "killed", "killed", ["mutation/fixture/units"]),
    ("units/units.mbt,within,ROR,<=,<,1", "survived", "killed", ["mutation/fixture/dial"]),
    ("units/units.mbt,past,BODY,{…},{ false },0", "killed", "killed", ["mutation/fixture/units"]),
    ("units/units.mbt,past,ROR,>,>=,0", "survived", "survived", []),
]

# calc's tests that the confirmation tests script, as moon names them: the
# only test that kills `low < n` and the only one that kills `||`.
LOW = ("mutation/fixture/calc", "calc_test.mbt", 0, "a number at the low end is in range")
BELOW = ("mutation/fixture/calc", "calc_test.mbt", 1, "a number below the range is not in it")

# The packages of smock that build only natively (CONTRIBUTING.md, "Terms":
# the native-only packages). None of them gives a pure package credit.
NATIVE_ONLY = {"smock/smock/server", "smock/smock/cmd/smock", "smock/smock/defdir", "smock/smock/watch",
               "smock/smock/openssl", "smock/smock/protobuf-conformance", "smock/smock/yaml-test-suite",
               "smock/smock/schema", "smock/smock/e2e"}

# The mutants of same's pinned set: each one's id, the outcome that the
# comment beside its site gives, and what the comparison of the compiler's
# output found before any test ran (#303).
SAME = [
    ("same/same.mbt,TRACING,BOOL,false,true,0", "killed", "not compared"),
    ("same/same.mbt,total,BODY,{…},{ 0 },0", "killed", "differs"),
    ("same/same.mbt,total,INT,0,1,0", "killed", "differs"),
    # The condition is false already: the mutant shortens its line.
    ("same/same.mbt,total,IFC,TRACING,false,0", "equivalent", "identical"),
    # A call over three lines, deleted: equivalent only because the runner
    # keeps the lines, which a later message names.
    ("same/same.mbt,total,DEL,trace.push(…),,0", "equivalent", "identical"),
    ("same/same.mbt,total,DEL,sum = sum + x,,0", "unviable", None),
    ("same/same.mbt,total,AOR,+,-,0", "killed", "differs"),
    # Its BODY's 0 goes into the caller: the mutant's output has no
    # function of its own for count_a.
    ("same/same.mbt,count_a,BODY,{…},{ 0 },0", "killed", "not compared"),
    ("same/same.mbt,count_a,INT,0,1,0", "killed", "differs"),
    ("same/same.mbt,count_a,IFC,c == 'a',false,0", "killed", "differs"),
    ("same/same.mbt,count_a,DEL,n += 1,,0", "unviable", None),
    ("same/same.mbt,count_a,AOR,+=,-=,0", "killed", "differs"),
    ("same/same.mbt,count_a,INT,1,2,0", "killed", "differs"),
    ("same/same.mbt,count_a_if,BODY,{…},{ 0 },0", "killed", "differs"),
    ("same/same.mbt,count_a_if,IFC,wanted,false,0", "duplicate", "duplicate"),
    ("same/same.mbt,count_a_if,INT,0,1,0", "killed", "differs"),
    ("same/same.mbt,refuse,BODY,{…},{ () },0", "killed", "differs"),
    # An implementation that a public function calls, and one that none
    # does, which the output leaves out.
    ("same/same.mbt,impl Show for Tally with output,BODY,{…},{ () },0", "killed", "differs"),
    ("same/same.mbt,impl Eq for Tally with equal,BODY,{…},{ false },0", "killed", "not compared"),
    ('same/same.mbt,describe,BODY,{…},{ "" },0', "killed", "differs"),
]


def find_sites(root, *paths, chosen=None):
    """What the site finder prints for the paths, as a list of objects:
    the sites and the skipped sites."""
    options = ["--set", chosen] if chosen else []
    result = subprocess.run([sys.executable, str(SITES), "--root", str(root), *options, *paths],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"sites.py failed ({result.returncode}):\n{result.stderr}")
    return [json.loads(line) for line in result.stdout.splitlines()]


def sites_of(lines):
    """The sites among the finder's lines, without the skipped ones."""
    return [s for s in lines if "skipped" not in s]


def table(lines, definitions=None, operator=None):
    """The finder's lines as (id, or the skipped rule with the texts; line;
    whether the pinned set takes it), for some definitions and an
    operator."""
    rows = []
    for s in lines:
        if definitions is not None and s["definition"] not in definitions:
            continue
        if operator is not None and s["operator"] != operator:
            continue
        label = s["id"] if "id" in s else ("skipped", s["skipped"], s["original"], s["replacement"])
        rows.append((label, s["line"], s["pinned"]))
    return rows


class SitesTest(unittest.TestCase):
    def test_each_site_of_calc_with_its_position(self):
        # The pinned set is the default.
        sites = find_sites(FIXTURE, "calc")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites],
                         [(i, line, column) for i, line, column, _ in CALC])
        self.assertEqual(sites, sites_of(sites))

    def test_a_site_has_the_fields_of_its_id(self):
        site = find_sites(FIXTURE, "calc")[3]
        self.assertEqual(site, {
            "id": "calc/calc.mbt,in_range,ROR,<=,<,1",
            "file": "calc/calc.mbt",
            "definition": "in_range",
            "operator": "ROR",
            "original": "<=",
            "replacement": "<",
            "ordinal": 1,
            "line": 17,
            "column": 17,
            "definition_lines": [10, 18],
            "pinned": True,
            "operator_set": VERSION,
        })

    def test_the_full_set_adds_the_other_alternatives_at_each_position(self):
        full = find_sites(FIXTURE, "calc", chosen="full")
        expected = sorted([(i, line, column, True) for i, line, column, _ in CALC]
                          + [(i, line, column, False) for i, line, column in CALC_OTHERS])
        self.assertEqual(sorted((s["id"], s["line"], s["column"], s["pinned"]) for s in full), expected)
        # The pinned set is part of the full set.
        pinned = find_sites(FIXTURE, "calc", chosen="pinned")
        self.assertEqual([s for s in full if s["pinned"]], pinned)

    def test_every_line_names_the_operator_set(self):
        lines = find_sites(FIXTURE, "calc", "forms", "log", "shapes", chosen="full")
        self.assertEqual({s["operator_set"] for s in lines}, {VERSION})

    def test_each_kind_of_definition_names_its_sites(self):
        sites = find_sites(FIXTURE, "shapes")
        self.assertEqual([(s["id"], s["line"], s["column"]) for s in sites
                          if s["operator"] in ("ROR", "BOOL", "NOT")], [
            ("shapes/shapes.mbt,Span::is_empty,ROR,>,>=,0", 15, 12),
            ("shapes/shapes.mbt,impl Show for Span with output,ROR,<=,<,0", 20, 35),
            ("shapes/shapes.mbt,impl Round with is_round,BOOL,false,true,0", 31, 3),
            ("shapes/shapes.mbt,threshold,NOT,!,,0", 35, 24),
            ("shapes/shapes.mbt,threshold,ROR,>=,>,0", 35, 28),
            ("shapes/shapes.mbt,init,ROR,<,<=,0", 58, 25),
        ])
        # BODY: a method, an implementation of a core trait, whose return
        # type, not written, is the trait's, and a trait's default
        # implementation, whose trait is the program's own.
        self.assertEqual(table(sites, operator="BODY"), [
            ("shapes/shapes.mbt,Span::is_empty,BODY,{…},{ false },0", 14, True),
            ("shapes/shapes.mbt,impl Show for Span with output,BODY,{…},{ () },0", 19, True),
            (("skipped", "no default", "{\n  false\n}", ""), 30, True),
            ("shapes/shapes.mbt,look_alikes,BODY,{…},{ 0 },0", 40, True),
        ])

    def test_tests_generated_files_and_the_test_certificates_have_no_sites(self):
        # In the fixture: calc_test.mbt, calc_wbtest.mbt, the test block of
        # calc.mbt and the generated limits.mbt each hold a comparison.
        self.assertEqual(
            {s["file"] for s in find_sites(FIXTURE, "calc", "calc/calc_test.mbt", "calc/limits.mbt", chosen="full")},
            {"calc/calc.mbt"})
        # In the workspace (#275, Scope): the Unicode data table, the build
        # information, which a build writes, and the test certificates.
        files = {s["file"] for s in find_sites(REPO, "unicode", "buildinfo", "testcerts", chosen="full")}
        self.assertEqual(files - {"unicode/unicode.mbt", "buildinfo/buildinfo.mbt"}, set())
        self.assertIn("unicode/unicode.mbt", files)

    def test_a_file_that_does_not_parse_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "broken.mbt").write_text("///|\nfn broken( -> Int {\n  1 < 2\n}\n")
            result = subprocess.run([sys.executable, str(SITES), "--root", tmp, "broken.mbt"],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("broken.mbt: moonc cannot parse it", result.stderr)
        self.assertEqual(result.stdout, "")


class OperatorsTest(unittest.TestCase):
    """Each form of each operator of v1, in the full set, with whether the
    pinned set takes each alternative, from the package forms."""

    @classmethod
    def setUpClass(cls):
        cls.lines = find_sites(FIXTURE, "forms/operators.mbt", chosen="full")

    def test_body_replaces_a_body_with_its_return_types_default(self):
        f = "forms/operators.mbt,"
        self.assertEqual(table(self.lines, operator="BODY"), [
            (f + "body_unit,BODY,{…},{ () },0", 15, True),
            (f + "body_int64,BODY,{…},{ 0 },0", 21, True),
            (f + 'body_string,BODY,{…},{ "" },0', 26, True),
            (f + "body_option,BODY,{…},{ None },0", 31, True),
            (f + "body_array,BODY,{…},{ [] },0", 36, True),
            (f + "body_tuple,BODY,{…},{ (0\\, false\\, '\\\\u{0}') },0", 41, True),
            (f + 'body_result,BODY,{…},{ Ok("") },0', 46, True),
            # No default: a type parameter, a type of the program's own,
            # and a tuple that holds one.
            (("skipped", "no default", "{\n  x\n}", ""), 53, True),
            (("skipped", "no default", "{\n  { x, }\n}", ""), 58, True),
            (("skipped", "no default", "{\n  (x, { x, })\n}", ""), 63, True),
            # body_already and body_empty already are the default: no site.
            (("skipped", "FFI", 'pub extern "js" fn body_foreign(fd : Int32) -> Int32 = "(fd) => fd"', ""), 80, True),
            (f + "impl Eq for Point with equal,BODY,{…},{ false },0", 84, True),
            (f + "conditions,BODY,{…},{ 0 },0", 92, True),
            (f + "logic,BODY,{…},{ false },0", 120, True),
            (f + 'arithmetic,BODY,{…},{ "" },0', 130, True),
            (f + "integers,BODY,{…},{ () },0", 145, True),
            (f + "statements,BODY,{…},{ () },0", 165, True),
            (f + "values,BODY,{…},{ 0 },0", 188, True),
            (f + "only,BODY,{…},{ () },0", 194, True),
            (f + "yes,BODY,{…},{ false },0", 200, True),
            (f + "one,BODY,{…},{ 0 },0", 205, True),
        ])

    def test_ifc_forces_each_kind_of_condition(self):
        f = "forms/operators.mbt,conditions,IFC,"
        self.assertEqual(table(self.lines, ["conditions"], "IFC"), [
            (f + "p.x > 0,false,0", 93, True), (f + "p.x > 0,true,0", 93, False),
            (f + "p.x < -5,false,0", 95, True), (f + "p.x < -5,true,0", 95, False),
            (f + "p.x > 3,false,0", 98, True), (f + "p.x > 3,true,0", 98, False),
            (f + "i < p.x,false,0", 101, True), (f + "i < p.x,true,0", 101, False),
            # A guard statement: its else never runs when it is true.
            (f + "p.x != 7,true,0", 104, True), (f + "p.x != 7,false,0", 104, False),
            (f + "o is Some(_),true,0", 105, True), (f + "o is Some(_),false,0", 105, False),
            # A condition that binds a name is forced to false with `false
            # && (...)`, which keeps the name bound where the body uses it;
            # forced to true, the name would be unbound, so that is skipped.
            (f + "o is Some(v),false && (o is Some(v)),0", 106, True),
            (("skipped", "binds a name", "o is Some(v)", "true"), 106, False),
            # `while true` (109): BOOL's mutant is IFC's false, and true is
            # the condition itself, so IFC has no site there.
            (f + "n > 9,false,0", 113, True), (f + "n > 9,true,0", 113, False),
        ])

    def test_ifc_forces_a_guard_that_binds_a_name_only_to_false(self):
        # The pinned set's true would leave `v` unbound after the guard.
        self.assertEqual(table(self.lines, ["logic"], "IFC"), [
            ("forms/operators.mbt,logic,IFC,o is Some(v) && v > 0,false && (o is Some(v) && v > 0),0", 121, True),
            (("skipped", "binds a name", "o is Some(v) && v > 0", "true"), 121, False),
        ])
        guards = find_sites(FIXTURE, "forms/operators.mbt", chosen="full")
        self.assertEqual(table(guards, ["conditions"], "IFC")[10:12], [
            ("forms/operators.mbt,conditions,IFC,o is Some(_),true,0", 105, True),
            ("forms/operators.mbt,conditions,IFC,o is Some(_),false,0", 105, False),
        ])

    def test_lcr_swaps_and_and_or(self):
        f = "forms/operators.mbt,logic,LCR,"
        self.assertEqual(table(self.lines, ["logic"], "LCR"), [
            (("skipped", "binds a name", "&&", "||"), 121, True),
            (f + "&&,||,0", 124, True),
            (f + "||,&&,0", 124, True),
        ])

    def test_aor_swaps_arithmetic_and_compound_assignments(self):
        f = "forms/operators.mbt,arithmetic,AOR,"
        self.assertEqual(table(self.lines, ["arithmetic"], "AOR"), [
            # `%` is not AOR's.
            (f + "+,-,0", 131, True), (f + "-,+,0", 131, True), (f + "*,/,0", 131, True), (f + "/,*,0", 131, True),
            (f + "+=,-=,0", 132, True), (f + "-=,+=,0", 133, True), (f + "*=,/=,0", 134, True),
            (f + "/=,*=,0", 135, True),
            # To a field, and to an element.
            (f + "+=,-=,1", 136, True), (f + "*=,/=,1", 137, True),
            (("skipped", "string operand", "+", "-"), 138, True),
            (("skipped", "string operand", "+", "-"), 138, True),
        ])

    def test_int_takes_n_plus_one_and_n_minus_one_in_a_comparison_or_an_index(self):
        f = "forms/operators.mbt,integers,INT,"
        self.assertEqual(table(self.lines, ["integers"], "INT"), [
            # A comparison.
            (f + "10,11,0", 146, True), (f + "10,9,0", 146, True), (f + "10,0,0", 146, False),
            # Through arithmetic: n-1 of 1 is 0, one alternative.
            (f + "1,2,0", 147, True), (f + "1,0,0", 147, True),
            (f + "0,1,0", 147, True), (f + "0,-1,0", 147, True),
            # An index, a slice, and the index of a compound assignment.
            (f + "2,3,0", 148, True), (f + "2,1,0", 148, True), (f + "2,0,0", 148, False),
            (f + "1,2,1", 149, True), (f + "1,0,1", 149, True),
            (f + "3,4,0", 150, True), (f + "3,2,0", 150, True), (f + "3,0,0", 150, False),
            # Elsewhere: the value assigned, and a call's argument.
            (f + "4,5,0", 150, True), (f + "4,3,0", 150, False), (f + "4,0,0", 150, False),
            (f + "5,6,0", 151, True), (f + "5,4,0", 151, False), (f + "5,0,0", 151, False),
            # n+1 does not fit an Int, so the pinned set takes n-1.
            (f + "2147483647,2147483646,0", 152, True), (f + "2147483647,0,0", 152, False),
            # n-1 does not fit a UInt.
            (f + "0U,1U,0", 153, True),
            (f + "-1,0,0", 154, True), (f + "-1,-2,0", 154, False),
            # The base, the case of the digits and the suffix are kept.
            (f + "0xFFL,0x100L,0", 155, True), (f + "0xFFL,0xFEL,0", 155, False), (f + "0xFFL,0x0L,0", 155, False),
            (f + "1,2,2", 156, True), (f + "1,0,2", 156, False),
            # The pattern 6 (158) is no site.
        ])

    def test_del_deletes_calls_and_assignments(self):
        f = "forms/operators.mbt,"
        self.assertEqual(table(self.lines, ["statements", "values", "only"], "DEL"), [
            (f + "statements,DEL,n = 1,,0", 167, True),
            (f + "statements,DEL,n += 2,,0", 168, True),
            (f + "statements,DEL,p.x = 3,,0", 169, True),
            (f + "statements,DEL,xs[0] = n,,0", 170, True),
            (f + "statements,DEL,xs[1] -= 5,,0", 171, True),
            (f + "statements,DEL,xs.push(6),,0", 172, True),
            (f + "statements,DEL,ignore(n),,0", 173, True),
            (f + "statements,DEL,n |> ignore,,0", 174, True),
            # The last statement of an if's body without an else, and of a
            # loop's body; not a branch of an if with an else (178).
            (f + "statements,DEL,xs.clear(),,0", 176, True),
            (f + "statements,DEL,ignore(x),,0", 180, True),
            # The last statement of a function's body that returns Unit.
            (f + "statements,DEL,xs.push(m),,0", 182, True),
            # Not the value of values' body (190), nor only's one statement,
            # whose BODY site makes the same mutant.
            (f + "values,DEL,xs.push(8),,0", 189, True),
        ])

    def test_two_sites_that_make_the_same_mutant_are_one(self):
        # BODY's `{ false }` is BOOL's `false`, and BODY's `{ 0 }` is INT's 0.
        self.assertEqual(table(self.lines, ["yes", "one"]), [
            ("forms/operators.mbt,yes,BODY,{…},{ false },0", 200, True),
            ("forms/operators.mbt,one,BODY,{…},{ 0 },0", 205, True),
            ("forms/operators.mbt,one,INT,1,2,0", 206, True),
        ])
        # IFC's false at `while true` is BOOL's.
        self.assertEqual([(s["operator"], s["replacement"]) for s in self.lines if s["line"] == 109],
                         [("BOOL", "false")])


class StringsTest(unittest.TestCase):
    """STR: each form of a string literal, inside STR's scope and outside."""

    def test_str_changes_the_first_character_of_each_form(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "server").mkdir()
            shutil.copy(FIXTURE / "forms" / "strings.mbt", Path(tmp) / "server" / "strings.mbt")
            lines = find_sites(tmp, "server", chosen="full")
        f = "server/strings.mbt,strings,STR,"
        self.assertEqual(table(lines, operator="STR"), [
            (f + '"ab","_b",0', 11, True), (f + '"ab","",0', 11, False),
            (f + '"_b","-b",0', 12, True), (f + '"_b","",0', 12, False),
            (f + '"","_",0', 13, True),
            # An escape is one character, and it stands for one: `\u{5F}` is `_`.
            (f + r'"\\tb","_b",0', 14, True), (f + r'"\\tb","",0', 14, False),
            (f + r'"\\u{5F}b","-b",0', 15, True), (f + r'"\\u{5F}b","",0', 15, False),
            # The first character outside any interpolation, or none.
            (f + r'"\\{x}b","\\{x}_",0', 16, True), (f + r'"\\{x}b","",0', 16, False),
            (f + r'"\\{x}","_\\{x}",0', 17, True), (f + r'"\\{x}","",0', 17, False),
            (f + 'b"ab",b"_b",0', 18, True), (f + 'b"ab",b"",0', 18, False),
            # A character literal (19) is no site; nor is the pattern (31).
            # Over several lines, the id writes the first and the last line.
            (f + '#|ab…#|cd,#|_b…#|cd,0', 21, True), (f + '#|ab…#|cd,"",0', 21, False),
            (f + '#|…#|cd,#|…#|_d,0', 24, True), (f + '#|…#|cd,"",0', 24, False),
            (f + r'$|\\{x}ab,$|\\{x}_b,0', 27, True), (f + r'$|\\{x}ab,"",0', 27, False),
            # A map literal's key.
            (f + '"k","_",0', 29, True), (f + '"k","",0', 29, False),
            # BODY's `{ "" }` is the empty literal's mutant.
            ('server/strings.mbt,name,STR,"ab","_b",0', 40, True),
        ])
        self.assertEqual(
            [s["replacement"] for s in lines if s["line"] == 21 and s["pinned"] and s["operator"] == "STR"],
            ["#|_b\n    #|cd"])

    def test_outside_strs_scope_each_string_is_a_skipped_site(self):
        inside = {(s["line"], s["original"], s["replacement"], s["pinned"])
                  for s in find_sites(FIXTURE, "forms/strings.mbt", chosen="full") if s["operator"] == "STR"}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "server").mkdir()
            shutil.copy(FIXTURE / "forms" / "strings.mbt", Path(tmp) / "server" / "strings.mbt")
            copied = [s for s in find_sites(tmp, "server", chosen="full") if s["operator"] == "STR"]
        self.assertEqual(inside, {(s["line"], s["original"], s["replacement"], s["pinned"]) for s in copied})
        outside = [s for s in find_sites(FIXTURE, "forms/strings.mbt", chosen="full") if s["operator"] == "STR"]
        self.assertEqual({s.get("skipped") for s in outside}, {"outside scope"})

    def test_strs_scope_holds_the_protocol_packages_server_and_logs_writers(self):
        # In the fixture: log/target.mbt, as smock's reader of request
        # targets, is outside STR's scope; the rest of log is inside.
        lines = find_sites(FIXTURE, "log", chosen="full")
        self.assertEqual({(s["file"], s.get("skipped")) for s in lines if s["operator"] == "STR"},
                         {("log/lines.mbt", None), ("log/target.mbt", "outside scope")})
        self.assertEqual(table(lines), [
            ('log/lines.mbt,line,BODY,{…},{ "" },0', 9, True),
            ('log/lines.mbt,line,STR,"info: ","_nfo: ",0', 14, True),
            ('log/lines.mbt,line,STR,"info: ","",0', 14, False),
            (("skipped", "string operand", "+", "-"), 14, True),
            ("log/lines.mbt,is_comment,BODY,{…},{ false },0", 19, True),
            ('log/lines.mbt,is_comment,STR,"#","_",0', 24, True),
            ('log/lines.mbt,is_comment,STR,"#","",0', 24, False),
            ('log/lines.mbt,cut_mark,BODY,{…},{ "" },0', 29, True),
            ('log/lines.mbt,cut_mark,STR,"~","_",0', 34, True),
            (("skipped", "outside scope", '"/"', '"_"'), 7, True),
            (("skipped", "outside scope", '"/"', '""'), 7, False),
        ])
        # In the workspace: log's line and envelope writers are inside, its
        # reader of request targets is outside (its strings are all in doc
        # comments today, so it has no STR site at all), and so is usage.
        repo = find_sites(REPO, "log", "usage", chosen="full")
        scoped = {}
        for s in repo:
            if s["operator"] == "STR":
                scoped.setdefault(s["file"], set()).add(s.get("skipped"))
        self.assertNotIn(None, scoped.get("log/target.mbt", set()))
        for file in ("log/log.mbt", "log/envelope.mbt", "log/mockoon.mbt"):
            self.assertEqual(scoped.get(file), {None}, file)
        self.assertEqual(scoped.get("usage/usage.mbt"), {"outside scope"})

    def test_strs_scope_holds_the_parsers_moved_out_of_server(self):
        # serverparsers holds server's pure parsers (#317, #318, #319), whose
        # strings STR's scope covered while they were in server, so it holds
        # them there too: each string of the forms is a site in both.
        with tempfile.TemporaryDirectory() as tmp:
            for package in ("server", "serverparsers"):
                (Path(tmp) / package).mkdir()
                shutil.copy(FIXTURE / "forms" / "strings.mbt", Path(tmp) / package / "strings.mbt")
            found = [s for s in find_sites(tmp, "server", "serverparsers", chosen="full") if s["operator"] == "STR"]
        sites = {}
        for s in found:
            package = s["file"].split("/")[0]
            sites.setdefault(package, set()).add((s["line"], s["original"], s["replacement"], s.get("skipped")))
        self.assertEqual({p: {skipped for *_, skipped in held} for p, held in sites.items()},
                         {"server": {None}, "serverparsers": {None}})
        self.assertEqual(sites["serverparsers"], sites["server"])


def logging_moon(directory, fail_build_when=None):
    """A moon that logs each of its command lines and runs the real one."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    script = directory / "moon"
    log = directory / "moon.log"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return script, log


class RunnerTest(unittest.TestCase):
    """One run of calc's pinned set, the default, which the tests read, and
    runs of one mutant alone, in the same work directory."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "all"
        cls.result = cls.run_runner(cls.out, "calc")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args):
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(out),
             "--moon", str(cls.moon), *args],
            capture_output=True, text=True)

    def test_each_mutant_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["outcome"]) for r in self.records],
                         [(i, outcome) for i, _, _, outcome in CALC])

    def test_a_record_names_the_tests_that_killed_its_mutant(self):
        killed = {r["id"]: [t["name"] for t in r["killing_tests"]] for r in self.records}
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,0"], ["a number at the low end is in range"])
        self.assertEqual(killed["calc/calc.mbt,is_odd,NOT,!,,0"], ["3 is odd"])
        self.assertEqual(killed["calc/calc.mbt,in_range,LCR,&&,||,0"], ["a number below the range is not in it"])
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,1"], [])

    def test_a_record_gives_the_backend_the_timings_the_set_and_the_operator_set(self):
        for record in self.records:
            self.assertEqual(record["backend"], "wasm-gc")
            self.assertEqual(record["package"], "mutation/fixture/calc")
            self.assertEqual((record["operator_set"], record["set"], record["pinned"]), (VERSION, "pinned", True))
            timings = record["timings"]
            self.assertGreater(timings["build_s"], 0)
            # An unviable mutant never runs.
            if record["outcome"] == "unviable":
                self.assertEqual(timings["run_s"], 0)
            else:
                self.assertGreater(timings["run_s"], 0)
        summary = json.loads((self.out / "summary.json").read_text())["packages"][0]
        limit = 1.25 * summary["baseline"]["run_s"] + 4
        timed_out = next(r for r in self.records if r["outcome"] == "timed out")
        self.assertAlmostEqual(timed_out["timings"]["limit_s"], limit, places=2)
        self.assertGreaterEqual(timed_out["timings"]["run_s"], limit)

    def test_a_mutant_that_does_not_compile_is_unviable(self):
        # DEL of `x = x / 2` leaves a `let mut` that is never changed, which
        # the compiler refuses.
        record = next(r for r in self.records if r["id"] == "calc/calc.mbt,halve_until,DEL,x = x / 2,,0")
        self.assertEqual(record["outcome"], "unviable")
        self.assertIn("never used", record["message"])

    def test_each_kill_and_the_time_out_are_confirmed(self):
        # calc's tests are not flaky: each kill fails again with the mutant
        # on and passes with it off, and the endless loop times out again,
        # while the run without it finishes within the limit.
        judged = [r for r in self.records if r["outcome"] in ("killed", "timed out")]
        self.assertEqual(len(judged), 15)
        for record in judged:
            self.assertEqual(record["confirmation"], "confirmed", record["id"])
            self.assertGreater(record["timings"]["without_s"], 0)
        timed_out = next(r for r in judged if r["outcome"] == "timed out")
        self.assertGreaterEqual(timed_out["timings"]["again_s"], timed_out["timings"]["limit_s"])
        self.assertLess(timed_out["timings"]["without_s"], timed_out["timings"]["limit_s"])
        killed = {r["id"]: [t["name"] for t in r["killing_tests"]] for r in judged}
        self.assertEqual(killed["calc/calc.mbt,in_range,ROR,<=,<,0"], [LOW[3]])
        # The tests ran twice without a mutant; the longer run sets the limit.
        summary = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual(len(summary["baseline"]["runs_s"]), 2)
        self.assertEqual(summary["baseline"]["run_s"], max(summary["baseline"]["runs_s"]))
        self.assertEqual(summary["baseline"]["failed"], [])
        # A confirmed time-out counts as killed (#275, "Outcomes").
        self.assertEqual((summary["unconfirmed"], summary["score"]), (0, round(15 / 24, 4)))

    def test_the_summary_counts_each_outcome_of_the_package(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual((summary["operator_set"], summary["set"]), (VERSION, "pinned"))
        self.assertEqual(len(summary["packages"]), 1)
        package = summary["packages"][0]
        self.assertEqual(package["package"], "mutation/fixture/calc")
        self.assertEqual(package["backend"], "wasm-gc")
        self.assertEqual(
            {k: package[k] for k in ("sites", "positions", "mutants", "killed", "timed_out", "survived", "unviable")},
            {"sites": 25, "positions": 22, "mutants": 25, "killed": 14, "timed_out": 1, "survived": 9,
             "unviable": 1})
        self.assertEqual(package["baseline"]["tests"], 7)
        # Both sets' counts; calc has no skipped site.
        self.assertEqual(package["sets"], {
            "pinned": {"sites": 25, "positions": 22, "skipped": {}},
            "full": {"sites": 31, "positions": 22, "skipped": {}},
        })

    def test_the_report_shows_each_survivor_with_its_definition(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("Operator set v1, the pinned set.", report)
        self.assertIn("| pinned | 25 | 22 |\n| full | 31 | 22 |", report)
        self.assertIn("calc/calc.mbt,is_blank,NOT,!,,0", report)
        self.assertIn("calc/calc.mbt,is_blank,BOOL,true,false,0", report)
        self.assertIn(
            "@@ -10,9 +10,9 @@ in_range\n"
            " pub fn in_range(n : Int32, low : Int32, high : Int32) -> Bool {\n",
            report)
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n }\n", report)
        # The time-out is listed apart, and no killed mutant is shown.
        self.assertIn("calc/calc.mbt,halve_until,ROR,>,>=,0", report)
        self.assertNotIn("calc/calc.mbt,is_odd,NOT,!,,0", report)
        # The run prints the report.
        self.assertIn("-  low <= n && n <= high\n+  low <= n && n < high\n", self.result.stdout)

    def test_each_survivor_has_its_status_after_the_exclusion_list(self):
        # The fixture's exclusion list (fixture/exclusions.toml) has three
        # entries for calc's survivors: a current ARID one, which accepts
        # its survivor; a current DEFERRED one, which still counts as
        # unexplained; and a stale one, whose survivor is stale-covered
        # (#302). The other survivors have none: unexplained.
        status = {r["id"]: r["exclusion"] for r in self.records if r["outcome"] == "survived"}
        self.assertEqual(status.pop("calc/calc.mbt,is_blank,BOOL,true,false,0"),
                         {"status": "accepted", "entry": "calc/calc.mbt,is_blank,BOOL,true,false,0",
                          "category": "ARID"})
        self.assertEqual(status.pop("calc/calc.mbt,is_odd,INT,0,-1,0"),
                         {"status": "unexplained", "entry": "calc/calc.mbt,is_odd,INT,0,-1,0",
                          "category": "DEFERRED", "issue": 1})
        self.assertEqual(status.pop("calc/calc.mbt,halve_until,INT,2,3,0"),
                         {"status": "stale-covered", "entry": "calc/calc.mbt,halve_until,INT,2,3,0",
                          "category": "ARID"})
        self.assertEqual(len(status), 6)
        self.assertEqual(status, {i: {"status": "unexplained"} for i in status})
        # Only a survivor has a status.
        self.assertFalse(any("exclusion" in r for r in self.records if r["outcome"] != "survived"))

    def test_the_summary_and_the_report_count_the_survivors_after_the_exclusion_list(self):
        package = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual(package["exclusions"], {"unexplained": 7, "stale_covered": 1, "accepted": 1,
                                                 "accepted_by_category": {"ARID": 1}})
        report = (self.out / "report.md").read_text()
        self.assertIn("After the exclusion list: 7 unexplained, 1 stale-covered, 1 accepted (ARID 1).", report)
        self.assertIn("#### `calc/calc.mbt,halve_until,INT,2,3,0`\n\nStale-covered: its only entry,"
                      " `calc/calc.mbt,halve_until,INT,2,3,0`, is stale.\n", report)
        self.assertIn("#### `calc/calc.mbt,is_odd,INT,0,-1,0`\n\nUnexplained: DEFERRED to #1.\n", report)
        self.assertIn("#### `calc/calc.mbt,is_blank,BOOL,true,false,0`\n\nAccepted by the exclusion list: ARID.\n",
                      report)
        self.assertIn("#### `calc/calc.mbt,is_blank,NOT,!,,0`\n\nUnexplained.\n", report)
        # The unexplained survivors come first, then the stale-covered one,
        # then the accepted one.
        self.assertLess(report.index("`calc/calc.mbt,is_odd,INT,0,-1,0`\n"),
                        report.index("`calc/calc.mbt,halve_until,INT,2,3,0`\n"))
        self.assertLess(report.index("`calc/calc.mbt,halve_until,INT,2,3,0`\n"),
                        report.index("`calc/calc.mbt,is_blank,BOOL,true,false,0`\n"))

    def test_the_summary_and_the_report_list_the_pseudo_tested_functions(self):
        # #275, "Terms": "A function whose BODY mutant survives is
        # pseudo-tested"; #313's baseline gives them per package. Of calc's
        # four BODY mutants, only halve_until's survives (CALC).
        package = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual(package["body_mutants"], 4)
        self.assertEqual(package["pseudo_tested"], [
            {"definition": "halve_until", "file": "calc/calc.mbt",
             "mutant": "calc/calc.mbt,halve_until,BODY,{…},{ 0 },0", "status": "unexplained"}])
        report = (self.out / "report.md").read_text()
        self.assertIn("### Pseudo-tested functions (1 of 4 BODY mutants)\n\n"
                      "Each function's BODY mutant survived; L2 needs it killed or excluded.\n\n"
                      "- `halve_until` (calc/calc.mbt): Unexplained.\n", report)

    def test_the_runner_never_passes_u(self):
        # in_range's first mutant is killed by a snapshot alone, which -u
        # would rewrite: it would then survive.
        lines = self.log.read_text().splitlines()
        self.assertTrue(lines)
        for line in lines:
            self.assertNotIn("--update", line.split())
            self.assertNotIn("-u", line.split())
        self.assertEqual((self.work / "tree-0" / "calc" / "calc_test.mbt").read_text(),
                         (FIXTURE / "calc" / "calc_test.mbt").read_text())

    def test_one_mutant_runs_alone_by_its_id(self):
        # Among two packages: shapes holds none of the ids, so it is not run.
        out = self.tmp / "one"
        result = self.run_runner(out, "--mutant", "calc/calc.mbt,is_odd,NOT,!,,0", "calc", "shapes")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [("calc/calc.mbt,is_odd,NOT,!,,0", "killed")])
        summary = json.loads((out / "summary.json").read_text())
        self.assertEqual([(p["package"], p["mutants"]) for p in summary["packages"]], [("mutation/fixture/calc", 1)])

    def test_an_unknown_id_fails(self):
        result = self.run_runner(self.tmp / "unknown", "--mutant", "calc/calc.mbt,is_odd,NOT,!,,9", "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no site of calc in the pinned set has the id calc/calc.mbt,is_odd,NOT,!,,9", result.stderr)

    def test_an_id_of_the_full_set_alone_is_not_in_the_pinned_set(self):
        result = self.run_runner(self.tmp / "other", "--mutant", "calc/calc.mbt,is_odd,INT,2,0,0", "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no site of calc in the pinned set has the id calc/calc.mbt,is_odd,INT,2,0,0", result.stderr)

    def test_a_mutant_that_does_not_build_is_unviable_and_never_runs(self):
        # A finder that gives one site whose replacement does not parse.
        # Were the build's exit status not checked, the tests would run the
        # binary of the last build, the baseline's, and pass.
        site = {"id": "calc/calc.mbt,in_range,ROR,<=,<=<,0", "file": "calc/calc.mbt", "definition": "in_range",
                "operator": "ROR", "original": "<=", "replacement": "<=<", "ordinal": 0,
                "line": 17, "column": 17, "definition_lines": [10, 18], "pinned": True, "operator_set": VERSION}
        finder = self.tmp / "finder"
        finder.write_text(f"#!/bin/sh\necho '{json.dumps(site)}'\n")
        finder.chmod(finder.stat().st_mode | stat.S_IXUSR)
        out = self.tmp / "unviable"
        before = len(self.log.read_text().splitlines())
        result = self.run_runner(out, "--finder", str(finder), "calc")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"]) for r in records], [(site["id"], "unviable")])
        self.assertIn("Parse error", records[0]["message"])
        summary = json.loads((out / "summary.json").read_text())["packages"][0]
        self.assertEqual((summary["unviable"], summary["killed"], summary["survived"]), (1, 0, 0))
        # The last thing the run did was the failed build.
        self.assertIn("--build-only", self.log.read_text().splitlines()[-1].split())
        self.assertGreater(len(self.log.read_text().splitlines()), before)

    def test_a_finder_line_without_an_operator_set_fails(self):
        site = {"id": "calc/calc.mbt,in_range,ROR,<=,<,1", "file": "calc/calc.mbt", "definition": "in_range",
                "operator": "ROR", "original": "<=", "replacement": "<", "ordinal": 1,
                "line": 17, "column": 17, "definition_lines": [10, 18], "pinned": True}
        finder = self.tmp / "unversioned"
        finder.write_text(f"#!/bin/sh\necho '{json.dumps(site)}'\n")
        finder.chmod(finder.stat().st_mode | stat.S_IXUSR)
        result = self.run_runner(self.tmp / "unversioned-out", "--finder", str(finder), "calc")
        self.assertEqual(result.returncode, 1)
        self.assertIn("do not name one operator set", result.stderr)


class FullSetTest(unittest.TestCase):
    """One run of log's full set, and a count of forms' sites without a
    run."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-full-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "full"
        cls.result = cls.run_runner(cls.out, "--set", "full", "log")
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_runner(cls, out, *args):
        return subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(out),
             "--moon", str(cls.moon), *args],
            capture_output=True, text=True)

    def test_each_mutant_of_the_full_set_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["pinned"], r["outcome"]) for r in self.records], LOG)
        self.assertEqual({(r["set"], r["operator_set"]) for r in self.records}, {("full", VERSION)})

    def test_the_summary_counts_the_pinned_and_the_other_alternatives_apart(self):
        summary = json.loads((self.out / "summary.json").read_text())
        self.assertEqual((summary["operator_set"], summary["set"]), (VERSION, "full"))
        package = summary["packages"][0]
        self.assertEqual({k: package[k] for k in ("sites", "positions", "mutants", "killed", "survived")},
                         {"sites": 8, "positions": 6, "mutants": 8, "killed": 6, "survived": 2})
        self.assertEqual({k: package["pinned"][k] for k in ("mutants", "killed", "survived")},
                         {"mutants": 6, "killed": 5, "survived": 1})
        self.assertEqual({k: package["other"][k] for k in ("mutants", "killed", "survived")},
                         {"mutants": 2, "killed": 1, "survived": 1})
        self.assertEqual(package["skipped"], {"AOR string operand": 1, "STR outside scope": 2})
        self.assertEqual(package["sets"]["pinned"],
                         {"sites": 6, "positions": 6, "skipped": {"AOR string operand": 1, "STR outside scope": 1}})

    def test_the_report_lists_the_survivors_at_the_other_alternatives_apart(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("Operator set v1, the full set.", report)
        self.assertIn("Sites skipped in this set: AOR string operand 1, STR outside scope 2.", report)
        pinned = report.index("### Survivors at the pinned alternatives (1)")
        other = report.index("### Survivors at the other alternatives (1)")
        self.assertLess(pinned, report.index('log/lines.mbt,cut_mark,STR,"~","_",0'), other)
        self.assertGreater(report.index('log/lines.mbt,is_comment,STR,"#","",0'), other)

    def test_a_count_of_sites_runs_no_mutant(self):
        before = self.log.read_text()
        out = self.tmp / "count"
        result = self.run_runner(out, "--sites-only", "forms")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(), before)
        self.assertEqual((out / "mutants.jsonl").read_text(), "")
        package = json.loads((out / "summary.json").read_text())["packages"][0]
        self.assertEqual(package["sets"]["full"]["skipped"], {
            "AOR string operand": 2, "BODY FFI": 1, "BODY no default": 3, "IFC binds a name": 2,
            "LCR binds a name": 1, "STR outside scope": 28})
        self.assertEqual(package["sets"]["pinned"]["skipped"], {
            "AOR string operand": 2, "BODY FFI": 1, "BODY no default": 3,
            "LCR binds a name": 1, "STR outside scope": 15})
        report = (out / "report.md").read_text()
        self.assertIn("## mutation/fixture/forms", report)
        self.assertIn("Sites skipped in this set: AOR string operand 2, BODY FFI 1, BODY no default 3,"
                      " LCR binds a name 1, STR outside scope 15.", report)


class ImportersTest(unittest.TestCase):
    """One run of units' pinned set, whose survivors run again with the
    tests of the packages that import units, and the importers of smock's
    own packages."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-importers-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.out = cls.tmp / "units"
        cls.result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.tmp / "work"), "--out", str(cls.out),
             "--moon", str(cls.moon), "units"],
            capture_output=True, text=True)
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_an_importers_test_kills_what_the_packages_own_tests_leave(self):
        self.assertEqual([(r["id"], r["outcome"]) for r in self.records],
                         [(i, after) for i, _, after, _ in UNITS])

    def test_a_record_names_the_package_of_each_test_that_killed_it(self):
        self.assertEqual([(r["id"], sorted({t["package"] for t in r["killing_tests"]})) for r in self.records],
                         [(i, packages) for i, _, _, packages in UNITS])
        killed = {r["id"]: [t["name"] for t in r["killing_tests"]] for r in self.records}
        self.assertEqual(killed["units/units.mbt,within,ROR,<=,<,0"],
                         ["a reading at the low end of the scale is on it"])
        self.assertEqual(killed["units/units.mbt,within,ROR,<=,<,1"],
                         ["a reading at the high end of a scale from 0 to 10 is on it"])

    def test_only_the_survivors_of_the_packages_own_tests_run_again(self):
        # With the tests of meter and of dial, which reaches units through
        # meter; not with probe's, which builds only natively.
        importers = ["mutation/fixture/dial", "mutation/fixture/meter"]
        self.assertEqual([(r["id"], r["importers"]) for r in self.records],
                         [(i, importers if own == "survived" else []) for i, own, _, _ in UNITS])
        for record in self.records:
            if record["importers"]:
                self.assertGreater(record["timings"]["importers"]["run_s"], 0)
            else:
                self.assertNotIn("importers", record["timings"])
        # Only the last survivor keeps its diff.
        self.assertEqual([r["id"] for r in self.records if "diff" in r], ["units/units.mbt,past,ROR,>,>=,0"])

    def test_a_native_only_importers_tests_never_run(self):
        # probe's test would kill `n >= high`, but a pure package's verdict
        # is taken on wasm-gc. moon is only asked whether probe builds there.
        runs = [line.split() for line in self.log.read_text().splitlines()
                if "mutation/fixture/probe" in line.split()]
        self.assertTrue(runs)
        for words in runs:
            self.assertIn("--dry-run", words)

    def test_the_summary_counts_the_outcomes_before_and_after_the_importers_tests(self):
        package = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual({k: package["own"][k] for k in ("mutants", "killed", "timed_out", "survived", "unviable")},
                         {"mutants": 6, "killed": 3, "timed_out": 0, "survived": 3, "unviable": 0})
        self.assertEqual(package["own"]["score"], 0.5)
        self.assertEqual({k: package[k] for k in ("mutants", "killed", "timed_out", "survived", "unviable")},
                         {"mutants": 6, "killed": 5, "timed_out": 0, "survived": 1, "unviable": 0})
        importers = package["importers"]
        self.assertEqual(importers["packages"], ["mutation/fixture/dial", "mutation/fixture/meter"])
        self.assertEqual(importers["native_only"], ["mutation/fixture/probe"])
        self.assertEqual(importers["baseline"]["tests"], 2)
        self.assertAlmostEqual(importers["limit_s"], 1.25 * importers["baseline"]["run_s"] + 4, places=2)
        self.assertEqual((importers["reran"], importers["killed"]), (3, 2))
        self.assertEqual(importers["killed_by"], {"mutation/fixture/dial": 1, "mutation/fixture/meter": 1})

    def test_the_report_gives_the_importers_and_what_their_tests_killed(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("With its own tests alone: 6 mutants, killed 3, timed out 0, survived 3, unviable 0,"
                      " score 50.0%.", report)
        self.assertIn("Importers that build on wasm-gc: mutation/fixture/dial, mutation/fixture/meter.", report)
        self.assertIn("Importers that build only natively, whose tests give no credit: mutation/fixture/probe.",
                      report)
        self.assertIn("Their tests ran the 3 survivors of its own tests again and killed 2:"
                      " mutation/fixture/dial 1, mutation/fixture/meter 1.", report)
        self.assertIn("### Survivors (1)", report)
        self.assertIn("units/units.mbt,past,ROR,>,>=,0", report)
        self.assertNotIn("#### `units/units.mbt,within,ROR,<=,<,0`", report)

    def test_the_importers_tests_never_run_when_nothing_survives(self):
        # meter's one mutant, BODY's `{ false }`, is killed by meter's own
        # test, so dial's tests, which import meter, are not even built.
        before = len(self.log.read_text().splitlines())
        out = self.tmp / "meter"
        result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(self.tmp / "work"), "--out", str(out),
             "--moon", str(self.moon), "meter"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        self.assertEqual([(r["id"], r["outcome"], r["importers"]) for r in records],
                         [("meter/meter.mbt,on_scale,BODY,{…},{ false },0", "killed", [])])
        importers = json.loads((out / "summary.json").read_text())["packages"][0]["importers"]
        self.assertEqual((importers["packages"], importers["reran"], importers["killed"]),
                         (["mutation/fixture/dial"], 0, 0))
        self.assertNotIn("baseline", importers)
        for line in self.log.read_text().splitlines()[before:]:
            if "mutation/fixture/dial" in line.split():
                self.assertIn("--dry-run", line.split())

    def test_smocks_importers_come_from_the_build_and_leave_out_native_only_packages(self):
        # Worked out by hand from each package's moon.pkg: its imports, for
        # its source and for its tests, and its supported_targets.
        result = subprocess.run([sys.executable, str(HERE / "importers.py"), "--root", str(REPO),
                                 "template", "log", "yaml", "protobuf", "testcerts", "unicode"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        found = {line["package"]: line for line in map(json.loads, result.stdout.splitlines())}
        # template: llm and definitions import it, engine, importopenapi,
        # serverparsers (which imports definitions since #318) and settings
        # through them; defdir, server and cmd/smock build only natively
        # (#300: engine's tests killed 16 of template's survivors).
        self.assertEqual(found["smock/smock/template"]["importers"],
                         ["smock/smock/definitions", "smock/smock/engine", "smock/smock/importopenapi",
                          "smock/smock/llm", "smock/smock/serverparsers", "smock/smock/settings"])
        self.assertEqual(found["smock/smock/template"]["native_only"],
                         ["smock/smock/cmd/smock", "smock/smock/defdir", "smock/smock/server"])
        # Through as many packages as it takes: only template imports
        # unicode, definitions imports template, and settings imports
        # definitions, but neither template nor unicode.
        self.assertIn("smock/smock/settings", found["smock/smock/unicode"]["importers"])
        # e2e imports log for its tests, and builds only natively: e2e tests
        # give no credit for a pure package.
        self.assertIn("smock/smock/e2e", found["smock/smock/log"]["native_only"])
        self.assertIn("smock/smock/template", found["smock/smock/log"]["importers"])
        # schema imports yaml for its tests, and yaml-test-suite imports it;
        # protobuf-conformance imports protobuf; all three build only
        # natively (#300, "Native-only importers").
        self.assertTrue({"smock/smock/schema", "smock/smock/yaml-test-suite"}
                        <= set(found["smock/yaml"]["native_only"]))
        self.assertIn("smock/smock/protobuf-conformance", found["smock/protobuf"]["native_only"])
        # A test import reaches no further: cmd/smock imports server, which
        # imports testcerts only for its tests (as openssl does, and since
        # #384 server's own white-box tests), so cmd/smock is no importer.
        self.assertEqual((found["smock/smock/testcerts"]["importers"], found["smock/smock/testcerts"]["native_only"]),
                         ([], ["smock/smock/e2e", "smock/smock/openssl", "smock/smock/server"]))
        for line in found.values():
            self.assertEqual(set(line["importers"]) & NATIVE_ONLY, set(), line["package"])


# A moon that answers the runs of tests, but not their builds nor the dry
# runs, from a script: a JSON list of answers, taken in turn. "real" runs
# the real moon; {"fail": [test, ...]} prints what moon prints when those
# tests fail, and exits as it does; {"sleep": s} waits s seconds, and the
# runner stops it at its time limit; {"crash": how} prints what moon prints
# when a test program stops before its end, as one did in each weekly run
# (#431: "The test executable exited with signal: 11 (SIGSEGV)"), naming no
# test, and exits as moon 0.1.20261104 does then, with 255. Once the script
# is used up, the real moon answers. Its arguments: the script, a log of the
# command lines, the real moon, then moon's own.
SCRIPTED_MOON = '''\
import json, os, sys, time
script, log, real, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
with open(log, "a") as f:
    f.write(" ".join(args) + "\\n")
if args[:1] == ["test"] and "--build-only" not in args and "--dry-run" not in args:
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
        if isinstance(answer, dict) and "sleep" in answer:
            time.sleep(answer["sleep"])
        if isinstance(answer, dict) and "crash" in answer:
            target = args[args.index("--target") + 1]
            print(f"Error: failed to run test for target {target}\\n\\nCaused by:\\n"
                  f"    Failed to run the test: a test program\\n"
                  f"    The test executable exited with {answer['crash']}")
            sys.exit(255)
os.execv(real, [real, *args])
'''


class FlakeRecordsTest(unittest.TestCase):
    """The flake records of one run made of shards, each of which writes
    its own (#301: a weekly run on Actions is sharded, and the next run
    reads one file)."""

    def test_the_shards_of_a_run_make_one_run(self):
        earlier = {"suites": {"p/a": 4}, "tests": [{"package": "p/a", "file": "a_test.mbt", "name": "x",
                                                      "flaked": 1, "reruns": 0}]}
        shards = [
            {"suites": {"p/a": 2, "p/b": 3},
             "tests": [{"package": "p/a", "file": "a_test.mbt", "name": "x", "flaked": 1, "reruns": 2}]},
            {"suites": {"p/a": 2},
             "tests": [{"package": "p/a", "file": "a_test.mbt", "name": "x", "flaked": 0, "reruns": 1},
                       {"package": "p/b", "file": "b_test.mbt", "name": "y", "flaked": 1, "reruns": 0}]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for n, mine in enumerate(shards):
                path = Path(tmp) / f"shard-{n}.json"
                path.write_text(json.dumps({"version": 1, "threshold": 0.01, "recent_runs": 10,
                                            "runs": [earlier, mine], "rates": []}))
                paths.append(str(path))
            result = subprocess.run([sys.executable, str(HERE / "confirm.py"), "merge", *paths],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            merged = json.loads(result.stdout)
            self.assertEqual(merged["runs"], [earlier, {
                "suites": {"p/a": 4, "p/b": 3},
                "tests": [{"package": "p/a", "file": "a_test.mbt", "name": "x", "flaked": 1, "reruns": 3},
                          {"package": "p/b", "file": "b_test.mbt", "name": "y", "flaked": 1, "reruns": 0}]}])
            # x: 2 flaky results in 4 + 4 runs of p/a and 3 reruns; y: 1 in 3.
            self.assertEqual(merged["rates"], [
                {"package": "p/b", "file": "b_test.mbt", "name": "y", "flaked": 1, "observed": 3,
                 "rate": round(1 / 3, 6)},
                {"package": "p/a", "file": "a_test.mbt", "name": "x", "flaked": 2, "observed": 11,
                 "rate": round(2 / 11, 6)}])
            # Shards that read different records are not one run.
            other = Path(tmp) / "other.json"
            other.write_text(json.dumps({"version": 1, "threshold": 0.01, "recent_runs": 10,
                                         "runs": [shards[0]], "rates": []}))
            result = subprocess.run([sys.executable, str(HERE / "confirm.py"), "merge", paths[0], str(other)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("did not read the same flake records", result.stderr)


class EarlierRecordsTest(unittest.TestCase):
    """Records as the runner wrote them before #431, without "ended", as
    the weekly runs' artifacts keep them for months: the report, the
    merge of an importers' run and the native verdicts still read them,
    and say of them what they said."""

    @staticmethod
    def records():
        # The second weekly run's records, cut to what the readers use: an
        # unconfirmed survivor of definitions' own tests, a confirmed kill
        # and a survivor.
        where = {"package": "smock/smock/definitions", "file": "definitions/response.mbt",
                 "definition": "File::read_response", "definition_lines": [1, 3], "pinned": True,
                 "operator": "BOOL"}
        unconfirmed = dict(where, id="definitions/response.mbt,File::read_response,BOOL,false,true,6",
                           outcome="unconfirmed", first_outcome="killed", diff="the diff\n",
                           confirmation="the tests that failed passed when run again with the mutant on",
                           failed_first=[], killing_tests=[], importers=["smock/smock/engine"],
                           message="The test executable exited with signal: 11 (SIGSEGV) (core dumped)",
                           timings={"build_s": 0.8, "run_s": 0.4, "limit_s": 4.48,
                                    "importers": {"build_s": 2.6, "run_s": 1.264, "limit_s": 6.246,
                                                  "again_s": 1.894}})
        killed = dict(where, id="definitions/response.mbt,File::read_response,BOOL,false,true,5", outcome="killed",
                      confirmation="confirmed", importers=[],
                      killing_tests=[{"package": "smock/smock/definitions", "file": "a_test.mbt", "index": 0,
                                      "name": "t"}],
                      timings={"build_s": 0.8, "run_s": 0.4, "limit_s": 4.48, "again_s": 0.4, "without_s": 0.4})
        survived = dict(where, id="definitions/response.mbt,File::read_response,BOOL,false,true,4",
                        outcome="survived", killing_tests=[], importers=["smock/smock/engine"],
                        exclusion={"status": "unexplained"}, diff="the diff\n",
                        timings={"build_s": 0.8, "run_s": 0.4, "limit_s": 4.48,
                                 "importers": {"build_s": 2.6, "run_s": 1.3, "limit_s": 6.2}})
        return [unconfirmed, killed, survived]

    def test_the_report_reads_records_without_how_their_runs_ended(self):
        import compare
        import run

        records = self.records()
        summary = {"package": "smock/smock/definitions", "directory": "definitions", "operator_set": VERSION,
                   "set": "pinned", "sites": 3, "positions": 3, "skipped": {},
                   "sets": {s: {"sites": 3, "positions": 3, "skipped": {}} for s in ("pinned", "full")},
                   "backend": "wasm-gc", "baseline": {"run_s": 0.4, "runs_s": [0.4, 0.4], "tests": 9, "failed": []},
                   "limit_s": 4.48, **run.outcome_counts(records), **compare.counts(records)}
        report = run.report(VERSION, "pinned", [summary], records)
        self.assertIn("### Unconfirmed (1)\n\n#### `definitions/response.mbt,File::read_response,BOOL,false,true,6`"
                      "\n\nIt was killed, but the tests that failed passed when run again with the mutant on.", report)
        self.assertIn("### Survivors (1)\n\n#### `definitions/response.mbt,File::read_response,BOOL,false,true,4`"
                      "\n\nUnexplained.\n\nIn `File::read_response`", report)
        self.assertNotIn("ended otherwise", report)
        self.assertNotIn("Not a kill", report)

    def test_the_importers_and_native_verdicts_take_records_without_how_their_runs_ended(self):
        import importers
        import native

        unconfirmed, killed, survived = self.records()
        own = dict(survived, importers=[], timings={"run_s": 0.4})
        credit = importers.credit(["smock/smock/engine"], [])
        importers.merge(own, unconfirmed, ["smock/smock/engine"], credit)
        self.assertEqual((own["outcome"], own["first_outcome"], own["confirmation"]),
                         ("unconfirmed", "killed", unconfirmed["confirmation"]))
        self.assertNotIn("ended", own)
        native.combine(killed, dict(survived), "aarch64")
        self.assertEqual((killed["outcome"], killed["verdicts"]["native"]["outcome"]), ("killed", "survived"))
        self.assertNotIn("ended", killed["verdicts"]["wasm-gc"])


class ConfirmationTest(unittest.TestCase):
    """Runs of one or two of calc's mutants each, with a moon that answers
    from a script, so that a flaky failure, a time-out that does not repeat
    and a slow runner happen every time; and a run that reads flake
    records."""

    @classmethod
    def setUpClass(cls):
        moon = shutil.which("moon")
        if moon is None:
            raise unittest.SkipTest("moon is not on PATH")
        cls.real = moon
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-confirm-"))
        cls.fake = cls.tmp / "scripted_moon.py"
        cls.fake.write_text(SCRIPTED_MOON)
        cls.runs = 0
        with open(HERE.parent.parent / "mutation" / "flakes.toml", "rb") as f:
            cls.policy = tomllib.load(f)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_scripted(self, answers, *args, package="calc"):
        """Runs the runner on a package, calc unless given, with the moon
        that answers from the script: its result, records, package summary
        and whole summary."""
        type(self).runs += 1
        name = f"run-{self.runs}"
        script = self.tmp / f"{name}.json"
        script.write_text(json.dumps(answers))
        moon = f"{sys.executable} {self.fake} {script} {self.tmp / f'{name}.log'} {self.real}"
        out = self.tmp / name
        result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(self.tmp / "work"), "--out", str(out),
             "--moon", moon, *args, package],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (out / "mutants.jsonl").read_text().splitlines()]
        summary = json.loads((out / "summary.json").read_text())
        return out, records, summary["packages"][0], summary

    # The runs of tests, in turn, for one mutant: the two runs without a
    # mutant, the self-test's run (#309, which the real moon answers), the
    # mutant's run, its run again with the mutant on, and the run without
    # it.

    def test_a_kill_that_does_not_repeat_is_not_counted(self):
        # `n < high` survives calc's tests; a flaky failure says otherwise once.
        out, records, package, _ = self.run_scripted(["real", "real", "real", {"fail": [LOW]}],
                                                     "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("unconfirmed", "killed", "the tests that failed passed when run again with the mutant on"))
        self.assertEqual([t["name"] for t in record["failed_first"]], [LOW[3]])
        self.assertEqual(record["killing_tests"], [])
        self.assertEqual((package["killed"], package["unconfirmed"], package["survived"]), (0, 1, 0))
        # The test failed once of the one time it ran again with the mutant
        # on, and passed the two runs without a mutant.
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["suites"], {"mutation/fixture/calc": 2})
        self.assertEqual(flaked["tests"], [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "flaked": 1,
                                            "reruns": 1}])
        report = (out / "report.md").read_text()
        self.assertIn("### Unconfirmed (1)", report)
        self.assertIn("the tests that failed passed when run again with the mutant on", report)

    # #431 and the maintainer's twentieth round (2026-11-21), point 3: a run
    # again that the time limit stops, or that fails without naming a test,
    # repeats the kill; no test is flaky by it. Only a run again that
    # finishes with the tests that failed now passing makes the kill
    # unconfirmed. The record keeps how each run ended ("ended").

    def test_a_kill_whose_run_again_the_time_limit_stops_is_confirmed(self):
        # The second weekly run's `template/encoding.mbt,lossy_utf8_length,
        # DEL,length += 1L,,0`: killed by two tests, then its run again was
        # stopped by the time limit, naming no test. `low < n` is killed by
        # LOW; its run again sleeps past the limit.
        out, records, package, summary = self.run_scripted(["real", "real", "real", "real", {"sleep": 120}],
                                                           "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual([t["name"] for t in record["killing_tests"]], [LOW[3]])
        self.assertGreaterEqual(record["timings"]["again_s"], record["timings"]["limit_s"])
        self.assertLess(record["timings"]["without_s"], record["timings"]["limit_s"])
        # moon exits with 2 when tests fail; the runner stops a run at its
        # limit with SIGKILL, which Python gives as the exit status -9.
        self.assertEqual(record["ended"], {"run": {"exit_status": 2, "timed_out": False, "failed_tests": 1},
                                           "again": {"exit_status": -9, "timed_out": True, "failed_tests": 0},
                                           "without": {"exit_status": 0, "timed_out": False, "failed_tests": 0}})
        self.assertEqual((package["killed"], package["unconfirmed"]), (1, 0))
        # No test had a flaky result: the run again did not pass.
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked, {"suites": {"mutation/fixture/calc": 3}, "tests": []})
        self.assertEqual(summary["flakes"]["flaked"], [])
        # The report lists the kills whose run again ended otherwise than
        # their run, which it listed as unconfirmed before.
        report = (out / "report.md").read_text()
        self.assertIn("### Confirmed by a run again that ended otherwise (1)\n\n"
                      "A run that the time limit stopped, or that failed without naming a test, did not pass: it"
                      " repeats a kill, and names no test.\n\n"
                      "- `calc/calc.mbt,in_range,ROR,<=,<,0` (killed): its run failed naming 1 test; its run again"
                      f" was stopped at the time limit after {record['timings']['again_s']:.2f} s.\n", report)
        self.assertNotIn("### Unconfirmed", report)

    def test_a_kill_whose_run_again_fails_without_naming_a_test_is_confirmed(self):
        # The second weekly run's `engine/store.mbt,SessionStore::remove_where,
        # AOR,+=,-=,4`: killed by two tests in 1.381 s, then its run again
        # ended after 0.64 s naming no test. Here the test program of the
        # run again stops with an exit status of 1, as an abort outside a
        # test does on wasm-gc.
        out, records, package, summary = self.run_scripted(
            ["real", "real", "real", "real", {"crash": "exit status: 1"}],
            "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual([t["name"] for t in record["killing_tests"]], [LOW[3]])
        self.assertEqual(record["ended"]["again"], {"exit_status": 255, "timed_out": False, "failed_tests": 0})
        self.assertEqual((package["killed"], package["unconfirmed"]), (1, 0))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked, {"suites": {"mutation/fixture/calc": 3}, "tests": []})
        self.assertEqual(summary["flakes"]["flaked"], [])
        report = (out / "report.md").read_text()
        self.assertIn("- `calc/calc.mbt,in_range,ROR,<=,<,0` (killed): its run failed naming 1 test; its run again"
                      " failed without naming a test, with exit status 255.\n", report)

    def test_a_native_kill_whose_run_again_stops_on_a_signal_is_confirmed(self):
        # The first weekly run's `protobuf/encode.mbt,Writer::utf8,AOR,+=,-=,5`
        # at a site that uses an unchecked array access: natively, 26 tests
        # failed, and its run again named none (in the second weekly run,
        # its native runs stopped on SIGSEGV both times). bounds' BODY
        # mutant runs natively too (test_native.py); natively, it is killed
        # by its test of "a.b", then its run again stops on SIGSEGV. The
        # runs of tests: on wasm-gc, the two without a mutant, the
        # self-test's, the mutant's and its two confirming runs; natively,
        # the two without a mutant, the mutant's, then its run again.
        dot = ("mutation/fixture/bounds", "bounds_test.mbt", "a dot after the first characters")
        _, records, _, summary = self.run_scripted(
            ["real"] * 9 + [{"crash": "signal: 11 (SIGSEGV) (core dumped)"}],
            "--mutant", "bounds/bounds.mbt,dot_after,BODY,{…},{ false },0", package="bounds")
        [record] = records
        native = record["verdicts"]["native"]
        self.assertEqual((native["outcome"], native["confirmation"]), ("killed", "confirmed"))
        self.assertEqual([(t["package"], t["file"], t["name"]) for t in native["killing_tests"]], [dot])
        self.assertEqual(native["ended"]["again"], {"exit_status": 255, "timed_out": False, "failed_tests": 0})
        self.assertEqual(summary["flakes"]["flaked"], [])

    def test_a_survivor_whose_importers_run_fails_without_naming_a_test_once_is_a_survivor(self):
        # The second weekly run's `definitions/response.mbt,File::read_response,
        # BOOL,false,true,6`: it survived definitions' own tests; in its
        # importers' run, engine's test program stopped on SIGSEGV, naming no
        # test; run again, their tests passed. It is a survivor, unexplained
        # until a test kills it or an entry covers it, not unconfirmed. units'
        # `n >= high` survives every test that gives credit (UNITS). The
        # runs of tests: units' two without a mutant, the self-test's and
        # the mutant's; its importers' two without a mutant, the mutant's
        # (which stops), then its run again.
        mutant = "units/units.mbt,past,ROR,>,>=,0"
        out, records, package, summary = self.run_scripted(
            ["real"] * 6 + [{"crash": "signal: 11 (SIGSEGV) (core dumped)"}], "--mutant", mutant, package="units")
        [record] = records
        self.assertEqual((record["outcome"], record["killing_tests"], record["importers"]),
                         ("survived", [], ["mutation/fixture/dial", "mutation/fixture/meter"]))
        self.assertEqual(record["exclusion"], {"status": "unexplained"})
        self.assertEqual((record["first_outcome"], record["confirmation"]),
                         ("killed", "the run failed without naming a test, and passed when run again with the"
                                    " mutant on"))
        self.assertIn("The test executable exited with signal: 11 (SIGSEGV)", record["message"])
        self.assertEqual(record["ended"], {
            "run": {"exit_status": 0, "timed_out": False, "failed_tests": 0},
            "importers": {"run": {"exit_status": 255, "timed_out": False, "failed_tests": 0},
                          "again": {"exit_status": 0, "timed_out": False, "failed_tests": 0}}})
        self.assertIn("diff", record)
        self.assertEqual({k: package[k] for k in ("killed", "survived", "unconfirmed")},
                         {"killed": 0, "survived": 1, "unconfirmed": 0})
        self.assertEqual(package["exclusions"]["unexplained"], 1)
        self.assertEqual((package["importers"]["reran"], package["importers"]["killed"]), (1, 0))
        # No test is named, so none had a flaky result.
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["tests"], [])
        self.assertEqual(summary["flakes"]["flaked"], [])
        # The report lists it among the survivors, and says what happened.
        report = (out / "report.md").read_text()
        self.assertIn(f"### Survivors (1)\n\n#### `{mutant}`\n\nUnexplained.\n\nNot a kill: with its importers'"
                      " tests, the run failed without naming a test, and passed when run again with the mutant on.\n",
                      report)
        self.assertNotIn("### Unconfirmed", report)

    def test_a_survivor_whose_importers_tests_fail_once_by_name_is_unconfirmed(self):
        # Named tests that fail and then pass when run again are flaky
        # results, wherever they run: the kill is unconfirmed, as a kill by
        # a package's own tests is (twentieth round, point 3: only such a
        # run again makes a kill unconfirmed). meter's test fails once.
        meter = ("mutation/fixture/meter", "meter_test.mbt", 0, "a reading at the low end of the scale is on it")
        out, records, package, _ = self.run_scripted(
            ["real"] * 6 + [{"fail": [meter]}], "--mutant", "units/units.mbt,past,ROR,>,>=,0", package="units")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("unconfirmed", "killed", "the tests that failed passed when run again with the mutant on"))
        self.assertEqual([t["name"] for t in record["failed_first"]], [meter[3]])
        self.assertEqual((package["survived"], package["unconfirmed"]), (0, 1))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["tests"], [{"package": meter[0], "file": meter[1], "name": meter[3], "flaked": 1,
                                            "reruns": 1}])

    def test_a_kill_that_named_no_test_and_passes_when_run_again_is_a_survivor(self):
        # The own tests' counterpart of read_response's case: units' test
        # program stops once, naming no test, and passes when run again. It
        # is a survivor of units' own tests, so its importers' tests run it
        # again, and it survives those too.
        out, records, package, _ = self.run_scripted(
            ["real"] * 3 + [{"crash": "exit status: 1"}], "--mutant", "units/units.mbt,past,ROR,>,>=,0",
            package="units")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("survived", "killed", "the run failed without naming a test, and passed when run again"
                                                " with the mutant on"))
        self.assertEqual(record["importers"], ["mutation/fixture/dial", "mutation/fixture/meter"])
        self.assertEqual(record["ended"]["again"], {"exit_status": 0, "timed_out": False, "failed_tests": 0})
        self.assertEqual(record["ended"]["importers"], {"run": {"exit_status": 0, "timed_out": False,
                                                                "failed_tests": 0}})
        self.assertEqual((package["own"]["survived"], package["survived"], package["unconfirmed"]), (1, 1, 0))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["tests"], [])
        self.assertIn("Unexplained.\n\nNot a kill: the run failed without naming a test, and passed when run again"
                      " with the mutant on.\n", (out / "report.md").read_text())

    def test_a_kill_that_named_no_test_is_decided_by_its_run_again(self):
        # Its run again stopped by the limit repeats the kill, with no test;
        # one that fails names the tests that kill it.
        mutant = ("--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        _, records, _, _ = self.run_scripted(["real", "real", "real", {"crash": "exit status: 1"}, {"sleep": 120}],
                                             *mutant)
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"], record["killing_tests"]),
                         ("killed", "confirmed", []))
        self.assertTrue(record["ended"]["again"]["timed_out"])
        out, records, _, _ = self.run_scripted(["real", "real", "real", {"crash": "exit status: 1"},
                                                {"fail": [LOW]}], *mutant)
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual([t["name"] for t in record["killing_tests"]], [LOW[3]])
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["tests"], [])

    def test_a_kill_whose_tests_fail_without_the_mutant_is_not_counted(self):
        # `low < n` is killed by LOW, which then fails without it too.
        out, records, package, _ = self.run_scripted(["real", "real", "real", "real", "real", {"fail": [LOW]}],
                                                     "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]),
                         ("unconfirmed", "the tests that failed fail without the mutant too"))
        self.assertEqual((package["killed"], package["unconfirmed"]), (0, 1))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["suites"], {"mutation/fixture/calc": 3})
        self.assertEqual(flaked["tests"], [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "flaked": 1,
                                            "reruns": 1}])

    # A time-out that does not repeat, decided by the twentieth round's
    # principle (#431): the run the limit stopped named no test, so its run
    # again decides. A run again that passes makes the mutant a survivor; one
    # that fails repeats the kill, as killed, since only both runs stopped by
    # the limit make a time-out.

    def test_a_time_out_whose_run_again_passes_is_a_survivor(self):
        # `n < high` survives calc's tests; a slow runner stops it once.
        out, records, package, _ = self.run_scripted(["real", "real", "real", {"sleep": 120}],
                                                     "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("survived", "timed out", "the run was stopped at the time limit, and passed when run"
                                                   " again with the mutant on"))
        self.assertGreaterEqual(record["timings"]["run_s"], record["timings"]["limit_s"])
        self.assertLess(record["timings"]["again_s"], record["timings"]["limit_s"])
        self.assertEqual(record["ended"]["again"], {"exit_status": 0, "timed_out": False, "failed_tests": 0})
        self.assertEqual(record["exclusion"], {"status": "unexplained"})
        self.assertEqual((package["timed_out"], package["survived"], package["unconfirmed"], package["score"]),
                         (0, 1, 0, 0.0))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked["tests"], [])
        report = (out / "report.md").read_text()
        self.assertIn("### Survivors (1)", report)
        self.assertIn("Not a kill: the run was stopped at the time limit, and passed when run again with the mutant"
                      " on.\n", report)
        self.assertNotIn("### Unconfirmed", report)

    def test_a_time_out_whose_run_again_fails_named_tests_is_killed_by_them(self):
        # The first weekly run's `yaml/writer.mbt,Writer::hex,AOR,-,+,1` timed
        # out (5.586 s against 5.576 s), and its run again ended within the
        # limit; the second weekly run killed it in 3.935 s.
        out, records, package, _ = self.run_scripted(["real", "real", "real", {"sleep": 120}, {"fail": [LOW]}],
                                                     "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]), ("killed", "confirmed"))
        self.assertEqual([t["name"] for t in record["killing_tests"]], [LOW[3]])
        self.assertEqual((record["ended"]["run"]["timed_out"], record["ended"]["again"]),
                         (True, {"exit_status": 2, "timed_out": False, "failed_tests": 1}))
        self.assertEqual((package["killed"], package["timed_out"], package["unconfirmed"]), (1, 0, 0))
        # LOW failed once, with the mutant on: no flaky result.
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked, {"suites": {"mutation/fixture/calc": 3}, "tests": []})

    def test_a_time_out_whose_run_again_fails_without_naming_a_test_is_killed(self):
        _, records, package, _ = self.run_scripted(
            ["real", "real", "real", {"sleep": 120}, {"crash": "exit status: 1"}],
            "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"], record["killing_tests"]),
                         ("killed", "confirmed", []))
        self.assertEqual(record["ended"]["again"], {"exit_status": 255, "timed_out": False, "failed_tests": 0})
        self.assertEqual((package["killed"], package["timed_out"], package["unconfirmed"]), (1, 0, 0))

    def test_a_kill_or_a_time_out_whose_run_without_the_mutant_fails_without_naming_a_test_is_unconfirmed(self):
        # The run without the mutant must show that the tests that killed it
        # pass without it, or that the tests finish within the limit. One
        # that fails without naming a test shows neither, as one that the
        # limit stops does not (#431's principle): no run of every test is
        # counted by it.
        reason = "the run without the mutant failed without naming a test"
        out, records, package, _ = self.run_scripted(
            ["real", "real", "real", "real", "real", {"crash": "signal: 11 (SIGSEGV) (core dumped)"}],
            "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("unconfirmed", "killed", reason))
        self.assertEqual([t["name"] for t in record["failed_first"]], [LOW[3]])
        self.assertEqual(record["ended"]["without"], {"exit_status": 255, "timed_out": False, "failed_tests": 0})
        self.assertEqual((package["killed"], package["unconfirmed"]), (0, 1))
        flaked = json.loads((out / "flakes.json").read_text())["runs"][-1]
        self.assertEqual(flaked, {"suites": {"mutation/fixture/calc": 2},
                                  "tests": [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "flaked": 0,
                                             "reruns": 1}]})
        # A time-out, the same way.
        _, records, package, _ = self.run_scripted(
            ["real", "real", "real", {"sleep": 120}, {"sleep": 120}, {"crash": "exit status: 1"}],
            "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["first_outcome"], record["confirmation"]),
                         ("unconfirmed", "timed out", reason))
        self.assertEqual((package["timed_out"], package["unconfirmed"]), (0, 1))

    def test_a_time_out_whose_run_without_the_mutant_is_too_slow_is_unconfirmed(self):
        # A slow runner: everything times out, the run without the mutant too.
        _, records, package, _ = self.run_scripted(["real", "real", "real", {"sleep": 120}, {"sleep": 120}, {"sleep": 120}],
                                                   "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,1")
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]),
                         ("unconfirmed", "the run without the mutant did not finish within the limit"))
        self.assertGreaterEqual(record["timings"]["again_s"], record["timings"]["limit_s"])
        self.assertGreaterEqual(record["timings"]["without_s"], record["timings"]["limit_s"])
        self.assertEqual((package["timed_out"], package["unconfirmed"]), (0, 1))

    def test_a_test_that_fails_without_a_mutant_gives_no_credit_in_that_run(self):
        # LOW fails in the second run without a mutant, and then is the only
        # test that kills `low < n`.
        out, records, package, summary = self.run_scripted(["real", {"fail": [LOW]}],
                                                           "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        self.assertEqual(package["baseline"]["failed"],
                         [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "runs": [2]}])
        [record] = records
        self.assertEqual((record["outcome"], record["confirmation"]),
                         ("survived", "only tests that give no kill credit failed"))
        self.assertEqual([t["name"] for t in record["no_credit"]], [LOW[3]])
        self.assertEqual(summary["flakes"]["flaked"], [{"package": LOW[0], "file": LOW[1], "name": LOW[3],
                                                        "flaked": 1, "observed": 2, "rate": 0.5}])
        report = (out / "report.md").read_text()
        self.assertIn(f"Tests that failed without a mutant, which give no kill credit in this run: `{LOW[3]}`"
                      f" ({LOW[0]}, {LOW[1]}, run 2).", report)

    def test_a_test_above_the_flake_threshold_gives_no_credit(self):
        # Records of an earlier run in which LOW flaked in every run, and
        # BELOW in exactly the threshold's share of its runs.
        runs = 1_000_000
        at = round(self.policy["threshold"] * runs)
        self.assertEqual(at / runs, self.policy["threshold"])
        records_file = self.tmp / "earlier-flakes.json"
        records_file.write_text(json.dumps({"version": 1, "runs": [{
            "suites": {"mutation/fixture/calc": runs},
            "tests": [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "flaked": runs, "reruns": 0},
                      {"package": BELOW[0], "file": BELOW[1], "name": BELOW[3], "flaked": at, "reruns": 0}]}]}))
        out, records, package, summary = self.run_scripted(
            [], "--flakes", str(records_file),
            "--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0", "--mutant", "calc/calc.mbt,in_range,LCR,&&,||,0")
        outcomes = {r["id"]: (r["outcome"], [t["name"] for t in r["killing_tests"]]) for r in records}
        self.assertEqual(outcomes, {"calc/calc.mbt,in_range,ROR,<=,<,0": ("survived", []),
                                    "calc/calc.mbt,in_range,LCR,&&,||,0": ("killed", [BELOW[3]])})
        self.assertEqual([t["name"] for t in summary["flakes"]["above"]], [LOW[3]])
        self.assertEqual(summary["flakes"]["runs_read"], 1)
        report = (out / "report.md").read_text()
        self.assertIn("Above the threshold, so they give no kill credit in this run: 1.", report)
        self.assertIn(f"- `{LOW[3]}` ({LOW[0]}, {LOW[1]}): {runs} of {runs} runs, 100.00%", report)
        # The records kept for the next run: the earlier run, then this one.
        kept = json.loads((out / "flakes.json").read_text())
        self.assertEqual(len(kept["runs"]), 2)
        # The two runs without a mutant, and the run without `||` that
        # confirms its kill; `low < n`'s only failed test gives no credit,
        # so it is not run again.
        self.assertEqual(kept["runs"][-1]["suites"], {"mutation/fixture/calc": 3})
        self.assertEqual((kept["threshold"], kept["recent_runs"]),
                         (self.policy["threshold"], self.policy["recent_runs"]))

    def test_a_flaky_test_gives_credit_again_once_its_flaky_runs_are_not_among_the_latest(self):
        # As many earlier runs as the policy counts: in the oldest, LOW
        # flaked in every one of its many runs; in the others, never.
        flaky = {"suites": {"mutation/fixture/calc": 1_000_000},
                 "tests": [{"package": LOW[0], "file": LOW[1], "name": LOW[3], "flaked": 1_000_000, "reruns": 0}]}
        clean = {"suites": {"mutation/fixture/calc": 2}, "tests": []}
        recent = self.policy["recent_runs"]
        records_file = self.tmp / "older-flakes.json"
        records_file.write_text(json.dumps({"version": 1, "runs": [flaky] + [clean] * (recent - 1)}))
        mutant = ("--mutant", "calc/calc.mbt,in_range,ROR,<=,<,0")
        out, records, _, summary = self.run_scripted([], "--flakes", str(records_file), *mutant)
        self.assertEqual(summary["flakes"]["runs_read"], recent)
        self.assertEqual([t["name"] for t in summary["flakes"]["above"]], [LOW[3]])
        self.assertEqual([r["outcome"] for r in records], ["survived"])
        # The records this run keeps leave the oldest run out, so the next
        # run, which reads them, takes LOW's kill.
        kept = json.loads((out / "flakes.json").read_text())
        self.assertEqual(len(kept["runs"]), recent)
        self.assertNotIn(flaky, kept["runs"])
        self.assertEqual(kept["rates"], [])
        _, records, _, summary = self.run_scripted([], "--flakes", str(out / "flakes.json"), *mutant)
        self.assertEqual(summary["flakes"]["above"], [])
        self.assertEqual([(r["outcome"], r["confirmation"]) for r in records], [("killed", "confirmed")])
        # Records that hold one run more than the policy counts: the oldest
        # is not read.
        records_file.write_text(json.dumps({"version": 1, "runs": [flaky] + [clean] * recent}))
        _, records, _, summary = self.run_scripted([], "--flakes", str(records_file), *mutant)
        self.assertEqual((summary["flakes"]["runs_read"], summary["flakes"]["above"]), (recent, []))
        self.assertEqual([r["outcome"] for r in records], ["killed"])


class OutputNamesTest(unittest.TestCase):
    """The compiler numbers its locals, labels and closures in the order it
    makes them, and a closure's name holds the line of its definition: the
    comparison replaces every name of the output, and keeps its text."""

    # A closure at line 30, in moonc's WAT, and a SourceLoc that the program
    # holds as text.
    OUTPUT = """(func $_M0FP38mutation7fixture4same5totalC12l30 (param $_M0L1yS3 i32) (result i32)
 (loop $loop:4 (result i32)
  (i32.add (local.get $_M0L1yS3) (call $_M0FP38mutation7fixture4same4next (i32.const 1)))))
(data $moonbit.const_data "s\\00a\\00m\\00e\\00:\\003\\000\\00")"""

    def test_names_that_differ_alone_compare_alike(self):
        import compare
        moved = (self.OUTPUT.replace("C12l30", "C14l31").replace("S3", "S5").replace("$loop:4", "$loop:9"))
        self.assertNotEqual(moved, self.OUTPUT)
        self.assertEqual(compare.digest(moved), compare.digest(self.OUTPUT))

    def test_text_and_the_names_pattern_of_use_still_differ(self):
        import compare
        # The program's own text, here the line of a SourceLoc.
        self.assertNotEqual(compare.digest(self.OUTPUT.replace("\\003\\000", "\\003\\001")),
                            compare.digest(self.OUTPUT))
        # Two functions that were one.
        call = "$_M0FP38mutation7fixture4same4next"
        self.assertNotEqual(compare.digest(self.OUTPUT.replace(call, "$_M0FP38mutation7fixture4same5totalC12l30")),
                            compare.digest(self.OUTPUT))


class CompilerOutputTest(unittest.TestCase):
    """One run of same's pinned set, whose mutants the compiler's output
    judges before any test runs (#303)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-mutation-same-"))
        cls.moon, cls.log = logging_moon(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.out = cls.tmp / "same"
        cls.result = subprocess.run(
            [sys.executable, str(RUN), "--root", str(FIXTURE), "--work", str(cls.work), "--out", str(cls.out),
             "--moon", str(cls.moon), "same"],
            capture_output=True, text=True)
        if cls.result.returncode != 0:
            raise AssertionError(f"run.py failed ({cls.result.returncode}):\n{cls.result.stderr}")
        cls.records = [json.loads(line) for line in (cls.out / "mutants.jsonl").read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_mutant_has_its_known_outcome(self):
        self.assertEqual([(r["id"], r["outcome"], r.get("compiler_output", {}).get("result")) for r in self.records],
                         SAME)

    def test_an_equivalent_mutant_or_a_duplicate_runs_no_tests(self):
        runs = [line for line in self.log.read_text().splitlines() if "--test-failure-json" in line.split()]
        # The run without a mutant, twice, the self-test once (#309), and
        # each mutant that compiled and was neither equivalent nor a
        # duplicate, three times: each of them is killed, and a kill is
        # confirmed by a run with the mutant on and one without it (#301).
        ran = [outcome for _, outcome, _ in SAME if outcome not in ("unviable", "equivalent", "duplicate")]
        self.assertEqual(set(ran), {"killed"})
        self.assertEqual(len(runs), 2 + 1 + 3 * len(ran))
        for record in self.records:
            if record["outcome"] in ("equivalent", "duplicate"):
                self.assertEqual((record["killing_tests"], record["timings"]["run_s"]), ([], 0), record["id"])
                self.assertGreater(record["timings"]["compare_s"], 0)

    def test_a_duplicate_names_the_first_mutant_that_compiled_alike(self):
        duplicate = next(r for r in self.records if r["outcome"] == "duplicate")
        self.assertEqual(duplicate["duplicate_of"], "same/same.mbt,count_a_if,BODY,{…},{ 0 },0")
        # Both compiled alike, and unlike the package without a mutant.
        first = next(r for r in self.records if r["id"] == duplicate["duplicate_of"])
        self.assertEqual(duplicate["compiler_output"]["digest"], first["compiler_output"]["digest"])
        equivalent = next(r for r in self.records if r["outcome"] == "equivalent")
        self.assertNotEqual(first["compiler_output"]["digest"], equivalent["compiler_output"]["digest"])

    def test_a_mutant_the_output_does_not_hold_is_not_compared(self):
        reasons = {r["id"]: r["compiler_output"]["reason"] for r in self.records
                   if r.get("compiler_output", {}).get("result") == "not compared"}
        self.assertEqual(reasons, {
            "same/same.mbt,TRACING,BOOL,false,true,0":
                "the output has no function of its own for TRACING",
            "same/same.mbt,count_a,BODY,{…},{ 0 },0":
                "the mutant's output has no function of its own for count_a",
            "same/same.mbt,impl Eq for Tally with equal,BODY,{…},{ false },0":
                "the output has no function of its own for impl Eq for Tally with equal",
        })

    def test_the_summary_counts_them_apart(self):
        package = json.loads((self.out / "summary.json").read_text())["packages"][0]
        self.assertEqual(
            {k: package[k] for k in ("mutants", "killed", "timed_out", "survived", "unviable", "equivalent",
                                     "duplicate", "not_compared")},
            {"mutants": 20, "killed": 15, "timed_out": 0, "survived": 0, "unviable": 2, "equivalent": 2,
             "duplicate": 1, "not_compared": 3})
        # Neither counts as killed nor as survived.
        self.assertEqual(package["score"], 1.0)

    def test_the_report_counts_and_lists_them(self):
        report = (self.out / "report.md").read_text()
        self.assertIn("By the compiler's output: 2 equivalent and 1 duplicate, which ran no tests;"
                      " 15 mutants compared, 3 not compared.", report)
        self.assertIn("### Equivalent by the compiler's output (2)\n\n"
                      "- `same/same.mbt,total,IFC,TRACING,false,0`\n"
                      "- `same/same.mbt,total,DEL,trace.push(…),,0`\n", report)
        self.assertIn("### Duplicates by the compiler's output (1)\n\n"
                      "- `same/same.mbt,count_a_if,IFC,wanted,false,0`, as"
                      " `same/same.mbt,count_a_if,BODY,{…},{ 0 },0` (killed)\n", report)


if __name__ == "__main__":
    unittest.main()
