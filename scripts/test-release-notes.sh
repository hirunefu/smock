#!/bin/sh
# Tests of the release notes (scripts/release-notes.sh). Each test runs the
# script, as the release workflow does, and checks the Markdown it prints.
# The first tests put a test CHANGELOG.md next to a copy of the script and
# check how the links it copies from it come out. The last tests render the
# notes of Unreleased and of each released version from the repository's
# own CHANGELOG.md and check that no relative link is left in them.
#
# usage: scripts/test-release-notes.sh
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# notes <script> <name> <version>: runs <script> for <version> into
# $tmp/<name>.md.
notes() {
  if ! "$1" "$3" 0123456789ab "moonc v0.0.0" ghcr.io/hirunefu/smock >"$tmp/$2.md" 2>"$tmp/$2.err"; then
    fail "$2: the script failed: $(cat "$tmp/$2.err")"
  fi
}

# has_line <name> <description> <line>: the notes <name> have <line>.
has_line() {
  if grep -qxF -- "$3" "$tmp/$1.md"; then
    pass "$1: $2"
  else
    fail "$1: $2"
    echo "     no line: $3"
  fi
}

# --- Links in the CHANGELOG -------------------------------------------------

# The notes copy the section from a CHANGELOG.md next to the script's
# directory.
mkdir -p "$tmp/repo/scripts"
cp scripts/release-notes.sh "$tmp/repo/scripts/"
cat >"$tmp/repo/CHANGELOG.md" <<'MARKDOWN'
# Changelog

## [Unreleased]

## [1.2.0] - 2026-10-23

### Added

- A relative link: [the guide](docs/guide.md).
- A relative link with a fragment: [its limits](docs/guide.md#limits).
- An absolute link: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
- An in-page link: [the binaries](#binaries).
- A link from the site's root: [the issues](/hirunefu/smock/issues).
- Two links on a line: [one](docs/one.md) and [two](docs/two.md).

[Unreleased]: https://github.com/hirunefu/smock/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/hirunefu/smock/releases/tag/v1.2.0
MARKDOWN

notes "$tmp/repo/scripts/release-notes.sh" links 1.2.0
has_line links "a relative link leads to the file at the release's tag" \
  '- A relative link: [the guide](https://github.com/hirunefu/smock/blob/v1.2.0/docs/guide.md).'
has_line links "a relative link with a fragment keeps it" \
  '- A relative link with a fragment: [its limits](https://github.com/hirunefu/smock/blob/v1.2.0/docs/guide.md#limits).'
has_line links "an absolute link stays as it is" \
  '- An absolute link: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).'
has_line links "an in-page link stays as it is" \
  '- An in-page link: [the binaries](#binaries).'
has_line links "a link from the site's root stays as it is" \
  "- A link from the site's root: [the issues](/hirunefu/smock/issues)."
has_line links "both relative links of a line lead to the tag" \
  '- Two links on a line: [one](https://github.com/hirunefu/smock/blob/v1.2.0/docs/one.md) and [two](https://github.com/hirunefu/smock/blob/v1.2.0/docs/two.md).'

# --- The repository's CHANGELOG ---------------------------------------------

# relative_links <name>: prints the targets of the Markdown links in the
# notes <name> that are relative: with no scheme, and not to a place on the
# page (#) or from the site's root (/).
relative_links() {
  grep -oE '[]][(][^ )]+' "$tmp/$1.md" | cut -c3- | grep -vE '^([A-Za-z][A-Za-z0-9+.-]*:|#|/)' || true
}

# no_relative_links <name>: the notes <name> have no relative link.
no_relative_links() {
  links=$(relative_links "$1")
  if [ -z "$links" ]; then
    pass "$1: no relative link"
  else
    fail "$1: relative links:"
    printf '%s\n' "$links" | sed 's/^/     /'
  fi
}

# A run by hand gets a development version, a pre-release whose notes take
# the Unreleased section.
notes scripts/release-notes.sh unreleased 0.0.0-dev.1
no_relative_links unreleased
sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md >"$tmp/versions"
while read -r version; do
  notes scripts/release-notes.sh "$version" "$version"
  no_relative_links "$version"
done <"$tmp/versions"

echo
echo "test-release-notes: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
