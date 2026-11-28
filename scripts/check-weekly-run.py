#!/usr/bin/env python3
"""The release's check of the latest weekly mutation run (decision 7, ADR
0006, "What L4 and a release read"; docs/releasing.md): whether a tag's
commit may be released, by the latest weekly run over the pinned set. The
release workflow (.github/workflows/release.yml) runs it before it
publishes, beside its check that CI passed on the tag's commit
(scripts/check-ci-passed.sh).

usage: python3 scripts/check-weekly-run.py [--repo <dir>] [--repository <owner/repo>] <commit sha>
       python3 scripts/check-weekly-run.py --jobs

<commit sha> is the full id of the tag's commit; <dir> is the checkout,
with the whole history, this one unless given; <owner/repo> is
GITHUB_REPOSITORY unless given. With --jobs, it prints the jobs of a
weekly run that it knows (JOBS below), one a line: the name that
mutation-runs.yml gives the job, what the job is there (job, matrix or
workflow), and whether it decides a verdict, separated by tabs.
scripts/check-release-workflow.sh compares them with the workflow.

The packages at L4 are those that mutation/l4-packages.txt names on the
tag's commit. With none, the check reads nothing and passes, and says so.

Otherwise it asks GitHub (with gh) for the runs of the bulk mutation runs
(.github/workflows/mutation-runs.yml), and takes the weekly runs, which
that workflow names "Mutation runs: weekly", whether its schedule or a
person started them. It reads no other run: the monthly run over the full
set is reported, never gated. The weekly runs that decide are those on
the tag's commit or on an ancestor of it on main, its first-parent
history, wherever they were started (on main, or by hand on the tag): a
weekly run on later commits of main is about other code, and a tag can be
neither moved nor deleted, so such a run does not decide, and the check
says so. Of those, the latest that has ended decides; one still running
is not a result yet. The check refuses the release, and says why with the
run's link, when

  - no weekly run on the tag's commit or an ancestor of it on main has
    ended: there is none, or one is still running;
  - a job of the latest that ended that decides a verdict did not
    succeed, or the run lacks it (JOBS below): the plan, which checks the
    site counts; each shard, from 1 to the count the shards' names give;
    the canary; the properties with random seeds; and the finish, which
    merges the shards into the report. It reads the jobs of the run's
    latest attempt, not the run's conclusion: a job that only reports, as
    the coverage from the e2e tests does, or that opens the issue of the
    stale entries, may fail and the run with it, and the check says so
    and goes on;
  - its report (the artifact mutation-report, summary.json) cannot be
    read, is not of the pinned set, did not run a package at L4, or shows
    an unexplained survivor in one: stale-covered survivors and those that
    a DEFERRED entry covers count as unexplained, as the report counts
    them;
  - it does not cover the tag's commit.

The run covers the tag's commit when it ran on it, or when the later
commits of the tag's commit's first-parent history, each a change to
main, each meet one of two conditions:

  - it touches no non-test source of a package at L4: no .mbt file in the
    package's directory but a test file (*_test.mbt, *_wbtest.mbt) or a
    generated one (the site finder's rules, scripts/mutation/sites.py) is
    added, changed or deleted. A release commit, which changes only the
    version and the changelog, meets it;
  - or a run of the branch checks (.github/workflows/branch-checks.yml),
    on a push or started by hand, on the branch the change merged (its
    second parent; a change that is no merge, on itself) passed, and its
    report of the mutants on the changed lines (the artifact
    changed-lines, report.json, as scripts/changed-lines.py writes it)
    covered the change whole and shows no unexplained or stale-covered
    survivor in a package at L4. The latest run that passed and covered
    it decides, as for the merge check (scripts/check-merge.py): its
    report is of that head, against main, from the branch's merge base
    with main before the merge, and covered the whole diff. A merge that
    changes a source file of a package at L4 otherwise than its branch
    did, as when it resolves a conflict, and a merge of several branches
    at once, are not covered. A change pushed straight to main has no
    such run.

It exits with 0 when the tag's commit may be released, and with 1 when it
may not, or when git or gh fails or an answer cannot be read, since a
release must not go ahead on doubt. It exits with 2 when <commit sha> is
not the full id of a commit of the checkout.
"""

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent / "mutation"))
import sites as finder  # noqa: E402

