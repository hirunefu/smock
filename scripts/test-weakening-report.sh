#!/bin/sh
# Tests of the weakening report (scripts/weakening-report.py), which the
# branch checks workflow writes on each push to a branch other than main.
# Each test makes a small git repository in a temporary directory: a commit
# on main, then a branch with one kind of change. It runs the report on the
# branch and checks what the report lists: each kind of weakening shows,
# and a branch that weakens nothing gives an empty report.
#
# It needs what the report needs, python3 and git, and yq (mikefarah/yq
# v4, on GitHub's Ubuntu runners) to read the workflows' verdict steps.
#
# usage: scripts/test-weakening-report.sh
#
# shellcheck disable=SC2016 # the backticks are the report's Markdown, not commands
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/weakening-report.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo

# git looks for a repository no higher than the temporary directory, should
# that be in a checkout, and reads no configuration of the machine's.
export GIT_CEILING_DIRECTORIES="$tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

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

# tree: makes $repo anew, a git repository on main with no commit.
tree() {
  rm -rf "$repo"
  git init --quiet --initial-branch=main "$repo"
}

# file <path>: writes its standard input to <path> in the tree.
file() {
  mkdir -p "$(dirname "$repo/$1")"
  cat >"$repo/$1"
}

# remove <path>: removes <path> from the tree.
remove() {
  rm -rf "${repo:?}/$1"
}

# commit <message>: commits everything in the tree.
commit() {
  git -C "$repo" add --all
  git -C "$repo" commit --quiet --allow-empty -m "$1"
}

# branch: commits the tree on main as the base, and starts the branch
# topic from it.
branch() {
  commit base
  git -C "$repo" switch --quiet -c topic
}

# report <name>: commits the tree on the branch, runs the report against
# main, its output into $tmp/<name>.out and its exit status into
# $tmp/<name>.status.
report() {
  commit "$1"
  status=0
  python3 "$script" --repo "$repo" --base main >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
  if [ "$status" != 0 ]; then
    fail "$1: exits with $status, not 0"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# mentions <name> <text>: the report <name> holds <text> in some line.
mentions() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: mentions $2"
  else
    fail "$1: does not mention $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# lacks <name> <text>: the report <name> holds <text> in no line.
lacks() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: mentions $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: does not mention $2"
  fi
}

# section <name> <heading>: the lines of the report <name> under the
# heading "## <heading>", up to the next heading of its level.
section() {
  awk -v heading="## $2" '
    $0 == heading { inside = 1; next }
    /^## / { inside = 0 }
    inside
  ' "$tmp/$1.out"
}

