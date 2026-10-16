#!/usr/bin/env python3
"""Compares two runs of the release benchmark.

It reads the summary.json of an older and of a newer run, as bench/bench.py
run writes it on this machine and scripts/gke-bench.sh on GKE Autopilot, and
reports, for each step both ran (a case under a profile at a rate), how p99
and p99.9 changed. A step is a regression when either got worse by more
than the rule of bench/targets.json (its `regression` entry). Only steps at
or below the rate of their profile's entry in that file, for the newer
run's CPU architecture, count: above it smock may be past its capacity, and
the latencies of a queue swing from run to run, so those steps are shown
for reference. p99.9 counts only where both runs measured at least the
rule's number of requests at the step. Where both runs measured smock's CPU
time a request at a step, it shows how that changed too, for information
only, and for two GKE runs, whether smock's node had another CPU under each
profile. It also lists the targets the newer run missed. It exits with 1 when
it finds a regression or a missed target, or when the newer run did not
measure a step that counts and that the older one measured (it stopped
early, left the step out, or its load generator fell behind), and 2 when it
cannot compare.

usage: python3 bench/compare.py <older> <newer> [--targets FILE]

<older> and <newer> are summary.json files or the directories that hold
them. Compare runs of the same kind: two runs on the same machine, or two
GKE runs. Runs on different CPU architectures are not compared step by
step: their latencies differ by more than smock.
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
    requests p99.9 needs to count, and for each architecture it has
    targets for, the target rate of each profile it has an entry for
    ({architecture: {profile: rate}}): the highest, when it has entries at
    several rates, so that no step a target holds at is left out."""
    targets = read_json(path)
    rule = targets.get("regression")
    if not isinstance(rule, dict) or not all(isinstance(rule.get(key), (int, float)) for key in RULE_KEYS):
        raise CompareError(f"{path} has no regression rule (regression, with {', '.join(RULE_KEYS[:-1])} "
                           f"and {RULE_KEYS[-1]})")
    by_architecture = {}
    architectures = targets.get("architectures")
    for name, value in (architectures if isinstance(architectures, dict) else {}).items():
        rates = by_architecture[name] = {}
        for entry in (value.get("profiles") if isinstance(value, dict) else None) or []:
            if isinstance(entry, dict) and isinstance(entry.get("profile"), str) and \
                    isinstance(entry.get("rate"), (int, float)):
                rates[entry["profile"]] = max(entry["rate"], rates.get(entry["profile"], entry["rate"]))
    return rule, by_architecture


def number(value):
    return "-" if value is None else str(value)


def percent_text(change):
    """A change in percent, for people: to one digit, signed, 0% when it
    rounds to none, and - when it is unknown."""
    if change is None:
        return "-"
    change = round(change, 1)
    if change == 0:
        return "0%"
    return f"{change:+.1f}".removesuffix(".0") + "%"


def change_text(older, newer):
    if older is None or newer is None or older == 0:
        return "-"
    return percent_text((newer - older) / older * 100)


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


def compare_step(older, newer, rule, counted, architectures=None):
    """The cells of the row of a step both runs ran, whether it is a
    regression, and whether the newer run left it unmeasured where the older
    run measured it. A step the older run did not measure is not compared,
    nor one the runs ran on different architectures (`architectures`, the
    older's and the newer's, when they differ). Requests the newer run
    failed, where the older run measured the step, are a regression, and so
    is a p99 or p99.9 worse by more than the rule. p99.9 counts only where
    both runs measured at least the rule's number of requests; elsewhere its
    change is marked for reference. The verdict of a step that does not
    count, shown for reference, says what happened without calling it a
    regression."""
    enough = min(measured_requests(older), measured_requests(newer)) >= rule["p99_9_min_requests"]
    metrics = [metric for metric, _ in LATENCIES if metric != "p99_9" or enough]
    cells = {}
    for metric, name in LATENCIES:
        before, after = older["latency_ms"][metric], newer["latency_ms"][metric]
        change = change_text(before, after)
        cells[f"{name} ms"] = f"{number(before)} → {number(after)}"
        cells[f"{name} change"] = change if metric in metrics or change == "-" else f"{change} (for reference)"
    if architectures:
        why = f"the older run ran on {architectures[0]}, the newer on {architectures[1]}"
        return {**cells, "Verdict": f"not compared: {why}"}, False, False
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


