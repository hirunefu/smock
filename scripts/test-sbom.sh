#!/bin/sh
# Tests of scripts/add-smock-to-sbom.sh and scripts/check-sbom-notice.sh.
# They run on a small SBOM in the shape syft makes of the image, and on a
# small NOTICE that a test changes to disagree with the SBOM. The check
# must find each such disagreement about the software that comes with the
# MoonBit toolchain. A last test makes and checks the SBOM with this
# repository's NOTICE. CI makes and checks the real image's SBOM in
# build-test.yml.
#
# It needs jq.
#
# usage: scripts/test-sbom.sh
#
# shellcheck disable=SC2016 # jq filters are in single quotes on purpose
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# A repository with the scripts, a moon.mod that imports one module from
# mooncakes, a toolchain, and a NOTICE that names the toolchain and the
# software that comes with it.
fixture=$tmp/repo
mkdir -p "$fixture/scripts"
cp scripts/add-smock-to-sbom.sh scripts/check-sbom-notice.sh scripts/notice.jq "$fixture/scripts/"
cat >"$fixture/moon.mod" <<'EOF'
name = "smock/smock"

version = "1.0.0"

license = "Apache-2.0"

import {
  "moonbitlang/async@0.22.4",
}
EOF
echo '1.2.3+test' >"$fixture/.moonbit-version"
cat >"$fixture/NOTICE" <<'EOF'
smock
Copyright 2026 The smock authors


Third-party software in the smock binary
========================================

The smock binary is built with the MoonBit toolchain moonc v1.2.3+test,
which smock --version names.

- moonbitlang/async: Apache License, Version 2.0
- The MoonBit native runtime: Apache License, Version 2.0
- mimalloc: MIT License
- simdutf: MIT License


moonbitlang/async
-----------------

Version 0.22.4.

Licence: Apache License, Version 2.0


The MoonBit native runtime
--------------------------

The C runtime of MoonBit's native backend.

Source:  https://github.com/moonbitlang/moonbit-native-runtime
Licence: Apache License, Version 2.0


mimalloc
--------

Version 9.8.7, the memory allocator of MoonBit's native backend.

Source:  https://github.com/microsoft/mimalloc
Licence: MIT License


simdutf
-------

Unicode validation and conversion. The toolchain does not say which
version.

Source:  https://github.com/simdutf/simdutf
Licence: MIT License
EOF

# The image's SBOM as syft makes it: the image, which the document
# describes, and the base's OpenSSL.
cat >"$tmp/syft.spdx.json" <<'EOF'
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "smock",
  "documentNamespace": "https://anchore.com/syft/image/smock-test",
  "creationInfo": {"creators": ["Tool: syft-1.54.1"], "created": "2026-10-23T00:00:00Z"},
  "packages": [
    {"name": "libssl3t64", "SPDXID": "SPDXRef-Package-deb-libssl3t64-1", "versionInfo": "3.5.7-1~deb13u3",
     "supplier": "NOASSERTION", "downloadLocation": "NOASSERTION", "filesAnalyzed": false,
     "licenseConcluded": "NOASSERTION", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION"},
    {"name": "smock", "SPDXID": "SPDXRef-DocumentRoot-Image-smock", "versionInfo": "ci",
     "supplier": "NOASSERTION", "downloadLocation": "NOASSERTION", "filesAnalyzed": false,
     "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
     "primaryPackagePurpose": "CONTAINER"}
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relatedSpdxElement": "SPDXRef-DocumentRoot-Image-smock",
     "relationshipType": "DESCRIBES"}
  ]
}
EOF

# add <name> [repository]: runs the repository's add-smock-to-sbom.sh (the
# fixture's by default) on a copy of syft's SBOM, $tmp/<name>.spdx.json.
add() {
  cp "$tmp/syft.spdx.json" "$tmp/$1.spdx.json"
  if ! "${2:-$fixture}/scripts/add-smock-to-sbom.sh" "$tmp/$1.spdx.json" 1.0.0 0123456789abcdef \
    >/dev/null 2>"$tmp/$1.err"; then
    fail "$1: add-smock-to-sbom.sh failed: $(cat "$tmp/$1.err")"
  fi
}

