#!/bin/sh
# Verifies a published smock Helm chart the way the README tells its users
# to: cosign verifies the signature of the chart's OCI artifact. The release
# workflow runs it right after it pushes and signs the chart.
#
# It needs cosign.
#
# usage: scripts/verify-chart.sh <chart>:<version> [cosign verification flags...]
#   The chart is named without oci://, as in ghcr.io/hirunefu/charts/smock:1.2.3.
#   The flags say whose signatures to accept. By default they are those of
#   the README: keyless signatures made by the release workflow for the tag
#   v<version>. To try the script on a local registry, sign with a key and
#   pass, for example, --key cosign.pub --insecure-ignore-tlog.
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <chart>:<version> [cosign verification flags...]" >&2
  exit 2
fi
chart=$1
shift
version=${chart##*:}
if [ "$#" -eq 0 ]; then
  set -- \
    --certificate-identity "https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v$version" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
fi

fail() {
  echo "verify-chart: $*" >&2
  exit 1
}

cosign verify "$@" "$chart" >/dev/null || fail "cosign cannot verify the signature of $chart"
echo "verify-chart: $chart is signed"
