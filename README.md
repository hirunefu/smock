# smock

smock is a mock server for HTTP/1.1, HTTPS and Server-Sent Events. It stands in
for the services a system depends on, on Kubernetes and on developers'
machines. It is written in MoonBit ([ADR 0001](docs/adr/0001-moonbit-with-c-only-for-tls.md)).
The domain terms are defined in [GLOSSARY.md](GLOSSARY.md).
[docs/getting-started-on-gke.md](docs/getting-started-on-gke.md) takes a
first-time reader to smock answering requests on GKE Autopilot.
[docs/migrating-from-mockoon.md](docs/migrating-from-mockoon.md) maps
Mockoon environments, routes and rules onto Mocks and Stubs.

## Layout

The repository is a MoonBit workspace (`moon.work`) of five modules:

| Directory | Module | What it is |
|---|---|---|
| `.` | `smock/smock` | smock itself. Its parts are packages of this module. |
| `http1/` | `smock/http1` | The HTTP/1.1 codec. |
| `re2/` | `smock/re2` | RE2-syntax regular expressions. |
| `xml/` | `smock/xml` | An XML parser that refuses DTDs, with simple paths that select values (documented in `xml/README.mbt.md`). |
| `yaml/` | `smock/yaml` | Safe-subset YAML: `parse` turns a document into the tree `@json.parse` gives for the equivalent JSON (documented in `yaml/yaml.mbt`). |

The four protocol modules do no I/O and do not depend on smock, so they can
be published on mooncakes on their own. `scripts/check-no-io.sh` checks
that.

Packages of `smock/smock`:

- `cmd/smock`: the `smock` binary. It ends with a status through
  `moonbitlang/x`'s `@sys.exit`, since neither core nor
  `moonbitlang/async` exposes one; smock itself binds no C for it.
- `settings`: the settings of `smock serve`, each a flag with a matching
  `SMOCK_<NAME>` environment variable, and the arguments of `smock check`
  and `smock render`; also the rule that derives the Journal's byte bound
  from a memory limit, which `server` reads from the cgroup at startup.
- `definitions`: reads a definition set, given as (name, bytes) pairs of
  JSON and YAML files, into an immutable snapshot, or into diagnostics
  (file, JSON Pointer, message). Its validation is written by hand and
  follows the JSON Schema. The snapshot holds each Mock's Stubs in matching
  order and their match index, which finds the Stubs a request can match
  by its method and exact path, and each response's templates, parsed.
- `engine`: decides the response to each request from the snapshot,
  including its Faults, and renders a named Stub's response for a sample
  request, for `smock render` and the Admin render operation. It also holds
  the Ephemeral Stubs and the Scenario state per Mock and Session, and the
  Journal, with its bound,
  eviction counts and query filter, applies the Admin API operations on
  them (verification and the unmatched requests included), and reads the Session a request carries in its W3C Baggage header. `Engine(snapshot, match_index=false)` tries every Stub in
  matching order instead of using the index; tests check the index against
  it.
- `template`: response templates: text templates (`${ expr }` in a body,
  a body file, a header value or an event field) and structured templates
  (`json` with `$each` and `$if`), the expression grammar, the fake-data
  helpers and their word and name lists, and escaping by media type. It
  parses a template once and renders it for a request, the time and one
  64-bit draw, and writes JSON with smock's own number form.
- `prng`: the seeded pseudo-random generator that Fault decisions and
  template helpers draw from. Its sequence for a seed is fixed, the same on
  every target.
- `defdir`: reads the definitions directory and loads it, for
  `smock serve`, `smock check` and `smock render`, and takes the stamp of
  it that a poll compares (native).
- `server`: the listeners, the connection loop and the Admin API (native).
  On the TLS port the same loop reads and writes through a TLS stream; on
  the admin port it answers the Admin API. It reloads rotated certificates,
  and reads the SNI name from the ClientHello before OpenSSL sees it, so that
  the name chooses the certificate without a C callback. Its one C
  function, in `server/reset.c`, sets `SO_LINGER` so that the reset Fault
  ends a connection with an RST, the exception ADR 0001 makes for it.
- `watch`: watches a directory, with the async runtime's file watcher
  (inotify) and polling in case an event is missed, so that `server` can
  reload the definitions directory and the certificate directories
  (native). Its `Schedule`, which coalesces a burst of events into one
  check and keeps the poll interval, does no I/O and reads no clock. A poll
  reads nothing unless the `Stamp` of what the caller reads (the names it
  lists, and where the files it reads really are and their times) may have
  changed since the last one.
- `metrics`: the metrics registry: counters, gauges and histograms with
  fixed label names, rendered in the Prometheus text format. Features
  register their metrics in the one registry `smock serve` keeps.
- `usage`: understands what Linux says a process and its cgroup use, and
  how long the process waited for a CPU, in `/proc/self/stat`,
  `/proc/self/status`, `/proc/self/schedstat` and a cgroup v2's `cpu.stat`
  and `memory.peak`, for the process and cgroup metrics; the machine's
  steal time in `/proc/stat`; and where `/proc/self/cgroup` puts the
  process's cgroup, for those and for the memory limit the Journal's bound
  follows. It does no I/O: `server` reads the files and hands it their
  text.
- `openssl`: smock's own bindings to OpenSSL, the one C library ADR 0001
  allows (native). A TLS connection there does no I/O: it takes the bytes
  that arrive from the peer and hands out the bytes to send, and `server`
  carries them over the socket. It also generates self-signed certificates
  in memory. Its C is `openssl/openssl.c`. The client side
  (`openssl/client.mbt`) is there for the bindings' own tests, which run a
  client and a server in memory under the sanitizers.
