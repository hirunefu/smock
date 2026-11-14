#!/bin/sh
# Tests of the check of the protobuf fixtures,
# `scripts/gen-protobuf-fixtures.sh --check`, which CI runs on every push.
# Each test runs the check, as CI does, in a fresh copy of the files git
# tracks, with the fixtures rebuilt there by the script, after changing the
# copy, and checks its exit status, the files it names and that it writes
# nothing.
#
# It needs the protoc that scripts/install-protoc.sh installs, as $PROTOC or
# protoc on the PATH, and git, tar and sha256sum.
#
# usage: scripts/test-protobuf-fixtures.sh
set -eu
cd "$(dirname "$0")/.."

pinned=$(sed -n 's/^version=//p' scripts/install-protoc.sh)
protoc=${PROTOC:-protoc}
if [ "$("$protoc" --version 2>/dev/null || true)" != "libprotoc $pinned" ]; then
  echo "test-protobuf-fixtures: needs protoc $pinned, as \$PROTOC or protoc on the PATH; scripts/install-protoc.sh installs it" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=$tmp/base
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

# The working tree's files that git tracks or does not ignore, with the
# fixtures rebuilt by the script, so that the tests do not depend on whether
# the committed ones are up to date.
mkdir -p "$base"
git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - | tar -xf - -C "$base"
if ! "$base/scripts/gen-protobuf-fixtures.sh" >"$tmp/rebuild.out" 2>&1; then
  cat "$tmp/rebuild.out" >&2
  echo "test-protobuf-fixtures: the script cannot rebuild the fixtures" >&2
  exit 1
fi

set_file=fixtures/protobuf/helloworld/greeter.binpb

# fresh: makes $copy, a copy of $base.
fresh() {
  rm -rf "$copy"
  cp -R "$base" "$copy"
}

# files: every file of the copy with its SHA-256, one per line.
files() {
  (cd "$copy" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)
}

# check <name>: runs the check in the copy into $tmp/<name>.out, its exit
# status into $tmp/<name>.status, and the files it names, one per line, in
# order, into $tmp/<name>.named. It also fails the test <name> if the check
# changed a file of the copy.
check() {
  files >"$tmp/before"
  status=0
  "$copy/scripts/gen-protobuf-fixtures.sh" --check >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
  sed -n -e 's/^gen-protobuf-fixtures: \([^ ]*\) differs from what its sources build$/\1/p' \
    -e 's/^gen-protobuf-fixtures: \([^ ]*\) is missing: its sources build it$/\1/p' \
    "$tmp/$1.out" >"$tmp/$1.named"
  files >"$tmp/after"
  if ! cmp -s "$tmp/before" "$tmp/after"; then
    fail "$1: the check wrote to the copy"
    cat "$tmp/$1.out"
  fi
}

# expect <name> <test> <status> [<file>...]: the check <name> exited with
# <status> and named exactly these files, in this order; <test> says what
# that shows.
expect() {
  name=$1
  test=$2
  want=$3
  shift 3
  printf '%s\n' "$@" | sed '/^$/d' >"$tmp/$name.want"
  if [ "$(cat "$tmp/$name.status")" = "$want" ] && cmp -s "$tmp/$name.want" "$tmp/$name.named"; then
    pass "$test"
  else
    fail "$test: exit status $(cat "$tmp/$name.status"), not $want; it named, then the test expected:"
    cat "$tmp/$name.named" "$tmp/$name.want"
    cat "$tmp/$name.out"
  fi
}

# bump <file> <offset>: adds 1 to the octet at <offset> of a file of the
# copy, so that exactly that octet changes.
bump() {
  octet=$(od -An -tu1 -j "$2" -N 1 "$copy/$1" | tr -d ' ')
  # shellcheck disable=SC2059 # the format is the octet, in octal
  printf "\\$(printf '%03o' $(((octet + 1) % 256)))" |
    dd of="$copy/$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

fresh
check rebuilt
expect rebuilt "the check passes on fixtures that the script rebuilt, and writes nothing" 0

fresh
cp "$copy/$set_file" "$tmp/committed"
bump "$set_file" 100
check changed
expect changed "one octet of $set_file changed: the check fails and names that file alone" 1 "$set_file"
cp "$tmp/committed" "$copy/$set_file"
check restored
expect restored "$set_file restored: the check passes again" 0

echo "test-protobuf-fixtures: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
