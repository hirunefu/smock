#!/usr/bin/env python3
"""Judges a run of h2spec against one of smock's ports, from h2spec's JUnit
report and the list of cases that do not pass on that port.

usage: python3 scripts/h2spec-verdict.py <list> <report>

<list> is scripts/h2spec/<port>.txt; its name, without .txt, names the port
in what this prints. <report> is the JUnit report of h2spec 2.6.0
(h2spec -j <report>).

Each line of the list names a case, why it is listed, and the reason in
words, separated by spaces; a line that starts with # is a comment. Why is

  #<issue>  the case fails until that issue is done.

It prints how many cases passed, every listed case with its outcome and
reason, and every case that failed and is not listed, with what h2spec
expected and got. It exits with 1 when such a case failed, and with 2 when
it cannot read the list or the report.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


class ListError(Exception):
    """A line of the list that cannot be read."""


def cases(report):
    """The cases of a JUnit report, in order: (ID, description, outcome,
    detail), where the detail of a failed case is what h2spec expected and
    got, one line each.

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
    """The entries of a list, by case: {ID: (why, reason)}."""
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split(None, 2)
        if len(fields) < 3:
            raise ListError(f"{path.name}:{number}: give the case, why it is listed, and the reason")
        case, why, reason = fields
        if not re.fullmatch(r"#[0-9]+", why):
            raise ListError(f"{path.name}:{number}: {case} is listed as {why!r}, not as #<issue>")
        entries[case] = (why, reason.strip())
    return entries


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
    run = cases(argv[2])
    counts = {outcome: sum(1 for _, _, o, _ in run if o == outcome) for outcome in ("passed", "skipped", "failed")}
    print(f"h2spec {port}: {len(run)} cases, {counts['passed']} passed, {counts['skipped']} skipped, "
          f"{counts['failed']} failed")

    if listed:
        print(f"h2spec {port}: listed in {path.name}, with the reason:")
    for case, description, outcome, detail in run:
        if case not in listed:
            continue
        why, reason = listed[case]
        print(f"  {case} {outcome}, as listed until {why}: {reason}")

    unlisted = 0
    for case, description, outcome, detail in run:
        if outcome == "passed" or case in listed:
            continue
        unlisted += 1
        print(f"h2spec {port}: {case} {outcome}, and is not listed: {description}")
        for line in detail.splitlines():
            print(f"    {line}")
    if unlisted:
        print(f"h2spec {port}: {unlisted} {'case' if unlisted == 1 else 'cases'} failed or was skipped "
              f"without being listed in {path.name}")
        return 1
    print(f"h2spec {port}: every case passed or is listed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
