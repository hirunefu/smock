#!/usr/bin/env python3
"""The exclusion list (CONTRIBUTING.md, "Exclusions"): the one list in the
repository, exclusions.toml at the root, that accepts a surviving mutant
or an uncovered point, each entry with a category, a reason and who
reviewed it. No attribute in the source excludes anything.

usage: python3 scripts/mutation/exclusions.py [--root <dir>] [--moonc <moonc>] check
           [--allow-pending]
       python3 scripts/mutation/exclusions.py [--root <dir>] [--moonc <moonc>] new <what>
       python3 scripts/mutation/exclusions.py [--root <dir>] review [--base <ref>]
           [--seed <run ID>]

<root> is the workspace, the current directory unless it is given. Each
entry is a table of the array `exclusion`:

  mutant      a mutant's id, as the site finder gives it (sites.py): its
              file, enclosing definition, operator, original text,
              replacement text and ordinal; or, for a point,
  file        the point's file, relative to <root>,
  definition  the top-level definition that holds it, named as a
              mutant's id names it, and
  position    its line, counted from the definition's first line, which
              is line 1, and its column in characters, as "<line>:<column>"
  text        the first 16 hexadecimal digits of the SHA-256 of the
              definition's text, from its first line to its last, when
              the entry was made: an entry whose definition no longer has
              that text, or is gone, is stale
  category    EQUIVALENT, ARID, UNREACHABLE, FAULT, UB-NATIVE or DEFERRED
              (ADR 0006)
  reason      why the mutant or the point is accepted
  reviewer    who reviewed it: empty until the maintainer fills it in

and what its category needs:

  EQUIVALENT   a mutant only, with compiler_output, what the comparison
               of the compiler's output found ("differs", or "not
               compared" where it cannot compare the mutant), and
               adversarial = { context = <the agent context that made the
               attempt>, tests = [<each test it tried, which passed>] }.
               Until a separate context has made the attempt, the context
               that proposed the entry writes one whose context starts
               with "pending" (in any case), and that context replaces it
  UNREACHABLE  a point at an abort, which an invariant guards; anything
               else carries argument, its written argument
  UB-NATIVE    a mutant only
  DEFERRED     issue, the number of the issue that resolves it; it still
               counts as unresolved

check  fails, with 1, on an entry in another category, without what its
       category needs, with a field the list does not know, or a second
       entry for the same mutant or point, and on a list that is not
       TOML. It lists each stale entry, and passes with stale entries. It
       fails on an EQUIVALENT entry whose adversarial attempt is still
       pending, unless --allow-pending is given: a ticket branch passes it
       before the separate context has run; CI never does, so nothing
       pending reaches the integration branch. With the option, it lists
       each pending entry.

new    prints the stanza of a new entry for <what>, a mutant's id or a
       point as <file>:<line>:<column> (the coverage report names points
       so), with the definition's text as it is now, and the category,
       the reason and the reviewer empty, for the author to fill in.

review lists the batch: the entries that the tree adds or changes against
       the merge base of HEAD and <base> (origin/main unless it is given),
       a change of the reviewer alone aside. Of the batch, the maintainer
       reads every entry in the protocol packages (http1, grpc, yaml, re2,
       xml and protobuf) and in serverparsers, and one in five of the
       others, rounded up. Those are drawn once the batch is frozen, with
       a seed that no agent can know before, so that the author cannot
       know which: the run ID that GitHub Actions gives the packages run
       of the bulk workflow (mutation-runs.yml) on the frozen tip. No one
       picks the seed. With --seed, it lists them; without, it says how
       many there are to draw.

The coverage report (scripts/coverage-report.py, through points()) and
the mutation runner (run.py and merge.py, through annotate() and counts())
read the list too.

The definitions are read with the site finder's parser (sites.py), so
check and new need moonc; review does not. It exits with 2 when it cannot
judge: a file does not parse, git cannot answer, or a point of `new` lies
in no definition.
"""