def architecture(conditions):
    """The CPU architecture a run ran on, as Kubernetes names it: a GKE run
    names it so, a run on a machine as the kernel does."""
    return harness.kubernetes_architecture(conditions["machine"]["architecture"])


def different_architectures(older, newer):
    """The older and the newer run's architectures when both are known and
    differ, else None."""
    if older is None or newer is None or architecture(older) == architecture(newer):
        return None
    return architecture(older), architecture(newer)


def where(conditions):
    """Where a run ran, for people."""
    place = harness.machine_text(conditions["machine"])
    gke = conditions.get("gke")
    if gke:
        place = f"GKE Autopilot ({gke.get('zone') or gke['region']}, {gke['compute_class']}), {place}"
    return place


def run_line(name, conditions):
    if conditions is None:
        return f"- {name}: no conditions.json beside its summary."
    smock = conditions["smock"]
    return (f"- {name}: smock {harness.known(smock['version'], 'of an unknown version')} (commit "
            f"{harness.known(smock['commit'])}) on {where(conditions)}, plan {conditions['plan']['file']}, started "
            f"{conditions['started_at']}.")


# The conditions besides smock that change what a run measures: for each, a
# name and how a run shows it.
CONDITIONS = (
    ("architecture", architecture),
    ("machine", where),
    ("plan", lambda conditions: (conditions["plan"]["file"], conditions["plan"]["sha256"],
                                 conditions["plan"].get("sha256_without_about"))),
    ("request mix", lambda conditions: conditions["request_mix"]["sha256"]),
    ("definition set", lambda conditions: conditions["definitions"]["digest"]),
    ("load generator", lambda conditions: conditions["load_generator"]["version"]),
    ("options that changed the plan", lambda conditions: conditions.get("overrides") or "none"),
)


def same(name, before, after):
    """Whether the runs had the same condition `name`. The same plan is the
    same file with the same content but for its about, when both runs
    recorded the hash of that; else, as a run from before runs recorded it
    has only the file's hash, the same file with the same hash."""
    if name != "plan":
        return before == after
    if before[2] and after[2]:
        return (before[0], before[2]) == (after[0], after[2])
    return before[:2] == after[:2]


def difference(name, before, after):
    if name == "plan" and before[0] == after[0]:
        return f"plan ({after[0]} changed)"
    if isinstance(before, tuple):
        before, after = before[0], after[0]
    return f"{name} ({harness.known(before)} → {harness.known(after)})"


def smock_node_cpus(conditions):
    """The CPU of smock's node under each profile of a GKE run, as its
    conditions.json records it ({profile: CPU}), None where it does not:
    a run before the nodes' CPUs were recorded, or one that could not read
    it."""
    cpus = {}
    for name, profile in conditions["gke"].get("profiles", {}).items():
        nodes = profile.get("nodes", {})
        cpus[name] = next((nodes[pod["node"]]["cpu"] for pod in profile.get("smock", [])
                           if (nodes.get(pod.get("node")) or {}).get("cpu")), None)
    return cpus


# What tells a CPU of x86 or of arm64 from another of the same model name.
CPU_IDENTITY = (("cpu_family", "family"), ("model", "model"), ("stepping", "stepping"), ("cpu_variant", "variant"),
                ("cpu_revision", "revision"))


def cpu_name(cpu):
    """A node's CPU model, for people: its model name, then its family,
    model and stepping (or on arm64, its variant and revision)."""
    identity = [f"{label} {cpu[key]}" for key, label in CPU_IDENTITY if cpu.get(key) is not None]
    return f"{cpu['model_name']} ({', '.join(identity)})" if identity else str(cpu["model_name"])


def flags_text(cpu):
    flags = cpu.get("flags")
    if flags is None:
        return "unknown"
    return " ".join(flag for flag, has in flags.items() if has) or "none"


