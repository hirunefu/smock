#!/bin/sh
# Installs a MoonBit toolchain into $MOON_HOME (default ~/.moon) with the
# official installer. CI uses it; running it locally replaces your toolchain.
#
# usage: scripts/install-moonbit.sh [pinned|latest]
#   pinned  exactly the version in .moonbit-version (the default)
#   latest  the latest stable release
set -eu
cd "$(dirname "$0")/.."

channel=${1:-pinned}
case $channel in
pinned) version=$(cat .moonbit-version) ;;
latest) version=latest ;;
*)
  echo "usage: $0 [pinned|latest]" >&2
  exit 2
  ;;
esac

installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl -fsSL https://cli.moonbitlang.com/install/unix.sh -o "$installer"
bash "$installer" "$version"

bin=${MOON_HOME:-$HOME/.moon}/bin
moonc_version=$("$bin/moonc" -v)
installed=$(echo "$moonc_version" | cut -d' ' -f1)
echo "install-moonbit: installed moonc $installed ($channel)"
if [ "$channel" = pinned ] && [ "$installed" != "v$version" ]; then
  echo "install-moonbit: expected moonc v$version from .moonbit-version" >&2
  exit 1
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bin" >>"$GITHUB_PATH"
fi
