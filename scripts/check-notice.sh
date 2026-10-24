#!/bin/sh
# Checks that NOTICE names the MoonBit toolchain in .moonbit-version, as
# moonc v<version>, and every MoonBit module the build resolves: those that
# moon.mod imports, those that the workspace's other modules import, and
# those that these import in turn, of any owner, as
# scripts/resolved-modules.sh --json lists them. For each, NOTICE must have
# a section titled with its name (scripts/notice.jq reads it), with:
#
# - a line "Version <version>." with the version the build resolves;
# - a line "Licence: <licence>" with the licence that the module's own
#   module file declares;
# - a line "Source: <URL>" with the repository that its module file names,
#   if it names one;
# - the words "smock compiles nothing from it" when the smock binary is
#   built from none of its packages, and not otherwise.
#
# NOTICE may name no module that the build does not resolve. CI runs it on
# every push (build-test.yml), and the release workflow before it builds
# the binaries it publishes. scripts/test-dependency-checks.sh tests it. It
# needs moon, with the registry index updated (moon update), and jq.
#
# usage: scripts/check-notice.sh
set -eu
cd "$(dirname "$0")/.."

modules=$(scripts/resolved-modules.sh --json)

# What disagrees, one line each.
problems=$(jq -nr -L scripts --rawfile notice NOTICE --argjson modules "$modules" \
  --arg toolchain "$(cat .moonbit-version)" '
  include "notice";
  def shown: map(if . == "" then "(its root package)" else . end) | join(", ");
  ($notice | notice_toolchain) as $named
  | ($notice | notice_module_titles) as $titles
  | (if $named == $toolchain then empty
     else "NOTICE names the toolchain moonc v\($named), but .moonbit-version says \($toolchain)" end),
    ($modules[] as $module
     | if ($titles | index($module.name)) == null then
         "NOTICE has no section \($module.name), which the build resolves at version \($module.version)"
       else
         ($notice | notice_module($module.name)) as $entry
         | (if $entry.version == $module.version then empty
            elif $entry.version == null then
              "NOTICE gives \($module.name) no version, but the build resolves \($module.version)"
            else "NOTICE gives \($module.name) the version \($entry.version), but the build resolves \($module.version)"
            end),
           (if $module.licence == "" then "the module file of \($module.name) declares no licence"
            elif $entry.licence == $module.licence then empty
            else "NOTICE gives \($module.name) the licence \($entry.licence), but its module file \($module.licence)"
            end),
           (if $entry.source == null then "NOTICE gives \($module.name) no line Source: <URL>"
            elif $module.repository == "" or $entry.source == $module.repository then empty
            else "NOTICE gives \($module.name) the source \($entry.source), but its module file the repository \($module.repository)"
            end),
           (if $entry.compiled == $module.compiled then empty
            elif $module.compiled then
              "NOTICE says that smock compiles nothing from \($module.name), but the binary is built from its packages \($module.packages | shown)"
            else
              "NOTICE does not say that smock compiles nothing from \($module.name), but the binary reaches none of its packages"
            end)
       end),
    ($titles[] | select(. as $title | all($modules[]; .name != $title))
     | "NOTICE has a section \(.), but the build does not resolve it")
') || {
  echo "check-notice: cannot check NOTICE" >&2
  exit 1
}

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed 's|^|check-notice: |' >&2
  exit 1
fi
echo "check-notice: NOTICE names moonc v$(cat .moonbit-version) and each module the build resolves:" \
  "$(printf '%s' "$modules" | jq -r '
    [.[] | "\(.name)@\(.version)" + (if .compiled then "" else " (compiled from nothing)" end)] | join(", ")')"