def cpu_changes(before, after):
    """How the CPU of smock's node changed between two runs, for people:
    its model, microcode, TLS flags and the mitigations of its
    vulnerabilities, each where it changed."""
    changes = []
    if cpu_name(before) != cpu_name(after):
        changes.append(f"model {cpu_name(before)} → {cpu_name(after)}")
    if before.get("microcode") != after.get("microcode"):
        changes.append(f"microcode {before.get('microcode') or 'none'} → {after.get('microcode') or 'none'}")
    if before.get("flags") != after.get("flags"):
        changes.append(f"TLS flags {flags_text(before)} → {flags_text(after)}")
    mitigations = before.get("vulnerabilities") or {}, after.get("vulnerabilities") or {}
    changed = [name for name in sorted({*mitigations[0], *mitigations[1]})
               if mitigations[0].get(name) != mitigations[1].get(name)]
    if changed:
        changes.append(f"mitigations of {', '.join(changed)}")
    return changes


def smock_nodes_section(older, newer):
    """Whether smock's node had another CPU in the newer run than in the
    older, under each profile both GKE runs ran, for people, and whether it
    did under any; nothing unless both runs are on GKE."""
    if not (older.get("gke") and newer.get("gke")):
        return [], False
    before, after = smock_node_cpus(older), smock_node_cpus(newer)
    profiles = [name for name in after if name in before]
    if profiles and not any(before[name] for name in profiles) and not any(after[name] for name in profiles):
        return ["Neither run recorded the CPU of smock's nodes: whether it changed is unknown."], False
    for run, cpus in (("older", before), ("newer", after)):
        if profiles and not any(cpus[name] for name in profiles):
            return [f"The {run} run did not record the CPU of smock's nodes: whether it changed is unknown."], False
    changed = {name: cpu_changes(before[name], after[name]) for name in profiles if before[name] and after[name]}
    unknown = [name for name in profiles if name not in changed]
    lines = []
    if any(changed.values()):
        lines += ["smock's node had another CPU in the newer run, so a change in latency there may be the node's "
                  "rather than smock's:", "",
                  *(f"- {name}: {'; '.join(changes)}." for name, changes in changed.items() if changes)]
    unchanged = [name for name, changes in changed.items() if not changes]
    if unchanged:
        lines += [*([""] if lines else []), "smock's node had the same CPU in both runs (model, microcode, TLS flags "
                  f"and mitigations) under {', '.join(unchanged)}."]
    if unknown:
        lines += [*([""] if lines else []), "Whether smock's node had another CPU is unknown under "
                  f"{', '.join(unknown)}: a run did not record it."]
    return lines, any(changed.values())


def runs_section(older, newer):
    lines = [run_line("Older", older), run_line("Newer", newer)]
    if older is None or newer is None:
        return lines
    if bool(older.get("gke")) != bool(newer.get("gke")):
        lines += ["", "One run is on GKE Autopilot and the other is not: compare runs of the same kind."]
    architectures = different_architectures(older, newer)
    if architectures:
        lines += ["", f"The runs ran on different architectures ({architectures[0]} → {architectures[1]}): no step is "
                      "compared as a regression."]
    differences = [difference(name, shown(older), shown(newer)) for name, shown in CONDITIONS
                   if not same(name, shown(older), shown(newer))]
    nodes, nodes_changed = smock_nodes_section(older, newer)
    if nodes_changed:
        differences.append("the CPU of smock's nodes")
    if differences:
        lines += ["", f"Besides smock, the runs differ in: {', '.join(differences)}."]
    else:
        lines += ["", "Besides smock, the runs had the same conditions."]
    if nodes:
        lines += ["", *nodes]
    return lines


def counts(step, rates):
    """Whether a step counts: its rate is at most its profile's target
    rate, or its profile has none. Above it, smock may be past its
    capacity, and the latencies of a queue swing from run to run."""
    return step["profile"] not in rates or step["rate"] <= rates[step["profile"]]


