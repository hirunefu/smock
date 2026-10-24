#!/bin/sh
# Prints each module the build resolves from outside this workspace, as
# "<name>@<version>", one a line, sorted: the modules that moon.mod and the
# workspace's other modules import, and the modules those import in turn,
# at the versions moon chose. moon takes the version a module file gives an
# import as a minimum, and resolves the highest version that any module
# asks for, so these can be later than the ones moon.mod names.
#
# It asks `moon tree`, which reads the registry index (moon update) and
# downloads nothing. scripts/check-moonhttp-pin.sh and scripts/check-no-c.sh
# use it. It needs moon and jq.
#
# usage: scripts/resolved-modules.sh
set -eu
cd "$(dirname "$0")/.."

status=0
tree=$(moon tree --json) || status=$?
if [ -z "$tree" ]; then
  echo "resolved-modules: moon tree printed nothing (exit status $status)" >&2
  exit 1
fi
printf '%s\n' "$tree" | jq -r '
  if .status == "success" then
    [.modules[] | select(.workspace_member | not) | "\(.name)@\(.version)"] | sort | .[]
  else
    "resolved-modules: moon tree failed: \(.error)\([.logs[]?.message | " (\(.))"] | add // "")\n"
    | halt_error(1)
  end'
