#!/bin/sh
# Checks the C boundary of ADR 0001: smock is MoonBit, and C comes only with
# the exceptions the ADR lists (OpenSSL for TLS, one setsockopt function for
# the reset Fault). Each C source those bring is added to `allowed` below,
# each MoonBit file that binds C functions to `bindings`, and each C library
# linked to `libraries`.
set -eu
cd "$(dirname "$0")/.."

# Paths of C sources ADR 0001 allows, one per line.
allowed="openssl/openssl.c
server/reset.c"

# The C source of the reset Fault, which ADR 0001 allows one function.
reset=server/reset.c

# MoonBit files that bind C functions directly (extern "C"), each with how
# many bindings it may hold, "*" for any: the OpenSSL bindings and the reset
# Fault's function. A binding anywhere else fails, so that no call into C
# goes unnoticed.
bindings="openssl/openssl.mbt *
openssl/client.mbt *
server/reset.mbt 1"

# The C libraries linked, sorted, one per line: OpenSSL's two. prebuild.py
# names them for moon, because link flags in a library's own moon.pkg do not
# reach the packages that import it.
libraries="crypto
ssl"

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

linked=$(grep -o '"link_libs": *\[[^]]*\]' prebuild.py | sed 's/^"link_libs"//' |
  grep -o '"[^"]*"' | tr -d '"' | sort -u)
if [ "$linked" != "$libraries" ]; then
  echo "check-no-c: prebuild.py links $(printf "%s" "$linked" | tr "\n" " "); ADR 0001 allows $(printf "%s" "$libraries" | tr "\n" " ")" >&2
  failed=1
fi
if grep -o '"link_flags": *"[^"]*"' prebuild.py | grep -qE '[" ]-l'; then
  echo "check-no-c: prebuild.py links a library through link_flags; name it in link_libs" >&2
  failed=1
fi
for manifest in $(git ls-files --cached --others --exclude-standard 'moon.pkg' '*/moon.pkg' 'moon.mod' '*/moon.mod'); do
  if grep -qE 'link-flags.*[" ]-l' "$manifest"; then
    echo "check-no-c: $manifest links a library, which ADR 0001 does not allow" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-no-c: no C beyond what ADR 0001 allows"
