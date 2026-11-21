"""Native verdicts of the mutation runner (CONTRIBUTING.md, "Mutation
runner", "Native verdicts"). scripts/mutation/run.py takes a pure
package's verdicts on wasm-gc, but wasm-gc traps on an unchecked array
access out of bounds, where the native binary reads on without a sign: a
mutant there can be killed on wasm-gc by the trap alone and survive
natively. So each mutant at a site whose enclosing definition uses an
unchecked array access, which the site finder marks
("unchecked_access"), runs natively as well, once its wasm-gc verdict is
known: with the package's own tests, and, if it survives them, with the
tests of the same importers whose tests ran it on wasm-gc. Kills and
time-outs are confirmed natively too. The record gives both verdicts
("verdicts").

Native verdicts are taken on CI's amd64 runner: there a mutant killed on
wasm-gc and surviving natively is a survivor, until a test kills it
natively or an exclusion covers it (UB-NATIVE). One machine is the
reference so that a verdict can be reproduced: natively, an access out
of bounds is undefined behaviour, and what it does can change with the
machine and with the C compiler that built the test program. amd64 is
that machine because its native builds are about six times faster than
arm64's (#276). The native verdict decides on any amd64 machine
(DECIDING), so that a laptop's records read as CI's would, but a verdict
taken off CI is for information. On arm64 the native verdict is recorded
and not used, and the wasm-gc verdict counts.

A package that builds only natively, which moon refuses to test on
wasm-gc, runs wholly natively: every mutant, the runs without a mutant
and the self-test, with its own in-process tests.

Native builds take no C compiler, archiver or wrapper from the
environment: before the first, the runner unsets the variables of moon's
that would give it one (C_VARIABLES), and the summary names those it
unset. The runner sets none, so the mutation copy builds as moon builds
it by default.

Natively, each mutant is built on its own (moon test --build-only, as on
wasm-gc), not in a schema build: on amd64 a native rebuild after one
mutant took 5.3 s in engine, the largest package (#276), and the marked
sites are few.
"""

import copy
import os
import platform
import resource

import importers

BACKEND = "native"
# The site finder's mark on a site whose definition uses an unchecked
# array access.
MARK = "unchecked_access"
# moon's variables that give its native builds another C compiler, archiver
# or compiler wrapper (moon 0.1.20261104 reads these three).
C_VARIABLES = ("MOON_AR", "MOON_CC", "MOON_CC_WRAPPER")
# The machines whose native verdict decides, as Python names amd64, the
# architecture of CI's runner that takes native verdicts.
DECIDING = ("x86_64", "amd64")
# The wasm-gc outcomes of a mutant whose tests ran: those that also run
# natively. A mutant that does not build, or that the compiler's output
# shows equivalent or a duplicate, runs no tests on either backend.
RAN = ("killed", "timed out", "survived", "unconfirmed")
# The outcomes of a verdict, as the summary counts them.
OUTCOMES = ("killed", "timed out", "survived", "unconfirmed")
# The fields of a record that make one backend's verdict.
VERDICT = ("outcome", "killing_tests", "timings", "ended", "importers", "confirmation", "first_outcome",
           "failed_first", "no_credit", "message")

# The variables this run unset, in the order it unset them.
UNSET = []


def machine():
    """The machine the runner runs on, as Python names it."""
    return platform.machine()


def decides(name):
    """Whether the native verdict taken on a machine decides."""
    return name.lower() in DECIDING


def unset_c_variables():
    """Unsets moon's variables for another C compiler, archiver or wrapper
    in the runner's environment, which every moon it starts inherits."""
    for name in C_VARIABLES:
        if name in os.environ:
            del os.environ[name]
            UNSET.append(name)


def dump_no_core():
    """Sets the runner's limit on core dumps, which every moon it starts
    and every test program inherits, to none: natively, a mutant that
    aborts or reads out of bounds often stops the test program, which would
    otherwise dump its core into the worker's tree."""
    _, hard = resource.getrlimit(resource.RLIMIT_CORE)
    resource.setrlimit(resource.RLIMIT_CORE, (0, hard))


def twins(workers):
    """Workers that build and run natively in the same trees and target
    directories as the given ones (moon keeps each backend's builds apart
    there)."""
    unset_c_variables()
    dump_no_core()
    found = []
    for worker in workers:
        twin = copy.copy(worker)
        twin.backend = BACKEND
        found.append(twin)
    return found


def workers_for(workers, package):
    """The workers that run a package: the given ones, on wasm-gc, or, when
    moon refuses to test the package on wasm-gc, their native twins. Raises
    importers.ImportersError when moon cannot say."""
    first = workers[0]
    if importers.builds_on_wasm_gc(first.moon, first.tree, first.target, package):
        return workers
    return twins(workers)


def combine(record, again, name):
    """Takes a mutant's native verdict (again, the record of its native
    runs, taken on the machine named) into its record, beside its wasm-gc
    verdict. Where the native verdict decides, it becomes the record's
    outcome, with its tests, its timings and its diff."""
    wasm_gc = {field: record[field] for field in VERDICT if field in record}
    native = {field: again[field] for field in VERDICT if field in again}
    native["machine"] = name
    record["verdicts"] = {"wasm-gc": wasm_gc, "native": native}
    if not decides(name):
        return
    for field in VERDICT:
        record.pop(field, None)
    record.update({field: value for field, value in native.items() if field != "machine"})
    record["backend"] = BACKEND
    if "diff" in again:
        record["diff"] = again["diff"]
    else:
        record.pop("diff", None)


