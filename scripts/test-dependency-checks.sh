#!/bin/sh
# Tests of scripts/check-moonhttp-pin.sh and of the scan of the resolved
# dependencies in scripts/check-no-c.sh. Each test runs a check, as CI does,
# in a fresh copy of what it reads: the scripts, this workspace's module
# files, prebuild.py, .gitignore, and the modules outside moonbitlang that
# moon downloaded into .mooncakes/. moon resolves the copy's modules itself,
# from the registry index, as it resolves the build's. A test changes the
# copy so that the build resolves another moonhttp than moon.mod names, or
# so that a scanned module brings C, and the check must fail and say so.
# Both checks must pass on the copy as it is.
#
# It needs moon, with the registry index updated (moon update), and jq, and
# the modules downloaded: run it after moon check, as CI does.
#
# usage: scripts/test-dependency-checks.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
copy=$tmp/repo

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

moonhttp=moonbitstack/moonhttp
# The moonhttp version moon.mod names, and a published one before it.
named=$(sed -n 's|.*"moonbitstack/moonhttp@\([^"]*\)".*|\1|p' moon.mod)
earlier=0.13.0

# fresh: makes $copy, a copy of what the checks read.
fresh() {
  rm -rf "$copy"
  mkdir -p "$copy/scripts" "$copy/.mooncakes"
  cp scripts/check-moonhttp-pin.sh scripts/check-no-c.sh scripts/resolved-modules.sh "$copy/scripts/"
  cp .gitignore prebuild.py moon.work "$copy/"
  for manifest in $(git ls-files 'moon.mod' '*/moon.mod'); do
    mkdir -p "$copy/$(dirname "$manifest")"
    cp "$manifest" "$copy/$manifest"
  done
  git -C "$copy" init -q
}

# edit <file> <sed script>: changes a file of the copy.
edit() {
  sed "$2" "$copy/$1" >"$tmp/edited"
  mv "$tmp/edited" "$copy/$1"
}

# member <dir> <import>: adds a module to the copy's workspace, in <dir>,
# that imports <import> ("<name>@<version>").
member() {
  mkdir -p "$copy/$1"
  printf 'name = "smock/%s"\n\nversion = "0.1.0"\n\nimport {\n  "%s",\n}\n' "$1" "$2" >"$copy/$1/moon.mod"
  edit moon.work "s|^members = \[|members = [\n  \"./$1\",|"
}

# passes <check> <description> <text>: the check passes on the copy and
# says <text>.
passes() {
  if ! "$copy/scripts/$1" >"$tmp/out" 2>&1; then
    fail "$1: $2: the check fails: $(cat "$tmp/out")"
  elif grep -qF -- "$3" "$tmp/out"; then
    pass "$1: $2"
  else
    fail "$1: $2: the check passes, but does not say \"$3\": $(cat "$tmp/out")"
  fi
}

# fails <check> <description> <text>: the check fails on the copy and says
# <text>.
fails() {
  if "$copy/scripts/$1" >"$tmp/out" 2>&1; then
    fail "$1: $2: the check passes: $(cat "$tmp/out")"
  elif grep -qF -- "$3" "$tmp/out"; then
    pass "$1: $2"
  else
    fail "$1: $2: the check fails, but does not say \"$3\": $(cat "$tmp/out")"
  fi
}

# The resolved-version check.

fresh
passes check-moonhttp-pin.sh "the build resolves the moonhttp that moon.mod names" \
  "the build resolves $moonhttp $named, the version moon.mod names"

fresh
edit moon.mod "s|\"$moonhttp@$named\"|\"$moonhttp@$earlier\"|"
passes check-moonhttp-pin.sh "moon.mod names an earlier moonhttp, and no module needs a later one" \
  "the build resolves $moonhttp $earlier, the version moon.mod names"

fresh
edit moon.mod "s|\"$moonhttp@$named\"|\"$moonhttp@$earlier\"|"
member extra "$moonhttp@$named"
fails check-moonhttp-pin.sh "a new module needs a later moonhttp than moon.mod names" \
  "moon.mod names $moonhttp $earlier, but the build resolves $named"

fresh
edit moon.mod "s|\"$moonhttp@$named\"|\"$moonhttp@$earlier\"|"
printf '\nimport {\n  "%s",\n}\n' "$moonhttp@$named" >>"$copy/http1/moon.mod"
fails check-moonhttp-pin.sh "an upgraded module needs a later moonhttp than moon.mod names" \
  "moon.mod names $moonhttp $earlier, but the build resolves $named"

fresh
edit moon.mod "\|\"$moonhttp@$named\"|d"
fails check-moonhttp-pin.sh "moon.mod does not import moonhttp" \
  "moon.mod does not import $moonhttp"

echo
echo "test-dependency-checks: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
