# moon runs this before every native build (see the prebuild option in
# moon.mod). It links OpenSSL into every executable that depends on the
# bindings in openssl/, test executables included. Link flags declared in a
# library's own moon.pkg do not reach its dependents, so they live here.
import json

print(
    json.dumps(
        {
            "link_configs": [
                {"package": "smock/smock/openssl", "link_libs": ["ssl", "crypto"]}
            ]
        }
    )
)
