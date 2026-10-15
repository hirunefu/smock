#!/bin/sh
# Installs the pinned oha, the benchmark's load generator, for linux/amd64
# or linux/arm64 (this machine's architecture by default), checked against
# its pinned SHA-256 digest, into a directory (default: ~/.local/bin). On
# GitHub Actions it also adds the directory to the PATH of later steps.
# bench/plan.json names the same version. The GKE run
# (scripts/gke-bench.sh) installs the one of the nodes' architecture, which
# may not be this machine's, for the load generator's image.
#
# usage: scripts/install-oha.sh [<directory> [amd64 | arm64]]
set -eu

version=1.16.0

case $(uname -m) in
x86_64) machine=amd64 ;;
aarch64 | arm64) machine=arm64 ;;
*) machine="" ;;
esac
arch=${2:-$machine}
case $arch in
amd64 | arm64) ;;
"")
  echo "install-oha: unsupported machine $(uname -m): give the architecture, amd64 or arm64" >&2
  exit 1
  ;;
*)
  echo "install-oha: unsupported architecture $arch: amd64 or arm64" >&2
  exit 2
  ;;
esac

# The SHA-256 of each release asset, as GitHub lists it with the release.
case $arch in
amd64) digest=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716 ;;
arm64) digest=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39 ;;
esac

directory=${1:-$HOME/.local/bin}
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/oha" "https://github.com/hatoo/oha/releases/download/v$version/oha-linux-$arch"
echo "$digest  $tmp/oha" | sha256sum --check --quiet
install -m 755 "$tmp/oha" "$directory/oha"
if [ "$arch" = "$machine" ]; then
  echo "install-oha: installed $("$directory/oha" --version) into $directory"
else
  echo "install-oha: installed oha $version for linux/$arch, which this machine cannot run, into $directory"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
