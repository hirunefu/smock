#!/bin/sh
# Checks the C boundary of ADR 0001: smock is MoonBit, and C comes only with
# the exceptions the ADR lists (OpenSSL for TLS, one setsockopt function for
# the reset Fault). Each C source those bring is added to `allowed` below,
# each MoonBit file that binds C functions to `bindings`, and each C library
# linked to `libraries`.
#
# It also scans the modules the build resolves from outside this workspace:
# moonhttp and the modules it imports (ADR 0005), which may bring no C at
# all. moon downloads them into .mooncakes/ as it checks or builds, so run
# this after moon check, as CI does. It needs moon and jq.
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

# The modules the build resolves, as scripts/resolved-modules.sh lists them:
# moonhttp and every module it imports, at the versions moon chose, so that
# a module an upgrade adds is scanned too. Each may bring no C source, no
# extern "C", no native stub, no C compiler or link flag, and no prebuild
# script, which could add link flags. moonbitlang's modules are left out:
# ADR 0001 already covers their C, such as moonbitlang/async's.
resolved=$(scripts/resolved-modules.sh)

# dependency <name>@<version> <what> <files>: fails each of the files, one a
# line, of that module.
dependency() {
  if [ -n "$3" ]; then
    printf '%s\n' "$3" | while IFS= read -r file; do
      echo "check-no-c: $1 $2 ${file#./}, which ADR 0001 does not allow" >&2
    done
    failed=1
  fi
}

# matching <regex> <name pattern>...: prints each file under the current
# directory whose name matches one of the patterns and whose text, without
# // comments, matches the extended regular expression, in any case.
matching() {
  regex=$1
  shift
  find . -type f | sort | while IFS= read -r file; do
    for pattern in "$@"; do
      # shellcheck disable=SC2254 # the pattern is a glob on purpose
      case ${file##*/} in
      $pattern)
        if sed 's|//.*||' "$file" | grep -qiE "$regex"; then
          echo "$file"
        fi
        break
        ;;
      esac
    done
  done
}

# The keys of the module and package files that give a C compiler, or its
# compile or link flags.
flags='(^|[^a-z0-9_-])"?(cc|cc-flags|cc-link-flags|stub-cc|stub-cc-flags|stub-cc-link-flags|link-flags)"?[[:space:]]*:'

scanned=""
for module in $resolved; do
  name=${module%@*}
  version=${module##*@}
  case $name in
  moonbitlang/*) continue ;;
  esac
  dir=.mooncakes/$name
  if [ ! -f "$dir/moon.mod" ] && [ ! -f "$dir/moon.mod.json" ]; then
    echo "check-no-c: $module is not in .mooncakes/; run moon check first, which downloads it" >&2
    failed=1
    continue
  fi
  held=$(sed -n 's/^[[:space:]]*"\{0,1\}version"\{0,1\}[[:space:]]*[=:][[:space:]]*"\([^"]*\)".*/\1/p' \
    "$dir"/moon.mod* | head -n 1)
  if [ "$held" != "$version" ]; then
    echo "check-no-c: $dir holds version $held, but the build resolves $version; run moon check first" >&2
    failed=1
    continue
  fi
  scanned="$scanned $module"
  dependency "$module" "has C source" "$(cd "$dir" && find . -type f \( -name '*.c' -o -name '*.h' \
    -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.hh' -o -name '*.hpp' -o -name '*.m' \
    -o -name '*.s' -o -name '*.S' \) | sort)"
  dependency "$module" 'binds C functions (extern "C") in' \
    "$(cd "$dir" && matching 'extern[[:space:]]*"c"' '*.mbt')"
  dependency "$module" "declares a native stub in" "$(cd "$dir" && matching 'native[-_]stub' 'moon.mod*' 'moon.pkg*')"
  dependency "$module" "sets a C compiler or link flag in" "$(cd "$dir" && matching "$flags" 'moon.mod*' 'moon.pkg*')"
  dependency "$module" "runs a prebuild script in" "$(cd "$dir" && matching 'prebuild' 'moon.mod*' 'moon.pkg*')"
done
echo "check-no-c: scanned the modules the build resolves outside moonbitlang:${scanned:- none}"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-no-c: no C beyond what ADR 0001 allows"