L4_LIST = "mutation/l4-packages.txt"
SHA = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
# The bulk mutation runs' workflow, and the name it gives a weekly run.
RUNS = "mutation-runs.yml"
WEEKLY = "Mutation runs: weekly"
# The commits whose weekly runs decide: on main's line up to the tag's.
HELD = "the tag's commit or an ancestor of it on main"
# The jobs of a weekly run, by the names mutation-runs.yml gives them, what
# each is there, and whether it decides a verdict. A job is one job of the
# Actions API by that name; the matrix of the shards is a job named
# "shard <k>-of-<n>" for each of its n shards (bulk.py plan names them);
# a call of a workflow is the called workflow's jobs, each named "<name> /
# <its own name>". The plan checks the site counts and lists the stale
# entries; the canary replays its mutants; the finish merges the shards
# into the report that the check reads. The coverage from the e2e tests
# only reports (#342), and the job of the stale entries opens or updates
# an issue: neither decides a verdict. scripts/check-release-workflow.sh
# holds this table to the workflow's jobs.
JOBS = (
    ("Plan the run", "job", True),
    ("shard ${{ matrix.name }}", "matrix", True),
    ("Canary (weekly)", "workflow", True),
    ("Properties with random seeds (weekly)", "job", True),
    ("Merge the shards into one report", "job", True),
    ("Coverage from e2e (weekly)", "workflow", False),
    ("Open or update the issue of the stale entries (weekly)", "job", False),
)
SHARD = re.compile(r"(\d+)-of-(\d+)")


class Refused(Exception):
    """Why the commit may not be released, and what to do then."""

    def __init__(self, why, then=None):
        super().__init__(why)
        self.then = then


def start_weekly(repository):
    """What to do when no weekly run that passed covers the commit."""
    return (f"start a weekly run on the tag's commit, and run the release workflow again once it has passed:"
            f" gh workflow run {RUNS} -R {repository} --ref <the tag, or main while it is at the commit>"
            " -f mode=weekly")


class Unusable(Exception):
    """What makes the check unable to start: an argument that is not a
    commit's full id."""


def git(repo, *args):
    """Runs git in repo, and gives its output, or None when it fails."""
    result = subprocess.run(["git", "-C", str(repo), "-c", "core.quotepath=off", *args], capture_output=True,
                            text=True, encoding="utf-8", errors="replace")
    return result.stdout if result.returncode == 0 else None


