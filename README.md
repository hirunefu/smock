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
  `SMOCK_<NAME>` environment variable, and the arguments of `smock check`
  and `smock render`.
- `definitions`: reads a definition set, given as (name, bytes) pairs of
  JSON and YAML files, into an immutable snapshot, or into diagnostics
  (file, JSON Pointer, message). Its validation is written by hand and
  follows the JSON Schema. The snapshot holds each Mock's Stubs in matching
  order and their match index, which finds the Stubs a request can match
  by its method and exact path.
- `engine`: decides the response to each request from the snapshot,
  including its Faults, and renders a named Stub's response for a sample
  request, for `smock render` and the Admin render operation. `Engine(snapshot, match_index=false)` tries every
  Stub in matching order instead of using the index; tests check the index
  against it.
- `prng`: the seeded pseudo-random generator that Fault decisions draw
  from. Its sequence for a seed is fixed, the same on every target.
- `defdir`: reads the definitions directory and loads it, for
  `smock serve`, `smock check` and `smock render` (native).
- `server`: the listeners, the connection loop and the Admin API (native).
  On the TLS port the same loop reads and writes through a TLS stream; on
  the admin port it answers the Admin API.
- `metrics`: the metrics registry: counters, gauges and histograms with
  fixed label names, rendered in the Prometheus text format. Features
  register their metrics in the one registry `smock serve` keeps.
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

`openapi/admin.json` is the OpenAPI 3.1 document of the Admin API, the
contract for it as the JSON Schema is for Definition files; a client can be
generated from it in any language.

