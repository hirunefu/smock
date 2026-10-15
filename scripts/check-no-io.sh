#!/bin/sh
# Checks that the code which decides a response stays free of I/O and builds
# for wasm-gc (spec #1, "I/O-independent engine"). CI's wasm-gc job skips any
# package that leaves out wasm-gc, so without this check such a package
# could opt out, or read the environment, unnoticed.
#
# The protocol modules also stay independent of smock, so they can be
# published on mooncakes on their own:
#
# - their moon.mod imports no other module;
# - their packages import only their own module and moonbitlang/core.
#
# The no-I/O packages of smock/smock import only the protocol modules,
# moonbitlang/core and each other.
#
# Both, in every import block (test imports included):
#
# - import no moonbitlang/core/env, which reads the process environment;
# - declare no FFI (no extern functions, no native stubs);
# - do not leave out wasm-gc in supported_targets, so CI tests them there.
#
# A new protocol module is added to `modules` below, and a new no-I/O package
# of smock/smock to `packages`.
set -eu
cd "$(dirname "$0")/.."

modules="http1 re2 yaml"

# The packages of smock/smock that decide a response, and the packages of
# smock/smock they import.
packages="definitions engine template prng log"

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
  echo "check-no-io: $*" >&2
  failed=1
}

# Fails a moon.mod or moon.pkg that leaves out wasm-gc or declares a native stub.
check_manifest() {
  if grep -q 'supported_targets' "$1" && ! grep -q 'supported_targets.*wasm-gc' "$1"; then
    fail "$1 leaves out wasm-gc in supported_targets"
  fi
  if grep -q 'native-stub' "$1"; then
    fail "$1 declares a native stub"
  fi
}

# Fails a MoonBit file that declares an extern function.
check_source() {
  if grep -nE '^[[:space:]]*(pub[^ ]* )?extern[[:space:]]' "$1" >/dev/null; then
    fail "$1 declares an extern (FFI) function"
  fi
}

for module in $modules; do
  [ -f "$module/moon.mod" ] || { fail "$module/moon.mod is missing"; continue; }

  for dep in $(imports "$module/moon.mod"); do
    fail "$module/moon.mod imports the module $dep"
  done
  check_manifest "$module/moon.mod"

  for pkg in $(find "$module" -name moon.pkg -not -path '*/_build/*' | sort); do
    for dep in $(imports "$pkg"); do
      case $dep in
      "smock/$module" | "smock/$module"/*) ;;
      moonbitlang/core/env) fail "$pkg imports $dep, which reads the process environment" ;;
      moonbitlang/core/*) ;;
      *) fail "$pkg imports $dep" ;;
      esac
    done
    check_manifest "$pkg"
  done

  for src in $(find "$module" -name '*.mbt' -not -path '*/_build/*' | sort); do
    check_source "$src"
  done
done

for package in $packages; do
  pkg="$package/moon.pkg"
  [ -f "$pkg" ] || { fail "$pkg is missing"; continue; }

  for dep in $(imports "$pkg"); do
    case $dep in
    moonbitlang/core/env) fail "$pkg imports $dep, which reads the process environment" ;;
    moonbitlang/core/*) ;;
    smock/http1 | smock/http1/* | smock/re2 | smock/re2/* | smock/yaml | smock/yaml/*) ;;
    smock/smock/*)
      case " $packages " in
      *" ${dep#smock/smock/} "*) ;;
      *) fail "$pkg imports $dep, which is not a no-I/O package" ;;
      esac
      ;;
    *) fail "$pkg imports $dep" ;;
    esac
  done
  check_manifest "$pkg"

  # Only the package's own files: a subdirectory with a moon.pkg is another
  # package.
  for src in $(find "$package" -maxdepth 1 -name '*.mbt' | sort); do
    check_source "$src"
  done
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-no-io: the protocol modules ($modules) are independent of smock and of I/O, and $packages do no I/O"
