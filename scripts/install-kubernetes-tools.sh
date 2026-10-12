#!/bin/sh
# Installs pinned versions of helm, kubectl and kind for linux/amd64 or
# linux/arm64, checked against pinned SHA-256 digests, into a directory
# (default: ~/.local/bin). On GitHub Actions it also adds the directory to
# the PATH of later steps. CI uses them to test the Helm chart
# (scripts/test-helm-chart.sh, scripts/test-helm-chart-on-kind.sh) and the
# release workflow to package and push it.
#
# usage: scripts/install-kubernetes-tools.sh [<directory>] [<tool>...]
#   tools: helm, kubectl, kind (default: all three)
set -eu

helm_version=v4.3.0
kubectl_version=v1.37.1
kind_version=v0.33.0

case $(uname -m) in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*)
  echo "install-kubernetes-tools: unsupported machine $(uname -m)" >&2
  exit 1
  ;;
esac

# digest <tool>: the SHA-256 of the download for this architecture, as each
# project publishes it next to the download.
digest() {
  case $1-$arch in
  helm-amd64) echo 86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb ;;
  helm-arm64) echo 31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08 ;;
  kubectl-amd64) echo 65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8 ;;
  kubectl-arm64) echo ff749f4b78d9c4f1ec87307df9b50119ed819e2094aa9810cb9acffc3286c8c7 ;;
  kind-amd64) echo aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d ;;
  kind-arm64) echo 20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2 ;;
  esac
}

directory=${1:-$HOME/.local/bin}
[ "$#" -gt 0 ] && shift
[ "$#" -gt 0 ] || set -- helm kubectl kind
mkdir -p "$directory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch <tool> <url>: downloads <url> to $tmp/<tool> and checks its digest.
fetch() {
  curl -fsSL --retry 3 -o "$tmp/$1" "$2"
  echo "$(digest "$1")  $tmp/$1" | sha256sum --check --quiet
}

for tool in "$@"; do
  case $tool in
  helm)
    fetch helm "https://get.helm.sh/helm-$helm_version-linux-$arch.tar.gz"
    tar -xzf "$tmp/helm" -C "$tmp" "linux-$arch/helm"
    install -m 755 "$tmp/linux-$arch/helm" "$directory/helm"
    ;;
  kubectl)
    fetch kubectl "https://dl.k8s.io/release/$kubectl_version/bin/linux/$arch/kubectl"
    install -m 755 "$tmp/kubectl" "$directory/kubectl"
    ;;
  kind)
    fetch kind "https://github.com/kubernetes-sigs/kind/releases/download/$kind_version/kind-linux-$arch"
    install -m 755 "$tmp/kind" "$directory/kind"
    ;;
  *)
    echo "install-kubernetes-tools: unknown tool $tool" >&2
    exit 2
    ;;
  esac
  echo "install-kubernetes-tools: installed $tool into $directory"
done

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$directory" >>"$GITHUB_PATH"
fi
