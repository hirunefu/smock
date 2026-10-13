#!/bin/sh
# Builds the native release binary at dist/smock with fresh build information.
#
# SMOCK_VERSION and SMOCK_COMMIT override the version and the commit that
# `smock --version` and the startup log entry report (see
# buildinfo/gen_build_info.sh).
set -eu
cd "$(dirname "$0")/.."

# prebuild.py brings the build information up to date first.
moon build --target native --release
mkdir -p dist
install -m 755 _build/native/release/build/smock/smock/cmd/smock/smock.exe dist/smock
