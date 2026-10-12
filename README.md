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
- `settings`: the settings of `smock serve`, each a flag with a matching
  `SMOCK_<NAME>` environment variable.
- `definitions`: reads a definition set, given as (name, bytes) pairs, into
  an immutable snapshot, or into diagnostics (file, JSON Pointer, message).
- `engine`: decides the response to each request from the snapshot.
- `defdir`: reads the definitions directory (native).
- `server`: the listeners and the connection loop (native).
- `log`: the JSON logger, one object per line.
- `buildinfo`: the version, commit and toolchain the binary was built with.
- `e2e`: tests that run the `smock` binary as a black box (native).

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there.

## Run

```sh
moon build --target native
_build/native/debug/build/smock/smock/cmd/smock/smock.exe serve --dir defs
```

`smock serve` reads the Definition files in the definitions directory and
listens on the plain port. Logs go to stderr, one JSON object per line.
`smock serve --help` lists the settings:

| Flag | Variable | Default |
|---|---|---|
| `--dir` | `SMOCK_DIR` | none: one empty Default Mock |
| `--port` | `SMOCK_PORT` | 8080 (0 picks a free port) |
| `--log-format` | `SMOCK_LOG_FORMAT` | `json` |
| `--body-file-dir` | `SMOCK_BODY_FILE_DIR` | `files` |

A Definition file, such as `defs/users.json`:

```json
{
  "mocks": [{ "name": "users" }],
  "stubs": [
    {
      "id": "get-user",
      "mock": "users",
      "request": { "method": "GET", "path": "/users/1" },
      "response": {
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": "{\"id\":1,\"name\":\"Alice\"}"
      }
    }
  ]
}
```

The field names are provisional until the JSON Schema is published.

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

Most tests drive the engine through its public interface, with in-memory
Definition files, a fixed clock and a seeded random source
(`engine/harness_test.mbt`). The tests in `e2e/` run the binary itself: each
one first runs `moon build --target native cmd/smock`, then starts smock with
its own temporary definitions directory and port 0, so they run in parallel
(`e2e/harness_test.mbt`). They need `moon` and `kill` on `PATH`.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that
`scripts/build-release.sh` records in the binary.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