def target_rates(by_architecture, newer_conditions):
    """The target rate of each profile ({profile: rate}) that decides which
    steps count: those of the newer run's architecture, or none when the
    targets file has none for it or the architecture is unknown. Then,
    for people, why there are none, or None."""
    if newer_conditions is None:
        return {}, ("The newer run's architecture is unknown, with no conditions.json beside its summary: every "
                    "step counts.")
    name = architecture(newer_conditions)
    if name not in by_architecture:
        return {}, f"The targets file has no targets for {name}, the newer run's architecture: every step counts."
    return by_architecture[name], None


def rule_line(rule, rates, steps, architecture_name, no_rates):
    """Which of `steps` count, by the target `rates` of the newer run's
    architecture (`architecture_name`), or why none apply (`no_rates`), and
    when a step is a regression, for people."""
    profiles = list(dict.fromkeys(step["profile"] for step in steps))
    with_rate = [f"{profile} {rates[profile]:,} requests/s" for profile in profiles if profile in rates]
    without = [profile for profile in profiles if profile not in rates]
    which = no_rates or "Every step counts."
    if with_rate:
        which = (f"A step counts when its rate is at most its profile's target rate for {architecture_name}, the "
                 f"newer run's architecture ({', '.join(with_rate)})"
                 + (f", or its profile has no target ({', '.join(without)})" if without else "")
                 + "; steps above it are shown for reference and do not count.")
    return (f"{which} A step is a regression when p99 or p99.9 got worse by more than {rule['more_than_percent']}% "
            f"and by more than {rule['more_than_ms']} ms; p99.9 counts only where both runs measured at least "
            f"{rule['p99_9_min_requests']:,} requests at the step.")


COLUMNS = ("Profile", "Case", "Rate", "p99 ms", "p99 change", "p99.9 ms", "p99.9 change", "Verdict")


def latency_table(older, newer, rule, rates, counted, architectures):
    """The table of the steps that count (or of those that do not), with
    the steps of them only one run has under it, and how many regressions
    and steps the newer run left unmeasured it found among them. Runs on
    different architectures (`architectures`) are not compared."""
    older_steps = {step_key(step): step for step in older["cases"] if counts(step, rates) == counted}
    newer_steps = {step_key(step): step for step in newer["cases"] if counts(step, rates) == counted}
    rows, regressions, unmeasured = [], 0, 0
    for key, step in newer_steps.items():
        if key not in older_steps:
            continue
        cells, regression, left_unmeasured = compare_step(older_steps[key], step, rule, counted, architectures)
        regressions += regression
        unmeasured += left_unmeasured
        rows.append({"Profile": step["profile"], "Case": step["case"], "Rate": f"{step['rate']:,}", **cells})
    lines = ["| " + " | ".join(COLUMNS) + " |", "|" + "---|" * len(COLUMNS),
             *("| " + " | ".join(row[column] for column in COLUMNS) + " |" for row in rows)]
    only_older = [step_name(step) for key, step in older_steps.items() if key not in newer_steps]
    # A step the older run measured and the newer did not run says nothing
    # of how smock did there: a run cut short must not pass, unless the
    # runs are not compared at all.
    unmeasured += sum(1 for key, step in older_steps.items() if not architectures
                      and key not in newer_steps and not not_measured(step, "older"))
    only_newer = [step_name(step) for key, step in newer_steps.items() if key not in older_steps]
    if only_older or only_newer:
        lines.append("")
    if only_older:
        lines.append(f"Only in the older run: {', '.join(only_older)}.")
    if only_newer:
        lines.append(f"Only in the newer run: {', '.join(only_newer)}.")
    return lines, regressions, unmeasured


CPU_COLUMNS = ("Profile", "Case", "Rate", "CPU µs/request", "Change", "CPU % of limit")


def cpu_of(step):
    """What a step measured of smock's CPU (its smock_cpu), or {} when it
    measured nothing, as a run before the CPU a request was measured."""
    return step.get("smock_cpu") or {}


def percent(utilization):
    return "-" if utilization is None else f"{utilization * 100:.1f}"


