#!/usr/bin/env python3
"""The kill matrix of the mutation runner: for each mutant, every test that
kills it (CONTRIBUTING.md, "Mutation runner", "The kill matrix").

In kill-matrix mode (`run.py --matrix`), each mutant of a package runs once
against the tests of the package and of all its importers that build on
wasm-gc (importers.py) together, whichever would kill it first, with no
early stop: not the package's own tests first and its importers' tests
only for the survivors, as a run without the mode goes. Each test that
fails is confirmed on its own (confirm.py): it is credited with the kill
only if it fails again with the mutant on and passes with it off. Each
record then lists every test that kills its mutant, with the test's
package and layer, and the runner writes the matrix per package into
<out>/matrix/<package directory>.json:

  version, package, directory, operator_set, set, backend
                 the matrix's format (1), the package, its directory, the
                 operator set and the set that ran, and the backend;
  packages       the packages whose tests ran, the package first;
  native_only    its importers that build only natively, whose tests did
                 not run;
  tests          every test that ran, in moon's order, as moon's outline
                 lists them: its name in the matrix ("test"), package,
                 file, line, index in the file, name and layer;
  mutants        each mutant in the run's order: its id, its outcome, the
                 tests that kill it, by their names in the matrix, and,
                 for a duplicate, the mutant it compiles as (duplicate_of).

A test's name in the matrix is its package, `/` and its file, then `:` and
its name, or `#` and its index in the file for a test with no name. A
test's layer is "in-process" or "e2e", from the lowest: removal rule (A)
counts only the kills of tests in the same layer as the test removed or a
lower one. A time-out names no test: the run stops whole at its limit, so
which test would have failed is not known.

usage: python3 scripts/mutation/matrix.py alone [--none] <matrix>...
       python3 scripts/mutation/matrix.py kills [--test <test>]...
           [--package <package>]... [--without] [--layer in-process|e2e]
           <matrix>...
       python3 scripts/mutation/matrix.py draw --seed <run ID> [--base <commit>]
           [--size <n>] [--root <dir>] <matrix>...

<matrix> is a matrix's file, or a run's output directory, whose matrix/
holds one per package. Several may be given, and a test is the same test
in each. Each command prints JSON lines.

  alone    the tests that alone kill some mutant, each with those mutants
           ("alone"); with --none, the other tests instead, each with the
           mutants it kills together with other tests ("kills").
  kills    each mutant's outcome as if only a set of tests had run: the
           tests --test names and the tests of the packages --package
           names, every test when neither is given, or every other test
           with --without; with --layer, only those of the set in that
           layer or a lower one. A mutant that the matrix holds as killed
           survives unless a test of the set kills it. Each line gives the
           mutant's outcome then ("outcome"), its outcome in the matrix
           ("matrix") and the tests of the set that kill it. It also
           prints, on standard error, how many of the killed mutants the
           set kills.
  draw     the tests of a snapshot audit (CONTRIBUTING.md, "Snapshot
           audits"): <n> (10 unless given, or all when there are fewer)
           of the tests that alone kill some mutant, at least half of them
           from the work's tests, those whose block holds a line that
           differs from <commit> (d953f320, where the test review began,
           unless given). The seed is the run ID of the kill-matrix run on
           Actions, which no agent can know before the run. A test's
           block runs from the `///|` at or before its line to the line
           before the next `///|`, in its file as HEAD of <dir> (the
           current directory unless given) has it; a line that differs is
           one that `git diff -U0 <commit> HEAD` adds or changes, or the
           line at which it deletes some. So <dir> is a checkout of the
           commit the run ran on. The draw: the tests sorted by their
           names in the matrix; random.Random(<run ID>), with the seed as
           text, samples half of <n>, rounded up, of the work's tests (all
           of them when there are fewer), then, the same generator going
           on, the rest of the <n> from every test not yet drawn. Each
           line, in the order of the draw, is the test as the matrix lists
           it, with its file in <dir> ("path"), whether it is the work's
           ("work") and the mutants it alone kills ("alone"). It also
           prints, on standard error, how many tests alone kill some
           mutant and how many of them are the work's.

A duplicate counts as the mutant it compiles as, when the same matrix
holds that one. The tool exits with 0 when it answered, and with 1 when a
file is no kill matrix, a test or package given is in none, or, for draw,
a test's file or line is not in HEAD of <dir> or git cannot answer.
"""