# check <name> <description> <jq filter>: the filter, run on
# $tmp/<name>.spdx.json, must give true. It may use package($name), the
# SBOM's one package of that name, and static($name), whether smock links
# that package statically.
defs='
def package($name): [.packages[] | select(.name == $name)] | if length == 1 then .[0] else null end;
def static($name):
  package($name).SPDXID as $id
  | any(.relationships[]; .spdxElementId == "SPDXRef-Package-smock" and .relatedSpdxElement == $id
                          and .relationshipType == "STATIC_LINK");
'
check() {
  if jq -e "$defs $3" "$tmp/$1.spdx.json" >/dev/null 2>"$tmp/jq.err"; then
    pass "$1: $2"
  else
    fail "$1: $2"
    echo "     filter: $3"
    if [ -s "$tmp/jq.err" ]; then
      sed 's/^/     /' "$tmp/jq.err"
    fi
  fi
}

# variant <name> <sed script>: a copy of the fixture, $tmp/<name>, whose
# NOTICE the sed script changed.
variant() {
  cp -R "$fixture" "$tmp/$1"
  sed "$2" "$fixture/NOTICE" >"$tmp/$1/NOTICE"
}

add sbom
check sbom "mimalloc has the version NOTICE gives and the MIT licence" '
  package("mimalloc") | .versionInfo == "9.8.7" and .licenseDeclared == "MIT"'
check sbom "smock links mimalloc statically" 'static("mimalloc")'
check sbom "the runtime has the toolchain's version and the Apache licence" '
  package("The MoonBit native runtime") | .versionInfo == "1.2.3+test" and .licenseDeclared == "Apache-2.0"'
check sbom "smock links the runtime statically" 'static("The MoonBit native runtime")'
check sbom "simdutf, whose version NOTICE does not give, has none, and has the MIT licence" '
  package("simdutf") | .versionInfo == "NOASSERTION" and .licenseDeclared == "MIT"'
check sbom "smock links simdutf statically" 'static("simdutf")'
check sbom "their identifiers follow the SBOM's scheme, and every identifier is unique" '
  all(package("The MoonBit native runtime", "mimalloc", "simdutf"); .SPDXID | startswith("SPDXRef-Package-"))
  and ([.packages[].SPDXID] | length == (unique | length))'

# NOTICE must name each part of the toolchain the script adds.
variant no-simdutf '/^simdutf$/,$d'
cp "$tmp/syft.spdx.json" "$tmp/no-simdutf.spdx.json"
if "$tmp/no-simdutf/scripts/add-smock-to-sbom.sh" "$tmp/no-simdutf.spdx.json" 1.0.0 0123456789abcdef \
  >/dev/null 2>"$tmp/no-simdutf.err"; then
  fail "no-simdutf: add-smock-to-sbom.sh adds simdutf, which NOTICE does not name"
elif grep -q 'NOTICE should have one section simdutf' "$tmp/no-simdutf.err"; then
  pass "no-simdutf: add-smock-to-sbom.sh fails when NOTICE does not name simdutf"
else
  fail "no-simdutf: add-smock-to-sbom.sh fails, but not because NOTICE does not name simdutf: $(cat "$tmp/no-simdutf.err")"
fi

# accepts <description> <sbom name> <NOTICE>: check-sbom-notice.sh must
# accept $tmp/<sbom name>.spdx.json with that NOTICE.
accepts() {
  if "$fixture/scripts/check-sbom-notice.sh" "$tmp/$2.spdx.json" "$3" >/dev/null 2>"$tmp/check.err"; then
    pass "$2: $1"
  else
    fail "$2: $1: $(cat "$tmp/check.err")"
  fi
}

