# Making a release

A release publishes the image `ghcr.io/hirunefu/smock:<version>`, the Helm
chart `oci://ghcr.io/hirunefu/charts/smock` with version `<version>`, and a
GitHub release with the binaries `smock-<version>-linux-amd64` and
`smock-<version>-linux-arm64`, their SBOMs, `LICENSE` and `NOTICE`. The
README's
[Container image and release binaries](../README.md#container-image-and-release-binaries)
says how people use them. This page is for the maintainer who makes one.

## What a tag does

Pushing a tag `v<major>.<minor>.<patch>` (or
`v<major>.<minor>.<patch>-<pre-release>`) runs
`.github/workflows/release.yml`. On an amd64 and an arm64 runner, each
building for its own architecture without emulation, it builds smock with
the toolchain in `.moonbit-version`, builds the image and runs
`scripts/smoke-test-image.sh` on it. Only then does it push, combine, sign
and attest the image, verify it with `scripts/verify-image.sh`, push and
sign the Helm chart packaged by `scripts/package-helm-chart.sh`, verify it
with `scripts/verify-chart.sh`, and create the GitHub release with notes
from `scripts/release-notes.sh`. It never runs on pull requests. Started
by hand from the Actions tab, it builds and smoke-tests everything and
keeps the binaries, images, chart and notes as workflow artifacts, but
publishes nothing. `scripts/check-release-workflow.sh`, run in CI, checks
those rules.

The tag names the version. Keep the `version` in `moon.mod` the same.

## Smoke-testing the image locally

To smoke-test the image on your machine (needs docker, curl, openssl,
readelf and jq):

```sh
scripts/build-release.sh
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev "$(git rev-parse --short=12 HEAD)" "moonc $(moonc -v | cut -d' ' -f1)"
```

It runs the image as its own UID with a read-only root filesystem, no
capabilities and no privilege escalation, and checks `smock --version`, a
Stub on the plain port, HTTPS with a test certificate, and the Admin API
status operation with a token file, which must name the same build as
`smock --version`. Then, without certificate files, it checks HTTPS with
the self-signed certificate smock generates, on the same read-only root
filesystem. It also checks that the image adds nothing to its base but
the smock binary, `LICENSE` and `NOTICE`, and that the image is for the
machine it runs on.

## The first release

The first release also makes the repository and its packages public.
Work through these steps in order:

1. **Run Release by hand on `main`** from the Actions tab. It publishes
   nothing, and covers the build, the smoke test and the chart on both
   architectures.
2. **Check that no stale package is in the way.** No ghcr package `smock`
   or `charts/smock` may exist yet without a link to this repository. Reading
   packages needs the `read:packages` scope (`gh auth refresh -s read:packages`):

   ```sh
   gh api /users/hirunefu/packages/container/smock
   gh api /users/hirunefu/packages/container/charts%2Fsmock
   ```

   Each should answer 404, or name `hirunefu/smock` as its repository.
3. **Make the repository public, before any tag.** Each keyless
   signature's certificate records whether the repository is private, and
   the public Rekor transparency log keeps it for good, so a tag pushed
   while private would leave "private" there. It would also create the
   packages private, and the links in the release notes would answer 404.
   Then, under Settings → Security, turn on private vulnerability
   reporting, which [SECURITY.md](../SECURITY.md) tells reporters to use.
4. **Publish the JSON Schema.** In the repository settings, under Pages,
   set Source to GitHub Actions, then run `.github/workflows/schema-pages.yml`
   by hand. Going public does not start it, and the Schema's `$id`
   answers 404 until it has run.
5. **Add a tag ruleset for `v*`**, so that the tags that publish a release
   are protected. Rulesets answer 403 while the repository is private.
6. **Tag `v0.1.0-rc.1` first.** It is a pre-release, and it runs the
   publishing path of the release workflow for the first time.
7. **Make both packages public**, `ghcr.io/hirunefu/smock` and
   `ghcr.io/hirunefu/charts/smock`, in their package settings. GitHub
   creates them private, and making a package public cannot be undone.
   Then, from a machine that is not logged in to GitHub or ghcr.io, check
   that `docker pull ghcr.io/hirunefu/smock:0.1.0-rc.1`,
   `helm show chart oci://ghcr.io/hirunefu/charts/smock --version 0.1.0-rc.1`
   and the README's `cosign verify` work.
8. **Tag `v0.1.0`**, the version `moon.mod` gives.
9. **Run `.github/workflows/latest-toolchain.yml` and
   `.github/workflows/benchmark.yml` by hand once.** Neither had run before
   the first release.

## Every release after

Check that CI is green on `main` and that `moon.mod` gives the new
version.

In [CHANGELOG.md](../CHANGELOG.md), move the entries under
`## [Unreleased]` to a new section `## [<version>] - <date>` below it,
leave `## [Unreleased]` empty, and update the links at the end. The
release notes include that section under "Changes".
`scripts/release-notes.sh` fails the release workflow, before anything is
built, when a tag that is not a pre-release has no section of its own. A
pre-release tag, such as `v<version>-rc.1`, takes its own section if there
is one, else the section of `<version>`, else `Unreleased`.

When `.moonbit-version` or the imports in `moon.mod` changed since the
last release, check that [NOTICE](../NOTICE) still names what the binary
holds, with the right versions. The release workflow fails when NOTICE
does not name the toolchain or a module of `moon.mod` with its version;
the runtime, mimalloc and simdutf come with the toolchain and are checked
by hand.

Then push the tag `v<version>`. A pre-release tag, such as
`v<version>-rc.1`, tries the publishing path first. The packages stay
public, so nothing else needs doing in their settings.
