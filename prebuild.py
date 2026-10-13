# moon runs this before every native build (see the prebuild option in
# moon.mod). Flags declared in a library's own moon.pkg do not reach its
# dependents, so the flags that every executable depending on a package
# needs, test executables included, live here:
#
# - OpenSSL is linked into every executable that depends on the bindings in
#   openssl/.
# - Every executable that holds the engine is compiled with
#   -ffp-contract=off. moon compiles a program's one C file in the command
#   that links it, so the flag reaches the compiler. Without it, an aarch64
#   release build fuses floating-point multiply-adds, in the log-normal
#   delay sampler and in core's exp and ln, and a seeded delay could then
#   differ from the one wasm-gc draws (spec #1: "native and Wasm agree").
#
# It also brings buildinfo/build_info.mbt up to date. moon's own rule for
# that file (buildinfo/moon.pkg) runs only when the file is missing or its
# generator changes, so on its own a binary would keep reporting the commit
# and the toolchain of its first build after a new commit or a toolchain
# upgrade. The file is rewritten only when what it records changes, so that
# nothing is recompiled for nothing.
import json
import os
import subprocess
import sys

root = os.path.dirname(os.path.abspath(__file__))
generator = os.path.join(root, "buildinfo", "gen_build_info.sh")
build_info = os.path.join(root, "buildinfo", "build_info.mbt")

generated = subprocess.run(
    ["sh", generator], stdout=subprocess.PIPE, stderr=sys.stderr, check=True
).stdout
try:
    with open(build_info, "rb") as f:
        current = f.read()
except FileNotFoundError:
    current = None
if generated != current:
    with open(build_info, "wb") as f:
        f.write(generated)

print(
    json.dumps(
        {
            "link_configs": [
                {"package": "smock/smock/openssl", "link_libs": ["ssl", "crypto"]},
                {"package": "smock/smock/engine", "link_flags": "-ffp-contract=off"},
            ]
        }
    )
)
