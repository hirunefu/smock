#!/bin/sh
# Tests of what scripts/resolved-modules.sh --json says of each module the
# build resolves, of scripts/check-moonhttp-pin.sh and of the scan of the
# resolved dependencies in scripts/check-no-c.sh. Each test runs a script,
# as CI does, in a fresh copy of what it reads: the scripts, this
# workspace's module and package files, prebuild.py, .gitignore, and the
# modules outside moonbitlang that moon downloaded into .mooncakes/. moon
# resolves the copy's modules itself, from the registry index, as it
# resolves the build's. A test changes the copy so that the build resolves
# another moonhttp than moon.mod names, or so that a scanned module brings
# C, and the check must fail and say so. Both checks must pass on the copy
# as it is.
#
# It needs moon, with the registry index updated (moon update), and jq, and
# the modules downloaded: run it after moon check, as CI does.
#
# usage: scripts/test-dependency-checks.sh
#
# shellcheck disable=SC2016 # jq filters are in single quotes on purpose
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

# The modules the C check scans, as the build resolves them, which the copy
# takes from .mooncakes/.
resolved=$(scripts/resolved-modules.sh)
scanned=$(printf '%s\n' "$resolved" | grep -v '^moonbitlang/')
for module in $scanned; do
  if [ ! -d ".mooncakes/${module%@*}" ]; then
    echo "test-dependency-checks: .mooncakes/ has no ${module%@*}; run moon check first" >&2
    exit 2
  fi
done

# version <name>: the version of a module the build resolves.
version() {
  printf '%s\n' "$resolved" | sed -n "s|^$1@||p"
}