import argparse
import json
import math
import posixpath
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

import changed
import compare

BACKEND = "wasm-gc"
# The version of the format of a matrix's file.
VERSION = 1
# How long moon may take to list the tests it would run: it builds nothing,
# so this only stops one that hangs.
OUTLINE_LIMIT_S = 600
# One test in moon's outline: its number, its package, its file and line,
# its index in the file, and its name, if it has one, with each `\` and `"`
# escaped by a `\`.
OUTLINE = re.compile(r'^\s*\d+\. (\S+) (\S+):(\d+) index=(\d+)(?: name="(.*)")?$')
# The layers of tests, from the lowest: in-process tests of a package's
# public interface, and e2e tests, which run the binary over real sockets
# (CONTRIBUTING.md, "What makes a good test").
LAYERS = ("in-process", "e2e")
# The last part of the name of the package whose tests are e2e tests.
E2E = "e2e"
# The commit of main at which the test review began (#275): a snapshot
# audit draws at least half of its tests from those that the work added
# or changed since.
WORK_BASE = "d953f320e0bb4fad15352224d01c365a02c0ab79"
# How many tests a snapshot audit draws: about ten of a package's.
AUDIT_SIZE = 10
# A module's name in its moon.mod or moon.mod.json.
MODULE_NAME = re.compile(r'^\s*"?name"?\s*[=:]\s*"([^"]+)"', re.MULTILINE)
# A hunk of a diff without context: where its lines start in the new file,
# and how many there are.
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", re.MULTILINE)


def layer(package):
    """The layer of a package's tests."""
    return "e2e" if package.rsplit("/", 1)[-1] == E2E else "in-process"


def key(test):
    """A test as both moon's outline and its failures name it."""
    return test["package"], test["file"], test["index"], test["name"]


def test_id(test):
    """A test's name in the matrix: its package, `/`, its file, then `:`
    and its name, or, for a test that has none, `#` and its index in the
    file. A name stays when other tests of its file come or go; an index
    may not, but moon tells a test with no name apart by nothing else."""
    where = f"{test['package']}/{test['file']}"
    return f"{where}:{test['name']}" if test["name"] else f"{where}#{test['index']}"


def unescaped(text):
    """A test's name as moon's outline prints it, without the outline's
    escapes: as moon's failures name the test, and as its file writes it
    between the quotes."""
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and text[i + 1 : i + 2] in ("\\", '"'):
            out.append(text[i + 1])
            i += 2
        elif text[i] in '\\"':
            raise ValueError(f"an escape moon's outline does not write: {text}")
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def outline(worker, packages, error):
    """Every test that moon runs for packages in a worker's tree, in moon's
    order, each with its package, file, line, index, name and layer."""
    selected = [option for name in packages for option in ("-p", name)]
    command = [*worker.moon, "test", "--target", BACKEND, *selected, "--target-dir", str(worker.target),
               "--outline"]
    try:
        result = subprocess.run(command, cwd=worker.tree, capture_output=True, text=True, timeout=OUTLINE_LIMIT_S)
    except subprocess.TimeoutExpired as problem:
        raise error(f"moon took over {OUTLINE_LIMIT_S} s to list the tests of {', '.join(packages)}") from problem
    if result.returncode != 0:
        raise error(f"moon cannot list the tests of {', '.join(packages)}:\n{result.stdout}{result.stderr}")
    tests = []
    for line in result.stdout.splitlines():
        match = OUTLINE.match(line)
        if not match:
            continue
        package, file, number, index, name = match.groups()
        try:
            name = unescaped(name or "")
        except ValueError as problem:
            raise error(f"cannot read moon's outline of {package}: {problem}") from problem
        tests.append({"package": package, "file": file, "line": int(number), "index": int(index), "name": name,
                      "layer": layer(package)})
    names = [test_id(t) for t in tests]
    doubled = sorted({n for n in names if names.count(n) > 1})
    if doubled:
        raise error(f"moon lists two tests by one name, which a kill matrix cannot tell apart: {', '.join(doubled)}")
    return tests