def gh(*args):
    """Runs gh, and gives its output, or None when it fails."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def artifact(repository, run, name, file):
    """The text of a file of a run's artifact, or None when it cannot be
    read."""
    with tempfile.TemporaryDirectory() as directory:
        if gh("run", "download", str(run["id"]), "-R", repository, "-n", name, "--dir", directory) is None:
            return None
        path = Path(directory) / file
        return path.read_text(encoding="utf-8") if path.is_file() else None


def runs_of(repository, query, keep):
    """The runs of a workflow that the Actions API lists for the query and
    keep keeps, latest first."""
    answer = gh("api", f"repos/{repository}/actions/workflows/{query}")
    if answer is None:
        raise Refused(f"gh cannot list the runs of {query.split('/', 1)[0]}")
    try:
        runs = json.loads(answer)["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError
        kept = [r for r in runs if keep(r)]
        kept.sort(key=lambda r: (r["created_at"], r["id"]), reverse=True)
    except (ValueError, KeyError, TypeError) as problem:
        raise Refused("the Actions API gave an answer that cannot be read") from problem
    return kept


def latest_weekly(repo, repository, sha):
    """The latest weekly run that has ended on the tag's commit or on an
    ancestor of it on main (its first-parent history), wherever it was
    started, which must have passed; it says when a later weekly run is
    still running there, or ran elsewhere."""
    weekly = runs_of(repository, f"{RUNS}/runs?per_page=100", lambda r: r["display_title"] == WEEKLY)
    line = set((git(repo, "rev-list", "--first-parent", sha) or "").split())
    held = [r for r in weekly if r["head_sha"] in line]
    if not held:
        latest = f"; the latest, {weekly[0]['html_url']}, ran on {weekly[0]['head_sha'][:12]}" if weekly else ""
        raise Refused(f"no weekly run over the pinned set ran on {HELD}{latest}", start_weekly(repository))
    ended = [r for r in held if r["status"] == "completed"]
    if not ended:
        raise Refused(f"no weekly run over the pinned set on {HELD} has ended, and {held[0]['html_url']} is still"
                      " running", "run the release workflow again once it has passed")
    run = ended[0]
    jobs_passed(repository, run)
    if held[0] is not run:
        print(f"check-weekly-run: a later weekly run, {held[0]['html_url']}, is still running, and does not decide")
    if weekly[0] is not held[0]:
        print(f"check-weekly-run: a later weekly run, {weekly[0]['html_url']}, ran on {weekly[0]['head_sha'][:12]},"
              f" which is not {HELD}, and does not decide")
    return run


def jobs_of(repository, run):
    """The jobs of the run's latest attempt, as the Actions API lists them,
    page after page."""
    jobs, page = [], 1
    while True:
        answer = gh("api", f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100&page={page}")
        if answer is None:
            raise Refused(f"gh cannot list the jobs of {run['html_url']}")
        try:
            listed = json.loads(answer)
            found, total = listed["jobs"], listed["total_count"]
            if not isinstance(found, list) or not all(isinstance(j["name"], str) for j in found):
                raise TypeError("the jobs are not a list of named jobs")
        except (ValueError, KeyError, TypeError) as problem:
            raise Refused("the Actions API gave an answer that cannot be read") from problem
        jobs += found
        if not found or len(jobs) >= total:
            return jobs
        page += 1


def state(job):
    """How a job ended, as the Actions API says it."""
    return job.get("conclusion") or job.get("status")


def of_row(jobs, name, shape):
    """The run's jobs that a row of JOBS stands for, and the names of those
    the run should have and lacks: every shard, from 1 to the count that
    the shards' names give."""
    if shape == "job":
        mine = [j for j in jobs if j["name"] == name]
        return mine, [] if mine else [name]
    if shape == "workflow":
        mine = [j for j in jobs if j["name"].startswith(f"{name} / ")]
        return mine, [] if mine else [name]
    prefix = name.split("${{", 1)[0]
    shards = {j["name"]: SHARD.fullmatch(j["name"][len(prefix):]) for j in jobs if j["name"].startswith(prefix)}
    mine = [j for j in jobs if shards.get(j["name"])]
    held = {(int(found[1]), int(found[2])) for found in shards.values() if found}
    count = max((n for _, n in held), default=0)
    if not count:
        return mine, [f"{prefix}<k>-of-<n>"]
    return mine, [f"{prefix}{k}-of-{count}" for k in range(1, count + 1) if (k, count) not in held]


def jobs_passed(repository, run):
    """Refuses unless every job of the run that decides a verdict is there
    and succeeded, whatever the run's conclusion; says each other job that
    did not succeed."""
    jobs = jobs_of(repository, run)
    problems, deciding = [], []
    for name, shape, decides in JOBS:
        mine, missing = of_row(jobs, name, shape)
        if decides:
            deciding += mine
            problems += [f"{j['name']} ({state(j)})" for j in mine if state(j) != "success"]
            problems += [f"{m} (missing)" for m in missing]
    others = [f"{j['name']} ({state(j)})" for j in jobs
              if not any(j is d for d in deciding) and state(j) not in ("success", "skipped")]
    if others:
        print(f"check-weekly-run: of the jobs of {run['html_url']} that decide no verdict, these did not succeed,"
              f" which does not stop the release: {', '.join(others)}")
    if problems:
        raise Refused(f"the latest weekly run over the pinned set on {HELD} failed in a job that decides a verdict:"
                      f" {', '.join(problems)}: {run['html_url']}", start_weekly(repository))


