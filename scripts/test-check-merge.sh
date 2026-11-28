#!/bin/sh
# Tests of the merge check (scripts/check-merge.py), which the maintainer
# runs before merging a branch into main. Each test makes a small git
# repository in a temporary directory: main with the list of packages at
# L4 (mutation/l4-packages.txt), a branch from it, and a later commit on
# main. A fake gh answers for the Actions API with a canned list of runs
# of the branch checks on the branch's head, and gives each run's
# artifacts from canned files: the report of the mutants on the changed
# lines (changed-lines, report.json, as scripts/changed-lines.py writes
# it) and the weakening report. Each test checks the exit status and what
# the check prints.
#
# The rules come from the ticket (#312): the check refuses a merge when
# the run on the branch head is missing, failed, has a base other than
# main, or did not cover the whole diff (unless a run started by hand
# covered it), or when its report shows an unexplained survivor on changed
# lines of a package at L4, and says which, with the run's link; it prints
# a stale-covered survivor with its stale entry's id, without refusing;
# it prints the branch's weakening report; and it passes a clean run.
#
# It needs python3, git and jq, and no network.
#
# usage: scripts/test-check-merge.sh
set -eu
cd "$(dirname "$0")/.."

script=$PWD/scripts/check-merge.py
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

# The fake gh records its arguments in $tmp/gh.args. For `gh api` it
# prints $tmp/runs.json; for `gh run download <id> -n <name> --dir <dir>`
# it copies $tmp/artifacts/<id>/<name>/ into <dir>, or fails as gh does
# when the run has no such artifact. With FAKE_GH=fail it fails as gh does
# when the API answers with an error.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH_DIR/gh.args"
if [ "${FAKE_GH:-}" = fail ]; then
  echo "gh: Server Error (HTTP 502)" >&2
  exit 1
fi
case "$1 $2" in
"api "*)
  cat "$FAKE_GH_DIR/runs.json"
  ;;
"run download")
  id=$3
  shift 3
  name="" dir=""
  while [ "$#" -gt 0 ]; do
    case $1 in
    -n | --name) name=$2 && shift 2 ;;
    -D | --dir) dir=$2 && shift 2 ;;
    -R | --repo) shift 2 ;;
    *) shift ;;
    esac
  done
  if [ ! -d "$FAKE_GH_DIR/artifacts/$id/$name" ]; then
    echo "no valid artifacts found to download" >&2
    exit 1
  fi
  mkdir -p "$dir"
  cp -R "$FAKE_GH_DIR/artifacts/$id/$name/." "$dir/"
  ;;
*)
  echo "the fake gh does not answer: $*" >&2
  exit 2
  ;;
esac
SH
chmod +x "$tmp/bin/gh"
export FAKE_GH_DIR="$tmp"

# no_package: writes the repository's list of packages at L4 as the
# committed list's lines that name no package, its header: each is blank
# once its comment is cut off, as the check reads a line. The committed
# list's packages are smock's, which no canned report here names.
no_package() {
  awk '{ line = $0; sub(/#.*/, "", line) } line ~ /^[[:space:]]*$/' mutation/l4-packages.txt \
    >"$repo/mutation/l4-packages.txt"
}

# The repository: main with a list of packages at L4 that names none, the
# branch integration/x from it with a change, and a later commit on main.
git init --quiet --initial-branch=main "$repo"
mkdir -p "$repo/mutation"
no_package
printf 'let a : Int = 1\n' >"$repo/calc.mbt"
git -C "$repo" add --all
git -C "$repo" commit --quiet -m base
base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout --quiet -b integration/x
printf 'let b : Int = 2\n' >>"$repo/calc.mbt"
git -C "$repo" commit --quiet -am change
head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout --quiet main
printf 'other\n' >"$repo/other.txt"
git -C "$repo" add --all
git -C "$repo" commit --quiet -m "main moves on"
url=https://github.com/hirunefu/smock/actions/runs

