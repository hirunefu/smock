#!/usr/bin/env python3
"""Runs the mutants of MoonBit packages on wasm-gc with each package's own
tests, and those that survive with the tests of the packages that import
it, and writes one record per mutant, a summary per package and a report
(CONTRIBUTING.md, "Mutation runner").

usage: python3 scripts/mutation/run.py [--root <dir>] [--work <dir>] [--out <dir>]
           [--set pinned|full] [--mutant <id>]... [--operator <operator>]...
           [--sites-only] [--workers <n>]
           [--list <file> [--totals-only]] [--sample <n> [--seed <s>]] [--shard <k>/<n>]
           [--changed [--base <ref>]] [--self-test-only] [--matrix]
           [--flakes <file>] [--moon <moon>] [--finder <command>]
           [<package directory>...]

<package directory> is relative to <root>, the workspace or module to
mutate: the current directory unless it is given. The site finder
(scripts/mutation/sites.py, or --finder) gives the sites of the full set,
one per line, each with whether the pinned set takes it, and the sites
that a rule of the operator set skipped. --set pinned, the default, makes
one mutant of each site of the pinned set: one per position, two for INT
in a comparison or an index, the alternative chosen by the rule of
operator set v1. --set full makes one of each site of the full set: every
alternative of every operator at every position. --mutant runs only the
mutant with that id, which must be in the set, and may be given more than
once; a package given that holds none of the ids is not run. --operator
runs only the set's mutants that an operator of operator set v1 makes,
and may be given more than once: --operator BODY is a BODY pass, the
BODY mutant of every function; a package given that holds none is not
run.
--sites-only runs no mutant: it writes the counts of sites, positions and
skipped sites of each package, in both sets, and the mutants a run would
make, in chosen.jsonl. --self-test-only runs each package's self-test,
and no mutant.

Four more options choose the mutants: three for bulk runs (choice.py
says how), and one for a contributor's branch (changed.py says how):

  --list <file>    runs the mutants a file lists, in its order, in place
                   of a set: by offset on a commit, or by key on any
                   later commit. A mutant that no site of operator set v1
                   makes is outside v1, and its record says so
                   (in_operator_set). The packages are those of the
                   listed files, unless given. A key that no longer
                   finds its text is written, with why, to
                   unapplied.jsonl, and the report counts it. With
                   --totals-only, the run writes only per-package and
                   total counts into summary.json and report.md; it
                   removes from <out> the files of an earlier run that
                   name mutants and from <work> the workers' builds, and
                   prints no mutant's id, no output of a build or a test,
                   and not the reason it stops, which may name a mutant.
  --sample <n>     runs a sample of n of the set's mutants, stratified by
                   package, which --seed (0 unless given) fixes.
  --shard <k>/<n>  runs the k-th of n parts of the mutants, in the run's
                   order, whose sizes differ by one at most;
                   scripts/mutation/merge.py merges the outputs of a
                   run's shards into the output of the run without them.
  --changed        runs the mutants whose original text holds a non-test
                   line that the working tree adds or changes in a pure
                   package, against the merge base of HEAD with main
                   (origin/main where there is no main), or with the ref
                   --base gives. The packages are those of the changed
                   files, unless given. The report starts with the base,
                   the merge base, the count of changed lines and of the
                   mutants that ran; with no changed line, the run runs
                   nothing and says so. The summary gives the lines
                   (changed).

Without --mutant, --operator, --list, --sample or --changed, every
package given runs, one that has no mutant at all in the first shard; with one of them,
only the packages that hold one of the shard's mutants run.

For each worker, the runner copies <root> into <work>/tree-<n>, the files
that git tracks and the untracked ones it does not ignore, and builds
there into <work>/target-<n>: a build directory at a stable path, in a
target directory of the runner's own, so that a plain build and a mutant
build never rebuild each other, and each mutant is built where the last
one was. <work> is <root>/_build/mutation unless it is given. For each
package, the runner first builds the tests without a mutant and runs them
twice: it stops if they do not build, or if a run fails without naming a
test that failed, and a test that fails in either run gives no kill
credit in this run. Then, when the package has a mutant to run, or with
--self-test-only, it runs the package's forced-fail self-test
(selftest.py): it switches on a mutant that puts an abort at the start of
every function of the package, builds and runs the tests, switches it
off, and stops unless a test that gives kill credit failed, so that a
runner that could see no mutant never reports one. A self-test that the
package's own tests do not see runs again with its importers' tests, as
a mutant that survives them does. Then, for each
mutant, it writes the mutated file into
the tree, builds the package's tests (moon test --build-only), and runs
them. It checks the build's exit status, so that a failed build never
runs the binary of an earlier one, and it never passes -u.

It confirms each kill and time-out (scripts/mutation/confirm.py): a kill
counts only if some of the tests that failed fail again with the mutant
on and pass with it off, and a time-out only if it happens again and the
run without the mutant finishes within the limit. Nor does a test whose
flake rate, in the flake records of earlier runs that --flakes names, is
above the flake threshold of mutation/flakes.toml give kill credit.

Each mutant that survives the package's own tests runs again, the same
way, with the tests of the package's importers that build on wasm-gc:
the packages that import it, directly or through other packages, which
scripts/mutation/importers.py finds in the build's own package graph
before any mutant runs. Their tests first run without a mutant, and the
run stops if they fail. Importers that build only natively, such as e2e,
give no credit, since a pure package's verdict is taken on wasm-gc. The
outcome, after both runs, is

  killed       a test failed, and the kill is confirmed;
  timed out    the run took longer than 1.25 times the longer run without
               a mutant plus 4 s, and was stopped, and the time-out is
               confirmed; it counts as killed, and is listed apart;
  unconfirmed  a kill or a time-out that its confirmation did not bear
               out; outside the counts of killed and survived, and listed
               with the reason;
  unviable     the mutant does not build; outside the counts of killed
               and survived;
  survived     every test that gives kill credit passed.

With --matrix, the kill-matrix mode (matrix.py), each mutant runs once
with the tests of the package and of its importers that build on wasm-gc
together, whichever would kill it first, with no early stop, and each
test that failed is confirmed on its own: its record lists every test
that kills it, with its package and layer. Its summary then counts, in
place of the runs with the package's own tests alone and with its
importers' tests, the tests that kill some mutant and those that alone
kill one, and the runner writes the matrix per package.

Before the tests run, compare.py compares the compiler's output for the
mutated package with the output without a mutant and with the earlier
mutants' outputs; the mutant keeps the lines of the source. Where it
finds the same output, the mutant runs no tests, and the outcome is

  equivalent  the output is the same as without a mutant;
  duplicate   the output is the same as an earlier mutant's, which the
              record names (duplicate_of).

Each record of a mutant that built gives what the comparison found
(compiler_output) and its time (compare_s). summary.json and report.md
count the equivalent mutants, the duplicates and the mutants not
compared per package, apart from the other outcomes, and report.md lists
the equivalent mutants and the duplicates.

A mutant at a site that the finder marks as one whose definition uses an
unchecked array access (unchecked_access), whose tests ran, runs again
natively, the same way, with the same tests (native.py): wasm-gc traps
on an access out of bounds where the native binary reads on. Its record
gives both verdicts (verdicts), and the native verdict decides on amd64
alone: native verdicts are taken on CI's amd64 runner, one machine, so
that they can be reproduced, and one taken off CI is for information. A
package that builds only natively runs wholly natively, with its own
tests, and its compiler output is not compared. Before the first native
build, the runner unsets moon's variables for another C compiler
(MOON_CC, MOON_AR, MOON_CC_WRAPPER), and native runs dump no core.
summary.json and report.md give, per package, what ran natively, where,
and the mutants whose verdicts differ between the backends (native).

It writes into <out> (<work>/out unless it is given):

  mutants.jsonl  one record per mutant: the site's fields (its operator
                 set's version and whether the pinned set takes it
                 included), the package, the set that ran, the outcome,
                 the tests that killed it, each with its package, the
                 importers whose tests ran it again (none, unless it
                 survived the package's own), the backend, the timings
                 (build_s, run_s and the run's limit_s, and the same of
                 the importers' run under "importers", and those of the
                 runs that confirm a kill or a time-out: again_s and
                 without_s), how its confirmation went ("confirmation";
                 for an unconfirmed one, its first outcome and the tests
                 that failed then), the tests that failed but give no kill
                 credit, the compiler's message for an unviable one, the
                 diff of a survivor or of an unconfirmed one, and a
                 survivor's status after the exclusion list (exclusion,
                 below);
  summary.json   the operator set's version, the set that ran (listed for
                 --list), what chose the mutants (selection), that the
                 run was a kill matrix (kill_matrix, with --matrix), the
                 flake
                 threshold with the tests above it and those with a
                 flaky result in this run ("flakes"), and per package: the
                 baseline (both runs, and the tests that failed in them),
                 the counts of sites and positions in the set that ran
                 and in both sets, the sites each rule skipped, the
                 counts of mutants and each outcome, and the score:
                 (killed + timed out) / (killed + timed out + survived),
                 which leaves unconfirmed mutants out; the same counts
                 with the package's own tests alone ("own"); its
                 importers ("importers"): those that build on wasm-gc and
                 those that build only natively, their tests' runs
                 without a mutant and time limit, how many survivors they
                 ran again, how many they killed, and how many the tests
                 of each package killed; for the full set, the same
                 counts at the pinned alternatives and at the other
                 alternatives apart; and the self-test's record
                 (self_test): the functions it changed, its outcome and
                 how many of its tests failed; and its survivors after the
                 exclusion list (exclusions): how many are unexplained,
                 stale-covered and accepted, and the categories of those
                 accepted; and, when BODY mutants ran, how many
                 (body_mutants) and the functions whose BODY mutant
                 survived, the pseudo-tested functions (pseudo_tested),
                 each with its status after the exclusion list;
  report.md      the operator set's version and the set, the summaries,
                 the counts with the package's own tests alone, its
                 importers and what their tests killed, the sites each
                 rule skipped, the tests that failed without a mutant,
                 the time-outs, the unconfirmed mutants, the survivors
                 after the exclusion list, the pseudo-tested functions,
                 and each survivor's status and
                 diff with its whole enclosing definition, the unexplained
                 first, then the stale-covered, then the accepted (for the full
                 set, the survivors at the pinned alternatives and those
                 at the other alternatives apart); for a listed set,
                 then, per package, the mutants listed, run, no longer
                 applying and outside v1, each listed mutant with its
                 outcome, and each key that no longer applies, with why;
                 and last the flaky tests. It also prints the report;
  flakes.json    the flake records: the latest runs' records, this one
                 included, and each test's flake rate over them, for the
                 next run's --flakes;
  matrix/        with --matrix, each package's kill matrix,
                 <package directory>.json: every test that ran, and each
                 mutant with every test that kills it, which
                 scripts/mutation/matrix.py reads. Every run removes what
                 an earlier one wrote there.

A position is the place of one or more sites: their file, operator, line
and column.

The exclusion list, exclusions.toml at <root> (exclusions.py,
CONTRIBUTING.md, "Exclusions"), gives each survivor its status: accepted,
when a current entry other than DEFERRED names it; stale-covered, when
its only entry is stale (the text of its definition changed); and
unexplained otherwise, a survivor with a DEFERRED entry included, whose
issue the record names. The merge check reports a stale-covered survivor
without blocking; every other count treats it as unexplained.

It exits with 0 when every mutant has an outcome, survivors or not, and
with 1 when it cannot run them, a self-test that no test killed included.
"""

