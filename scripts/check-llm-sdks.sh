#!/bin/sh
# Runs the SDK job (llm-sdks/README.md): reads smock's LLM responses with
# the official SDKs, as CI does after it builds and tests smock.
#
# It installs the SDKs pinned in llm-sdks/requirements.txt, and every
# package they need, into a new virtual environment, each checked against
# its pinned hashes and only from a wheel, so nothing is built. Then
# llm-sdks/check.py serves llm-sdks/definitions/ with the given binary,
# calls it through the SDKs and checks what they read.
#
# It runs with the Python that $PYTHON names, python3 by default. CI sets
# up the version pinned in llm-sdks/.python-version; another version gets
# a note, not a failure.
#
# usage: scripts/check-llm-sdks.sh <smock binary>
#   such as dist/smock, which scripts/build-release.sh writes.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <smock binary>" >&2
  exit 2
fi
case $1 in
/*) smock=$1 ;;
*) smock=$PWD/$1 ;;
esac
if [ ! -x "$smock" ] || [ -d "$smock" ]; then
  echo "check-llm-sdks: $1 is not an executable file" >&2
  exit 2
fi
cd "$(dirname "$0")/.."

python=${PYTHON:-python3}
pinned=$(cat llm-sdks/.python-version)
version=$("$python" -c 'import platform; print(platform.python_version())')
if [ "$version" != "$pinned" ]; then
  echo "check-llm-sdks: note: Python $version, not the pinned $pinned (llm-sdks/.python-version)" >&2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$python" -m venv "$tmp/venv"
# --isolated: no pip configuration or PIP_ variable picks another index.
# --require-hashes also fails when a package that one of them needs is not
# pinned.
"$tmp/venv/bin/python" -m pip install --isolated --disable-pip-version-check --no-input --quiet \
  --require-hashes --only-binary :all: --requirement llm-sdks/requirements.txt

"$tmp/venv/bin/python" llm-sdks/check.py "$smock"
