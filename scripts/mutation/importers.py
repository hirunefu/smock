#!/usr/bin/env python3
"""Finds the packages whose tests give a package's mutants kill credit
besides its own (CONTRIBUTING.md, "Kill credit for a pure package"): the
packages that import it, directly or through other packages, on wasm-gc.
The mutation runner (scripts/mutation/run.py) runs the survivors of a
package's own tests again with theirs, and merges what they find into its
records, summary and report with the functions below.

usage: python3 scripts/mutation/importers.py [--root <dir>] [--moon <moon>]
           <package directory>...

<package directory> is relative to <root>, the workspace or module: the
current directory unless it is given. For each package, it prints one
line, as JSON: the package's name, its importers that build on wasm-gc
("importers") and those that build only natively ("native_only"), each
sorted by name.

The importers come from the build's own package graph,
`moon tree --package --json --target wasm-gc`, never from a list kept by
hand. A package imports another directly when its source or its tests
import it. It imports it through other packages when it imports, in its
source or its tests, a package whose source imports it, directly or
through other packages. A package's tests never pass on what they import
to the packages that import it, since those never build its tests.

Whether an importer builds on wasm-gc is moon's to say: the graph lists
every package of the workspace on every backend, and
`moon test --target wasm-gc -p <importer> --dry-run` fails for one whose
supported_targets leave wasm-gc out, as smock's server, defdir, schema,
protobuf-conformance and e2e do. A pure package's verdict is taken on
wasm-gc, so their tests give it no credit.
"""

import argparse
import json
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

BACKEND = "wasm-gc"
# What moon says when a package selected for a test leaves the backend out.
UNSUPPORTED = "do not support target backend"


class ImportersError(Exception):
    """What stops the search: a package graph that moon cannot give, or a
    package that is not in it."""


def package_graph(moon, cwd, target_dir):
    """The build's package graph on wasm-gc, as moon tree gives it: each
    package's name, whether it is one of the workspace's own, and each
    import, with the kinds of code that make it (source, blackbox-test,
    whitebox-test)."""
    command = [*moon, "tree", "--package", "--json", "--target", BACKEND, "--target-dir", str(target_dir)]
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    try:
        graph = json.loads(result.stdout)
    except ValueError:
        graph = None
    if result.returncode != 0 or not isinstance(graph, dict) or graph.get("status") != "success":
        raise ImportersError(f"moon tree gives no package graph in {cwd}:\n{result.stdout}{result.stderr}")
    names = [f"{n['module']}/{n['rel']}" if n.get("rel") else n["module"] for n in graph["nodes"]]
    local = [n.get("source", {}).get("kind") == "local" for n in graph["nodes"]]
    edges = [(e["from"], e["to"], set(e["kinds"])) for e in graph["edges"]]
    return names, local, edges


def importers_of(graph, package):
    """The workspace's packages that import package, directly or through
    other packages, sorted by name."""
    names, local, edges = graph
    if package not in names:
        raise ImportersError(f"the build's package graph has no package {package}")
    target = names.index(package)
    by_source, by_any = {}, {}
    for importer, imported, kinds in edges:
        if not local[importer]:
            continue
        by_any.setdefault(imported, set()).add(importer)
        if "source" in kinds:
            by_source.setdefault(imported, set()).add(importer)
    # The package and every package whose source reaches it.
    reached, stack = {target}, [target]
    while stack:
        for importer in by_source.get(stack.pop(), ()):
            if importer not in reached:
                reached.add(importer)
                stack.append(importer)
    found = set(reached)
    for package_index in reached:
        found |= by_any.get(package_index, set())
    found.discard(target)
    return sorted(names[i] for i in found)


def builds_on_wasm_gc(moon, cwd, target_dir, package):
    """Whether moon would build and run a package's tests on wasm-gc."""
    command = [*moon, "test", "--target", BACKEND, "-p", package, "--dry-run", "--target-dir", str(target_dir)]
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if UNSUPPORTED in result.stdout + result.stderr:
        return False
    raise ImportersError(f"moon cannot say whether {package} builds on {BACKEND}:\n{result.stdout}{result.stderr}")


def find(moon, cwd, target_dir, package):
    """A package's importers that build on wasm-gc, and those that build
    only natively, each sorted by name."""
    found = importers_of(package_graph(moon, cwd, target_dir), package)
    on_wasm_gc = [p for p in found if builds_on_wasm_gc(moon, cwd, target_dir, p)]
    return on_wasm_gc, [p for p in found if p not in on_wasm_gc]


def credit(packages, native_only):
    """What a package's summary says of its importers before any of their
    tests runs."""
    return {"packages": list(packages), "native_only": list(native_only), "reran": 0, "killed": 0,
            "killed_by": {}}