# mentions_in <name> <heading> <text>: the report <name> holds <text> in a
# line under the heading "## <heading>".
mentions_in() {
  if section "$1" "$2" | grep -qF -- "$3"; then
    pass "$1: mentions $3 under $2"
  else
    fail "$1: does not mention $3 under $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# lacks_in <name> <heading> <text>: the report <name> holds <text> in no
# line under the heading "## <heading>".
lacks_in() {
  if section "$1" "$2" | grep -qF -- "$3"; then
    fail "$1: mentions $3 under $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: does not mention $3 under $2"
  fi
}

# empty <name>: the report <name> lists nothing.
empty() {
  if grep -qxF -- "Nothing to report." "$tmp/$1.out" && ! grep -q '^## ' "$tmp/$1.out"; then
    pass "$1: lists nothing"
  else
    fail "$1: lists something"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# The headings of the report's sections that a test reads by name.
other="Other lines changed in tests that stay"
assertions="Assertions removed or changed in tests that stay"

# A package with two tests and the function they test.
package() {
  file add/add.mbt <<'MBT'
///|
/// The sum of two numbers.
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
MBT
  file add/add_test.mbt <<'MBT'
///|
test "adds two numbers" {
  assert_eq(@add.add(2, 3), 5)
}

///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
}

# --- A branch that weakens nothing ---------------------------------------------

# A new test, a changed function and a new document weaken nothing.
tree
package
branch
cat >>"$repo/add/add_test.mbt" <<'MBT'

///|
test "adds zero" {
  assert_eq(@add.add(2, 0), 2)
}
MBT
file add/add.mbt <<'MBT'
///|
/// The sum of two numbers, a and b.
pub fn add(a : Int, b : Int) -> Int {
  b + a
}
MBT
file README.md <<'MD'
# Add
MD
report nothing
empty nothing
mentions nothing "against \`$(git -C "$repo" rev-parse --short main)\`, its merge base with \`main\`"

# --- Tests deleted -------------------------------------------------------------

tree
package
branch
file add/add_test.mbt <<'MBT'
///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
report deleted
mentions deleted "## Tests deleted"
mentions deleted '`add/add_test.mbt:2`: test "adds two numbers"'
lacks deleted 'test "adds a negative number"'

# A test file deleted whole deletes each of its tests.
tree
package
branch
remove add/add_test.mbt
report deleted-file
mentions deleted-file '`add/add_test.mbt:2`: test "adds two numbers"'
mentions deleted-file '`add/add_test.mbt:7`: test "adds a negative number"'

# --- Assertions removed or changed in a test that stays -------------------------

# A timed test: an upper bound in a guard, a comparison kept in a variable,
# and an assertion over several lines.
timed() {
  file add/timed_test.mbt <<'MBT'
///|
test "answers in time" {
  let took = 120L
  guard took < 250L else { fail("took \{took} ms") }
  let fast = took < 300L
  inspect(fast, content="true")
  assert_eq(
    @add.add(took.to_int(), 1),
    121,
  )
}

///|
/// Fails unless the text is short.
fn check_short(text : String) -> Unit raise {
  if text.length() > 10 {
    fail("too long: \{text}")
  }
}
MBT
}

# An exact comparison made weaker.
tree
package
branch
file add/add_test.mbt <<'MBT'
///|
test "adds two numbers" {
  assert_true(@add.add(2, 3) > 0)
}

///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
report weaker
mentions weaker "## Assertions removed or changed in tests that stay"
mentions weaker '`add/add_test.mbt:2`: test "adds two numbers"'
mentions weaker '-  assert_eq(@add.add(2, 3), 5)'
mentions weaker '+  assert_true(@add.add(2, 3) > 0)'
lacks weaker "## Tests deleted"
lacks weaker 'test "adds a negative number"'

# An upper bound raised, in a guard and in a variable.
tree
package
timed
branch
sed -i 's/took < 250L/took < 2500L/; s/took < 300L/took < 3000L/' "$repo/add/timed_test.mbt"
report bound
mentions bound '`add/timed_test.mbt:2`: test "answers in time"'
mentions bound '-  guard took < 250L else { fail("took \{took} ms") }'
mentions bound '+  guard took < 2500L else { fail("took \{took} ms") }'
mentions bound '-  let fast = took < 300L'
mentions bound '+  let fast = took < 3000L'

# The bound in the variable alone: a comparison is an assertion line of
# its own, whatever the lines beside it.
tree
package
timed
branch
sed -i 's/took < 300L/took < 3000L/' "$repo/add/timed_test.mbt"
report bound-variable
mentions bound-variable '-  let fast = took < 300L'
mentions bound-variable '+  let fast = took < 3000L'
lacks bound-variable 'guard'

# A guard whose pattern matches more, and an if whose failure can no longer
# happen, with no comparison on their lines.
tree
package
file add/patterns_test.mbt <<'MBT'
///|
test "answers with a reply" {
  let reply : Int? = Some(5)
  guard reply is Some(5) else {
    fail("no reply")
  }
}

///|
/// Fails when the text is empty.
fn check_filled(text : String) -> Unit raise {
  if text.is_empty() {
    fail("empty")
  }
}
MBT
branch
sed -i 's/Some(5) else/Some(_) else/; s/if text.is_empty() {/if text.is_empty() \&\& false {/' "$repo/add/patterns_test.mbt"
report patterns
mentions patterns '-  guard reply is Some(5) else {'
mentions patterns '+  guard reply is Some(_) else {'
mentions patterns '-  if text.is_empty() {'
mentions patterns '+  if text.is_empty() && false {'

# An assertion removed, and a line changed inside one that spans lines.
tree
package
timed
branch
sed -i '/inspect(fast/d; s/^    121,$/    122,/' "$repo/add/timed_test.mbt"
report removed
mentions removed '-  inspect(fast, content="true")'
mentions removed '-    121,'
mentions removed '+    122,'

# A helper of a test file that no longer fails.
tree
package
timed
branch
sed -i '/fail("too long/d' "$repo/add/timed_test.mbt"
report helper
mentions helper '`add/timed_test.mbt:15`: fn check_short'
mentions helper '-    fail("too long: \{text}")'

# Assertions added to a test that stays, a changed line that asserts
# nothing, and the same test indented in a block of its own remove or
# change no assertion. The added and changed lines show among the other
# lines (#395), and the deeper indentation nowhere.
tree
package
timed
branch
file add/timed_test.mbt <<'MBT'
///|
test "answers in time" {
  let took = 121L
  {
    guard took < 250L else { fail("took \{took} ms") }
    let fast = took < 300L
    inspect(fast, content="true")
    inspect(took > 0L, content="true")
    assert_eq(
      @add.add(took.to_int(), 1),
      121,
    )
  }
}

///|
/// Fails unless the text is short.
fn check_short(text : String) -> Unit raise {
  if text.length() > 10 {
    fail("too long: \{text}")
  }
}
MBT
report extended
lacks extended "## Assertions removed or changed in tests that stay"
lacks extended "## Snapshot lines changed"
mentions_in extended "$other" '-  let took = 120L'
mentions_in extended "$other" '+  let took = 121L'
mentions_in extended "$other" '+    inspect(took > 0L, content="true")'
lacks extended '+    guard took < 250L'

# A case added inside an assertion, as extending a test adds one, removes
# or changes no assertion: it shows among the other lines (#395).
tree
package
timed
branch
sed -i 's/^    @add.add(took.to_int(), 1),$/    @add.add(took.to_int(), 1),\n    @add.add(1, 1),/' "$repo/add/timed_test.mbt"
report case-added
lacks case-added "## Assertions removed or changed in tests that stay"
lacks case-added "## Snapshot lines changed"
mentions_in case-added "$other" '+    @add.add(1, 1),'

# A test whose name is extended, with a case added, stays: its added case
# is among the other lines (#395), and no assertion of it is listed. One
# whose name changes with an assertion is listed under its new name.
tree
package
timed
branch
sed -i 's/test "answers in time"/test "answers in time, under 250 ms"/; s/^  inspect(fast, content="true")$/  inspect(fast, content="true")\n  inspect(took > 100L, content="true")/' "$repo/add/timed_test.mbt"
sed -i 's/test "adds two numbers"/test "adds two positive numbers"/; s/assert_eq(@add.add(2, 3), 5)/assert_eq(@add.add(2, 3), 6)/' "$repo/add/add_test.mbt"
report renamed
lacks renamed "## Tests deleted"
lacks_in renamed "Assertions removed or changed in tests that stay" 'answers in time'
lacks renamed "## Snapshot lines changed"
mentions_in renamed "$other" '### `add/timed_test.mbt:2`: test "answers in time"'
mentions_in renamed "$other" 'Now `add/timed_test.mbt:2`: test "answers in time, under 250 ms".'
mentions_in renamed "$other" '+  inspect(took > 100L, content="true")'
mentions renamed '### `add/add_test.mbt:2`: test "adds two numbers"'
mentions renamed 'Now `add/add_test.mbt:2`: test "adds two positive numbers".'
mentions renamed '-  assert_eq(@add.add(2, 3), 5)'
mentions renamed '+  assert_eq(@add.add(2, 3), 6)'
mentions_in renamed "Tests moved or renamed" '- `add/timed_test.mbt:2`: test "answers in time", now `add/timed_test.mbt:2`, test "answers in time, under 250 ms": its body changed, as listed below.'
mentions_in renamed "Tests moved or renamed" '- `add/add_test.mbt:2`: test "adds two numbers", now `add/add_test.mbt:2`, test "adds two positive numbers": its body changed, as listed below.'

# A test renamed and nothing else: the pairing shows, so that a reader
# sees which new test stands for the old one.
tree
package
branch
sed -i 's/test "adds two numbers"/test "adds two numbers, 2 and 3"/' "$repo/add/add_test.mbt"
report renamed-only
mentions_in renamed-only "Tests moved or renamed" '- `add/add_test.mbt:2`: test "adds two numbers", now `add/add_test.mbt:2`, test "adds two numbers, 2 and 3": its body is unchanged.'
lacks renamed-only "## $other"
lacks renamed-only "## Tests deleted"
lacks renamed-only "Nothing to report."

# --- Tests moved or renamed -------------------------------------------------------

# A test file of three tests and their helper, which a branch moves to
# another package, as #317 moved the ClientHello tests from server to
# serverparsers.
reader() {
  file add/reader_test.mbt <<'MBT'
///|
test "reads a name" {
  let name = read("a.example")
  inspect(name, content="Some(\"a.example\")")
}

///|
test "reads no name" {
  let name = read("")
  inspect(name, content="None")
}

///|
test "reads a name split in two" {
  let name = read("b.example")
  inspect(name, content="Some(\"b.example\")")
}

///|
/// What the reader reads from the text.
fn read(text : String) -> String? {
  let name = text
  if name.is_empty() {
    None
  } else {
    Some(name)
  }
}
MBT
}

# The file moved to another package and renamed: a test moved as it was,
# one moved with a line added, and one deleted; the helper moved with a
# changed line. In the package, a test moved to another file. A test is
# deleted only when no test of its name is left (#395).
tree
package
reader
branch
mkdir -p "$repo/parse"
git -C "$repo" mv add/reader_test.mbt parse/parse_test.mbt
sed -i 's/^  let name = read("")$/  let name = read("")\n  let _ = read("x")/; s/^  let name = text$/  let name = text.trim()/' "$repo/parse/parse_test.mbt"
sed -i '/^test "reads a name split in two" {$/,/^}$/d' "$repo/parse/parse_test.mbt"
file add/sum_test.mbt <<'MBT'
///|
test "adds two numbers" {
  assert_eq(@add.add(2, 3), 5)
}
MBT
file add/add_test.mbt <<'MBT'
///|
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}
MBT
report moved
moved="Tests moved or renamed"
mentions moved "## $moved"
mentions_in moved "$moved" '- `add/reader_test.mbt:2`: test "reads a name", now `parse/parse_test.mbt:2`: its body is unchanged.'
mentions_in moved "$moved" '- `add/reader_test.mbt:8`: test "reads no name", now `parse/parse_test.mbt:8`: its body changed, as listed below.'
mentions_in moved "$moved" '- `add/add_test.mbt:2`: test "adds two numbers", now `add/sum_test.mbt:2`: its body is unchanged.'
lacks_in moved "$moved" 'split in two'
lacks_in moved "$moved" 'fn read'
mentions_in moved "Tests deleted" '- `add/reader_test.mbt:14`: test "reads a name split in two"'
lacks_in moved "Tests deleted" 'test "reads a name"'
lacks_in moved "Tests deleted" 'test "reads no name"'
lacks_in moved "Tests deleted" 'test "adds two numbers"'
mentions_in moved "$other" '### `add/reader_test.mbt:8`: test "reads no name"'
mentions_in moved "$other" 'Now `parse/parse_test.mbt:8`: test "reads no name".'
mentions_in moved "$other" '+  let _ = read("x")'
mentions_in moved "$other" '### `add/reader_test.mbt:21`: fn read'
mentions_in moved "$other" 'Now `parse/parse_test.mbt:18`: fn read.'
mentions_in moved "$other" '+  let name = text.trim()'
lacks_in moved "$other" 'test "reads a name"'

# Moved to another package and renamed, its body kept: followed there, as
# a rename in its package is. A test whose name is left in another
# package has moved there, even when its own package gains a new test
# with its body. A moved test whose comments alone changed says so.
tree
package
reader
branch
mkdir -p "$repo/parse"
git -C "$repo" mv add/reader_test.mbt parse/parse_test.mbt
sed -i 's/^test "reads a name" {$/test "reads the name it asks for" {/' "$repo/parse/parse_test.mbt"
sed -i 's/^  let name = read("b.example")$/  \/\/ Split as a client may split it.\n  let name = read("b.example")/' "$repo/parse/parse_test.mbt"
file add/again_test.mbt <<'MBT'
///|
test "reads no name, again" {
  let name = read("")
  inspect(name, content="None")
}
MBT
report moved-renamed
mentions_in moved-renamed "$moved" '- `add/reader_test.mbt:2`: test "reads a name", now `parse/parse_test.mbt:2`, test "reads the name it asks for": its body is unchanged.'
mentions_in moved-renamed "$moved" '- `add/reader_test.mbt:8`: test "reads no name", now `parse/parse_test.mbt:8`: its body is unchanged.'
mentions_in moved-renamed "$moved" '- `add/reader_test.mbt:14`: test "reads a name split in two", now `parse/parse_test.mbt:14`: only comments or blank lines changed in its body.'
lacks moved-renamed 'reads no name, again'
lacks moved-renamed "## Tests deleted"
lacks moved-renamed "## $other"

# A test whose name is gone, alike a new test of its package and a new
# test of another whose name is even more like its own: its package's
# comes first.
tree
package
reader
branch
sed -i 's/^test "reads a name" {$/test "reads the name it asks for" {/' "$repo/add/reader_test.mbt"
file parse/parse_test.mbt <<'MBT'
///|
test "reads a name." {
  let name = read("a.example")
  inspect(name, content="Some(\"a.example\")")
}
MBT
report renamed-here
mentions_in renamed-here "$moved" '- `add/reader_test.mbt:2`: test "reads a name", now `add/reader_test.mbt:2`, test "reads the name it asks for": its body is unchanged.'
lacks renamed-here 'reads a name.'

# Two packages with a test and a helper of the same names, and a second
# helper in the first. The branch deletes the first package's file, and
# the second package gains a helper of the second's name. The first
# package's test is deleted, since the test of its name that is left is
# the second package's own, and its helpers are followed nowhere: its
# tests moved nowhere.
works() {
  file "$1" <<'MBT'
///|
test "works" {
  assert_true(check())
}

///|
/// Whether it works.
fn check() -> Bool {
  true
}
MBT
}
tree
package
works add/works_test.mbt
cat >>"$repo/add/works_test.mbt" <<'MBT'

///|
/// What it reads.
fn read() -> Bool {
  true
}
MBT
works sub/works_test.mbt
branch
remove add/works_test.mbt
cat >>"$repo/sub/works_test.mbt" <<'MBT'

///|
/// What it reads.
fn read() -> Bool {
  false
}
MBT
report same-names
mentions_in same-names "Tests deleted" '- `add/works_test.mbt:2`: test "works"'
lacks_in same-names "Tests deleted" 'sub/works_test.mbt'
lacks same-names "## $moved"
lacks same-names "## $other"
lacks same-names "## Assertions removed or changed in tests that stay"

# --- Snapshot lines changed ------------------------------------------------------

# Snapshots: written in the call, over several lines, and in a constant and
# a variable that content= names. The test also reads a multi-line string
# that is its input, not a snapshot.
snapshots() {
  file add/lines_test.mbt <<'MBT'
///|
/// The lines that start_up writes.
let startup : String =
  #|starting
  #|listening

///|
test "writes lines" {
  let input =
    #|a: 1
    #|b: 2
  let expected =
    #|a=1
    #|b=2
  inspect(input.length(), content="9")
  inspect(
    [input, "end"].join("\n"),
    content=(
      #|a: 1
      #|b: 2
      #|end
    ),
  )
  inspect(input, content=expected)
  inspect(input, content=startup)
}
MBT
}

# A snapshot written in the call: the line counts as a snapshot line, not
# as another assertion.
tree
package
branch
sed -i 's/content="-1"/content="-2"/' "$repo/add/add_test.mbt"
report inline
mentions inline "## Snapshot lines changed"
mentions inline '`add/add_test.mbt:7`: test "adds a negative number"'
mentions inline '-  inspect(@add.add(2, -3), content="-1")'
mentions inline '+  inspect(@add.add(2, -3), content="-2")'
lacks inline "## Assertions removed or changed in tests that stay"

# A line of a snapshot over several lines changed, and one added to it.
tree
package
snapshots
branch
sed -i 's/^      #|b: 2$/      #|b: 3/; s/^      #|end$/      #|end\n      #|more/' "$repo/add/lines_test.mbt"
report multiline
mentions multiline '`add/lines_test.mbt:8`: test "writes lines"'
mentions multiline '-      #|b: 2'
mentions multiline '+      #|b: 3'
mentions multiline '+      #|more'
lacks multiline '#|a: 1'

# A snapshot in a variable and in a constant that content= names.
tree
package
snapshots
branch
sed -i 's/^    #|b=2$/    #|b=3/; s/^  #|listening$/  #|ready/' "$repo/add/lines_test.mbt"
report named
mentions named '-    #|b=2'
mentions named '+    #|b=3'
mentions named '`add/lines_test.mbt:3`: let startup'
mentions named '-  #|listening'
mentions named '+  #|ready'
lacks named "## Assertions removed or changed in tests that stay"

# A snapshot of a file in __snapshot__, changed and deleted; a new one is
# not a change.
tree
package
file add/__snapshot__/sum.txt <<'TXT'
5
TXT
file add/__snapshot__/difference.txt <<'TXT'
-1
TXT
branch
echo 6 >"$repo/add/__snapshot__/sum.txt"
remove add/__snapshot__/difference.txt
echo 0 >"$repo/add/__snapshot__/zero.txt"
report snapshot-file
mentions snapshot-file '`add/__snapshot__/sum.txt`'
mentions snapshot-file '+6'
mentions snapshot-file '`add/__snapshot__/difference.txt`'
lacks snapshot-file 'zero.txt'

# The test's input changed, and a new snapshot added, change no snapshot
# or assertion: the input's new line shows among the other lines (#395),
# and the new test nowhere.
tree
package
snapshots
branch
sed -i 's/^    #|b: 2$/    #|b: 2\n    #|c: 3/' "$repo/add/lines_test.mbt"
cat >>"$repo/add/lines_test.mbt" <<'MBT'

///|
test "writes one line" {
  inspect(
    "a",
    content=(
      #|a
    ),
  )
}
MBT
report input
lacks input "## Snapshot lines changed"
lacks input "## Assertions removed or changed in tests that stay"
mentions_in input "$other" '+    #|c: 3'
lacks input 'writes one line'

# --- Other lines changed in tests that stay ---------------------------------------

# A test that computes its result first and asserts it later, as the SSE
# test of a client that closes the connection mid-stream does (#395): the
# wait and the condition that decide what it shows are lines that assert
# nothing, so its snapshot can stay while they loosen it.
waited() {
  file add/waited_test.mbt <<'MBT'
///|
test "ends soon after the close" {
  let start = 0L
  // The stream ends at smock's next write.
  let ended = wait_for(3000)
  let ended_ms = 120L - start
  let out = [
    if ended {
      "ended"
    } else {
      "still runs 3 s after the close"
    },
  ]
  inspect(out.join("\n"), content="ended")
}

///|
/// Whether the stream ended within the wait.
fn wait_for(ms : Int) -> Bool {
  let waited = ms
  waited > 0
}
MBT
}

# The wait raised, and the condition changed: issue #395's first example.
# A line added that asserts nothing shows too.
tree
package
waited
branch
sed -i 's/wait_for(3000)/wait_for(20000)/; s/^    if ended {$/    if ended \&\& ended_ms < 10000L {/' "$repo/add/waited_test.mbt"
sed -i 's/^  let ended_ms = 120L - start$/  let ended_ms = 120L - start\n  let _ = ended_ms + 1L/' "$repo/add/waited_test.mbt"
report other
mentions other "## $other"
mentions_in other "$other" '### `add/waited_test.mbt:2`: test "ends soon after the close"'
mentions_in other "$other" '-  let ended = wait_for(3000)'
mentions_in other "$other" '+  let ended = wait_for(20000)'
mentions_in other "$other" '-    if ended {'
mentions_in other "$other" '+    if ended && ended_ms < 10000L {'
mentions_in other "$other" '+  let _ = ended_ms + 1L'
lacks other "## Assertions removed or changed in tests that stay"
lacks other "## Snapshot lines changed"
lacks other "## Tests deleted"

# A comment changed and a blank line added change no code: nothing shows.
tree
package
waited
branch
sed -i "s|^  // The stream ends at smock's next write.\$|  // smock notices at its next write (the documents' words).\n|" "$repo/add/waited_test.mbt"
report comment
empty comment

# A test whose assertions span lines, with comments between the elements
# of a debug_inspect call's array, in an assert_eq call and between the
# lines of a snapshot. Two lines only look like comments: a string that
# starts with // and a snapshot line of that text.
counted() {
  file add/counted_test.mbt <<'MBT'
///|
test "adds in lists" {
  debug_inspect(
    [
      @add.add(1, 2),
      // The second sum: two and three,
      // as the first test adds them.
      @add.add(2, 3),
      @add.add(3, 4), // seven
    ],
    content=(
      #|[3, 5, 7]
    ),
  )
  assert_eq(
    @add.add(4, 4),
    // Eight, as the documents say.
    8,
  )
  // Nine, as the documents say.
  assert_eq(@add.add(4, 5), 9)
}

///|
test "names the sums" {
  inspect(
    [
      // An address, then a line that only looks like a comment.
      "http://a.example/\{@add.add(1, 2)}",
      "// \{@add.add(2, 3)}",
    ].join("\n"),
    content=(
      #|http://a.example/3
      // The second line, from the second element.
      #|// 5
    ),
  )
}
MBT
}

# Comments reworded, and one added, inside assertions and a snapshot that
# span lines change no code: nothing shows, as outside them (#428).
tree
package
counted
branch
sed -i 's|^      // as the first test adds them\.$|      // as the first test adds them, which\n      // the documents give.|; s|^    // Eight, as the documents say\.$|    // Eight, the sum the documents give.|' "$repo/add/counted_test.mbt"
sed -i 's/^      #|\[3, 5, 7\]$/      \/\/ The three sums.\n      #|[3, 5, 7]/' "$repo/add/counted_test.mbt"
sed -i 's|^      // An address, then .*$|      // An address, then a string.|; s|^      // The second line, from .*$|      // The second line.\n      // It is the second element.|' "$repo/add/counted_test.mbt"
report comment-inside
empty comment-inside

# A hunk is left out only when every line of it is a comment or blank, in
# the base and in the head. A line that only looks like a comment is
# listed: a string that holds //, and a snapshot line (#|) whose text
# starts with it.
tree
package
counted
branch
sed -i 's|"http://a.example/|"http://b.example/|; s|^      "// \\{|      "//  \\{|; s/^      #|\/\/ 5$/      #|\/\/  5/' "$repo/add/counted_test.mbt"
report comment-like
mentions_in comment-like "$assertions" '+      "http://b.example/\{@add.add(1, 2)}",'
mentions_in comment-like "$assertions" '+      "//  \{@add.add(2, 3)}",'
mentions_in comment-like "Snapshot lines changed" '-      #|// 5'
mentions_in comment-like "Snapshot lines changed" '+      #|//  5'

# A comment changed in one hunk with a line of code, and a comment after
# code on its line, are listed with the code.
tree
package
counted
branch
sed -i 's|^    // Eight, as the documents say\.$|    // Eight or more.|; s|^    8,$|    @add.add(4, 4),|; s|^      @add.add(3, 4), // seven$|      @add.add(3, 4), // seven, or more|' "$repo/add/counted_test.mbt"
report comment-and-code
mentions_in comment-and-code "$assertions" '-    // Eight, as the documents say.'
mentions_in comment-and-code "$assertions" '-    8,'
mentions_in comment-and-code "$assertions" '+    @add.add(4, 4),'
mentions_in comment-and-code "$assertions" '-      @add.add(3, 4), // seven'
mentions_in comment-and-code "$assertions" '+      @add.add(3, 4), // seven, or more'

# An assertion commented out, and one deleted beside a comment that is
# reworded: the base's lines are code, so they are listed.
tree
package
counted
branch
sed -i 's|^      @add.add(2, 3),$|      // @add.add(2, 3),|; s|^  // Nine, as the documents say\.$|  // Nine is checked elsewhere.|; /^  assert_eq(@add.add(4, 5), 9)$/d' "$repo/add/counted_test.mbt"
report comment-out
mentions_in comment-out "$assertions" '-      @add.add(2, 3),'
mentions_in comment-out "$assertions" '+      // @add.add(2, 3),'
mentions_in comment-out "$assertions" '-  assert_eq(@add.add(4, 5), 9)'

# The other lines of a helper of a test file show too, since a helper's
# wait loosens every test that calls it; a changed comparison in it stays
# with the assertions.
tree
package
waited
branch
sed -i 's/^  waited > 0$/  waited >= 0/' "$repo/add/waited_test.mbt"
sed -i 's/^fn wait_for(ms : Int) -> Bool {$/fn wait_for(ms : Int, patience? : Int = 20000) -> Bool {/' "$repo/add/waited_test.mbt"
report other-helper
mentions_in other-helper "$other" '### `add/waited_test.mbt:19`: fn wait_for'
mentions_in other-helper "$other" '-fn wait_for(ms : Int) -> Bool {'
mentions_in other-helper "$other" '+fn wait_for(ms : Int, patience? : Int = 20000) -> Bool {'
mentions_in other-helper "Assertions removed or changed in tests that stay" '-  waited > 0'
lacks_in other-helper "$other" '-  waited > 0'

# --- Skip attributes and settings that keep tests off wasm-gc ---------------------

# A test skipped, a new test skipped, and a test compiled for native alone.
tree
package
branch
file add/add_test.mbt <<'MBT'
///|
#skip
test "adds two numbers" {
  assert_eq(@add.add(2, 3), 5)
}

///|
#cfg(target="native")
test "adds a negative number" {
  inspect(@add.add(2, -3), content="-1")
}

///|
#skip("flaky")
test "adds zero" {
  assert_eq(@add.add(2, 0), 2)
}
MBT
report skip
mentions skip "## Skip attributes and target settings added"
mentions skip '`add/add_test.mbt:3`: test "adds two numbers": `#skip`'
mentions skip '`add/add_test.mbt:9`: test "adds a negative number": `#cfg(target="native")`'
mentions skip '`add/add_test.mbt:15`: test "adds zero": `#skip("flaky")`'
lacks skip "## Tests deleted"

# A test that keeps the attribute it had, and gains a skip: only the skip
# is listed.
tree
file add/add_test.mbt <<'MBT'
///|
#cfg(target="native")
test "adds two numbers" {
  assert_eq(2 + 3, 5)
}
MBT
branch
sed -i 's/^#cfg(target="native")$/#cfg(target="native")\n#skip/' "$repo/add/add_test.mbt"
report skip-kept
mentions skip-kept '`add/add_test.mbt:4`: test "adds two numbers": `#skip`'
lacks skip-kept '`#cfg'

# A package whose tests no longer run on wasm-gc.
tree
package
file add/moon.pkg <<'PKG'
import {
  "moonbitlang/core/json",
}
PKG
branch
cat >>"$repo/add/moon.pkg" <<'PKG'

supported_targets = "native"
PKG
report package-targets
mentions package-targets '`add/moon.pkg`: the tests of `add` no longer run on wasm-gc: `supported_targets = "native"`'

# The same in a package's JSON settings, by a list of targets.
tree
package
echo '{ "import": [] }' >"$repo/add/moon.pkg.json"
branch
echo '{ "import": [], "supported-targets": ["native", "js"] }' >"$repo/add/moon.pkg.json"
report package-targets-json
mentions package-targets-json '`add/moon.pkg.json`: the tests of `add` no longer run on wasm-gc'

# A test file that no longer builds for wasm-gc.
tree
package
file add/moon.pkg <<'PKG'
options(
  targets: {
    "add_test.mbt": [ "native", "wasm-gc" ],
  },
)
PKG
branch
sed -i 's/"native", "wasm-gc"/"native"/' "$repo/add/moon.pkg"
report file-targets
mentions file-targets '`add/moon.pkg`: `add/add_test.mbt` no longer runs on wasm-gc: `"add_test.mbt": [ "native" ]`'

# The same in settings that the package had not.
tree
package
branch
file add/moon.pkg <<'PKG'
options(targets: { "add_test.mbt": ["native"] })
PKG
report file-targets-new
mentions file-targets-new '`add/moon.pkg`: `add/add_test.mbt` no longer runs on wasm-gc: `"add_test.mbt": ["native"]`'

# Another import, a package that runs on wasm-gc as well, and one that
# stays native-only weaken nothing.
tree
package
file add/moon.pkg <<'PKG'
supported_targets = "native"
PKG
file sub/sub_test.mbt <<'MBT'
///|
test "subtracts" {
  assert_eq(3 - 2, 1)
}
MBT
file sub/moon.pkg <<'PKG'
supported_targets = "native"
PKG
branch
file add/moon.pkg <<'PKG'
import {
  "moonbitlang/core/json",
}

supported_targets = "native+wasm-gc"
PKG
file sub/moon.pkg <<'PKG'
supported_targets = "-all+native"
PKG
report targets-kept
empty targets-kept

# --- Files that decide a verdict ----------------------------------------------------

# A list of watched paths: a file, a directory and a pattern.
watched() {
  file scripts/verdict-files.txt <<'TXT'
# A comment, and a blank line.

floors.txt          the coverage floors
runner/             the mutation runner and its data
ci/mutation*.yml    the mutation workflows
TXT
  file floors.txt <<'TXT'
add 3
TXT
  file runner/data/sites.txt <<'TXT'
add 12
TXT
}

# A floor raised, a file of the runner's data changed and one added, a
# workflow added; a file beside them that is not listed.
tree
package
watched
branch
echo "add 4" | file floors.txt
echo "add 11" | file runner/data/sites.txt
echo "operators" | file runner/operators.txt
echo "on: push" | file ci/mutation-weekly.yml
echo "on: push" | file ci/other.yml
echo "not runner" | file runner.txt
echo "on: push" | file ci/mutation/deeper.yml
report verdict
mentions verdict "## Files that decide a verdict changed"
mentions verdict '### `floors.txt` (changed)'
mentions verdict 'The coverage floors (listed as `floors.txt`).'
mentions verdict '-add 3'
mentions verdict '+add 4'
mentions verdict '### `runner/data/sites.txt` (changed)'
mentions verdict 'The mutation runner and its data (listed as `runner/`).'
mentions verdict '### `runner/operators.txt` (added)'
mentions verdict '### `ci/mutation-weekly.yml` (added)'
mentions verdict 'The mutation workflows (listed as `ci/mutation*.yml`).'
lacks verdict 'ci/other.yml'
lacks verdict 'runner.txt'
lacks verdict 'ci/mutation/deeper.yml'

# A file deleted, and a path taken off the list while its file changes:
# the list of the base and the head's both count, and a change to the list
# shows whatever it names.
tree
package
watched
branch
remove runner
sed -i '/^floors.txt/d' "$repo/scripts/verdict-files.txt"
echo "add 2" | file floors.txt
report verdict-off
mentions verdict-off '### `runner/data/sites.txt` (deleted)'
mentions verdict-off '### `floors.txt` (changed)'
mentions verdict-off '### `scripts/verdict-files.txt` (changed)'
mentions verdict-off 'The list of the files that decide a verdict (listed as `scripts/verdict-files.txt`).'
mentions verdict-off '-floors.txt          the coverage floors'

# --- The exclusion list's reviewers --------------------------------------------------

# Only the maintainer fills in an entry's reviewer, in a commit the
# maintainer makes or acknowledges at the merge: the report lists every
# entry whose reviewer changed, by its id, and an entry that comes with a
# reviewer (#302). A change to another field shows only in the list's
# diff.
exclusions() {
  file exclusions.toml <<TOML
[[exclusion]]
mutant = "calc/calc.mbt,is_odd,INT,0,-1,0"
text = "90e6c82aa9560cde"
category = "ARID"
reason = "$1"
reviewer = "$2"

[[exclusion]]
file = "engine/crud.mbt"
definition = "crud_call"
position = "5:13"
text = "0123456789abcdef"
category = "UNREACHABLE"
reason = "An abort arm."
reviewer = "$3"
TOML
}
tree
package
exclusions "A default." "" ""
branch
exclusions "Another reason." "" "the maintainer"
cat >>"$repo/exclusions.toml" <<'TOML'

[[exclusion]]
mutant = "calc/calc.mbt,is_blank,NOT,!,,0"
text = "5fd10e41baf9fa48"
category = "ARID"
reason = "A new entry."
reviewer = "the maintainer"

[[exclusion]]
mutant = "calc/calc.mbt,is_blank,INT,0,1,0"
text = "5fd10e41baf9fa48"
category = "ARID"
reason = "A new entry, not reviewed."
reviewer = ""
TOML
report reviewers
mentions reviewers "## Exclusion entries whose reviewer changed"
mentions reviewers '- `engine/crud.mbt,crud_call,5:13`: from none to "the maintainer"'
mentions reviewers '- `calc/calc.mbt,is_blank,NOT,!,,0`: a new entry, reviewed by "the maintainer"'
lacks reviewers '- `calc/calc.mbt,is_odd,INT,0,-1,0`'
lacks reviewers '- `calc/calc.mbt,is_blank,INT,0,1,0`'

# A reviewer taken away shows too.
tree
package
exclusions "A default." "the maintainer" ""
branch
exclusions "A default." "" ""
report reviewer-gone
mentions reviewer-gone '- `calc/calc.mbt,is_odd,INT,0,-1,0`: from "the maintainer" to none'

# A watched Markdown file whose diff holds a fence of its own: the report
# fences the diff with more backticks, so that the fence does not end it.
tree
package
file scripts/verdict-files.txt <<'TXT'
docs/rules.md    the rules
TXT
file docs/rules.md <<'MD'
# Rules
MD
branch
cat >>"$repo/docs/rules.md" <<'MD'

```sh
run it
```
MD
report fence
mentions fence '````diff'
mentions fence '+```sh'
if [ "$(grep -c '^````$' "$tmp/fence.out")" = 1 ]; then
  pass "fence: the diff's fence ends once"
else
  fail "fence: the diff's fence does not end once"
  sed 's/^/     /' "$tmp/fence.out"
fi

# Each path that the committed list names shows, with what the list says
# it is. A path with * or ending in / stands for a file it matches.
list=scripts/verdict-files.txt
tree
package
branch
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
entries=0
# shellcheck disable=SC2094 # file writes into the repository, not the list
while read -r pattern description; do
  case $pattern in '' | '#'*) continue ;; esac
  entries=$((entries + 1))
  path=$(printf '%s\n' "$pattern" | sed 's|\*|x|g; s|/$|/x|')
  if [ "$path" != "$list" ]; then
    file "$path" </dev/null
  fi
  printf '%s\t%s\t%s\n' "$path" "$pattern" "$description" >>"$tmp/entries"
