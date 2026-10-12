#!/bin/sh
# Checks that the protocol modules stay independent of smock and of I/O, so
# they can be published on mooncakes on their own:
#
# - their moon.mod imports no other module;
# - their packages import only their own module and moonbitlang/core
#   (except moonbitlang/core/env, which reads the process environment);
# - they declare no FFI (no extern functions, no native stubs);
# - none of their packages leaves out wasm-gc, so CI tests all of them there.
#
# A new protocol module is added to the list below.
set -eu
cd "$(dirname "$0")/.."

modules="http1 re2 yaml"

# Prints every quoted string inside the import blocks of a moon.mod or moon.pkg.
imports() {
  awk '
    /^[[:space:]]*import[[:space:]]*\{/ { inside = 1 }
    inside {
      line = $0
      sub(/\}.*/, "", line)
      while (match(line, /"[^"]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
    inside && /\}/ { inside = 0 }
  ' "$1"
}

failed=0
fail() {
  echo "check-protocol-modules: $*" >&2
  failed=1
}

for module in $modules; do
  [ -f "$module/moon.mod" ] || { fail "$module/moon.mod is missing"; continue; }

  for dep in $(imports "$module/moon.mod"); do
    fail "$module/moon.mod imports the module $dep"
  done

  for pkg in $(find "$module" -name moon.pkg -not -path '*/_build/*' | sort); do
    for dep in $(imports "$pkg"); do
      case $dep in
      "smock/$module" | "smock/$module"/*) ;;
      moonbitlang/core/env) fail "$pkg imports $dep, which reads the process environment" ;;
      moonbitlang/core/*) ;;
      *) fail "$pkg imports $dep" ;;
      esac
    done
    if grep -q 'supported_targets' "$pkg" && ! grep -q 'supported_targets.*wasm-gc' "$pkg"; then
      fail "$pkg leaves out wasm-gc in supported_targets"
    fi
    if grep -q 'native-stub' "$pkg"; then
      fail "$pkg declares a native stub"
    fi
  done

  if grep -q 'supported_targets' "$module/moon.mod" && ! grep -q 'supported_targets.*wasm-gc' "$module/moon.mod"; then
    fail "$module/moon.mod leaves out wasm-gc in supported_targets"
  fi

  for src in $(find "$module" -name '*.mbt' -not -path '*/_build/*' | sort); do
    if grep -nE '^[[:space:]]*(pub[^ ]* )?extern[[:space:]]' "$src" >/dev/null; then
      fail "$src declares an extern (FFI) function"
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-protocol-modules: $modules are independent of smock and of I/O"
