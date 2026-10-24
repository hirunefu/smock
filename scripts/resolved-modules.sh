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
# With --json, it prints the same modules, in the same order, as one JSON
# array of objects with:
#
# - name and version;
# - licence and repository, as the module's own module file declares them
#   ("" when it declares none);
# - compiled: whether the smock binary is built from any of its packages.
#   Those are the packages that the binary's package (cmd/smock, which
#   scripts/build-release.sh builds) imports for the native target, and the
#   ones they import in turn. Imports for tests do not count;
# - packages: those packages, sorted ("" is the module's root package).
#
# A module that moon resolves only because another module imports it, and
# of which the binary reaches no package, has compiled false. NOTICE and the
# image's SBOM tell such modules apart (scripts/check-notice.sh and
# scripts/add-smock-to-sbom.sh read this). For the package graph, `moon
# tree --package` downloads the modules into .mooncakes/, where their module
# files are read.
#
# usage: scripts/resolved-modules.sh [--json]
set -eu
cd "$(dirname "$0")/.."

json=false
case ${1:-} in
--json) json=true ;;
"") ;;
*)
  echo "usage: $0 [--json]" >&2
  exit 2
  ;;
esac

# tree [option...]: what `moon tree --json` prints with the options, as one
# line, once it is sure that moon resolved.
tree() {
  status=0
  out=$(moon tree --json "$@") || status=$?
  if [ -z "$out" ]; then
    echo "resolved-modules: moon tree printed nothing (exit status $status)" >&2
    return 1
  fi
  printf '%s\n' "$out" | jq -c '
    if .status == "success" then .
    else
      "resolved-modules: moon tree failed: \(.error)\([.logs[]?.message | " (\(.))"] | add // "")\n"
      | halt_error(1)
    end'
}

modules=$(tree)
resolved=$(printf '%s\n' "$modules" | jq -r '
  [.modules[] | select(.workspace_member | not) | "\(.name)@\(.version)"] | sort | .[]')
if [ "$json" = false ]; then
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  fi
  exit 0
fi

# The packages of each module that the binary's package reaches through the
# imports of their sources, as {"<module>": ["<package>", ...]}.
graph=$(tree --package --target native)
packages=$(printf '%s\n' "$graph" | jq -c '
  .nodes as $nodes
  | (reduce (.edges[] | select(.kinds | index("source"))) as $edge
      ({}; .[$edge.from | tostring] += [$edge.to])) as $imports
  | [.root[] | select($nodes[.].rel == "cmd/smock")] as $binary
  | if ($binary | length) != 1 then error("moon tree --package lists no package cmd/smock") else . end
  | {seen: $binary, todo: $binary}
  | until(.todo == [];
      .todo[0] as $package
      | .todo |= .[1:]
      | (($imports[$package | tostring] // []) - .seen) as $new
      | .seen += $new
      | .todo += $new)
  | [.seen[] | $nodes[.]] | group_by(.module)
  | map({key: .[0].module, value: ([.[].rel] | sort)}) | from_entries')

# field <module file> <key>: the string a module file, moon.mod or
# moon.mod.json, gives the key, or nothing.
field() {
  sed -n "s/^[[:space:]]*\"\{0,1\}$2\"\{0,1\}[[:space:]]*[=:][[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

lines=""
for module in $resolved; do
  name=${module%@*}
  version=${module##*@}
  file=""
  for candidate in ".mooncakes/$name/moon.mod" ".mooncakes/$name/moon.mod.json"; do
    if [ -f "$candidate" ]; then
      file=$candidate
      break
    fi
  done
  if [ -z "$file" ]; then
    echo "resolved-modules: $module is not in .mooncakes/" >&2
    exit 1
  fi
  held=$(field "$file" version)
  if [ "$held" != "$version" ]; then
    echo "resolved-modules: .mooncakes/$name holds version $held, but the build resolves $version" >&2
    exit 1
  fi
  lines="$lines$(jq -nc --arg name "$name" --arg version "$version" --arg licence "$(field "$file" license)" \
    --arg repository "$(field "$file" repository)" --argjson packages "$packages" '
    ($packages[$name] // []) as $used
    | {$name, $version, $licence, $repository, compiled: ($used != []), packages: $used}')
"
done
printf '%s' "$lines" | jq -s .
