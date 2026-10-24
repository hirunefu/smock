#!/usr/bin/env python3
"""Judges a run of h2spec against one of smock's ports, from h2spec's JUnit
report and the list of cases that do not pass on that port.

usage: python3 scripts/h2spec-verdict.py <list> <report>

<list> is scripts/h2spec/<port>.txt; its name, without .txt, names the port
in what this prints. <report> is the JUnit report of h2spec 2.6.0
(h2spec -j <report>).

Each line of the list names a case, why it is listed, and the reason in
words, separated by spaces; a line that starts with # is a comment. Why is
one of

  skipped   h2spec skips the case.
  left-out  the case runs, but its outcome does not count.
  #<issue>  the case fails until that issue is done.

It prints how many cases passed, every listed case with its outcome and
reason, the listed cases that passed, which can come off the list, and
every case that failed or was skipped without being listed with that
outcome, with what h2spec expected and got. On GitHub Actions, a listed
case that passed is also a notice on its line of the list. It exits with 1
when a case failed or was skipped without being listed with that outcome,
when a listed case did not run, or when the report holds no case, and with
2 when it cannot read the list or the report.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


class ListError(Exception):
    """A line of the list that cannot be read."""


class Entry:
    """A case on the list: why it is listed, the reason, and its line."""

    def __init__(self, why, reason, line):
        self.why = why
        self.reason = reason
        self.line = line

    def allows(self, outcome):
        """Whether the case may have this outcome, other than passing."""
        if self.why == "left-out":
            return True
        return outcome == ("skipped" if self.why == "skipped" else "failed")

    def how(self):
        """How the case is listed, in words."""
        if self.why == "skipped":
            return "as skipped"
        if self.why == "left-out":
            return "as left out"
        return f"until {self.why}"


def cases(report):
    """The cases of a JUnit report, in order: (ID, description, outcome,
    detail), where the detail of a failed case is the lines h2spec gives on
    what went wrong.

    h2spec names a case by its group and its number in the group, such as
    http2/6.9.1/1, but the report gives only the group (package) and the
    description (classname). The cases of a group are in order, so the
    number is the case's place among them, when h2spec ran every case.
    """
    found = []
    for suite in ET.parse(report).getroot().iter("testsuite"):
        for number, case in enumerate(suite.findall("testcase"), start=1):
            # h2spec 2.6.0 writes a failed case as an error element.
            failure = case.find("failure")
            if failure is None:
                failure = case.find("error")
            if case.find("skipped") is not None:
                outcome, detail = "skipped", ""
            elif failure is not None:
                outcome, detail = "failed", (failure.text or "").strip()
            else:
                outcome, detail = "passed", ""
            found.append((f"{case.get('package')}/{number}", case.get("classname"), outcome, detail))
    return found


def read_list(path):
    """The entries of a list, by case ID."""
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) < 3:
            raise ListError(f"{path.name}:{number}: give the case, why it is listed, and the reason")
        case, why, reason = fields
        if why not in ("skipped", "left-out") and not re.fullmatch(r"#[0-9]+", why):
            raise ListError(f"{path.name}:{number}: {case} is listed as {why!r}, "
                            "not as skipped, left-out or #<issue>")
        if case in entries:
            raise ListError(f"{path.name}:{number}: {case} is listed twice")
        entries[case] = Entry(why, reason.strip(), number)
    return entries


def explain(detail):
    """The lines of a failed case's detail, labelled. h2spec 2.6.0 writes
    each outcome it expected on a line, then what it got; a detail of one
    line says what went wrong instead."""
    lines = detail.splitlines()
    if len(lines) < 2:
        return [f"    {line}" for line in lines]
    labels = ["expected"] + ["or"] * (len(lines) - 2) + ["got"]
    return [f"    {label:>8}: {line}" for label, line in zip(labels, lines)]


def plural(count, one, more):
    """<count> <one>, or <count> <more> when count is not 1."""
    return f"{count} {one if count == 1 else more}"


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(argv[1])
    port = path.stem
    try:
        listed = read_list(path)
    except (OSError, ListError) as error:
        print(f"h2spec {port}: {error}", file=sys.stderr)
        return 2
    try:
        run = cases(argv[2])
    except (OSError, ET.ParseError) as error:
        print(f"h2spec {port}: cannot read the report {argv[2]}: {error}", file=sys.stderr)
        return 2
    if not run:
        print(f"h2spec {port}: the report holds no case: h2spec ran none")
        return 1
    counts = {outcome: sum(1 for _, _, o, _ in run if o == outcome) for outcome in ("passed", "skipped", "failed")}
    print(f"h2spec {port}: {len(run)} cases, {counts['passed']} passed, {counts['skipped']} skipped, "
          f"{counts['failed']} failed")

    # Every listed case, with its outcome and reason.
    if listed:
        print(f"h2spec {port}: listed in {path.name}, with the reason:")
    passing = []
    for case, _, outcome, _ in run:
        entry = listed.get(case)
        if entry is None:
            continue
        print(f"  {case} {outcome}, listed {entry.how()}: {entry.reason}")
        if outcome == "passed":
            passing.append((case, entry))
    if passing:
        print(f"h2spec {port}: {plural(len(passing), 'listed case', 'listed cases')} passed, "
              f"so {'it' if len(passing) == 1 else 'they'} can come off {path.name}: "
              + " ".join(case for case, _ in passing))
        if os.environ.get("GITHUB_ACTIONS") == "true":
            for case, entry in passing:
                print(f"::notice file={path},line={entry.line},title=h2spec {port}::"
                      f"{case} passes now, so it can come off the list")

    # The cases that failed or were skipped without being listed so.
    wrong = 0
    for case, description, outcome, detail in run:
        entry = listed.get(case)
        if outcome == "passed" or (entry is not None and entry.allows(outcome)):
            continue
        wrong += 1
        if entry is None:
            print(f"h2spec {port}: {case} {outcome}, and is not listed: {description}")
        else:
            print(f"h2spec {port}: {case} {outcome}, but is listed {entry.how()}: {description}")
        for line in explain(detail):
            print(line)
    ran = {case for case, _, _, _ in run}
    stale = 0
    for case in listed:
        if case not in ran:
            stale += 1
            print(f"h2spec {port}: {case} is listed in {path.name}, but h2spec ran no such case")
    if wrong:
        print(f"h2spec {port}: {plural(wrong, 'case', 'cases')} failed or "
              f"{'was' if wrong == 1 else 'were'} skipped, and {path.name} does not list "
              f"{'it' if wrong == 1 else 'them'} with that outcome")
    if stale:
        print(f"h2spec {port}: {plural(stale, 'listed case', 'listed cases')} did not run, "
              f"so {path.name} is out of date")
    if wrong or stale:
        return 1
    print(f"h2spec {port}: every case passed or is listed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