done <"$list"
report committed-list
while IFS="$(printf '\t')" read -r path pattern description; do
  first=$(printf '%s' "$description" | cut -c1 | tr '[:lower:]' '[:upper:]')
  mentions committed-list "### \`$path\` (added)"
  mentions committed-list "$first$(printf '%s' "$description" | cut -c2-) (listed as \`$pattern\`)."
done <"$tmp/entries"
if [ "$entries" -ge 10 ]; then
  pass "committed-list: names $entries paths"
else
  fail "committed-list: names $entries paths, fewer than the kinds of file it must name"
fi

# Under the committed list, a change to the coverage floors and a recorded
# raise show line by line: the maintainer's acknowledgment of the report at
# the merge is the approval of each changed floor and recorded raise
# (#297).
tree
package
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
printf '%s\n' "# The floors." "engine 103" "prng 0" | file coverage/floors.txt
printf '%s\n' "# The raises." | file coverage/approved-raises.txt
branch
printf '%s\n' "# The floors." "engine 101" "prng 1" | file coverage/floors.txt
printf '%s\n' "# The raises." "prng 1 the abort arm waits for the exclusion list (#302)" | file coverage/approved-raises.txt
report floors
mentions floors '### `coverage/floors.txt` (changed)'
mentions floors '-engine 103'
mentions floors '+engine 101'
mentions floors '-prng 0'
mentions floors '+prng 1'
mentions floors '### `coverage/approved-raises.txt` (changed)'
mentions floors '+prng 1 the abort arm waits for the exclusion list (#302)'

