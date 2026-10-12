#!/bin/sh
# Runs the tests of the OpenSSL bindings (openssl/) under AddressSanitizer
# and LeakSanitizer, which fail them on any memory error or leak in the C
# stub or in what it asks OpenSSL to allocate.
#
# It compiles with a wrapper around the system C compiler that adds the
# sanitizer flags (MOON_CC takes a path, not flags), into a build directory
# of its own, so it changes no tracked file and no toolchain file.
#
# usage: scripts/test-openssl-asan.sh
set -eu
cd "$(dirname "$0")/.."

cc=$(command -v cc || command -v gcc)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/cc" <<EOF
#!/bin/sh
exec "$cc" -g -fsanitize=address -fno-omit-frame-pointer "\$@"
EOF
chmod +x "$work/cc"

ASAN_OPTIONS=detect_leaks=1:abort_on_error=0:fast_unwind_on_malloc=0 \
  MOON_CC="$work/cc" MOON_AR="$(command -v ar)" \
  moon test --target native -p smock/smock/openssl --target-dir _build/asan "$@"
