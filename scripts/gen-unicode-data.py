#!/usr/bin/env python3
"""Writes unicode/data.mbt: the Unicode data that the template helpers
`uppercase`, `lowercase` and `trim` read, from one pinned version of the
Unicode Character Database.

- The simple (one-to-one) upper-case and lower-case mappings, fields 12 and
  13 of UnicodeData.txt. SpecialCasing.txt is not read, so a mapping never
  changes the number of code points.
- The code points with the property White_Space, from PropList.txt.

The version is part of format version 1: the data never changes within it,
so that a template gives the same output in every release. The file is
checked in; this script is run again only for a new format version, after
VERSION below is changed.

A mapping is written as runs, each the first and the last code point of
the run, the step between the code points it maps (1, or 2 where upper
and lower case alternate), and what each one's mapping adds to them. The
runs are in order and do not overlap. Before it writes anything, the
script checks the runs against the data for every code point.

usage: python3 scripts/gen-unicode-data.py [--check] [UCD_DIR]
  UCD_DIR  a directory with VERSION's UnicodeData.txt and PropList.txt;
           without it, the script downloads them from unicode.org
  --check  writes nothing; exits 1 if unicode/data.mbt differs from what it
           would write
"""

import hashlib
import sys
import urllib.request
from pathlib import Path

VERSION = "18.0.0"
SOURCE = f"https://www.unicode.org/Public/{VERSION}/ucd/"
FILES = ("UnicodeData.txt", "PropList.txt")
OUT = Path(__file__).resolve().parent.parent / "unicode" / "data.mbt"
LAST_CODE_POINT = 0x10FFFF


def read_files(ucd_dir):
    """The bytes of each of FILES, by name, read from ucd_dir or, without
    one, downloaded."""
    if ucd_dir is not None:
        return {name: (Path(ucd_dir) / name).read_bytes() for name in FILES}
    out = {}
    for name in FILES:
        with urllib.request.urlopen(SOURCE + name, timeout=60) as reply:
            out[name] = reply.read()
    return out


def case_mappings(unicode_data):
    """The simple upper-case and lower-case mappings of UnicodeData.txt,
    each a dict from a code point to the one it maps to."""
    upper, lower = {}, {}
    for line in unicode_data.splitlines():
        fields = line.split(";")
        if len(fields) != 15:
            sys.exit(f"gen-unicode-data: UnicodeData.txt: not 15 fields: {line}")
        code = int(fields[0], 16)
        if fields[12]:
            upper[code] = int(fields[12], 16)
        if fields[13]:
            lower[code] = int(fields[13], 16)
    return upper, lower


def white_space(prop_list):
    """The White_Space ranges of PropList.txt, each (first, last), in
    order. Checks that the file is VERSION's."""
    lines = prop_list.splitlines()
    if not lines or lines[0] != f"# PropList-{VERSION}.txt":
        sys.exit(f"gen-unicode-data: PropList.txt is not version {VERSION}")
    ranges = []
    for line in lines:
        data = line.split("#", 1)[0].strip()
        if not data:
            continue
        codes, prop = (part.strip() for part in data.split(";"))
        if prop != "White_Space":
            continue
        first, _, last = codes.partition("..")
        ranges.append((int(first, 16), int(last or first, 16)))
    ranges.sort()
    merged = []
    for first, last in ranges:
        if merged and first == merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], last)
        else:
            merged.append((first, last))
    return merged


def runs(mapping):
    """The mapping as runs (first, last, step, delta), in order."""
    out = []
    for code in sorted(mapping):
        delta = mapping[code] - code
        if out:
            first, last, step, run_delta = out[-1]
            gap = code - last
            if run_delta == delta and gap in (1, 2) and (first == last or gap == step):
                out[-1] = (first, code, gap, delta)
                continue
        out.append((code, code, 1, delta))
    return out


def check_runs(name, run_list, mapping):
    """Exits when the runs, read as unicode/unicode.mbt reads them, do not
    map every code point as mapping does."""
    for (_, last, _, _), (first, _, _, _) in zip(run_list, run_list[1:]):
        if first <= last:
            sys.exit(f"gen-unicode-data: {name}: runs overlap at {first:04X}")
    run_at = -1
    for code in range(LAST_CODE_POINT + 1):
        # The last run that starts at or before code.
        while run_at + 1 < len(run_list) and run_list[run_at + 1][0] <= code:
            run_at += 1
        got = code
        if run_at >= 0:
            first, last, step, delta = run_list[run_at]
            if code <= last and (code - first) % step == 0:
                got = code + delta
        if got != mapping.get(code, code):
            sys.exit(f"gen-unicode-data: {name}: the runs map {code:04X} wrongly")


def lines(rows):
    """The rows, each a run or a range, as the lines of a MoonBit array
    literal of tuples: code points in hex, the step and the delta in
    decimal."""
    out = []
    for row in rows:
        cells = [f"0x{code:04X}" for code in row[:2]] + [str(n) for n in row[2:]]
        out.append("  (" + ", ".join(cells) + "),")
    return out


def source(files):
    """The text of unicode/data.mbt."""
    unicode_data = files["UnicodeData.txt"].decode("utf-8")
    prop_list = files["PropList.txt"].decode("utf-8")
    upper, lower = case_mappings(unicode_data)
    upper_runs, lower_runs = runs(upper), runs(lower)
    check_runs("upper", upper_runs, upper)
    check_runs("lower", lower_runs, lower)
    spaces = white_space(prop_list)
    sums = "\n".join(
        f"// - {name}: SHA-256 {hashlib.sha256(files[name]).hexdigest()}"
        for name in FILES
    )
    return "\n".join(
        [
            "// Generated by scripts/gen-unicode-data.py. Do not edit.",
            "//",
            f"// From the Unicode Character Database {VERSION}, {SOURCE}:",
            sums,
            "//",
            "// The data is under the Unicode License v3, which NOTICE gives.",
            "",
            "///|",
            "/// The version of the Unicode Character Database the data comes from.",
            f'pub let version : String = "{VERSION}"',
            "",
            "///|",
            "/// The simple upper-case mappings, as runs in order: the first and the",
            "/// last code point of the run, the step between the code points it maps,",
            "/// and what each one's mapping adds to them.",
            "let upper_runs : FixedArray[(Int32, Int32, Int32, Int32)] = [",
            *lines(upper_runs),
            "]",
            "",
            "///|",
            "/// The simple lower-case mappings, as runs like those of `upper_runs`.",
            "let lower_runs : FixedArray[(Int32, Int32, Int32, Int32)] = [",
            *lines(lower_runs),
            "]",
            "",
            "///|",
            "/// The code points with the property White_Space, as ranges in order:",
            "/// the first and the last code point of the range.",
            "let white_space_ranges : FixedArray[(Int32, Int32)] = [",
            *lines(spaces),
            "]",
            "",
        ]
    )


def main(args):
    check = "--check" in args
    rest = [arg for arg in args if arg != "--check"]
    if len(rest) > 1 or any(arg.startswith("-") for arg in rest):
        sys.exit("usage: python3 scripts/gen-unicode-data.py [--check] [UCD_DIR]")
    text = source(read_files(rest[0] if rest else None))
    if check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print(f"gen-unicode-data: {OUT} differs from what Unicode {VERSION} gives")
            return 1
        print(f"gen-unicode-data: {OUT} is what Unicode {VERSION} gives")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"gen-unicode-data: wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
