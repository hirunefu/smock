#!/bin/sh
# Checks the rules of the benchmark workflow (.github/workflows/benchmark.yml):
#
# - it runs only when started by hand (workflow_dispatch), so never on a
#   schedule, on pull requests or on pushes: benchmarks run before an
#   integration branch is merged into main (docs/merging-into-main.md);
# - its permissions are read-only, and it uses no secrets;
# - it runs the benchmark (bench/bench.py run) on linux/amd64 and on
#   linux/arm64;
# - it keeps what the benchmark writes as workflow artifacts, also when the
#   benchmark fails.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-benchmark-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/benchmark.yml}

failed=0
fail() {
  echo "check-benchmark-workflow: $workflow: $*" >&2
  failed=1
}

if [ ! -f "$workflow" ]; then
  echo "check-benchmark-workflow: $workflow does not exist" >&2
  exit 1
fi
json=$(yq --output-format=json "$workflow")

triggers=$(printf '%s\n' "$json" | jq -r '.on | if type == "object" then keys | join(" ") else tostring end')
[ "$triggers" = workflow_dispatch ] ||
  fail "it should run only when started by hand (workflow_dispatch), not on: $triggers"

printf '%s\n' "$json" | jq -e '
  (.permissions | type == "object" and all(.[]; . != "write"))
  and all(.jobs[]; (.permissions // {}) | type == "object" and all(.[]; . != "write"))' >/dev/null ||
  fail "its permissions should be read-only"
if grep -q 'secrets\.' "$workflow"; then
  fail "it should use no secrets"
fi

# The jobs that run the benchmark, with the architectures of their matrix
# and whether they upload artifacts whatever happened before.
benchmark_jobs='[.jobs[] | select(any(.steps[]?; (.run // "") | test("bench/bench\\.py run")))]'
architectures=$(printf '%s\n' "$json" | jq -r "$benchmark_jobs"' | [.[].strategy.matrix.include[]?.arch] | sort | join(" ")')
[ "$architectures" = "amd64 arm64" ] ||
  fail "it should run the benchmark on amd64 and arm64, not on: ${architectures:-nothing}"
printf '%s\n' "$json" | jq -e "$benchmark_jobs"' | length > 0 and all(.[];
  any(.steps[]; (.uses // "" | startswith("actions/upload-artifact@")) and .if == "always()"))' >/dev/null ||
  fail "every job that runs the benchmark should upload its output as artifacts with if: always()"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-benchmark-workflow: $workflow runs only by hand, on amd64 and arm64, and keeps its output"
