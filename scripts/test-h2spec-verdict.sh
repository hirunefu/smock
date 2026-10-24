#!/bin/sh
# Tests of the h2spec verdict (scripts/h2spec-verdict.py), which
# scripts/check-h2spec.sh runs on h2spec's JUnit report. Each test writes a
# small report, as h2spec 2.6.0 writes it, and a list of cases, runs the
# verdict on them, and checks its exit status and what it prints.
#
# usage: scripts/test-h2spec-verdict.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

# outcome <pass | fail | skip>: what a testcase element holds for it.
# h2spec 2.6.0 writes a failed case as an error element.
outcome() {
  case $1 in
  pass) ;;
  fail) printf '<error>GOAWAY Frame (Error Code: PROTOCOL_ERROR)\nConnection closed\nError: unexpected EOF</error>' ;;
  skip) printf '<skipped></skipped>' ;;
  esac
}

# report <generic/1/1> <http2/3.5/1> <http2/3.5/2> <http2/6.9.1/1>: writes
# $tmp/report.xml, a report of four cases with these outcomes.
report() {
  cat >"$tmp/report.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="1. Starting HTTP/2" package="generic/1" id="1" tests="1" skipped="0" failures="0" errors="0">
    <testcase package="generic/1" classname="Sends a client connection preface" time="0.0001">$(outcome "$1")</testcase>
  </testsuite>
  <testsuite name="3.5. HTTP/2 Connection Preface" package="http2/3.5" id="3.5" tests="2" skipped="0" failures="0" errors="0">
    <testcase package="http2/3.5" classname="Sends client connection preface" time="0.0001">$(outcome "$2")</testcase>
    <testcase package="http2/3.5" classname="Sends invalid connection preface" time="0.0002">$(outcome "$3")</testcase>
  </testsuite>
  <testsuite name="6.9.1. The Flow-Control Window" package="http2/6.9.1" id="6.9.1" tests="1" skipped="0" failures="0" errors="0">
    <testcase package="http2/6.9.1" classname="Sends SETTINGS frame to set the initial window size to 1 and sends HEADERS frame" time="2.0010">$(outcome "$4")</testcase>
  </testsuite>
</testsuites>
XML
}

# list <line>...: writes $tmp/plain.txt, a list of cases with a comment
# first, one entry for each argument.
list() {
  printf '# A list of cases for the tests.\n' >"$tmp/plain.txt"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp/plain.txt"
  done
}

# verdict <name>: runs the verdict on $tmp/plain.txt and $tmp/report.xml
# into $tmp/<name>.out, and its exit status into $tmp/<name>.status.
verdict() {
  status=0
  python3 scripts/h2spec-verdict.py "$tmp/plain.txt" "$tmp/report.xml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# exits <name> <status>: the verdict <name> exited with <status>.
exits() {
  if [ "$(cat "$tmp/$1.status")" = "$2" ]; then
    pass "$1: exits with $2"
  else
    fail "$1: exits with $(cat "$tmp/$1.status"), not $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# says <name> <line>: the verdict <name> printed <line>.
says() {
  if grep -qxF -- "$2" "$tmp/$1.out"; then
    pass "$1: says $2"
  else
    fail "$1: does not say $2"
    sed 's/^/     /' "$tmp/$1.out"
  fi
}

# --- Cases that pass ---------------------------------------------------------

report pass pass pass pass
list
verdict all-pass
exits all-pass 0
says all-pass "h2spec plain: 4 cases, 4 passed, 0 skipped, 0 failed"
says all-pass "h2spec plain: every case passed or is listed"

# --- Cases that fail ---------------------------------------------------------

# A case that fails and is not listed fails the run, with what h2spec
# expected and got.
report pass pass fail pass
list
verdict unlisted-failure
exits unlisted-failure 1
says unlisted-failure "h2spec plain: 4 cases, 3 passed, 0 skipped, 1 failed"
says unlisted-failure "h2spec plain: http2/3.5/2 failed, and is not listed: Sends invalid connection preface"
says unlisted-failure "    GOAWAY Frame (Error Code: PROTOCOL_ERROR)"
says unlisted-failure "    Error: unexpected EOF"
says unlisted-failure "h2spec plain: 1 case failed or was skipped without being listed in plain.txt"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
