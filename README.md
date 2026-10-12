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
| `yaml/` | `smock/yaml` | Safe-subset YAML: `parse` turns a document into the tree `@json.parse` gives for the equivalent JSON (documented in `yaml/yaml.mbt`). |

The three protocol modules do no I/O and do not depend on smock, so they can
be published on mooncakes on their own. `scripts/check-protocol-modules.sh`
checks that.

Packages of `smock/smock`:

- `cmd/smock`: the `smock` binary.
- `settings`: the settings of `smock serve`, each a flag with a matching
  `SMOCK_<NAME>` environment variable.
- `definitions`: reads a definition set, given as (name, bytes) pairs of
  JSON and YAML files, into an immutable snapshot, or into diagnostics
  (file, JSON Pointer, message). Its validation is written by hand and
  follows the JSON Schema.
- `engine`: decides the response to each request from the snapshot.
- `defdir`: reads the definitions directory and loads it, for both
  `smock serve` and `smock check` (native).
- `server`: the listeners and the connection loop (native). On the TLS
  port the same loop reads and writes through a TLS stream.
- `openssl`: smock's own bindings to OpenSSL, the one C library ADR 0001
  allows (native). A TLS connection there does no I/O: it takes the bytes
  that arrive from the peer and hands out the bytes to send, and `server`
  carries them over the socket. Its C is `openssl/openssl.c`.
- `testcerts`: a test PKI (a root CA, an intermediate CA, RSA and ECDSA
  leaf chains for `localhost` and `127.0.0.1`), used only by tests.
  `scripts/gen-test-certificates.sh` regenerates it.
- `log`: the JSON logger, one object per line.
- `buildinfo`: the version, commit and toolchain the binary was built with.
- `e2e`: tests that run the `smock` binary as a black box (native).

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there.

`schema/v1/definitions.json` is the JSON Schema of Definition files, the
contract for their format. `.github/workflows/schema-pages.yml` publishes it
on GitHub Pages, and `schema/v1/fixtures/` holds the Definition files that
CI checks with both the Schema and smock.

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
| `--tls-port` | `SMOCK_TLS_PORT` | 8443 (0 picks a free port) |
| `--tls-cert-file` | `SMOCK_TLS_CERT_FILE` | none |
| `--tls-key-file` | `SMOCK_TLS_KEY_FILE` | none |
| `--log-format` | `SMOCK_LOG_FORMAT` | `json` |
| `--body-file-dir` | `SMOCK_BODY_FILE_DIR` | `files` |
| `--header-size-limit` | `SMOCK_HEADER_SIZE_LIMIT` | 16384 bytes (16 KiB): larger request heads get 431 |
| `--header-count-limit` | `SMOCK_HEADER_COUNT_LIMIT` | 100 header fields: more get 431 |
| `--body-limit` | `SMOCK_BODY_LIMIT` | 10485760 bytes (10 MiB): longer bodies get 413 |
| `--read-timeout-ms` | `SMOCK_READ_TIMEOUT_MS` | 30000: a request must arrive whole within 30 s of its first byte |
| `--idle-timeout-ms` | `SMOCK_IDLE_TIMEOUT_MS` | 60000: a connection that waits 60 s for a request closes |

A request over a limit gets its status with `Connection: close`, then the
connection closes; a timeout closes the connection without a response.
Neither is logged.

With a certificate and its key, smock also serves HTTPS on the TLS port, with
the same Mocks as the plain port. Both are PEM files, for example the
`tls.crt` and `tls.key` of a Kubernetes Secret:

```sh
smock serve --dir defs --tls-cert-file /etc/smock/tls/tls.crt --tls-key-file /etc/smock/tls/tls.key
```

- The certificate file holds the leaf certificate, then its intermediate
  certificates, as cert-manager writes it; smock sends the whole chain. The
  key may be RSA or ECDSA, in PKCS#8, PKCS#1 or SEC1 PEM, and must not be
  encrypted.
- Setting only one of the two files, a file that cannot be read or holds no
  usable PEM, or a key that does not belong to the certificate stops
  `smock serve` with a log entry that says why, and exit status 1 (2 for a
  missing partner setting).
