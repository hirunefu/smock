#!/bin/sh
# Checks the rules that keep publishing in the release workflow
# (.github/workflows/release.yml) to version tags:
#
# - it runs when a v* tag is pushed and when started by hand, and on nothing
#   else, so never on pull requests;
# - its default permissions are read-only, and it uses no secrets;
# - every job that gets a write permission runs only for a pushed tag.
#
# A run by hand can therefore build and test, but not publish: its token can
# neither push nor sign the image, nor create a release.
#
# It needs yq (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-release-workflow.sh [workflow file]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/release.yml}
publish_condition="github.event_name == 'push' && github.ref_type == 'tag'"

failed=0
fail() {
  echo "check-release-workflow: $workflow: $*" >&2
  failed=1
}

json=$(yq --output-format=json "$workflow")

triggers=$(echo "$json" | jq -r '.on | keys | join(" ")')
[ "$triggers" = "push workflow_dispatch" ] ||
  fail "it should run on push and workflow_dispatch only, not on: $triggers"
push=$(echo "$json" | jq -r '.on.push | keys | join(" ")')
[ "$push" = tags ] || fail "it should run on pushed tags only, but on.push has: $push"
for pattern in $(echo "$json" | jq -r '.on.push.tags[]?'); do
  case $pattern in
  v*) ;;
  *) fail "it should run on version tags (v*) only, not on $pattern" ;;
  esac
done

echo "$json" | jq -e '.permissions | type == "object" and all(.[]; . != "write")' >/dev/null ||
  fail "its default permissions should be read-only"
if grep -q 'secrets\.' "$workflow"; then
  fail "it should use no secrets, only its own token"
fi

for job in $(echo "$json" | jq -r --arg condition "$publish_condition" '
  .jobs | to_entries[]
  | select(.value.permissions | tostring | test("write"))
  | select(.value.if != $condition)
  | .key'); do
  fail "job $job gets a write permission, so it should run only if: $publish_condition"
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-release-workflow: $workflow publishes only for pushed version tags"
