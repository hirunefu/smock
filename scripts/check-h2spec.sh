#!/bin/sh
# Runs h2spec 2.6.0, the HTTP/2 conformance tool, against a smock binary,
# and judges each run against the port's list of cases that do not pass,
# scripts/h2spec/<port>.txt, with scripts/h2spec-verdict.py. Each run
# starts smock on free ports, serving scripts/h2spec/definitions, and runs
# every case of h2spec's three sections, generic, http2 and hpack, strict
# cases included, against one port:
#
# - plain: the plain port, HTTP/2 by prior knowledge (h2c).
# - tls: the TLS port, HTTP/2 by ALPN (h2), with the self-signed
#   certificate smock generates, which h2spec does not verify.
#
# It fails when a case fails or is skipped without being listed so, when a
# listed case did not run, or when smock stops during a run. It prints
# h2spec's output, then the verdict, which lists every listed case with its
# reason and names a listed case that passed, so that it can come off.
#
# CI runs it on linux/amd64 (.github/workflows/build-test.yml). It needs
# h2spec 2.6.0 on PATH (scripts/install-h2spec.sh installs it), python3
# and jq.
#
# usage: scripts/check-h2spec.sh <smock> [<port>...]
#   port: plain or tls (default: every port)
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <smock> [<port>...]" >&2
  exit 2
fi
smock=$1
shift
[ "$#" -gt 0 ] || set -- plain tls
for port in "$@"; do
  case $port in
  plain | tls) ;;
  *)
    echo "check-h2spec: unknown port $port, not plain or tls" >&2
    exit 2
    ;;
  esac
done

h2spec_version=2.6.0
version=$(h2spec --version 2>/dev/null || true)
case $version in
"Version: $h2spec_version "*) ;;
*)
  echo "check-h2spec: needs h2spec $h2spec_version on PATH, which scripts/install-h2spec.sh installs; found: ${version:-none}" >&2
  exit 1
  ;;
esac

tmp=$(mktemp -d)
pid=""
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# group <title> / endgroup: fold what is printed between them in the log
# of GitHub Actions.
group() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::group::$1"; else echo "--- $1"; fi
}
endgroup() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::endgroup::"; fi
}

# smock_log <port>: prints what smock logged during the run on <port>.
smock_log() {
  echo "check-h2spec: $1: smock logged:" >&2
  sed 's/^/    /' "$tmp/$1.log" >&2
}

failed=0
for port in "$@"; do
  # smock, on free ports, with no Admin API token: nothing else reaches it.
  # Without certificate files, the TLS port presents a self-signed
  # certificate.
  "$smock" serve --dir scripts/h2spec/definitions --port 0 --tls-port 0 --admin-port 0 \
    --admin-auth off 2>"$tmp/$port.log" &
  pid=$!

  # The port's number, from smock's listening entry. A line still being
  # written is not JSON yet, and is skipped.
  number=""
  tries=0
  while [ -z "$number" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      smock_log "$port"
      echo "check-h2spec: $port: smock stopped before it listened" >&2
      exit 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      smock_log "$port"
      echo "check-h2spec: $port: smock did not listen within 10 seconds" >&2
      exit 1
    fi
    sleep 0.1
    number=$(jq -rR --arg listener "$port" \
      'fromjson? | select(.msg == "listening" and .listener == $listener) | .address | sub(".*:"; "")' \
      "$tmp/$port.log")
  done

  # Over TLS, h2spec offers h2 by ALPN and does not verify the certificate.
  tls=""
  [ "$port" != tls ] || tls="--tls --insecure"
  group "h2spec $port: h2spec $h2spec_version against port $number"
  # shellcheck disable=SC2086 # $tls is empty or two flags.
  h2spec generic http2 hpack --strict $tls --host 127.0.0.1 --port "$number" \
    --junit-report "$tmp/$port.xml" || true
  endgroup

  if ! kill -0 "$pid" 2>/dev/null; then
    smock_log "$port"
    echo "check-h2spec: $port: smock stopped during the run" >&2
    exit 1
  fi
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  pid=""
  if [ "$status" -ne 0 ]; then
    smock_log "$port"
    echo "check-h2spec: $port: smock exited with $status after SIGTERM, not 0" >&2
    exit 1
  fi

  python3 scripts/h2spec-verdict.py "scripts/h2spec/$port.txt" "$tmp/$port.xml" || failed=1
done
exit "$failed"
