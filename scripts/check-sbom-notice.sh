#!/bin/sh
# Checks that an SPDX SBOM of the smock image and NOTICE agree on the
# software that comes with the MoonBit toolchain and that it links into
# smock: the native runtime, mimalloc and simdutf (scripts/notice.jq reads
# what NOTICE says about them). For each, NOTICE must have its section, and
# the SBOM one package of that name:
#
# - with the licence NOTICE gives as its declared licence;
# - with the version NOTICE gives: the toolchain's that NOTICE names for the
#   runtime, the one in its section for the others, or NOASSERTION when the
#   section gives none;
# - which smock (SPDXRef-Package-smock) links statically.
#
# scripts/add-smock-to-sbom.sh makes the SBOM so. CI runs this check on the
# SBOM it makes of the image (build-test.yml), and the release workflow on
# each architecture's SBOM before attesting it. scripts/test-sbom.sh tests
# it. It needs jq.
#
# usage: scripts/check-sbom-notice.sh <sbom.spdx.json> [NOTICE]
#   NOTICE is the repository's by default.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <sbom.spdx.json> [NOTICE]" >&2
  exit 2
fi
sbom=$1
root=$(cd "$(dirname "$0")/.." && pwd)
notice=${2:-$root/NOTICE}

# What disagrees, one line each.
problems=$(jq -r -L "$root/scripts" --rawfile notice "$notice" '
  include "notice";
  . as $sbom
  | ($notice | notice_toolchain) as $toolchain
  | $notice | notice_parts[]
  | . as $part
  | [$sbom.packages[] | select(.name == $part.name)] as $packages
  | if $packages == [] then "the SBOM has no package \(.name), which NOTICE names"
    elif ($packages | length) > 1 then "the SBOM has \($packages | length) packages \(.name), not one"
    else
      $packages[0] as $package
      | (if $package.licenseDeclared == .licence then empty
         else "NOTICE gives \(.name) the licence \(.licence), the SBOM \($package.licenseDeclared)" end),
        (sbom_version($toolchain) as $version
         | if $package.versionInfo == $version then empty
           else "NOTICE gives \(.name) the version \($version), the SBOM \($package.versionInfo)" end),
        (if any($sbom.relationships[]; .spdxElementId == "SPDXRef-Package-smock"
                and .relatedSpdxElement == $package.SPDXID and .relationshipType == "STATIC_LINK") then empty
         else "smock does not link \(.name) statically in the SBOM" end)
    end
' "$sbom") || {
  echo "check-sbom-notice: cannot check $sbom against $notice" >&2
  exit 1
}

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-sbom-notice: $sbom: |" >&2
  exit 1
fi
echo "check-sbom-notice: $sbom lists the runtime, mimalloc and simdutf as NOTICE names them"
