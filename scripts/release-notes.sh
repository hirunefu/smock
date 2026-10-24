#!/bin/sh
# Prints the notes of a GitHub release in Markdown. They name the MoonBit
# toolchain the release was built with, carry the version's changes from
# CHANGELOG.md, say that the binaries need OpenSSL at run time, and point to
# LICENSE and NOTICE. The release workflow (.github/workflows/release.yml)
# uses them.
#
# The changes are the lines under the CHANGELOG.md heading
# "## [<version>]". A version that is not a pre-release must have them, or
# the script fails, so that no release goes out without its changes. A
# pre-release (<version>-<pre-release>, such as 0.2.0-rc.1, or the
# development version of a run by hand) takes its own section, else that of
# the version it leads up to, else "## [Unreleased]", else none.
#
# CHANGELOG.md links to files of the repository with relative links, which
# work where GitHub shows the file but not on the release page. The notes
# turn each into a link to the file at the release's tag.
#
# usage: scripts/release-notes.sh <version> <commit> <toolchain> <image>
# example: scripts/release-notes.sh 0.1.0 0123456789ab "moonc v0.10.17+d971670cd" ghcr.io/hirunefu/smock
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <version> <commit> <toolchain> <image>" >&2
  exit 2
fi
version=$1 commit=$2 toolchain=$3 image=$4
blob=https://github.com/hirunefu/smock/blob/v$version
readme=$blob/README.md
changelog=$(dirname "$0")/../CHANGELOG.md

if [ ! -f "$changelog" ]; then
  echo "release-notes: $changelog does not exist" >&2
  exit 1
fi

# Prints the section of CHANGELOG.md under the heading "## [$1]", which a
# date may follow: the lines up to the next such heading or the link
# definitions at the end, without blank lines at either end. Prints nothing
# when there is no such section.
section() {
  awk -v heading="## [$1]" '
    index($0, heading) == 1 && (length($0) == length(heading) || substr($0, length(heading) + 1, 1) == " ") {
      found = 1
      next
    }
    found && (/^## / || /^\[[^]]*\]: /) { exit }
    found { lines[++n] = $0 }
    END {
      first = 1
      while (first <= n && lines[first] == "") first++
      last = n
      while (last >= first && lines[last] == "") last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$changelog"
}

# Prints its input with each relative Markdown link, [text](<target>)
# whose target has no scheme and starts with neither "#" nor "/", turned
# into $blob/<target>: the file at the release's tag, with the target's
# fragment kept. Other links stay as they are.
tag_links() {
  awk -v blob="$blob" '
    {
      out = ""
      rest = $0
      while (match(rest, /[]][(][^ )]+/)) {
        target = substr(rest, RSTART + 2, RLENGTH - 2)
        if (target !~ /^([A-Za-z][A-Za-z0-9+.-]*:|#|\/)/) target = blob "/" target
        out = out substr(rest, 1, RSTART + 1) target
        rest = substr(rest, RSTART + RLENGTH)
      }
      print out rest
    }
  '
}

case $version in
*-*)
  changes=$(section "$version")
  [ -n "$changes" ] || changes=$(section "${version%%-*}")
  [ -n "$changes" ] || changes=$(section Unreleased)
  ;;
*)
  changes=$(section "$version")
  if [ -z "$changes" ]; then
    echo "release-notes: CHANGELOG.md has no section for $version. Move its changes from \"## [Unreleased]\" to \"## [$version] - <date>\" before tagging v$version (docs/releasing.md)." >&2
    exit 1
  fi
  ;;
esac

cat <<NOTES
smock $version, built from commit \`$commit\` with the MoonBit toolchain
\`$toolchain\`. \`smock --version\` prints the same line in the image and in
the binaries:

\`\`\`
smock $version (commit $commit, $toolchain)
\`\`\`
NOTES

if [ -n "$changes" ]; then
  printf '\n## Changes\n\n%s\n' "$changes" | tag_links
fi

cat <<NOTES

## Container image

\`$image:$version\`, for linux/amd64 and linux/arm64. It runs smock as UID
65532 on a read-only root filesystem. Each architecture is signed with cosign
and has an SPDX SBOM; [the README]($readme#verify-the-image) explains how to
verify the signature and fetch the SBOM.

## Helm chart

\`${image%/*}/charts/smock\`, version $version, published as an OCI chart. It
runs \`$image:$version\` by default:

\`\`\`sh
helm install smock oci://${image%/*}/charts/smock --version $version \\
  --set adminAuth.tokenSecret.name=<Secret with the Admin API token>
\`\`\`

[Its README]($blob/charts/smock/README.md)
lists its values. The chart is signed with cosign;
[smock's README]($readme#verify-the-helm-chart) explains how to verify
the signature.

## Binaries

- \`smock-$version-linux-amd64\`
- \`smock-$version-linux-arm64\`

They are the binaries in the image. They link OpenSSL 3 dynamically, so they
need OpenSSL 3 (\`libssl.so.3\` and \`libcrypto.so.3\`) and glibc 2.34 or later at run time:
on Debian and Ubuntu, the \`libssl3\` package (\`libssl3t64\` on newer
releases).

The SBOM of each image is attached as \`smock-$version-linux-<arch>.spdx.json\`.

## Licence

smock is licensed under the Apache License, Version 2.0 (\`LICENSE\`). The
binaries also link third-party software statically, and \`NOTICE\` names it
with its licences. Both files are attached, and the image holds them in
\`/usr/share/doc/smock/\`.
NOTES