def merge(record, again, packages, summary):
    """Takes into a survivor's record what its run with the importers'
    tests found (again, that run's record), and counts it in the summary
    of the importers."""
    record["importers"] = list(packages)
    record["timings"]["importers"] = again["timings"]
    if "ended" in again:
        record.setdefault("ended", {})["importers"] = again["ended"]
    summary["reran"] += 1
    if again["outcome"] == "survived":
        # Its importers' tests that failed but give no kill credit.
        if again.get("no_credit"):
            record["no_credit"] = record.get("no_credit", []) + again["no_credit"]
        # A failure of their tests that named no test and did not repeat
        # (confirm.py): the record says so, in place of what its own tests
        # left.
        if "first_outcome" in again:
            replace(record, again, ("message", "confirmation", "first_outcome"))
        return
    if again["outcome"] != "unconfirmed":
        record.pop("diff", None)
    record.update(outcome=again["outcome"], killing_tests=again["killing_tests"])
    replace(record, again, ("message", "confirmation", "first_outcome", "failed_first"))
    if "no_credit" in again:
        record["no_credit"] = again["no_credit"]
    # A confirmed time-out counts as killed.
    if again["outcome"] in ("killed", "timed out"):
        summary["killed"] += 1
        for name in sorted({t["package"] for t in again["killing_tests"] if t.get("package")}):
            summary["killed_by"][name] = summary["killed_by"].get(name, 0) + 1
        summary["killed_by"] = dict(sorted(summary["killed_by"].items()))


def replace(record, again, fields):
    """Gives a record the fields of its importers' run (again) in place of
    those its own tests' run left: each field again has, and none that it
    lacks."""
    for field in fields:
        if field in again:
            record[field] = again[field]
        else:
            record.pop(field, None)


def own_records(records):
    """A package's records as its own tests left them: a mutant that its
    importers' tests ran again had survived its own tests."""
    return [dict(r, outcome="survived") if r.get("importers") else r for r in records]


def merge_credits(credits):
    """What a package's summary says of its importers in a run in shards
    (scripts/mutation/merge.py), from what each shard's summary says: the
    same importers, the survivors they ran again and killed summed over
    the shards, and the run without a mutant and the time limit of the
    first shard whose importers' tests ran."""
    merged = credit(credits[0]["packages"], credits[0]["native_only"])
    for found in credits:
        merged["reran"] += found["reran"]
        merged["killed"] += found["killed"]
        for name, n in found["killed_by"].items():
            merged["killed_by"][name] = merged["killed_by"].get(name, 0) + n
        if "baseline" in found and "baseline" not in merged:
            merged.update(baseline=found["baseline"], limit_s=found["limit_s"])
    merged["killed_by"] = dict(sorted(merged["killed_by"].items()))
    return merged


def report_lines(summary):
    """The lines of the report that give a package's counts with its own
    tests alone, its importers, and what their tests killed."""
    own, found = summary.get("own"), summary.get("importers")
    if own is None or found is None:
        return []
    score = "none" if own["score"] is None else f"{own['score']:.1%}"
    out = [f"- With its own tests alone: {own['mutants']} mutants, killed {own['killed']}, timed out"
           f" {own['timed_out']}, survived {own['survived']}, unviable {own['unviable']}, score {score}.",
           "- Importers that build on wasm-gc: " + (", ".join(found["packages"]) or "none") + "."]
    if found["native_only"]:
        out += ["- Importers that build only natively, whose tests give no credit: "
                + ", ".join(found["native_only"]) + "."]
    if "baseline" in found:
        out += [f"- Their tests: {found['baseline']['tests']} tests, baseline run {found['baseline']['run_s']:.2f} s,"
                f" time limit {found['limit_s']:.2f} s."]
    if found["packages"]:
        if found["reran"]:
            survivors = "survivor" if found["reran"] == 1 else "survivors"
            by = ", ".join(f"{name} {n}" for name, n in found["killed_by"].items())
            out += [f"- Their tests ran the {found['reran']} {survivors} of its own tests again and killed"
                    f" {found['killed']}" + (f": {by}." if by else ".")]
        else:
            out += ["- No mutant survived its own tests, so their tests did not run."]
    return out + [""]


def main():
    from run import RunnerError, package_name

    parser = argparse.ArgumentParser(description="List the importers of MoonBit packages on wasm-gc.")
    parser.add_argument("--root", default=".", help="the workspace or module")
    parser.add_argument("--moon", default="moon", help="the moon command")
    parser.add_argument("packages", nargs="+", help="package directories, relative to <root>")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    try:
        with tempfile.TemporaryDirectory(prefix="importers-") as target_dir:
            moon = shlex.split(args.moon)
            graph = package_graph(moon, root, target_dir)
            cache = {}
            for directory in args.packages:
                package = package_name(root, directory)
                found = importers_of(graph, package)
                for name in found:
                    if name not in cache:
                        cache[name] = builds_on_wasm_gc(moon, root, target_dir, name)
                print(json.dumps({"package": package, "importers": [p for p in found if cache[p]],
                                  "native_only": [p for p in found if not cache[p]]}))
    except (ImportersError, RunnerError) as error:
        print(f"importers: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
