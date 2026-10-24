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

# outcome <pass | fail | error | skip>: what a testcase element holds for
# it. h2spec 2.6.0 writes a failed case as an error element: what it
# expected, one line each, then what it got (fail), or only what went wrong
# (error).
outcome() {
  case $1 in
  pass) ;;
  fail) printf '<error>GOAWAY Frame (Error Code: PROTOCOL_ERROR)\nConnection closed\nError: unexpected EOF</error>' ;;
  error) printf '<error>No HEADER frame received</error>' ;;
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

# verdict <name> [github]: runs the verdict on $tmp/plain.txt and
# $tmp/report.xml into $tmp/<name>.out, and its exit status into
# $tmp/<name>.status; with github, as on GitHub Actions, and otherwise as
# elsewhere, wherever the tests run.
verdict() {
  github=""
  [ "${2:-}" = github ] && github=true
  status=0
  env GITHUB_ACTIONS="$github" python3 scripts/h2spec-verdict.py "$tmp/plain.txt" "$tmp/report.xml" \
    >"$tmp/$1.out" 2>&1 || status=$?
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

# mentions <name> <text>: the verdict <name> printed <text> in some line.
mentions() {
  if grep -qF -- "$2" "$tmp/$1.out"; then
    pass "$1: mentions $2"
  else
    fail "$1: does not mention $2"
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
says unlisted-failure "    expected: GOAWAY Frame (Error Code: PROTOCOL_ERROR)"
says unlisted-failure "          or: Connection closed"
says unlisted-failure "         got: Error: unexpected EOF"
says unlisted-failure "h2spec plain: 1 case failed or was skipped, and plain.txt does not list it with that outcome"

# An error of one line is not what h2spec expected and got, but what went
# wrong.
report pass pass error pass
verdict one-line-error
exits one-line-error 1
says one-line-error "    No HEADER frame received"

# A case listed with the issue that fixes it may fail, and the run lists it
# with its issue and reason.
report pass pass fail pass
list "http2/3.5/2  #150  The TLS port does not serve HTTP/2 yet."
verdict listed-failure
exits listed-failure 0
says listed-failure "h2spec plain: listed in plain.txt, with the reason:"
says listed-failure "  http2/3.5/2 failed, listed until #150: The TLS port does not serve HTTP/2 yet."
says listed-failure "h2spec plain: every case passed or is listed"

# A listed case that passes is reported, so that it can come off the list,
# but does not fail the run. On GitHub Actions, it is also a notice on its
# line of the list.
report pass pass pass pass
list "generic/1/1  #147  Not yet." "http2/3.5/2  #150  The TLS port does not serve HTTP/2 yet."
verdict listed-pass
exits listed-pass 0
says listed-pass "  http2/3.5/2 passed, listed until #150: The TLS port does not serve HTTP/2 yet."
says listed-pass "h2spec plain: 2 listed cases passed, so they can come off plain.txt: generic/1/1 http2/3.5/2"
says listed-pass "h2spec plain: every case passed or is listed"
verdict listed-pass-on-github github
says listed-pass-on-github "::notice file=$tmp/plain.txt,line=3,title=h2spec plain::http2/3.5/2 passes now, so it can come off the list"

# --- Cases that h2spec skips -------------------------------------------------

# A case that h2spec skips needs a reason on the list too.
report pass pass pass skip
list
verdict unlisted-skip
exits unlisted-skip 1
says unlisted-skip "h2spec plain: 4 cases, 3 passed, 1 skipped, 0 failed"
says unlisted-skip "h2spec plain: http2/6.9.1/1 skipped, and is not listed: Sends SETTINGS frame to set the initial window size to 1 and sends HEADERS frame"

list "http2/6.9.1/1  skipped  The Stub answers with an empty body."
verdict listed-skip
exits listed-skip 0
says listed-skip "  http2/6.9.1/1 skipped, listed as skipped: The Stub answers with an empty body."
says listed-skip "h2spec plain: every case passed or is listed"

# A listed case must have the outcome it is listed with.
list "http2/6.9.1/1  #147  Not yet."
verdict skip-listed-as-failing
exits skip-listed-as-failing 1
says skip-listed-as-failing "h2spec plain: http2/6.9.1/1 skipped, but is listed until #147: Sends SETTINGS frame to set the initial window size to 1 and sends HEADERS frame"

report pass pass fail pass
list "http2/3.5/2  skipped  The Stub answers with an empty body."
verdict failure-listed-as-skipped
exits failure-listed-as-skipped 1
says failure-listed-as-skipped "h2spec plain: http2/3.5/2 failed, but is listed as skipped: Sends invalid connection preface"
says failure-listed-as-skipped "         got: Error: unexpected EOF"

# --- Cases left out ----------------------------------------------------------

# A case left out runs, but its outcome does not count, unless it passes:
# then it is reported, as any listed case that passes is.
list "http2/3.5/2  left-out  On the plain port, octets that are not the preface are HTTP/1.1."
verdict left-out-failure
exits left-out-failure 0
says left-out-failure "  http2/3.5/2 failed, listed as left out: On the plain port, octets that are not the preface are HTTP/1.1."
says left-out-failure "h2spec plain: every case passed or is listed"

report pass pass skip pass
verdict left-out-skip
exits left-out-skip 0
says left-out-skip "  http2/3.5/2 skipped, listed as left out: On the plain port, octets that are not the preface are HTTP/1.1."

report pass pass pass pass
verdict left-out-pass
exits left-out-pass 0
says left-out-pass "h2spec plain: 1 listed case passed, so it can come off plain.txt: http2/3.5/2"

# --- A list or a report that does not fit ------------------------------------

# A listed case that h2spec did not run is out of date, as after an
# upgrade of h2spec that numbers its cases differently.
list "http2/9.9/1  #147  Gone."
verdict stale-entry
exits stale-entry 1
says stale-entry "h2spec plain: http2/9.9/1 is listed in plain.txt, but h2spec ran no such case"
says stale-entry "h2spec plain: 1 listed case did not run, so plain.txt is out of date"

list "http2/3.5/2  later  Some day."
verdict unknown-why
exits unknown-why 2
says unknown-why "h2spec plain: plain.txt:2: http2/3.5/2 is listed as 'later', not as skipped, left-out or #<issue>"

list "http2/3.5/2  #150"
verdict no-reason
exits no-reason 2
says no-reason "h2spec plain: plain.txt:2: give the case, why it is listed, and the reason"

list "http2/3.5/2  #150  One reason." "http2/3.5/2  #147  Another."
verdict listed-twice
exits listed-twice 2
says listed-twice "h2spec plain: plain.txt:3: http2/3.5/2 is listed twice"

list
rm "$tmp/report.xml"
verdict no-report
exits no-report 2
mentions no-report "h2spec plain: cannot read the report $tmp/report.xml:"

printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites></testsuites>\n' >"$tmp/report.xml"
verdict empty-report
exits empty-report 1
says empty-report "h2spec plain: the report holds no case: h2spec ran none"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
