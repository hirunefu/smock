#!/bin/sh
# Checks the C boundary of ADR 0001: smock is MoonBit, and C comes only with
# the exceptions the ADR lists (OpenSSL for TLS, one setsockopt function for
# the reset Fault). Each C source those bring is added to `allowed` below,
# and each MoonBit file that binds C functions to `bindings`.
set -eu
cd "$(dirname "$0")/.."

# Paths of C sources ADR 0001 allows, one per line.
allowed="openssl/openssl.c
server/reset.c"

# The C source of the reset Fault, which ADR 0001 allows one function.
reset=server/reset.c

# MoonBit files that bind C functions directly (extern "C"), each with how
# many bindings it may hold, "*" for any: the OpenSSL bindings, the reset
# Fault's function, and libc's exit, which cmd/smock binds because neither
# core nor moonbitlang/async exposes an exit with a status. A binding
# anywhere else fails, so that no call into C goes unnoticed.
bindings="openssl/openssl.mbt *
openssl/client.mbt *
server/reset.mbt 1
cmd/smock/main.mbt 1"

failed=0
for file in $(git ls-files --cached --others --exclude-standard \
  '*.c' '*.h' '*.cc' '*.cpp' '*.cxx' '*.hh' '*.hpp' '*.m' '*.s' '*.S'); do
  if ! printf '%s\n' "$allowed" | grep -qxF "$file"; then
    echo "check-no-c: $file is C, which ADR 0001 does not allow" >&2
    failed=1
  fi
done

for file in $(git ls-files --cached --others --exclude-standard '*.mbt'); do
  count=$(grep -ci 'extern "c"' "$file" || true)
  if [ "$count" -eq 0 ]; then
    continue
  fi
  limit=$(printf '%s\n' "$bindings" | awk -v file="$file" '$1 == file { print $2 }')
  if [ -z "$limit" ]; then
    echo "check-no-c: $file binds C functions (extern \"C\"), which ADR 0001 does not allow" >&2
    failed=1
  elif [ "$limit" != "*" ] && [ "$count" -gt "$limit" ]; then
    echo "check-no-c: $file has $count C bindings; $limit allowed" >&2
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
