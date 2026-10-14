#!/usr/bin/env python3
"""Compares two runs of the release benchmark.

It reads the summary.json of an older and of a newer run, as bench/bench.py
run writes it on this machine and scripts/gke-bench.sh on GKE Autopilot, and
reports, for each step both ran (a case under a profile at a rate), how p99
and p99.9 changed. A step is a regression when either got worse by more
than the rule of bench/targets.json (its `regression` entry). Only steps at
or below the rate of their profile's entry in that file count: above it
smock may be past its capacity, and the latencies of a queue swing from run
to run, so those steps are shown for reference. p99.9 counts only where both
runs measured at least the rule's number of requests at the step. It also
lists the targets the newer run missed. It exits with 1 when it finds a
regression or a missed target, or when the newer run did not measure a step
that counts and that the older one measured (it stopped early, left the
step out, or its load generator fell behind), and 2 when it cannot compare.

usage: python3 bench/compare.py <older> <newer> [--targets FILE]

<older> and <newer> are summary.json files or the directories that hold
them. Compare runs of the same kind: two runs on the same machine, or two
GKE runs.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent

# bench/bench.py, for the layout of the summaries it writes.
_spec = importlib.util.spec_from_file_location("bench_harness", BENCH / "bench.py")
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

LATENCIES = (("p99", "p99"), ("p99_9", "p99.9"))


class CompareError(Exception):
    """A problem that stops the comparison."""


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise CompareError(f"cannot read {path}: {error}") from error


def read_run(path):
    """A run's summary, and its conditions or None when there is no
    conditions.json beside the summary."""
    path = Path(path)
    if path.is_dir():
        path = path / "summary.json"
    summary = read_json(path)
    if summary.get("format") != harness.FORMAT:
        raise CompareError(f"{path} has format {summary.get('format')}; this compares summaries of format "
                           f"{harness.FORMAT}, as bench/bench.py writes them now")
    conditions_path = path.parent / "conditions.json"
    return summary, read_json(conditions_path) if conditions_path.exists() else None


RULE_KEYS = ("more_than_percent", "more_than_ms", "p99_9_min_requests")


def read_targets(path):
    """The regression rule of a targets file, by how many percent and how
    many milliseconds p99 or p99.9 may get worse at most and how many
    requests p99.9 needs to count, and the target rate of each profile it
    has an entry for."""
    targets = read_json(path)
    rule = targets.get("regression")
    if not isinstance(rule, dict) or not all(isinstance(rule.get(key), (int, float)) for key in RULE_KEYS):
        raise CompareError(f"{path} has no regression rule (regression, with {', '.join(RULE_KEYS[:-1])} "
                           f"and {RULE_KEYS[-1]})")
    rates = {entry["profile"]: entry["rate"] for entry in targets.get("profiles") or []
             if isinstance(entry.get("profile"), str) and isinstance(entry.get("rate"), (int, float))}
    return rule, rates


def number(value):
    return "-" if value is None else str(value)


def change_text(older, newer):
    if older is None or newer is None or older == 0:
        return "-"
    change = round((newer - older) / older * 100, 1)
    if change == 0:
        return "0%"
    return f"{change:+.1f}".removesuffix(".0") + "%"


def worse(older, newer, rule):
    """Whether a latency got worse by more than the rule: by more than its
    percentage and by more than its milliseconds."""
    return newer > older * (1 + rule["more_than_percent"] / 100) and newer - older > rule["more_than_ms"]


def step_key(step):
    return step["profile"], step["case"], step["rate"]


def step_name(step):
    return f"{step['case']}@{step['profile']}@{step['rate']}"


def limits_text(step):
    memory = step["memory_limit"] or "no memory limit"
    return f"{step['cpu_limit']} CPU and {memory}"


def failed_text(step):
    return f"{step['errors']} of {step['requests']['scheduled']} requests failed"


def not_measured(step, run):
    """Why a step of `run` (older or newer) did not measure smock's
    latency, or None when it did."""
    if not step["smock_ready"]:
        return f"smock was not ready in the {run} run"
    if step["errors"]:
        return f"{failed_text(step)} in the {run} run"
    if step["load_generator_late"]:
        return f"the load generator fell behind in the {run} run"
    if any(step["latency_ms"][metric] is None for metric, _ in LATENCIES):
        return f"the {run} run has no latencies"
    return None


def measured_requests(step):
    """How many requests of a step have a latency: those that got a
    response."""
    return step["requests"]["ok"] + step["requests"]["unexpected_status"]


def compare_step(older, newer, rule, counted):
    """The cells of the row of a step both runs ran, whether it is a
    regression, and whether the newer run left it unmeasured where the older
    run measured it. A step the older run did not measure is not compared.
    Requests the newer run failed, where the older run measured the step,
    are a regression, and so is a p99 or p99.9 worse by more than the
    rule. p99.9 counts only where both runs measured at least the rule's
    number of requests; elsewhere its change is marked for reference. The
    verdict of a step that does not count, shown for reference, says what
    happened without calling it a regression."""
    enough = min(measured_requests(older), measured_requests(newer)) >= rule["p99_9_min_requests"]
    metrics = [metric for metric, _ in LATENCIES if metric != "p99_9" or enough]
    cells = {}
    for metric, name in LATENCIES:
        before, after = older["latency_ms"][metric], newer["latency_ms"][metric]
        change = change_text(before, after)
        cells[f"{name} ms"] = f"{number(before)} → {number(after)}"
        cells[f"{name} change"] = change if metric in metrics or change == "-" else f"{change} (for reference)"
    if (older["cpu_limit"], older["memory_limit"]) != (newer["cpu_limit"], newer["memory_limit"]):
        why = f"the older run had {limits_text(older)}, the newer {limits_text(newer)}"
        return {**cells, "Verdict": f"not compared: {why}"}, False, False
    why = not_measured(older, "older")
    if why:
        return {**cells, "Verdict": f"not compared: {why}"}, False, False
    why = not_measured(newer, "newer")
    if not newer["smock_ready"] or newer["errors"]:
        return {**cells, "Verdict": f"regression: {why}" if counted else why}, True, False
    if why:
        return {**cells, "Verdict": f"not compared: {why}"}, False, True
    regression = any(worse(older["latency_ms"][metric], newer["latency_ms"][metric], rule) for metric in metrics)
    return {**cells, "Verdict": ("regression" if counted else "worse") if regression else "ok"}, regression, False


def where(conditions):
    """Where a run ran, for people."""
    machine = conditions["machine"]
    place = f"{machine['architecture']} ({machine['cpu_model']}, {machine['cpus']} CPUs)"
    gke = conditions.get("gke")
    if gke:
        place = f"GKE Autopilot ({gke['zone']}, {gke['compute_class']}), {place}"
    return place


def run_line(name, conditions):
    if conditions is None:
        return f"- {name}: no conditions.json beside its summary."
    smock = conditions["smock"]
    return (f"- {name}: smock {smock['version']} (commit {smock['commit']}) on {where(conditions)}, "
            f"plan {conditions['plan']['file']}, started {conditions['started_at']}.")


# The conditions besides smock that change what a run measures: for each, a
# name and how a run shows it.
CONDITIONS = (
    ("machine", where),
    ("plan", lambda conditions: (conditions["plan"]["file"], conditions["plan"]["sha256"])),
    ("request mix", lambda conditions: conditions["request_mix"]["sha256"]),
    ("definition set", lambda conditions: conditions["definitions"]["digest"]),
    ("load generator", lambda conditions: conditions["load_generator"]["version"]),
    ("options that changed the plan", lambda conditions: conditions.get("overrides") or "none"),
)


def difference(name, before, after):
    if name == "plan" and before[0] == after[0]:
        return f"plan ({after[0]} changed)"
    if isinstance(before, tuple):
        before, after = before[0], after[0]
    return f"{name} ({before} → {after})"


def runs_section(older, newer):
    lines = [run_line("Older", older), run_line("Newer", newer)]
    if older is None or newer is None:
        return lines
    if bool(older.get("gke")) != bool(newer.get("gke")):
        lines += ["", "One run is on GKE Autopilot and the other is not: compare runs of the same kind."]
    differences = [difference(name, shown(older), shown(newer)) for name, shown in CONDITIONS
                   if shown(older) != shown(newer)]
    if differences:
        lines += ["", f"Besides smock, the runs differ in: {', '.join(differences)}."]
    else:
        lines += ["", "Besides smock, the runs had the same conditions."]
    return lines


def counts(step, rates):
    """Whether a step counts: its rate is at most its profile's target
    rate, or its profile has none. Above it, smock may be past its
    capacity, and the latencies of a queue swing from run to run."""
    return step["profile"] not in rates or step["rate"] <= rates[step["profile"]]


def rule_line(rule, rates, steps):
    """Which of `steps` count, and when one is a regression, for people."""
    profiles = list(dict.fromkeys(step["profile"] for step in steps))
    with_rate = [f"{profile} {rates[profile]:,} requests/s" for profile in profiles if profile in rates]
    without = [profile for profile in profiles if profile not in rates]
    which = "Every step counts."
    if with_rate:
        which = (f"A step counts when its rate is at most its profile's target rate ({', '.join(with_rate)})"
                 + (f", or its profile has no target ({', '.join(without)})" if without else "")
                 + "; steps above it are shown for reference and do not count.")
    return (f"{which} A step is a regression when p99 or p99.9 got worse by more than {rule['more_than_percent']}% "
            f"and by more than {rule['more_than_ms']} ms; p99.9 counts only where both runs measured at least "
            f"{rule['p99_9_min_requests']:,} requests at the step.")


COLUMNS = ("Profile", "Case", "Rate", "p99 ms", "p99 change", "p99.9 ms", "p99.9 change", "Verdict")


def latency_table(older, newer, rule, rates, counted):
    """The table of the steps that count (or of those that do not), with
    the steps of them only one run has under it, and how many regressions
    and steps the newer run left unmeasured it found among them."""
    older_steps = {step_key(step): step for step in older["cases"] if counts(step, rates) == counted}
    newer_steps = {step_key(step): step for step in newer["cases"] if counts(step, rates) == counted}
    rows, regressions, unmeasured = [], 0, 0
    for key, step in newer_steps.items():
        if key not in older_steps:
            continue
        cells, regression, left_unmeasured = compare_step(older_steps[key], step, rule, counted)
        regressions += regression
        unmeasured += left_unmeasured
        rows.append({"Profile": step["profile"], "Case": step["case"], "Rate": f"{step['rate']:,}", **cells})
    lines = ["| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS),
             *("| " + " | ".join(row[column] for column in COLUMNS) + " |" for row in rows)]
    only_older = [step_name(step) for key, step in older_steps.items() if key not in newer_steps]
    # A step the older run measured and the newer did not run says nothing
    # of how smock did there: a run cut short must not pass.
    unmeasured += sum(1 for key, step in older_steps.items()
                      if key not in newer_steps and not not_measured(step, "older"))
    only_newer = [step_name(step) for key, step in newer_steps.items() if key not in older_steps]
    if only_older or only_newer:
        lines.append("")
    if only_older:
        lines.append(f"Only in the older run: {', '.join(only_older)}.")
    if only_newer:
        lines.append(f"Only in the newer run: {', '.join(only_newer)}.")
    return lines, regressions, unmeasured


def report(older_run, newer_run, rule, rates):
    """The comparison for people, in Markdown, and how many regressions,
    missed targets and steps the newer run left unmeasured it found among
    the steps that count."""
    (older, older_conditions), (newer, newer_conditions) = older_run, newer_run
    incomplete = [f"The {name} run is incomplete: it stopped before its last step."
                  for name, summary in (("older", older), ("newer", newer)) if not summary["complete"]]
    lines = ["# Benchmark comparison", "", *runs_section(older_conditions, newer_conditions), "",
             *(line for text in incomplete for line in (text, "")),
             rule_line(rule, rates, [*older["cases"], *newer["cases"]]), "", "## Latency", ""]
    table, regressions, unmeasured = latency_table(older, newer, rule, rates, True)
    lines += table
    if not all(counts(step, rates) for step in [*older["cases"], *newer["cases"]]):
        # They are listed, and what the newer run did there does not fail it.
        table, _, _ = latency_table(older, newer, rule, rates, False)
        lines += ["", "## For reference: steps above the target rate", "", *table]
    missed, target_lines = targets_section(older, newer)
    lines += ["", "## Targets", "", *target_lines, "", result_line(regressions, missed, unmeasured)]
    return "\n".join(lines) + "\n", regressions + missed + unmeasured


def measured_text(target):
    return "nothing measured" if target["measured"] is None else f"{target['measured']} {target['unit']}"


def older_verdict(target, older):
    """What the older run did for a target the newer one missed."""
    before = next((other for other in older["targets"] if other["id"] == target["id"]), None)
    if before is None:
        return "not in the older run"
    if before["verdict"] == "met":
        return f"met in the older run ({measured_text(before)})"
    if before["verdict"] == "missed":
        return f"missed in the older run too ({measured_text(before)})"
    return "not measured in the older run"


def targets_section(older, newer):
    """How many targets the newer run missed, and the lines that list
    them, with the targets it did not measure."""
    missed = [target for target in newer["targets"] if target["verdict"] == "missed"]
    lines = ["Targets missed in the newer run: none."]
    if missed:
        lines = ["Targets missed in the newer run:", ""]
        for target in missed:
            reason = f": {target['reason']}" if target["reason"] else ""
            lines.append(f"- {target['id']} ({target['about']}): {measured_text(target)}, "
                         f"at most {target['max']} {target['unit']}{reason}; {older_verdict(target, older)}")
    unmeasured = [target["id"] for target in newer["targets"] if target["verdict"] == "not measured"]
    if unmeasured:
        lines += ["", f"Not measured in the newer run: {', '.join(unmeasured)}."]
    return len(missed), lines


def plural(count, noun):
    return f"{count} {noun}" + ("" if count == 1 else "s")


def result_line(regressions, missed, unmeasured):
    found = plural(regressions, "regression") if regressions else "no regression"
    targets = f"{plural(missed, 'target')} missed" if missed else "no target missed"
    steps = f", {plural(unmeasured, 'step')} the older run measured not measured in the newer one" \
        if unmeasured else ""
    return f"**Result:** {found[0].upper()}{found[1:]}, {targets}{steps}."


def main(argv):
    parser = argparse.ArgumentParser(prog="compare.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("older", help="the older run's summary.json, or its directory")
    parser.add_argument("newer", help="the newer run's summary.json, or its directory")
    parser.add_argument("--targets", default=str(BENCH / "targets.json"),
                        help="the targets file whose regression rule and target rates apply "
                             "(default: bench/targets.json)")
    args = parser.parse_args(argv)
    try:
        rule, rates = read_targets(args.targets)
        text, found = report(read_run(args.older), read_run(args.newer), rule, rates)
    except CompareError as error:
        print(f"compare: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(text)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
