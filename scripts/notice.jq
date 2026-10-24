# Reads what NOTICE says about the software that comes with the MoonBit
# toolchain and that the toolchain links into smock: the native runtime,
# mimalloc and simdutf. scripts/add-smock-to-sbom.sh adds them to the
# image's SBOM as NOTICE names them, and scripts/check-sbom-notice.sh checks
# that the SBOM and NOTICE agree on them. It also reads what NOTICE says
# about the MoonBit modules the build resolves, which scripts/check-notice.sh
# checks against the build, and scripts/check-sbom-notice.sh against the
# SBOM. Each function takes NOTICE's text (jq --rawfile).

# The titles of NOTICE's sections for that software. Whatever the toolchain
# stops shipping leaves NOTICE and this list together.
def toolchain_parts: ["The MoonBit native runtime", "mimalloc", "simdutf"];

# The part that has no version of its own: it has the toolchain's.
def runtime: "The MoonBit native runtime";

# The version of the toolchain that NOTICE names as moonc v<version>.
def notice_toolchain:
  [match("moonc v([0-9][0-9A-Za-z.+-]*[0-9A-Za-z])"; "g").captures[0].string] | unique
  | if length == 1 then .[0]
    else error("NOTICE should name one MoonBit toolchain, as moonc v<version>, not \(length)") end;

# The SPDX identifier of a licence as NOTICE names it.
def spdx_licence:
  . as $name
  | {"Apache License, Version 2.0": "Apache-2.0", "MIT License": "MIT"}[$name]
    // error("NOTICE names the licence \($name), which scripts/notice.jq has no SPDX identifier for");

# The indexes in $lines, NOTICE's lines, of the titles of its sections:
# each title is a line with a line of dashes under it.
def title_indexes($lines):
  [range(0; ($lines | length) - 1) | select($lines[.] != "" and ($lines[. + 1] | test("^-+$")))];

# The titles of NOTICE's sections.
def notice_titles: split("\n") as $lines | [title_indexes($lines)[] | $lines[.]];

# The lines of the section of NOTICE with the title $title, below the line
# of dashes under the title, up to the next section.
def notice_section($title):
  split("\n") as $lines
  | title_indexes($lines) as $titles
  | [$titles[] | select($lines[.] == $title)] as $found
  | if ($found | length) != 1 then error("NOTICE should have one section \($title), not \($found | length)") else . end
  | ([$titles[] | select(. > $found[0])] | first // ($lines | length)) as $end
  | $lines[$found[0] + 2:$end];

# What NOTICE says about the part $title: its name, its licence as an SPDX
# identifier, from the section's line "Licence: <licence>", and its
# version, from a line "Version <version>", or null when the section gives
# none.
def notice_part($title):
  notice_section($title) as $section
  | [$section[] | capture("^Licence: (?<licence>.+)$").licence] as $licences
  | if ($licences | length) != 1 then error("NOTICE's section \($title) should have one line Licence: <licence>")
    else . end
  | {name: $title,
     licence: ($licences[0] | spdx_licence),
     version: ([$section[] | capture("^Version (?<version>[^ ,]+)").version | sub("[.]$"; "")] | first)};

# Every part, as notice_part gives it.
def notice_parts: . as $notice | [toolchain_parts[] as $title | $notice | notice_part($title)];

# The MoonBit standard library, which has a section of its own but no
# version: it comes with the toolchain, and the build resolves it from
# there.
def standard_library: "moonbitlang/core";

# The titles of the sections for the MoonBit modules the build resolves:
# every title of the form <owner>/<name>, but the standard library's.
def notice_module_titles:
  [notice_titles[] | select(test("^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$") and . != standard_library)];

# What a module's section says, in its words, when the module is one that
# the build resolves but that smock's binary is built from none of.
def compiled_from_nothing: "smock compiles nothing from it";

# What NOTICE says about the module $name, as notice_part gives it, with
# its source, from the line "Source: <URL>" (null when there is none), and
# whether smock is compiled from it: false when the section says
# compiled_from_nothing, which may run over two lines.
def notice_module($name):
  notice_section($name) as $section
  | notice_part($name)
    + {source: ([$section[] | capture("^Source: +(?<source>[^ ]+)$").source] | first),
       compiled: ($section | join(" ") | gsub("\\s+"; " ") | contains(compiled_from_nothing) | not)};

# Every module NOTICE names, as notice_module gives it.
def notice_modules: . as $notice | [notice_module_titles[] as $name | $notice | notice_module($name)];

# The version a part, as notice_part gives it, has in the SBOM: $toolchain
# for the runtime, else the version NOTICE gives, else NOASSERTION, as SPDX
# says when nothing records it.
def sbom_version($toolchain):
  if .name == runtime then $toolchain else .version // "NOASSERTION" end;