# The committed list names every file of the tools that decide a verdict,
# where the checkout has them, so that a change to any of them is listed:
# #310 lists "the runner and its data" and "the coverage wrapper with its
# floors and scope" among the files that decide a verdict. The mutation
# runner is scripts/mutation/ (#298, #299), and the coverage wrapper, its
# bisect parser and the parser's test data are scripts/coverage.sh,
# scripts/coverage-report.py and scripts/coverage-tests/ (#296); the
# ratchet that holds the floors is scripts/coverage-ratchet.py (#297).
# #308: "Changes to the list and to the recorded verdicts show in the
# weakening report": the canary's mutants with their recorded verdicts,
# its list of explained differences (mutation/canary/) and its workflow.
# #275, "Weakening report": "the mutation and coverage workflows", among
# them the bulk runs' (#313) and the coverage from the e2e tests (#342),
# with its report, which decides the positions e2e covers and the points
# no test reaches.
tree
package
branch
mkdir -p "$repo/scripts"
cp "$list" "$repo/$list"
git ls-files -- scripts/mutation scripts/coverage.sh scripts/coverage-report.py scripts/coverage-tests \
  scripts/coverage-ratchet.py mutation/canary .github/workflows/mutation-canary.yml \
  .github/workflows/mutation-runs.yml scripts/coverage-e2e.sh scripts/coverage-e2e.py \
  .github/workflows/coverage-e2e.yml >"$tmp/tool-files"
