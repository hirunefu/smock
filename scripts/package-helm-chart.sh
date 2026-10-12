#!/bin/sh
# Packages the Helm chart (charts/smock) for a release. The chart's version
# and its app version are both the release's version, so the chart runs the
# image of its own release, ghcr.io/hirunefu/smock:<version>, by default. The
# release workflow (.github/workflows/release.yml) pushes the package to
# oci://ghcr.io/hirunefu/charts.
#
# It needs helm (v3.8 or later, or v4).
#
# usage: scripts/package-helm-chart.sh <version> [<directory>]
#   writes <directory>/smock-<version>.tgz (dist/ by default)
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <version> [<directory>]" >&2
  exit 2
fi
version=$1 directory=${2:-dist}

mkdir -p "$directory"
helm lint --strict charts/smock --set adminAuth.tokenSecret.name=smock-admin-token
helm package charts/smock --version "$version" --app-version "$version" --destination "$directory"