# fresh: makes $copy, a copy of what the checks read.
fresh() {
  rm -rf "$copy"
  mkdir -p "$copy/scripts" "$copy/.mooncakes"
  cp scripts/check-moonhttp-pin.sh scripts/check-no-c.sh scripts/resolved-modules.sh \
    scripts/check-notice.sh scripts/notice.jq "$copy/scripts/"
  cp .gitignore prebuild.py moon.work NOTICE .moonbit-version "$copy/"
  for manifest in $(git ls-files 'moon.mod' '*/moon.mod' 'moon.pkg' '*/moon.pkg'); do
    mkdir -p "$copy/$(dirname "$manifest")"
    cp "$manifest" "$copy/$manifest"
  done
  for module in $scanned; do
    mkdir -p "$copy/.mooncakes/${module%/*}"
    cp -R ".mooncakes/${module%@*}" "$copy/.mooncakes/${module%@*}"
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

# lists <description> <jq filter>: the filter, run on what
# scripts/resolved-modules.sh --json prints for the copy, gives true. It may
# use entry($name), the one module of that name, and $resolved, what
# scripts/resolved-modules.sh prints for this repository.
lists() {
  if ! "$copy/scripts/resolved-modules.sh" --json >"$tmp/out" 2>"$tmp/err"; then
    fail "resolved-modules.sh --json: $1: it fails: $(cat "$tmp/err")"
  elif jq -e --arg resolved "$resolved" \
    "def entry(\$name): [.[] | select(.name == \$name)] | if length == 1 then .[0] else null end; $2" \
    "$tmp/out" >/dev/null 2>"$tmp/err"; then
    pass "resolved-modules.sh --json: $1"
  else
    fail "resolved-modules.sh --json: $1: $(cat "$tmp/err" "$tmp/out")"
  fi
}

# What the build resolves, with what NOTICE and the SBOM need of each
# module.

fresh
lists "it lists the modules the build resolves, at the versions it resolves" \
  '[.[] | "\(.name)@\(.version)"] == ($resolved | split("\n"))'
lists "moonhttp, whose http2 smock's server imports, is compiled into smock" \
  'entry("moonbitstack/moonhttp") | .compiled and (.packages | index("http2") and index("header"))'
lists "each module has the licence and repository of its own module file" \
  'all(.[]; .licence != "" and (.repository | startswith("https://")))'

fresh
edit ".mooncakes/moonbitstack/moonvar/moon.mod" 's/^license = ".*"/license = "MIT"/'
lists "a module that declares another licence has that one" \
  'entry("moonbitstack/moonvar").licence == "MIT"'

# The e2e tests still import moonhttp, but the binary does not reach them.
fresh
edit server/moon.pkg '\|"moonbitstack/|d'
lists "a module that the build resolves but whose packages the binary does not reach is not compiled in" \
  'entry("moonbitstack/moonhttp") | (.compiled | not) and .packages == []'

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

# The C check's scan of the resolved dependencies: moonhttp and the modules
# it imports (moonvar, moondate, mooncrypt and moonbase as of 0.14.0).

moonvar=moonbitstack/moonvar
moonbase=moonbitstack/moonbase
mooncrypt=moonbitstack/mooncrypt
moondate=moonbitstack/moondate

fresh
passes check-no-c.sh "smock and the modules it resolves outside moonbitlang have no C" \
  "$moonhttp@$named"

fresh
printf 'int varint(void) { return 0; }\n' >"$copy/.mooncakes/$moonvar/varint.c"
fails check-no-c.sh "a module that moonhttp imports has a C source" \
  "$moonvar@$(version $moonvar) has C source varint.c"

fresh
printf '\nextern "C" fn probe() -> Int = "probe"\n' >"$copy/.mooncakes/$moonhttp/http2/probe.mbt"
fails check-no-c.sh "moonhttp declares a C function" \
  "$moonhttp@$named binds C functions (extern \"C\") in http2/probe.mbt"

fresh
printf '\noptions(\n  "native-stub": [ "stub.c" ],\n)\n' >>"$copy/.mooncakes/$moonbase/moon.pkg"
fails check-no-c.sh "a module that moonhttp imports declares a native stub" \
  "$moonbase@$(version $moonbase) declares a native stub in moon.pkg"

fresh
printf '\noptions(\n  link: { native: { "cc-link-flags": "-lz" } },\n)\n' >>"$copy/.mooncakes/$moondate/moon.pkg"
fails check-no-c.sh "a module that moonhttp imports sets a link flag" \
  "$moondate@$(version $moondate) sets a C compiler or link flag in moon.pkg"

fresh
printf '\noptions(\n  "--moonbit-unstable-prebuild": "prebuild.py",\n)\n' >>"$copy/.mooncakes/$mooncrypt/moon.mod"
fails check-no-c.sh "a module that moonhttp imports runs a prebuild script, which can add link flags" \
  "$mooncrypt@$(version $mooncrypt) runs a prebuild script in moon.mod"

fresh
printf '\n// No "native-stub": here, nor "cc-flags": or a prebuild.\n' >>"$copy/.mooncakes/$moonbase/moon.pkg"
printf '///| Calls no extern "C" function.\nfn note() -> Unit { () }\n' >"$copy/.mooncakes/$moonbase/note.mbt"
passes check-no-c.sh "a comment that names C is not C" \
  "no C beyond what ADR 0001 allows"

# moonbitlang/async has C of its own, which ADR 0001 covers.
fresh
mkdir -p "$copy/.mooncakes/moonbitlang/async/src"
printf 'int event_loop(void) { return 0; }\n' >"$copy/.mooncakes/moonbitlang/async/src/event_loop.c"
passes check-no-c.sh "the moonbitlang modules stay outside the scan" \
  "no C beyond what ADR 0001 allows"

# A module that only a new module of the workspace imports: moon resolves
# it, so the scan covers it, as it covers one that a moonhttp upgrade adds.
added=moonbitstack/moonurl
fresh
member extra "$added@0.2.0"
fails check-no-c.sh "a module the build newly resolves must be downloaded to be scanned" \
  "$added@0.2.0 is not in .mooncakes/"

fresh
member extra "$added@0.2.0"
mkdir -p "$copy/.mooncakes/$added"
printf 'name = "%s"\n\nversion = "0.2.0"\n' "$added" >"$copy/.mooncakes/$added/moon.mod"
printf 'int url(void) { return 0; }\n' >"$copy/.mooncakes/$added/url.c"
fails check-no-c.sh "a module the build newly resolves is scanned" \
  "$added@0.2.0 has C source url.c"

fresh
edit ".mooncakes/$moonvar/moon.mod" 's/^version = ".*"/version = "0.0.1"/'
fails check-no-c.sh "the module in .mooncakes/ is not the version the build resolves" \
  ".mooncakes/$moonvar holds version 0.0.1, but the build resolves $(version $moonvar)"

# The NOTICE check: every module the build resolves, of any owner and
# transitive ones included, at the version the build resolves.

toolchain=$(cat .moonbit-version)

# without <title>: removes the section <title> from the copy's NOTICE.
without() {
  awk -v title="$1" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (i < NR && line[i] != "" && line[i + 1] ~ /^-+$/) {
          skip = line[i] == title
        }
        if (!skip) {
          print line[i]
        }
      }
    }' "$copy/NOTICE" >"$tmp/edited"
  mv "$tmp/edited" "$copy/NOTICE"
}