tools=0
while read -r path; do
  tools=$((tools + 1))
  file "$path" </dev/null
done <"$tmp/tool-files"
report tool-files
while read -r path; do
  mentions tool-files "### \`$path\` (added)"
done <"$tmp/tool-files"
if [ "$tools" -ge 5 ]; then
  pass "tool-files: the checkout has $tools files of the tools"
else
  fail "tool-files: the checkout has $tools files of the tools, fewer than the five it names"
fi

# --- The verdict steps ---------------------------------------------------------

# The steps of the workflows that judge a suite's results against its list
# of the cases that may fail, a list the committed list names, and the
# steps that test that judgment. Each script such a step runs, and each
# script that one of those runs, decides a verdict, so the committed list
# names it and the report shows a change to it (#395, which names the YAML
# test suite's verdict script and its test). The release's check of the
# latest weekly mutation run judges that run against the list of packages
# at L4, which the committed list names too (#316). The checks of the keep
# list and of the ledgers judge each test those lists name against the
# tests there are (the maintainer, 2026-11-20, on what #395 left off). The
# tests of these scripts are asked for below, with every listed script's.
# A step is named by its workflow, its job and its name: a step renamed or
# gone fails the check, so that it is looked at again.
cat >"$tmp/verdict-steps" <<'TXT'
.github/workflows/ci.yml	yaml-test-suite	Run yaml-test-suite against smock/yaml in both modes
.github/workflows/ci.yml	scripts	Test the yaml-test-suite verdict
.github/workflows/build-test.yml	release	Run h2spec against the plain port (h2c) and the TLS port (h2)
.github/workflows/ci.yml	scripts	Test the h2spec verdict
.github/workflows/build-test.yml	protobuf-conformance	Run protobuf's conformance suite against smock/protobuf
.github/workflows/release.yml	plan	Check that the latest weekly mutation run is clean in the packages at L4
.github/workflows/ci.yml	scripts	Check that every test on the keep list is still there
.github/workflows/ci.yml	scripts	Check that every test the ledgers name is still there
TXT