def run_package(workers, package, directory, found, native_only, sites, mutants, log, run_tests, outcome_counts,
                error):
    """Runs the chosen mutants of one package against the tests of the
    package and of its importers that build on wasm-gc (found) together:
    its records, each listing every test that kills its mutant, with the
    test's layer, and its summary's counts. run_tests, outcome_counts and
    error are the runner's (run.py)."""
    everyone = [package, *found]
    tests = outline(workers[0], everyone, error)
    records, baseline, limit, self_test = run_tests(
        workers, f"the tests of {package} and its importers ({', '.join(found) or 'none'})", everyone, mutants, log,
        f"{package}: {len(sites)} sites, a kill matrix with the tests of {', '.join(everyone)}", own=directory,
        with_self_test=bool(mutants))
    if baseline["tests"] != len(tests):
        raise error(f"moon lists {len(tests)} tests of {', '.join(everyone)}, but ran {baseline['tests']}")
    place = {key(t): n for n, t in enumerate(tests)}
    for record in records:
        # The run tested every package's tests; the record is the package's.
        record["package"] = package
        tested = record["outcome"] in ("killed", "timed out", "survived", "unconfirmed")
        record["importers"] = list(found) if tested else []
        for test in record["killing_tests"]:
            if key(test) not in place:
                raise error(f"{record['id']}: {test} killed it, but moon does not list it")
            test["layer"] = layer(test["package"])
        record["killing_tests"].sort(key=lambda t: place[key(t)])
    summary = {
        "backend": BACKEND,
        "baseline": baseline,
        "limit_s": round(limit, 3),
        **outcome_counts(records),
        **compare.counts(records),
        "matrix": counts({"packages": everyone, "native_only": native_only, "tests": tests}, records),
        **({"self_test": self_test} if self_test is not None else {}),
    }
    return records, summary


def entries(records):
    """The mutants of a package's matrix, from its records: each one's id,
    outcome and killing tests, and the mutant it compiles as, for a
    duplicate."""
    found = []
    for record in records:
        entry = {"id": record["id"], "outcome": record["outcome"],
                 "killing_tests": [test_id(t) for t in record["killing_tests"]]}
        if record["outcome"] == "duplicate":
            entry["duplicate_of"] = record["duplicate_of"]
        found.append(entry)
    return found


def counts(found, records):
    """What a package's summary says of its matrix: the packages whose
    tests ran and those that build only natively, every test that ran, and
    how many of them kill some mutant, how many alone kill one, and how
    many mutants each package's tests kill."""
    mutants = entries(records)
    by = {}
    for record in records:
        if record["outcome"] == "killed":
            for package in {t["package"] for t in record["killing_tests"]}:
                by[package] = by.get(package, 0) + 1
    return {
        "packages": list(found["packages"]),
        "native_only": list(found["native_only"]),
        "tests": list(found["tests"]),
        "killing": len({t for m in mutants if m["outcome"] == "killed" for t in m["killing_tests"]}),
        "alone": len(alone(mutants)),
        "killed_by": dict(sorted(by.items())),
    }


def merged(founds, records, error):
    """What the summary of a run in shards says of a package's matrix,
    from what its shards' summaries say (scripts/mutation/merge.py): the
    same packages and tests in each, and the counts taken again from all
    its records."""
    first = founds[0]
    for found in founds[1:]:
        if (found["packages"], found["native_only"], found["tests"]) != (
                first["packages"], first["native_only"], first["tests"]):
            raise error(f"the shards' kill matrices of {first['packages'][0]} hold different tests")
    return counts(first, records)


def report_lines(summary):
    """The lines of the report that give a package's kill matrix: the tests
    that ran, how many of them kill some mutant and alone kill one, and
    how many mutants each package's tests kill."""
    found = summary.get("matrix")
    if found is None:
        return []
    packages = found["packages"]
    listed = packages[0] if len(packages) == 1 else ", ".join(packages[:-1]) + f" and {packages[-1]}"
    out = [f"Kill matrix: each mutant ran against the {len(found['tests'])} tests of {listed} at once, with no early"
           " stop.",
           f"- {found['killing']} of these tests kill some mutant, and {found['alone']} of them alone kill some"
           " mutant."]
    if found["killed_by"]:
        out += ["- Mutants killed by the tests of each package: "
                + ", ".join(f"{name} {n}" for name, n in found["killed_by"].items()) + "."]
    if found["native_only"]:
        out += ["- Importers that build only natively, whose tests did not run: "
                + ", ".join(found["native_only"]) + "."]
    return out + [""]


