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
import json

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