import argparse
import difflib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import changed
import choice
import compare
import confirm
import exclusions
import importers
import matrix
import native
import operators
import selftest

HERE = Path(__file__).resolve().parent
BACKEND = "wasm-gc"
# The build of the package without a mutant, and its tests, may take this
# long: they have no baseline to scale from.
FIRST_RUN_LIMIT_S = 1800
# Directories of a tree that are never copied nor removed: build output,
# downloaded modules and git's own.
SKIPPED = {"_build", "target", ".mooncakes", ".git"}
# The file in a tree that lists what the runner copied there.
MANIFEST = ".mutation-files"
NAME = re.compile(r'^\s*"?name"?\s*[=:]\s*"([^"]+)"', re.MULTILINE)
TOTAL = re.compile(r"Total tests: (\d+), passed: (\d+), failed: (\d+)")


class RunnerError(Exception):
    """What stops the run: a package that fails without a mutant, or a site
    that does not match the source."""


def package_name(root, directory):
    """The moon package of a directory: its module's name, from the nearest
    moon.mod or moon.mod.json at or above it within root, and its path
    within the module."""
    root = root.resolve()
    current = (root / directory).resolve()
    if not current.is_dir():
        raise RunnerError(f"{directory} is not a directory of {root}")
    module = current
    while True:
        for file in ("moon.mod", "moon.mod.json"):
            if (module / file).is_file():
                match = NAME.search((module / file).read_text(encoding="utf-8"))
                if not match:
                    raise RunnerError(f"{module / file} names no module")
                rel = current.relative_to(module).as_posix()
                return match.group(1) if rel == "." else f"{match.group(1)}/{rel}"
        if module == root:
            raise RunnerError(f"no module holds {directory}")
        module = module.parent


