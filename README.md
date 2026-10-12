# smock

smock is a mock server for HTTP/1.1, HTTPS and Server-Sent Events. It stands in
for the services a system depends on, on Kubernetes and on developers'
machines. It is written in MoonBit ([ADR 0001](docs/adr/0001-moonbit-with-c-only-for-tls.md)).
The domain terms are defined in [GLOSSARY.md](GLOSSARY.md).

## Layout

The repository is a MoonBit workspace (`moon.work`) of four modules:

| Directory | Module | What it is |
|---|---|---|
| `.` | `smock/smock` | smock itself. Its parts are packages of this module. |
| `http1/` | `smock/http1` | The HTTP/1.1 codec. |
| `re2/` | `smock/re2` | RE2-syntax regular expressions. |
| `yaml/` | `smock/yaml` | Safe-subset YAML. |

The three protocol modules do no I/O and do not depend on smock, so they can
be published on mooncakes on their own. `scripts/check-protocol-modules.sh`
checks that.

Packages of `smock/smock`:

- `cmd/smock`: the `smock` binary.
- `log`: the JSON logger, one object per line.
- `buildinfo`: the version, commit and toolchain the binary was built with.

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there.

## Toolchain

The MoonBit toolchain version is pinned in `.moonbit-version`, and CI installs
exactly that version. A weekly CI job also builds and tests with the latest
stable MoonBit and opens an issue when that fails.

## Build and test

```sh
moon test --target native      # every module
moon test --target wasm-gc     # every package that does no I/O
moon check --deny-warn --target all
moon fmt --check
scripts/check-protocol-modules.sh
scripts/check-no-c.sh          # the C boundary of ADR 0001
scripts/build-release.sh       # dist/smock
dist/smock --version
```

CI runs all of these on linux/amd64 and linux/arm64
(`.github/workflows/build-test.yml`).

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that
`scripts/build-release.sh` records in the binary.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
