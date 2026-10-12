#!/bin/sh
# Builds the native release binary at dist/smock with fresh build information.
#
# SMOCK_VERSION and SMOCK_COMMIT override the version and the commit that
# `smock --version` and the startup log entry report (see
# buildinfo/gen_build_info.sh).
set -eu
cd "$(dirname "$0")/.."

# moon regenerates the build information only when the file is missing.
rm -f buildinfo/build_info.mbt
moon build --target native --release
mkdir -p dist
install -m 755 _build/native/release/build/smock/smock/cmd/smock/smock.exe dist/smock
