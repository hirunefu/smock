#!/bin/sh
# Adds smock itself to the SPDX SBOM that syft makes of a smock image. syft
# lists the packages of the distroless base, but it knows no MoonBit binary,
# so without this the SBOM would leave out the main component. It adds:
#
# - the package smock (the binary /usr/local/bin/smock), with the release's
#   version, the commit it was built from and the MoonBit toolchain, as a
#   package of the image the SBOM describes;
# - smock's own modules that its moon.mod imports, with the version it
#   names, and moonbitlang/core, the standard library of the toolchain in
#   .moonbit-version: all are compiled into the binary, so smock links them
#   statically;
# - every module the build resolves from outside this workspace, of any
#   owner and transitive ones included, as scripts/resolved-modules.sh
#   --json lists them in the modules file: with the version the build
#   resolves and the licence that the module's own module file declares.
#   smock links a module statically when the binary is built from any of
#   its packages. A module that the build resolves but compiles nothing
#   from is not in the binary: smock depends on it (DEPENDS_ON), and its
#   comment says so;
# - the native runtime, mimalloc and simdutf, which come with the toolchain
#   and which it links into smock statically, with the names and licences
#   NOTICE gives them (scripts/notice.jq reads NOTICE). The runtime has the
#   toolchain's version, mimalloc the one NOTICE gives, and simdutf, whose
#   version nothing records, NOASSERTION;
# - smock's dynamic link to the base's OpenSSL package (libssl3).
#
# The release workflow runs it on each architecture's SBOM before attesting
# it, with the modules file its build of that architecture wrote, and CI on
# the SBOM of the image it builds. scripts/check-sbom-notice.sh checks that
# the SBOM and NOTICE agree, and scripts/verify-image.sh that the published
# SBOMs have smock. It needs jq, but not moon: the modules file holds what
# it needs of the build.
#
# usage: scripts/add-smock-to-sbom.sh <sbom.spdx.json> <version> <commit> <modules.json>
#   Rewrites the SBOM in place. <commit> is the full commit hash.
#   <modules.json> is what scripts/resolved-modules.sh --json printed for
#   the same commit.
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <sbom.spdx.json> <version> <commit> <modules.json>" >&2
  exit 2
fi
sbom=$1
version=$2
commit=$3
resolved=$4
root=$(cd "$(dirname "$0")/.." && pwd)
repository=https://github.com/hirunefu/smock

# The "<name>@<version>" strings of the import block of a moon.mod.
imports() {
  awk '
    /^[[:space:]]*import[[:space:]]*\{/ { inside = 1 }
    inside {
      line = $0
      sub(/\}.*/, "", line)
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
    inside && /\}/ { inside = 0 }
  ' "$1"
}

# The licence a moon.mod declares, or nothing.
licence() {
  sed -n 's/^[[:space:]]*license[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
}

toolchain=$(cat "$root/.moonbit-version")