- ALPN offers only `http/1.1`. TLS 1.2 and 1.3 are accepted.
- The Host header chooses the Mock, as on the plain port; SNI does not.
- The `listening` log entry of the TLS port names the certificate and key
  files.
- Without certificate files, smock does not listen on the TLS port.

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

A Mock answers the requests for the Hosts it lists in `hosts`, and the
Default Mock answers the rest. A lone Mock is the Default Mock, so `users`
answers `curl localhost:8080/users/1`, with a `Smock-Mock: users;
via=default` header that says no Host matched.
[docs/definition-files.md](docs/definition-files.md#hosts-and-the-default-mock)
describes Hosts and the Default Mock.

`smock check defs` validates a definitions directory the way `smock serve`
loads it: it prints every problem, one per line with the file and a JSON
Pointer, and exits with status 1 if there is any.
[docs/definition-files.md](docs/definition-files.md) describes the format:
how Stubs match requests (method, path, query parameters, headers and
body, exactly, by RE2 pattern or as JSON), the order they are tried in (priority, then
file-name order), what a Mock answers when nothing matches, responses with
inline bodies, body files or Server-Sent Events, the JSON Schema, editor
support and writing Definition files in another configuration language.

Definition files can also be YAML (`.yaml` or `.yml`), mixed with JSON files
in one directory. A YAML file means exactly what the equivalent JSON file
means. `defs/users.yaml` is the same as `defs/users.json` above:

```yaml
mocks:
  - name: users
stubs:
  - id: get-user
    mock: users
    request: { method: GET, path: /users/1 }
    response:
      status: 200
      headers:
        Content-Type: application/json
      body: '{"id":1,"name":"Alice"}'
```

To keep that meaning the same in every YAML version and tool, smock accepts
only a safe subset of YAML (`yaml/`):

- Block and flow collections, plain and quoted scalars, `|` and `>` block
  scalars with their chomping indicators, comments, and one document.
- Plain `true`, `false`, `null` and JSON-syntax numbers are typed; quoted
  scalars are always strings. Any other plain scalar that YAML 1.1 or 1.2
  would type, such as `yes`, `on`, `~`, `True`, `0x1F`, `007`, `1_000`,
  `.inf` or `2001-12-14`, is rejected with "quote this value". Every other
  plain scalar is a string.
- Anchors, aliases, tags, merge keys, duplicate keys and multiple documents
  are rejected.

Every problem is reported with the file and the JSON Pointer of the value,
such as `users.yaml: /stubs/0/request/method: "on" may be read as a boolean;
quote this value`.

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
scripts/test-openssl-asan.sh   # the OpenSSL bindings under AddressSanitizer and LeakSanitizer
scripts/build-release.sh       # dist/smock
dist/smock --version
scripts/check-schema.sh dist/smock   # the JSON Schema and smock agree
```

`scripts/check-schema.sh` runs the external validator check-jsonschema
through `uvx` (or `pipx`) and needs `jq`. Adding a fixture file under
`schema/v1/fixtures/` adds it to the cross-check; the README there says
which directory a fixture belongs in.

CI runs all of these on linux/amd64 and linux/arm64
(`.github/workflows/build-test.yml`).

The native build links OpenSSL 3 (on Debian and Ubuntu, `libssl-dev`).
`prebuild.py`, which `moon` runs with `python3` before every native build,
adds `-lssl -lcrypto` to every executable that uses the bindings, tests
included, because link flags in a library's own `moon.pkg` do not reach the
packages that import it.

Most tests drive the engine through its public interface, with in-memory
Definition files, a fixed clock and a seeded random source
(`engine/harness_test.mbt`). The tests in `e2e/` run the binary itself: each
one first runs `moon build --target native cmd/smock`, then starts smock with
its own temporary definitions directory and port 0, so they run in parallel
(`e2e/harness_test.mbt`). They need `moon`, `kill` and `openssl` on `PATH`.
The HTTPS tests use clients that trust only the root CA of `testcerts`, and
the HTTP/1.1 tests run on both the plain and the TLS port.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that
`scripts/build-release.sh` records in the binary.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