def cpu_table(older, newer):
    """The lines of the section on smock's CPU time a request at each step
    both runs measured it at, with how it changed; none when no step has it
    in both."""
    older_steps = {step_key(step): step for step in older["cases"]}
    rows = []
    for step in newer["cases"]:
        before, after = cpu_of(older_steps.get(step_key(step)) or {}), cpu_of(step)
        if before.get("us_per_request") is None or after.get("us_per_request") is None:
            continue
        rows.append({"Profile": step["profile"], "Case": step["case"], "Rate": f"{step['rate']:,}",
                     "CPU µs/request": f"{before['us_per_request']} → {after['us_per_request']}",
                     "Change": change_text(before["us_per_request"], after["us_per_request"]),
                     "CPU % of limit": f"{percent(before.get('utilization'))} → {percent(after.get('utilization'))}"})
    if not rows:
        return []
    return ["## CPU per request", "",
            "smock's CPU time during each step's load, ramp and tail included, divided by the requests it answered "
            "then, and that time against the CPU limit, at each step both runs measured them at. For information "
            "only: no change here is a regression, and another machine or CPU model gives other numbers.", "",
            "| " + " | ".join(CPU_COLUMNS) + " |", "|" + "---|" * len(CPU_COLUMNS),
            *("| " + " | ".join(row[column] for column in CPU_COLUMNS) + " |" for row in rows)]


def report(older_run, newer_run, rule, rates_by_architecture):
    """The comparison for people, in Markdown, and how many regressions,
    missed targets and steps the newer run left unmeasured it found among
    the steps that count. The target rates of the newer run's architecture
    (from `rates_by_architecture`) decide which steps count."""
    (older, older_conditions), (newer, newer_conditions) = older_run, newer_run
    rates, no_rates = target_rates(rates_by_architecture, newer_conditions)
    newer_architecture = architecture(newer_conditions) if newer_conditions else None
    incomplete = [f"The {name} run is incomplete: it stopped before its last step."
                  for name, summary in (("older", older), ("newer", newer)) if not summary["complete"]]
    lines = ["# Benchmark comparison", "", *runs_section(older_conditions, newer_conditions), "",
             *(line for text in incomplete for line in (text, "")),
             rule_line(rule, rates, [*older["cases"], *newer["cases"]], newer_architecture, no_rates), "",
             "## Latency", ""]
    architectures = different_architectures(older_conditions, newer_conditions)
    table, regressions, unmeasured = latency_table(older, newer, rule, rates, True, architectures)
    lines += table
    if not all(counts(step, rates) for step in [*older["cases"], *newer["cases"]]):
        # They are listed, and what the newer run did there does not fail it.
        table, _, _ = latency_table(older, newer, rule, rates, False, architectures)
        lines += ["", "## For reference: steps above the target rate", "", *table]
    cpu = cpu_table(older, newer)
    if cpu:
        lines += ["", *cpu]
    missed, target_lines = targets_section(older, newer)
    lines += ["", "## Targets", "", *target_lines, "", result_line(regressions, missed, unmeasured)]
    return "\n".join(lines) + "\n", regressions + missed + unmeasured


def measured_text(target):
    return "nothing measured" if target["measured"] is None else f"{target['measured']} {target['unit']}"


def same_target(target, other):
    """Whether two runs' targets are one: the same id, at the same load,
    for the same architecture when both name it (a summary written before
    the targets were by architecture does not). Under one id, each
    architecture may have its own rate and bounds."""
    def load(one):
        return one["id"], one.get("case"), one.get("rate")

    architectures = target.get("architecture"), other.get("architecture")
    return load(target) == load(other) and (None in architectures or architectures[0] == architectures[1])


def older_verdict(target, older):
    """What the older run did for a target the newer one missed."""
    before = next((other for other in older["targets"] if same_target(target, other)), None)
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
    unmeasured = list(dict.fromkeys(target["id"] for target in newer["targets"]
                                    if target["verdict"] == "not measured"))
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
                        help="the targets file whose regression rule, and whose target rates for the newer run's "
                             "architecture, apply (default: bench/targets.json)")
    args = parser.parse_args(argv)
    try:
        rule, rates_by_architecture = read_targets(args.targets)
        text, found = report(read_run(args.older), read_run(args.newer), rule, rates_by_architecture)
    except CompareError as error:
        print(f"compare: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(text)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