def judge(workers, run_tests, package, packages, mutants, records, log):
    """Runs natively the mutants at sites that use an unchecked array
    access whose tests ran on wasm-gc, with the package's own tests, and
    those that survive them with the tests of its importers (packages),
    and takes each native verdict into its record (combine). run_tests is
    the runner's. It gives what the package's summary says of native
    verdicts, as {"native": ...}, or {} when no mutant of the package is
    at such a site."""
    here = machine()
    if workers[0].backend == BACKEND:
        return {"native": {"machine": here, "builds_only_natively": True, "unset": sorted(UNSET)}}
    marked = [i for i, site in enumerate(mutants) if site.get(MARK)]
    if not marked:
        return {}
    running = [i for i in marked if records[i]["outcome"] in RAN]
    summary = {"machine": here, "decides": decides(here)}
    if running:
        natively = twins(workers)
        again, baseline, limit, _ = run_tests(
            natively, f"{package} natively", [package], [mutants[i] for i in running], log,
            f"{package}: mutants at sites that use an unchecked array access, natively on {here}")
        credit = importers.credit(packages, [])
        for record in again:
            record["importers"] = []
        survivors = [k for k, r in enumerate(again) if r["outcome"] == "survived"]
        if packages and survivors:
            more, more_baseline, more_limit, _ = run_tests(
                natively, f"the importers of {package} ({', '.join(packages)}) natively", packages,
                [mutants[running[k]] for k in survivors], log,
                f"{package}: survivors again natively with the tests of {', '.join(packages)}")
            credit.update(baseline=more_baseline, limit_s=round(more_limit, 3))
            for k, record in zip(survivors, more):
                importers.merge(again[k], record, packages, credit)
        for i, record in zip(running, again):
            combine(records[i], record, here)
        summary.update(baseline=baseline, limit_s=round(limit, 3), importers=credit)
    summary.update(counts(records), unset=sorted(UNSET))
    return {"native": summary}


def counts(records):
    """The counts of a package's mutants at sites that use an unchecked
    array access, of those that ran natively, of each native outcome, and
    of those whose native outcome differs from the wasm-gc one."""
    ran = [r["verdicts"] for r in records if "verdicts" in r]
    return {
        "marked": sum(1 for r in records if r.get(MARK)),
        "ran": len(ran),
        "outcomes": {o: sum(1 for v in ran if v["native"]["outcome"] == o) for o in OUTCOMES},
        "differ": sum(1 for v in ran if v["native"]["outcome"] != v["wasm-gc"]["outcome"]),
    }


def merged(entries, records):
    """What a package's summary says of native verdicts in a run in shards
    (scripts/mutation/merge.py), from what each shard's summary says (each
    shard that held such a mutant) and from all the package's records: the
    counts taken again, the importers' counts summed, and the runs without
    a mutant and the time limit of the first shard that ran natively."""
    found = dict(entries[0])
    for field in ("baseline", "limit_s", "importers"):
        found.pop(field, None)
    ran = [e for e in entries if "baseline" in e]
    if ran:
        found.update(baseline=ran[0]["baseline"], limit_s=ran[0]["limit_s"],
                     importers=importers.merge_credits([e["importers"] for e in ran]))
    found["unset"] = sorted({name for e in entries for name in e.get("unset", [])})
    if not found.get("builds_only_natively"):
        found.update(counts(records))
    return found


def report_lines(summary, records):
    """The lines of a package's report on its native verdicts: what ran
    natively and where, the runs without a mutant, the variables unset,
    and the mutants whose verdicts differ between the backends."""
    found = summary.get("native")
    if found is None:
        return []
    out = []
    if found.get("builds_only_natively"):
        out += [f"- It builds only natively, so every mutant ran natively on {found['machine']}, with its own"
                " in-process tests; e2e's tests give no credit in this run."]
    else:
        ran = "all of which" if found["ran"] == found["marked"] else f"{found['ran']} of which"
        verdicts = "1 has another verdict there" if found["differ"] == 1 else \
            f"{found['differ']} have another verdict there"
        out += [f"- Unchecked array access: {found['marked']} mutants at sites whose definition uses one, {ran}"
                f" ran natively on {found['machine']} as well; {verdicts}."
                + (" The native verdict decides here." if found["decides"] else
                   f" On {found['machine']}, the native verdict is recorded, and the wasm-gc verdict counts:"
                   " only amd64's native verdict decides.")]
        if "baseline" in found:
            out += [f"- Natively: {found['baseline']['tests']} tests, baseline run {found['baseline']['run_s']:.2f} s,"
                    f" time limit {found['limit_s']:.2f} s."]
    if found["unset"]:
        listed = found["unset"]
        joined = listed[0] if len(listed) == 1 else ", ".join(listed[:-1]) + " and " + listed[-1]
        out += [f"- The runner unset {joined}, so that its native builds take no C compiler or flags from the"
                " environment."]
    out += [""]
    differ = [r for r in records if "verdicts" in r
              and r["verdicts"]["native"]["outcome"] != r["verdicts"]["wasm-gc"]["outcome"]]
    if differ:
        out += [f"### Verdicts that differ between wasm-gc and native ({len(differ)})", ""]
        out += [f"- `{r['id']}`: wasm-gc {r['verdicts']['wasm-gc']['outcome']}, native"
                f" {r['verdicts']['native']['outcome']} ({r['verdicts']['native']['machine']})" for r in differ]
        out += [""]
    return out