# step_scripts <root> <steps>: the scripts under <root> that the steps of
# <root>'s workflows named in <steps> run, one path a line. A step runs the
# scripts its run names as a command; a shell script runs those its code
# names as a command, and a Python script those it holds as a string that
# is the path alone. A step that is not there, or that runs no command, is
# said on standard error, with status 1.
step_scripts() {
  python3 - "$1" "$2" <<'PY'
import ast, json, os, re, subprocess, sys

root, steps = sys.argv[1], sys.argv[2]
PATH = r"(?:\./|\$PWD/|\$\{PWD\}/)?(scripts/[\w./-]+\.(?:sh|py))\b"
COMMAND = re.compile(
    r"(?:^|[;&|(`{]|\$\(|\b(?:then|do|else|exec)\s)\s*(?:[A-Za-z_]\w*=\S*\s+)*"
    r"(?:(?:python3|sh|bash)(?:\s+-\w+)*\s+)?[\"']?" + PATH
)


def by_shell(text):
    return [
        found
        for line in text.splitlines()
        if not line.lstrip().startswith("#")
        for found in COMMAND.findall(line)
    ]


def by_python(text):
    return [
        match.group(1)
        for node in ast.walk(ast.parse(text))
        if isinstance(node, ast.Constant) and isinstance(node.value, str)
        if (match := re.fullmatch(PATH, node.value))
    ]


status, queue, seen, workflows = 0, [], [], {}
for line in open(steps):
    workflow, job, name = line.rstrip("\n").split("\t")
    if workflow not in workflows:
        try:
            yq = subprocess.run(["yq", "-o=json", os.path.join(root, workflow)], capture_output=True, text=True)
        except OSError as error:
            sys.exit(f"cannot run yq: {error}")
        if yq.returncode != 0:
            sys.exit(f"yq cannot read {workflow}: {yq.stderr.strip()}")
        workflows[workflow] = json.loads(yq.stdout)
    runs = [
        step.get("run")
        for step in ((workflows[workflow].get("jobs") or {}).get(job) or {}).get("steps") or []
        if step.get("name") == name
    ]
    if len(runs) != 1 or not isinstance(runs[0], str):
        print(f"{workflow}: job {job} has no step {name!r} that runs a command", file=sys.stderr)
        status = 1
        continue
    queue += by_shell(runs[0])
while queue:
    path = queue.pop(0)
    if path in seen or not os.path.isfile(os.path.join(root, path)):
        continue
    seen.append(path)
    text = open(os.path.join(root, path)).read()
    queue += by_python(text) if path.endswith(".py") else by_shell(text)
print("\n".join(seen))
sys.exit(status)
PY
}

