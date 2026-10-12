#!/bin/sh
# Installs the pinned oha, the benchmark's load generator, for linux/amd64
# or linux/arm64, checked against its pinned SHA-256 digest, into a
# directory (default: ~/.local/bin). On GitHub Actions it also adds the
# directory to the PATH of later steps. bench/plan.json names the same
# version.
#
# usage: scripts/install-oha.sh [<directory>]
set -eu

version=1.16.0

case $(uname -m) in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
  echo "install-oha: unsupported machine $(uname -m)" >&2
  exit 1
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
echo "install-oha: installed $("$directory/oha" --version) into $directory"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
