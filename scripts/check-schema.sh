#!/bin/sh
# Cross-checks the Definition-file JSON Schema (schema/v1/definitions.json)
# with smock's own validation, which is written by hand.
#
# First it checks the Schema itself: it is a valid JSON Schema, its $id is
# the URL it is published at, and every field has a description.
#
# Then it checks every fixture under schema/v1/fixtures/, each alone in a
# definitions directory, twice: with an external JSON Schema validator
# (check-jsonschema) and with `smock check`. Both verdicts must match the
# directory the fixture is in:
#
#   valid/                  the Schema accepts it, and so does smock
#   invalid/                the Schema rejects it, and so does smock
#   invalid-beyond-schema/  the Schema accepts it, but smock rejects it for
#                           a reason the Schema cannot see, such as a rule
#                           across the files of a definition set
#
# Each definitions directory also gets the files under body-files/ as its
# body-file subdirectory (files/, the default), so that fixtures can refer
# to them with bodyFile.
#
# Adding a fixture file is enough to add it to the cross-check.
#
# usage: scripts/check-schema.sh [smock binary]
#   Without a binary, it builds and uses the native debug build. It runs
#   check-jsonschema with uvx, or with pipx when uvx is not installed.
set -eu
cd "$(dirname "$0")/.."

# .github/workflows/schema-pages.yml reads this line too.
validator_version=0.38.2
schema=schema/v1/definitions.json
fixtures=schema/v1/fixtures
published_at=https://hirunefu.github.io/smock/$schema

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [smock binary]" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  smock=$1
else
  moon build --target native cmd/smock >&2
  smock=_build/native/debug/build/smock/smock/cmd/smock/smock.exe
fi

# From here on, "$@" runs the validator.
if command -v uvx >/dev/null 2>&1; then
  set -- uvx "check-jsonschema@$validator_version"
elif command -v pipx >/dev/null 2>&1; then
  set -- pipx run --spec "check-jsonschema==$validator_version" check-jsonschema
else
  echo "check-schema: needs uvx or pipx to run check-jsonschema" >&2
  exit 2
fi

failed=0
fail() {
  echo "check-schema: $*" >&2
  failed=1
}

# The Schema itself.
"$@" --check-metaschema "$schema" >/dev/null || fail "$schema is not a valid JSON Schema"
id=$(jq -r '."$id"' "$schema")
[ "$id" = "$published_at" ] || fail "$schema has \$id $id, not the URL it is published at, $published_at"
# Every member of a "properties" object describes itself, or refers to a
# definition that does.
undescribed=$(jq -r '
  . as $schema
  | paths(objects)
  | select(length >= 2 and .[-2] == "properties") as $path
  | ($schema | getpath($path)) as $field
  | select($field.description == null)
  | select(($field["$ref"] // "" | ltrimstr("#/$defs/")) as $def
      | $schema["$defs"][$def].description == null)
  | $path | map(tostring) | join("/")
' "$schema")
for path in $undescribed; do
  fail "$schema: the field at /$path has no description"
done

# The fixtures.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
count=0
for category in valid invalid invalid-beyond-schema; do
  case $category in
  valid) schema_expects=valid smock_expects=valid ;;
  invalid) schema_expects=invalid smock_expects=invalid ;;
  invalid-beyond-schema) schema_expects=valid smock_expects=invalid ;;
  esac
  for fixture in "$fixtures/$category"/*; do
    [ -e "$fixture" ] || continue
    name=${fixture##*/}
    case $name in
    *.json | *.yaml | *.yml) ;;
    *)
      fail "$fixture: a fixture's name ends in .json, .yaml or .yml"
      continue
      ;;
    esac
    count=$((count + 1))

    if "$@" --schemafile "$schema" "$fixture" >"$tmp/schema.out" 2>&1; then
      schema_says=valid
    else
      schema_says=invalid
    fi

    rm -rf "$tmp/definitions"
    mkdir "$tmp/definitions"
    cp "$fixture" "$tmp/definitions/$name"
    cp -R "$fixtures/body-files" "$tmp/definitions/files"
    status=0
    "$smock" check "$tmp/definitions" >"$tmp/smock.out" 2>&1 || status=$?
    case $status in
    0) smock_says=valid ;;
    1) smock_says=invalid ;;
    *)
      fail "$fixture: smock check exited with status $status:"
      sed 's/^/    /' "$tmp/smock.out" >&2
      continue
      ;;
    esac

    echo "$category/$name: the Schema says $schema_says, smock says $smock_says"
    sed 's/^/    /' "$tmp/smock.out"
    if [ "$schema_says" != "$schema_expects" ]; then
      fail "$fixture: the Schema should say $schema_expects:"
      sed 's/^/    /' "$tmp/schema.out" >&2
    fi
    if [ "$smock_says" != "$smock_expects" ]; then
      fail "$fixture: smock should say $smock_expects"
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-schema: the Schema and smock agree on all $count fixtures"