def listed_files(root):
    """The files of root to copy, relative to it: those git tracks, and the
    untracked ones it does not ignore; every file outside the skipped
    directories when root is not in a git work tree."""
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                            capture_output=True)
    if result.returncode == 0:
        names = [n for n in result.stdout.decode("utf-8").split("\0") if n]
        return sorted(n for n in names if (root / n).is_file())
    files = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = [d for d in subdirectories if d not in SKIPPED]
        for name in names:
            files.append((Path(directory) / name).relative_to(root).as_posix())
    return sorted(files)


def sync(root, tree, files):
    """Makes tree a copy of root's files: copies each one that differs, and
    removes what an earlier copy left that root no longer has. Files the
    build writes in the tree stay."""
    tree.mkdir(parents=True, exist_ok=True)
    manifest = tree / MANIFEST
    wanted = set(files)
    if manifest.is_file():
        for old in manifest.read_text(encoding="utf-8").splitlines():
            if old and old not in wanted and (tree / old).is_file():
                (tree / old).unlink()
    for name in files:
        source, target = root / name, tree / name
        data = source.read_bytes()
        if not target.is_file() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copymode(source, target)
    manifest.write_text("".join(f"{n}\n" for n in files), encoding="utf-8")


def run(command, cwd, limit):
    """Runs a command in its own process group, and stops the group after
    limit seconds: (exit status, output, seconds, whether it timed out)."""
    start = time.monotonic()
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=limit)
        timed_out = False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        timed_out = True
    elapsed = time.monotonic() - start
    return process.returncode, output.decode("utf-8", errors="replace"), elapsed, timed_out


def diagnostics(output, tree):
    """The error messages of moon's JSON diagnostics in an output, with
    paths relative to the tree."""
    prefix = f"{tree}/"
    messages = []
    for line in output.split("\n"):
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("$message_type") == "diagnostic" and item.get("level") == "error":
            path = str(item.get("path", "")).removeprefix(prefix)
            messages.append(f"{path}:{item.get('loc', '')}: {item.get('message', '')}")
    return messages


def failed_tests(output):
    """The tests that failed, from moon test --test-failure-json."""
    tests = []
    for line in output.split("\n"):
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and "test_name" in item:
            tests.append({"package": item.get("package"), "file": item.get("filename"),
                          "index": int(item.get("index", -1)), "name": item.get("test_name")})
    return tests


class Worker:
    """A tree and a target directory, where mutants are built one at a
    time."""

    def __init__(self, number, work, moon):
        self.number = number
        self.tree = work / f"tree-{number}"
        self.target = work / f"target-{number}"
        self.moon = moon
        # The backend it builds and tests on (native.py makes native twins).
        self.backend = BACKEND
        # The run's Judge (scripts/mutation/confirm.py), which confirms
        # kills and time-outs.
        self.judge = None

    def moon_test(self, package, limit, build_only):
        """Builds the tests of a package, or of a list of packages, or runs
        them, in the worker's tree."""
        packages = [package] if isinstance(package, str) else package
        selected = [option for name in packages for option in ("-p", name)]
        command = [*self.moon, "test", "--target", self.backend, *selected, "--target-dir", str(self.target)]
        command += ["--build-only", "--output-json"] if build_only else ["--test-failure-json"]
        return run(command, self.tree, limit)

    def build(self, package, limit=FIRST_RUN_LIMIT_S):
        """Builds the package's tests: (exit status, output, seconds)."""
        status, output, seconds, timed_out = self.moon_test(package, limit, build_only=True)
        if timed_out:
            raise RunnerError(f"the build of {package} in {self.tree} took over {limit} s")
        return status, output, seconds


def apply(text, site):
    """The text with the site's change, after checking that the site's
    original text is where the site says."""
    starts = [0]
    for line in text.split("\n"):
        starts.append(starts[-1] + len(line) + 1)
    line, column = site["line"], site["column"]
    if not 1 <= line < len(starts):
        raise RunnerError(f"{site['id']}: {site['file']} has no line {line}")
    offset = starts[line - 1] + column - 1
    end = offset + len(site["original"])
    if text[offset:end] != site["original"]:
        raise RunnerError(f"{site['id']}: {site['file']}:{line}:{column} holds {text[offset:end]!r},"
                          f" not {site['original']!r}")
    return text[:offset] + compare.with_line_breaks(site["original"], site["replacement"]) + text[end:]


