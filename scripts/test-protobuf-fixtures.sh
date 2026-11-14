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

# add <line>...: adds lines at the end of the list of fixtures in the
# copy's script, as a later ticket adds a fixture.
add() {
  script=$copy/scripts/gen-protobuf-fixtures.sh
  printf '%s\n' "$@" >"$tmp/lines"
  # The lines go before the comment that ends the list.
  awk -v lines="$tmp/lines" '
    /^# The end of the list of fixtures\./ { while ((getline line < lines) > 0) print line; print "" }
    { print }' "$script" >"$tmp/script"
  cat "$tmp/script" >"$script"
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

# A fixture that a later ticket adds: a set, a message of its type, a copy
# of the set and the set in hex in a test file.
fresh
added=fixtures/protobuf/added
mkdir -p "$copy/$added"
cat >"$copy/$added/added.proto" <<'PROTO'
syntax = "proto3";
package added;
import "google/protobuf/timestamp.proto";
message Item {
  string name = 1;
  google.protobuf.Timestamp at = 2;
}
PROTO
printf 'name: "one"\nat { seconds: 1 }\n' >"$copy/$added/item.txtpb"
add "descriptor_set added added.binpb added.proto" \
  "message added added.proto added.Item item" \
  "copy added/added.binpb $added/copy/added.binpb" \
  "hex_test added/added.binpb added_set \"The added set, in hex.\" $added/hex"
check added
expect added "a fixture added to the script, not built yet: the check names each file it builds" 1 \
  "$added/added.binpb" "$added/item.binpb" "$added/copy/added.binpb" "$added/hex/added_set_test.mbt"
"$copy/scripts/gen-protobuf-fixtures.sh" >/dev/null
check built
expect built "the added fixture built by the script: the check passes" 0
printf 'name: "two"\nat { seconds: 1 }\n' >"$copy/$added/item.txtpb"
check message
expect message "the added message changed in its source: the check names it alone" 1 "$added/item.binpb"
"$copy/scripts/gen-protobuf-fixtures.sh" >/dev/null
cat >"$copy/$added/added.proto" <<'PROTO'
syntax = "proto3";
package added;
import "google/protobuf/timestamp.proto";
message Item {
  string name = 1;
  google.protobuf.Timestamp at = 2;
  int32 count = 3;
}
PROTO
check source
expect source "a field added to the added .proto: the check names its set and every copy of it" 1 \
  "$added/added.binpb" "$added/copy/added.binpb" "$added/hex/added_set_test.mbt"

# Another protoc than the pinned one, which says it is 36.1.
fresh
mkdir -p "$tmp/other"
real=$(command -v "$protoc")
cat >"$tmp/other/protoc" <<SCRIPT
#!/bin/sh
if [ "\$1" = --version ]; then echo "libprotoc 36.1"; exit 0; fi
exec "$real" "\$@"
SCRIPT
chmod +x "$tmp/other/protoc"
PROTOC=$tmp/other/protoc check other
expect other "another protoc than the pinned one: the check refuses to run" 2
if ! grep -q "not libprotoc $pinned" "$tmp/other.out"; then
  fail "another protoc than the pinned one: the check does not name the pinned version"
  cat "$tmp/other.out"
fi

echo "test-protobuf-fixtures: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
