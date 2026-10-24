#!/bin/sh
# Checks that the build resolves moonbitstack/moonhttp at exactly the
# version moon.mod names (ADR 0005). moon takes that version as a minimum,
# and resolves the highest version that any module asks for, so a new or
# upgraded module that needs a later moonhttp would raise it with no change
# to moon.mod. This check is what makes the pin exact: moonhttp is raised
# only on purpose, on an integration branch, through the gate that
# docs/releasing.md describes (Upgrading moonhttp). CI runs it on every
# push.
#
# It needs moon, with the registry index updated (moon update), and jq.
#
# usage: scripts/check-moonhttp-pin.sh
set -eu
cd "$(dirname "$0")/.."

module=moonbitstack/moonhttp

# Prints every quoted string inside the import blocks of a moon.mod.
imports() {
  awk '
    /^[[:space:]]*import[[:space:]]*\{/ { inside = 1 }
    inside {
      line = $0
      sub(/\}.*/, "", line)
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
    inside && /\}/ { inside = 0 }
  ' "$1"
}

named=$(imports moon.mod | sed -n "s|^$module@||p")
if [ -z "$named" ]; then
  echo "check-moonhttp-pin: moon.mod does not import $module" >&2
  exit 1
fi

modules=$(scripts/resolved-modules.sh)
resolved=$(printf '%s\n' "$modules" | sed -n "s|^$module@||p" | tr '\n' ' ' | sed 's/ $//')
if [ "$resolved" != "$named" ]; then
  echo "check-moonhttp-pin: moon.mod names $module $named, but the build resolves ${resolved:-none}." >&2
  echo "check-moonhttp-pin: moon takes an import's version as a minimum, so a module that needs a later moonhttp raises it." >&2
  echo "check-moonhttp-pin: raise moonhttp only on purpose, on an integration branch (docs/releasing.md, Upgrading moonhttp)." >&2
  exit 1
fi
echo "check-moonhttp-pin: the build resolves $module $named, the version moon.mod names"