def definition_diff(site, text, mutated):
    """The mutant's diff, with its whole enclosing definition as context."""
    first, last = site["definition_lines"]
    before = text.split("\n")
    after = mutated.split("\n")
    delta = len(after) - len(before)
    old = before[first - 1 : last]
    new = after[first - 1 : last + delta]
    lines = list(difflib.unified_diff(old, new, lineterm="", n=len(old) + len(new)))
    hunk = [f"@@ -{first},{len(old)} +{first},{len(new)} @@ {site['definition']}"]
    return "\n".join([f"--- a/{site['file']}", f"+++ b/{site['file']}"] + hunk + lines[3:]) + "\n"


def find_sites(finder, root, directory):
    """The sites of the full set that the finder prints for a package's
    directory, and the sites that a rule skipped. Every line names the
    same operator set."""
    command = [*finder, "--root", str(root), "--set", "full", directory]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RunnerError(f"the site finder failed on {directory}:\n{result.stderr}")
    lines = [json.loads(line) for line in result.stdout.split("\n") if line.strip()]
    versions = {line.get("operator_set") for line in lines}
    if None in versions or len(versions) > 1:
        raise RunnerError(f"the site finder's lines for {directory} do not name one operator set:"
                          f" {sorted(map(str, versions))}")
    return [s for s in lines if "skipped" not in s], [s for s in lines if "skipped" in s]


def in_set(site, chosen):
    """Whether a site is in the chosen set, pinned or full."""
    return chosen == "full" or site["pinned"]


def position(site):
    """The place of a site, which it shares with the other alternatives of
    its operator there."""
    return site["file"], site["operator"], site["line"], site["column"]


def set_counts(sites, skipped):
    """The counts of sites and positions, and of the sites that each rule
    skipped, in the pinned set and in the full set."""
    counts = {}
    for chosen in ("pinned", "full"):
        mine = [s for s in sites if in_set(s, chosen)]
        rules = {}
        for site in skipped:
            if in_set(site, chosen):
                rule = f"{site['operator']} {site['skipped']}"
                rules[rule] = rules.get(rule, 0) + 1
        counts[chosen] = {"sites": len(mine), "positions": len({position(s) for s in mine}),
                          "skipped": dict(sorted(rules.items()))}
    return counts


def outcome_counts(records):
    """The count of each outcome among records, and the score."""
    outcomes = ("killed", "timed out", "survived", "unviable", "unconfirmed")
    counts = {o: sum(1 for r in records if r["outcome"] == o) for o in outcomes}
    # A time-out is confirmed, so it counts as killed; an unconfirmed kill
    # or time-out counts neither as killed nor as survived.
    killed = counts["killed"] + counts["timed out"]
    judged = killed + counts["survived"]
    return {
        "mutants": len(records),
        "killed": counts["killed"],
        "timed_out": counts["timed out"],
        "survived": counts["survived"],
        "unviable": counts["unviable"],
        "unconfirmed": counts["unconfirmed"],
        "score": round(killed / judged, 4) if judged else None,
    }


def choose(found, chosen_set, ids, directories):
    """The sites of the chosen set in each package, and the mutants to run
    of them: all of them, or, with ids, those the ids name, which must all
    be sites of the set."""
    sites = {d: [s for s in found[d][0] if in_set(s, chosen_set)] for d in directories}
    if not ids:
        return sites, {d: list(mine) for d, mine in sites.items()}
    known = {s["id"] for mine in sites.values() for s in mine}
    unknown = [i for i in ids if i not in known]
    if unknown:
        where = ", ".join(directories)
        raise RunnerError("".join(f"no site of {where} in the {chosen_set} set has the id {i}\n"
                                  for i in unknown).rstrip())
    return sites, {d: [s for s in mine if s["id"] in ids] for d, mine in sites.items()}


def pseudo_tested(records):
    """The functions whose BODY mutant survived among records, for a
    summary: how many BODY mutants there are, and each survivor's
    definition with its status after the exclusion list. A function whose
    BODY mutant survives is pseudo-tested, and L2 needs each such mutant
    killed or excluded. Nothing when no BODY mutant is among them."""
    body = [r for r in records if r["operator"] == "BODY"]
    if not body:
        return {}
    return {"body_mutants": len(body),
            "pseudo_tested": [{"definition": r["definition"], "file": r["file"], "mutant": r["id"],
                               "status": r.get("exclusion", {}).get("status", "unexplained")}
                              for r in exclusions.ordered([r for r in body if r["outcome"] == "survived"])]}


def pseudo_tested_lines(summary, records):
    """The report's list of a package's pseudo-tested functions, when its
    BODY mutants ran."""
    if "pseudo_tested" not in summary:
        return []
    found = summary["pseudo_tested"]
    out = [f"### Pseudo-tested functions ({len(found)} of {summary['body_mutants']} BODY mutants)", ""]
    if not found:
        return out + ["None: no BODY mutant survived.", ""]
    out += ["Each function's BODY mutant survived; L2 needs it killed or excluded.", ""]
    by_id = {r["id"]: r for r in records}
    for function in found:
        status = exclusions.status_line(by_id[function["mutant"]]) if function["mutant"] in by_id else None
        out += [f"- `{function['definition']}` ({function['file']}): {status or function['status']}"]
    return out + [""]


def alternative_counts(records):
    """A full set's counts at the pinned alternatives and at the others,
    apart: L4 reads only the former."""
    return {"pinned": outcome_counts([r for r in records if r["pinned"]]),
            "other": outcome_counts([r for r in records if not r["pinned"]])}


def package_summary(root, directory, sites, skipped, chosen, operator_set):
    """What a package's summary says without a run: its sites, positions
    and skipped sites in the set that ran and in both sets."""
    counts = set_counts(sites, skipped)
    return {
        "package": package_name(root, directory),
        "directory": directory,
        "operator_set": operator_set,
        "set": chosen,
        "sites": counts[chosen]["sites"],
        "positions": counts[chosen]["positions"],
        "skipped": counts[chosen]["skipped"],
        "sets": counts,
    }