# rejects <description> <sbom name> <NOTICE> <message>: check-sbom-notice.sh
# must reject $tmp/<sbom name>.spdx.json with that NOTICE, and say <message>.
rejects() {
  if "$fixture/scripts/check-sbom-notice.sh" "$tmp/$2.spdx.json" "$3" >/dev/null 2>"$tmp/check.err"; then
    fail "$2: $1: the check accepts it"
  elif grep -qF "$4" "$tmp/check.err"; then
    pass "$2: $1"
  else
    fail "$2: $1: the check rejects it, but does not say \"$4\": $(cat "$tmp/check.err")"
  fi
}

# edit <name> <jq filter>: $tmp/<name>.spdx.json, the SBOM that the fixture
# makes, changed by the filter.
edit() {
  jq "$defs $2" "$tmp/sbom.spdx.json" >"$tmp/$1.spdx.json"
}

accepts "the check accepts the SBOM made with the same NOTICE" sbom "$fixture/NOTICE"

variant mimalloc-version 's/^Version 9\.8\.7,/Version 9.8.8,/'
rejects "the check finds that NOTICE gives mimalloc another version" sbom "$tmp/mimalloc-version/NOTICE" \
  'NOTICE gives mimalloc the version 9.8.8, the SBOM 9.8.7'

variant toolchain 's/moonc v1\.2\.3+test/moonc v1.2.4/'
rejects "the check finds that NOTICE names another toolchain than the runtime's version" sbom \
  "$tmp/toolchain/NOTICE" 'NOTICE gives The MoonBit native runtime the version 1.2.4, the SBOM 1.2.3+test'

variant simdutf-licence '/^simdutf$/,$s/^Licence: MIT License$/Licence: Apache License, Version 2.0/'
rejects "the check finds that NOTICE gives simdutf another licence" sbom "$tmp/simdutf-licence/NOTICE" \
  'NOTICE gives simdutf the licence Apache-2.0, the SBOM MIT'

rejects "the check finds that NOTICE does not name simdutf" sbom "$tmp/no-simdutf/NOTICE" \
  'NOTICE should have one section simdutf'

edit missing 'del(.packages[] | select(.name == "simdutf"))'
rejects "the check finds that the SBOM does not list simdutf" missing "$fixture/NOTICE" \
  'the SBOM has no package simdutf'

edit licence '(.packages[] | select(.name == "mimalloc") | .licenseDeclared) = "Apache-2.0"'
rejects "the check finds that the SBOM gives mimalloc another licence" licence "$fixture/NOTICE" \
  'NOTICE gives mimalloc the licence MIT, the SBOM Apache-2.0'

edit guess '(.packages[] | select(.name == "simdutf") | .versionInfo) = "5.0.0"'
rejects "the check finds that the SBOM gives simdutf a version that NOTICE does not give" guess "$fixture/NOTICE" \
  'NOTICE gives simdutf the version NOASSERTION, the SBOM 5.0.0'

edit unlinked 'package("The MoonBit native runtime").SPDXID as $id
  | del(.relationships[] | select(.relatedSpdxElement == $id))'
rejects "the check finds that smock does not link the runtime statically" unlinked "$fixture/NOTICE" \
  'smock does not link The MoonBit native runtime statically'

# This repository's NOTICE, toolchain and moon.mod.
add repository "$PWD"
check repository "mimalloc has a version from this NOTICE, and the runtime the toolchain's" '
  (package("mimalloc").versionInfo | test("^[0-9]+[.][0-9]+"))
  and package("The MoonBit native runtime").versionInfo == "'"$(cat .moonbit-version)"'"'
if scripts/check-sbom-notice.sh "$tmp/repository.spdx.json" >/dev/null 2>"$tmp/check.err"; then
  pass "repository: the check accepts the SBOM made with this NOTICE"
else
  fail "repository: the check rejects the SBOM made with this NOTICE: $(cat "$tmp/check.err")"
fi

echo
echo "test-sbom: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
