# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- HTTP/2, beside HTTP/1.1, on the plain and TLS ports, served by the same
  Mocks and Stubs. See [docs/http2.md](docs/http2.md).
  - **h2c on the plain port.** A connection that starts with the HTTP/2
    preface, as `curl --http2-prior-knowledge` sends it, is served over
    HTTP/2, and any other is HTTP/1.1, as before. `Upgrade: h2c` is not
    accepted.
  - **h2 on the TLS port.** A connection whose client chooses `h2` by ALPN
    is served over HTTP/2, with any certificate: the certificate files,
    the self-signed certificate or a Mock's own. Over TLS 1.2, ALPN leaves
    `h2` out when the suite is one RFC 9113 prohibits, such as a CBC suite:
    a client that also offers `http/1.1` gets HTTP/1.1, so a strict client
    does not fail the connection. The admin port stays HTTP/1.1 only.
  - **Requests.** Each stream is a request of its own, with the Host from
    `:authority`, else from the `host` field, and its Session from its own
    `baggage`. SNI still only chooses the certificate, so one connection
    can carry streams for several Mock Hosts. Several `cookie` fields are
    joined into one, so conditions see what an HTTP/1.1 client's one Cookie
    line gives. A stream whose request HTTP/1.1 would refuse gets 400 on
    that stream alone, and the connection's other streams go on. A CONNECT
    reaches the Mocks as soon as its HEADERS arrive, with `:authority` as
    its target, and smock opens no tunnel: a 2xx to it ends the stream
    with no body.
  - **Responses.** A Stub's response follows HTTP/2's rules: header names
    in lower case, spaces and tabs around a value trimmed, and
    `Keep-Alive`, `Upgrade`, `Proxy-Connection` and `TE` left out. HEAD,
    204 and 304 are framed as over HTTP/1.1. A Stub's delay delays only
    its own stream, while the connection's other streams are answered. A
    body larger than the client's flow-control windows goes out as the
    client widens them, so a client with small windows still gets all of
    it.
  - **Server-Sent Events.** An events Stub streams one event stream per
    HTTP/2 stream, several at once on one connection: the DATA of its last
    event ends the HTTP/2 stream, and a client that resets the HTTP/2
    stream ends the event stream at once.
  - **Faults.** A connection Fault takes its nearest HTTP/2 form: `reset`
    resets its stream alone, `partial` sends half the body, or half the
    events, then resets the HTTP/2 stream, and `close` sends GOAWAY and
    closes the connection, with the same draws and seeds as over HTTP/1.1.
  - **Limits and timeouts.** A header list over `--header-size-limit` or
    `--header-count-limit` gets 431, and a body over `--body-limit` 413, on
    that stream alone, while the connection's other streams go on.
    `expect: 100-continue` gets `100 Continue`, as over HTTP/1.1.
    The read timeout applies to each stream alone, and resets only a
    stream whose request is late, with `CANCEL`; an idle connection gets
    GOAWAY before it closes. The write timeout closes a connection whose
    connection window stays at zero, and resets with `CANCEL` a stream
    whose own window does. A client that stops reading makes smock stop
    reading too, once what smock has queued for the connection and not yet
    written passes 16 KiB, and the write timeout then closes the
    connection.
  - **Defences.** A client that sends more than 100 frames that do no work
    in one second, such as a flood of PING or SETTINGS frames, gets GOAWAY
    `ENHANCE_YOUR_CALM`, and smock logs one line that names the pattern.
    So does a header block over twice `--header-size-limit` as received,
    such as a flood of CONTINUATION frames makes, and empty CONTINUATION
    frames count among the frames that do no work. So does a client whose
    streams end reset before smock has finished their responses, by the
    client or by moonhttp for the client's frames, once more than 100 have
    and they are more than half of its streams (Rapid Reset and
    MadeYouReset); smock's own resets never count. The HPACK table smock
    encodes responses with stays at 4,096 octets, however large a table
    the client allows, and a header block that does not decode ends the
    connection with GOAWAY `COMPRESSION_ERROR`.
  - **The drain.** On SIGTERM, each HTTP/2 connection gets GOAWAY and a
    PING, then a second GOAWAY that names the last stream smock received:
    the streams up to it finish, and the client sends the others again on
    a new connection.
  - **Logs.** In the `mockoon` log format, each HTTP/2 request a Mock
    handles gets its `Transaction recorded` line, with `:method` and
    `:path`, after its `Error while serving the content: …` line when its
    Stub's content failed, as over HTTP/1.1. The line comes once the
    stream's response has ended: its last frame, its RST_STREAM or GOAWAY,
    a client's reset, or the end of the connection. A stream that never
    reaches a Mock, such as one refused with 431 or `REFUSED_STREAM`, gets
    none. The format costs about 7 to 10 µs more on each HTTP/2 request
    than `json` on an M1 laptop, 20% to 50% more: under 1 CPU, HTTP/2 over
    TLS at 30,000 requests/s used 88% of the CPU rather than 64%, and its
    latency rose past the performance targets in one of two runs. See
    [Logs](docs/http2.md#logs).
- HTTP/2 comes from moonbitstack/moonhttp 0.14.0 (Apache-2.0), pinned to
  that exact version: CI fails when the build resolves another one
  ([ADR 0005](docs/adr/0005-http2-comes-from-moonhttp.md)). moonhttp and
  the modules it imports are named in NOTICE and the image's SBOM. smock
  is compiled from moonhttp and moonvar. The build also resolves moondate,
  mooncrypt and moonbase, but compiles nothing from them, so NOTICE says
  so and the SBOM gives them `DEPENDS_ON`, not `STATIC_LINK`. The SBOM
  lists every module the build resolves, with the licence of its own
  module file, and CI fails on every push when NOTICE leaves out such a
  module or gives it another version.
- `--http2-max-concurrent-streams` (`SMOCK_HTTP2_MAX_CONCURRENT_STREAMS`),
  100 by default, from 1 to 1000: the most streams an HTTP/2 connection may
  have in progress at once. smock advertises it in its SETTINGS and holds
  the client to it from the first stream; a stream past it gets
  RST_STREAM `REFUSED_STREAM` and never reaches the Mocks. With the body
  limit, it bounds the request bodies one connection holds. See
  [Limits and timeouts](docs/http2.md#limits-and-timeouts).
- `--tls-http2` (`SMOCK_TLS_HTTP2`), `on` by default: `off` takes `h2` out
  of the TLS port's ALPN, for every certificate, so that it offers
  `http/1.1` alone, as before HTTP/2. The plain port still serves h2c. See
  [Turning h2 off](docs/http2.md#turning-h2-off).
- Each `listening` log entry names the protocols its port serves, as
  `protocols`: `["http/1.1", "h2c"]` on the plain port, `["h2", "http/1.1"]`
  on the TLS port (`["http/1.1"]` with `--tls-http2 off`) and
  `["http/1.1"]` on the admin port.
- The Helm chart's `service.appProtocol.plain` and `service.appProtocol.tls`
  set the `appProtocol` of the traffic Service's plain and TLS ports, such
  as `kubernetes.io/h2c` on the plain port for a gateway that speaks h2c to
  smock. Both are empty by default, so no port has one: the plain port
  serves both HTTP/1.1 and h2c. See
  [Ports, Services and probes](charts/smock/README.md#ports-services-and-probes)
  and [Kubernetes and load balancers](docs/http2.md#kubernetes-and-load-balancers).
- The release benchmark measures HTTP/2: `bench/plan-autopilot.json` has
  `h2c-keep-alive`, to the plain port, and `h2-keep-alive`, to the TLS
  port, which are `http-keep-alive` over HTTP/2, sent by oha with
  `--http2`, locally and on GKE. They make each run of the plan about 22
  minutes longer, so `scripts/gke-bench.sh`'s default time limit is now 100
  minutes. Both are held to `http-keep-alive`'s targets, h2 over TLS
  included: an entry of `bench/targets.json` may name several cases
  (`cases`), and a load target's id now names its case, such as
  `chart-default/h2-keep-alive/p99`. A third case, `h2c-multiplexed`,
  measures one connection serving many streams: 16 connections that each
  carry 4 requests at once (oha's `-p 4`, a case's new
  `streams_per_connection`). It has no target, runs only on your machine
  (`local_only`), where it adds about 11 minutes, and the GKE run leaves it
  out. The Benchmark workflow's new `plan` and `profiles` inputs run them
  on GitHub's amd64 and arm64 runners. See
  [HTTP/2 cases](bench/README.md#http2-cases).
- The `smock/http1` module makes public the checks and encodings that its
  parser and encoder use, so that another protocol, such as HTTP/2,
  refuses what HTTP/1.1 refuses and sends the same octets:
  `is_origin_or_asterisk_form`, for a path and query, or `*` for OPTIONS;
  `is_authority_form`, for a host and a port, the target of a CONNECT;
  `is_visible_ascii`, for characters from 0x21 to 0x7E alone;
  `expects_continue`, which tells whether an Expect field value asks for
  `100 Continue`, as its parser reads it; `has_content`, which tells
  whether a response with a status has content; `is_space_or_tab`, for
  the white space around a field value; and `field_octets`, the octets
  `encode_response` writes for a field name or value. They join
  `is_token`, `is_field_value` and `is_host_value`, which were public
  already.
- A Mock's `grpc` field names its Descriptor set, a FileDescriptorSet as
  `protoc --include_imports -o` or `buf build -o` writes it, in the
  body-file subdirectory: `grpc: { descriptorSet: greeter.binpb }`. smock
  reads the set with the Definition files: `smock check`, startup and a
  reload report a set that is missing or does not decode, at the JSON
  Pointer of `descriptorSet`, and a reload swaps the set in with the files.
  The path has the rules of `bodyFile`. The new `smock/protobuf` module
  reads the set. See [Descriptor sets](docs/definition-files.md#descriptor-sets).
- smock reads any self-contained Descriptor set that `buf build` or
  `protoc --include_imports` writes, proto2, proto3 and editions files
  included, and keeps the whole descriptor model, with the JSON names of
  fields. It refuses a set that lacks a file its files import, holds a
  file twice, defines a name twice, or names a type it does not define,
  each a problem at `descriptorSet`. Source info, options other than
  `map_entry`, `packed` and `message_set_wire_format`, and unknown fields
  such as Buf's image extensions cost nothing. Each Mock holds its own
  set. A new guide, [gRPC](docs/grpc.md), says how to build a set.
- gRPC unary calls, on the plain port over h2c. An HTTP/2 request whose
  `content-type` is `application/grpc` is a gRPC call: smock takes its one
  message, decodes it into JSON with the input type of the method its
  `:path` names in its Mock's set, and matches it against the Mock's gRPC
  Stubs on that method, as a `POST` with the metadata as headers and the
  JSON as the body. The reply JSON is encoded with the output type and
  sent as HEADERS, one DATA frame and trailers with `grpc-status: 0`. The
  Journal records the call with its decoded body, whose size counts the
  octets received, and the request metrics count it under its Mock and
  Stub. A call that no Stub matches gets Trailers-Only UNIMPLEMENTED
  `no Stub matched`, with its Near miss in a `smock-near-miss` trailer, in
  the form of the `Smock-Near-Miss` header; the Mock's `noMatch` applies
  to HTTP requests only. For now smock serves messages of singular
  `string`, `bool` and `int32` fields, and answers the calls it does not
  serve yet with Trailers-Only INTERNAL and a fixed message. The new
  `smock/grpc` module frames messages and names gRPC's status codes, and
  `smock/protobuf` decodes and encodes messages. See [gRPC](docs/grpc.md).
- `grpcStatus` in the Journal. A gRPC call's entry records the name of the
  gRPC status the call got, such as `OK` or `UNIMPLEMENTED`, beside its
  HTTP status, which is 200 for a reply and for an unmatched call. An HTTP
  request's entry has none. Queries,
  verification and the unmatched list take calls by their Mock, `POST`,
  the method's path and their metadata as headers. See
  [The Journal and the metrics](docs/grpc.md#the-journal-and-the-metrics).

### Changed

- A client that offers both `h2` and `http/1.1` by ALPN, as most HTTPS
  clients do, now gets HTTP/2 on the TLS port instead of HTTP/1.1: ALPN
  offers `h2`, then `http/1.1`, where it offered `http/1.1` alone. A client
  that offers only `h2`, such as oha with `--http2`, now completes the
  handshake instead of failing it. A client that offers only `http/1.1`, or
  no ALPN, still gets HTTP/1.1. `--tls-http2 off` restores the old
  behaviour.
- The HTTP/2 preface on the plain port now starts HTTP/2, instead of
  getting 505. The Journal's `version` and the Admin API's
  `RecordedRequest.version` can be `HTTP/2`.
- The help texts of `smock_requests_total`,
  `smock_request_duration_seconds` and `smock_unmatched_requests_total`
  speak of a request the protocol layer rejects, and name HTTP/2's
  statuses beside HTTP/1.1's: 400, 413 and 431 on its stream.
- The help texts of `--header-size-limit` and `--read-timeout-ms` give
  their meaning over HTTP/2. A header list is counted as RFC 7541 counts
  it, each field with 32 octets more, and a larger one gets 431 on its
  stream, while a header block over twice the limit closes the
  connection. So a head that fits over HTTP/1.1 can get 431 over HTTP/2
  ([Header lists](docs/http2.md#header-lists)). A request that does not
  arrive in time resets its stream instead of closing the connection.
- The Definition-file Schema's description of a connection Fault's `kind`
  gives its HTTP/2 form beside its HTTP/1.1 one: RST_STREAM on the
  request's stream for `reset`, half the response then RST_STREAM for
  `partial`, and GOAWAY then the close for `close`. The format is
  unchanged. See [Faults](docs/http2.md#faults).
- `scripts/verify-image.sh` also requires moonhttp, and every other module
  that NOTICE names, in each SBOM. It reads NOTICE, so check an image with
  the script and NOTICE of the image's own tag.
- smock is built with the MoonBit toolchain moonc v0.10.20+65efd5b93, up
  from v0.10.17+d971670cd, which `smock --version`, the startup log entry,
  `smock_build_info` and the Admin API status operation name. Its core
  library's NOTICE, which NOTICE quotes, is unchanged, and mimalloc is
  still 2.1.7.
- smock is built with moonbitlang/async 0.22.9, up from 0.22.4, which
  NOTICE names. What smock does is unchanged. The new version takes a
  descriptor off epoll before it closes it, so a read in smock's e2e tests
  no longer fails now and then with EAGAIN while the tests start other
  processes. smock itself starts no process while it serves, so it was
  never exposed.
- smock finds changes to the Definition files and to the TLS certificate
  and key files by polling them every second. It used file events, and
  polled every 10 s as well. As before, a change is read once the files
  have stayed the same for 250 ms, so a change of several files written
  one after the other gives one reload. Files that keep changing are read
  10 s after the change was first seen. A change is now reloaded within
  about 1.25 s (0.8 s at the median in a measurement), where it took about
  250 ms. A change to a name that starts with `.`, or an edit to a file
  smock does not read, such as a README, no longer leads to a reload.
  Adding, removing or renaming a visible file that smock does not read
  still does, once such changes pause for 250 ms, or at most once every
  10 s while they go on. An idle poll still reads no file. Each second it
  takes the change time of each file smock reads and of each directory it
  lists, one call each, and only when one changed, or every 10 s, does it
  also compare the names in the directories and the times and real paths
  of the files. A change that the change times do not show, as on NFS
  while the client's attribute cache hides it, or a symlink pointed at
  another file with the very same times, is found within 10 s. While a
  problem reading the definitions directory lasts, smock reads every file
  each second, where it did every 10 s. The warning that the definitions
  directory or a certificate directory cannot be watched and is only
  polled is gone, and the inotify limits no longer matter. See
  [Reloading](docs/definition-files.md#reloading).
- The Definition-file Schema no longer requires a response's `status`,
  since a gRPC Stub's response has none. The loader still requires it on
  HTTP Stubs, so `smock check` still reports an HTTP Stub's response
  without `status`. The format version stays 1. See
  [gRPC Stubs](docs/definition-files.md#grpc-stubs).
- The Admin API document's `JournalEntry` gains `grpcStatus`, one of
  gRPC's seventeen status names, which a gRPC call's entry has and an HTTP
  request's does not. Its `Body` says what a gRPC call's recorded request
  holds: in `data` the decoded JSON, in `size` the octets of the DATA
  frames received, and in `truncated` whether the JSON was cut at
  `--journal-body-limit`.

### Fixed

- A reload of the Definition files no longer stops smock from answering
  requests while it computes the definition set digest. smock hashed every
  Definition file and body file at once, and twice per reload, so a reload
  with a 16 MiB body file held every connection for about half a second,
  and one with 64 MiB for about 2 s. It now hashes the files once, a step
  at a time, and answers requests between the steps. At startup, the
  admin port answers its probes meanwhile too. The digest is the same as
  before.
- An HTTP/1.1 connection no longer holds on to the header fields of its
  earlier, longer requests. A client that sent long requests and then
  short ones on one connection could leave smock holding about 5 MB of
  their fields and decoded text until the connection closed. A
  connection now holds its last request's fields at most.
- smock no longer aborts (SIGABRT, exit status 134) when files are created
  and written in a directory it watches: the definitions directory, or the
  directory of a TLS certificate or key file, as an editor, a Kubernetes
  ConfigMap update or a program that keeps a database there can do. The
  file watcher of moonbitlang/async panicked on such changes
  ([smock#264](https://github.com/hirunefu/smock/issues/264),
  [moonbitlang/async#725](https://github.com/moonbitlang/async/issues/725)),
  so smock no longer uses it: it polls every second instead of using file
  events, until a release of the runtime fixes that.

## [0.4.0] - 2026-11-01

### Added

- Dependabot proposes, once a week, the updates of the GitHub Actions and
  of the image's distroless base, so that the base's glibc and OpenSSL
  fixes reach the next release's image.
  [docs/releasing.md](docs/releasing.md#dependency-updates) says what it
  does not cover, such as the MoonBit toolchain and modules.
- The Helm chart `oci://ghcr.io/hirunefu/charts/smock` is signed with
  cosign, without a key, as the image is: the signature's certificate names
  the release workflow at the release's tag. The release workflow verifies
  the signature before it publishes the release. See
  [Verify the Helm chart](README.md#verify-the-helm-chart).
- The image's SBOM lists the MoonBit native runtime, mimalloc and simdutf,
  which come with the MoonBit toolchain and are linked into smock, with the
  licences that NOTICE gives them. The runtime has the toolchain's version,
  mimalloc the one NOTICE gives, and simdutf none (`NOASSERTION`), since the
  toolchain does not record it. CI fails when the SBOM and NOTICE disagree.
- A write timeout, `--write-timeout-ms` (`SMOCK_WRITE_TIMEOUT_MS`), 30000 by
  default: smock closes a connection when a write to it makes no progress
  for that long, as when the client stops reading. Before, such a client
  kept its connection, and the response smock held for it, open for good.
  A client that reads slowly but steadily still gets the whole response,
  and delays do not count. It is not logged, like the read and idle
  timeouts. See [Run](README.md#run).
- A `json` condition can match the last element of an array with
  `{ "$last": <condition> }`. It holds when the value is an array with at
  least one element, and its last element meets the condition, so a Stub
  can match the last message of a conversation, such as
  `messages: { $last: { role: tool } }`. It nests with the other
  operators. No file changes meaning: a lone `$last` key failed to load
  before, and `$$last` still means the key `$last`. See
  [Operators in json conditions](docs/definition-files.md#operators-in-json-conditions).
- A template helper, `last(array)`, gives the last element of an array,
  with its own type, and steps can follow it, so
  `${last(body.messages).content}` quotes the last message of a
  conversation. An empty array gives a missing value, so `??` applies.
  Since a response reads the Data buckets after its own Stub's writes,
  `${last(data.orders)}` answers the item that the Stub's `append` just
  added, its new key included. See
  [Helpers](docs/definition-files.md#helpers).
- LLM API presets: a response can give `llm` in place of a body, an LLM
  response that smock writes in the wire form of an LLM API. The request
  decides between JSON and a stream: a request whose JSON body has
  `stream: true` gets Server-Sent Events, and any other request one JSON
  body, so one Stub serves both. With `api: openai-chat`, it answers OpenAI
  Chat Completions requests with one `chat.completion` JSON body, or with
  `chat.completion.chunk` events that carry the text in pieces and end
  with `data: [DONE]`: `text` as the assistant's content, an id that
  `fault.seed` and `--seed` replay, or the one `id` fixes, `created` the
  time the request was received, and the Stub's `model`, or else the
  request's. A piece holds 4 code points, or `chunkSize` of them, and
  never splits one; or `chunks` gives the pieces themselves in place of
  `text`, an empty one included. `toolCalls: [{ name, arguments, id }]`
  declares function tool calls, after the text: the JSON reply gives them
  in `message.tool_calls`, with `content: null` when the text is empty,
  and a stream opens each one with its integer `index`, call id and name,
  then sends its arguments in pieces of the same size. `arguments` is an
  object, written as compact JSON, or a string sent as written, so broken
  arguments can be tested; a call id is `call_` and 24 characters, or the
  one `id` fixes. smock adds an `x-request-id: req_…`
  header to the reply, unless the Stub gives its own.
  `usage: { input, output }` declares the token counts, which the reply
  gives with their total, and a stream whose request sets
  `stream_options.include_usage` gets `usage: null` on every chunk and a
  last usage chunk before `[DONE]`. `stopReason` writes the
  `finish_reason` in the API's own word, checked at load, and is
  `tool_calls` with tool calls, or else `stop`, when left out. With
  `api: openai-responses`, it answers OpenAI Responses
  requests with a Response object: the text in its message item, each
  tool call in a `function_call` item after it, the usage, a `resp_` id,
  `created_at` and `completed_at` the time the request was received, and
  the settings the request gave, such as `instructions` and `tools`,
  copied back. A function call item's id is `fc_` and 24 characters, and
  its `call_id` is `call_` and the 24 characters a Chat reply gives the
  call, or the one `id` fixes; with tool calls and empty text, there is
  no message item. Its `stopReason` is an incomplete reason, such as
  `max_output_tokens`, which makes the reply `incomplete`. A Responses
  request with `stream: true` gets the Responses events, each with an
  `event:` line and a `sequence_number` from 0: from `response.created`
  through the message item's text deltas and each function call's
  argument deltas to `response.completed`, or to `response.incomplete`
  with a stop reason, and no `[DONE]`.
  With `api: anthropic-messages`, it answers Anthropic
  Messages requests with one `message` JSON body, or with events each named
  by an `event:` line, as anthropic-sdk-python's `messages.stream()` reads
  them: `message_start`, the text block's start, a `text_delta` per piece
  and its stop, a block per tool call, then `message_delta` and
  `message_stop`, with no `ping`. The reply has `text` in a text block, or
  no block when it is empty, then each tool call in a `tool_use` block
  with a `toolu_` id, or the one `id` fixes. Its `input` is the
  arguments' object, or a string that holds one as that object, and any
  other string as a JSON string; a stream starts the block with
  `input: {}` and an empty `partial_json`, then sends the arguments' text
  as written in `input_json_delta` pieces. The reply has an id `msg_…`,
  usage as `input_tokens` and `output_tokens`, which a stream gives in
  `message_start` and `message_delta`, and a `request-id: req_…` header in
  place of `x-request-id`. Its `stopReason` is Anthropic's `stop_reason`,
  `tool_use` with tool calls, or else `end_turn`, when left out; with
  `stop_sequence`, the reply echoes the request's first stop sequence, and
  a refusal carries `stop_details`, in the JSON body and in
  `message_delta`. A Stub without a stop reason or an error moves between
  the APIs by changing `api` alone.
  `timing: { first, interval }` paces a stream: a wait before the first
  piece, counted from the head, and one before each later piece, each
  drawn from a distribution of the delay Fault, which `fault.seed` and
  `--seed` replay. A Responses stream's `completed_at` adds the waits to
  the time received. `error: { after, type, message }` cuts a stream with
  the API's own error after `after` code points of the text, in place of
  the rest, with no end marker: for `openai-chat`, a
  `data: {"error": …}` frame, which openai-python raises as `APIError`;
  for `openai-responses`, which gives `code` in place of `type`, an
  `error` event numbered next, with no `.done` event or
  `response.completed`, which openai-python yields rather than raises;
  for `anthropic-messages`, an `event: error` with no `content_block_stop`,
  `message_delta` or `message_stop`, which anthropic-sdk-python raises as
  `APIStatusError` with status 200 and the type in the body's
  `error.type`, never `OverloadedError`. A request that does not stream
  gets the ordinary reply. `anthropic-messages` gives one of Anthropic's
  error types. With `template: true`, the text,
  each chunk, `id`, `model`, each tool call's `name`, `id` and
  `arguments`, and the error's `message` are templates: the text is
  rendered whole, then cut into pieces, an error's `after` past it puts
  the error after the whole text, what they insert is JSON-escaped on the
  wire, and a template that fails gives the 500 `template failed` and no
  stream. The encoded reply, the JSON body or all the events, takes at
  most 1 MiB, the bound of a rendered body: about 20,000 characters of
  text in an OpenAI stream at 4 code points per piece. A reply as written
  over it, as JSON or as a stream, is a load error, and one that a
  template or a long request value pushes over it gets the 500
  `template failed` and no stream. It works with request conditions,
  `responses`, Faults, Scenarios, Variables, Data buckets, Ephemeral Stubs
  and the Journal.
  `smock render` and the Admin render operation show the reply the
  sample's body asks for, the JSON body or a stream's events, each event
  with its wait, with the ids and the waits the seed fixes. See
  [LLM responses](docs/definition-files.md#llm-responses).
- `--log-format mockoon` (`SMOCK_LOG_FORMAT=mockoon`) writes the Mockoon
  CLI's log lines to stdout, so that log pipelines, dashboards, alerts and
  readiness checks built on them keep working after a move from the
  Mockoon CLI. Four of its lines come with Mockoon's messages and keys.
  `Server started on port <port>`, with the plain port, comes once per
  Mock when every listener is open. A `Transaction recorded` line comes
  for each request a Mock handles, once its last byte is written: a Stub
  matched, no Stub matched, or no Mock answered. It names the Mock
  (`environmentName`, left out when no Mock answered), the method as sent,
  the path without its query (`requestPath`, an absolute-form target cut
  to its path), `requestProxied` (always false) and the status, or
  `fault` (`"reset"` or `"close"`) in place of the status when a
  connection Fault sent none; a `partial` Fault logs the status it wrote.
  A delayed response logs after its delay, a Server-Sent Event stream once,
  when it ends, and a request whose client goes away, whose write times
  out or that the drain cuts, when it ends, with its planned status.
  `Error while serving the content: <message>`, at level `error`, comes
  just before it when the Stub's template cannot be rendered or its data
  write cannot be applied, with the Stub's path as written (`routePath`,
  left out for a Stub with no path condition) and its ID (`routeUUID`),
  also with the Journal off and when a connection Fault replaces the 500.
  `Server stopped` comes once per Mock when the drain after SIGTERM ends.
  A reload writes no stop and start pair, and requests the HTTP/1.1 codec
  rejects, Admin API calls, probes and scrapes get no line. Every other
  line smock writes goes to stdout too, fatal startup errors included,
  keeping its message and fields, so stderr carries only usage errors.
  Every line has the same envelope: `app` (always `"smock"`), `level`,
  `message` and `timestamp`, with the line's own fields beside them and
  the keys sorted at every depth, as Mockoon sorts them. Each line is
  written whole and at once, also to a pipe, and a line that cannot be
  written is dropped. A reader of stdout that stops reading holds up only
  the connections whose requests have a line to write; smock's own lines
  then wait in a queue of up to 1,024, and the new metric
  `smock_log_lines_dropped_total` counts those dropped beyond it. The
  format costs CPU: on an M1 laptop smock spent about 8 to 11 µs more on
  each request than in `json`, 40% to 90% more, so size the CPU limit
  for it. The four lines and the envelope are a stable contract: a change to them is
  a breaking change, listed under Changed. `json` stays the default, on
  stderr, and serving a request in it adds one test of a value fixed at
  startup. [Logs](docs/migrating-from-mockoon.md#logs) in the Mockoon
  migration guide shows the setting for the binary, Docker and the Helm
  chart, and lists every line and how it differs from Mockoon's. See also
  [Run](README.md#run).

### Changed

- `scripts/verify-image.sh` requires the runtime, mimalloc and simdutf in
  each SBOM, so it refuses the images of 0.3.0 and earlier. Check one of
  those with the script from its own tag, such as
  `git show v0.3.0:scripts/verify-image.sh`.
- The docs' templated Server-Sent Events example now ends with
  `data: [DONE]` alone, without `event: done`. OpenAI's `[DONE]` frame has
  no `event:` line, and a stream written by hand could copy the old one.
  The example points to
  [LLM responses](docs/definition-files.md#llm-responses), which write an
  LLM API's reply in its wire form.
- smock is built with the MoonBit toolchain moonc v0.10.17+d971670cd, up
  from v0.10.14+7d59c7ec9, which `smock --version`, the startup log entry,
  `smock_build_info` and the Admin API status operation name. NOTICE
  follows its core library. mimalloc is still 2.1.7.
- With the new `mockoon` log format, an unknown `--log-format` value is a
  usage error that ends "must be json or mockoon", and the help text reads
  "The log format: json or mockoon."

### Fixed

- A release's notes link to files of the repository at the release's tag.
  They copy the version's section of CHANGELOG.md, whose relative links to
  files led to a missing page from the release page.
- Every final response smock writes now carries a `Date` header with the
  current time, as RFC 9110 requires: Stub responses, the no-match
  response, Admin API responses and the errors smock sends itself, on
  every port. A Stub, `noMatch.headers` or `crud.headers` that gives its
  own `Date` gets that one alone. `100 Continue` carries none.

## [0.3.0] - 2026-10-22

### Added

- `cookie.NAME` in templates reads a cookie as cookie conditions read it,
  from every `Cookie` field, with quotes kept and nothing percent-decoded.
  It is the first value of the cookie, and `$each` over it walks every
  value.
- Template helpers for text: `len`, `concat`, `padStart`, `padEnd`,
  `substr`, `indexOf`, `includes`, `replace`, `replaceAll`, `split` and
  `join`. Lengths and positions count Unicode code points. A text argument
  may be a number or a boolean, taken as its text. `replace` and
  `replaceAll` take the replacement literally. `split` gives an array that
  `$each` can walk, and `join` turns an array back into text.
- Template helpers `uppercase`, `lowercase` and `trim`, from the data of
  Unicode 18.0.0, built in: simple case mapping, one code point to one and
  with no locale (`ß` stays `ß`), and White_Space removed at both ends.
- Template helpers for encodings: `base64`, `base64url`, `base64Decode`,
  `base64urlDecode`, `urlEncode` and `urlDecode`. The decoders refuse
  characters outside their alphabet, wrong padding and malformed escapes,
  and turn bytes that are not UTF-8 into U+FFFD. `urlEncode` follows
  RFC 3986, so a space is `%20`.
- Template helpers `jwtPayload` and `jwtHeader` give the payload or the
  header of a JWT as an object, read with steps, such as
  `${jwtPayload(header.authorization).sub ?? 'anonymous'}`. A leading
  `Bearer` is removed. They only decode: no signature is ever checked. A
  malformed token is missing, so `??` applies.
- Template helpers for dates: `now(format)`, `dateFormat(date, format,
  offset)` and `dateTimeShift(date, duration)`. Formats use date-fns
  tokens, with English names only; the week-numbering year (`YYYY`) and
  the day of the year (`DD`) are load errors. `yyyy` writes the calendar
  year, so the year 0 is `0000`, as in RFC 3339. Offsets are `Z` or
  `±HH:MM`. Shifts take ISO 8601 durations such as `P1M`, and a month
  shift clamps to the end of the month. A date is an RFC 3339 date-time, a
  date `YYYY-MM-DD` or epoch milliseconds; anything else is missing, so
  `??` applies.
- Template helpers for arithmetic: `add`, `subtract`, `multiply`,
  `divide`, `modulo`, `ceil`, `floor`, `round`, `toFixed` and `parseInt`.
  They compute in exact decimal with integers only, so `add(0.1, 0.2)` is
  `0.3` on every target. `divide` rounds half to even at 10 decimal
  places, `round` and `toFixed` round half away from zero, and numbers
  have at most 18 digits before the point and 18 after. A numeric argument
  may be a string that is a JSON number, such as `query.page`. A number
  literal is taken as written, with every digit, even those a 64-bit
  float would lose.
- Template helper `find(array, member, value)` gives the first element of
  an array that is an object whose member meets a value. The value is
  taken as text, `null` included. A member meets it when it is a string
  equal to that text, a number of equal value as `json` conditions compare
  numbers (`12.50` meets `12.5`), or `true`, `false` or `null` by those
  words. So `find(body.orders, 'id', path[1])` finds the order `1004`
  whether its `id` is a number or a string. When no element meets the
  value, the call is missing, so `??` applies.
- A helper call can be followed by steps, as a reference can:
  `${range(1, 3)[1]}` gives `2`.
- The bounds of `range(a, b)` can be any expression that gives an integer,
  such as `len(body.items)`.
- A helper's result above 1 MiB is a render error, found before the
  result is built.
- `--template-env` (`SMOCK_TEMPLATE_ENV`) on `smock serve`, `smock check`
  and `smock render` lists, separated by commas, the environment variables
  templates may read. Their values are read once, at startup, and every
  load, reload and Ephemeral Stub uses them. A name that starts with
  `SMOCK_` cannot be listed.
- The template root `env.NAME` gives the value of a listed variable as a
  string, and is missing when it is unset. A name that is not listed is an
  error when loading.
- `responses`: a Stub can give 1 to 100 responses with integer weights,
  from 1 to 1,000,000, instead of `response`. Each matched request gets
  one of them, picked with the probability of its weight over the sum of
  the weights, so the status can vary. The pick draws from the request's
  one random draw, so `fault.seed` and `--seed` replay it, and it leaves a
  seed's Fault decisions and helper output as they are. Ephemeral Stubs
  take `responses` with inline bodies.
- Journal entries record `responseIndex`, the index of the response a
  request got. It is null for a Stub with `response`, for a request no
  Stub matched, and when no response was picked, because a value of the
  Stub's `variables` failed to render or the state bound refused its
  writes.
- `smock render` and the Admin render operation show `responseIndex`, and
  render a given response with `--response <i>` and the `response` query
  parameter.
- Variables: named JSON values kept per Mock and Session. A Stub's
  `variables` write them when it matches, before its response is built,
  and templates read them as `vars.NAME`, so a POST can store what a later
  GET returns. Each value is a template, rendered against the Variables as
  they were before the request; a value that fails to render writes none
  of them. Ephemeral Stubs take `variables` too.
- Journal entries record `variablesWritten`, the names of the Variables a
  request wrote.
- `POST /v1/reset` clears the Variables in its scope and says how many it
  cleared, in `removed.variables` of its response and its log entry. A
  reload keeps Variables, except those of a Mock the new files no longer
  declare. The `per_replica_state` warning names Variables too.
- `smock render` and the Admin render operation show `variables`, the
  values a Stub would write, and take the Variables templates read from
  the sample's optional `vars` object, never from the live Variables. The
  response sees the sample's `vars` with the Stub's values written over
  them. A rendering writes nothing, so it stays repeatable.
- Range requests. An untemplated body file of a 200 answers a GET for a
  single byte range with 206 Partial Content and `Content-Range`, or with
  416 and `Content-Range: bytes */<length>` when the range starts past the
  end. Such a 200, to GET and to HEAD, and every 206 carry
  `Accept-Ranges: bytes`. Several ranges, more than one `Range` field, a
  malformed field, another unit, any `If-Range` and an empty file get the
  whole body with 200. A Stub that gives status 206, `Content-Range` or
  `Accept-Ranges` itself is left alone. A `partial` Fault cuts the range
  in half. `smock render` and the Admin render operation apply the rule to
  the sample's `Range` header.
- `--state-max-bytes` (`SMOCK_STATE_MAX_BYTES`) bounds, in bytes, the
  per-Session state of the whole process, across every Mock and Session.
  By default it is an eighth of smock's memory limit, at least 1 MiB and
  at most 64 MiB, as ADR 0004's rule gives the Journal a quarter; smock
  logs the bound at startup. Each space of a Mock and a Session counts its
  Mock name and Session key, and each Variable its name and its value's
  compact JSON, with fixed bytes for each space, Variable and JSON value.
  A request whose writes would pass the bound writes nothing, picks no
  response and gets 507 `state limit reached`.
- The metrics `smock_state_bytes`, the bytes the state bound counts, and
  `smock_state_writes_refused_total`, the writes it refused, from requests
  and Admin API sets.
- Admin API operations on the calling Session's Variables of a Mock:
  `GET /v1/mocks/{mock}/variables` lists them by name, with their values;
  `PUT /v1/mocks/{mock}/variables/{name}` sets one to the JSON value in the
  body; `DELETE /v1/mocks/{mock}/variables/{name}` deletes one. A value
  above 1 MiB of compact JSON, the bound each value of a Stub's
  `variables` has, gets 400 `invalid_request`, and a set keeps a number's
  value, not its text. A set counts against the state bound, and one that
  would pass it writes nothing and gets 507 `state_limit_reached`; a
  delete gives the bytes back. A delete of an unset Variable gets 404
  `unknown_variable`. Each set and delete is logged.
- Data buckets: named JSON values that a Mock declares under the new
  top-level `data` of Definition files, with an initial value inline
  (`json`) or in a JSON file of the body-file subdirectory (`jsonFile`).
  Like a JSON Definition file, a `jsonFile` must not repeat a key in one
  object. A bucket with `key` holds an array of objects whose keys,
  strings or integers, are unique by their text, so `42` and `"42"`
  collide; smock checks this when loading. An integer key is judged by
  its 64-bit floating-point value, so `1.0000000000000001` is the key
  `1`. Templates read a bucket of their Stub's Mock as `data.NAME`, with
  steps, `$each` and `len`. A name that is not one of the Mock's buckets
  is an error when loading.
- Session copies of Data buckets. A Session reads a bucket's initial value
  until it first writes to the bucket, which gives it its own copy; reads
  never copy. Requests without a Session share one copy of each bucket.
  Templates read the request's Session's copy, and `smock render` and the
  Admin render operation never read a copy. Copies count
  toward `--state-max-bytes` with Variables: each counts its bucket's
  name, its value's compact JSON and fixed bytes, and its space counts
  once. Initial values do not count.
- Admin API operations on Data buckets, for the calling Session:
  `GET /v1/mocks/{mock}/data` lists a Mock's buckets, with their keys and
  whether the Session holds a copy; `GET /v1/mocks/{mock}/data/{bucket}`
  reads one with the value the Session reads;
  `PUT /v1/mocks/{mock}/data/{bucket}` sets the Session's copy to the JSON
  value in the body; `DELETE /v1/mocks/{mock}/data/{bucket}` drops it, so
  the bucket reads its initial value again. A bucket the Mock does not
  declare gets 404 `unknown_bucket`, and a value that breaks a keyed
  bucket's rules 400 `invalid_data`. A set keeps a number's value, not its
  text, as a Variable's does. A set that would pass the state bound
  writes nothing and gets 507 `state_limit_reached`. Each set and each
  drop of a copy is logged. The `per_replica_state` warning names the
  copies of Data buckets.
- `POST /v1/reset` drops the copies of Data buckets in its scope, which
  give their bytes back to the state bound, and says how many it dropped,
  in `removed.dataBuckets` of its response and its log entry. A reload
  that swaps in new files drops the copies of a Mock that is gone, of a
  bucket the new files no longer declare, and of a bucket whose initial
  value or `key` changed; it keeps the others, so editing an unrelated
  Stub keeps a test's data. Initial values are compared as compact JSON,
  so moving one between `json` and `jsonFile` is no change, and a change
  of `newKey` keeps the copies. The `definitions reloaded` log entry says
  how many copies the reload dropped, in `dataBucketsReset`. Nothing
  expires a copy.
- A Stub's `dataWrites` writes to the Data buckets of its Mock when it
  matches: 1 to 100 writes, applied in order, each `set` (the bucket
  becomes the value), `merge` (a shallow merge of an object into the
  bucket) or `append` (to the array in the bucket), with a value that is
  always a structured template. The values render against the state from
  before the request, after the values of `variables`, and the writes are
  stored with the Variables all at once, or not at all: a value that fails
  to render gives the template failure, a write that cannot be applied
  gives 500 `data write failed`, and writes past the state bound give 507.
  The response sees the data after the writes, and the writes stand
  whatever follows. Only a Session's first write to a bucket copies it.
  An Ephemeral Stub takes `dataWrites` too. When a reload removes a
  write's bucket, or changes it so that the write would no longer load,
  the write gets 500 `data write failed`, checked before any value
  renders. Each Journal entry gains `dataWritten`, the buckets written,
  and `dataError`, why a write failed to apply.
- `dataWrites` writes keyed Data buckets item by item. `set`, `merge` and
  `remove` take the `key` of one item, a text template compared as a key
  text, so `${path[3]}` finds the order whose `id` is `1002` or `"1002"`.
  `append` adds an item at the end. A value's key member may be absent or
  hold the item's key, and the item keeps its stored key value. An item
  that `append` adds without a key gets a new one, as the bucket's
  `newKey` says: one more than the highest integer key, skipping integers
  whose text a string key has, or a version 4 UUID from the request's
  helpers, which `fault.seed` repeats. A key that no item has, a value
  that would break the bucket's rules, and running out of integer keys
  (`no new key`) fail the write, and nothing is written. A literal value
  that already breaks them, such as an item whose key member holds no key
  or a key other than a literal `key`, is an error when loading. A Stub's
  response cannot read a key that its own `append` made.
- `smock render` and the Admin render operation take sample data and show
  the writes a Stub would make. The sample's `data` gives the value of a
  Data bucket of the Stub's Mock in place of its initial value; a name the
  Mock does not declare, or a value that breaks a keyed bucket's rules,
  makes `smock render` exit with status 1 and the Admin render answer 400
  `invalid_data`. The rendering's `dataWrites` lists the writes of the
  Stub's `dataWrites` in order, each with its op, bucket, rendered key and
  rendered value, the new key filled in for an `append` to a keyed bucket,
  and the response reads the data after them. A write that fails to render
  or to apply shows the 500 a request would get, and no write. A rendering
  never reads or writes a Session's copy, and no state bound applies.
- CRUD Stubs: a Stub with `crud` (`bucket`, `path` and optional `headers`)
  in place of `request` and `response` serves a keyed Data bucket as a REST
  resource. `GET <path>` lists the bucket's items, with `X-Total-Count`
  and `X-Filtered-Count`, and `GET <path>/<key>` reads one item, or answers
  404 `no item with this key`. Reads see the Session's copy, or else the
  initial value. Any other method or path shape falls through to later
  Stubs. A CRUD Stub is tried in the usual order, so an earlier Stub can
  take over one of its requests. `crud.headers`, such as CORS headers, go
  on every answer, and `fault` works as on any Stub. An Ephemeral Stub can
  be a CRUD Stub. Each Journal entry gains `crud`, the operation and its
  key.
- CRUD Stubs write: `POST <path>` creates an item and answers 201 with it
  and its `Location`, `PUT <path>/<key>` replaces the item, `PATCH
  <path>/<key>` merges the body into it shallowly, and `DELETE
  <path>/<key>` removes it and answers the removed item. Each is one write
  by key, as `dataWrites` makes, to the Session's copy, made at the match
  decision before any delay, all or nothing, within the state bound. The
  body must be a JSON object, whatever its Content-Type (400 `body is not
  a JSON object`). A create without the key member gets a new key, added
  last; a key that is not one is 400 `invalid key`, and a taken one 409
  `key already exists`. A replace or update keeps the item's key, and a
  body that holds another is 400 `key does not match the path`. A missing
  item is 404, no integer key left 500 `no new key`, and the state bound
  507, a delete's included. A connection Fault replaces the answer, but
  not the write.
- List queries: a CRUD Stub's list reads its query in smock's own syntax.
  A parameter filters on the item member of its name, as `find` compares,
  and a repeated name holds when any of its values does. `$sort=a,-b`
  sorts by members, by type first and then by value, with strings by
  Unicode code point; absent members, objects and arrays go last, and the
  sort is stable. `$offset` and `$limit` page the list. `X-Filtered-Count`
  counts the items that pass the filters, before paging, and the body
  stays a plain array. `$$name` filters on the member `$name`, and any
  other name that starts with `$`, such as OData's `$top`, is 400
  `invalid query parameter`, without the two counts, as are malformed or
  repeated `$sort`, `$offset` and `$limit`. A client's own parameters,
  such as `page`, are filters too, so its list comes back `[]`.
- A CRUD Stub can be the Near miss of a request that no Stub matches. It
  counts two conditions: `path` fails when the request path is neither its
  list path nor an item path, and `method` when the Stub does not serve
  the method at the path's shape, or at either shape when `path` fails.
  The Near miss expects `{"crud": "<path>"}` or `{"crud": [<methods>]}`,
  and the header keeps its form, such as `Smock-Near-Miss: orders;
  failed=method`.
- `smock check` warns about CRUD Stubs in the cases it can prove: an
  earlier CRUD Stub hides a later Stub whose method and exact path it
  serves, whatever that Stub's other conditions or `requires`, or a later
  CRUD Stub with the same path; a Stub with no request conditions and no
  `requires` hides a later CRUD Stub. A partial overlap gets no warning.
- `smock render` and the Admin render operation render a CRUD Stub: the
  answer its operation would give to the sample, from the sample's data or
  else the initial value, failures and list queries included, with a new
  `uuid` key drawn from the seed. Its write shows in `dataWrites` as the op
  that makes the same write, `append` for a create, `set` for a replace,
  `merge` for an update and `remove` for a delete, and not at all when it
  fails. A sample whose method and path fit no operation of the Stub, and
  a `--response` index, make `smock render` exit with status 1 and the
  Admin render answer 400 `invalid_request`.
- docs/migrating-from-mockoon.md maps Mockoon's helpers, `RANDOM` routes,
  global variables, Range requests, dates, cookies and environment
  variables onto smock, with each difference called out. It also maps
  data buckets, CRUD routes and their list parameters, the `data` and
  `dataRaw` helpers, `setData` and the purge of data buckets onto Data
  buckets, CRUD Stubs, list queries and `dataWrites`, and its worked
  example serves its orders from a Data bucket with a CRUD Stub. It says
  that it needs smock 0.3.0 or later, and which of its counterparts came
  in 0.2.0 and which in 0.3.0.
- `smock import-openapi <document> --mock <name> --output <file>` converts
  an OpenAPI 3.0, 3.1 or 3.2 document into one Definition file, once.
  smock never reads OpenAPI when it serves. `--hosts` gives the Mock its
  Hosts, and `--declare-mock off` writes only Stubs, for a Mock declared by
  hand in another file; the document's `servers` never become Hosts. Parts
  that it does not import, such as callbacks and webhooks, are left out
  with a warning. See [docs/importing-openapi.md](docs/importing-openapi.md).
  The Mockoon migration guide points there too: an environment that
  Mockoon imported from an OpenAPI document can be imported into smock from
  the same document.
- Each imported operation, 3.2's `query` and `additionalOperations`
  included, becomes Stubs that match its method and its path, under the
  path of its server URL, so the mock answers where the real service does;
  `--base-path` replaces that prefix. A path with parameters, such as
  `/pets/{petId}`, becomes a pattern in which each parameter matches one
  segment, and concrete paths come before templated ones. The main
  response answers by default. Every other response has a Stub that a
  request selects with `Smock-Status: <key>`, such as `404`, and every
  further named example one that `Smock-Example: <name>` selects. A test
  that reaches the mock through its system under test adds an Ephemeral Stub
  for its Session instead, as the guide shows.
- Imported bodies come from a media type's `examples`, then its `example`,
  then one fixed sample of its schema, written in the file as `json` or
  `body`, with the media type as the Content-Type. Samples follow formats,
  number bounds, `allOf`, `oneOf` and `anyOf`, and `$ref`, recursive schemas
  included. Nothing is random and nothing is templated, and number bounds
  use exact decimal arithmetic on the shortest decimal text of each bound,
  so every platform writes the same digits. A sample nests at most 32
  levels, one above 64 KiB is cut to its required parts, and a body above
  1 MiB is left empty, with a warning.
  The headers a response documents are written too, with their example or a
  sample of their schema; a header with neither is left out, with a
  warning.
- `smock import-openapi` reads YAML documents as YAML 1.2, as OpenAPI
  recommends, so `200:` is the key `"200"` and a date is a string; anchors
  and aliases stay errors. It follows a `$ref` where OpenAPI allows one,
  within the document and into other files under `--ref-dir`, by default the
  document's directory, so a downloaded document cannot copy a secret into a
  committed file. At most 1,000 documents and 64 MiB are read. A URL is an
  error that suggests bundling the document into one file first.
- The import writes YAML or JSON, as the name of `--output` says. A YAML
  file starts with a comment that names the document and the flags whose
  value is not the default, and says not to edit the file, and each Stub
  has one that maps it back to its operation. An existing file is replaced
  only with `--overwrite on`, through a temporary file and a rename, so a
  smock that watches the directory never loads half a file. The guide
  shows how to keep hand changes in another file, and how CI can check
  that the file is current.
- `write` in the `smock/yaml` module turns a JSON tree into a YAML
  document, with comments, that the module's own parser reads back as the
  same tree. A string is quoted only when it would not read back as the
  same string. The OpenAPI import writes YAML Definition files with it.
- `parse` in the `smock/yaml` module has a mode for OpenAPI documents,
  `openapi=true`. It types plain values by the YAML 1.2 core schema, as
  OpenAPI asks: `200:` is the key `"200"`, `2020-01-01` and `yes` are
  strings, `007` is the number 7, and `~` is null. It also accepts block
  scalar indentation indicators such as `|2`. Definition files keep the
  safe subset, unchanged. The OpenAPI import reads YAML documents with it.

### Changed

- A loop variable named `cookie`, `env` or `vars` now fails to load, since
  `cookie`, `env` and `vars` are template roots. No valid file changes
  meaning: rename the loop variable. The Definition file format is still
  version 1.
- A loop variable named `data` now fails to load, since `data` is the
  template root of Data buckets. Rename the loop variable. No other valid
  file changes meaning, and the format is still version 1.
- A 200 from an untemplated body file now carries `Accept-Ranges: bytes`,
  and a GET with a `Range` field gets the range it asks for. To keep
  sending the whole body, give the response an `Accept-Ranges` header of
  its own, such as `none`.

## [0.2.0] - 2026-10-21

### Added

- Operators in request conditions. `$not` negates a condition, and
  `$exists` asks whether a query parameter, header, cookie, form field or
  XML path is present. Inside `json` conditions, `$not` and `$exists` work
  on any value, `$includes` matches an array with an element that meets
  its condition, and `$$name` writes a key that starts with `$`.
- `cookies` conditions match the cookies of the request by name, from
  every `Cookie` field.
- `form` body conditions match the fields of an
  `application/x-www-form-urlencoded` body by name. They hold only when the
  Content-Type says the body is a form.
- `xml` body conditions match the values at simple paths into an XML body,
  such as `/Envelope/Body/GetUser/id` or `/order/item/@sku`. A body that is
  not well-formed XML, or that has a DOCTYPE, fails them.
- The `smock/xml` module, the XML parser and paths behind `xml` conditions.
  It does no I/O and depends only on `moonbitlang/core`.
- The Near miss names the new conditions `cookie:<name>`, `form:<name>` and
  `xml:<path>`, and shows operators as the Stub writes them. Journal
  filters take `$not` and `$exists` for headers.

### Changed

- Two kinds of `json` condition written for smock 0.1 now mean something
  else. The Definition file format is still version 1.
  - An object whose only key is `$not`, `$exists` or `$includes` was
    literal JSON, and is now an operator.
  - A key that starts with `$$`, such as `$$id`, matched that key as
    written, and now matches it with one `$` less, `$id`.

  Any other key that starts with `$` in a `json` condition is now an
  error, so a file with one fails to load rather than change its meaning:
  write the key with `$$`.
- The Journal bounds the form and XML values that an entry's Near miss
  keeps. They are kept in order until their total reaches
  `--journal-body-limit`, each counting its bytes and 32 bytes more; the
  last one kept is cut, and the rest are dropped. The 32 bytes per value
  also count toward `--journal-max-bytes`.

## [0.1.0] - 2026-10-19

- The first public release.

[Unreleased]: https://github.com/hirunefu/smock/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/hirunefu/smock/releases/tag/v0.4.0
[0.3.0]: https://github.com/hirunefu/smock/releases/tag/v0.3.0
[0.2.0]: https://github.com/hirunefu/smock/releases/tag/v0.2.0
[0.1.0]: https://github.com/hirunefu/smock/releases/tag/v0.1.0
