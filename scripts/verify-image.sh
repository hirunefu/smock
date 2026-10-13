#!/bin/sh
# Verifies a published smock image the way the README tells its users to.
# The release workflow runs it right after publishing. It checks that:
#
# - the image is one multi-architecture image for linux/amd64 and linux/arm64;
# - cosign verifies the signature of the image and of each architecture;
# - each architecture has a signed SPDX SBOM attestation that lists smock
#   with the version, the MoonBit modules compiled into it, and the OpenSSL
#   package of the base.
#
# It needs docker (with buildx), cosign and jq.
#
# usage: scripts/verify-image.sh <image>:<version> [cosign verification flags...]
#   The flags say whose signatures to accept. By default they are those of
#   the README: keyless signatures made by the release workflow for the tag
#   v<version>. To try the script on a local registry, sign with a key and
#   pass, for example, --key cosign.pub --insecure-ignore-tlog.
set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <image>:<version> [cosign verification flags...]" >&2
  exit 2
fi
image=$1
shift
repository=${image%:*}
version=${image##*:}
if [ "$#" -eq 0 ]; then
  set -- \
    --certificate-identity "https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v$version" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
fi

fail() {
  echo "verify-image: $*" >&2
  exit 1
}

cosign verify "$@" "$image" >/dev/null || fail "cosign cannot verify the signature of $image"
echo "verify-image: $image is signed"

index=$(docker buildx imagetools inspect --raw "$image")
for platform in linux/amd64 linux/arm64; do
  digest=$(echo "$index" | jq -r --arg os "${platform%/*}" --arg arch "${platform#*/}" \
    '.manifests[]? | select(.platform.os == $os and .platform.architecture == $arch) | .digest')
  [ -n "$digest" ] || fail "$image has no $platform image"

  cosign verify "$@" "$repository@$digest" >/dev/null ||
    fail "cosign cannot verify the signature of the $platform image"
  echo "verify-image: the $platform image $digest is signed"

  # The attestation's payload is an in-toto statement whose predicate is the
  # SPDX document.
  cosign verify-attestation "$@" --type spdxjson "$repository@$digest" 2>/dev/null |
    jq -r '.payload' | base64 -d | jq -e --arg version "$version" '
      .predicate.spdxVersion != null
      and any(.predicate.packages[];
        .name == "smock" and .versionInfo == $version and .primaryPackagePurpose == "APPLICATION")
      and any(.predicate.packages[]; .name == "moonbitlang/async")
      and any(.predicate.packages[]; .name | startswith("libssl3"))' >/dev/null ||
    fail "the $platform image has no verified SPDX SBOM that lists smock $version, its MoonBit modules and OpenSSL"
  echo "verify-image: the $platform image has a signed SPDX SBOM"
done
