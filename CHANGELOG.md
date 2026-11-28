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
  module file, and CI fails when NOTICE leaves out such a module or gives
  it another version.
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
- gRPC unary calls, on the plain port over h2c and on the TLS port over
  h2, beside HTTP and served by the same Mocks. A Mock names its service's
  Descriptor set, and its gRPC Stubs answer unary calls, which smock
  decodes from protobuf into JSON, matches as it matches JSON requests,
  and answers with replies written as JSON. See [gRPC](docs/grpc.md).
  - **Ports and detection.** An HTTP/2 request whose `content-type` is
    `application/grpc`, alone or followed by `+` or `;`, is a gRPC call.
    One with no subtype, `+proto` or `;` parameters is served; one with
    another subtype, such as `+json`, gets Trailers-Only UNIMPLEMENTED as
    soon as its HEADERS arrive, and counts as rejected traffic. Every
    other content type, gRPC-Web's included, and every HTTP/1.1 request
    go to the HTTP Stubs. `--tls-http2 off` turns gRPC over TLS off too,
    and the admin port never serves it. See
    [Ports and detection](docs/grpc.md#ports-and-detection).
  - **Serving a call.** smock takes a call's one message, decodes it into
    JSON with the input type of the method its `:path` names in its Mock's
    set, and matches it against the Mock's gRPC Stubs on that method, as a
    `POST` with the metadata as headers and the JSON as the body. The
    reply JSON is read as ProtoJSON reads it, so a reply pasted from any
    tool works, encoded with the output type as protoc encodes it, and
    sent as HEADERS, one DATA frame and trailers with `grpc-status: 0`. A
    static reply is checked and encoded when the files load; a templated
    one is encoded on each call, and gets INTERNAL `template failed` when
    it does not fit the output type. `:authority` chooses the Mock, and
    the Default Mock answers with its own set. A call is looked up again
    when its request ends, so a reload never makes a call decoded with one
    version of a set and answered with another. See
    [How smock serves a call](docs/grpc.md#how-smock-serves-a-call).
  - **gRPC Stubs.** A Stub whose exact path names a unary method of its
    Mock's set is a gRPC Stub. It answers gRPC calls only, and gRPC calls
    reach gRPC Stubs only. Its fields that make no sense for gRPC are load
    errors that say why: `query` and `cookies` conditions, a body
    condition other than `json`, and `status`, `body`, `bodyFile`, `events`
    and `llm` in a reply. `method` may be left out, and when given, must
    be `POST`. A Stub on a streaming method is a load error. A CRUD Stub
    stays an HTTP Stub whatever its path. `smock check` warns about an
    HTTP Stub of a Mock with a set whose exact path has the form
    `/package.Service/Method` but names no method of the set, which gRPC
    calls never reach. See [gRPC Stubs](docs/grpc.md#grpc-stubs).
  - **Ephemeral gRPC Stubs.** An Ephemeral Stub whose exact path names a
    method of its Mock's set is a gRPC Stub, checked against the set and
    normalised as a Stub in a Definition file is, or refused with 400
    `invalid_stub` and each problem's JSON Pointer. A call tries its
    Session's Ephemeral gRPC Stubs first. They are not read again at a
    reload: while the new set lacks their method as a unary method, they
    answer no call, and a reply that no longer fits the output type gets
    INTERNAL, with a `templateError`. See
    [Ephemeral gRPC Stubs](docs/grpc.md#ephemeral-grpc-stubs).
  - **The JSON form.** A request message, of any type of a proto3 or a
    proto2 file, is decoded into one JSON form that the Journal, conditions,
    templates and the Near miss see: fields in field-number order under
    their JSON names, 64-bit integers as exact numbers, floats in their
    shortest form, NaN and the infinities as strings, bytes in base64, enums
    by name, repeated fields as arrays and maps as objects in key order.
    Fields without presence print at their defaults, `[]` and `{}` included,
    and proto3 `optional` fields, oneof members, message fields and every
    singular field of a proto2 message only when set, so `$exists` tells
    them apart. Messages are read as protobuf's parsers read them: packed or
    unpacked, a later oneof member replacing an earlier one, and the values
    of a message field merged. So a message gives one text, whatever order
    its client encoded it in. See [The request message as
    JSON](docs/grpc/messages.md#the-request-message-as-json).
  - **Well-known types.** Timestamp, Duration, FieldMask, the wrappers,
    Empty, Struct, Value, ListValue, NullValue and Any take their
    ProtoJSON forms, as grpcurl shows them, in request messages,
    conditions and replies, at any place, a method's whole input or
    output included. A request prints a Timestamp in UTC with `Z`, and a
    Duration with `s`, each with 0, 3, 6 or 9 fractional digits, such as
    `"1970-01-01T00:00:01.500Z"` and `"1.500s"`; a FieldMask as its paths
    in lowerCamelCase, joined by commas; a wrapper as the value it wraps;
    a Struct, a Value and a ListValue as the JSON values they hold; and an
    Any as its type URL in `"@type"`, then the message it holds, or its
    form in `"value"`. An Any's type is looked up in the Mock's set: a
    call whose Any holds a type the set lacks gets INTERNAL, and in a
    condition or a static reply such a type is a load error. In a reply,
    `null` sets a Value or a NullValue, and leaves other fields unset. See
    [Well-known types](docs/grpc/messages.md#well-known-types) and
    [Any](docs/grpc/messages.md#any).
  - **proto2.** A request message without a required field, at any depth,
    gets INTERNAL and does not reach the Stubs, as protobuf's parsers
    refuse it; a static reply without one is a load error, and a templated
    one gets INTERNAL with `templateError`. A number that a closed enum
    does not define is kept as an unknown field, so it is never printed or
    matched, and a condition or a reply that gives one is refused. A reply
    packs a proto2 field's repeated scalars only when it says
    `packed = true`. A proto2 string that is not UTF-8 prints with U+FFFD
    for each bad sequence. Groups decode and encode as messages. An
    extension prints under its full name in brackets, as ProtoJSON writes
    it, such as `{"id":7,"[shop.priority]":3}`, and conditions and replies
    give it under the same key. A Stub whose method's types reach a type
    of an editions file, a type that an extension declared in one extends,
    or a MessageSet, is a load error that says why, per method, so files
    that no Stub uses still load. See
    [proto2 types](docs/grpc/messages.md#proto2-types).
  - **Conditions on the message.** A gRPC Stub's `json` condition is checked
    against its method's input type when the files load, and rewritten into
    the form in which smock prints a call's message, so matching costs
    nothing more per call. A key may name a field by its proto name or its
    JSON name, and becomes the JSON name; an enum number or alias becomes
    the enum's first name; a `float`, or a FloatValue, is rounded to the
    nearest 32-bit float, so `{ratio: 0.1}` matches 0.1. Map keys and Struct
    keys are data and stay as written. A key that names no field, and a
    literal that is not a value of its field's type, are load errors at
    their JSON Pointer; one that ProtoJSON reads but smock never prints,
    such as a 64-bit integer as a string, base64 without its padding or
    URL-safe, an integer map key such as `"007"`, a Duration of `"1.5s"` or
    a Timestamp with an offset other than `Z`, names the form to write. gRPC
    Stubs are compared once rewritten for the warning about a Stub that can
    never match. See [Conditions on the
    message](docs/grpc/messages.md#conditions-on-the-message).
  - **Request metadata.** Every field of a call's metadata, `content-type`,
    `te`, `grpc-timeout` and `user-agent` included, reaches `headers`
    conditions, `header.NAME` in templates and the Journal as a header, one
    value per field line. A call's `-bin` values lose the base64 padding
    that ends each comma-separated element, commas kept, so `AAA=,BBB=`
    becomes `AAA,BBB`; smock never decodes them. An exact `headers`
    condition on a `-bin` field of a gRPC Stub loses its padding when the
    files load, so padded and unpadded clients match alike, and a pattern
    sees the unpadded value. The Journal stores the values unpadded, so a
    Journal filter gives them so; filters are not rewritten, and HTTP
    requests keep their `-bin` headers as received. A call's Session comes
    from its `baggage` metadata, with `--session-header` and
    `--session-member`, as an HTTP request's does. See [Request
    metadata](docs/grpc/metadata-and-status.md#request-metadata) and
    [Sessions](docs/grpc/metadata-and-status.md#sessions).
  - **Unmatched calls.** A call that no Stub matches gets Trailers-Only
    UNIMPLEMENTED `no Stub matched`, with its Near miss among the Mock's
    gRPC Stubs in a `smock-near-miss` trailer, in the form of the
    `Smock-Near-Miss` header; the Mock's `noMatch` applies to HTTP requests
    only. A call whose Host reaches no Mock, whose Mock has no set, or whose
    method the set lacks or streams gets UNIMPLEMENTED with a fixed message
    as soon as its HEADERS arrive, then RST_STREAM `NO_ERROR` while the
    client still sends, and is journaled as unmatched with an empty body.
    See [Unmatched
    calls](docs/grpc/unmatched-and-refused-calls.md#unmatched-calls).
  - **State.** gRPC Stubs require and move Scenarios, read and write
    Variables and Data buckets, and pick one of their weighted `responses`
    for each call, as HTTP Stubs do. A Mock's HTTP requests and gRPC calls
    share its state: an item a call writes, a CRUD Stub's GET reads over
    HTTP, and one an HTTP request creates, a call reads. smock's own HTTP
    answers never reach a gRPC call. A gRPC Stub whose template fails, a
    `variables` value or a `dataWrites` key or value included, gets
    Trailers-Only INTERNAL `template failed`; one whose data write cannot
    be applied, INTERNAL `data write failed`; and one whose writes would
    pass the state bound, RESOURCE_EXHAUSTED `state limit reached` instead
    of 507. Each is journaled with the HTTP status 200, its `grpcStatus`,
    and `templateError` or `dataError` as on HTTP. See
    [State over gRPC](docs/grpc/state-and-faults.md#state-over-grpc) and
    [smock's own failures](docs/grpc/unmatched-and-refused-calls.md#smocks-own-failures).
  - **Delays and deadlines.** A gRPC Stub's `fault.delay` waits before the
    reply's HEADERS, on the call's stream alone, as on HTTP/2. A call's
    deadline comes from its `grpc-timeout`, counted from its HEADERS. A
    delay that would end after it ends the call at the deadline with
    Trailers-Only DEADLINE_EXCEEDED `deadline exceeded`, journaled with
    the HTTP status 200 and the `grpcStatus` `DEADLINE_EXCEEDED`. A client
    reset that arrives while such a delay runs, at most 100 ms before the
    deadline, is journaled the same way, as clients reset the stream at
    their own deadline. Such a reset, and the first reset of a call smock
    ended at its deadline, count neither toward the Rapid Reset bound nor
    among the frames that do no work, so a client whose calls time out
    keeps its connection. A call cancelled earlier keeps the entry its
    Stub planned. A timeout longer than 2^31-1 ms, such as `99999999H`,
    gives no deadline, and a timeout of 0 ends a delayed call at once. See
    [Deadlines](docs/grpc/state-and-faults.md#deadlines).
  - **Faults.** A gRPC Stub's `fault.connection` takes its HTTP/2 form,
    with no `content-length`: `reset` resets the call's stream alone,
    `partial` sends the reply's HEADERS and the first half of its framed
    message, then resets the stream, and `close` sends GOAWAY and closes
    the connection, which ends every call on it. A gRPC client sees
    INTERNAL for `reset` and `partial`, and UNAVAILABLE for `close`. The
    entry of a call that `reset` or `close` ended has no `status` and no
    `grpcStatus`. A deadline that cuts a Stub's delay short comes before
    its Fault, which never comes. The guide gives the status a client
    derives from each of HTTP/2's resets and refusals too. See
    [Faults](docs/grpc/state-and-faults.md#faults).
  - **Protocol checks.** smock refuses a call that gRPC's rules refuse as
    gRPC servers do, before it reaches the Stubs: a method other than `POST`
    gets `:status` 405 and a malformed `grpc-timeout` 400, both with
    INTERNAL, on HEADERS, after the 431 and 400 of HTTP/2 and before the
    Mock's own checks. A body over `--body-limit`, its prefixes included,
    gets RESOURCE_EXHAUSTED instead of 413, as soon as `content-length`, a
    message's prefix or the octets received show it. A message's flag other
    than 0 or 1, or 1 with no `grpc-encoding` or `identity`, gets INTERNAL;
    flag 1 under another `grpc-encoding` gets UNIMPLEMENTED with
    `grpc-accept-encoding: identity`, since smock never decompresses, and
    flag 0 is served whatever `grpc-encoding` says. Replies are never
    compressed. A request that ends inside a message gets INTERNAL, and one
    with no message or several UNIMPLEMENTED; a message of zero octets is
    one message, and a message that does not parse gets INTERNAL. `te:
    trailers` is not required. Each refusal has a fixed message, but for two
    that name what the call sent: the encoding of a compressed message, and
    the numbers of a message whose JSON holds too many values. Each is
    followed by RST_STREAM `NO_ERROR` while the client still sends, is not
    journaled, and counts as rejected traffic. See [Protocol checks and
    limits](docs/grpc/unmatched-and-refused-calls.md#protocol-checks-and-limits)
    and [Compression](docs/grpc/unmatched-and-refused-calls.md#compression).
  - **Bounds on decoding.** smock bounds the CPU and the memory that a small
    hostile message can cost. A message nested deeper than 100, through
    messages, groups, map entries, Anys, Structs and their Values, gets
    INTERNAL, and so does one with a length that runs past it. smock counts
    the decoded JSON as it prints it, and a call gets RESOURCE_EXHAUSTED
    `the decoded request message is over the body limit` as soon as it
    passes `--body-limit`: an empty element of a list of messages, 2 octets,
    prints every field of its type, so a 10 MiB message could otherwise
    print gigabytes. smock counts the JSON's values too, since parsed JSON
    costs memory by its values: each object, array, string, number, `true`,
    `false` and `null` is one. A message of N octets may print 32,768 + 4 ×
    N of them, and a call past that gets RESOURCE_EXHAUSTED `the decoded
    request message holds more than 108768 values, the most for a message of
    19000 octets`, with its own two numbers. That call is a list of 9,500
    empty elements of a message with 60 fields, which would print 579,502
    values. A list passes at any length when an element of n octets prints
    at most 4 × n − 1 fields: 7 for a default-constructed element, 15 for
    one with a small field set. Wider elements pass in smaller numbers, such
    as 618 default-constructed elements of 60 fields, or 728 with one small
    number each. No flag changes the bound. It is a price in octets, not a
    cap on what a call costs: the same list passes in a message of 136,684
    octets, and a message of 64 KiB can still cost about 112 MiB once its
    JSON is parsed. A condition and a template each parse it, so a call
    whose message both read can cost about 194 MiB. `smock render` and the
    Admin render operation refuse a sample past the bound too. What smock
    holds to print a message, such as its map entries, is bounded by
    `--body-limit` too. See [The decoder's
    limits](docs/grpc/unmatched-and-refused-calls.md#the-decoders-limits).
  - **Connections.** A gRPC channel's connection is an HTTP/2 connection
    like any other: an idle one gets GOAWAY after `--idle-timeout-ms`,
    keepalive PINGs or not, and its client reconnects on its next call;
    keepalive PINGs are answered under HTTP/2's bound on frames that do no
    work, with no ping-strike policy of gRPC's own; and the drain lets
    calls in flight finish, while later calls get UNAVAILABLE. See
    [Connections](docs/grpc/services-and-connections.md#connections).
  - **Two new modules.** `smock/grpc` holds gRPC's wire rules: it frames
    messages, reads them as they arrive, in pieces split anywhere, reads
    `grpc-timeout` in whole milliseconds, names gRPC's status codes,
    percent-encodes status messages, checks reply metadata and takes the
    padding off `-bin` values. `smock/protobuf` reads Descriptor sets,
    decodes messages into JSON, with a limit on the JSON, encodes them from
    JSON, and encodes `google.rpc.Status`. Both do no I/O and build for
    every target, so smock gains no dependency and no C for gRPC.
- A Mock's `grpc` field names its Descriptor set, a FileDescriptorSet as
  `protoc --include_imports -o` or `buf build -o` writes it, in the
  body-file subdirectory: `grpc: { descriptorSet: greeter.binpb }`. The
  path has the rules of `bodyFile`. smock reads the set with the
  Definition files: `smock check`, startup and a reload report a set that
  is missing or does not decode, at the JSON Pointer of `descriptorSet`,
  and a reload swaps the set in with the files. smock reads any
  self-contained set, proto2, proto3 and editions files included. It
  refuses a set that lacks a file its files import, holds a file twice,
  defines a name twice, or names a type it does not define, each a
  problem at `descriptorSet`. Source info, options other than
  `map_entry`, `packed` and `message_set_wire_format`, and unknown fields
  such as Buf's image extensions cost nothing. Each Mock holds its own
  set, decoded, in every replica. `grpc` also turns on the Mock's
  built-in services, with `reflection` and `health`, and `descriptorSet`
  may be left out of it. See
  [Descriptor sets](docs/definition-files/grpc.md#descriptor-sets) and
  [Building a set](docs/grpc.md#building-a-set).
- `response.grpc`: a gRPC Stub's reply, or each of its `responses`, gives
  how it ends. See [Status and
  message](docs/grpc/metadata-and-status.md#status-and-message).
  - **Status and message.** The gRPC status by name, from `OK` to
    `UNAUTHENTICATED`, `OK` when left out, and a status message in any
    Unicode text, which smock percent-encodes into `grpc-message` and
    which may be a text template. With weighted `responses`, a dependency
    can fail one call in ten. An error that also gives `json`, and `grpc`
    on an HTTP Stub, are load errors.
  - **Trailers-Only.** An error without initial metadata goes out as
    Trailers-Only, as gRPC servers send it; `smock-mock` alone does not
    count as initial metadata. An error with initial metadata goes out as
    HEADERS, then trailers. See
    [Trailers-Only](docs/grpc/metadata-and-status.md#trailers-only).
  - **Reply metadata.** A gRPC Stub's `headers` are its reply's initial
    metadata, sent in its HEADERS, and `grpc.trailers` its trailing
    metadata, sent after `grpc-status` and `grpc-message`, in the shape
    of `headers`, several values of one name as an array. Names are sent
    in lower case. Names outside gRPC's grammar, the names gRPC reserves
    (`content-type`, `te` and `grpc-*`), those HTTP/2 forbids and those
    smock sets are load errors in both, so a gRPC Stub cannot give a
    Content-Type. A value as written outside 0x20 to 0x7E is a load
    error, and a `-bin` value is written in base64, checked when the
    files load, and sent without its padding. With `template: true`,
    trailer values are templates, rendered as header values are, and a
    rendered value that breaks these rules gets Trailers-Only INTERNAL
    `template failed`, with the reason in `templateError`. See
    [Reply metadata](docs/grpc/metadata-and-status.md#reply-metadata).
  - **Error details.** `grpc.details`, such as googleapis' `ErrorInfo`,
    `RetryInfo` or `BadRequest`, each in ProtoJSON with `@type`, whose
    type the Mock's set must define. smock builds `google.rpc.Status` from
    the reply's status, its message and the details packed as Any,
    encodes it itself, and sends it in `grpc-status-details-bin`, in
    base64 without padding, so the two status codes never disagree and the
    set need not hold `status.proto`. A detail type the set lacks, a
    detail that does not fit its type, and details with `OK` are load
    errors; detail types go through a method's type checks. With
    `template: true`, each detail is a structured template, and one that
    fails to render or does not fit its type gets Trailers-Only INTERNAL
    `template failed`, with the reason in `templateError`. See
    [Error details](docs/grpc/metadata-and-status.md#error-details).
  - **Size.** Each block of a reply's metadata counts against
    `--header-size-limit`, the details included (see Changed). See
    [Metadata size](docs/grpc/metadata-and-status.md#metadata-size).
- Server reflection and health, each turned on per Mock and off by default.
  A Mock that does not turn them on pays nothing for them. Their answers are
  not journaled, get no `Transaction recorded` line, and count in the
  request metrics under their Mock with `stub=""`, not as unmatched
  requests. See [Built-in
  services](docs/grpc/services-and-connections.md#built-in-services).
  - **Reflection.** With `grpc: { reflection: true }`, a Mock answers
    gRPC's `grpc.reflection.v1` and `grpc.reflection.v1alpha`, so grpcurl
    and Postman can list and describe its services without a local copy
    of its set: `list_services`, `file_by_filename`,
    `file_containing_symbol`, `file_containing_extension` and
    `all_extension_numbers_of_type`, from the Mock's set, each file with
    the files it imports, as the set holds them but without source info;
    a name the set lacks gets NOT_FOUND. With `health` on, it lists the
    health service too, from the descriptor smock embeds unless the set
    defines `grpc.health.v1`. It answers one request per call, once the
    request's message is whole, then resets the stream with NO_ERROR if
    the client still sends. It reads the request as protobuf's parsers
    read a message. A field it knows that comes with another wire type
    than its type's, such as `file_by_filename` sent as a varint, is
    skipped, as an unknown field is. `file_containing_extension` records
    in a row merge, as the records of a message field do, so the
    containing type can come in one record and the extension number in
    the next. A Mock with reflection on keeps its set's files as encoded,
    beside the set's model. See
    [Reflection](docs/grpc/services-and-connections.md#reflection).
  - **Health.** With `grpc: { health: true }`, a Mock answers gRPC's
    `grpc.health.v1.Health` as gRPC's health servers do: `Check` says
    SERVING for `""` and for each service of the Mock's set, and gives
    NOT_FOUND for other names; `List` gives the same statuses; `Watch`,
    which streams, gets UNIMPLEMENTED. Once SIGTERM starts the drain,
    every answer says NOT_SERVING. A gRPC Stub on a health method, an
    Ephemeral one of the call's Session included, answers in the
    service's place, so a Scenario can make it NOT_SERVING. smock embeds
    the descriptor of gRPC's `health.proto`, so the set need not hold it.
    smock's own probes stay on the admin port's `/readyz`. See
    [Health](docs/grpc/services-and-connections.md#health).
- `grpcStatus` in the Journal. A gRPC call's entry records the name of the
  gRPC status the call got, such as `OK` or `UNIMPLEMENTED`, beside its HTTP
  status, which is 200 for every answer smock sends a call. Its body is the
  decoded JSON, whose `size` counts the octets received. An HTTP request's
  entry has none, nor has the entry of a call that a `reset` or `close`
  Fault ended. Queries, verification and the unmatched list take calls by
  their Mock, `POST`, the method's path and their metadata as headers. See
  [The Journal and the
  metrics](docs/grpc/rendering-and-journal.md#the-journal-and-the-metrics).
- The release benchmark measures gRPC calls, in a gRPC variant of its
  definitions, `bench/definitions-grpc/`: the plain set with a gRPC Mock,
  its Stubs and its Descriptor set. Its own mix,
  `bench/requests-grpc.json`, holds three kinds of call: one matched by a
  condition on the message, one with a templated reply, and one answered
  NOT_FOUND as Trailers-Only. Each takes its framed message from a file
  (a request of a mix may now name a `bodyFile`, which oha sends with
  `-D`). `bench/plan-autopilot.json`'s new case `grpc-keep-alive` sends
  them over h2c, 64 keep-alive connections, one call at a time on each. It
  runs only when smock serves the gRPC variant, in about 11 minutes, and
  such a run runs no other case, so runs of the other definitions take no
  longer. It has no target: oha counts a call by its HTTP status, which is
  200 whatever the gRPC status, and `e2e/bench_test.mbt` checks each
  call's gRPC status instead. On GKE, variants with the new `grpc` option
  serve it (`scripts/gke-bench.sh --variant LABEL=FILE,grpc`). See
  [gRPC calls in the benchmark](bench/README.md#grpc-calls-in-the-benchmark).

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
  statuses beside HTTP/1.1's: 400, 413 and 431 on its stream. They also
  name gRPC's refusals: 405, 400, or 200 with the gRPC status
  UNIMPLEMENTED, INTERNAL or RESOURCE_EXHAUSTED. They say that, for a
  Mock, `stub=""` also counts the gRPC calls that its built-in health and
  reflection services answer, which are not unmatched requests.
- The help texts of `--body-limit`, `--state-max-bytes` and
  `smock_state_writes_refused_total` say what a gRPC call gets where an
  HTTP request gets 413 or 507: RESOURCE_EXHAUSTED.
- The help texts of `--header-size-limit` and `--read-timeout-ms` give
  their meaning over HTTP/2. A header list is counted as RFC 7541 counts
  it, each field with 32 octets more, and a larger one gets 431 on its
  stream, while a header block over twice the limit closes the
  connection. So a head that fits over HTTP/1.1 can get 431 over HTTP/2
  ([Header lists](docs/http2.md#header-lists)). A request that does not
  arrive in time resets its stream instead of closing the connection.
- The help texts of `--replicas`, `--header-count-limit` and
  `--journal-max-entries` give their ranges, as the help text of
  `--http2-max-concurrent-streams` does: `--replicas` from 1 to 10000, and
  the other two from 1 to 1073741824 (2^30). These are the values smock
  already took. The running guide's [Settings](docs/running.md#settings)
  table gives the same ranges.
- The help texts of `--header-size-limit`, `--body-limit`,
  `--journal-body-limit` and the four timeouts give their ranges too:
  `--header-size-limit` from 1 to 1073741824 (2^30), `--body-limit` and
  `--journal-body-limit` from 0 to 1073741824, `--read-timeout-ms`,
  `--idle-timeout-ms` and `--write-timeout-ms` from 1 to 2147483647
  (2^31 - 1), and `--drain-timeout-ms` from 0 to 2147483647. These are the
  values smock already took. The running guide's
  [Settings](docs/running.md#settings) table now gives the same ranges, and
  the help of `smock check` and `smock render` gives the range of
  `--header-size-limit`, which they take as `smock serve` does.
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
  [gRPC Stubs](docs/definition-files/grpc.md#grpc-stubs).
- The Admin API document, `openapi/admin.json`, describes gRPC calls.
  `JournalEntry` is closed, so its new member changes the Admin API's
  contract; the other changes are to descriptions and to the render
  result.
  - **`JournalEntry`** gains `grpcStatus`, one of gRPC's seventeen status
    names, which a gRPC call's entry has, unless a `reset` or `close`
    Fault ended the call, and an HTTP request's does not. Its `Body` says
    what a gRPC call's recorded request holds: in `data` the decoded
    JSON, in `size` the octets of the DATA frames received, and in
    `truncated` whether the JSON was cut at `--journal-body-limit`.
  - **`templateError`** says that a gRPC call got INTERNAL instead of
    500, and that, for a gRPC call, it also says why a templated reply,
    once rendered, is not a message of the method's output type, why a
    rendered error detail is not a message of its type, and why a reply's
    metadata is too large to send.
  - **`dataError`** says that a gRPC call got INTERNAL instead of 500,
    with the message `data write failed`.
  - **The render result** gains the gRPC part of a reply: a gRPC Stub's
    rendering has `response.grpc` (`RenderedGrpc`), with the gRPC status,
    message, trailing metadata and error details a call gets, and an HTTP
    Stub's has none. The descriptions of the result, its `templateError`,
    its headers and its body say what a gRPC rendering shows: the reply
    message as JSON, never protobuf bytes, and INTERNAL when the Stub cannot
    serve its content or its rendered reply or details do not fit their
    types. The description of the render sample says how a gRPC Stub reads
    it: as a call to its method, whatever its method and Content-Type, which
    are only conditions, with its body as the request message in JSON,
    checked against the method's input type. A body that does not fit gets
    400 `invalid_request`, and makes `smock render` exit with status 1. See
    [Rendering a gRPC
    Stub](docs/grpc/rendering-and-journal.md#rendering-a-grpc-stub).
  - **`EphemeralStubInput`** says that an Ephemeral Stub may be a gRPC
    Stub, checked against its Mock's set, what a reload does to it, and
    that a call whose data write names a bucket a reload removed gets
    INTERNAL `data write failed`.
- `--header-size-limit` also bounds a gRPC reply's metadata. Each block a
  reply goes out in, its HEADERS and its trailers, or its one
  Trailers-Only block, may take at most the limit, counted as RFC 7541
  counts a header list, smock's own fields included. A static reply over
  it is a load error, and `smock check` warns about one over 8 KiB, the
  size gRPC lets a client limit each block to. A templated reply over it
  once rendered, and any reply over the SETTINGS_MAX_HEADER_LIST_SIZE the
  client advertised, gets Trailers-Only INTERNAL `reply metadata too
  large` instead, so the client does not fail in its framing layer, and
  `templateError` says why. `smock check` and `smock render` take
  `--header-size-limit` and `SMOCK_HEADER_SIZE_LIMIT` too, so they load a
  directory as `smock serve` does. See
  [Metadata size](docs/grpc/metadata-and-status.md#metadata-size).
- NOTICE names gRPC's `health.proto` (Apache-2.0), whose descriptor smock
  embeds for a Mock's built-in health service.
- The documentation is reorganised into shorter documents, which
  [docs/README.md](docs/README.md) lists. The README now holds the summary
  and the quick start. Running smock, the Admin API, the commands and
  installing are documents of their own: [docs/running.md](docs/running.md),
  [docs/admin-api.md](docs/admin-api.md),
  [docs/commands.md](docs/commands.md) and
  [docs/installing.md](docs/installing.md). The sections for contributors
  are in [CONTRIBUTING.md](CONTRIBUTING.md). The Definition-file reference,
  the gRPC guide, the Mockoon guide and the OpenAPI guide each keep their
  entry at the old path
  ([docs/definition-files.md](docs/definition-files.md),
  [docs/grpc.md](docs/grpc.md),
  [docs/migrating-from-mockoon.md](docs/migrating-from-mockoon.md) and
  [docs/importing-openapi.md](docs/importing-openapi.md)), and go on in
  documents under `docs/definition-files/`, `docs/grpc/`, `docs/mockoon/`
  and `docs/openapi/`. The repository's own links follow their sections. A
  link from elsewhere, such as an issue, to a section that moved lands at
  the top of the old document: a guide's entry, whose Contents leads on to
  the section, or the README, whose list of documents does. CI now checks
  the documents' links.

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
- The usage that `smock`, `smock help` and `smock --help` print now names
  gRPC in its description of smock, as the README's opening line does: "A
  mock server for HTTP/1.1, HTTP/2, HTTPS, Server-Sent Events and gRPC
  unary calls." It left gRPC out.
- The Helm chart writes every number from a values file in full. Helm
  reads such a number as a floating-point number, and the chart wrote some
  of a million or more in exponent form: `definitions.gitSync.depth:
  1000000` gave git-sync `--depth=1e+06`, and `definitions.gitSync.uid:
  1000680000` gave `runAsUser: 1.00068e+09`, where git-sync and
  Kubernetes take an integer. The Services' ports, the replica count in
  the notes after an install, and Definition files or body files given as
  numbers were written the same way.
- The Helm chart writes a tag, a ref, a name, a key or a path given as
  digits with those digits. YAML reads such a value as a number, and the
  chart wrote `image.tag: 2024` as the image
  `ghcr.io/hirunefu/smock:%!s(float64=2024)`, and the same for
  `definitions.gitSync.ref`, `definitions.gitSync.image.tag`,
  `adminAuth.tokenSecret.key` and the body-file subdirectory's path in the
  definitions volume. A Secret name or key of a million or more was
  written as `1.234567e+06`, a definitions directory inside a repository
  or an image failed to render, and the name of an existing ConfigMap went
  into the Pod as a number, also when the values file quoted it. The
  chart's README now says which values YAML and Helm change before the
  chart sees them, such as an integer above 2^53, and that quotes or
  `--set` keep them
  ([smock#396](https://github.com/hirunefu/smock/issues/396)).
- The certificate expiry metric, and the `expiry` of a reload's log entry,
  now give the notAfter of the certificate that the TLS port presents:
  the first block of the certificate file labelled `CERTIFICATE`,
  `X509 CERTIFICATE` or `TRUSTED CERTIFICATE`, the block OpenSSL loads.
  smock read the first block whose label ended with `CERTIFICATE`, so a
  file that started with an `ATTRIBUTE CERTIFICATE` got a metric of 0 and
  an `expiry` of null, and one that started with an `X.509 CERTIFICATE`,
  which OpenSSL skips, got that block's notAfter.
- A YAML Definition file or OpenAPI document that starts with two `---`
  markers with nothing but comments between them is now rejected as
  multiple documents, as the documents say: the first `---` starts an empty
  document and the second starts another. smock read the second `---` as
  the document's text, so `---` on two lines read as the string `---`
  ([smock#365](https://github.com/hirunefu/smock/issues/365)).
- In YAML, a `#` with no space or tab before it no longer starts a
  comment, as YAML says. After a quoted value or a flow collection, such
  as `key: "value"# note` or `[a, b]#note`, smock dropped the rest of the
  line as a comment; it now rejects the text, with "a comment needs a
  space before its #". Inside a plain value, as in `path: /a#b`, the `#`
  is part of the value, as before
  ([smock#366](https://github.com/hirunefu/smock/issues/366)).
- In YAML, a tab between two `-` on one line, as in `-<tab>- x`, is now
  rejected as a tab in indentation, as the documents say: the white space
  after the first `-` indents the nested sequence. smock read it as a
  nested sequence, and in an OpenAPI document `-<tab>-` read as `[[null]]`
  ([smock#367](https://github.com/hirunefu/smock/issues/367)).
- In a YAML block scalar, a tab after the spaces of the indentation is now
  text, as YAML says, also on a line that holds nothing else. smock read
  such a line as an empty line and dropped the tab: `foo: |`, then a line
  of one space and a tab, then `bar: 1`, read `foo` as `""`, and now reads
  it as `"\t\n"`. On a line of white space, a tab after fewer spaces than
  the indentation is now rejected as a tab in indentation; smock read that
  line as an empty line too
  ([smock#369](https://github.com/hirunefu/smock/issues/369)).
- In YAML, a tab between a `-` and a mapping that starts on its line, as
  in `-<tab>id: a`, is now rejected as a tab in indentation, as YAML says:
  the white space after the `-` indents the mapping. smock read it as the
  mapping, so a Definition file or an OpenAPI document written that way
  loaded, and is now rejected. A tab between a `-` and a scalar still
  separates them
  ([smock#382](https://github.com/hirunefu/smock/issues/382)).
- A poll that reads the files at once, with no quiet period, no longer
  reloads what it reads. File times are coarse, so the polls of the 2 s
  after a change read the Definition files and the certificate and key
  files, also right after startup when the files were written just
  before, and so do the polls while a problem reading the definitions
  directory lasts. A file rewritten in place just as such a read began
  was read half written, and reloaded: smock logged a failed reload, such
  as "TLS certificate reload failed" with "no PEM certificate found", or
  served a half-written set, such as a body file read empty, for about a
  second, until the next poll. Two files written 100 ms apart could be
  read apart the same way. When such a read finds the files changed,
  smock now waits for them to settle, as for any change, and then reloads
  them once ([smock#384](https://github.com/hirunefu/smock/issues/384)).
- After a rotation to a certificate whose notAfter smock cannot read, the
  certificate expiry metric now gives 0 for it, as at startup. It kept the
  notAfter of the certificate before, which the TLS port no longer
  presented, so an alert on the metric watched a certificate that was no
  longer served. A failed reload still keeps the series of the certificate
  that smock keeps presenting
  ([smock#385](https://github.com/hirunefu/smock/issues/385)).
- A TLS client that sends its ClientHello slowly, in many small records,
  no longer costs smock seconds of CPU before the handshake. smock reads
  the name the client asks for by SNI again each time more octets arrive,
  and copied what it had of the ClientHello once for every record, so a
  client that sent a record of one octet every few milliseconds cost
  about 5 s of CPU on an Apple M1, and a dozen such clients stalled every
  port until the idle timeout cut them. A reading now walks each record
  once and copies the ClientHello at most once, when it is whole: such a
  client costs about 0.2 s, and a ClientHello in one record costs less
  than before ([smock#388](https://github.com/hirunefu/smock/issues/388)).
- The certificate expiry metric, and the `expiry` of a reload's log entry,
  now give the notAfter of the leaf that the TLS port presents when the
  certificate file starts with a UTF-8 byte order mark, as Windows
  PowerShell 5.1's `Out-File -Encoding utf8` writes it. OpenSSL drops the
  mark and presents the leaf. smock kept it, skipped the leaf and read the
  next certificate, so a chain got the notAfter of the certificate after
  the leaf, usually years later, and a certificate alone got 0. smock now
  drops the mark where OpenSSL does: on the first line of the file, and on
  the line right after the END line of a block that OpenSSL skips, such as
  a private key. A BEGIN line with white space before it is now no BEGIN
  line, as for OpenSSL, which then presents the certificate after it
  ([smock#389](https://github.com/hirunefu/smock/issues/389)).
- A numeric setting now takes a value in its range whatever its leading
  zeros. smock counted the zeros as digits, and refused a value with more
  characters than its largest value has digits: `--port=00000008080` was
  refused, and so were a seed of more than 16 characters and a response
  index of more than 2, such as `smock render --response=007` and the
  Admin render operation's `response=007`. A value is now read as the
  integer it writes, and its range alone decides. This holds for every
  integer setting of `smock serve`, `smock check` and `smock render`, by
  its flag or its `SMOCK_` variable, and for the Admin render operation's
  `seed` and `response`
  ([smock#426](https://github.com/hirunefu/smock/issues/426)).
- An HTTP/1.1 request whose Content-Length body would end more than
  2^31 - 1 bytes into what smock holds of its connection now waits for
  its body, as any other request does. With `--header-size-limit` and
  `--body-limit` both at 2^30, a head of 2^30 bytes with
  `Content-Length: 1073741824`, or a body that started after more than
  2^30 bytes of an earlier request still held, took the parser's position
  past what an Int32 holds: smock took the request with an empty body, or
  aborted ([smock#433](https://github.com/hirunefu/smock/issues/433)).

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
  [Verify the Helm chart](docs/installing.md#verify-the-helm-chart).
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
  timeouts. See [The write timeout](docs/running.md#the-write-timeout).
- A `json` condition can match the last element of an array with
  `{ "$last": <condition> }`. It holds when the value is an array with at
  least one element, and its last element meets the condition, so a Stub
  can match the last message of a conversation, such as
  `messages: { $last: { role: tool } }`. It nests with the other
  operators. No file changes meaning: a lone `$last` key failed to load
  before, and `$$last` still means the key `$last`. See
  [Operators in json conditions](docs/definition-files/matching.md#operators-in-json-conditions).
- A template helper, `last(array)`, gives the last element of an array,
  with its own type, and steps can follow it, so
  `${last(body.messages).content}` quotes the last message of a
  conversation. An empty array gives a missing value, so `??` applies.
  Since a response reads the Data buckets after its own Stub's writes,
  `${last(data.orders)}` answers the item that the Stub's `append` just
  added, its new key included. See
  [Arrays](docs/definition-files/template-helpers.md#arrays).
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
  [LLM responses](docs/definition-files/llm-responses.md#llm-responses).
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
  [Logs](docs/running.md#logs).

### Changed

- `scripts/verify-image.sh` requires the runtime, mimalloc and simdutf in
  each SBOM, so it refuses the images of 0.3.0 and earlier. Check one of
  those with the script from its own tag, such as
  `git show v0.3.0:scripts/verify-image.sh`.
- The docs' templated Server-Sent Events example now ends with `data:
  [DONE]` alone, without `event: done`. OpenAI's `[DONE]` frame has no
  `event:` line, and a stream written by hand could copy the old one. The
  example points to [LLM
  responses](docs/definition-files/llm-responses.md#llm-responses), which
  write an LLM API's reply in its wire form.
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