- `testcerts`: a test PKI (a root CA, an intermediate CA, RSA and ECDSA
  leaf chains for `localhost` and `127.0.0.1`, and ECDSA leaf chains for
  `users.example.com` and `orders.example.com`, each leaf with its own fixed
  expiry), used only by tests. `scripts/gen-test-certificates.sh`
  regenerates it.
- `log`: the JSON logger, one object per line, and the RFC 3339 times it
  writes, which the Admin API and the CLI also read.
- `buildinfo`: the version, commit and toolchain the binary was built with.
- `e2e`: tests that run the `smock` binary as a black box (native).

A package that does I/O or uses FFI declares `supported_targets = "native"`.
Every other package also builds for `wasm-gc`, and CI tests it there. The
packages that decide a response, `definitions`, `engine` and `template`,
and the ones they import, `prng` and `log`, must stay that way: `scripts/check-no-io.sh`
fails if one of them leaves out `wasm-gc`, reads the environment, binds C
or imports a package that does I/O.

`openapi/admin.json` is the OpenAPI 3.1 document of the Admin API, the
contract for it as the JSON Schema is for Definition files; a client can be
generated from it in any language.

`Dockerfile` packs the release binary into the container image, and
`.github/workflows/release.yml` publishes the image and the release binaries
(see [Container image and release binaries](#container-image-and-release-binaries)).
`charts/smock/` is the Helm chart, which the release workflow publishes too
(see [Helm chart](#helm-chart)).

`schema/v1/definitions.json` is the JSON Schema of Definition files, the
contract for their format. `.github/workflows/schema-pages.yml` publishes it
on GitHub Pages, and `schema/v1/fixtures/` holds the Definition files that
CI checks with both the Schema and smock.

`bench/` is the release benchmark, and `.github/workflows/benchmark.yml`
runs it when started by hand; `scripts/gke-bench.sh` runs it on GKE
Autopilot before an integration branch is merged into `main` (see
[Benchmark](#benchmark)).

## Run

Each release publishes the container image, the Helm chart and Linux
binaries ([Container image and release binaries](#container-image-and-release-binaries)).
To run the binary, download the one for your machine (`amd64` or `arm64`)
from the [latest release](https://github.com/hirunefu/smock/releases/latest),
with `<version>` its version without the `v`:

```sh
curl -fLo smock https://github.com/hirunefu/smock/releases/download/v<version>/smock-<version>-linux-amd64
chmod +x smock
SMOCK_ADMIN_TOKEN=change-me ./smock serve --dir defs
```

To run a commit that no release holds yet, build it from a checkout
([Build and test](#build-and-test)):

```sh
moon build --target native
SMOCK_ADMIN_TOKEN=change-me _build/native/debug/build/smock/smock/cmd/smock/smock.exe serve --dir defs
```

`smock serve` listens on the admin port, reads the Definition files in the
definitions directory, then listens on the plain port and on the TLS port.
It watches the directory and swaps in the new definition set when the files
change, ConfigMap updates included; an invalid set is reported and the
current one keeps serving
([docs/definition-files.md](docs/definition-files.md#reloading)). Logs go
to stderr, one JSON object per line; JSON is the only log format. Log
entries are a diagnostic aid: their messages and fields may change in any
release, unlike the Definition file format and the Admin API, which are
versioned (`v1`). A usage error, such as an
unknown flag, a missing argument or an invalid setting value, is not a log
entry: smock writes it to stderr as plain text, before any log entry, and
exits with status 2. `smock serve --help` lists the settings:

| Flag | Variable | Default |
|---|---|---|
| `--dir` | `SMOCK_DIR` | none: one empty Default Mock |
| `--port` | `SMOCK_PORT` | 8080 (0 picks a free port) |
| `--tls-port` | `SMOCK_TLS_PORT` | 8443 (0 picks a free port) |
| `--tls-cert-file` | `SMOCK_TLS_CERT_FILE` | none: a generated self-signed certificate |
| `--tls-key-file` | `SMOCK_TLS_KEY_FILE` | none: a generated self-signed certificate |
| `--tls-mock-certs` | `SMOCK_TLS_MOCK_CERTS` | none: no Mock has a certificate of its own (see below) |
| `--admin-port` | `SMOCK_ADMIN_PORT` | 9090 (0 picks a free port) |
| `--admin-auth` | `SMOCK_ADMIN_AUTH` | `on`: the Admin API needs a bearer token; `off` for local use |
| `--admin-token-file` | `SMOCK_ADMIN_TOKEN_FILE` | none: the token comes from `SMOCK_ADMIN_TOKEN` |
| `--replicas` | `SMOCK_REPLICAS` | 1: above 1, every Admin API response warns that state is per replica |
| `--session-header` | `SMOCK_SESSION_HEADER` | `baggage`: the W3C Baggage header that carries the [Session](#sessions-and-ephemeral-stubs) |
| `--session-member` | `SMOCK_SESSION_MEMBER` | `smock-session`: the member of that header whose value is the Session key |
| `--log-format` | `SMOCK_LOG_FORMAT` | `json`, the only format |
| `--body-file-dir` | `SMOCK_BODY_FILE_DIR` | `files` |
| `--header-size-limit` | `SMOCK_HEADER_SIZE_LIMIT` | 16384 bytes (16 KiB): larger request heads get 431 |
| `--header-count-limit` | `SMOCK_HEADER_COUNT_LIMIT` | 100 header fields: more get 431 |
| `--body-limit` | `SMOCK_BODY_LIMIT` | 10485760 bytes (10 MiB): longer bodies get 413 |
| `--read-timeout-ms` | `SMOCK_READ_TIMEOUT_MS` | 30000: a request must arrive whole within 30 s of its first byte, or, when it was pipelined behind a response, of that response |
| `--idle-timeout-ms` | `SMOCK_IDLE_TIMEOUT_MS` | 60000: a connection that waits 60 s for a request closes |
| `--drain-timeout-ms` | `SMOCK_DRAIN_TIMEOUT_MS` | 20000: how long smock drains after SIGTERM before it cuts what is still running |
| `--seed` | `SMOCK_SEED` | none: smock picks the seed of its random generator, from 0 to 9007199254740991, and logs it ([Faults](docs/definition-files.md#seeds)) |
| `--journal` | `SMOCK_JOURNAL` | `on`: requests are recorded in the [Journal](#the-journal); `off` records none |
| `--journal-max-entries` | `SMOCK_JOURNAL_MAX_ENTRIES` | 10000: beyond it, the oldest entries are evicted |
| `--journal-max-bytes` | `SMOCK_JOURNAL_MAX_BYTES` | a quarter of smock's memory limit (cgroup v2 `memory.max`), at least 1048576 bytes (1 MiB) and at most 67108864 (64 MiB); 64 MiB without a limit ([The Journal](#the-journal)): beyond it, the oldest entries are evicted |
| `--journal-body-limit` | `SMOCK_JOURNAL_BODY_LIMIT` | 4096 bytes (4 KiB): the most of a request body an entry keeps |

A request over a limit gets its status with `Connection: close`, then the
connection closes; a timeout closes the connection without a response.
Neither is logged.

Known limitation: after answering a request with 400, 413, 431, 501 or 505,
smock closes the connection without reading the rest of the request. A
client that is still sending it, such as a body over `--body-limit`, may
then get a connection reset instead of the error response. smock would
need to close only its sending side first (a half-close), which the async
library it is built on does not offer yet.

On SIGTERM, smock drains instead of dropping requests, so that a rolling
update does not fail the tests running against the old Pod. SIGINT and
SIGHUP do not drain: they end smock at once, cutting whatever is in
flight, so that Ctrl-C stops a local smock promptly.

- `/readyz` fails from the moment the signal arrives. The plain and TLS
  listeners close, so new connections are refused, and idle keep-alive
  connections close at once.
- Responses in progress finish with `Connection: close`, and their
  connections close after them. Server-Sent Event streams and pending
  delays go on. A stream whose client has gone away counts too, until smock
  next writes an event to it and notices, which an event's long delay can
  put off until the drain timeout.
- smock exits with status 0 as soon as nothing is in flight, and at the
  latest when the drain timeout (`--drain-timeout-ms`) expires: what is still
  running then is cut. Keep the Pod's `terminationGracePeriodSeconds` above
  it. On Kubernetes, also delay SIGTERM with a preStop sleep, so that
  Services stop sending new connections before the listeners close; the
  Helm chart does both.
- The admin port serves until exit, so the probes can be read during the
  drain. Log entries mark the start of the drain (`drain started`, with
  `timeoutMs`) and its end (`drain ended`, with `connectionsCut`, the number
  of connections still open when the timeout expired).

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

smock watches the directories of the certificate and key files, as it
watches the definitions directory: changes are coalesced for 250 ms, the
directories are polled every 10 s as well, and a Secret update (which swaps
the `..data` symlink) counts as a change. When a pair changes, smock loads
it without a restart: new handshakes get the new certificate, and open
connections carry on with the one they started with. A changed pair that
cannot be used (a file that cannot be read or holds no usable PEM, or a key
that does not belong to the certificate) is not swapped in, and smock keeps
presenting the previous one. Either way one log entry names the pair
(`"mock":""` for the default certificate) and the new certificate's expiry:

```json
{"time":"…","level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"/etc/smock/tls/tls.crt","keyFile":"/etc/smock/tls/tls.key","expiry":"2027-01-01T00:00:00.000Z"}
{"time":"…","level":"error","msg":"TLS certificate reload failed","mock":"","certFile":"/etc/smock/tls/tls.crt","keyFile":"/etc/smock/tls/tls.key","expiry":null,"error":"certificate file: no PEM certificate found"}
```

By default every handshake gets that one certificate, usually with a SAN for
each Host. `--tls-mock-certs` (`SMOCK_TLS_MOCK_CERTS`) gives single Mocks
their own certificates, as a JSON object that maps each Mock name to its
certificate and key files:

```sh
smock serve --dir defs --tls-cert-file /etc/smock/tls/tls.crt --tls-key-file /etc/smock/tls/tls.key \
  --tls-mock-certs '{"users":{"certFile":"/etc/smock/users/tls.crt","keyFile":"/etc/smock/users/tls.key"}}'
```

- A handshake whose SNI is one of the Hosts of a listed Mock, compared as
  Hosts are (case-insensitively, without a trailing dot), gets that Mock's
  certificate. A handshake without SNI, or whose SNI is no Host of a listed
  Mock, gets the default certificate: `--tls-cert-file`, or without it the
  generated self-signed certificate (below).
- SNI follows the Hosts of the definition set served, reloads included. It
  only chooses the certificate: the Host header still chooses the Mock.
  Definition files never refer to certificates.
- A listed Mock that the Definition files do not declare is not an error,
  since Mocks come and go on reload: its certificate is chosen for nothing
  until a reload declares the Mock, and smock logs a warning
  (`TLS certificate for a Mock that is not declared`) each time it goes
  missing, at startup included.
- Each pair is loaded at startup, and one that cannot be loaded stops
  `smock serve` with exit status 1, as for the default pair. A value that is
  not such a JSON object, or an entry without both files, exits with
  status 2.
- Each pair rotates as the default certificate does.

The metric `smock_tls_certificate_expiry_timestamp_seconds` gives when each
certificate the TLS port presents expires (its notAfter), in seconds since
the Unix epoch: `mock=""` for the default certificate, the generated
self-signed one included, and `mock="<name>"` for a Mock's own. It follows
rotations and new self-signed certificates, so an alert on it notices a
renewal that stopped working before clients fail.

Without default certificate files, smock still serves HTTPS on the TLS
port, with a self-signed certificate it generates at startup, for local
use. It is the default certificate, so with `--tls-mock-certs` the listed
Mocks' Hosts get their own certificates by SNI and every other handshake
gets this one:

- The certificate covers `localhost`, `127.0.0.1`, `::1` and every Host of
  every Mock. Hosts that are IP addresses are IP address names, the others
  DNS names, so a client that trusts the certificate can call any Mock by
  its Host.
- Its key is a new ECDSA P-256 key. Both are generated with OpenSSL and
  held only in memory; nothing is written to disk, so a read-only root
  filesystem is fine. The certificate is valid for 365 days.
- When a reload changes the set of Hosts, smock generates a new certificate
  for new connections; open connections keep theirs. A reload that keeps
  the Hosts, and a failed reload, keep the certificate.
- A log entry at startup and at each new certificate gives its SHA-256
  fingerprint and its names:
  `{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"AB:12:…","names":["localhost","127.0.0.1","::1","users.example.com"]}`.
  To trust it, read it from the handshake, for example with
  `openssl s_client -connect 127.0.0.1:8443 </dev/null | openssl x509 >smock.pem`
  and `curl --cacert smock.pem https://localhost:8443/`, and check its
  fingerprint against the log with `openssl x509 -in smock.pem -noout -fingerprint -sha256`.
- With default certificate files configured, nothing is generated.

The Admin API is JSON over HTTP/1.1 on the admin port, as
[openapi/admin.json](openapi/admin.json) describes it:

- Every operation needs `Authorization: Bearer <token>`. The token comes
  from the file `--admin-token-file` names, or from the environment variable
  `SMOCK_ADMIN_TOKEN` (it has no flag, so it never shows in the process
  list), without the whitespace around it. With authentication on and no
  token, `smock serve` logs why and exits with status 1. Setting both the
  token file and `SMOCK_ADMIN_TOKEN` is refused the same way, at startup,
  rather than one of them silently winning. A
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
  `smock --version` prints them, the definition set digest, the result of
  the last reload of the Definition files (`null` until the first one), and
  the Mocks with their Hosts and which one is the Default Mock.
- The probes need no token, also when authentication is on. They answer
  200 `{"status": "ok", ...}` when they pass and 503 with the error shape
  when they fail:
  - `GET /startupz` passes once the first definition set has loaded. The
    admin port opens before the definitions load, and until then the probe
    fails with `not_started`, as does every operation that needs the
    definitions.
  - `GET /readyz` passes while smock serves, also after a reload that
    failed, since the previous definition set keeps serving. It fails with
    `not_started` before startup completes and with `not_ready` from the
    moment SIGTERM arrives.
  - `GET /livez` passes while the event loop answers, during the drain too,
    so that Kubernetes does not kill a draining Pod early.
- `GET /metrics` serves the Prometheus metrics, without a token, also when
  authentication is on. `smock_build_info` carries the version, commit and
  toolchain as labels; `smock_definition_reloads_total` counts reloads of
  the Definition files by result; with HTTPS,
  `smock_tls_certificate_expiry_timestamp_seconds` gives when each
  certificate expires; `smock_journal_entries`, `smock_journal_bytes` and
  `smock_journal_evictions_total` show the [Journal](#the-journal)'s size
  and evictions, without labels.
- What smock's process and its cgroup use is read when `/metrics` is
  scraped, so serving requests costs nothing for it. The standard process
  metrics of Prometheus's client libraries: `process_cpu_seconds_total`
  (user and system, from `/proc/self/stat`, to the hundredth of a second),
  `process_resident_memory_bytes` (`VmRSS` of `/proc/self/status`) and
  `process_start_time_seconds`. How long smock's main thread, which serves
  every request, was ready to run but waited for a CPU,
  `smock_process_scheduling_delay_seconds_total` (`run_delay` of
  `/proc/self/schedstat`, to the nanosecond), and how many times the kernel
  took the CPU from it while it could still run,
  `smock_process_involuntary_context_switches_total`
  (`nonvoluntary_ctxt_switches` of `/proc/self/status`). With a CPU limit,
  both include the time the CFS quota held smock back. The CPU time the
  hypervisor gave to something else while the machine's CPUs had something
  to run, `smock_node_cpu_steal_seconds_total` (`steal` of `/proc/stat`, to
  the hundredth of a second): the machine's, all its CPUs together, not
  smock's, and 0 on bare metal; in a container, its node's. With how long
  the quota held smock back, `smock_cgroup_cpu_throttled_seconds_total`
  below, they tell a smock that waited for a CPU on a busy node (a delay
  well beyond the throttled time, or steal time) from one that needed more
  CPU (a delay about the throttled time). On cgroup v2, the metrics of
  smock's own cgroup, the one `/proc/self/cgroup` names: from its `cpu.stat`,
  `smock_cgroup_cpu_usage_seconds_total` (to the microsecond) and, with a
  CPU limit, `smock_cgroup_cpu_periods_total`,
  `smock_cgroup_cpu_throttled_periods_total` and
  `smock_cgroup_cpu_throttled_seconds_total`, how often and how long the
  CFS quota held it back; from its `memory.peak`,
  `smock_cgroup_memory_peak_bytes`, the most memory it has used, all that
  `memory.max` limits. In a Kubernetes container the cgroup is the
  container's, so they show smock's CPU, throttling and peak memory where
  nothing outside the Pod can read its cgroup, as on GKE Autopilot; outside
  one, the cgroup may hold other processes too. A metric whose file smock
  cannot read when it starts is left out; one whose file it cannot read
  or understand at a scrape keeps the value it last read, and `/metrics`
  answers all the same.
- The request traffic on the plain and TLS ports is in
  `smock_requests_total` and the latency histogram
  `smock_request_duration_seconds` (from the request being read in full to
  the last byte of its response, so injected delays and Server-Sent Event
  streams count; buckets from 100 µs to 5 minutes), labelled only by `mock`
  and `stub`, and in `smock_unmatched_requests_total`, labelled only by
  `mock`. A Stub from a Definition file is labelled by its ID, every
  Ephemeral Stub by `stub="ephemeral"`, and a request that matched no Stub
  by `stub=""`. A request is labelled with the Mock that answered it, the
  Default Mock included, or `mock=""` when no Mock did. A request the
  HTTP/1.1 codec rejects (400, 413, 431, 501 or 505, such as a malformed
  head or a body over `--body-limit`) counts with `mock=""` and `stub=""`,
  timed from the read that brought it; it is not an unmatched request, and
  the Journal does not record it. Labels never carry a path, Host, method,
  status or Session, so the number of series stays bounded by the
  Definition files. A request is counted once its response is written; the
  Admin API, probes and `/metrics` are not counted. No request is logged.
- `POST /v1/stubs/{id}/render` renders a Stub's response for the sample
  request in the body, against the definitions the replica serves now, as
  `smock render` does (below). The optional `time` and `seed` query
  parameters give the time (RFC 3339) and the seed of the random source;
  the rendering shows those it used.
- `/v1/mocks/{mock}/stubs` adds, lists and deletes Ephemeral Stubs, and
  `POST /v1/reset` clears them, Journal entries and Scenario state
  ([below](#sessions-and-ephemeral-stubs)).
- `GET /v1/mocks/{mock}/scenarios` lists the calling Session's Scenarios of
  a Mock, with their states, and `PUT /v1/mocks/{mock}/scenarios/{scenario}`
  sets the state of one ([below](#sessions-and-ephemeral-stubs)).
- `POST /v1/journal/query` lists the calling Session's requests from the
  [Journal](#the-journal), `POST /v1/journal/verify` checks how many of
  them there were, and `GET /v1/journal/unmatched` lists those that no
  Stub answered, with their Near misses
  ([below](#verifying-calls-and-unmatched-requests)).

```sh
curl -H "Authorization: Bearer change-me" localhost:9090/v1/status
curl -H "Authorization: Bearer change-me" -d '{"path": "/users/1"}' \
  localhost:9090/v1/stubs/get-user/render
curl localhost:9090/metrics
curl localhost:9090/readyz
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
that can never match, because an earlier Stub always matches first, and
about a [state that a Stub requires but no Stub moves its Scenario
to](docs/definition-files.md#a-state-that-no-stub-moves-to); warnings do
not change the exit status.

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
all). The Stub is rendered even when the sample fails them, and a
[templated](docs/definition-files.md#templates) response is rendered for
the sample. `--time` (RFC 3339) and `--seed` fix the clock and the random
source of the rendering; without a seed, it uses the Stub's `fault.seed`,
or a fresh one. The rendering shows the `time` and the `seed` it used, so
it can be repeated exactly, and a template that fails for the sample shows
the 500 a request would get and its `templateError`. An invalid definitions directory
prints the messages `smock check` prints, and it, an unknown Stub ID and a
sample that cannot be read or is not valid exit with status 1, with the
problem on stderr.

[docs/definition-files.md](docs/definition-files.md) describes the format:
how Stubs match requests (method, path, query parameters, headers,
cookies and body, exactly, by RE2 pattern, as JSON or by paths into XML,
negated or by presence with `$not` and `$exists`, and by array element
with `$includes`), the order they are tried in (priority, then
file-name order), what a Mock answers when nothing matches, responses with
inline bodies, body files, JSON or Server-Sent Events, response templates,
Faults, the JSON Schema, editor support and writing Definition files in
another configuration language.
[docs/migrating-from-mockoon.md](docs/migrating-from-mockoon.md) turns a
Mockoon environment into Definition files.

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

A JSON file with a key repeated in one object is rejected too, at the later
key: JSON parsers disagree on which of the two values counts.

Every problem is reported with the file and the JSON Pointer of the value,
such as `users.yaml: /stubs/0/request/method: "on" may be read as a boolean;
quote this value`.

## Sessions and Ephemeral Stubs

A test names its *Session* in the W3C `baggage` header of its requests, in
the `smock-session` member, and Admin API calls name theirs the same way.
Through the Admin API, a test adds *Ephemeral Stubs* to a Mock from the
Definition files, for its Session only:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"request":{"method":"GET","path":"/users/1"},"response":{"status":503}}' \
  localhost:9090/v1/mocks/users/stubs
curl -H "baggage: smock-session=checkout-42" localhost:8080/users/1   # 503
curl localhost:8080/users/1                                           # 200, from the file
```

- The Session key is the value of the first `smock-session` member of the
  `baggage` headers, combined, trimmed and percent-decoded; properties after
  `;` are ignored. A missing or empty value, or a `baggage` header that is
  not W3C Baggage, means no Session. `--session-header` and
  `--session-member` name another header or member.
- An Ephemeral Stub has the shape of a Stub in a Definition file, without
  `id` and `mock`: the path names the Mock, and smock assigns the ID,
  `eph-<n>`, and returns it. Its body must be inline. It is validated like a
  Stub from a Definition file: problems get 400 `invalid_stub` with the
  messages `smock check` gives. A Mock that does not exist gets 404
  `unknown_mock`: Mocks come only from Definition files.
- Requests with the Session try its Ephemeral Stubs of the Mock before any
  Stub from the Definition files: by their own `priority`, the newest first
  among equal priorities. Other Sessions never see them. Requests without a
  Session form their own space, and Ephemeral Stubs added without a Session
  apply only to them. An Ephemeral Stub can be the Near miss, named by its
  ID in `Smock-Near-Miss`.
- The Session also keeps its own state of each
  [Scenario](docs/definition-files.md#scenarios). An Ephemeral Stub may
  carry a `scenario` clause, as a Stub in a Definition file does, even on a
  Scenario that no file names, and shares the Session's state with the
  file Stubs that name the same Scenario. Deleting the Ephemeral Stub
  leaves the state as it is; a reset clears it.
- `GET /v1/mocks/{mock}/scenarios` lists the calling Session's Scenarios of
  the Mock, those its file Stubs and the Session's own Ephemeral Stubs
  name, by name. Each has its current `state` and its known `states`:
  `Started` first, then every state those Stubs name for it. When the
  Session deletes the Ephemeral Stubs that named a Scenario, but still
  holds a state for it, the Scenario stays listed, with `["Started"]` as
  its known states, so that a test can reset it.
  `PUT /v1/mocks/{mock}/scenarios/{scenario}` with `{"state":"Paid"}` sets
  the state for the calling Session, so that a test can start in the middle
  of a flow; `{"state":"Started"}` resets one Scenario. A Scenario that the
  list does not show gets 404 `unknown_scenario`, and a state outside the
  known states 400 `unknown_state`, so a typo cannot leave a Scenario in a
  state that nothing matches.
- `GET` lists and `DELETE /v1/mocks/{mock}/stubs/{id}` deletes the calling
  Session's Ephemeral Stubs of the Mock. `POST /v1/reset` with
  `{"scope":"session"}` clears the calling Session's Ephemeral Stubs,
  [Journal](#the-journal) entries and Scenario state of every Mock, and its
  eviction count; `{"scope":"mock","mock":"users"}` every Session's of one
  Mock, even one that a reload removed while the Journal holds its entries;
  and `{"scope":"all"}` all of them, and every eviction count. Without a
  Session, `{"scope":"session"}` clears the no-Session space. A Scenario
  whose state is cleared is back in `Started`. It answers how many
  Ephemeral Stubs, Journal entries and Scenario states it removed.
- Ephemeral Stubs live in the process that received them, until a reset or
  a restart. They survive a [reload](docs/definition-files.md#reloading) of
  the Definition files, except those of a Mock the new files no longer
  declare.
- Adding, deleting, setting a Scenario's state and resetting each write a
  log entry (`Ephemeral Stub added`, `Ephemeral Stub deleted`, `Scenario
  state set`, `reset`); requests write none.

## The Journal

smock records the requests it receives in the *Journal*, so that a test can
check what its system sent. A test queries its own Session's entries:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"filter":{"mock":"users","method":"GET","path":"/users/1"},"limit":10}' \
  localhost:9090/v1/journal/query
```

- Each entry records the Session, the Host, the Mock and whether the
  Default Mock answered; the method, target, HTTP version, header fields
  and body; the Stub that answered, or the Near miss with what each failed
  condition expects and what the request sent, each with `stubSource`:
  `file` for a Stub from a Definition file, `ephemeral` for an Ephemeral
  Stub, so that equal IDs cannot be confused; the
  [Scenario](docs/definition-files.md#seeing-what-moved) move the Stub
  made, as `scenario`, with its name and the states it moved from and to;
  the status, or the connection Fault; when the request was received and
  how long the response took; and the digest of the definition set that
  answered. A request for a Host that no Mock answers is recorded too,
  with no Mock; one the HTTP/1.1 codec rejects (400, 413, 431, 501 or 505)
  is not.
- A request is in the Journal as soon as its client has the whole
  response: smock records it just before it writes the response's last
  bytes, so a query made right after a call always finds it. A stream of
  Server-Sent Events is recorded when its last event is written, and a
  request ended by a connection Fault when the connection closes.
- The filter takes a Mock, a method, a path and headers, with the
  semantics of Stub conditions (exact, `{ "pattern": … }`, and `$not` and
  `$exists` for headers), and a time range on when the request was
  received: `since` (included) and `until` (excluded), as RFC 3339
  date-times. Every member is optional. Entries
  come oldest first, at most `limit` of them (100 by default, at most
  10000); `more` says whether more passed the filter.
- Each entry has a sequence number, `seq`: 1 for the first entry the
  process records, then one more for each entry after it, whatever its
  Session. To fetch the next page, a query gives `"after"` the `seq` of the
  last entry it got, with the same filter; no entry is lost or repeated,
  even among requests received in the same millisecond.
- The Journal is one ring buffer per process, bounded by entry count and by
  bytes (`--journal-max-entries`, `--journal-max-bytes`), and keeps at most
  4 KiB of each body (`--journal-body-limit`), cut at a character boundary
  when the body is UTF-8. When it is full, the oldest entries are evicted,
  and smock counts the evicted entries of each Session: `evicted` in the
  query's result says how many of the calling Session's entries may be
  missing. Requests without a Session have their own count. A Session's
  count is kept until that Session, or everything, is reset (a reset of
  one Mock keeps it), so the counts grow with the number of Sessions whose
  entries were evicted.
- `--journal off` records nothing, and a Mock with `"journal": false`
  ([docs/definition-files.md](docs/definition-files.md#turning-the-journal-off-for-a-mock))
  records none of its requests, so that a high-rate load test pays nothing
  for recording. A query while the Journal is off, or whose filter names
  such a Mock, gets 409 `journal_off` rather than entries that cannot be
  trusted. Only those are refused: a filter that names no Mock is answered
  from the requests that were recorded, which leave out those of Mocks
  whose Journal is off.
- The Journal survives a [reload](docs/definition-files.md#reloading) of
  the Definition files; each entry keeps the digest of the set that
  answered it. It lives in the process that received the requests, until a
  reset or a restart.
- The byte bound follows smock's memory limit, so that the Journal fits a
  small Pod ([ADR 0004](docs/adr/0004-journal-byte-bound-follows-the-memory-limit.md)).
  `--journal-max-bytes` or `SMOCK_JOURNAL_MAX_BYTES` always wins. Without
  either, smock reads the memory limit of its own cgroup at startup:
  `memory.max` of the cgroup v2 that `/proc/self/cgroup` names, under
  `/sys/fs/cgroup`, which in a container on a Kubernetes node with cgroup
  v2 is the container's memory limit. The bound is a quarter of that
  limit, rounded down, at least 1 MiB, so that a tiny limit still records
  something, and at most 64 MiB. Without a limit (`max`), or when it
  cannot be read, as on a cgroup v1 host, the bound is 64 MiB. Under a
  52Mi limit it is 13 MiB, which holds about 8,400 entries of the
  benchmark's request mix (each counts about 1.6 KB); from a 256Mi limit
  up, it is 64 MiB.
- smock logs the bound it uses at startup, with its `source`: `flag`,
  `variable`, `memoryLimit` (a quarter of the limit), `minimum` (1 MiB) or
  `default` (64 MiB), and the `memoryLimit` it read, in bytes or `max`, or
  `memoryLimitError`, why it could not read one:

  ```json
  {"time":"2026-10-14T09:00:00.000Z","level":"info","msg":"journal byte bound","maxBytes":13631488,"source":"memoryLimit","memoryLimit":54525952}
  ```

### Verifying calls and unmatched requests

A test checks that its system sent a request exactly, at least or at most
N times. It gives the same filter as a query, and exactly one of
`exactly`, `atLeast` and `atMost`:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
  -d '{"filter":{"method":"POST","path":"/orders"},"exactly":1}' \
  localhost:9090/v1/journal/verify
# {"ok":true,"count":1,"evicted":0,"reason":null,"warnings":[]}
```

- `count` is how many of the calling Session's entries pass the filter;
  other Sessions' requests are never counted. A check that fails is still
  a 200 response, with `ok` false and `reason` `count`.
- Verification never trusts a count that may be wrong. When the Journal
  bound has evicted any of the Session's entries since its last reset
  (`evicted` above 0), `exactly` and `atMost` fail with `reason` `evicted`,
  whatever the count. `atLeast` is still decided by the count, because
  eviction can only lower it. A Session reset clears the eviction count.
- Like a query, verification while the Journal is off, or whose filter
  names a Mock whose Journal is off, gets 409 `journal_off`. A filter that
  names no Mock counts only the requests that were recorded, so none of
  such a Mock's.

`GET /v1/journal/unmatched` lists the calling Session's requests that no
Stub answered, oldest first, at most `limit` of them (a query parameter,
100 by default, at most 10000), in the same form as a query's entries; the
`after` query parameter pages through them as a query's `after` does. Each
carries its full Near miss: the closest Stub, and every condition it
failed with what the Stub expects and what the request sent. A request for
a Host that no Mock answers is among them, with no Mock and no Near miss.
It gets 409 `journal_off` while the Journal is off globally; the unmatched
requests of a Mock whose Journal is off were not recorded, so they are not
listed.

## Container image and release binaries

Each release publishes the image `ghcr.io/hirunefu/smock:<version>` for
linux/amd64 and linux/arm64. The image of each architecture it is made of
also keeps a tag of its own, `<version>-amd64` and `<version>-arm64`; use
`<version>`, which picks the one for the machine. The image is distroless
(`gcr.io/distroless/base-debian13`): it holds the smock binary, what the
binary links dynamically (glibc and OpenSSL 3), and smock's `LICENSE` and
`NOTICE` under `/usr/share/doc/smock/`, and has no shell. smock runs
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

To run a commit that no release holds yet, build the image from a checkout
with `scripts/build-release.sh` and `docker build --tag smock:dev .`, or
from the release binary that CI keeps for 7 days after each push (the
`smock-linux-amd64` and `smock-linux-arm64` artifacts of its run), copied to
`dist/smock`. Push it to a registry the cluster can pull from, then install
the chart below from the checkout's `charts/smock`, with `image.repository`
and `image.tag` naming that image.

### Helm chart

Each release also publishes the Helm chart `oci://ghcr.io/hirunefu/charts/smock`,
with the release's version as its version and app version, so it runs the
image of the same release:

```sh
kubectl create secret generic smock-admin-token --from-literal=token="$(openssl rand -hex 32)"
helm install smock oci://ghcr.io/hirunefu/charts/smock --version <version> \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.users\.yaml=mocks/users.yaml'
```

The Definition files come from a ConfigMap by default, and a ConfigMap
update reaches the running smock through its reload, without a restart
(with body files, a file added, removed or renamed restarts the Pods); a
git-sync sidecar or an OCI image volume can deliver them instead. The Pods
meet the Restricted Pod Security Standard, run one replica with one CPU
core and 1 GiB by default (requests equal to limits, valid on GKE Autopilot
as they are), and get the Admin API token and the TLS certificates,
the default one and those of single Mocks, from Secrets. Before SIGTERM,
smock's container sleeps in a preStop hook (5 s by default) while the Pod
leaves its Services' endpoints, and the Pod's grace period covers that sleep
and the drain; the hook's `sleep` action needs Kubernetes 1.30 or later.
[charts/smock/README.md](charts/smock/README.md) describes the
chart and lists every value with its default.

### Verify the image

The image and the image of each architecture are signed with cosign, without
a key: each signature's certificate names the release workflow at the
release's tag. The release signs with cosign 3, which stores signatures as
OCI 1.1 referrers, so verify with cosign 3 or later:

```sh
cosign verify ghcr.io/hirunefu/smock:<version> \
  --certificate-identity https://github.com/hirunefu/smock/.github/workflows/release.yml@refs/tags/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The image of each architecture has an SPDX SBOM, attached as a signed
attestation. It lists the packages of the distroless base and smock itself:
the binary with the release's version, the commit and MoonBit toolchain it
was built from, the MoonBit modules compiled into it, and its dynamic link
to the base's OpenSSL. To verify the SBOM of the linux/arm64 image and save
it as `smock.spdx.json` (use `amd64` for linux/amd64):

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
`smock-<version>-linux-arm64`, the same builds as in the image; smock runs
on Linux only. They link glibc and OpenSSL 3 dynamically, so they need
glibc 2.34 or later and OpenSSL 3 at run time: on Debian and Ubuntu, the
`libssl3` package (`libssl3t64` on newer releases). Debian 12, Ubuntu 22.04,
RHEL 9 and their successors have both. Make the downloaded file executable
with `chmod +x`. The release notes name the MoonBit toolchain the release
was built with, which `smock --version` also prints.

### Making a release

[docs/releasing.md](docs/releasing.md) describes how a release is made and
published, for the maintainer.

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
scripts/check-no-io.sh         # no I/O in the protocol modules and the packages that decide a response
scripts/check-no-c.sh          # the C boundary of ADR 0001
scripts/test-openssl-asan.sh   # the OpenSSL bindings under AddressSanitizer and LeakSanitizer
scripts/build-release.sh       # dist/smock
dist/smock --version
scripts/check-schema.sh dist/smock   # the JSON Schema and smock agree
scripts/check-openapi.sh       # the Admin API document is valid OpenAPI 3.1
docker build --tag smock:dev .
scripts/smoke-test-image.sh smock:dev 0.0.0-dev <commit> "moonc <version>"   # the container image
scripts/check-release-workflow.sh    # the release workflow publishes only for tags (needs yq and jq)
scripts/check-benchmark-workflow.sh  # the benchmark workflow runs only by hand (needs yq and jq)
scripts/check-ci-artifacts.sh        # CI keeps the release binary of each architecture (needs yq and jq)
scripts/test-helm-chart.sh           # rendering tests of the Helm chart (needs helm, yq and jq)
scripts/test-helm-chart-on-kind.sh smock:dev   # the chart on a kind cluster (needs kind, kubectl and helm)
```

`scripts/test-helm-chart.sh` renders `charts/smock` for each delivery mode
of the Definition files and each Admin API authentication and TLS option,
and checks the manifests, the Restricted Pod Security Standard included,
and that the chart's README lists every value with its default.
`scripts/test-helm-chart-on-kind.sh` creates a kind cluster, checks every
delivery mode against Kubernetes' own Pod Security admission, installs the
chart with the image into a namespace that enforces the Restricted
standard, and checks that a Stub answers and that a ConfigMap update is
served without a Pod restart; it deletes the cluster afterwards.
`scripts/install-kubernetes-tools.sh` installs the pinned helm, kubectl and
kind that CI uses.

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
packages that import it. It also compiles every executable that holds the
engine with `-ffp-contract=off`, so that a release build on arm64 does not
fuse floating-point multiply-adds and a seeded delay is the same as on
wasm-gc; CI tests the engine in a release build to check it. And it brings
the build information that `smock --version` reports up to date, so every
native build, release or not, names the commit checked out and the
toolchain in use.

Most tests drive the engine through its public interface, with in-memory
Definition files, a fixed clock and a seeded random source
(`engine/harness_test.mbt`). The tests in `e2e/` run the binary itself: each
one first runs `moon build --target native cmd/smock`, then starts smock with
its own temporary definitions directory and port 0 for each port, so they
run in parallel (`e2e/harness_test.mbt`). They need `moon`, `moonc`, `git`,
`kill` and `openssl` on `PATH`. The HTTPS tests use clients that trust only
the root CA of `testcerts`, and the HTTP/1.1 tests run on both the plain and
the TLS port. The tests of the generated certificate (`e2e/self_signed_test.mbt`)
read it from the handshake with `openssl s_client` and then trust only it.
The test of the Journal's byte bound under a memory limit
(`e2e/journal_bound_test.mbt`) starts smock in a systemd user scope with
`MemoryMax`, as the benchmark does, so it needs `systemd-run` and a systemd
user manager with the `memory` controller delegated to it (see
[Run it on your machine](bench/README.md#run-it-on-your-machine)). Where a
scope cannot get the limit, it prints why it skipped and passes.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that a
native build, such as `scripts/build-release.sh`, records in the binary.

## Benchmark

`bench/` is the release benchmark. It measures smock's real request path,
realistic requests matched against a definition set with many Stubs with
the Journal on, at fixed arrival rates under the CPU and memory limits of
small GKE Autopilot Pods, and checks the provisional performance targets.
[bench/README.md](bench/README.md) says how to run it on a machine, on GKE
Autopilot and in CI, what a run writes and how to compare runs. The
[chart's sizing table](charts/smock/README.md#sizing) has what it measured.

## Licence

Apache-2.0. See [LICENSE](LICENSE). The binary also holds third-party
software under its own licences, which [NOTICE](NOTICE) names. The image
holds both files under `/usr/share/doc/smock/`, and each release attaches
them next to the binaries.