def run_package(root, directory, sites, mutants, workers, log, self_test_only=False, kill_matrix=False):
    """Runs the chosen mutants of one package, whose sites are given, with
    its own tests, and those that survive again with the tests of its
    importers that build on wasm-gc: its records, and its summary's counts
    of the run, with its own tests alone and after its importers' tests.
    The package's self-test runs first when it has a mutant to run, or
    with self_test_only. With kill_matrix, each mutant runs with its own
    and its importers' tests at once instead (matrix.py)."""
    package = package_name(root, directory)
    first = workers[0]
    try:
        workers = native.workers_for(workers, package)
        packages, native_only = importers.find(first.moon, first.tree, first.target, package)
    except importers.ImportersError as error:
        raise RunnerError(str(error)) from error
    if kill_matrix:
        return matrix.run_package(workers, package, directory, packages, native_only, sites, mutants, log,
                                  run_tests, outcome_counts, RunnerError)
    credit = importers.credit(packages, native_only)
    records, baseline, limit, self_test = run_tests(workers, package, [package], mutants, log,
                                                    f"{package}: {len(sites)} sites", own=directory,
                                                    with_self_test=bool(mutants) or self_test_only)
    own = outcome_counts(records)
    for record in records:
        record["importers"] = []
    survivors = [i for i, r in enumerate(records) if r["outcome"] == "survived"]
    if packages and survivors:
        again, again_baseline, again_limit, _ = run_tests(
            workers, f"the importers of {package} ({', '.join(packages)})", packages,
            [mutants[i] for i in survivors], log, f"{package}: survivors again with the tests of {', '.join(packages)}")
        credit.update(baseline=again_baseline, limit_s=round(again_limit, 3))
        for index, record in zip(survivors, again):
            importers.merge(records[index], record, packages, credit)
    natively = native.judge(workers, run_tests, package, packages, mutants, records, log)

    summary = {
        "backend": workers[0].backend,
        "baseline": baseline,
        "limit_s": round(limit, 3),
        **outcome_counts(records),
        **compare.counts(records),
        "own": own,
        "importers": credit,
        **({"self_test": self_test} if self_test is not None else {}),
        **natively,
    }
    return records, summary


def run_tests(workers, what, packages, mutants, log, header, own=None, with_self_test=False):
    """Builds the tests of packages without a mutant in each worker's tree,
    and runs them twice in the first; then runs each mutant with them. It
    stops if they do not build, or if a run without a mutant fails without
    naming a test that failed; a test that fails in either run gives no
    kill credit in this run. With own, the directory of the one package,
    this is the package's own pass: each mutant's compiler output is
    compared before its tests run (compare.py), and, with with_self_test,
    the self-test runs before any mutant (selftest.py). It logs the runs
    without a mutant after header, and each outcome. It gives the records,
    the baseline (the longer run's seconds, both runs' seconds, the number
    of tests and the tests that failed), the time limit, which the longer
    run sets, and the self-test's record (None when it did not run)."""
    first = workers[0]
    status, output, _ = first.build(packages)
    if status != 0:
        raise RunnerError(f"{what} does not build without a mutant:\n{output}")
    runs = []
    for _ in range(2):
        status, output, seconds, timed_out = first.moon_test(packages, FIRST_RUN_LIMIT_S, build_only=False)
        failed = failed_tests(output)
        if timed_out or status != 0 and not failed:
            raise RunnerError(f"the tests of {what} fail without a mutant:\n{output}")
        runs.append((seconds, failed, TOTAL.findall(output)))
    baseline_s = max(seconds for seconds, _, _ in runs)
    tests = sum(int(t[0]) for t in runs[0][2])
    baseline = {"run_s": round(baseline_s, 3), "runs_s": [round(seconds, 3) for seconds, _, _ in runs],
                "tests": tests, "failed": first.judge.baseline(packages, [failed for _, failed, _ in runs])}
    limit = 1.25 * baseline_s + 4
    log(f"{header}, {len(mutants)} mutants, {tests} tests, baseline runs"
        f" {', '.join(f'{s:.2f}' for s in baseline['runs_s'])} s, limit {limit:.2f} s"
        + (f", {len(baseline['failed'])} tests failed without a mutant" if baseline["failed"] else ""))
    for worker in workers[1:]:
        status, output, _ = worker.build(packages)
        if status != 0:
            raise RunnerError(f"{what} does not build without a mutant in {worker.tree}:\n{output}")
    # The own pass compares each mutant's compiler output before its tests
    # run (compare.py), and runs the self-test; the importers' pass reruns
    # only survivors, which it compared already. The self-test comes after
    # the comparison has linked the package without a mutant, since its
    # build replaces that one in the first worker's target directory. A
    # native run compares nothing: the output compared is wasm-gc's.
    comparison =compare.Comparison(packages[0], own, workers, log) if own and first.backend == BACKEND else None
    self_test = run_self_test(first, packages[0], own, limit, log) if own and with_self_test else None

    # A record names its package; the records of the importers' run are
    # only read for what they found.
    tested = packages[0] if len(packages) == 1 else packages
    records = [None] * len(mutants)
    queue = list(enumerate(mutants))
    lock = threading.Lock()

    def work(worker):
        while True:
            with lock:
                if not queue:
                    return
                index, site = queue.pop(0)
            records[index] = run_mutant(worker, tested, site, limit, comparison)
            record = records[index]
            log(f"  {record['outcome']:9} {site['id']}  (build {record['timings']['build_s']:.2f} s,"
                f" run {record['timings']['run_s']:.2f} s)")

    with ThreadPoolExecutor(max_workers=len(workers)) as pool:
        for future in [pool.submit(work, w) for w in workers]:
            future.result()
    return records, baseline, limit, self_test