# run <id> [<event> [<status> [<conclusion> [<created_at>]]]]: prints the
# run <id> of the branch checks on the branch's head as the Actions API
# lists it, by default one for a push that succeeded.
run() {
  jq -n --argjson id "$1" --arg sha "$head" --arg event "${2:-push}" --arg status "${3:-completed}" \
    --arg conclusion "${4-success}" --arg created "${5:-2026-11-18T10:00:00Z}" '{
    id: $id, name: "Branch checks", path: ".github/workflows/branch-checks.yml",
    head_branch: "integration/x", head_sha: $sha, event: $event,
    status: $status, conclusion: (if $conclusion == "" then null else $conclusion end),
    html_url: "https://github.com/hirunefu/smock/actions/runs/\($id)",
    created_at: $created, updated_at: $created, run_attempt: 1
  }'
}

# answer <run>...: writes $tmp/runs.json, an answer that lists the runs.
answer() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$tmp/runs.json"
}

# report <id> [<jq update>]: writes the artifacts of the run <id>: the
# report of the mutants on the changed lines of a run on a push that
# covered the whole diff with no survivor, changed by the update, and a
# weakening report that names the run.
report() {
  rm -rf "$tmp/artifacts/$1"
  mkdir -p "$tmp/artifacts/$1/changed-lines" "$tmp/artifacts/$1/weakening-report"
  jq -n --arg head "$head" --arg base "$base" '{
    head: $head, base: "origin/main", merge_base: $base, event: "push",
    lines: 12, packages: ["calc", "grid"], mutants: 30, covered: true, shards: 1, ran: 30,
    counts: {}, survivors: []
  }' | jq "${2:-.}" >"$tmp/artifacts/$1/changed-lines/report.json"
  printf '# Weakening report\n\nThe weakening report of run %s.\n' "$1" \
    >"$tmp/artifacts/$1/weakening-report/weakening-report.md"
}

# survivor <id> <directory> <status> [<entry>]: prints a survivor as
# report.json lists it.
survivor() {
  jq -n --arg id "$1" --arg dir "$2" --arg status "$3" --arg entry "${4:-}" '{
    id: $id, package: "smock/smock/\($dir)", directory: $dir, file: "\($dir)/\($dir).mbt",
    definition: "f", status: $status, entry: (if $entry == "" then null else $entry end)
  }'
}

# check <name> [<argument>...]: runs the check on integration/x in the
# repository, with the fake gh, and these arguments before the branch. Its
# output goes into $tmp/<name>.out, its exit status into $tmp/<name>.status,
# and gh's arguments into $tmp/<name>.args.
check() {
  name=$1
  shift
  rm -f "$tmp/gh.args"
  status=0
  GITHUB_REPOSITORY=hirunefu/smock PATH="$tmp/bin:$PATH" \
    python3 "$script" --repo "$repo" "$@" integration/x >"$tmp/$name.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$name.status"
  touch "$tmp/gh.args"
  mv "$tmp/gh.args" "$tmp/$name.args"
}

# exits <name> <status>: the check <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <text>: the check <name> printed <text> in some line.
says() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says_not <name> <text>: the check <name> did not print <text>.
says_not() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    fail "$1: says $2"
    sed 's/^/     /' "$tmp/$1.out"
  else
    pass "$1: does not say $2"
  fi
}

# --- A clean run -----------------------------------------------------------------

answer "$(run 101)"
report 101
check clean
exits clean 0
says clean "check-merge: integration/x ($(echo "$head" | cut -c1-12)) may be merged into main, by the branch checks on its head: $url/101"
says clean "The weakening report of run 101."
says clean "for the maintainer to read and acknowledge before the merge"
if grep -qxF "api repos/hirunefu/smock/actions/workflows/branch-checks.yml/runs?head_sha=$head&per_page=100" \
  "$tmp/clean.args"; then
  pass "clean: asks for the runs of the branch checks on the branch's head"