def write(out, operator_set, chosen, summaries, records):
    """Writes the kill matrix of each package that ran in kill-matrix mode
    into out/matrix/<package directory>.json, after removing what an
    earlier run wrote there."""
    folder = out / "matrix"
    shutil.rmtree(folder, ignore_errors=True)
    for summary in summaries:
        found = summary.get("matrix")
        if found is None:
            continue
        matrix = {
            "version": VERSION,
            "package": summary["package"],
            "directory": summary["directory"],
            "operator_set": operator_set,
            "set": chosen,
            "backend": summary["backend"],
            "packages": found["packages"],
            "native_only": found["native_only"],
            "tests": [dict(test=test_id(t), **t) for t in found["tests"]],
            "mutants": entries([r for r in records if r["package"] == summary["package"]]),
        }
        path = folder / f"{summary['directory']}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(dumps(matrix), encoding="utf-8")


def dumps(matrix):
    """A matrix as JSON, with one test and one mutant on each line."""
    lines = []
    for name, value in matrix.items():
        if name in ("tests", "mutants") and value:
            items = ",\n".join(f"    {json.dumps(v, ensure_ascii=False)}" for v in value)
            lines.append(f"  {json.dumps(name)}: [\n{items}\n  ]")
        else:
            lines.append(f"  {json.dumps(name)}: {json.dumps(value, ensure_ascii=False)}")
    return "{\n" + ",\n".join(lines) + "\n}\n"


class MatrixError(Exception):
    """What stops the tool: a file that is no kill matrix, a test or a
    package that the matrices do not hold, or, for a draw, a test that the
    checkout does not hold where the matrix says, or git that cannot
    answer."""


def read(paths):
    """The kill matrices of paths: each a matrix's file, or a directory, a
    run's output whose matrix/ holds them or one that holds them itself."""
    matrices = []
    for path in map(Path, paths):
        if path.is_dir():
            files = sorted((path / "matrix" if (path / "matrix").is_dir() else path).rglob("*.json"))
            if not files:
                raise MatrixError(f"{path} holds no kill matrix")
        else:
            files = [path]
        for file in files:
            try:
                matrix = json.loads(file.read_text(encoding="utf-8"))
            except (OSError, ValueError) as problem:
                raise MatrixError(f"cannot read {file}: {problem}") from problem
            if not isinstance(matrix, dict) or matrix.get("version") != VERSION or "mutants" not in matrix:
                raise MatrixError(f"{file} is no kill matrix of version {VERSION}")
            matrices.append(matrix)
    return matrices


def resolved(mutants):
    """A matrix's mutants, each duplicate with the outcome and the killing
    tests of the mutant it compiles as, when the matrix holds that one."""
    by_id = {m["id"]: m for m in mutants}
    out = []
    for mutant in mutants:
        first = by_id.get(mutant.get("duplicate_of"))
        out.append(dict(mutant, outcome=first["outcome"], killing_tests=first["killing_tests"]) if first else mutant)
    return out


def alone(mutants):
    """The tests that alone kill some of a matrix's mutants, each with
    those mutants' ids, in the order of the mutants."""
    found = {}
    for mutant in resolved(mutants):
        if mutant["outcome"] == "killed" and len(mutant["killing_tests"]) == 1:
            found.setdefault(mutant["killing_tests"][0], []).append(mutant["id"])
    return found


def alone_in(matrices):
    """The tests that alone kill some mutant of any of the matrices, each
    with those mutants' ids, matrix after matrix."""
    found = {}
    for matrix in matrices:
        for name, mutants in alone(matrix["mutants"]).items():
            found.setdefault(name, []).extend(mutants)
    return found


def modules(root):
    """The modules of the workspace at root, by name: each one's directory
    relative to root, from moon.work's members, or the root's own module
    when there is no moon.work."""
    found = {}
    for directory in changed.members(root):
        for file in ("moon.mod", "moon.mod.json"):
            if (directory / file).is_file():
                name = MODULE_NAME.search((directory / file).read_text(encoding="utf-8"))
                if name:
                    found[name.group(1)] = directory.relative_to(root.resolve()).as_posix()
                break
    return found


