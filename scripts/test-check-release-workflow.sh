#!/bin/sh
# Tests of the check of the release workflow
# (scripts/check-release-workflow.sh). The check must pass on the workflow
# as it is. Each other test copies it, changes one thing in the copy with
# yq, and expects the check to fail and to say what is wrong: each change
# would let a run publish where it should not, or publish without the
# checks a release waits for (docs/releasing.md, "What a tag does"): that
# the tag names moon.mod's version, that CI passed on the tagged commit,
# and that the latest weekly mutation run is clean in the packages at L4
# (#316).
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-release-workflow.sh
#
# The ${{ ... }} and $(...) below are the workflow's own syntax, which the
# shell must leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/release.yml
runs=.github/workflows/mutation-runs.yml

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# The plan's steps, as yq selects them.
tag_step='.jobs.plan.steps[] | select((.run // "") | test("check-tag-version"))'
ci_step='.jobs.plan.steps[] | select((.run // "") | test("check-ci-passed"))'
weekly_step='.jobs.plan.steps[] | select((.run // "") | test("check-weekly-run"))'
checkout_step='.jobs.plan.steps[] | select((.uses // "") | test("^actions/checkout@"))'

# check <name>: runs the check on the copies of the release workflow and
# of the bulk mutation runs' workflow, its output into $tmp/<name>.out and
# its exit status into $tmp/<name>.status.
check() {
  status=0
  scripts/check-release-workflow.sh "$tmp/release.yml" "$tmp/mutation-runs.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# changed <name> <file> <copy> <yq expression>: fresh copies of both
# workflows, the expression applied to the copy of <file>; fails the test
# <name> when the expression changed nothing.
changed() {
  cp "$workflow" "$tmp/release.yml"
  cp "$runs" "$tmp/mutation-runs.yml"
  yq --inplace "$4" "$3"
  if cmp -s "$2" "$3"; then
    fail "$1: the change left the workflow as it was"
    return 1
  fi
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the release workflow, the check exits 1 and prints
# each message; refuses_runs: applied to a fresh copy of the bulk mutation
# runs' workflow.
refuses() {
  name=$1
  changed "$name" "$workflow" "$tmp/release.yml" "$2" || return 0
  shift 2
  said "$name" "$@"
}
refuses_runs() {
  name=$1
  changed "$name" "$runs" "$tmp/mutation-runs.yml" "$2" || return 0
  shift 2
  said "$name" "$@"
}

# said <name> <message>...: the check exits 1 and prints each message.
said() {
  name=$1
  shift
  check "$name"
  if [ "$(cat "$tmp/$name.status")" != 1 ]; then
    fail "$name: exits with $(cat "$tmp/$name.status"), not 1: $(cat "$tmp/$name.out")"
    return
  fi
  for message in "$@"; do
    if grep -qF -- "$message" "$tmp/$name.out"; then
      pass "$name: says \"$message\""
    else
      fail "$name: does not say \"$message\" but: $(cat "$tmp/$name.out")"
    fi
  done
}

# --- The workflow as it is -----------------------------------------------------

cp "$workflow" "$tmp/release.yml"
cp "$runs" "$tmp/mutation-runs.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

# --- Only for pushed version tags, and by hand ------------------------------------

refuses on-pull-requests \
  '.on.pull_request = {}' \
  "it should run on push and workflow_dispatch only, not on: pull_request push workflow_dispatch"

refuses on-pushed-branches \
  '.on.push.branches = ["main"]' \
  "it should run on pushed tags only, but on.push has: branches tags"

refuses on-other-tags \
  '.on.push.tags = ["release-*"]' \
  "it should run on version tags (v*) only, not on release-*"

refuses default-write-permission \
  '.permissions.contents = "write"' \
  "its default permissions should be read-only"

refuses a-secret \
  '.jobs.build.env.TOKEN = "${{ secrets.TOKEN }}"' \
  "it should use no secrets, only its own token"

refuses a-job-that-publishes-on-a-run-by-hand \
  'del(.jobs."publish-image".if)' \
  "job publish-image gets a write permission, so it should run only if: github.event_name == 'push' && github.ref_type == 'tag'"

# --- The checks a release waits for -----------------------------------------------

refuses publishes-without-the-plan \
  '.jobs."publish-image".needs = ["build"]' \
  "job publish-image gets a write permission, so it should need plan, whose checks a release waits for"

refuses releases-without-the-plan \
  '.jobs.release.needs = ["publish-image", "publish-chart"]' \
  "job release gets a write permission, so it should need plan, whose checks a release waits for"

refuses no-tag-check \
  "del($tag_step)" \
  "job plan should check that the tag names the version in moon.mod, for a pushed tag: scripts/check-tag-version.sh \"\$VERSION\""

refuses no-ci-check \
  "del($ci_step)" \
  "job plan should check that CI passed on the tagged commit, for a pushed tag: scripts/check-ci-passed.sh \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses no-weekly-run-check \
  "del($weekly_step)" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-on-another-commit \
  "($weekly_step | .run) = \"python3 scripts/check-weekly-run.py \\\"\$(git rev-parse HEAD~1)\\\"\"" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-by-hand-only \
  "($weekly_step | .if) = \"github.event_name == 'workflow_dispatch'\"" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-without-a-token \
  "del($weekly_step | .env.GH_TOKEN)" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-that-may-fail \
  "($weekly_step | .\"continue-on-error\") = true" \
  "job plan should not continue on error, nor any of its steps"

refuses ci-check-hidden \
  "($ci_step | .run) |= . + \" || true\"" \
  "job plan should check that CI passed on the tagged commit, for a pushed tag: scripts/check-ci-passed.sh \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses a-plan-that-may-fail \
  '.jobs.plan."continue-on-error" = true' \
  "job plan should not continue on error, nor any of its steps"

refuses a-shallow-plan \
  "del($checkout_step | .with)" \
  "job plan should check out the whole history (fetch-depth: 0), which scripts/check-weekly-run.py reads"

refuses a-plan-that-cannot-read-runs \
  'del(.jobs.plan.permissions.actions)' \
  "job plan should read the Actions API (actions: read), which its checks of CI's run and of the weekly run ask"

# --- The weekly run's jobs that the release reads -------------------------------

# The release's check of the latest weekly run reads the run's jobs by the
# names that mutation-runs.yml gives them, and only those that decide a
# verdict (the maintainer, 2026-11-20, on #316 with #342). Its table of
# them (scripts/check-weekly-run.py, JOBS) must name every job that a
# weekly run holds, as the workflow names it and of the kind it is: a
# renamed job would stop every release, and a new one would go unread.
knows="scripts/check-weekly-run.py knows the weekly run's job"
unknown="runs in a weekly run, but scripts/check-weekly-run.py does not say whether it decides a verdict (its JOBS)"
in_runs="but $tmp/mutation-runs.yml has no such job in a weekly run"

refuses_runs a-renamed-job \
  '.jobs.seeds.name = "Seeds (weekly)"' \
  "$knows \"Properties with random seeds (weekly)\", a job, $in_runs" \
  "job seeds (\"Seeds (weekly)\") $unknown"

# A job with no name is named by its key, as GitHub names it.
refuses_runs a-job-without-a-name \
  'del(.jobs.seeds.name)' \
  "$knows \"Properties with random seeds (weekly)\", a job, $in_runs" \
  "job seeds (\"seeds\") $unknown"

# The jobs that decide no verdict are held to it too: the release must
# know that they decide none.
refuses_runs a-renamed-report \
  '.jobs."coverage-e2e".name = "Coverage (weekly)"' \
  "$knows \"Coverage from e2e (weekly)\", a call of a workflow, $in_runs" \
  "job coverage-e2e (\"Coverage (weekly)\") $unknown"

refuses_runs a-new-job \
  '.jobs.selftest = {"name": "Self-test (weekly)", "needs": "plan", "if": "needs.plan.outputs.mode == '"'weekly'"'", "runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
  "job selftest (\"Self-test (weekly)\") $unknown"

refuses_runs a-new-job-of-every-run \
  '.jobs.notes = {"name": "Notes", "needs": "plan", "runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
  "job notes (\"Notes\") $unknown"

refuses_runs a-new-job-of-two-modes \
  '.jobs.both = {"name": "Both", "needs": "plan", "if": "needs.plan.outputs.mode == '"'monthly'"' || needs.plan.outputs.mode == '"'weekly'"'", "runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
  "job both (\"Both\") $unknown"

# Of the kind it reads: the canary as a call of a workflow, whose jobs the
# API names "<the caller's job> / <its own job>", and the shards as a
# matrix, a job for each shard.
refuses_runs a-canary-not-called \
  '.jobs.canary = {"name": "Canary (weekly)", "needs": "plan", "if": "needs.plan.outputs.mode == '"'weekly'"'", "runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
  "$knows \"Canary (weekly)\", a call of a workflow, $in_runs"

refuses_runs shards-without-a-matrix \
  'del(.jobs.shard.strategy)' \
  "$knows \"shard \${{ matrix.name }}\", a matrix of jobs, $in_runs"

# When the release's check cannot list the jobs it knows, the check fails.
mkdir -p "$tmp/no-python"
printf '#!/bin/sh\necho "python3: cannot run" >&2\nexit 1\n' >"$tmp/no-python/python3"
chmod +x "$tmp/no-python/python3"
cp "$workflow" "$tmp/release.yml"
cp "$runs" "$tmp/mutation-runs.yml"
status=0
PATH="$tmp/no-python:$PATH" scripts/check-release-workflow.sh "$tmp/release.yml" "$tmp/mutation-runs.yml" \
  >"$tmp/no-table.out" 2>&1 || status=$?
if [ "$status" = 1 ] &&
  grep -qF "scripts/check-weekly-run.py --jobs does not list the weekly run's jobs it knows" "$tmp/no-table.out"; then
  pass "no-table: fails, and says that the jobs cannot be listed"
else
  fail "no-table: exits with $status: $(cat "$tmp/no-table.out")"
fi

# A job that runs only in another mode is not the weekly run's.
changed a-monthly-job "$runs" "$tmp/mutation-runs.yml" \
  '.jobs.e2e = {"name": "Server through e2e (monthly)", "needs": "plan", "if": "needs.plan.outputs.mode == '"'monthly'"'", "runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}'
check a-monthly-job
if [ "$(cat "$tmp/a-monthly-job.status")" = 0 ]; then
  pass "a-monthly-job: passes"
else
  fail "a-monthly-job: does not pass: $(cat "$tmp/a-monthly-job.out")"
fi

echo
echo "test-check-release-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