# The finder on a small tree: a step that runs a shell script, which runs
# a Python script and names another in a message; the Python script runs
# a third and names a fourth in its docstring. A step that is gone, and
# one that runs no command, are said.
steps=$tmp/steps
rm -rf "$steps"
mkdir -p "$steps/.github/workflows" "$steps/scripts"
cat >"$steps/.github/workflows/ci.yml" <<'YML'
jobs:
  suite:
    steps:
      - name: Set up Python
        uses: actions/setup-python@v6
      - name: Run the suite
        run: |
          mkdir -p out
          FOO=1 scripts/run-suite.sh out
YML
cat >"$steps/scripts/run-suite.sh" <<'SH'
#!/bin/sh
# scripts/commented.sh is not run.
python3 scripts/verdict.py "$1" || echo "see scripts/message.sh"
SH
cat >"$steps/scripts/verdict.py" <<'PY'
"""Judges a run. scripts/docstring.sh tells how."""
import subprocess
subprocess.run(["sh", "scripts/helper.sh"], check=True)
PY
for name in commented.sh message.sh docstring.sh helper.sh; do
  : >"$steps/scripts/$name"
done
printf '.github/workflows/ci.yml\tsuite\tRun the suite\n' >"$tmp/steps.tsv"
if step_scripts "$steps" "$tmp/steps.tsv" >"$tmp/steps.out" &&
  [ "$(tr '\n' ' ' <"$tmp/steps.out")" = "scripts/run-suite.sh scripts/verdict.py scripts/helper.sh " ]; then
  pass "step-scripts: finds the scripts a step runs, through the scripts it runs"
else
  fail "step-scripts: finds $(tr '\n' ' ' <"$tmp/steps.out")"
fi
printf '.github/workflows/ci.yml\tsuite\tRun the old suite\n' >"$tmp/steps-gone.tsv"
if step_scripts "$steps" "$tmp/steps-gone.tsv" >/dev/null 2>"$tmp/steps-gone.err"; then
  fail "step-scripts: passes a step that is gone"
elif grep -qF "job suite has no step 'Run the old suite' that runs a command" "$tmp/steps-gone.err"; then
  pass "step-scripts: says a step that is gone"
else
  fail "step-scripts: says $(cat "$tmp/steps-gone.err")"
fi
printf '.github/workflows/ci.yml\tsuite\tSet up Python\n' >"$tmp/steps-uses.tsv"
if step_scripts "$steps" "$tmp/steps-uses.tsv" >/dev/null 2>"$tmp/steps-uses.err"; then
  fail "step-scripts: passes a step that runs no command"
elif grep -qF "job suite has no step 'Set up Python' that runs a command" "$tmp/steps-uses.err"; then
  pass "step-scripts: says a step that runs no command"
else
  fail "step-scripts: says $(cat "$tmp/steps-uses.err")"
fi

# unlisted <list> <name> [<paths>]: writes into $tmp/<name>.missing the
# paths of the file <paths>, by default the scripts of the verdict steps,
# that the report does not show as files that decide a verdict, under the
# list <list>, on a branch that adds each of them; the report is <name>.
unlisted() {
  paths=${3:-$tmp/step-scripts}
  tree
  package
  branch
  mkdir -p "$repo/scripts"
  cp "$1" "$repo/$list"
  while read -r path; do
    file "$path" </dev/null
  done <"$paths"
  report "$2"
  : >"$tmp/$2.missing"
  while read -r path; do
    grep -qF -- "### \`$path\` (added)" "$tmp/$2.out" || echo "$path" >>"$tmp/$2.missing"
  done <"$paths"
}

# The committed list names every script of the verdict steps.
if step_scripts . "$tmp/verdict-steps" >"$tmp/step-scripts" 2>"$tmp/step-scripts.err"; then
  pass "verdict-steps: each verdict step is in its workflow"
else
  fail "verdict-steps: $(cat "$tmp/step-scripts.err")"
fi
for path in scripts/yaml-test-suite-verdict.py scripts/test-yaml-test-suite-verdict.sh scripts/h2spec-verdict.py \
  scripts/check-weekly-run.py scripts/check-kept-tests.py scripts/check-ledgers.py; do
  if grep -qxF -- "$path" "$tmp/step-scripts"; then
    pass "verdict-steps: the verdict steps run $path"
  else
    fail "verdict-steps: the verdict steps do not run $path"
  fi
done
unlisted "$list" verdict-steps
if [ -s "$tmp/verdict-steps.missing" ]; then
  fail "verdict-steps: the committed list does not name $(tr '\n' ' ' <"$tmp/verdict-steps.missing")"
else
  pass "verdict-steps: the committed list names the $(wc -l <"$tmp/step-scripts") scripts of the verdict steps"
fi

# The check fails when the list leaves one of them out: here the YAML test
# suite's verdict script.
grep -v '^scripts/yaml-test-suite-verdict\.py[[:space:]]' "$list" >"$tmp/short-list"
unlisted "$tmp/short-list" verdict-steps-short
if [ "$(cat "$tmp/verdict-steps-short.missing")" = scripts/yaml-test-suite-verdict.py ]; then
  pass "verdict-steps: a list without the YAML test suite's verdict script fails the check"
