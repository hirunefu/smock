#!/bin/sh
# Prints the notes of a GitHub release in Markdown. They name the MoonBit
# toolchain the release was built with and say that the binaries need
# OpenSSL at run time. The release workflow (.github/workflows/release.yml)
# uses them.
#
# usage: scripts/release-notes.sh <version> <commit> <toolchain> <image>
# example: scripts/release-notes.sh 0.1.0 0123456789ab "moonc v0.10.14+7d59c7ec9" ghcr.io/hirunefu/smock
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <version> <commit> <toolchain> <image>" >&2
  exit 2
fi
version=$1 commit=$2 toolchain=$3 image=$4
readme=https://github.com/hirunefu/smock/blob/v$version/README.md

cat <<NOTES
smock $version, built from commit \`$commit\` with the MoonBit toolchain
\`$toolchain\`. \`smock --version\` prints the same line in the image and in
the binaries:

\`\`\`
smock $version (commit $commit, $toolchain)
\`\`\`

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

[Its README](https://github.com/hirunefu/smock/blob/v$version/charts/smock/README.md)
lists its values.

## Binaries

- \`smock-$version-linux-amd64\`
- \`smock-$version-linux-arm64\`

They are the binaries in the image. They link OpenSSL 3 dynamically, so they
need OpenSSL 3 (\`libssl.so.3\` and \`libcrypto.so.3\`) and glibc at run time:
on Debian and Ubuntu, the \`libssl3\` package (\`libssl3t64\` on newer
releases).

The SBOM of each image is attached as \`smock-$version-linux-<arch>.spdx.json\`.
NOTES