def unexplained(package):
    """A package's unexplained survivors in a weekly run's summary, and how
    many of them are stale-covered, as the run's report counts them: those
    that a DEFERRED entry covers are among the unexplained, and survivors
    that no exclusion list judged are unexplained."""
    found = package.get("exclusions") or {}
    if not found:
        return int(package.get("survived", 0)), 0
    stale = int(found["stale_covered"])
    return int(found["unexplained"]) + stale, stale


def survivors_at_l4(repository, run, at_l4):
    """Refuses unless the run's report is of the pinned set, ran every
    package at L4, and shows no unexplained survivor in any of them."""
    text = artifact(repository, run, "mutation-report", "summary.json")
    try:
        summary = json.loads(text) if text is not None else None
        ran, listed = summary["selection"]["packages"], summary["packages"]
        if not isinstance(ran, list) or not isinstance(listed, list):
            raise TypeError("the packages are not lists")
        packages = {p["directory"]: p for p in listed}
        counts = {d: unexplained(packages.get(d, {})) for d in at_l4}
    except (ValueError, KeyError, TypeError) as problem:
        raise Refused("the report of the latest weekly run over the pinned set (the artifact mutation-report,"
                      f" summary.json) cannot be read: {run['html_url']}") from problem
    if summary.get("set") != "pinned":
        raise Refused(f"the report of the latest weekly run over the pinned set is of the {summary.get('set')}"
                      f" set, not the pinned set: {run['html_url']}")
    for directory in at_l4:
        if directory not in ran:
            raise Refused(f"the latest weekly run over the pinned set did not run {directory}, a package at L4:"
                          f" {run['html_url']}", start_weekly(repository))
    found = [f"{d} {n}" + (f" ({stale} stale-covered)" if stale else "")
             for d, (n, stale) in counts.items() if n]
    if found:
        raise Refused("the latest weekly run over the pinned set shows unexplained survivors in a package at"
                      f" L4: {', '.join(found)}: {run['html_url']}",
                      f"its report lists them: gh run download {run['id']} -R {repository} --name mutation-report"
                      " --dir mutation-report")


