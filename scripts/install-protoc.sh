#!/bin/sh
# Installs the pinned protoc, the protobuf compiler that builds the protobuf
# fixtures (scripts/gen-protobuf-fixtures.sh, fixtures/protobuf/README.md),
# for linux/amd64 or linux/arm64 (this machine's architecture by default),
# checked against its pinned SHA-256 digest, under a prefix (default:
# ~/.local): protoc into <prefix>/bin, and the well-known types that come
# with it into <prefix>/include, where protoc finds them. On GitHub Actions
# it also adds <prefix>/bin to the PATH of later steps. CI and contributors
# use it alike. smock itself never runs protoc, and the image does not hold
# it.
#
# It needs curl, sha256sum and unzip.
#
# usage: scripts/install-protoc.sh [<prefix> [amd64 | arm64]]
set -eu

# scripts/gen-protobuf-fixtures.sh reads this line: the committed fixtures
# are what this version builds.
version=36.2

case $(uname -m) in
x86_64) machine=amd64 ;;
aarch64 | arm64) machine=arm64 ;;
*) machine="" ;;
esac
arch=${2:-$machine}
case $arch in
amd64 | arm64) ;;
"")
  echo "install-protoc: unsupported machine $(uname -m): give the architecture, amd64 or arm64" >&2
  exit 1
  ;;
*)
  echo "install-protoc: unsupported architecture $arch: amd64 or arm64" >&2
  exit 2
  ;;
esac

# The release asset of each architecture, and its SHA-256, as GitHub lists
# it with the release and as the release's tool_integrity.bzl pins it.
case $arch in
amd64)
  asset=protoc-$version-linux-x86_64.zip
  digest=121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278
  ;;
arm64)
  asset=protoc-$version-linux-aarch_64.zip
  digest=8b8f18bd2b30346efbc698dd5a73dd7c805f3ef8380f6dfc95c768f3f1852f6a
  ;;
esac

prefix=${1:-$HOME/.local}
mkdir -p "$prefix"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/protoc.zip" \
  "https://github.com/protocolbuffers/protobuf/releases/download/v$version/$asset"
echo "$digest  $tmp/protoc.zip" | sha256sum --check --quiet
unzip -q -o "$tmp/protoc.zip" 'bin/protoc' 'include/*' -d "$prefix"
chmod 755 "$prefix/bin/protoc"
if [ "$arch" = "$machine" ]; then
  installed=$("$prefix/bin/protoc" --version)
  if [ "$installed" != "libprotoc $version" ]; then
    echo "install-protoc: $prefix/bin/protoc says $installed, not libprotoc $version" >&2
    exit 1
  fi
  echo "install-protoc: installed $installed into $prefix/bin, with its well-known types in $prefix/include"
else
  echo "install-protoc: installed protoc $version for linux/$arch, which this machine cannot run, into $prefix/bin"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$prefix/bin" >>"$GITHUB_PATH"
fi