`Dockerfile` packs the release binary into the container image, and
`.github/workflows/release.yml` publishes the image and the release binaries
(see [Container image and release binaries](#container-image-and-release-binaries)).

`schema/v1/definitions.json` is the JSON Schema of Definition files, the
contract for their format. `.github/workflows/schema-pages.yml` publishes it
on GitHub Pages, and `schema/v1/fixtures/` holds the Definition files that
CI checks with both the Schema and smock.

## Run

```sh
moon build --target native
SMOCK_ADMIN_TOKEN=change-me _build/native/debug/build/smock/smock/cmd/smock/smock.exe serve --dir defs
```

`smock serve` reads the Definition files in the definitions directory and
listens on the plain port and on the admin port. Logs go to stderr, one JSON
object per line. `smock serve --help` lists the settings:

| Flag | Variable | Default |
|---|---|---|
| `--dir` | `SMOCK_DIR` | none: one empty Default Mock |
| `--port` | `SMOCK_PORT` | 8080 (0 picks a free port) |
| `--tls-port` | `SMOCK_TLS_PORT` | 8443 (0 picks a free port) |
| `--tls-cert-file` | `SMOCK_TLS_CERT_FILE` | none |
| `--tls-key-file` | `SMOCK_TLS_KEY_FILE` | none |
| `--admin-port` | `SMOCK_ADMIN_PORT` | 9090 (0 picks a free port) |
| `--admin-auth` | `SMOCK_ADMIN_AUTH` | `on`: the Admin API needs a bearer token; `off` for local use |
| `--admin-token-file` | `SMOCK_ADMIN_TOKEN_FILE` | none: the token comes from `SMOCK_ADMIN_TOKEN` |
| `--replicas` | `SMOCK_REPLICAS` | 1: above 1, every Admin API response warns that state is per replica |
| `--log-format` | `SMOCK_LOG_FORMAT` | `json` |
| `--body-file-dir` | `SMOCK_BODY_FILE_DIR` | `files` |
| `--header-size-limit` | `SMOCK_HEADER_SIZE_LIMIT` | 16384 bytes (16 KiB): larger request heads get 431 |
| `--header-count-limit` | `SMOCK_HEADER_COUNT_LIMIT` | 100 header fields: more get 431 |
| `--body-limit` | `SMOCK_BODY_LIMIT` | 10485760 bytes (10 MiB): longer bodies get 413 |
| `--read-timeout-ms` | `SMOCK_READ_TIMEOUT_MS` | 30000: a request must arrive whole within 30 s of its first byte |
| `--idle-timeout-ms` | `SMOCK_IDLE_TIMEOUT_MS` | 60000: a connection that waits 60 s for a request closes |
| `--seed` | `SMOCK_SEED` | none: smock picks the seed of its random generator, from 0 to 9007199254740991, and logs it ([Faults](docs/definition-files.md#seeds)) |

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

The Admin API is JSON over HTTP/1.1 on the admin port, as
[openapi/admin.json](openapi/admin.json) describes it:

- Every operation needs `Authorization: Bearer <token>`. The token comes
  from the file `--admin-token-file` names, or from the environment variable
  `SMOCK_ADMIN_TOKEN` (it has no flag, so it never shows in the process
  list), without the whitespace around it. With authentication on and no
  token, or with both, `smock serve` logs why and exits with status 1. A
  missing or wrong token gets 401 with `WWW-Authenticate: Bearer`; the token
  is compared in constant time. `--admin-auth off` turns authentication off
  for local use. The `smock starting` log entry says whether it is on
  (`"adminAuth":"on"`).
- Every response, errors included, names the replica that handled it in
  `Smock-Replica`: the host name, which in Kubernetes is the Pod's hostname.
  Every JSON response has a `warnings` array, which carries a
  `per_replica_state` warning when `--replicas` is above 1.
- Errors take the form `{"error": <code>, "message": ..., "warnings": [...]}`,
  unknown operations (404), unsupported methods (405) and malformed JSON
  (400) included.
- `GET /v1/status` shows the version, commit and toolchain, as
  `smock --version` prints them, and the Mocks with their Hosts and which
  one is the Default Mock. The definition set digest and the last reload
  result are `null` until reloading arrives.
- `GET /metrics` serves the Prometheus metrics, without a token, also when
  authentication is on. `smock_build_info` carries the version, commit and
  toolchain as labels.
- `POST /v1/stubs/{id}/render` renders a Stub's response for the sample
  request in the body, against the definitions the replica serves now, as
  `smock render` does (below). The optional `time` and `seed` query
  parameters give the time (RFC 3339) and the seed of the random source.
- The other operations of the document answer 501 until their tickets
  build them.

```sh
curl -H "Authorization: Bearer change-me" localhost:9090/v1/status
curl -H "Authorization: Bearer change-me" -d '{"path": "/users/1"}' \
  localhost:9090/v1/stubs/get-user/render
curl localhost:9090/metrics
```

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

A request that no Stub matches gets the Mock's no-match response, with a
`Smock-Near-Miss` header naming the closest Stub and the conditions it
failed, such as `Smock-Near-Miss: get-user; failed=method`.

`smock check defs` validates a definitions directory the way `smock serve`
loads it: it prints every problem, one per line with the file and a JSON
Pointer, and exits with status 1 if there is any. It also warns about Stubs
that can never match, because an earlier Stub always matches first;
warnings do not change the exit status.

`smock render --dir defs get-user --request sample.json` shows what a Stub
returns for a sample request before a test relies on it. The sample is JSON,
`{method, path, query, headers, body, session}`, every member optional
(`GET /` without query, headers, body or Session); the path and the query
values are given percent-decoded, as Stub conditions compare them, and a
repeated parameter or header takes an array of values. smock reads the
directory as `smock serve` does, body files included, and prints the
rendering as JSON, the same as the Admin render operation's result without
its `warnings`: the Stub's status, headers and body (`utf-8` text, or
`base64`) or its Server-Sent Events, and the conditions the sample fails,
with expected and actual values as in a Near miss (empty when it meets them
all). The Stub is rendered even when the sample fails them. `--time` (RFC
3339) and `--seed` fix the clock and the random source of the rendering;
a static response depends on neither. An invalid definitions directory
prints the messages `smock check` prints, and it, an unknown Stub ID and a
sample that cannot be read or is not valid exit with status 1, with the
problem on stderr.

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

## Container image and release binaries

Each release publishes the image `ghcr.io/hirunefu/smock:<version>` for
linux/amd64 and linux/arm64. It is distroless
(`gcr.io/distroless/base-debian13`): it holds the smock binary and what the
binary links dynamically, glibc and OpenSSL 3, and has no shell. smock runs
as UID 65532 and writes nothing to the filesystem, so the root filesystem can
be read-only:

```sh
export SMOCK_ADMIN_TOKEN=change-me
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
  -e SMOCK_ADMIN_TOKEN -p 8080:8080 -p 9090:9090 -v "$PWD/defs:/defs:ro" \
  ghcr.io/hirunefu/smock:<version> serve --dir /defs
```

The image's command is `serve`; arguments replace it (`... smock:<version>
--version`). Like any `smock serve`, it needs the Admin API token, from
`SMOCK_ADMIN_TOKEN` or from a mounted file that `--admin-token-file` names
(such as a Kubernetes Secret). The image exposes the plain port 8080, the TLS
port 8443 and the admin port 9090. Files mounted into the container must be
readable by UID 65532.

### Verify the image

The image and the image of each architecture are signed with cosign, without
a key: each signature's certificate names the release workflow at the
release's tag. With cosign 2.6 or later:

```sh
cosign verify ghcr.io/hirunefu/smock:<version> \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The image of each architecture has an SPDX SBOM, attached as a signed
attestation. To verify the SBOM of the linux/arm64 image and save it as
`smock.spdx.json` (use `amd64` for linux/amd64):

```sh
digest=$(docker buildx imagetools inspect --raw ghcr.io/hirunefu/smock:<version> |
  jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest')
cosign verify-attestation --type spdxjson \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/hirunefu/smock@$digest" | jq -r .payload | base64 -d | jq .predicate >smock.spdx.json
```

The same `cosign verify` flags verify that architecture's signature with
`"ghcr.io/hirunefu/smock@$digest"`. The GitHub release also has the SBOMs as
files, `smock-<version>-linux-<arch>.spdx.json`.
`scripts/verify-image.sh ghcr.io/hirunefu/smock:<version>` runs all of these
checks.

### Release binaries

Each GitHub release has the binaries `smock-<version>-linux-amd64` and
`smock-<version>-linux-arm64`, the same builds as in the image (Linux only in
R1). They link OpenSSL 3 dynamically, so they need it at run time: on Debian
and Ubuntu, the `libssl3` package (`libssl3t64` on newer releases). Make the
downloaded file executable with `chmod +x`. The release notes name the
MoonBit toolchain the release was built with, which `smock --version` also
prints.

### Making a release

Pushing a tag `v<major>.<minor>.<patch>` (or `v<major>.<minor>.<patch>-<pre-release>`)
runs `.github/workflows/release.yml`. On an amd64 and an arm64 runner, each
building for its own architecture without emulation, it builds smock with
the toolchain in `.moonbit-version`, builds the image and runs
`scripts/smoke-test-image.sh` on it. Only then does it push, combine, sign
and attest the image, verify it with `scripts/verify-image.sh`, and create
the GitHub release with notes from `scripts/release-notes.sh`. It never runs
on pull requests. Started by hand from the Actions tab, it builds and
smoke-tests everything and keeps the binaries, images and notes as workflow
artifacts, but publishes nothing. `scripts/check-release-workflow.sh`, run in
CI, checks those rules. After the first release, make the
`ghcr.io/hirunefu/smock` package public in its settings; GitHub creates it
private.

To smoke-test the image locally (needs docker, curl, openssl, readelf and jq):

```sh
scripts/build-release.sh
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev "$(git rev-parse --short=12 HEAD)" "moonc $(moonc -v | cut -d' ' -f1)"
```

It runs the image as its own UID with a read-only root filesystem, no
capabilities and no privilege escalation, and checks `smock --version`, a
Stub on the plain port, HTTPS with a test certificate, and the Admin API
status operation with a token file, which must name the same build as
`smock --version`. It also checks that the image adds nothing to its base but
the smock binary, and that the image is for the machine it runs on.

## Toolchain

The MoonBit toolchain version is pinned in `.moonbit-version`, and CI installs
exactly that version, as does the release workflow; the release notes name
it. A weekly CI job also builds and tests with the latest stable MoonBit and
opens an issue when that fails.

## Build and test

```sh
moon test --target native      # every module
moon test --target wasm-gc     # every package that does no I/O
moon check --deny-warn --target all
moon fmt --check
moon bench -p smock/smock/engine --release   # match index lookups: 100 vs 10,000 Stubs
scripts/check-protocol-modules.sh
scripts/check-no-c.sh          # the C boundary of ADR 0001
scripts/test-openssl-asan.sh   # the OpenSSL bindings under AddressSanitizer and LeakSanitizer
scripts/build-release.sh       # dist/smock
dist/smock --version
scripts/check-schema.sh dist/smock   # the JSON Schema and smock agree
scripts/check-openapi.sh       # the Admin API document is valid OpenAPI 3.1
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev <commit> "moonc <version>"   # the container image
scripts/check-release-workflow.sh    # the release workflow publishes only for tags (needs yq)
```

`scripts/check-schema.sh` runs the external validator check-jsonschema
through `uvx` (or `pipx`) and needs `jq`; `scripts/check-openapi.sh` runs
openapi-spec-validator the same way. The Admin API tests in `e2e/` check
every response against `openapi/admin.json` (`e2e/contract_test.mbt`). Adding a fixture file under
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