else
  fail "verdict-steps: a list without the YAML test suite's verdict script misses $(tr '\n' ' ' <"$tmp/verdict-steps-short.missing")"
fi

# --- The steps that install or build a verdict step's tool ---------------------

# A verdict step judges what its tool says, so the step that installs or
# builds that tool, at the version it pins, decides the verdict as surely
# as the list of cases does: the committed list names each script such a
# step runs, and each script that one of those runs (the maintainer,
# 2026-11-20, on what #395 left off). h2spec is installed before its runs;
# protobuf's conformance runner is built, with the protoc of the same
# release, before the conformance suite runs. The YAML test suite's run
# fetches its pinned release itself, so that script is among the verdict
# steps' scripts. A step is named as a verdict step is; a new tool step
# goes into this table.
cat >"$tmp/tool-steps" <<'TXT'
.github/workflows/build-test.yml	release	Install h2spec
.github/workflows/build-test.yml	protobuf-conformance	Build protobuf's conformance runner
TXT
if step_scripts . "$tmp/tool-steps" >"$tmp/tool-scripts" 2>"$tmp/tool-scripts.err"; then
  pass "tool-steps: each tool step is in its workflow"
else
  fail "tool-steps: $(cat "$tmp/tool-scripts.err")"
fi
for path in scripts/install-h2spec.sh scripts/build-conformance-runner.sh scripts/install-protoc.sh; do
  if grep -qxF -- "$path" "$tmp/tool-scripts"; then
    pass "tool-steps: the tool steps run $path"
  else
    fail "tool-steps: the tool steps do not run $path"
  fi
done
unlisted "$list" tool-steps "$tmp/tool-scripts"
if [ -s "$tmp/tool-steps.missing" ]; then
  fail "tool-steps: the committed list does not name $(tr '\n' ' ' <"$tmp/tool-steps.missing")"
else
  pass "tool-steps: the committed list names the $(wc -l <"$tmp/tool-scripts") scripts of the tool steps"
fi

# The check fails when the list leaves one of them out: here h2spec's
# install.
grep -v '^scripts/install-h2spec\.sh[[:space:]]' "$list" >"$tmp/short-list"
unlisted "$tmp/short-list" tool-steps-short "$tmp/tool-scripts"
if [ "$(cat "$tmp/tool-steps-short.missing")" = scripts/install-h2spec.sh ]; then
  pass "tool-steps: a list without h2spec's install fails the check"
else
  fail "tool-steps: a list without h2spec's install misses $(tr '\n' ' ' <"$tmp/tool-steps-short.missing")"
fi

# --- The tests of the listed scripts -------------------------------------------

# A script that the committed list names decides a verdict, and so does its
# own test, which says what the script must do: a test loosened lets the
# script change unseen (the maintainer, 2026-11-20, on what #395 left off).
# A script's own test is the script beside it named test-<name>.sh or
# test_<name>.py, <name> being the script's file name without its
# extension, or the test that this table names for a script whose test is
# named otherwise.
cat >"$tmp/own-tests" <<'TXT'
scripts/check-weekly-run.py	scripts/test-release-gates.sh
TXT

# Each test of the table is there and runs its script.
while IFS="$(printf '\t')" read -r path own; do
  if [ -f "$own" ] && grep -qF -- "$path" "$own"; then
    pass "own-tests: $own runs $path"
  else
    fail "own-tests: $own is not there, or does not run $path"
  fi
done <"$tmp/own-tests"

# own_tests <list> <name>: on a branch that adds every script of the
# checkout, under the list <list> (the report <name>), writes into
# $tmp/<name>.asked the own test of each script that the report shows as a
# file that decides a verdict, with the script, and into $tmp/<name>.missing
# those of them that it does not show.
git ls-files -- 'scripts/*.sh' 'scripts/*.py' >"$tmp/scripts"
own_tests() {
  tree
  package
  branch
  mkdir -p "$repo/scripts"
  cp "$1" "$repo/$list"
  while read -r path; do
    file "$path" </dev/null
  done <"$tmp/scripts"
  report "$2"
  : >"$tmp/$2.asked"
  : >"$tmp/$2.missing"
  # shellcheck disable=SC2094 # the loop and grep both read the list of scripts; nothing writes it
  while read -r path; do
    grep -qF -- "### \`$path\` (added)" "$tmp/$2.out" || continue
    name=${path##*/}
    own=$(awk -F '\t' -v path="$path" '$1 == path { print $2 }' "$tmp/own-tests")
    for candidate in "${path%/*}/test-${name%.*}.sh" "${path%/*}/test_${name%.*}.py"; do
      if [ -z "$own" ] && grep -qxF -- "$candidate" "$tmp/scripts"; then
        own=$candidate
      fi
    done
    [ -n "$own" ] || continue
    echo "$own (the test of $path)" >>"$tmp/$2.asked"
    grep -qF -- "### \`$own\` (added)" "$tmp/$2.out" || echo "$own (the test of $path)" >>"$tmp/$2.missing"
  done <"$tmp/scripts"
}

# The committed list names the own test of every script it names: among
# them those that #395 left off, as #310 had left off the tests of checks.
own_tests "$list" own-tests
for test in "scripts/test-coverage-ratchet.sh (the test of scripts/coverage-ratchet.py)" \
  "scripts/test-check-merge.sh (the test of scripts/check-merge.py)" \
  "scripts/test-changed-lines.sh (the test of scripts/changed-lines.py)" \
  "scripts/test-release-gates.sh (the test of scripts/check-weekly-run.py)" \
  "scripts/test-check-kept-tests.sh (the test of scripts/check-kept-tests.py)" \
  "scripts/test-check-ledgers.sh (the test of scripts/check-ledgers.py)" \
  "scripts/mutation/test_bulk.py (the test of scripts/mutation/bulk.py)"; do
  if grep -qxF -- "$test" "$tmp/own-tests.asked"; then
    pass "own-tests: asks for $test"
  else
    fail "own-tests: does not ask for $test"
  fi
done
if [ -s "$tmp/own-tests.missing" ]; then
  fail "own-tests: the committed list does not name $(tr '\n' ' ' <"$tmp/own-tests.missing")"
else
  pass "own-tests: the committed list names the $(wc -l <"$tmp/own-tests.asked") own tests of the scripts it names"
fi

# The check fails when the list leaves one of them out: here the merge
# check's test, and the release's check's, which the table names.
grep -v '^scripts/test-check-merge\.sh[[:space:]]' "$list" >"$tmp/short-list"
own_tests "$tmp/short-list" own-tests-short
if [ "$(cat "$tmp/own-tests-short.missing")" = "scripts/test-check-merge.sh (the test of scripts/check-merge.py)" ]; then
  pass "own-tests: a list without the merge check's test fails the check"
else
  fail "own-tests: a list without the merge check's test misses $(tr '\n' ' ' <"$tmp/own-tests-short.missing")"
fi
grep -v '^scripts/test-release-gates\.sh[[:space:]]' "$list" >"$tmp/short-list"
own_tests "$tmp/short-list" own-tests-table
if [ "$(cat "$tmp/own-tests-table.missing")" = "scripts/test-release-gates.sh (the test of scripts/check-weekly-run.py)" ]; then
  pass "own-tests: a list without the release's check's test fails the check"
else
  fail "own-tests: a list without the release's check's test misses $(tr '\n' ' ' <"$tmp/own-tests-table.missing")"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
