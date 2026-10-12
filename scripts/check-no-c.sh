#!/bin/sh
# Checks the C boundary of ADR 0001: smock is MoonBit, and C comes only with
# the exceptions the ADR lists (OpenSSL for TLS, one setsockopt function for
# the reset Fault). Each C source those bring is added to `allowed` below.
set -eu
cd "$(dirname "$0")/.."

# Paths of C sources ADR 0001 allows, one per line.
allowed="openssl/openssl.c
server/reset.c"

# The C source of the reset Fault, which ADR 0001 allows one function.
reset=server/reset.c

failed=0
for file in $(git ls-files --cached --others --exclude-standard \
  '*.c' '*.h' '*.cc' '*.cpp' '*.cxx' '*.hh' '*.hpp' '*.m' '*.s' '*.S'); do
  if ! printf '%s\n' "$allowed" | grep -qxF "$file"; then
    echo "check-no-c: $file is C, which ADR 0001 does not allow" >&2
    failed=1
  fi
done

if [ -e "$reset" ]; then
  functions=$(grep -c 'MOONBIT_FFI_EXPORT' "$reset" || true)
  if [ "$functions" -ne 1 ]; then
    echo "check-no-c: $reset has $functions exported functions; ADR 0001 allows one" >&2
    failed=1
  fi
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-no-c: no C beyond what ADR 0001 allows"