# The modules compiled into smock, one JSON object per line. The smock/
# modules are the workspace members of this repository, built from the same
# commit. Every other module that moon.mod imports must be among those the
# build resolves.
lines=$(mktemp)
trap 'rm -f "$lines" "$sbom.tmp"' EXIT
for import in $(imports "$root/moon.mod"); do
  name=${import%@*}
  case $name in
  smock/*)
    dir=${name#smock/}
    if [ ! -f "$root/$dir/moon.mod" ]; then
      echo "add-smock-to-sbom: the module $name has no $dir/moon.mod" >&2
      exit 1
    fi
    jq -nc --arg name "$name" --arg version "${import##*@}" --arg licence "$(licence "$root/$dir/moon.mod")" \
      --arg download "git+$repository.git@$commit#$dir" '{$name, $version, $licence, $download}' >>"$lines"
    ;;
  *)
    if ! jq -e --arg name "$name" 'any(.[]; .name == $name)' "$resolved" >/dev/null; then
      echo "add-smock-to-sbom: $resolved does not list $name, which moon.mod imports;" \
        "make it with scripts/resolved-modules.sh --json" >&2
      exit 1
    fi
    ;;
  esac
done
jq -nc --arg version "$toolchain" '{name: "moonbitlang/core", $version, licence: "", download: "NOASSERTION"}' >>"$lines"
modules=$(jq -sc . "$lines")

jq -L "$root/scripts" --rawfile notice "$root/NOTICE" --arg version "$version" --arg commit "$commit" \
  --arg toolchain "moonc v$toolchain" --arg toolchain_version "$toolchain" --arg licence "$(licence "$root/moon.mod")" \
  --arg repository "$repository" --argjson modules "$modules" --slurpfile resolved "$resolved" '
  include "notice";
  def package($id; $name; $version; $licence; $download):
    {name: $name, SPDXID: $id, versionInfo: $version, supplier: "NOASSERTION",
     downloadLocation: $download, filesAnalyzed: false, licenseConcluded: "NOASSERTION",
     licenseDeclared: (if $licence == "" then "NOASSERTION" else $licence end),
     copyrightText: "NOASSERTION"};
  def module_id: "SPDXRef-Package-moonbit-" + (.name | gsub("[^A-Za-z0-9.]"; "-"));
  ($notice | notice_parts) as $parts
  | [.relationships[] | select(.spdxElementId == "SPDXRef-DOCUMENT" and .relationshipType == "DESCRIBES")
   | .relatedSpdxElement] as $described
  | if ($described | length) != 1 then error("the SBOM does not describe exactly one package") else . end
  | if any(.packages[]; .SPDXID == "SPDXRef-Package-smock") then error("the SBOM has smock already") else . end
  | [.packages[] | select(.name | test("^libssl3")) | .SPDXID] as $openssl
  | if $openssl == [] then error("the SBOM has no OpenSSL package (libssl3)") else . end
  | .packages += [
      package("SPDXRef-Package-smock"; "smock"; $version; $licence; "git+\($repository).git@\($commit)")
      + {primaryPackagePurpose: "APPLICATION",
         homepage: $repository,
         comment: "The smock binary, /usr/local/bin/smock, built from commit \($commit) with the MoonBit toolchain \($toolchain).",
         externalRefs: [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
                         referenceLocator: "pkg:github/hirunefu/smock@v\($version)"}]}
    ] + [$modules[], ($resolved[0][] | select(.compiled) | .download = "NOASSERTION")
         | package(module_id; .name; .version; .licence; .download)
         + {primaryPackagePurpose: "LIBRARY", comment: "A MoonBit module compiled into smock."}]
    + [$resolved[0][] | select(.compiled | not) | package(module_id; .name; .version; .licence; "NOASSERTION")
         + {primaryPackagePurpose: "LIBRARY",
            comment: "A MoonBit module that the build resolves, because another module imports it, but that smock compiles nothing from, so it is not in the binary."}]
    + [$parts[] | package(module_id; .name; sbom_version($toolchain_version); .licence; "NOASSERTION")
         + {primaryPackagePurpose: "LIBRARY",
            comment: "Part of the MoonBit toolchain \($toolchain), which links it into smock."}]
  | .relationships += [{spdxElementId: $described[0], relatedSpdxElement: "SPDXRef-Package-smock",
                        relationshipType: "CONTAINS"}]
      + [$modules[], ($resolved[0][] | select(.compiled)), $parts[]
         | {spdxElementId: "SPDXRef-Package-smock", relatedSpdxElement: module_id, relationshipType: "STATIC_LINK"}]
      + [$resolved[0][] | select(.compiled | not)
         | {spdxElementId: "SPDXRef-Package-smock", relatedSpdxElement: module_id, relationshipType: "DEPENDS_ON"}]
      + [$openssl[] | {spdxElementId: "SPDXRef-Package-smock", relatedSpdxElement: .,
                       relationshipType: "DYNAMIC_LINK"}]
' "$sbom" >"$sbom.tmp"
mv "$sbom.tmp" "$sbom"
echo "add-smock-to-sbom: $sbom has smock $version, the" \
  "$(jq --argjson own "$modules" '($own | length) + ([.[] | select(.compiled)] | length)' "$resolved")" \
  "MoonBit modules compiled into it, the $(jq '[.[] | select(.compiled | not)] | length' "$resolved")" \
  "it depends on but compiles nothing from, and the runtime, mimalloc and simdutf of the toolchain in it"