else
  fail "clean: asks gh: $(cat "$tmp/clean.args")"
fi

# --- A run that is missing, running or failed ----------------------------------------

answer
check missing
exits missing 1
says missing "check-merge: integration/x ($(echo "$head" | cut -c1-12)) may not be merged into main: no run of the branch checks on its head"

answer "$(run 102 push in_progress '')"
check running
exits running 1
says running "the branch checks on its head are still running: $url/102"

answer "$(run 103 push completed failure)"
check failed
exits failed 1
says failed "the branch checks on its head failed (failure): $url/103"

answer "$(run 104 push completed cancelled)"
check cancelled
exits cancelled 1
says cancelled "the branch checks on its head failed (cancelled): $url/104"

# The latest run is the one that says why none passed, in whatever order
# the API lists them.
answer "$(run 107 push completed failure 2026-11-18T10:00:00Z)" "$(run 108 push in_progress '' 2026-11-18T11:00:00Z)"
check latest
exits latest 1
says latest "the branch checks on its head are still running: $url/108"

# Nor does a run on another event, should the API list it.
answer "$(run 106 pull_request)"
report 106
check other-event
exits other-event 1
says other-event "no run of the branch checks on its head"

# A run of another commit does not count, should the API list it.
answer "$(run 105 | jq '.head_sha = "0123456789abcdef0123456789abcdef01234567"')"
report 105
check other-commit
exits other-commit 1
says other-commit "no run of the branch checks on its head"

# --- A run against another base -------------------------------------------------------

answer "$(run 111)"
report 111 '.base = "origin/integration/y"'
check other-base
exits other-base 1
says other-base "the branch checks on its head compared it with origin/integration/y, not main: $url/111"

answer "$(run 112)"
report 112 '.merge_base = "fedcba9876543210fedcba9876543210fedcba98"'
check other-merge-base
exits other-merge-base 1
says other-merge-base "the branch checks on its head took the merge base fedcba987654, not the branch's merge base with main, $(echo "$base" | cut -c1-12): $url/112"

# --- A run that did not cover the whole diff ------------------------------------------

answer "$(run 121)"
report 121 '.covered = false | .shards = 0 | .ran = 0 | .mutants = 2100'
check not-covered
exits not-covered 1
says not-covered "the branch checks on its head did not cover the whole diff (2100 mutants on its changed lines): $url/121"
says not-covered "gh workflow run branch-checks.yml --ref integration/x"

# A run started by hand covered it: that run decides, whichever came first.
answer "$(run 122 workflow_dispatch completed success 2026-11-18T11:00:00Z)" "$(run 121)"
report 122 '.event = "workflow_dispatch" | .shards = 20'
check by-hand
exits by-hand 0
says by-hand "may be merged into main, by the branch checks on its head: $url/122"
says by-hand "The weakening report of run 122."

# A later run on a push that did not cover the diff does not undo it, nor
# does a failed one.
answer "$(run 123 push completed failure 2026-11-18T12:00:00Z)" "$(run 121 push completed success 2026-11-18T11:30:00Z)" \
  "$(run 122 workflow_dispatch completed success 2026-11-18T11:00:00Z)"
check by-hand-first
exits by-hand-first 0
says by-hand-first "may be merged into main, by the branch checks on its head: $url/122"

# --- Survivors on the changed lines ------------------------------------------------------

# l4 <package>...: main's list of packages at L4 names these packages.
l4() {
  git -C "$repo" checkout --quiet main
  no_package
  printf '%s\n' "$@" >>"$repo/mutation/l4-packages.txt"
  git -C "$repo" commit --quiet --allow-empty -am "packages at L4: $*"
}

# At first no package is at L4: an unexplained survivor is reported, and
# does not block.
answer "$(run 131)"
report 131 ".survivors = [$(survivor 'calc/calc.mbt,f,ROR,<,<=,0' calc unexplained)]"
check report-only
exits report-only 0
says report-only "check-merge: 1 unexplained survivor on the changed lines of a package not at L4, reported only: calc/calc.mbt,f,ROR,<,<=,0 (calc)"