def directory_of(package, found):
    """The directory of a package, relative to the workspace, from the
    modules found: smock/smock/<directory> in the root module, and
    smock/<name> for a protocol module in <name>/."""
    names = [n for n in found if package == n or package.startswith(n + "/")]
    if not names:
        raise MatrixError(f"no module of the workspace holds the package {package}")
    name = max(names, key=len)
    return posixpath.normpath(posixpath.join(found[name], package[len(name) + 1 :]))


def git(root, *args):
    """The output of a git command in root."""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise MatrixError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def changed_lines(root, base, path):
    """The lines of HEAD's file at path that differ from base: the lines
    added or changed, and the line at which a deletion sits."""
    out = git(root, "diff", "--no-color", "--no-ext-diff", "-U0", base, "HEAD", "--", path)
    lines = set()
    for hunk in HUNK.finditer(out):
        start, count = int(hunk.group(1)), int(hunk.group(2) or "1")
        lines.update(range(start, start + max(count, 1)))
    return lines


def block(lines, line):
    """The lines, counted from 1, of the top-level block of a file's lines
    that holds line: from the `///|` at or before it to the line before
    the next `///|`."""
    first = line
    while first > 1 and not lines[first - 1].startswith("///|"):
        first -= 1
    last = line
    while last < len(lines) and not lines[last].startswith("///|"):
        last += 1
    return range(first, last + 1)


def drawn_tests(root, matrices, seed, base, size):
    """The tests of a snapshot audit (CONTRIBUTING.md, "Snapshot audits"):
    size of those that alone kill some mutant of the matrices (all, when
    there are fewer), at least half of them from the work's tests, those
    whose block in HEAD's file holds a line that differs from base. Each is
    the test as the matrices list it, with its file in the workspace
    ("path"), whether it is the work's ("work"), and the mutants it alone
    kills ("alone"), in the order of the draw; and how many tests alone
    kill some mutant, and how many of them are the work's.

    The draw: the tests sorted by their names in the matrix;
    random.Random(seed), with the seed as text, samples half of size,
    rounded up, of the work's tests (all of them, when there are fewer),
    and then, the same generator going on, the rest of size from every test
    not yet drawn."""
    tests = every_test(matrices)
    lone = alone_in(matrices)
    found = modules(root)
    files = {}
    chosen = {}
    for name in lone:
        test = tests[name]
        path = posixpath.join(directory_of(test["package"], found), test["file"])
        if path not in files:
            text = git(root, "show", f"HEAD:./{path}").split("\n")
            files[path] = (text, changed_lines(root, base, path))
        text, changed_here = files[path]
        if not 1 <= test["line"] <= len(text):
            raise MatrixError(f"HEAD's {path} has no line {test['line']}, where the matrix puts {name}: is the"
                              " checkout the commit that the kill-matrix run ran on?")
        work = any(n in changed_here for n in block(text, test["line"]))
        chosen[name] = dict(test, path=path, work=work, alone=lone[name])
    ids = sorted(chosen)
    work = [n for n in ids if chosen[n]["work"]]
    size = min(size, len(ids))
    generator = random.Random(seed)
    drawn = generator.sample(work, min(len(work), math.ceil(size / 2)))
    rest = [n for n in ids if n not in drawn]
    drawn += generator.sample(rest, size - len(drawn))
    return [chosen[n] for n in drawn], len(ids), len(work)


def every_test(matrices):
    """The tests of the matrices, by name, each once, in their order."""
    found = {}
    for matrix in matrices:
        for test in matrix["tests"]:
            found.setdefault(test["test"], test)
    return found


def chosen_tests(tests, names, packages, without, lowest):
    """The names of the tests of a set: those named and the tests of the
    packages given (every test when neither is given), or, without, every
    other test; and of those, only the tests in the layer lowest or a lower
    one, when lowest is given."""
    unknown = [n for n in names if n not in tests]
    unknown += [p for p in packages if not any(t["package"] == p for t in tests.values())]
    if unknown:
        raise MatrixError("".join(f"no test of the matrix is {n}\n" for n in unknown).rstrip())
    given = {n for n, t in tests.items() if n in names or t["package"] in packages}
    if not names and not packages:
        given = set(tests)
    kept = set(tests) - given if without else given
    if lowest:
        kept = {n for n in kept if LAYERS.index(tests[n]["layer"]) <= LAYERS.index(lowest)}
    return kept


