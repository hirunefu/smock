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
  the Ephemeral Stubs per Mock and Session and the Journal, with its bound,
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
  lists and the times of the files it reads) may have changed since the
  last one.
- `metrics`: the metrics registry: counters, gauges and histograms with
  fixed label names, rendered in the Prometheus text format. Features
  register their metrics in the one registry `smock serve` keeps.
- `usage`: understands what Linux says a process and its cgroup use, in
  `/proc/self/stat`, `/proc/self/status` and a cgroup v2's `cpu.stat` and
  `memory.peak`, for the process and cgroup metrics, and where
  `/proc/self/cgroup` puts the process's cgroup, for those and for the
  memory limit the Journal's bound follows. It does no I/O: `server` reads
  the files and hands it their text.
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
to stderr, one JSON object per line; JSON is the only log format. A usage
error, such as an unknown flag, a missing argument or an invalid setting
value, is not a log entry: smock writes it to stderr as plain text, before
any log entry, and exits with status 2. `smock serve --help` lists the
settings:

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
  (`nonvoluntary_ctxt_switches` of `/proc/self/status`). The CPU time the
  hypervisor gave to something else while the machine's CPUs had something
  to run, `smock_node_cpu_steal_seconds_total` (`steal` of `/proc/stat`, to
  the hundredth of a second): the machine's, all its CPUs together, not
  smock's, and 0 on bare metal; in a container, its node's. Together they
  tell a smock that waited for a CPU on a busy node from one that needed
  more CPU. On cgroup v2, the metrics of smock's own
  cgroup, the one `/proc/self/cgroup` names: from its `cpu.stat`,
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
  `POST /v1/reset` clears them and Journal entries
  ([below](#sessions-and-ephemeral-stubs)).
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
how Stubs match requests (method, path, query parameters, headers and
body, exactly, by RE2 pattern or as JSON), the order they are tried in (priority, then
file-name order), what a Mock answers when nothing matches, responses with
inline bodies, body files, JSON or Server-Sent Events, response templates,
Faults, the JSON Schema, editor support and writing Definition files in
another configuration language.

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
- `GET` lists and `DELETE /v1/mocks/{mock}/stubs/{id}` deletes the calling
  Session's Ephemeral Stubs of the Mock. `POST /v1/reset` with
  `{"scope":"session"}` clears the calling Session's Ephemeral Stubs and
  [Journal](#the-journal) entries of every Mock, and its eviction count;
  `{"scope":"mock","mock":"users"}` every Session's of one Mock, even one
  that a reload removed while the Journal holds its entries; and
  `{"scope":"all"}` all of them, and every eviction count. It answers how
  many Ephemeral Stubs and Journal entries it removed.
- Ephemeral Stubs live in the process that received them, until a reset or
  a restart. They survive a [reload](docs/definition-files.md#reloading) of
  the Definition files, except those of a Mock the new files no longer
  declare.
- Adding, deleting and resetting each write a log entry (`Ephemeral Stub
  added`, `Ephemeral Stub deleted`, `reset`); requests write none.

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
  Stub, so that equal IDs cannot be confused; the status, or the
  connection Fault; when the request was received and how long the response
  took; and the digest of the definition set that answered. A request for
  a Host that no Mock answers is recorded too, with no Mock; one the
  HTTP/1.1 codec rejects (400, 413, 431, 501 or 505) is not.
- A request is in the Journal as soon as its client has the whole
  response: smock records it just before it writes the response's last
  bytes, so a query made right after a call always finds it. A stream of
  Server-Sent Events is recorded when its last event is written, and a
  request ended by a connection Fault when the connection closes.
- The filter takes a Mock, a method, a path and headers, with the
  semantics of Stub conditions (exact or `{ "pattern": … }`), and a time
  range on when the request was received: `since` (included) and `until`
  (excluded), as RFC 3339 date-times. Every member is optional. Entries
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
release's tag. With cosign 2.6 or later:

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
and attest the image, verify it with `scripts/verify-image.sh`, push the
Helm chart packaged by `scripts/package-helm-chart.sh`, and create the
GitHub release with notes from `scripts/release-notes.sh`. It never runs
on pull requests. Started by hand from the Actions tab, it builds and
smoke-tests everything and keeps the binaries, images, chart and notes as
workflow artifacts, but publishes nothing. `scripts/check-release-workflow.sh`, run in
CI, checks those rules. After the first release, make the
`ghcr.io/hirunefu/smock` and `ghcr.io/hirunefu/charts/smock` packages public
in their settings; GitHub creates them private.

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
`smock --version`. Then, without certificate files, it checks HTTPS with
the self-signed certificate smock generates, on the same read-only root
filesystem. It also checks that the image adds nothing to its base but
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
[Run it on your machine](#run-it-on-your-machine)). Where a scope cannot
get the limit, it prints why it skipped and passes.

`SMOCK_VERSION` and `SMOCK_COMMIT` set the version and the commit that a
native build, such as `scripts/build-release.sh`, records in the binary.

## Benchmark

The release benchmark measures smock's real request path: realistic
requests, matched against a definition set with many Stubs, with the
Journal on. It sends them at a fixed arrival rate and reports p99 and p99.9
latency for each case, and checks the provisional performance targets.

| File | What it is |
|---|---|
| `bench/bench.py` | Runs the benchmark. |
| `bench/definitions/` | The definition set smock serves: four Mocks, one of them the Default Mock, and about 1,200 Stubs with exact, pattern and `json` conditions (`e2e/bench_test.mbt` pins the exact count). `bench/gen_definitions.py` writes it. |
| `bench/requests.json` | The request mix: nine kinds of request, with weights, realistic headers, a Session in `baggage`, and bodies. |
| `bench/plan.json` | The cases, the CPU limits, and the rates and durations. |
| `bench/plan-autopilot.json` | Another plan: smock under the CPU and memory limits of the smallest GKE Autopilot Pods and of the Helm chart's default, at ladders of rates. The targets hold under its profiles. |
| `bench/targets.json` | The provisional targets, a set for each CPU architecture, the one place to change them, and the rule that calls a change between two runs a regression. |
| `bench/compare.py` | Compares two runs: p99 and p99.9 at each step both ran, and the targets the newer one missed. |
| `bench/gke/` | The GKE Autopilot run's helper (`gke.py`: its plan, cost estimate, manifests and summary), its load generator (`generator.py`), and what its two images add. |
| `scripts/gke-bench.sh` | Runs the benchmark on GKE Autopilot, end to end. |

`e2e/bench_test.mbt` checks on every test run that each request of the mix
reaches the Mock and the Stub it names, on the plain and on the TLS port,
and lands in the Journal under its Session. CI checks that
`bench/definitions/` is what `bench/gen_definitions.py` writes.

The benchmark runs on a developer's machine. The full run of
`bench/plan-autopilot.json`, a run on GKE Autopilot, and their comparison
with the previous ones are part of the checklist before an integration
branch is merged into `main`,
[docs/merging-into-main.md](docs/merging-into-main.md). Nothing runs it on
a schedule.

### Run it on your machine

It needs Linux on amd64 or arm64 with at least three CPUs, python3 3.10 or
later, `openssl`, `taskset` and `lscpu` (util-linux), oha 1.16.0 on `PATH`
(`scripts/install-oha.sh` installs it into `~/.local/bin`, checked against
its digest), and a systemd user manager that can set CPU quotas and memory
limits: `cpu` and `memory` must be in
`/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers`.
Recent systemd delegates them by default; otherwise add a drop-in for
`user@.service` with `Delegate=cpu cpuset io memory pids`.

```sh
scripts/build-release.sh                 # dist/smock, which the benchmark runs
python3 bench/bench.py run               # the whole plan, about 20 minutes
python3 bench/bench.py run --cases http-keep-alive --cpu-limits 1   # one case under one limit
python3 bench/bench.py run --plan bench/plan-autopilot.json            # the profiles the targets hold under, about 20 minutes
python3 bench/bench.py run --plan bench/plan-autopilot.json --profiles autopilot-burst-min   # one profile
python3 bench/bench.py run --rate 500 --ramp 1 --duration 3 --tail 1 --settle 1 --cooldown 0   # a check of the setup, about 2 minutes
python3 bench/bench.py check-targets bench/results/<date>-<time>   # an earlier run against the targets as they are now
python3 -m unittest discover -s bench -v # the harness's own tests, about 5 minutes
```

`python3 bench/bench.py run --help` lists the options. A run first prints
how long it will take, then writes to `bench/results/<date>-<time>/` unless
`--out` says otherwise. Options that change the plan's rates or durations
are for checking the setup: the run records them, and the summary says it
was not a full run. For numbers worth comparing, close other programs and
plug a laptop in; the conditions record the CPU frequency governor.

### GKE Autopilot profiles

`bench/plan-autopilot.json` runs smock as it would run in the smallest
general-purpose GKE Autopilot Pods and in a Pod with the Helm chart's
default resources, simulated on your machine with the same cgroup limits:

| Profile | CPU limit | Memory limit | What it is |
|---|---|---|---|
| `autopilot-burst-min` | 50m | 52 MiB | The smallest Pod where Pods may burst. |
| `autopilot-min` | 250m | 512 MiB | The smallest Pod where they may not. |
| `chart-default` | 1 | 1 GiB | The Helm chart's default requests and limits, which Autopilot takes as they are. |

A CPU limit equal to the request is a CFS quota over a 100 ms period, as
here: under 50m, smock may run 5 ms in every 100 ms. smock runs with its
defaults, so if they do not fit a memory limit, the run shows OOM kills
rather than hiding them; the Journal's byte bound follows the memory limit
([The Journal](#the-journal)): 13 MiB under 52Mi, 64 MiB under the others.
Each profile measures idle RSS, then plain HTTP and TLS with keep-alive
connections, each at a ladder of fixed rates from 2,500 to 80,000 requests
a second per CPU (125 to 4,000 under 50m), 20 seconds a step. The top of
each ladder is about where smock uses up its CPU over TLS. Plain HTTP's
ladder also has 30,000 a second per CPU, so that it has the rate of each
profile's arm64 [targets](#targets) (250, 5,000 and 30,000; the amd64
ones, 125, 1,250 and 10,000, are on every ladder), and 50,000 a second per
CPU, by which smock had used up its CPU under each profile in the arm64
GKE probe those targets come from. A full run takes about 20 minutes; it
prints its estimate before it starts.

Before a full run:

- Plug the laptop in, and close heavy programs (browsers, builds, other
  benchmarks): smock and the load generator share this machine.
- Set the CPU frequency governor to `performance`, in a terminal of your
  own, since it needs root, and set it back afterwards (to the one
  `scaling_governor` had, such as `schedutil`):

  ```sh
  echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  scripts/build-release.sh
  python3 bench/bench.py run --plan bench/plan-autopilot.json
  echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
  ```

The numbers are this machine's: the quota and the memory limit are the
Pod's, but the CPU is not the one GKE schedules the Pod on, and the load
comes over loopback, not a Pod network. Absolute numbers differ from GKE's;
compare profiles with each other, and runs on the same machine. The summary
says so too.

### Targets

smock's performance targets are provisional, and there is a set for each
CPU architecture: x86 (amd64), the architecture of the maintainer's
production environment, and Arm (arm64). `bench/targets.json` holds both,
says where each comes from, and is the one place to change them. A run
checks the set of the architecture it ran on: a run on a machine, the
machine's (an M1 is arm64); a GKE run, its nodes' (`--arch`). A run on an
architecture with no set reports every target as not measured, and says
why; `check-targets` (below) refuses to pass it. Each target holds under a
profile of `bench/plan-autopilot.json`, with plain HTTP over keep-alive
connections at one rate:

| Architecture | Profile | CPU and memory limits | Rate | p99 at most | p99.9 at most |
|---|---|---|---|---|---|
| amd64 | `chart-default` | 1, 1 GiB | 10,000 requests/s | 10 ms | 20 ms |
| amd64 | `autopilot-min` | 250m, 512 MiB | 1,250 requests/s | 100 ms | 200 ms |
| amd64 | `autopilot-burst-min` | 50m, 52 MiB | 125 requests/s | 100 ms | 300 ms |
| arm64 | `chart-default` | 1, 1 GiB | 30,000 requests/s | 3 ms | 10 ms |
| arm64 | `autopilot-min` | 250m, 512 MiB | 5,000 requests/s | 3 ms | 5 ms |
| arm64 | `autopilot-burst-min` | 50m, 52 MiB | 250 requests/s | 3 ms | 50 ms |

On both, under every profile, smock's idle RSS is at most 20 MiB, and its
peak memory at the target's rate (`memory.peak`) at most 32 MiB. Under
`autopilot-burst-min`, the kernel may not OOM-kill it at that rate.

- **amd64** comes from three runs on GKE Autopilot, two on 2026-10-14 and
  one on 2026-10-15 with a smock that spends less CPU on each request, in
  general-purpose x86 Pods on ek-standard-8 nodes in us-central1-a, where a
  vCPU is a hyperthread. Under 1 CPU, smock kept up with about 19,000 to
  21,000 requests/s over plain HTTP and 14,000 over HTTPS. At 10,000, p99
  was 3.8 ms and p99.9 5.8 ms in the third run, with smock at 75% of its
  CPU limit (p99 12.9 and 4.2 ms, p99.9 22 and 11.7 ms in the first two);
  at 20,000, requests queued for seconds. Under 250m and 50m, the CFS quota
  showed in the slowest requests even at light load, and varied from run to
  run (p99 69 ms at 625 requests/s under 250m in one run; 3.3 to 45 ms at
  125 under 50m), hence their loose targets. Only the third run measured
  memory: idle RSS 16.2 to 16.3 MiB, and peak memory 27 MiB at 10,000
  requests/s under 1 CPU.
- **arm64** comes from a one-off probe on GKE Autopilot, in arm64
  general-purpose Pods on e4a nodes in us-central1, at the plain HTTP rates
  of `bench/plan-autopilot.json` (all but 30,000 a second per CPU, added
  since): under each profile, smock kept up with a rate at or above its
  target's, and under 50m the slowest requests took tens of milliseconds
  even at light load, hence its p99.9 of 50 ms. Per vCPU, Arm served about
  2.5 times what x86 did on GKE under 1 CPU (about 50,000 against 19,000
  to 21,000 requests/s), and 2 to 3.5 times under 250m and 50m. Runs on
  an M1 MacBook Air over loopback do better still: p99 and p99.9 stay about
  2 ms around each target's rate, and each profile keeps up with more than
  twice it.

The [chart's sizing table](charts/smock/README.md#sizing) has the numbers
of each.

Latency counts from each request's scheduled send time, as the harness
measures it, so it includes the load generator's floor: oha's timer has a
resolution of 1 ms, which adds about a millisecond at p50 and about 2 ms at
p99, whatever smock does. The targets absorb it, so a p99 of 3 ms leaves
smock about a millisecond. The latency from release, reported beside it,
shows what smock itself adds; a target below the floor would need a load
generator that paces requests more finely than 1 ms.

A full run of `bench/plan-autopilot.json` measures every target of its
architecture; on GKE, idle RSS and peak memory come from smock's own
[process and cgroup metrics](#admin-api), so a smock without them leaves
those two unmeasured. A run of `bench/plan.json`, as in CI, runs none of
these profiles, and reports each target as not measured.

To check an earlier run against the targets as they are now, such as after
they changed, without running anything:

```sh
python3 bench/bench.py check-targets bench/results/<run>   # a results directory, or its summary.json
```

It reads the run's `summary.json`, and the architecture it ran on from
`conditions.json` beside it, checks the set of that architecture (of
`--targets FILE` if given), and prints the *Targets* section of
`summary.md` to stdout. It changes nothing in the run's directory. It exits
with 1 when a target is missed, and with 2 when it cannot check: a summary
of another `format`, no `conditions.json` beside it, or a run on an
architecture the targets file has no set for.

### What a run does

- **Profiles.** A resource profile is a CPU limit and, optionally, a
  memory limit. In `bench/plan.json` each CPU limit is a profile, named by
  it, with no memory limit; `bench/plan-autopilot.json` names its profiles
  and gives each a memory limit. `--profiles` and `--cpu-limits` select some.
- **Idle RSS.** smock starts with the benchmark's definitions under a
  profile: in `bench/plan.json` the 1-CPU one, in
  `bench/plan-autopilot.json` each. Once it is ready and has idled for 5
  seconds, its RSS is the idle RSS.
- **Cases.** Each case of the plan runs under each profile it has a rate
  for, or a ladder of rates, one step for each from the lowest. In
  `bench/plan.json`, the profiles are 250m, 500m, 1 and 2 cores, and the
  cases are plain HTTP and TLS with keep-alive connections, plain HTTP and
  TLS with a new connection per request, plain HTTP with 1000 idle
  connections held open during the load, and a 10-minute run under 1 CPU
  that records RSS every second.
- **CPU limits and pinning.** smock runs in its own systemd scope with a
  CPU quota over the 100 ms period Kubernetes also uses, pinned to the
  fastest CPUs, as many as the largest CPU limit of the plan needs (two for
  `bench/plan.json`). The load generator and the harness run on the other
  CPUs. The run reads the quota back from smock's cgroup and stops if it
  did not take effect.
- **Memory limits and OOM kills.** Under a profile with a memory limit, the
  scope also gets `MemoryMax` and `MemorySwapMax=0`, so smock cannot swap,
  as in a Kubernetes container. The run reads `memory.max` and
  `memory.swap.max` back and stops if they did not take effect. It records
  smock's peak memory (`memory.peak`, all that `memory.max` counts: the
  Journal, socket buffers and page cache included) and how many times the
  kernel OOM-killed it, from `memory.events` of a slice that holds only
  smock's scope, which outlives it. An OOM kill does not stop the run: a
  case whose smock was killed before it was ready sends no load, and each
  request of its window counts as an error.
- **Fixed arrival rate.** oha sends each kind of request at its weight's
  share of the case's rate and connections. Its schedule releases request
  `i` at `i / rate` whether or not a connection is free to send it, and a
  request's latency counts from that time, when it was due. A request that
  waits behind a busy or stalled smock counts its wait, and so does one
  that oha releases late because it fell behind, as it can when a stalled
  smock answers a burst at once.
- **Latency from release and generator lag.** Beside the latency, each
  case reports the latency from the time oha actually released each
  request, and the generator lag, how late it released them: the latency is
  their sum. oha's timer has a resolution of 1 ms, so it releases requests
  about a millisecond late, and the scheduler adds a few milliseconds now
  and then. When the lag's p99.9 is over 5 ms or its maximum over 10 ms, the
  load generator fell behind its schedule, and the case says so
  (`load_generator_late`).
- **What oha's timer means for the targets.** Since every latency includes
  the generator lag, about a millisecond at p50 and 2 ms at p99, no
  latency can be measured below that floor, whatever smock does. The
  [targets](#targets) absorb it.
- **Window.** Requests scheduled in the first 2 seconds, while connections
  open, are not counted. The next 20 seconds are measured, and 3 more let
  the last of them finish.
- **Errors.** A request scheduled in the window that did not get the status
  `bench/requests.json` expects is an error, whether it got another status
  or no response.
- **Targets.** Each target of `bench/targets.json` for the machine's
  architecture is met, missed or not measured, with the reason. It holds
  under one profile, by its name and its CPU and memory limits: a run that
  did not run that profile with those limits does not measure it. The
  latency, peak memory and OOM-kill targets hold at one load, one case at
  one rate under the profile, and a run that did not run that step does
  not measure them. An OOM kill misses every
  target of its step. A latency target, counted from the scheduled send
  times, is not measured when the load generator fell behind, and missed by
  any error. Peak memory over its bound misses its target; within it, it is
  not measured if requests failed, since smock did not carry the load. The
  idle RSS target holds for the idle RSS under the profile.

### What a run writes

- `conditions.json`: what ran where. The smock version, commit, toolchain
  and binary digest; the definition set digest and the Mocks; the request
  mix; the plan file, with its SHA-256 and that of the plan without its
  `about` (`sha256_without_about`); the architecture, CPU model, kernel
  and CPU governors; the profiles with their CPU and memory limits, the CPU limits
  and the CPUs of smock and of the load generator; each case's profile,
  rate, durations and connection counts; oha and its version; the targets
  file; any options that changed the plan.
- `summary.json`: for each case at each rate (its `id` is
  `<case>@<profile>`, and `@<rate>` when it climbs a ladder), the latency
  from the scheduled send times and the latency from release (each p50,
  p90, p99, p99.9, max), the generator lag (p50, p99, p99.9, max) and
  whether the load generator fell behind, the achieved rate, the errors by
  kind, each second of the load from its start, ramp and tail included
  (`per_second`: how many of the requests due in that second got a
  response, `requests`, and their p99 from the scheduled send times,
  `p99_ms`, so that a burst at the start, a stall now and then and a step
  slow all through look apart), smock's CPU use and throttling
  (`smock_cpu`: from its cgroup's `cpu.stat`, with the requests smock
  answered meanwhile, from `smock_requests_total`, what the CPU time comes
  to a request, `us_per_request`, and against the CPU limit,
  `utilization`, the CPU time its process counted, `process_s`, from its
  `/metrics`, as a cross-check, how long smock's main thread waited for a
  CPU, `scheduling_delay_s`, how many times the kernel took the CPU from
  it, `involuntary_context_switches`, and the machine's steal time,
  `node_steal_s`, from its `/metrics`, and the same for the step's first
  second, `first_second`, read a second into the load, when connections
  open and TLS handshakes come at once), the quota, memory limit and CPUs
  read while it ran,
  smock's peak memory and OOM kills (`memory`), whether smock got ready,
  smock's RSS (first, last, max), the TCP connections the machine accepted
  during the load, and the idle connections still open at its end. Then
  the idle RSS under each profile, with peak memory and OOM kills, and
  each target with its architecture and profile, its verdict, what was
  measured and why when that is not plain. `format` numbers the layout.
- `summary.md`: the same for people, a section for each profile. Its
  *Targets* section says which architecture's targets it checked.
- `raw/<profile>/<case>/` (`<case>@<rate>` for a ladder's steps):
  `latency.json`, a histogram of the latencies from the scheduled send
  times in microseconds to three significant digits; `rss.json`, smock's
  RSS over time; smock's log; and oha's own report for each kind of
  request. `raw/<profile>/idle-rss.json` has the RSS samples of the idle
  measurement.

### Comparing runs

```sh
python3 bench/compare.py <older> <newer>   # each a results directory, or its summary.json
```

`bench/compare.py` reads two runs' `summary.json` and prints a report in
Markdown, ready to post. For each step both runs ran, a case under a
profile at a rate, it shows p99 and p99.9 in each and how they changed.
A step is a **regression** when either got worse by more than 20% and by
more than 1 ms: a change within a millisecond is within what oha's 1 ms
timer resolves, whatever its percentage. The rule is the `regression`
entry of `bench/targets.json`, next to the targets.

Only numbers that hold still from run to run count; where they do not, two
runs of the same smock can differ by more than 20%:

- **Only steps at or below the target rate count.** The rate of a
  profile's entry in `bench/targets.json` for the newer run's architecture
  (for `autopilot-min`, 1,250 requests/s on amd64 and 5,000 on arm64; the
  highest, if a profile has several) holds for every case of that profile.
  Above it smock may be past its capacity, and the latencies of a queue
  swing from run to run: those steps are listed under *For reference*, with
  the same columns, and never fail the comparison. A profile with no
  entry counts at every rate, and so does every profile when the file has
  no targets for the newer run's architecture or its `conditions.json` is
  missing.
- **p99.9 counts only on at least 10,000 requests**, measured at the step
  in both runs (`p99_9_min_requests` in the rule). With fewer, it rests on
  the few slowest requests: the 3rd slowest of 2,500, the 5th of 5,000.
  Its change is still shown, marked *for reference*, and p99 still counts.

The line above the table says which steps count.

- A step is not compared where the older run did not measure smock: when
  requests failed in it (past smock's capacity, the latencies measure the
  queue), or the load generator fell behind, or smock was not ready. Nor
  when the newer run's load generator fell behind, or the profile ran under
  other limits.
- Requests the newer run failed at a step the older one measured are a
  regression, and so is a smock that was not ready. Above the target rate
  they are listed for reference.
- Steps only one run has are listed, not compared.
- Where both runs measured smock's CPU time a request at a step, a *CPU
  per request* section shows it and its share of the CPU limit in each,
  and how it changed. It is there for information: it fails nothing, and
  another machine or CPU model gives other numbers.
- A step the older run measured and the newer one did not, because the
  newer run left it out or stopped before it, or its load generator fell
  behind, fails the comparison: nothing says how smock did there. Above
  the target rate it is listed and does not fail it.
- It lists each target the newer run missed, with what it measured and
  what the older run did for the same target (the same id at the same
  load, for the same architecture), and the targets it did not measure.
- From each run's `conditions.json`, it names the runs (smock's version and
  commit, the machine, the plan) and lists the conditions besides smock
  that differ, such as the architecture, the CPU model, the plan or oha.
  The plan differs when what it runs differs: the comparison takes the
  hash of the plan without its `about`, so that a change to the
  description alone is no difference. A run from before runs recorded
  that hash has only the file's, which the comparison then takes, so the
  first comparison with such a run shows the plan as changed if anything
  in its file changed, its `about` included (as that of
  `bench/plan-autopilot.json` did after the R1 runs).
  Compare runs of the same kind: a GKE run with a GKE run, a run on a
  machine with a run on the same machine. It says so when one run is on
  GKE and the other is not.
- Of two GKE runs, it says under each profile whether smock's node had
  another CPU in the newer run: its model (with its family, model and
  stepping, which tell apart the generations a virtual machine's model
  name may not), microcode, TLS flags or the kernel's mitigations of its
  vulnerabilities, each where it changed; where smock's node had the same
  CPU; and where a run did not record it, as runs before the nodes' CPUs
  were recorded did not. A latency that changed with the node may be the
  node's rather than smock's. It fails nothing.
- Runs on different CPU architectures, such as an arm64 GKE run and an
  amd64 one, are not compared step by step: their latencies differ by more
  than smock, so no step is a regression, nor a step the newer run left
  out. The report says so, and still lists the targets the newer run
  missed, which fail it.

It exits with 1 when it finds a regression, a missed target or a step that
counts and the newer run did not measure, and with 2 when it cannot
compare, such as for a summary of another `format`.

### On GKE Autopilot

`scripts/gke-bench.sh` runs `bench/plan-autopilot.json` on real GKE
Autopilot: smock in a Pod with each profile's limits as its requests, the
load from another node over the Pod network. It is part of the
[checklist before merging into main](docs/merging-into-main.md), and costs
money: about $0.22 to $0.26 a run on x86 nodes (us-central1 or
asia-northeast1), and about $0.18 on Arm nodes in us-central1, at the
on-demand prices of 2026-10-16, which it estimates before it makes
anything. Both architectures' Pods run on Autopilot's container-optimized
compute platform, Arm ones through the `autopilot-arm` compute class, and
the pricing page bills that platform's Pods at one rate for both.

```sh
export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1
scripts/gke-bench.sh --dry-run    # the checks, the estimate, and every command it would run; reads only
scripts/gke-bench.sh              # the checks and the estimate; makes nothing
scripts/gke-bench.sh --yes        # runs it, about 50 minutes
```

It needs gcloud (logged in), docker, kubectl, python3, setsid, and to
build the release binary the MoonBit toolchain (or `--smock` with a
binary). `GCLOUD`, `KUBECTL`, `DOCKER` and `PYTHON` name other commands
than those on `PATH`. `scripts/gke-bench.sh --help` lists its options: the
nodes' architecture, some profiles or cases only, another plan, the results
directory, the time limit.

A run is on nodes of one architecture, `--arch amd64` or `--arch arm64`,
by default the machine's that runs the script. Autopilot runs x86 (amd64)
Pods in every region, and Arm (arm64) Pods only in us-central1, us-east1,
us-west1, europe-west1, europe-west2, europe-west4 and asia-southeast1
(GKE's documentation, 2026-10-14): an arm64 run needs one of those, and
the script warns when its region is not one. x86 capacity is plentiful,
and an Arm run once failed for want of Arm nodes in its zone. To run on
x86 nodes from an arm64 machine, which cannot build smock for amd64, as
the pre-merge run does in us-central1-a, take the release binary that CI
built for linux/amd64 from the commit checked out, from CI's run on the
push of that commit (CI keeps it for 7 days):

```sh
gh run list -R hirunefu/smock --workflow CI --branch integration/r1 --event push --limit 1 --json databaseId,headSha
dir=$(mktemp -d)
gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir "$dir"   # writes $dir/smock
export GKE_BENCH_PROJECT=<project ID> GKE_BENCH_REGION=us-central1 GKE_BENCH_ZONE=us-central1-a
scripts/gke-bench.sh --dry-run --arch amd64 --smock "$dir/smock"
scripts/gke-bench.sh --yes --arch amd64 --smock "$dir/smock"
```

The run's `headSha` must be the commit checked out. A run on a pull request
builds its merge commit instead, so take the run on the push; the script
refuses a binary built from another commit. The artifact is there only if
that run's linux/amd64 build and tests passed.

- **Checks, before anything is made.** It checks that smock and oha, when
  given, are ELF executables of the run's architecture (from their
  headers; they are not run), and that smock is built from the commit
  checked out: as it says (`smock --version`) when the machine can run
  it, else as its build information names it, read from the binary
  without running it; of a smock it cannot run, it also prints the
  SHA-256, which `conditions.json` records too. For
  another architecture than the machine's, it checks that the images'
  Dockerfiles only copy, since a `RUN` would need emulation. It reads the
  project, checks that the Artifact Registry, Compute Engine and
  Kubernetes Engine APIs are enabled (it prints the command that enables
  them; `--enable-apis` runs it), that `GKE_BENCH_ZONE`, when set, is in
  the region, that the quotas the run's nodes draw on have enough free,
  and that no cluster or repository of an earlier run is left. The run
  needs four nodes of 8 vCPUs: Autopilot's first node, its system node,
  smock's and the load generator's (in the probe, a quota of 24 vCPUs held
  the load generator's node back). Autopilot's two are x86 nodes on either
  architecture; smock's and the load generator's are of the run's. So it
  needs 32 vCPUs free in `CPUS_ALL_REGIONS` (`GKE_BENCH_NEEDED_CPUS`, from
  which the number of nodes follows); in the region's `CPUS`, 8 for each
  x86 node; 100 GB of boot disk a node, in the region's `SSD_TOTAL_GB` for
  an x86 node (pd-balanced, GKE's default) and in `HDB_TOTAL_GB` for an
  Arm node (hyperdisk-balanced, as the probe's Arm nodes had); and an
  external IP address a node, in `IN_USE_ADDRESSES`. An Arm node's vCPUs
  count in a CPU quota of its machine family, which gcloud does not list:
  an arm64 run says that it is not checked, and the console's Quotas page
  shows it. It names each quota with how much is free and how much the
  run needs, and says which is short or cannot be read. Then it prints how
  long the run takes and what it costs, expected and at most, and stops
  unless `--yes` says to go on.
- **Images.** It builds the release binary, unless given one, and two
  images for the run's architecture (`docker build --platform`): the
  release image with `bench/definitions/`
  (`bench/gke/smock-definitions.dockerfile`), and the load generator's
  (`bench/gke/generator.Dockerfile`: Python, the pinned oha of that
  architecture, `bench.py`, the plan and `bench/gke/`). Both only copy
  files onto multi-architecture bases, so a machine of the other
  architecture builds them with no emulation; `python3 -m unittest
  discover -s bench` fails if a `RUN` appears. It pushes them to a new
  Artifact Registry repository, and lets the nodes' service account (the
  project's Compute Engine default one, or
  `GKE_BENCH_NODE_SERVICE_ACCOUNT`, which the nodes then run as) read that
  repository only.
- **Cluster.** A new Autopilot cluster on the Regular channel. The cluster
  and the repository are named `smock-bench-<date>-<time>` and labelled
  `purpose=smock-bench`. kubectl authenticates with an access token from
  gcloud, in a kubeconfig of the run's own (mode 600, deleted at the end),
  so gke-gcloud-auth-plugin is not needed and `~/.kube/config` is not
  touched.
- **Profiles.** For each profile: smock in a Pod, with the profile's CPU
  and memory limits as its requests, behind a ClusterIP Service, both
  named for the profile (`smock-<profile>`), so that a lookup of the name
  cannot get the address of the previous profile's Service; then the load
  generator (`bench/gke/generator.py`) in a Job with 6 vCPU and 6 GiB on
  amd64 (an x86 vCPU is a hyperthread, and 4 fell behind at 20,000
  requests a second), 4 vCPU and 4 GiB on arm64, either within an 8-vCPU
  node, and a required anti-affinity that keeps it off smock's node. Both
  have an `activeDeadlineSeconds` that ends them within minutes of the
  time limit at the latest, so that they stop being billed even if nothing
  is left to delete the cluster (smock is a Pod, not a Deployment, to have
  one). Both run on nodes of the run's architecture: the built-in
  `autopilot-arm` compute class on arm64, Autopilot's default
  general-purpose x86 Pods on amd64. Autopilot chooses smock's zone, and a
  required Pod affinity keeps the load generator in it; `GKE_BENCH_ZONE`
  pins both to one zone instead. Before smock starts, an init container
  in its Pod, from the load generator's image and with smock's limits so
  that the Pod asks for no more, prints the CPU of smock's node
  (`bench/gke/gke.py node-cpu`): its model name, vendor, family, model and
  stepping (on arm64, its implementer, part, variant and revision), its
  microcode, whether it has the flags that make TLS fast (`aes`, `avx2`,
  `sha_ni` and `vaes` on x86; `aes`, `pmull` and `sha2` on arm64), and
  what the kernel says of each of its vulnerabilities, from
  `/proc/cpuinfo` and `/sys/devices/system/cpu/vulnerabilities`. It
  succeeds whatever it can read, so that smock always starts. The load
  generator says the same of its own node. The load generator sends each
  step the way `bench/bench.py` does, with its functions, and prints one
  JSON line for each step, a case as `summary.json` has it. It looks up the
  Service's address once smock answers by name. Before any load, once
  smock has idled for the plan's settle time after it was ready, it reads
  smock's idle RSS from smock's `/metrics`. Before the first step it
  sends the first request of the mix to the plain and the TLS port there,
  for up to 60 s each until it gets a response; after a step that got no
  response at all, it checks again, since an overloaded smock can answer
  none of a step's measured requests and still be there. When a port does
  not answer, it runs no further step of the profile: the summary marks
  the steps it did not run as not measured, with the reason, and the run
  goes on to the next profile once the load generator's Job and smock's
  Pod and Service are deleted (it waits for that), and exits 1, as it does
  whenever a step of the plan was not measured.
  The namespace's quota allows no LoadBalancer, NodePort or volume claim,
  and the run makes no static IP.
- **Always deleted.** When the run ends, fails or is stopped (Ctrl-C,
  SIGTERM, a closed terminal), it deletes the cluster and the repository;
  after a closed terminal it logs that to `after-hangup.log` in the results
  directory. A watchdog in its own session deletes them at the time limit
  (`--time-limit` with its unit, 80m by default and at most 240m) even if
  the script was killed; nothing is made until the watchdog has started.
  At the end it lists the project's clusters, repositories, VM instances,
  disks, addresses and forwarding rules, and fails, naming them, if any is
  new since the start.
- **When the machine goes away.** The watchdog runs on the machine that
  runs the script: if that machine sleeps, loses its network or shuts down,
  nothing deletes the cluster until it is back. Keep it awake and on power
  for the run (on Linux, for example, under `systemd-inhibit`). The Pods
  still end soon after the time limit, so a cluster left this way costs
  its fee, $0.10 an hour, until deleted (the free tier covers one
  cluster); a later `scripts/gke-bench.sh --dry-run` names it.
- **Architectures.** The images are for `--arch`, whatever the machine
  that runs the script: smock's binary for another architecture comes from
  CI (`--smock`, above), and oha's is the pinned release of that
  architecture (`scripts/install-oha.sh <directory> <arch>`). The run
  records the architecture, the region, the zone and the nodes' machine
  types in `conditions.json`; `bench/compare.py` says when two runs differ
  in architecture, and does not compare their latencies as regressions.

It writes to `bench/results/gke-<date>-<time>/` unless `--out` says
otherwise: `raw/<profile>/generator.log`, the load generator's lines;
`raw/<profile>/pods.json`, the nodes the Pods ran on (with each one's
boot disk type, `boot_disk`), smock's restarts and the load generator's
CPU request; `raw/<profile>/smock.log`, smock's log
(and the log of its container before its last restart, when it
restarted, with kubectl's errors in their place);
`raw/<profile>/smock-node-cpu.log`, what smock's init container printed
of the CPU of its node; and
`raw/<profile>/service.json`, its Service with the Service's
EndpointSlices, all three kept before smock's Pod is deleted;
`summary.json` in the layout of a run on a machine, which
`bench/compare.py` reads; `summary.md`; `conditions.json`; and
`watchdog.log`. The summary and the conditions record, for each profile,
whether the traffic ports answered, whether the profile ended early and
why, and the load generator's CPU request; the conditions also record,
for each node of each profile, its CPU (`cpu`, as `gke.py node-cpu`
prints it, or null when it is unknown), and name the CPU model of smock's
nodes in `machine.cpu_model`, which `summary.md` shows. A run that stops
once a profile has started, because something fails or it is stopped
(Ctrl-C, SIGTERM, a closed terminal), still writes `summary.json`,
`summary.md` and `conditions.json` from what it measured; `summary.md`
then says, right below its first line, under which profile and after
which step the run stopped, and why (`gke.stopped` in `summary.json`).
The summary checks the targets of the run's architecture (`--arch`).
Nothing outside smock's Pod can read its cgroup on Autopilot, so what
smock used comes from its own
`/metrics`, its [process and cgroup metrics](#admin-api), which the load
generator scrapes right before and right after each step, and a second
into it: its CPU time and throttling during the step and in its first
second, from its container's cgroup, with the CPU time a request and
against the CPU limit; how long it waited for a CPU, and its node's steal
time; its RSS at the step's start and end,
the larger as its max; and the most memory its container had used by the
step's end (`memory.peak`), since smock started under the profile, so
earlier steps count too. A smock without those metrics leaves them, idle
RSS and the targets on them unmeasured. OOM kills come from smock's
restarts. Nothing it writes names the account or the project, and what it
prints shows the project as `$GKE_BENCH_PROJECT` and gcloud's account as
`<account>`.

`python3 -m unittest discover -s bench` tests the helper, the load
generator against smock on this machine, and the script against fake
gcloud, kubectl and docker commands, including that every way a run ends
deletes what it made.

### In CI

`.github/workflows/benchmark.yml` runs the benchmark on linux/amd64 and
linux/arm64 when started by hand from the Actions tab, optionally for some
cases or CPU limits only. It builds the release binary, installs oha, lets
the runner's systemd user manager set CPU quotas, runs the harness's tests
and then the whole of `bench/plan.json`, whose profiles have no memory
limits, so it reports the [targets](#targets) as not measured. The output
of each architecture is a workflow artifact, `benchmark-linux-amd64` and
`benchmark-linux-arm64`, and the run's page shows the summaries. It never
runs on a schedule, on pull requests or on pushes:
`scripts/check-benchmark-workflow.sh` checks in CI that it has no trigger
but `workflow_dispatch`. GitHub's shared runners vary from run to run, so a
single run is a rough measure.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
