#!/bin/sh
# Checks that `smock --version` names the version, the commit and the MoonBit
# toolchain the binary was built with, and exits 0.
#
# usage: scripts/check-version.sh <smock binary> <version> <commit> <toolchain>
# example: scripts/check-version.sh dist/smock 0.0.0-dev 0123456789ab "moonc v0.10.17+d971670cd"
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <smock binary> <version> <commit> <toolchain>" >&2
  exit 2
fi
bin=$1 version=$2 commit=$3 toolchain=$4

for value in "$version" "$commit" "$toolchain"; do
  if [ -z "$value" ]; then
    echo "check-version: an expected value is empty" >&2
    exit 2
  fi
done

out=$("$bin" --version)
expected="smock $version (commit $commit, $toolchain)"
echo "$out"
if [ "$out" != "$expected" ]; then
  echo "check-version: expected: $expected" >&2
  exit 1
fi
