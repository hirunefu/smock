#!/bin/sh
# Checks that CI keeps the release binary of each architecture as a
# workflow artifact (.github/workflows/build-test.yml), which the GKE run
# of the benchmark takes for an architecture its machine cannot build for
# (scripts/gke-bench.sh --arch, docs/merging-into-main.md):
#
# - the job that builds the release binary with scripts/build-release.sh
#   runs on linux/amd64 and on linux/arm64;
# - after that build, it uploads dist/smock, which the script writes and the
#   image packs, as smock-linux-<arch>, kept for 7 days at most;
# - only when every step before it passed (no always(), failure() or
#   cancelled()), and only with the pinned toolchain.
#
# And that the SDK job of the workflow that calls it on each push and pull
# request (.github/workflows/ci.yml, llm-sdks/README.md) takes the amd64
# binary kept there:
#
# - that workflow calls build-test.yml once, with the pinned toolchain;
# - one job downloads smock-linux-amd64, and it needs that call, runs on
#   an amd64 runner, runs scripts/check-llm-sdks.sh, and builds nothing:
#   no step runs moon or scripts/build-release.sh.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-ci-artifacts.sh [workflow file [calling workflow file]]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/build-test.yml}
caller=${2:-.github/workflows/ci.yml}

for file in "$workflow" "$caller"; do
  if [ ! -f "$file" ]; then
    echo "check-ci-artifacts: $file does not exist" >&2
    exit 1
  fi
done
json=$(yq --output-format=json "$workflow")

# What is wrong, one line each, about the jobs that build the release
# binary.
problems=$(printf '%s\n' "$json" | jq -r '
  def builds: (.run // "") | test("(^|[;&|[:space:]])scripts/build-release\\.sh");
  [.jobs | to_entries[] | select(any(.value.steps[]?; builds))] as $jobs
  | ([$jobs[].value.strategy.matrix.include[]?.arch] | sort | join(" ")) as $architectures
  | (if $architectures == "amd64 arm64" then empty
     else "the release binary should be built on amd64 and arm64, not on: \(if $architectures == "" then "nothing" else $architectures end)" end),
    ($jobs[] | .key as $job | (.value.steps | to_entries) as $steps
     | ([$steps[] | select(.value | builds) | .key] | first) as $build
     | [$steps[] | select((.value.uses // "") | startswith("actions/upload-artifact@"))
                 | select(.value.with.name == "smock-linux-${{ matrix.arch }}")] as $uploads
     | if ($uploads | length) != 1 then
         "job \($job) should upload dist/smock as smock-linux-${{ matrix.arch }} once, not \($uploads | length) times"
       else
         $uploads[0] as $upload
         | (if $upload.key < $build then "job \($job) uploads smock-linux-<arch> before it builds the release binary" else empty end),
           (if $upload.value.with.path != "dist/smock" then
              "job \($job) should upload dist/smock, which scripts/build-release.sh writes, not \($upload.value.with.path)"
            else empty end),
           (($upload.value.with["retention-days"]) as $days
            | if ($days | type) == "number" and $days >= 1 and $days <= 7 then empty
              else "job \($job) should keep smock-linux-<arch> for 7 days at most (retention-days), not \($days)" end),
           (($upload.value.if // "") as $if
            | if ($if | test("always\\(|failure\\(|cancelled\\(")) then
                "job \($job) should upload smock-linux-<arch> only when every step before it passed, not if: \($if)"
              elif ($if | contains("inputs.toolchain == '"'"'pinned'"'"'")) | not then
                "job \($job) should upload smock-linux-<arch> with the pinned toolchain only (if: inputs.toolchain == '"'"'pinned'"'"')"
              else empty end)
       end)')

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-ci-artifacts: $workflow: |" >&2
  exit 1
fi

# What is wrong, one line each, about the SDK job of the calling workflow.
problems=$(yq --output-format=json "$caller" | jq -r --arg workflow "$(basename "$workflow")" '
  def runs($pattern): (.run // "") | test($pattern);
  [.jobs | to_entries[] | select((.value.uses // "") | endswith("/" + $workflow))] as $calls
  | [.jobs | to_entries[]
     | select(any(.value.steps[]?; ((.uses // "") | startswith("actions/download-artifact@"))
                                   and .with.name == "smock-linux-amd64"))] as $sdk
  | if ($calls | length) != 1 then
      "it should call \($workflow) once, not \($calls | length) times"
    elif $calls[0].value.with.toolchain != "pinned" then
      "it should call \($workflow) with toolchain: pinned, which keeps the release binaries"
    elif ($sdk | length) != 1 then
      "one job, the SDK job, should download smock-linux-amd64, not \($sdk | length)"
    else
      $calls[0].key as $call | $sdk[0] as $job
      | ([$job.value.needs // empty] | flatten) as $needs
      | (if ($needs | index($call)) == null then "job \($job.key) should need \($call)" else empty end),
        (if ($job.value["runs-on"] | tostring | test("arm")) then
           "job \($job.key) should run on an amd64 runner, not \($job.value["runs-on"])"
         else empty end),
        (if any($job.value.steps[]?; runs("scripts/check-llm-sdks\\.sh")) | not then
           "job \($job.key) should run scripts/check-llm-sdks.sh"
         else empty end),
        (if any($job.value.steps[]?; runs("(^|[;&|[:space:]])(moon|scripts/build-release\\.sh)([[:space:]]|$)")) then
           "job \($job.key) should build nothing, but a step runs moon or scripts/build-release.sh"
         else empty end)
    end')

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-ci-artifacts: $caller: |" >&2
  exit 1
fi
echo "check-ci-artifacts: $workflow keeps the release binary of amd64 and arm64 as smock-linux-<arch>," \
  "and the SDK job of $caller takes the amd64 one"
