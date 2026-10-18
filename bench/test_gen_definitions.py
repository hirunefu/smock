"""Tests of bench/gen_definitions.py, which writes the release benchmark's
definition sets: bench/definitions/ and its Scenario variant,
bench/definitions-scenarios/.

They read the files it wrote, which CI checks are what it writes, and run
it on a copy of bench/. They need python3 alone. e2e/bench_test.mbt checks
the sets against smock itself.

usage: python3 -m unittest discover -s bench -v
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent
SCRIPT = BENCH / "gen_definitions.py"


def definition_files(directory):
    """The Definition files of a definitions directory, by name: {name:
    content}."""
    return {path.name: json.loads(path.read_text()) for path in sorted(Path(directory).glob("*.json"))}


def stubs_of(files):
    """The Stubs of Definition files, in their files' order, each with the
    name of its file: [(file, stub)]."""
    return [(name, stub) for name, content in files.items() for stub in content.get("stubs", [])]


class ScenarioVariant(unittest.TestCase):
    """The Scenario variant serves what the plain set does, but each Stub
    that a request of the mix names has a Scenario clause, and a twin right
    after it with the same request and response: the two take turns, so
    that every request of the mix matches one of them and moves its
    Scenario."""

    # Each Scenario Stub of the variant, in order: its file, its ID, and
    # its clause.
    SCENARIO_STUBS = [
        (file, stub_id, {"name": name, "requires": requires, "moveTo": move_to})
        for file, stub, name in (
            ("catalog.json", "catalog-item-00317", "catalog-item"),
            ("catalog.json", "catalog-search", "catalog-search"),
            ("orders.json", "create-order-partner-gold", "create-order"),
            ("orders.json", "get-order", "get-order"),
            ("orders.json", "update-order-status", "update-order-status"),
            ("payments.json", "create-payment-eur", "create-payment"),
            ("payments.json", "payment-000042", "legacy-payment"),
            ("users.json", "user-10042", "user-profile"),
            ("users.json", "user-preferences", "user-preferences"),
        )
        for stub_id, requires, move_to in ((stub, "Started", "Seen"), (f"{stub}-seen", "Seen", "Started"))
    ]

    def setUp(self):
        self.plain = definition_files(BENCH / "definitions")
        self.variant = definition_files(BENCH / "definitions-scenarios")

    def test_each_stub_the_mix_names_has_a_clause_and_a_twin_that_moves_the_scenario_back(self):
        found = [(file, stub["id"], stub["scenario"]) for file, stub in stubs_of(self.variant) if "scenario" in stub]
        self.assertEqual(found, self.SCENARIO_STUBS)
        # Each twin follows its Stub, with the same Mock, request and
        # response.
        stubs = [stub for _, stub in stubs_of(self.variant)]
        for at, stub in enumerate(stubs):
            if stub["id"].endswith("-seen"):
                before = stubs[at - 1]
                self.assertEqual(before["id"], stub["id"].removesuffix("-seen"))
                self.assertEqual({key: value for key, value in before.items() if key not in ("id", "scenario")},
                                 {key: value for key, value in stub.items() if key not in ("id", "scenario")})

    def test_without_its_scenario_stubs_clauses_and_twins_it_is_the_plain_set(self):
        self.assertEqual(sorted(self.variant), sorted(self.plain))
        without = {
            name: {key: [{member: value for member, value in item.items() if member != "scenario"}
                         for item in items if not item["id"].endswith("-seen")] if key == "stubs" else items
                   for key, items in content.items()}
            for name, content in self.variant.items()}
        self.assertEqual(without, self.plain)
        self.assertEqual((BENCH / "definitions-scenarios" / "files" / "search-results.json").read_bytes(),
                         (BENCH / "definitions" / "files" / "search-results.json").read_bytes())
        self.assertEqual(len(stubs_of(self.variant)), len(stubs_of(self.plain)) + 9)


class Check(unittest.TestCase):
    """--check writes nothing, and fails when a file of either set is not
    what the script writes, naming it."""

    def copy(self):
        """A copy of what the script reads and writes, in a directory of its
        own: the script, the request mix and both sets."""
        bench = Path(tempfile.mkdtemp(prefix="smock-gen-definitions-test-")) / "bench"
        self.addCleanup(shutil.rmtree, bench.parent, ignore_errors=True)
        bench.mkdir()
        for name in ("gen_definitions.py", "requests.json"):
            shutil.copy2(BENCH / name, bench / name)
        for name in ("definitions", "definitions-scenarios"):
            shutil.copytree(BENCH / name, bench / name)
        return bench

    def run_script(self, bench, *args):
        result = subprocess.run([sys.executable, str(bench / "gen_definitions.py"), *args], capture_output=True,
                                text=True)
        return result.returncode, result.stdout + result.stderr

    def test_both_sets_as_written_pass(self):
        status, output = self.run_script(BENCH, "--check")
        self.assertEqual(status, 0, output)
        self.assertEqual(output, "gen_definitions: bench/definitions/ and bench/definitions-scenarios/ are up to date "
                                 "(12 files)\n")

    def test_a_changed_or_missing_file_of_the_variant_fails_and_is_named_and_a_run_writes_it_again(self):
        bench = self.copy()
        orders = bench / "definitions-scenarios" / "orders.json"
        orders.write_text(orders.read_text().replace('"moveTo": "Seen"', '"moveTo": "Paid"'))
        (bench / "definitions-scenarios" / "files" / "search-results.json").unlink()
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 1, output)
        self.assertEqual(output, "gen_definitions: bench/definitions-scenarios/files/search-results.json is not what "
                                 "the script writes\n"
                                 "gen_definitions: bench/definitions-scenarios/orders.json is not what the script "
                                 "writes\n"
                                 "gen_definitions: run python3 bench/gen_definitions.py and commit the result\n")
        status, output = self.run_script(bench)
        self.assertEqual((status, output), (0, "gen_definitions: wrote 12 files to bench/definitions/ and "
                                               "bench/definitions-scenarios/\n"))
        status, output = self.run_script(bench, "--check")
        self.assertEqual(status, 0, output)


if __name__ == "__main__":
    unittest.main()