import argparse
import math
import random
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

import ratchet
import sites

LIST = Path("exclusions.toml")
CATEGORIES = ("EQUIVALENT", "ARID", "UNREACHABLE", "FAULT", "UB-NATIVE", "DEFERRED")
COMMON = ("text", "category", "reason", "reviewer")
POINT = ("file", "definition", "position")
# The fields each category adds to the common ones.
NEEDS = {"EQUIVALENT": ("compiler_output", "adversarial"), "UNREACHABLE": ("argument",), "DEFERRED": ("issue",)}
COMPARED = ("differs", "not compared")
# How the context of an adversarial attempt that is still to be made
# starts, in any case: the context that proposed the entry writes it so.
PENDING = "pending"
PLACE = re.compile(r"^(.+):(\d+):(\d+)$")
POSITION = re.compile(r"^(\d+):(\d+)$")
# The packages whose every entry the maintainer reads: the protocol
# packages, and the parsers moved out of server.
READ_ALL = ("http1", "grpc", "yaml", "re2", "xml", "protobuf", "serverparsers")


class ExclusionError(Exception):
    """What keeps the list from being judged: a file that does not parse,
    or a place in no definition."""


def split_id(mutant):
    """The six fields of a mutant's id, unescaped, or None when it does not
    have six."""
    fields, field, escaped = [], "", False
    for char in mutant:
        if escaped:
            field += {"n": "\n", "r": "\r", "t": "\t"}.get(char, char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ",":
            fields.append(field)
            field = ""
        else:
            field += char
    fields.append(field)
    return fields if len(fields) == 6 else None


class Entry:
    """An entry of the list: its fields, and the file and definition that
    it lies in."""

    def __init__(self, number, fields):
        self.number = number
        self.fields = fields
        self.mutant = fields.get("mutant")
        if isinstance(self.mutant, str):
            parts = split_id(self.mutant)
            self.file, self.definition = (parts[0], parts[1]) if parts else (None, None)
            self.key = self.mutant
        else:
            self.mutant = None
            self.file, self.definition = fields.get("file"), fields.get("definition")
            self.key = f"{self.file},{self.definition},{fields.get('position')}"

    @property
    def category(self):
        return self.fields.get("category")

    def is_point(self):
        return self.mutant is None

    def position(self):
        """A point's line within its definition and its column."""
        match = POSITION.match(str(self.fields.get("position", "")))
        return (int(match.group(1)), int(match.group(2))) if match else None


def read_list(root, text=None):
    """The entries of the list at root, or of its text if given, and the
    problems of its form; no list is an empty one."""
    path = root / LIST
    if text is None:
        if not path.is_file():
            return [], []
        text = path.read_text(encoding="utf-8")
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return [], [f"{LIST}: not TOML: {error}"]
    problems = []
    unknown = sorted(set(data) - {"exclusion"})
    if unknown:
        problems.append(f"{LIST}: it should hold only the array exclusion, not {', '.join(unknown)}")
    entries = []
    for number, fields in enumerate(data.get("exclusion", []), 1):
        if "mutant" not in fields and not all(f in fields for f in POINT):
            problems.append(f"{LIST}: entry {number} should name a mutant (mutant = <id>) or a point (file,"
                            " definition and position)")
            continue
        entries.append(Entry(number, fields))
    return entries, problems


def definitions(root, files, moonc):
    """The top-level definitions of each file, outside test blocks, as
    (name, first line, last line, text hash), read with the site finder's
    parser; none for a file that is gone."""
    found = {}
    with tempfile.TemporaryDirectory(prefix="smock-exclusions-") as tmp:
        for index, file in enumerate(sorted(files)):
            path = root / file
            if not path.is_file():
                found[file] = []
                continue
            text = path.read_text(encoding="utf-8")
            try:
                tree = sites.dump(moonc, "wasm-gc", Path(tmp), index, Path(file), text)
            except sites.FinderError as error:
                raise ExclusionError(str(error)) from error
            source = sites.SourceFile(Path(file), text)
            lines = text.split("\n")
            mine = []
            for entry in sites.parse_tree(tree):
                item = sites.Item(source, entry[1], entry[2])
                if item.is_test():
                    continue
                first, last = item.lines()
                mine.append((item.name(), first, last, ratchet.text_hash("\n".join(lines[first - 1 : last]))))
            found[file] = mine
    return found


def problems_of(entry, source):
    """What is wrong with an entry, given its file's definitions and text
    (None when the entry is stale: whether a stale point is at an abort is
    for its triage to say)."""
    fields, key = entry.fields, entry.key
    allowed = set(COMMON) | ({"mutant"} if entry.mutant else set(POINT))
    allowed |= set(NEEDS.get(entry.category, ()))
    problems = []
    unknown = sorted(set(fields) - allowed)
    if unknown:
        problems.append(f"{key}: it has a field the list does not know: {', '.join(unknown)}")
    if entry.mutant and split_id(entry.mutant) is None:
        problems.append(f"{key}: a mutant's id has six fields, its file, definition, operator, original text,"
                        " replacement text and ordinal")
    if entry.is_point() and entry.position() is None:
        problems.append(f"{key}: a point's position should be \"<line>:<column>\", its line within its"
                        " definition and its column")
    if entry.category not in CATEGORIES:
        problems.append(f"{key}: the category should be one of {', '.join(CATEGORIES[:-1])} and"
                        f" {CATEGORIES[-1]}, not \"{entry.category}\"")
    if not str(fields.get("reason", "")).strip():
        problems.append(f"{key}: it should give a reason")
    if not isinstance(fields.get("reviewer"), str):
        problems.append(f"{key}: it should have a reviewer, empty until the maintainer fills it in")
    if not isinstance(fields.get("text"), str) or not re.fullmatch(r"[0-9a-f]{16}", fields["text"]):
        problems.append(f"{key}: it should give its definition's text (text = <16 hexadecimal digits>), as `new`"
                        " prints it")
    if entry.is_point() and entry.category in ("EQUIVALENT", "UB-NATIVE"):
        problems.append(f"{key}: a point cannot be {entry.category}: only a mutant can")
    if entry.category == "EQUIVALENT":
        if fields.get("compiler_output") not in COMPARED:
            problems.append(f"{key}: an EQUIVALENT entry should record the comparison of the compiler's output"
                            ' (compiler_output = "differs" or "not compared")')
        attempt = fields.get("adversarial")
        if not (isinstance(attempt, dict) and set(attempt) == {"context", "tests"}
                and isinstance(attempt["context"], str) and attempt["context"].strip()
                and isinstance(attempt["tests"], list) and attempt["tests"]
                and all(isinstance(t, str) and t.strip() for t in attempt["tests"])):
            problems.append(f"{key}: an EQUIVALENT entry should record the adversarial attempt: the agent context"
                            " that made it and the tests it tried (adversarial = { context, tests })")
    if entry.category == "DEFERRED":
        issue = fields.get("issue")
        if not (isinstance(issue, int) and not isinstance(issue, bool) and issue > 0):
            problems.append(f"{key}: a DEFERRED entry should carry its issue's number (issue = <n>)")
    if entry.category == "UNREACHABLE" and not str(fields.get("argument", "")).strip():
        if not (entry.is_point() and (source is None or at_abort(entry, source))):
            problems.append(f"{key}: an UNREACHABLE entry should be an arm that an invariant guards with an abort,"
                            " or carry its written argument (argument = \"...\")")
    return problems


def at_abort(entry, source):
    """Whether a point entry's place in its file starts an abort, given the
    file's definitions and text."""
    if source is None or entry.position() is None:
        return False
    found, text = source
    line, column = entry.position()
    for name, first, _, _ in found:
        if name == entry.definition:
            lines = text.split("\n")
            at = first + line - 1
            return 1 <= at <= len(lines) and lines[at - 1][column - 1 :].startswith("abort(")
    return False


def stale(entry, found):
    """Whether an entry is stale: no definition of its file has its name
    and its text."""
    return not any(name == entry.definition and digest == entry.fields.get("text")
                   for name, _, _, digest in found.get(entry.file, []))


def pending(entry):
    """Whether an EQUIVALENT entry's adversarial attempt is still to be
    made: the context that proposed the entry wrote a context that starts
    with "pending", in any case, for the separate context to replace."""
    attempt = entry.fields.get("adversarial")
    return (entry.category == "EQUIVALENT" and isinstance(attempt, dict) and isinstance(attempt.get("context"), str)
            and attempt["context"].lstrip().casefold().startswith(PENDING))


def check(root, moonc, allow_pending=False):
    """Checks the list: whether it passed. An entry whose adversarial
    attempt is still pending fails it, unless allow_pending, as a ticket
    branch has it before the separate context has run."""
    entries, problems = read_list(root)
    files = {e.file for e in entries if isinstance(e.file, str)}
    found = definitions(root, files, moonc)
    sources = {f: (found[f], (root / f).read_text(encoding="utf-8")) for f in files if (root / f).is_file()}
    seen = set()
    stale_entries, pending_entries = [], []
    for entry in entries:
        if entry.key in seen:
            problems.append(f"{LIST}: {entry.key}: a second entry for it")
        seen.add(entry.key)
        is_stale = stale(entry, found)
        if is_stale:
            stale_entries.append(entry)
        source = None if is_stale else sources.get(entry.file)
        problems += [f"{LIST}: {problem}" for problem in problems_of(entry, source)]
        if pending(entry):
            pending_entries.append(entry)
            if not allow_pending:
                problems.append(f"{LIST}: {entry.key}: its adversarial attempt is still pending: the separate context"
                                " replaces it with what it tried before the branch is merged (check --allow-pending"
                                " passes it on a ticket branch until then)")
    for problem in problems:
        print(f"exclusions: {problem}", file=sys.stderr)
    for entry in stale_entries:
        print(f"exclusions: stale: {entry.key} ({entry.category}): its definition's text changed, or it is gone")
    if allow_pending:
        for entry in pending_entries:
            print(f"exclusions: pending: {entry.key} ({entry.category}): its adversarial attempt is still to be made")
    print(f"exclusions: {len(entries)} entries, " + (f"{len(stale_entries)} stale" if stale_entries else "none stale")
          + (f", {len(pending_entries)} pending" if pending_entries else ""))
    return not problems


# The order in which a report lists survivors: those that count first.
STATUSES = ("unexplained", "stale-covered", "accepted")


def annotate(root, records, moonc="moonc"):
    """Gives each survivor among records what the list at root says of it,
    as its "exclusion": accepted, by a current entry other than DEFERRED;
    stale-covered, when its only entry is stale; or unexplained, with its
    DEFERRED entry if it has one. Each names its entry and the category."""
    survivors = [r for r in records if r.get("outcome") == "survived"]
    if not survivors:
        return
    entries, problems = read_list(root)
    if problems and not entries:
        raise ExclusionError("; ".join(problems))
    by_mutant = {e.mutant: e for e in entries if e.mutant}
    covering = [by_mutant[r["id"]] for r in survivors if r["id"] in by_mutant]
    found = definitions(root, {e.file for e in covering if isinstance(e.file, str)}, moonc) if covering else {}
    for record in survivors:
        entry = by_mutant.get(record["id"])
        if entry is None:
            record["exclusion"] = {"status": "unexplained"}
            continue
        named = {"entry": entry.key, "category": entry.category}
        if stale(entry, found):
            record["exclusion"] = {"status": "stale-covered", **named}
        elif entry.category == "DEFERRED":
            record["exclusion"] = {"status": "unexplained", **named, "issue": entry.fields.get("issue")}
        elif entry.category in CATEGORIES:
            record["exclusion"] = {"status": "accepted", **named}
        else:
            record["exclusion"] = {"status": "unexplained"}


def counts(records):
    """The survivors among records after the list, for a summary."""
    found = [r["exclusion"] for r in records if r.get("outcome") == "survived" and "exclusion" in r]
    if not found:
        return {}
    accepted = sorted(f["category"] for f in found if f["status"] == "accepted")
    return {"exclusions": {
        "unexplained": sum(1 for f in found if f["status"] == "unexplained"),
        "stale_covered": sum(1 for f in found if f["status"] == "stale-covered"),
        "accepted": len(accepted),
        "accepted_by_category": {c: accepted.count(c) for c in CATEGORIES if c in accepted},
    }}


def summary_line(summary):
    """The report's line of a package's survivors after the list, or None
    when it has none."""
    found = summary.get("exclusions")
    if not found:
        return None
    by_category = ", ".join(f"{c} {n}" for c, n in found["accepted_by_category"].items())
    return (f"After the exclusion list: {found['unexplained']} unexplained, {found['stale_covered']} stale-covered,"
            f" {found['accepted']} accepted" + (f" ({by_category})" if by_category else "") + ".")


def ordered(survivors):
    """Survivors in the order a report lists them: unexplained, then
    stale-covered, then accepted, each in the run's order."""
    return sorted(survivors, key=lambda r: STATUSES.index(r.get("exclusion", {}).get("status", "unexplained")))


def status_line(record):
    """What the report says of a survivor after the list."""
    found = record.get("exclusion")
    if found is None:
        return None
    if found["status"] == "accepted":
        return f"Accepted by the exclusion list: {found['category']}."
    if found["status"] == "stale-covered":
        return f"Stale-covered: its only entry, `{found['entry']}`, is stale."
    if "issue" in found:
        return f"Unexplained: DEFERRED to #{found['issue']}."
    return "Unexplained."


class Points:
    """What the list says of the uncovered points: the places it accepts,
    each with its category, by (file, line, column); the places of its
    DEFERRED entries, each with its issue; and its stale point entries."""

    def __init__(self, accepted, deferred, stale_entries):
        self.accepted = accepted
        self.deferred = deferred
        self.stale = stale_entries


def points(root, moonc="moonc"):
    """The points of the list at root: a current entry other than DEFERRED
    accepts its place, and a stale or a DEFERRED one accepts none."""
    entries, problems = read_list(root)
    if problems and not entries:
        raise ExclusionError("; ".join(problems))
    mine = [e for e in entries if e.is_point() and e.position() is not None and isinstance(e.file, str)]
    found = definitions(root, {e.file for e in mine}, moonc) if mine else {}
    accepted, deferred, stale_entries = {}, {}, []
    for entry in mine:
        if stale(entry, found):
            stale_entries.append(entry)
            continue
        first = next(d[1] for d in found[entry.file] if d[0] == entry.definition and d[3] == entry.fields["text"])
        line, column = entry.position()
        place = (entry.file, first + line - 1, column)
        if entry.category == "DEFERRED":
            deferred[place] = entry.fields.get("issue")
        elif entry.category in CATEGORIES:
            accepted[place] = entry.category
    return Points(accepted, deferred, stale_entries)


def new(root, what, moonc):
    """The stanza of a new entry for a mutant's id or a point."""
    place = PLACE.match(what)
    if place and split_id(what) is None:
        file, line, column = place.group(1), int(place.group(2)), int(place.group(3))
        found = definitions(root, {file}, moonc)[file]
        holder = next((d for d in found if d[1] <= line <= d[2]), None)
        if holder is None:
            raise ExclusionError(f"{what} lies in no top-level definition")
        name, first, _, digest = holder
        head = [f"file = {quoted(file)}", f"definition = {quoted(name)}", f'position = "{line - first + 1}:{column}"']
    else:
        parts = split_id(what)
        if parts is None:
            raise ExclusionError(f"{what} is neither a mutant's id nor a point (<file>:<line>:<column>)")
        found = definitions(root, {parts[0]}, moonc)[parts[0]]
        holder = next((d for d in found if d[0] == parts[1]), None)
        if holder is None:
            raise ExclusionError(f"{parts[0]} has no definition {parts[1]}")
        digest = holder[3]
        head = [f"mutant = {quoted(what)}"]
    return "\n".join(["[[exclusion]]", *head, f'text = "{digest}"', 'category = ""', 'reason = ""',
                      'reviewer = ""']) + "\n"


def quoted(text):
    """A TOML basic string."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def git(root, *args):
    """The output of a git command in root."""
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise ExclusionError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def review(root, base, seed):
    """The lines that say which entries of the batch the maintainer reads."""
    entries, problems = read_list(root)
    if problems:
        raise ExclusionError("; ".join(problems))
    merge_base = git(root, "merge-base", "HEAD", base).strip()
    listed = git(root, "ls-tree", "--name-only", merge_base, "--", LIST.as_posix()).strip()
    before = read_list(root, git(root, "show", f"{merge_base}:{LIST.as_posix()}"))[0] if listed else []

    def unreviewed(entry):
        return {k: v for k, v in entry.fields.items() if k != "reviewer"}

    earlier = {e.key: unreviewed(e) for e in before}
    batch = [e for e in entries if earlier.get(e.key) != unreviewed(e)]
    every = [e for e in batch if isinstance(e.file, str) and str(Path(e.file).parent.as_posix()) in READ_ALL]
    others = [e for e in batch if e not in every]
    drawn = math.ceil(len(others) / 5)
    lines = [f"The batch: {len(batch)} entries that the branch adds or changes against {merge_base[:12]}, its merge"
             f" base with {base}.", "",
             f"Every one in the protocol packages and in serverparsers ({len(every)}):"]
    lines += [f"  {e.key}  {e.category}" for e in every]
    lines.append("")
    if seed is None:
        lines.append(f"One in five of the other {len(others)}: {drawn}, drawn once the batch is frozen, with"
                     " `review --seed <run ID>`: the ID of the packages run on the frozen tip, which no agent can"
                     " know before.")
    else:
        chosen = random.Random(seed).sample(sorted(e.key for e in others), drawn)
        lines.append(f"One in five of the other {len(others)}: {drawn}, drawn with the seed {seed!r}:")
        lines += [f"  {e.key}  {e.category}" for e in others if e.key in chosen]
    return lines


def main():
    parser = argparse.ArgumentParser(description="Check the exclusion list, or start an entry of it.")
    parser.add_argument("--root", default=".", help="the workspace")
    parser.add_argument("--moonc", default="moonc", help="the compiler, whose parse tree gives the definitions")
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("check", help="check the list's entries, and list the stale ones")
    checking.add_argument("--allow-pending", action="store_true",
                          help="pass an EQUIVALENT entry whose adversarial attempt is still pending, as a ticket"
                               " branch does before the separate context has run; CI never passes it")
    making = commands.add_parser("new", help="print the stanza of a new entry")
    making.add_argument("what", help="a mutant's id, or a point as <file>:<line>:<column>")
    reviewing = commands.add_parser("review", help="list the entries of the batch that the maintainer reads")
    reviewing.add_argument("--base", default="origin/main", help="the batch is what HEAD's tree changes against"
                                                                 " its merge base with this")
    reviewing.add_argument("--seed", help="the run ID of the packages run on the frozen tip, which draws one in five"
                                          " of the other entries")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    try:
        if args.command == "new":
            print(new(root, args.what, args.moonc), end="")
        elif args.command == "review":
            print("\n".join(review(root, args.base, args.seed)))
        elif not check(root, args.moonc, args.allow_pending):
            sys.exit(1)
    except ExclusionError as error:
        print(f"exclusions: {error}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