def run_self_test(worker, package, directory, limit, log):
    """The forced-fail self-test of a package (selftest.py), before any
    of its mutants: its record, or a RunnerError when no test saw it. Only
    the tests that give kill credit in this run count (confirm.py): a
    self-test whose failed tests all give none survived."""
    uncredited = []

    def credited(output):
        tests, others = worker.judge.split(failed_tests(output))
        uncredited[:] = others
        return tests

    record = selftest.run(worker, package, directory, limit, credited)
    if record["outcome"] == "killed" and not record["failed_tests"] and uncredited:
        record.update(outcome="survived", no_credit=uncredited)
    if record["outcome"] == "survived":
        record = self_test_with_importers(worker, package, directory, record, log, credited, uncredited)
    problem = selftest.failure(package, record)
    if problem:
        raise RunnerError(problem)
    log(f"  self-test killed, by {record['failed_tests']} tests ({len(record['definitions'])} functions changed)")
    return record


def self_test_with_importers(worker, package, directory, record, log, credited, uncredited):
    """A self-test that the package's own tests did not see, run again with
    the tests of its importers that build on wasm-gc, as a mutant that
    survives its own tests is: the record of that run, which names them,
    or the record given when the package has no such importer. So a package
    without tests of its own, such as cookies, passes when its importers'
    tests see the self-test. Their tests first run twice without it, which
    sets the time limit."""
    try:
        packages, _ = importers.find(worker.moon, worker.tree, worker.target, package)
    except importers.ImportersError as error:
        raise RunnerError(str(error)) from error
    if not packages:
        return record
    names = ", ".join(packages)
    _, _, limit, _ = run_tests([worker], f"the importers of {package} ({names})", packages, [], log,
                               f"{package}: its self-test again with the tests of {names}")
    again = selftest.run(worker, packages, directory, limit, credited)
    if again["outcome"] == "killed" and not again["failed_tests"] and uncredited:
        again.update(outcome="survived", no_credit=list(uncredited))
    return dict(again, importers=packages)


def run_mutant(worker, package, site, limit, comparison=None):
    """Builds and tests one mutant in a worker's tree, unless the compiler's
    output, where a comparison is given, shows it equivalent or a
    duplicate: its record."""
    path = worker.tree / site["file"]
    text = path.read_text(encoding="utf-8")
    mutated = apply(text, site)
    record = dict(site, package=package, backend=worker.backend)
    try:
        path.write_text(mutated, encoding="utf-8")
        status, output, build_s = worker.build(package)
        timings = {"build_s": round(build_s, 3), "run_s": 0.0, "limit_s": round(limit, 3)}
        if status != 0:
            messages = diagnostics(output, worker.tree)
            record.update(outcome="unviable", killing_tests=[], timings=timings,
                          message="\n".join(messages) if messages else output[-2000:])
        elif comparison is not None and comparison.judge(worker, site, record, timings):
            record.update(killing_tests=[], timings=timings)
        else:
            status, output, run_s, timed_out = worker.moon_test(package, limit, build_only=False)
            timings["run_s"] = round(run_s, 3)
            failed = failed_tests(output)
            ended = {"run": confirm.ended(status, timed_out, failed)}
            if timed_out:
                record.update(outcome="timed out", killing_tests=[], timings=timings, ended=ended)
            elif status == 0:
                record.update(outcome="survived", killing_tests=[], timings=timings, ended=ended)
            else:
                record.update(outcome="killed", killing_tests=failed, timings=timings, ended=ended)
                if not record["killing_tests"]:
                    record["message"] = output[-2000:]
    finally:
        path.write_text(text, encoding="utf-8")
    worker.judge.confirm(worker, package, path, text, mutated, record, limit)
    if record["outcome"] in ("survived", "unconfirmed"):
        record["diff"] = definition_diff(site, text, mutated)
    return record


def report(operator_set, chosen, summaries, records):
    """The report: the operator set and the set, the summary of each
    package, the sites each rule skipped, its time-outs, and its survivors
    with their diffs, those at the other alternatives of the full set
    apart."""
    which = {"pinned": "the pinned set", "full": "the full set"}.get(chosen, f"a {chosen} set")
    out = ["# Mutation report", "", f"Operator set {operator_set}, {which}.", ""]
    for summary in summaries:
        package = summary["package"]
        mine = [r for r in records if r["package"] == package]
        out += [f"## {package}", ""]
        if "backend" in summary:
            out += [f"Backend {summary['backend']}, {summary['baseline']['tests']} tests, baseline run"
                    f" {summary['baseline']['run_s']:.2f} s, time limit {summary['limit_s']:.2f} s.", ""]
        if "self_test" in summary:
            out += [selftest.report_line(summary["self_test"]), ""]
        out += site_table(summary)
        if "backend" not in summary:
            continue
        rows = [("", summary)]
        if chosen == "full":
            rows = [("all", summary), ("at the pinned alternatives", summary["pinned"]),
                    ("at the other alternatives", summary["other"])]
        out += ["| mutants | killed | timed out | survived | unviable | unconfirmed | score |" if chosen == "pinned"
                else "| alternatives | mutants | killed | timed out | survived | unviable | unconfirmed | score |"]
        out += ["|---:|---:|---:|---:|---:|---:|---:|" if chosen == "pinned" else
                "|---|---:|---:|---:|---:|---:|---:|---:|"]
        for label, counts in rows:
            score = "none" if counts["score"] is None else f"{counts['score']:.1%}"
            cells = [counts["mutants"], counts["killed"], counts["timed_out"], counts["survived"],
                     counts["unviable"], counts["unconfirmed"], score]
            out += ["| " + " | ".join(([label] if chosen == "full" else []) + [str(c) for c in cells]) + " |"]
        out += [""]
        after = exclusions.summary_line(summary)
        if after:
            out += [after, ""]
        out += pseudo_tested_lines(summary, mine)
        out += compare.report(mine)
        out += importers.report_lines(summary)
        out += matrix.report_lines(summary)
        out += native.report_lines(summary, mine)
        out += confirm.Judge.baseline_lines(summary)
        timed_out = [r for r in mine if r["outcome"] == "timed out"]
        if timed_out:
            out += ["### Timed out, confirmed, so counted as killed", ""]
            out += [f"- `{r['id']}` (run stopped after {r['timings'].get('importers', r['timings'])['run_s']:.2f} s)"
                    for r in timed_out]
            out += [""]
        out += confirm.repeated_lines(mine)
        unconfirmed = [r for r in mine if r["outcome"] == "unconfirmed"]
        if unconfirmed:
            out += [f"### Unconfirmed ({len(unconfirmed)})", ""]
            for record in unconfirmed:
                out += [f"#### `{record['id']}`", "", f"It was {record['first_outcome']}, but"
                        f" {record['confirmation']}. In `{record['definition']}`, {record['file']}"
                        f" lines {record['definition_lines'][0]} to {record['definition_lines'][1]}:", "",
                        "```diff", record["diff"].rstrip("\n"), "```", ""]
        survivors = [r for r in mine if r["outcome"] == "survived"]
        groups = [("Survivors", survivors)]
        if chosen == "full":
            groups = [("Survivors at the pinned alternatives", [r for r in survivors if r["pinned"]]),
                      ("Survivors at the other alternatives", [r for r in survivors if not r["pinned"]])]
        for title, group in groups:
            out += [f"### {title} ({len(group)})", ""]
            for record in exclusions.ordered(group):
                status = exclusions.status_line(record)
                no_kill = confirm.survivor_line(record)
                out += [f"#### `{record['id']}`", "", *([status, ""] if status else []),
                        *([no_kill, ""] if no_kill else []),
                        f"In `{record['definition']}`, {record['file']}"
                        f" lines {record['definition_lines'][0]} to {record['definition_lines'][1]}:", "",
                        "```diff", record["diff"].rstrip("\n"), "```", ""]
    return "\n".join(out)


