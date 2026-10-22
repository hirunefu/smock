# Reads what NOTICE says about the software that comes with the MoonBit
# toolchain and that the toolchain links into smock: the native runtime,
# mimalloc and simdutf. scripts/add-smock-to-sbom.sh adds them to the
# image's SBOM as NOTICE names them, and scripts/check-sbom-notice.sh checks
# that the SBOM and NOTICE agree on them. Each function takes NOTICE's text
# (jq --rawfile).

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

# The lines of the section of NOTICE with the title $title, below the line
# of dashes under the title, up to the next section.
def notice_section($title):
  split("\n") as $lines
  | [range(0; ($lines | length) - 1) | select($lines[.] != "" and ($lines[. + 1] | test("^-+$")))] as $titles
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

# The version a part, as notice_part gives it, has in the SBOM: $toolchain
# for the runtime, else the version NOTICE gives, else NOASSERTION, as SPDX
# says when nothing records it.
def sbom_version($toolchain):
  if .name == runtime then $toolchain else .version // "NOASSERTION" end;