def with_tests(matrix, kept):
    """Each mutant of a matrix as if only the tests kept had run: a killed
    one survives unless one of them kills it. Its outcome then, its outcome
    in the matrix and the tests kept that kill it. A time-out names no test,
    so it stays one."""
    out = []
    for mutant in resolved(matrix["mutants"]):
        tests = [t for t in mutant["killing_tests"] if t in kept]
        outcome = mutant["outcome"]
        if outcome == "killed" and not tests:
            outcome = "survived"
        line = {"package": matrix["package"], "id": mutant["id"], "outcome": outcome, "matrix": mutant["outcome"],
                "killing_tests": tests}
        if "duplicate_of" in mutant:
            line["duplicate_of"] = mutant["duplicate_of"]
        out.append(line)
    return out


def main():
    parser = argparse.ArgumentParser(description="Read the kill matrices that the mutation runner wrote.")
    commands = parser.add_subparsers(dest="command", required=True)
    lone = commands.add_parser("alone", help="the tests that alone kill some mutant, each with those mutants")
    lone.add_argument("--none", action="store_true",
                      help="the tests that alone kill no mutant instead, each with the mutants it kills")
    lone.add_argument("matrices", nargs="+", help="matrix files, or runs' output directories")
    kills = commands.add_parser("kills", help="each mutant's outcome as if only a set of tests had run")
    kills.add_argument("--test", action="append", default=[], help="a test of the set, by its name in the matrix")
    kills.add_argument("--package", action="append", default=[], help="a package whose tests are in the set")
    kills.add_argument("--without", action="store_true", help="the set is every test but those given")
    kills.add_argument("--layer", choices=LAYERS, help="only the set's tests in this layer or a lower one count")
    kills.add_argument("matrices", nargs="+", help="matrix files, or runs' output directories")
    drawing = commands.add_parser("draw", help="the tests of a snapshot audit, drawn among those that alone kill"
                                               " some mutant")
    drawing.add_argument("--seed", required=True,
                         help="the run ID of the kill-matrix run on Actions, which no agent knows before the run")
    drawing.add_argument("--base", default=WORK_BASE,
                         help="the work's tests are those whose block differs from this commit (where the test"
                              " review began unless given)")
    drawing.add_argument("--size", type=int, default=AUDIT_SIZE, help=f"how many to draw ({AUDIT_SIZE} unless given)")
    drawing.add_argument("--root", default=".", help="the workspace, checked out at the commit the run ran on")
    drawing.add_argument("matrices", nargs="+", help="matrix files, or runs' output directories")
    args = parser.parse_args()
    try:
        matrices = read(args.matrices)
        tests = every_test(matrices)
        if args.command == "draw":
            drawn, lone, work = drawn_tests(Path(args.root), matrices, args.seed, args.base, args.size)
            for test in drawn:
                print(json.dumps(test, ensure_ascii=False))
            print(f"{lone} tests alone kill some mutant, {work} of them the work's (changed since {args.base}); drew"
                  f" {len(drawn)} with the seed {args.seed!r}.", file=sys.stderr)
            return
        if args.command == "alone":
            found = alone_in(matrices)
            for name, test in tests.items():
                if args.none and name not in found:
                    killing = [m["id"] for x in matrices for m in resolved(x["mutants"])
                               if m["outcome"] == "killed" and name in m["killing_tests"]]
                    print(json.dumps(dict(test, kills=killing), ensure_ascii=False))
                elif not args.none and name in found:
                    print(json.dumps(dict(test, alone=found[name]), ensure_ascii=False))
            return
        kept = chosen_tests(tests, args.test, args.package, args.without, args.layer)
        lines = [line for matrix in matrices for line in with_tests(matrix, kept)]
        for line in lines:
            print(json.dumps(line, ensure_ascii=False))
        before = sum(1 for line in lines if line["matrix"] == "killed")
        after = sum(1 for line in lines if line["outcome"] == "killed")
        print(f"{len(kept)} of {len(tests)} tests kill {after} of the {before} mutants that the matrices hold as"
              f" killed; {before - after} survive them.", file=sys.stderr)
    except MatrixError as error:
        print(f"matrix: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