# Once calc is at L4 on main, it blocks the merge.
l4 calc
check at-l4
exits at-l4 1
says at-l4 "the report of the branch checks on its head shows 1 unexplained survivor on the changed lines of a package at L4: $url/131"
says at-l4 "check-merge:   calc/calc.mbt,f,ROR,<,<=,0 (calc)"
says at-l4 "The weakening report of run 131."

# A package that the branch's own list names is at L4 too.
l4
git -C "$repo" checkout --quiet integration/x
printf 'calc\n' >>"$repo/mutation/l4-packages.txt"
git -C "$repo" commit --quiet -am "calc at L4"
head=$(git -C "$repo" rev-parse HEAD)
answer "$(run 132)"
report 132 ".survivors = [$(survivor 'calc/calc.mbt,f,ROR,<,<=,0' calc unexplained), $(survivor 'grid/grid.mbt,g,INT,1,2,0' grid unexplained)]"
check at-l4-on-the-branch
exits at-l4-on-the-branch 1
says at-l4-on-the-branch "shows 1 unexplained survivor on the changed lines of a package at L4: $url/132"
says at-l4-on-the-branch "check-merge: 1 unexplained survivor on the changed lines of a package not at L4, reported only: grid/grid.mbt,g,INT,1,2,0 (grid)"

# A stale-covered survivor in a package at L4 is listed with its stale
# entry's id, and does not block; nor does an accepted one.
answer "$(run 133)"
report 133 ".survivors = [$(survivor 'calc/calc.mbt,f,ROR,<,<=,0' calc stale-covered 'calc/calc.mbt,f,ROR,<,<=,0'), $(survivor 'calc/calc.mbt,f,INT,1,2,0' calc accepted 'calc/calc.mbt,f,INT,1,2,0')]"
check stale
exits stale 0
says stale "check-merge: 1 stale-covered survivor on the changed lines, to re-triage in a batch:"
says stale "check-merge:   calc/calc.mbt,f,ROR,<,<=,0 (calc), its stale entry calc/calc.mbt,f,ROR,<,<=,0"
says_not stale "calc/calc.mbt,f,INT,1,2,0"

# --- What it cannot read ------------------------------------------------------------

answer "$(run 141)"
report 141
FAKE_GH=fail check gh-fails
exits gh-fails 1
says gh-fails "check-merge: integration/x ($(echo "$head" | cut -c1-12)) may not be merged into main: gh cannot list the runs of the branch checks"

answer "$(run 142)"
check no-artifact
exits no-artifact 1
says no-artifact "the report of the branch checks on its head cannot be read: $url/142"

answer "$(run 143)"
report 143 '.head = "0123456789abcdef0123456789abcdef01234567"'
check other-head
exits other-head 1
says other-head "the report of the branch checks on its head is of another commit, 0123456789ab: $url/143"

# The maintainer acknowledges the weakening report before the merge, so a
# run whose weakening report cannot be read does not let it go ahead.
answer "$(run 144)"
report 144
rm -r "$tmp/artifacts/144/weakening-report"
check no-weakening
exits no-weakening 1
says no-weakening "may not be merged into main: the weakening report of the branch checks on its head cannot be read: $url/144"

printf 'not json\n' >"$tmp/runs.json"
check unreadable
exits unreadable 1
says unreadable "the Actions API gave an answer that cannot be read"

status=0
GITHUB_REPOSITORY=hirunefu/smock PATH="$tmp/bin:$PATH" python3 "$script" --repo "$repo" no/such/branch \
  >"$tmp/no-branch.out" 2>&1 || status=$?
echo "$status" >"$tmp/no-branch.status"
exits no-branch 2
says no-branch "check-merge: no/such/branch is not a commit of"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