def l4_packages(repo, sha):
    """The packages at L4 that the list names on the commit, in its order."""
    found = []
    for line in (git(repo, "show", f"{sha}:{L4_LIST}") or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in found:
            found.append(line)
    return found


def later_changes(repo, run, sha):
    """The commits of the tag's commit's first-parent history after the
    run's commit, which is on it, oldest first: main's changes since the
    run."""
    return (git(repo, "rev-list", "--first-parent", f"{run['head_sha']}..{sha}") or "").split()[::-1]


def parents(repo, commit):
    """The commit's parents, the first first."""
    return (git(repo, "rev-list", "--parents", "-n", "1", commit) or "").split()[1:]


def subject(repo, commit):
    """The commit's subject."""
    return (git(repo, "log", "-1", "--format=%s", commit) or "").strip()


def is_source(repo, file, commits):
    """Whether a .mbt file is non-test source on any of the commits that
    have it: not a test file, and not a generated one (the site finder's
    rules)."""
    if not file.endswith(".mbt") or finder.is_test_file(PurePosixPath(file)):
        return False
    texts = [git(repo, "show", f"{c}:{file}") for c in commits]
    return any(t is not None and not finder.is_generated(t) for t in texts)


def source_touched(repo, change, at_l4):
    """The packages at L4 whose non-test source a commit adds, changes or
    deletes against its first parent."""
    before = parents(repo, change)[0]
    names = git(repo, "diff", "--no-renames", "--name-only", before, change)
    if names is None:
        raise Refused(f"git cannot tell what {change[:12]} changes")
    touched = {posixpath.dirname(f) for f in names.splitlines()
               if posixpath.dirname(f) in at_l4 and is_source(repo, f, (before, change))}
    return sorted(touched, key=at_l4.index)


def edits(repo, old, new, file):
    """The lines that the diff from old to new removes and adds in a file,
    sorted, each with its sign: what a change does to the file, wherever
    its lines are."""
    diff = git(repo, "diff", "--no-renames", "--no-color", "-U0", old, new, "--", file)
    if diff is None:
        raise Refused(f"git cannot tell what {new[:12]} changes in {file}")
    return sorted(line for line in diff.splitlines()
                  if line[:1] in "+-" and not line.startswith(("+++ ", "--- ")))


def on_main(found):
    """Whether a report of the branch checks compared its head with main."""
    return found.get("base") in ("main", "origin/main")


def branch_report(repository, runs, head, whose, merge_base):
    """The run of the branch checks on head that decides, with its report:
    the latest that passed and whose report covered the change whole; or
    why none does, the latest's reason when none passed or covered it."""
    if not runs:
        return None, f"no run of the branch checks is on {whose}"
    passed = [r for r in runs if r["status"] == "completed" and r["conclusion"] == "success"]
    if not passed:
        latest = runs[0]
        state = "is still running" if latest["status"] != "completed" else f"failed ({latest['conclusion']})"
        return None, f"no run of the branch checks on {head[:12]} passed: the latest {state}: {latest['html_url']}"
    problems = []
    for run in passed:
        text = artifact(repository, run, "changed-lines", "report.json")
        try:
            found = json.loads(text) if text is not None else None
        except ValueError:
            found = None
        if not isinstance(found, dict) or not isinstance(found.get("survivors"), list):
            problems.append(f"the report of the branch checks on {head[:12]} cannot be read: {run['html_url']}")
        elif found.get("head") != head:
            problems.append(f"the report of the branch checks on {head[:12]} is of another commit,"
                            f" {str(found.get('head'))[:12]}: {run['html_url']}")
        elif not on_main(found):
            problems.append(f"the branch checks on {head[:12]} compared it with {found.get('base')}, not main:"
                            f" {run['html_url']}")
        elif found.get("merge_base") != merge_base:
            problems.append(f"the branch checks on {head[:12]} took the merge base {str(found.get('merge_base'))[:12]},"
                            f" not {merge_base[:12]}, the branch's merge base with main before the merge:"
                            f" {run['html_url']}")
        elif found.get("covered") is not True:
            problems.append(f"the branch checks on {head[:12]} did not cover the whole diff ({found.get('mutants')}"
                            f" mutants on its changed lines): {run['html_url']}")
        else:
            return (run, found), None
    return None, problems[0]


def covered(repo, repository, run, change, at_l4):
    """How a change to main after the run is covered, or a refusal."""
    touched = source_touched(repo, change, at_l4)
    if not touched:
        return "it touches no non-test source of a package at L4"
    what = (f"{change[:12]} ({subject(repo, change)}), a change to main after the latest weekly run over the pinned"
            f" set ({run['html_url']}), changes non-test source of {', '.join(touched)}, a package at L4, and")
    then = start_weekly(repository)
    before, *merged = parents(repo, change)
    if len(merged) > 1:
        raise Refused(f"{what} merges more than one branch, which no one branch's report covers", then)
    head = merged[0] if merged else change
    whose = f"{head[:12]}, the head of the branch it merged" if merged else \
        f"{change[:12]}, as none is on a change pushed straight to main"
    merge_base = (git(repo, "merge-base", before, head) or "").strip()
    names = (git(repo, "diff", "--no-renames", "--name-only", before, change) or "").splitlines()
    for file in names:
        if posixpath.dirname(file) in touched and is_source(repo, file, (before, change)) and \
                edits(repo, before, change, file) != edits(repo, merge_base, head, file):
            raise Refused(f"{what} changes {file} otherwise than {head[:12]}, the head of the branch it merged, so no"
                          " branch's report covers it whole", then)
    runs = runs_of(repository, f"branch-checks.yml/runs?head_sha={head}&per_page=100",
                   lambda r: r["head_sha"] == head and r["event"] in ("push", "workflow_dispatch"))
    decided, why = branch_report(repository, runs, head, whose, merge_base)
    if decided is None:
        raise Refused(f"{what} {why}", then)
    checks, found = decided
    blocking = [s for s in found["survivors"]
                if s.get("status") in ("unexplained", "stale-covered") and s.get("directory") in at_l4]
    if blocking:
        listed = ", ".join(f"{s['id']} ({s['directory']})" + (", stale-covered" if s["status"] == "stale-covered"
                                                               else "") for s in blocking)
        raise Refused(f"{what} the branch checks on {head[:12]} show unexplained survivors in a package at L4: {listed}:"
                      f" {checks['html_url']}", then)
    return (f"the branch checks on {head[:12]} covered it whole, with no unexplained survivor in a package at L4:"
            f" {checks['html_url']}")


def check(repo, sha, repository):
    """Prints whether the commit may be released, and why; whether it may."""
    named = sha[:12]
    at_l4 = l4_packages(repo, sha)
    if not at_l4:
        print(f"check-weekly-run: no package is at L4 on {named} ({L4_LIST} names none), so the release reads no"
              " weekly run and waits for none")
        return True
    try:
        if not REPOSITORY.fullmatch(repository):
            raise Refused(f"cannot ask GitHub, since GITHUB_REPOSITORY is not owner/repository: '{repository}'")
        run = latest_weekly(repo, repository, sha)
        survivors_at_l4(repository, run, at_l4)
        changes = later_changes(repo, run, sha)
        lines = [f"{c[:12]} {subject(repo, c)}: {covered(repo, repository, run, c, at_l4)}" for c in changes]
        where = "the tag's commit" if not changes else f"{run['head_sha'][:12]}, an ancestor of the tag's commit"
        print(f"check-weekly-run: {named} may be released: the latest weekly run over the pinned set, on {where},"
              f" shows no unexplained survivor in the packages at L4 ({', '.join(at_l4)}): {run['html_url']}")
        if changes:
            count = "the one change" if len(changes) == 1 else f"each of the {len(changes)} changes"
            print(f"check-weekly-run: {count} to main after it is covered:")
            for line in lines:
                print(f"check-weekly-run:   {line}")
        return True
    except Refused as why:
        print(f"check-weekly-run: {named} may not be released: {why}", file=sys.stderr)
        if why.then:
            print(f"check-weekly-run: {why.then}", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--repo", default=".", help="the checkout")
    parser.add_argument("--repository", help="owner/repo on GitHub (GITHUB_REPOSITORY unless given)")
    parser.add_argument("--jobs", action="store_true", help="print the jobs of a weekly run it knows, and exit")
    parser.add_argument("commit", nargs="?", help="the full id of the tag's commit")
    args = parser.parse_args()
    if args.jobs:
        for name, shape, decides in JOBS:
            print(f"{name}\t{shape}\t{'decides a verdict' if decides else 'decides no verdict'}")
        return 0
    if args.commit is None:
        parser.error("the commit is required")
    repo = Path(args.repo)
    try:
        if not SHA.fullmatch(args.commit):
            raise Unusable(f"'{args.commit}' is not a commit's full SHA in lower case")
        if (git(repo, "rev-parse", "--verify", "--quiet", f"{args.commit}^{{commit}}") or "").strip() != args.commit:
            raise Unusable(f"{args.commit} is not a commit of {repo}")
    except Unusable as error:
        print(f"check-weekly-run: {error}", file=sys.stderr)
        return 2
    repository = args.repository or os.environ.get("GITHUB_REPOSITORY", "")
    return 0 if check(repo, args.commit, repository) else 1


if __name__ == "__main__":
    sys.exit(main())