# in_section <title> <sed command>: runs the sed command on the lines of the
# section <title> of the copy's NOTICE, from its title to its Licence line.
in_section() {
  edit NOTICE "\\|^$1\$|,/^Licence:/$2"
}

fresh
passes check-notice.sh "NOTICE names the toolchain and every module the build resolves" \
  "$moonhttp@$named"

fresh
without "$moonvar"
fails check-notice.sh "NOTICE leaves out a module that moonhttp imports" \
  "NOTICE has no section $moonvar, which the build resolves at version $(version $moonvar)"

fresh
without moonbitlang/x
fails check-notice.sh "NOTICE leaves out a moonbitlang module" \
  "NOTICE has no section moonbitlang/x, which the build resolves at version $(version moonbitlang/x)"

fresh
in_section "$moondate" "s/^Version $(version $moondate)\\./Version 0.0.9./"
fails check-notice.sh "NOTICE gives a module that moonhttp imports another version" \
  "NOTICE gives $moondate the version 0.0.9, but the build resolves $(version $moondate)"

fresh
in_section "$moonhttp" "s/^Version $named\\./Version $earlier./"
fails check-notice.sh "NOTICE gives moonhttp another version" \
  "NOTICE gives $moonhttp the version $earlier, but the build resolves $named"

fresh
edit ".mooncakes/$moonvar/moon.mod" 's/^license = ".*"/license = "MIT"/'
fails check-notice.sh "a module's own module file declares another licence than NOTICE gives" \
  "NOTICE gives $moonvar the licence Apache-2.0, but its module file MIT"

fresh
edit ".mooncakes/$moonvar/moon.mod" 's|^repository = ".*"|repository = "https://example.com/moonvar"|'
fails check-notice.sh "a module's own module file names another repository than NOTICE's source" \
  "NOTICE gives $moonvar the source https://github.com/$moonvar, but its module file the repository https://example.com/moonvar"

fresh
edit server/moon.pkg '\|"moonbitstack/|d'
fails check-notice.sh "NOTICE says smock is built from a module whose packages the binary does not reach" \
  "NOTICE does not say that smock compiles nothing from $moonhttp, but the binary reaches none of its packages"

fresh
in_section "$moonvar" 's/^Version \(.*\)$/Version \1 But smock compiles nothing from it./'
fails check-notice.sh "NOTICE says smock compiles nothing from a module that the binary is built from" \
  "NOTICE says that smock compiles nothing from $moonvar, but the binary is built from its packages"

fresh
printf '\n\n%s\n%s\n\nVersion 0.2.0.\n\nSource:  https://github.com/%s\nLicence: Apache License, Version 2.0\n' \
  "$added" "$(printf '%s' "$added" | tr '[:print:]' '-')" "$added" >>"$copy/NOTICE"
fails check-notice.sh "NOTICE names a module the build does not resolve" \
  "NOTICE has a section $added, but the build does not resolve it"

fresh
echo "9.9.9" >"$copy/.moonbit-version"
fails check-notice.sh "NOTICE names another toolchain than .moonbit-version" \
  "NOTICE names the toolchain moonc v$toolchain, but .moonbit-version says 9.9.9"

echo
echo "test-dependency-checks: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
