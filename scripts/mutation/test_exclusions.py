"""Tests of the exclusion list (scripts/mutation/exclusions.py), through
its command line, on small trees in temporary directories: copies of the
coverage report's small source tree (scripts/coverage-tests/tree) and of
the fixture package calc.

The rules come from the ticket of the list (#302), the spec's
"Exclusions" (#275) and ADR 0006, which CONTRIBUTING.md, "Exclusions",
states: an entry names a mutant by its id, or a point by its file,
definition and position in it, and gives a category, a reason and the
reviewer. The categories are EQUIVALENT, ARID, UNREACHABLE, FAULT,
UB-NATIVE and DEFERRED; an entry in another category, or without what its
category needs, fails the check: an EQUIVALENT entry records the
comparison of the compiler's output and the adversarial attempt (the
agent context that made it and the tests it tried, which passed), and
fails while that attempt is still pending, unless a ticket branch asks
the check to accept it before the separate context has run;
UNREACHABLE holds an arm that an invariant guards with an abort, or
carries a written argument; DEFERRED carries an issue number. An entry
goes stale when the text of its definition changes.

They need python3, git and moonc (the toolchain of .moonbit-version):
staleness reads the definitions with the site finder's parser.

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
EXCLUSIONS = HERE / "exclusions.py"
TREE = REPO / "scripts" / "coverage-tests" / "tree"
CALC = HERE / "fixture" / "calc" / "calc.mbt"

# The uncovered point of the small tree's report partly.bisect: the then
# arm's abort of Generator::below, at line 16, column 19, of prng.mbt.
ABORT = "prng/prng.mbt:16:19"
# A mutant of calc that survives its tests: NOT, `!spaces` to `spaces`.
NOT = "calc/calc.mbt,is_blank,NOT,!,,0"


def need_moonc():
    if shutil.which("moonc") is None:
        raise unittest.SkipTest("moonc is not on PATH")


class Tree:
    """A small tree: the coverage report's source tree, and calc's source,
    with an exclusion list at its root."""

    def __init__(self, tmp):
        self.root = tmp / "tree"
        shutil.copytree(TREE, self.root)
        (self.root / "calc").mkdir()
        shutil.copy(CALC, self.root / "calc" / "calc.mbt")

    def run(self, *args):
        return subprocess.run([sys.executable, str(EXCLUSIONS), "--root", str(self.root), *args],
                              capture_output=True, text=True)

    def new(self, what):
        """The stanza that `new` prints for a point or a mutant."""
        result = self.run("new", what)
        if result.returncode != 0:
            raise AssertionError(f"new {what} failed ({result.returncode}):\n{result.stderr}")
        return result.stdout

    def write(self, *stanzas):
        """Writes the exclusion list, of the stanzas given."""
        (self.root / "exclusions.toml").write_text("# A test's list.\n\n" + "\n".join(stanzas))

    def edit(self, path, old, new):
        """Replaces the one occurrence of old in a file of the tree."""
        file = self.root / path
        text = file.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"{path} does not hold {old!r} once")
        file.write_text(text.replace(old, new))


def filled(stanza, **fields):
    """A stanza that `new` printed, with fields set: each `<name> = ""`
    that it holds takes the value given, as TOML, and any other is added."""
    lines = stanza.rstrip("\n").split("\n")
    for name, value in fields.items():
        line = f"{name} = {value}"
        at = next((i for i, l in enumerate(lines) if l.startswith(f"{name} = ")), None)
        if at is None:
            lines.append(line)
        else:
            lines[at] = line
    return "\n".join(lines) + "\n"


class NewTest(unittest.TestCase):
    """`new` prints the stanza of a new entry, with the definition's text
    as it is now, for the author to fill in."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_point_is_named_by_its_file_definition_and_position_in_it(self):
        stanza = self.tree.new(ABORT)
        # Generator::below starts at line 15, so line 16 is its second.
        self.assertIn('file = "prng/prng.mbt"\n', stanza)
        self.assertIn('definition = "Generator::below"\n', stanza)
        self.assertIn('position = "2:19"\n', stanza)
        self.assertRegex(stanza, r'\ntext = "[0-9a-f]{16}"\n')
        for field in ("category", "reason", "reviewer"):
            self.assertIn(f'\n{field} = ""\n', stanza)

    def test_a_mutant_is_named_by_its_id(self):
        stanza = self.tree.new(NOT)
        self.assertIn('mutant = "calc/calc.mbt,is_blank,NOT,!,,0"\n', stanza)
        self.assertRegex(stanza, r'\ntext = "[0-9a-f]{16}"\n')

    def test_a_place_without_a_definition_fails(self):
        result = self.tree.run("new", "prng/prng.mbt:7:1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("prng/prng.mbt:7:1 lies in no top-level definition", result.stderr)


class CategoriesTest(unittest.TestCase):
    """The check passes an entry of each category with what it needs, and
    fails one without it, saying what is missing."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)
        self.point = self.tree.new(ABORT)
        self.mutant = self.tree.new(NOT)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def check(self, *stanzas):
        self.tree.write(*stanzas)
        return self.tree.run("check")

    def passes(self, *stanzas):
        result = self.check(*stanzas)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def fails(self, message, *stanzas):
        result = self.check(*stanzas)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)

    def test_an_entry_of_each_category_with_what_it_needs_passes(self):
        result = self.passes(
            filled(self.point, category='"UNREACHABLE"', reason='"The count is never 0 here."'),
            filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                   compiler_output='"differs"',
                   adversarial='{ context = "an adversarial agent", tests = ["calc/calc_test.mbt: a try"] }'),
            filled(self.tree.new("calc/calc.mbt,is_blank,BOOL,true,false,0"), category='"ARID"',
                   reason='"A default that no test reads."'),
            filled(self.tree.new("calc/calc.mbt,is_blank,INT,0,1,0"), category='"FAULT"',
                   reason='"Needs a file-system failure."'),
            filled(self.tree.new("calc/calc.mbt,is_odd,INT,0,-1,0"), category='"UB-NATIVE"',
                   reason='"An unchecked access out of bounds."'),
            filled(self.tree.new("calc/calc.mbt,in_range,ROR,<=,<,1"), category='"DEFERRED"',
                   reason='"A test at the high end."', issue="123"),
            filled(self.tree.new("calc/calc.mbt,halve_until,INT,2,3,0"), category='"UNREACHABLE"',
                   reason='"Never divided."', argument='"halve_until is called with a limit of 0 only."'),
        )
        self.assertIn("exclusions: 7 entries, none stale", result.stdout)

    def test_another_category_fails(self):
        self.fails('exclusions.toml: calc/calc.mbt,is_blank,NOT,!,,0: the category should be one of EQUIVALENT,'
                   ' ARID, UNREACHABLE, FAULT, UB-NATIVE and DEFERRED, not "DEAD"',
                   filled(self.mutant, category='"DEAD"', reason='"Never called."'))

    def test_an_entry_without_a_reason_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it should give a reason",
                   filled(self.mutant, category='"ARID"'))

    def test_an_entry_without_its_reviewer_field_fails(self):
        stanza = filled(self.mutant, category='"ARID"', reason='"A default."').replace('reviewer = ""\n', "")
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it should have a reviewer, empty until the maintainer"
                   " fills it in", stanza)

    def test_an_equivalent_entry_without_its_record_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an EQUIVALENT entry should record the comparison of the"
                   ' compiler\'s output (compiler_output = "differs" or "not compared")',
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          adversarial='{ context = "an agent", tests = ["calc/calc_test.mbt: a try"] }'))
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an EQUIVALENT entry should record the adversarial attempt:"
                   " the agent context that made it and the tests it tried (adversarial = { context, tests })",
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"differs"'))
        self.fails("an EQUIVALENT entry should record the adversarial attempt",
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"differs"', adversarial='{ context = "an agent", tests = [] }'))

    def test_an_equivalent_entry_whose_attempt_is_still_pending_fails_unless_a_ticket_branch_allows_it(self):
        # The context that proposes an entry writes a context that starts
        # with "pending"; the separate context replaces it with what it
        # tried, and nothing pending reaches the integration branch, whose
        # CI runs the check without the option (#302, CONTRIBUTING.md,
        # "Exclusions").
        def equivalent(context):
            return filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"differs"',
                          adversarial=f'{{ context = "{context}", tests = ["none yet; the author\'s own check"] }}')

        for context in ("pending: a separate agent context, after the author", "Pending, after the author",
                        " pending: after the author"):
            self.fails("calc/calc.mbt,is_blank,NOT,!,,0: its adversarial attempt is still pending: the separate"
                       " context replaces it with what it tried before the branch is merged (check --allow-pending"
                       " passes it on a ticket branch until then)", equivalent(context))
        self.tree.write(equivalent("pending: a separate agent context, after the author"))
        result = self.tree.run("check", "--allow-pending")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exclusions: pending: calc/calc.mbt,is_blank,NOT,!,,0 (EQUIVALENT): its adversarial attempt"
                      " is still to be made", result.stdout)
        self.assertIn("exclusions: 1 entries, none stale, 1 pending", result.stdout)
        # A context that only names the word later made its attempt.
        self.passes(equivalent("an agent that is no longer pending"))
        # The option accepts a pending attempt, not one missing.
        self.tree.write(filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                               compiler_output='"differs"'))
        self.assertEqual(self.tree.run("check", "--allow-pending").returncode, 1)

    def test_an_equivalent_entry_whose_outputs_are_the_same_fails(self):
        # The comparison marks such a mutant equivalent itself.
        self.fails('compiler_output = "differs" or "not compared"',
                   filled(self.mutant, category='"EQUIVALENT"', reason='"Both read the same."',
                          compiler_output='"identical"',
                          adversarial='{ context = "an agent", tests = ["calc/calc_test.mbt: a try"] }'))

    def test_a_deferred_entry_without_its_issue_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: a DEFERRED entry should carry its issue's number (issue = <n>)",
                   filled(self.mutant, category='"DEFERRED"', reason='"Later."'))

    def test_an_unreachable_entry_that_is_no_abort_needs_its_argument(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: an UNREACHABLE entry should be an arm that an invariant"
                   " guards with an abort, or carry its written argument (argument = \"...\")",
                   filled(self.mutant, category='"UNREACHABLE"', reason='"Never false."'))
        # A point that is not an abort: next's first statement.
        self.fails("an UNREACHABLE entry should be an arm that an invariant guards with an abort",
                   filled(self.tree.new("prng/prng.mbt:10:3"), category='"UNREACHABLE"', reason='"Never."'))

    def test_a_point_cannot_be_equivalent_or_undefined_natively(self):
        for category in ("EQUIVALENT", "UB-NATIVE"):
            self.fails(f"prng/prng.mbt,Generator::below,2:19: a point cannot be {category}: only a mutant can",
                       filled(self.point, category=f'"{category}"', reason='"No."', compiler_output='"differs"',
                              adversarial='{ context = "an agent", tests = ["a"] }'))

    def test_an_unknown_field_fails(self):
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: it has a field the list does not know: reviewed_by",
                   filled(self.mutant, category='"ARID"', reason='"A default."', reviewed_by='"someone"'))

    def test_an_entry_that_names_neither_a_mutant_nor_a_point_fails(self):
        self.fails("exclusions.toml: entry 1 should name a mutant (mutant = <id>) or a point (file, definition"
                   " and position)", '[[exclusion]]\ncategory = "ARID"\nreason = "Why."\nreviewer = ""\n')

    def test_two_entries_for_one_mutant_fail(self):
        stanza = filled(self.mutant, category='"ARID"', reason='"A default."')
        self.fails("calc/calc.mbt,is_blank,NOT,!,,0: a second entry for it", stanza, stanza)

    def test_a_list_that_is_not_toml_fails(self):
        self.fails("exclusions.toml: not TOML:", "[[exclusion]\n")

    def test_no_list_is_an_empty_list(self):
        result = self.tree.run("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exclusions: 0 entries, none stale", result.stdout)


class StaleTest(unittest.TestCase):
    """An entry goes stale when the text of its definition changes, or the
    definition is gone; the check lists it, and passes."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)
        self.tree.write(filled(self.tree.new(ABORT), category='"UNREACHABLE"', reason='"Never 0."'),
                        filled(self.tree.new(NOT), category='"ARID"', reason='"A default."'))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def stale(self):
        result = self.tree.run("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line.split(": ", 2)[2] for line in result.stdout.splitlines() if line.startswith("exclusions: stale: ")]

    def test_entries_whose_definitions_are_as_they_were_are_current(self):
        # Another definition of the file changes, and white space between
        # definitions: neither is the entries' definitions' text.
        self.tree.edit("prng/prng.mbt", "self.state = self.state + 1", "self.state = self.state + 2")
        self.tree.edit("calc/calc.mbt", "///|\n/// Whether `n` is odd.", "\n///|\n/// Whether `n` is odd.")
        self.assertEqual(self.stale(), [])

    def test_a_changed_definition_makes_its_entry_stale(self):
        self.tree.edit("prng/prng.mbt", 'abort("count is 0")', 'abort("the count is 0")')
        self.assertEqual(self.stale(), ["prng/prng.mbt,Generator::below,2:19 (UNREACHABLE): its definition's text"
                                        " changed, or it is gone"])

    def test_a_definition_that_is_gone_or_renamed_makes_its_entry_stale(self):
        self.tree.edit("calc/calc.mbt", "pub fn is_blank(", "pub fn is_empty(")
        (self.tree.root / "prng" / "prng.mbt").unlink()
        self.assertEqual(sorted(self.stale()), [
            "calc/calc.mbt,is_blank,NOT,!,,0 (ARID): its definition's text changed, or it is gone",
            "prng/prng.mbt,Generator::below,2:19 (UNREACHABLE): its definition's text changed, or it is gone",
        ])

    def test_the_check_counts_the_stale_entries(self):
        self.tree.edit("calc/calc.mbt", "if !spaces {", "if spaces == false {")
        result = self.tree.run("check")
        self.assertIn("exclusions: 2 entries, 1 stale", result.stdout)


REPORT = REPO / "scripts" / "coverage-report.py"
RATCHET = REPO / "scripts" / "coverage-ratchet.py"
BISECTS = REPO / "scripts" / "coverage-tests"


class CoverageTest(unittest.TestCase):
    """The coverage report and the coverage ratchet count the uncovered
    points that no current entry accepts, on the small tree's report
    partly.bisect, whose one uncovered point is the abort of
    Generator::below; a stale or a DEFERRED entry accepts nothing."""

    def setUp(self):
        need_moonc()
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.tree = Tree(self.tmp)
        self.entry = filled(self.tree.new(ABORT), category='"UNREACHABLE"', reason='"The count is never 0."')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def report(self, bisect="partly.bisect"):
        result = subprocess.run([sys.executable, str(REPORT), "--root", str(self.tree.root), str(BISECTS / bisect)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [" ".join(line.split()) for line in result.stdout.splitlines()]

    def ratchet(self, floor):
        root = self.tree.root
        (root / "coverage").mkdir(exist_ok=True)
        (root / "coverage" / "floors.txt").write_text(f"prng {floor}\n")
        git = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
               "-C", str(root)]
        if not (root / ".git").exists():
            subprocess.run([*git, "init", "-q", "-b", "main"], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "a change"], check=True)
        return subprocess.run([sys.executable, str(RATCHET), "--root", str(root), "check", "--base", "main",
                               str(BISECTS / "partly.bisect")], capture_output=True, text=True)

    def test_an_accepted_point_is_not_uncovered(self):
        self.tree.write(self.entry)
        lines = self.report()
        # The table's uncovered points leave it out; the points covered and
        # the lines stay as they are.
        self.assertIn("prng 3 of 4 75.0% 0 1 of 2", lines)
        self.assertNotIn("prng: 1 of 4 points uncovered", lines)
        self.assertIn("prng: 1 point accepted by the exclusion list", lines)
        self.assertIn("prng/prng.mbt:16:19 Generator::below UNREACHABLE", lines)
        self.assertIn("All packages: 3 of 4 points covered (75.0%), 0 uncovered, 1 accepted by the exclusion list;"
                      " lines 1 of 2", lines)

    def test_a_stale_entry_accepts_nothing(self):
        self.tree.write(self.entry)
        # A change after the report's last point, which keeps its points
        # where they are.
        self.tree.edit("prng/prng.mbt", "self.next() % count", "self.next() % (count)")
        lines = self.report()
        self.assertIn("prng: 1 of 4 points uncovered", lines)
        self.assertIn("prng 3 of 4 75.0% 1 1 of 2", lines)
        self.assertIn("Stale entries of the exclusion list, which accept nothing: prng/prng.mbt,Generator::below,2:19",
                      lines)

    def test_a_deferred_entry_accepts_nothing(self):
        self.tree.write(filled(self.tree.new(ABORT), category='"DEFERRED"', reason='"A test later."', issue="123"))
        lines = self.report()
        self.assertIn("prng: 1 of 4 points uncovered", lines)
        self.assertIn("prng/prng.mbt:16:19 Generator::below (DEFERRED to #123)", lines)

    def test_without_a_list_the_report_is_as_it_was(self):
        lines = self.report()
        self.assertIn("prng: 1 of 4 points uncovered", lines)
        self.assertIn("All packages: 3 of 4 points covered (75.0%), 1 uncovered; lines 1 of 2", lines)

    def test_the_ratchet_counts_the_points_after_the_list(self):
        self.tree.write(self.entry)
        result = self.ratchet(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prng: 0 uncovered points, at its floor of 0", result.stdout)
        # Once stale, the entry accepts nothing, and the point is above the
        # floor again.
        self.tree.edit("prng/prng.mbt", 'abort("count is 0")', 'abort("the count is 0")')
        result = self.ratchet(0)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("prng: 1 uncovered point, above its floor of 0", result.stderr)
        self.assertIn("stale entries of the exclusion list, which accept nothing:"
                      " prng/prng.mbt,Generator::below,2:19", result.stderr)


def stanza(mutant, reason="A reason.", reviewer=""):
    """An ARID entry of a mutant, with a made-up text: review reads no
    definition."""
    return (f'[[exclusion]]\nmutant = "{mutant}"\ntext = "0123456789abcdef"\ncategory = "ARID"\n'
            f'reason = "{reason}"\nreviewer = "{reviewer}"\n')


class ReviewTest(unittest.TestCase):
    """`review` lists the batch, the entries that a branch adds or changes
    against its merge base with main, and those the maintainer reads:
    every one in the protocol packages (http1, grpc, yaml, re2, xml and
    protobuf) and in serverparsers, and one in five of the others, drawn
    once the batch is frozen with a seed that no agent can know before:
    the run ID that GitHub Actions gives the packages run on the frozen
    tip (#302, #275, CONTRIBUTING.md, "Exclusions")."""

    OTHERS = ["engine/a.mbt,a,INT,1,2,0", "engine/b.mbt,b,INT,1,2,0", "engine/c.mbt,c,INT,1,2,0",
              "engine/d.mbt,d,INT,1,2,0", "engine/e.mbt,e,INT,1,2,0", "protobuf-conformance/f.mbt,f,INT,1,2,0"]
    PROTOCOL = ["yaml/y.mbt,y,INT,1,2,0", "protobuf/p.mbt,p,INT,1,2,0", "serverparsers/s.mbt,s,INT,1,2,0"]

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-exclusions-"))
        self.root = self.tmp / "repo"
        self.root.mkdir()
        self.git("init", "-q", "-b", "main")
        # At the base: an entry the branch changes, and one whose reviewer
        # alone it fills in, which is the maintainer's review, not the
        # author's batch.
        self.list(stanza("log/l.mbt,changed,INT,1,2,0"), stanza("log/l.mbt,reviewed,INT,1,2,0"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.git("checkout", "-q", "-b", "topic")
        self.list(stanza("log/l.mbt,changed,INT,1,2,0", reason="Another reason."),
                  stanza("log/l.mbt,reviewed,INT,1,2,0", reviewer="the maintainer"),
                  *[stanza(m) for m in self.PROTOCOL + self.OTHERS])
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "a batch")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args):
        subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                        "-c", "commit.gpgsign=false", "-C", str(self.root), *args], check=True, capture_output=True)

    def list(self, *stanzas):
        (self.root / "exclusions.toml").write_text("\n".join(stanzas))

    def review(self, *args):
        result = subprocess.run([sys.executable, str(EXCLUSIONS), "--root", str(self.root), "review", "--base", "main",
                                 *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def listed(self, text, heading):
        """The ids listed under a heading of review's output."""
        lines = text.split("\n")
        start = next(i for i, line in enumerate(lines) if line.startswith(heading))
        found = []
        for line in lines[start + 1 :]:
            if not line.startswith("  "):
                break
            found.append(line.split()[0])
        return found

    def test_the_maintainer_reads_every_entry_in_the_protocol_packages_and_serverparsers(self):
        text = self.review()
        self.assertIn("The batch: 10 entries that the branch adds or changes against", text)
        self.assertEqual(sorted(self.listed(text, "Every one in the protocol packages and in serverparsers (3):")),
                         sorted(self.PROTOCOL))

    def test_without_a_seed_it_says_how_many_of_the_others_the_maintainer_draws(self):
        # The changed entry and the six others: one in five of seven is 2.
        text = self.review()
        self.assertIn("One in five of the other 7: 2, drawn once the batch is frozen, with `review --seed <run ID>`:"
                      " the ID of the packages run on the frozen tip, which no agent can know before.", text)
        self.assertNotIn("log/l.mbt,reviewed", text)

    def test_with_a_seed_it_draws_one_in_five_of_the_others(self):
        text = self.review("--seed", "a seed the author cannot know")
        drawn = self.listed(text, "One in five of the other 7: 2, drawn with the seed")
        self.assertEqual(len(drawn), 2)
        self.assertTrue(set(drawn) <= set(self.OTHERS) | {"log/l.mbt,changed,INT,1,2,0"}, drawn)
        # The same seed draws the same entries.
        self.assertEqual(self.listed(self.review("--seed", "a seed the author cannot know"),
                                     "One in five of the other 7"), drawn)


if __name__ == "__main__":
    unittest.main()