def site_table(summary):
    """The lines of the report that count a package's sites, positions and
    skipped sites, in both sets."""
    sets = summary["sets"]
    out = ["| set | sites | positions |", "|---|---:|---:|"]
    for chosen in ("pinned", "full"):
        out += [f"| {chosen} | {sets[chosen]['sites']} | {sets[chosen]['positions']} |"]
    out += [""]
    skipped = summary["skipped"]
    if skipped:
        out += ["Sites skipped in this set: " + ", ".join(f"{rule} {n}" for rule, n in skipped.items()) + ".", ""]
    else:
        out += ["Sites skipped in this set: none.", ""]
    return out


def main():
    parser = argparse.ArgumentParser(description="Run the mutants of MoonBit packages and report the survivors.")
    parser.add_argument("--root", default=".", help="the workspace or module to mutate")
    parser.add_argument("--work", help="the runner's own directory (default <root>/_build/mutation)")
    parser.add_argument("--out", help="where the records and the report go (default <work>/out)")
    parser.add_argument("--set", default="pinned", choices=("pinned", "full"),
                        help="the pinned set (the default) or the full set")
    parser.add_argument("--mutant", action="append", help="run only the mutant with this id")
    parser.add_argument("--operator", action="append", choices=operators.OPERATORS,
                        help="run only the mutants that this operator makes (BODY: a BODY pass)")
    parser.add_argument("--sites-only", action="store_true",
                        help="count the sites of each package in both sets, and run no mutant")
    parser.add_argument("--list", metavar="FILE",
                        help="run the mutants that FILE lists, by offset on a commit or by key")
    parser.add_argument("--changed", action="store_true",
                        help="run the mutants on the non-test lines the branch changes in the pure packages")
    parser.add_argument("--base", help="with --changed, the ref whose merge base with HEAD the lines are"
                                       " compared with (main, or origin/main, unless given)")
    parser.add_argument("--totals-only", action="store_true",
                        help="with --list, write only per-package and total counts, naming no mutant")
    parser.add_argument("--sample", type=int, metavar="N",
                        help="run a sample of N of the mutants, stratified by package")
    parser.add_argument("--seed", default="0", help="the seed of --sample (0 unless given)")
    parser.add_argument("--shard", type=choice.shard_spec, metavar="K/N",
                        help="run only shard K of N of the mutants (K from 1)")
    parser.add_argument("--self-test-only", action="store_true",
                        help="run each package's self-test, and no mutant")
    parser.add_argument("--matrix", action="store_true",
                        help="run each mutant with its package's and its importers' tests at once, and write the"
                             " kill matrix")
    parser.add_argument("--workers", type=int, default=1, help="how many mutants build and run at once")
    parser.add_argument("--flakes", help="the flake records of an earlier run (its flakes.json)")
    parser.add_argument("--moon", default="moon", help="the moon command")
    parser.add_argument("--finder", help="the site finder's command (default: sites.py beside this script)")
    parser.add_argument("packages", nargs="*",
                        help="package directories, relative to <root> (with --list, those of its files"
                             " unless given)")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.sample is not None and (args.sample < 1 or args.mutant or args.list):
        parser.error("--sample takes a number from 1, and no --mutant or --list")
    if args.list and args.mutant:
        parser.error("--list and --mutant choose the mutants each: give one of them")
    if args.list and args.operator:
        parser.error("--list chooses the mutants: give no --operator with it")
    if not args.packages and not args.list and not args.changed:
        parser.error("give at least one package directory")
    if args.changed and (args.list or args.mutant):
        parser.error("--changed chooses the mutants: give no --list or --mutant with it")
    if args.base and not args.changed:
        parser.error("--base goes with --changed")
    if args.totals_only and (not args.list or args.sites_only or args.shard):
        parser.error("--totals-only takes --list, and neither --sites-only nor --shard")
    if args.self_test_only and (args.mutant or args.operator or args.list or args.sample is not None
                                or args.changed or args.sites_only):
        parser.error("--self-test-only runs no mutant, so it takes no --mutant, --operator, --list, --sample,"
                     " --changed or --sites-only")
    if args.matrix and (args.totals_only or args.self_test_only):
        parser.error("--matrix takes no --totals-only or --self-test-only")
    root = Path(args.root).resolve()
    work = Path(args.work).resolve() if args.work else root / "_build" / "mutation"
    out = Path(args.out).resolve() if args.out else work / "out"
    finder = shlex.split(args.finder) if args.finder else [sys.executable, str(HERE / "sites.py")]

    def log(message):
        if not args.totals_only:
            print(message, file=sys.stderr, flush=True)

    judge = None
    try:
        entries = choice.read_list(args.list) if args.list else None
        if entries is not None and not args.packages:
            args.packages = choice.list_directories(entries)
        changes = changed.find(root, args.base, args.packages) if args.changed else None
        if changes is not None:
            args.packages = changed.directories(changes["lines"])
        found = {directory: find_sites(finder, root, directory) for directory in args.packages
                 if entries is None or (root / directory).is_dir()}
        found.update({directory: ([], []) for directory in args.packages if directory not in found})
        versions = {s["operator_set"] for sites, skipped in found.values() for s in sites + skipped}
        if len(versions) > 1:
            raise RunnerError(f"the packages' sites name several operator sets: {sorted(versions)}")
        operator_set = versions.pop() if versions else None
        sites, chosen = choose(found, args.set, args.mutant, args.packages)
        if args.operator:
            chosen = choice.of_operators(chosen, args.packages, args.operator)
        if args.self_test_only:
            chosen = {directory: [] for directory in args.packages}
        unapplied = {directory: [] for directory in args.packages}
        if entries is not None:
            chosen, unapplied = choice.resolve(root, args.list, entries, found, args.packages)
            if args.shard and args.shard[0] != 1:
                # The first shard counts the keys that no longer apply.
                unapplied = {directory: [] for directory in args.packages}
        if changes is not None:
            chosen = changed.on_lines(chosen, args.packages, changes["lines"])
            changes["mutants"] = sum(len(chosen[directory]) for directory in args.packages)
        if args.sample is not None:
            chosen = choice.sample(chosen, args.packages, args.sample, args.seed)
        # The run's mutants, and the shard's.
        whole, chosen = chosen, choice.shard(chosen, args.packages, *args.shard) if args.shard else chosen
        selected = (bool(args.mutant) or bool(args.operator) or args.sample is not None or entries is not None
                    or changes is not None)
        run_set = "listed" if entries is not None else args.set
        runs = choice.running(args.packages, whole, chosen, selected, args.shard and args.shard[0])
        records, summaries = [], []
        if not args.sites_only and runs:
            files = listed_files(root)
            workers = [Worker(n, work, shlex.split(args.moon)) for n in range(args.workers)]
            judge = confirm.Judge.read(args.flakes, failed_tests, RunnerError)
            for worker in workers:
                worker.judge = judge
                sync(root, worker.tree, files)
        for directory in args.packages:
            if directory not in runs:
                continue
            summary = package_summary(root, directory, found[directory][0], found[directory][1], args.set,
                                      operator_set)
            summary["set"] = run_set
            if not args.sites_only:
                package_records, counts = run_package(root, directory, sites[directory], chosen[directory],
                                                      workers, log, self_test_only=args.self_test_only,
                                                      kill_matrix=args.matrix)
                for record in package_records:
                    record.update(set=run_set)
                summary.update(counts)
                if run_set == "full":
                    summary.update(alternative_counts(package_records))
                records += package_records
            summaries.append(summary)
        if records:
            exclusions.annotate(root, records)
            for summary in summaries:
                mine = [r for r in records if r["package"] == summary["package"]]
                summary.update(exclusions.counts(mine))
                summary.update(pseudo_tested(mine))
    except (RunnerError, choice.ChoiceError, changed.ChangedError, exclusions.ExclusionError) as error:
        print(choice.HIDDEN if args.totals_only else f"run: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        if not args.totals_only:
            raise
        print(choice.HIDDEN, file=sys.stderr)
        sys.exit(1)
    finally:
        if args.totals_only:
            choice.drop_builds(work)
    # Every run rewrites the kill matrices: a run with --totals-only keeps
    # none that would name a mutant.
    matrix.write(out, operator_set, run_set, summaries, records)
    if args.totals_only:
        print(choice.write_totals(out, operator_set, choice.selection(args), args.packages, summaries, records,
                                  unapplied, outcome_counts))
        return
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "mutants.jsonl", "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    flakes = {} if judge is None else {"flakes": judge.summary()}
    if judge is not None:
        (out / "flakes.json").write_text(json.dumps(judge.records(), indent=2, ensure_ascii=False) + "\n",
                                         encoding="utf-8")
    if entries is not None:
        with open(out / "unapplied.jsonl", "w", encoding="utf-8") as f:
            for directory in args.packages:
                for entry, why in unapplied[directory]:
                    line = {"directory": directory, "listed": entry, "why": why}
                    f.write(json.dumps(line, ensure_ascii=False) + "\n")
    if args.sites_only:
        with open(out / "chosen.jsonl", "w", encoding="utf-8") as f:
            for directory in args.packages:
                for site in chosen[directory] if directory in runs else []:
                    f.write(json.dumps(site, ensure_ascii=False) + "\n")
    (out / "summary.json").write_text(
        json.dumps({"operator_set": operator_set, "set": run_set, "selection": choice.selection(args),
                    **({"changed": changes} if changes is not None else {}),
                    **({"kill_matrix": True} if args.matrix else {}), "packages": summaries, **flakes},
                   indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    text = report(operator_set, run_set, summaries, records)
    if entries is not None and not args.sites_only:
        text += "\n".join(["", *choice.listed_report(args.packages, records, unapplied)])
    if judge is not None:
        text = text.rstrip("\n") + "\n\n" + "\n".join(judge.report_lines())
    if changes is not None:
        ran = None if args.sites_only else sum(len(chosen[directory]) for directory in runs)
        text = "\n".join(changed.header(changes, args.set, ran, args.shard is not None)
                         + ([text] if args.packages else []))
    (out / "report.md").write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
