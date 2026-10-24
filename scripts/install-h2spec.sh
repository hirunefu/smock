#!/bin/sh
# Installs the pinned h2spec, the HTTP/2 conformance tool that
# scripts/check-h2spec.sh runs, into a directory (default: ~/.local/bin).
# On GitHub Actions it also adds the directory to the PATH of later steps.
#
# h2spec publishes a Linux binary for amd64 only. On linux/amd64, this
# installs that binary, checked against its pinned SHA-256 digest. On
# linux/arm64, such as a developer's machine, it builds h2spec from its tag,
# checked against the tag's pinned commit, with a pinned Go, checked against
# its pinned SHA-256 digest; Go checks the modules h2spec needs against
# h2spec's go.sum. Either way, `h2spec --version` names the version and the
# commit. Nothing is left behind but h2spec, and nothing is configured.
#
# It needs curl, tar and sha256sum, and git on arm64.
#
# usage: scripts/install-h2spec.sh [<directory>]
set -eu

version=2.6.0
# The commit that h2spec's tag v2.6.0 names.
commit=70ac2294010887f48b18e2d64f5cccd48421fad1
# The SHA-256 of the release asset h2spec_linux_amd64.tar.gz. GitHub lists
# no digest for an asset of 2020; this is the asset's, which other
# projects pin too.
amd64_digest=157ee0de702e01ad40e752dbf074b366027e550c8e7504f9450da2809e279318
# The Go that builds h2spec on arm64, and the SHA-256 of its archive, as
# https://go.dev/dl/ lists it.
go_version=1.27.3
go_arm64_digest=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49

case $(uname -m) in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
  echo "install-h2spec: unsupported machine $(uname -m)" >&2
  exit 1
  ;;
esac

directory=${1:-$HOME/.local/bin}
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch <file> <url> <digest>: downloads <url> to $tmp/<file> and checks its
# SHA-256 digest.
fetch() {
  curl -fsSL --retry 3 -o "$tmp/$1" "$2"
  echo "$3  $tmp/$1" | sha256sum --check --quiet
}

case $arch in
amd64)
  fetch h2spec.tar.gz "https://github.com/summerwind/h2spec/releases/download/v$version/h2spec_linux_amd64.tar.gz" "$amd64_digest"
  tar -xzf "$tmp/h2spec.tar.gz" -C "$tmp" h2spec
  how="the release binary"
  ;;
arm64)
  fetch go.tar.gz "https://go.dev/dl/go$go_version.linux-arm64.tar.gz" "$go_arm64_digest"
  tar -xzf "$tmp/go.tar.gz" -C "$tmp"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$version" \
    https://github.com/summerwind/h2spec.git "$tmp/source"
  tagged=$(git -C "$tmp/source" rev-parse HEAD)
  if [ "$tagged" != "$commit" ]; then
    echo "install-h2spec: the tag v$version names $tagged, not $commit" >&2
    exit 1
  fi
  # Everything Go writes stays in $tmp, and nothing from this machine's Go
  # setup applies: no go env file, no other toolchain, no private module
  # settings, and the modules come from the public proxy and checksum
  # database. -modcacherw lets the module cache be removed with $tmp.
  (
    cd "$tmp/source"
    env GOENV=off GOTOOLCHAIN=local GOFLAGS="-mod=readonly -modcacherw" CGO_ENABLED=0 \
      GOPATH="$tmp/gopath" GOMODCACHE="$tmp/gopath/pkg/mod" GOCACHE="$tmp/gocache" \
      GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org \
      GOPRIVATE= GONOPROXY= GONOSUMDB= GOINSECURE= \
      "$tmp/go/bin/go" build -trimpath -ldflags "-X main.VERSION=$version -X main.COMMIT=$commit" \
      -o "$tmp/h2spec" ./cmd/h2spec
  )
  how="built from its tag with Go $go_version"
  ;;
esac

install -m 755 "$tmp/h2spec" "$directory/h2spec"
echo "install-h2spec: installed h2spec into $directory, $how: $("$directory/h2spec" --version)"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
