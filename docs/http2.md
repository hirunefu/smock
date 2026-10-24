# HTTP/2

smock serves HTTP/2 beside HTTP/1.1, with the same Mocks and Stubs. This
guide says how a client reaches smock over HTTP/2, and what a Stub and the
Journal see of an HTTP/2 request.

## h2c on the plain port

On the plain port, a connection that starts with the HTTP/2 connection
preface is HTTP/2 in cleartext: h2c by prior knowledge (RFC 9113, section
3.4). Any other connection is HTTP/1.1, served as before. So one port
serves both, and a client that speaks HTTP/1.1 sees no change.

```sh
curl --http2-prior-knowledge http://localhost:8080/users/1
```

The client must know in advance that the port speaks HTTP/2, as curl's
`--http2-prior-knowledge` does. smock does not accept `Upgrade: h2c`, which
RFC 9113 deprecates: such a request is answered over HTTP/1.1, and the
upgrade is ignored.

The admin port serves HTTP/1.1 only. It never looks for the preface, so a
preface sent there gets `505 HTTP Version Not Supported`.

## What a Stub sees

Each HTTP/2 stream carries one request, which reaches the Mocks once the
client has sent all of it:

- `:method` is the method, and `:path` is the target, as sent. The path
  and the query come from it as from an HTTP/1.1 request target, and `*`
  with OPTIONS is the asterisk form.
- `:authority` is the Host, which chooses the Mock, as the Host header does
  over HTTP/1.1. Without `:authority`, the `host` field gives the Host. A
  request with neither has no Host, and the Default Mock answers it.
- The header fields are the regular fields, in the order sent, with their
  names in lower case, as HTTP/2 sends them. Header conditions and
  `header.NAME` compare names in any case, so they match as over HTTP/1.1.
  The pseudo-header fields (`:method`, `:path`, `:scheme` and
  `:authority`) are not among them. `:scheme` must be sent, but its value
  is not checked.
- No `host` field is added for `:authority`. `header.host` and a `host`
  header condition see only a `host` field the client sent, so tell Hosts
  apart with each Mock's `hosts`.
- Several `cookie` fields are joined into one with `; `, in their order, at
  the place of the first, as RFC 9113 requires. So cookie conditions,
  `cookie.NAME`, `header.cookie` and a header condition on `cookie` see
  what the one Cookie line of an HTTP/1.1 client gives.
- Request trailers are accepted and ignored, as HTTP/1.1 chunked trailers
  are.

Each stream of a connection is a request of its own. It goes to the Mock
its own `:authority` names, and its
[Session](../README.md#sessions-and-ephemeral-stubs) comes from its own
`baggage` field. So a browser that sends requests for several Hosts over one
connection reaches each Host's Mock, and tests that share a pooled
connection stay apart. Ephemeral Stubs, Scenarios, Variables, Data buckets
and CRUD Stubs work as over HTTP/1.1.

A stream that the client resets before it has sent all of its request
never reaches the Mocks: it has no Journal entry, and it moves no Scenario.

## Responses

A stream's response carries the Stub's status, headers and body, as an
HTTP/1.1 response does, adapted to the rules of HTTP/2:

- Header names are in lower case, as HTTP/2 requires. So are smock's own
  headers, `smock-mock` and `smock-near-miss`.
- Spaces and tabs around a value are trimmed, since HTTP/2 does not allow
  them there. Values go out as the same UTF-8 octets as over HTTP/1.1.
- `Keep-Alive`, `Upgrade`, `Proxy-Connection` and `TE` are left out, since
  HTTP/2 forbids them in a response (RFC 9113, section 8.2.2). So a Stub
  written for HTTP/1.1 still works over HTTP/2. No response has a
  `connection` field.
- `date` and `content-length` are sent as over HTTP/1.1. A Stub that gives
  its own Date sends that one alone. A response to HEAD carries the length
  of the body but not the body, and a 204 or 304 carries neither.
- Templates, several responses, body files and Range requests work as over
  HTTP/1.1, with the same statuses and bytes.

smock never pushes: it sends no PUSH_PROMISE.

## Streams that wait

A Stub's [delay](definition-files.md#delays) delays only its own stream.
The other streams of the connection are answered meanwhile, so a slow call
does not hold up the fast ones a client sends beside it on the same
connection, as with a real server.

A stream that the client resets during its delay stops waiting at once,
and gets no response. So do a stream that smock resets because a frame the
client sent on it breaks the protocol, and every stream of a connection
that closes. Each such request is in the Journal, as a request whose client
goes away is.

## The Journal

An HTTP/2 request is in the Journal like any other, with `version`
`HTTP/2`. Its `target` is `:path`, its `host` is the Host from
`:authority` or the `host` field, and its `headers` are the regular fields
as the Stubs saw them, cookies joined. So an HTTP/1.1 request and an
HTTP/2 request for the same call read alike, and Journal queries,
verification and the unmatched requests count both.
The request metrics count HTTP/2 requests with the same `mock` and `stub`
labels as HTTP/1.1 ones.

## Limits and timeouts

The limits and timeouts of `smock serve` apply to HTTP/2 too. One flag is
HTTP/2's own: `--http2-max-concurrent-streams`
(`SMOCK_HTTP2_MAX_CONCURRENT_STREAMS`), the most streams one connection may
have in progress at once. It is 100 by default, and can be from 1 to 1000.

- smock tells the client the limit in its SETTINGS, as
  SETTINGS_MAX_CONCURRENT_STREAMS, and holds the client to it from the
  first stream, before the client has acknowledged the SETTINGS.
- A stream is in progress from its HEADERS until both sides have ended it,
  or until either side resets it. So a stream still counts while its
  request arrives, and then until its response has gone out.
- A stream past the limit gets RST_STREAM `REFUSED_STREAM` and never
  reaches the Mocks: it has no Journal entry. The client may send that
  request again, since RFC 9113 says it was not processed (section 8.7).
  Frames the client sent on that stream before it learnt of the refusal
  are ignored.

Each stream in progress can hold a request body of up to `--body-limit`.
So the request bodies one connection holds at once can reach the
concurrent-streams limit times the body limit: 100 × 10 MiB with the
defaults, against 10 MiB for an HTTP/1.1 connection. For a small Pod, lower
either flag, such as `--http2-max-concurrent-streams 10` or a smaller
`--body-limit`.

### Defences

smock bounds what a client can make one connection cost. Each bound is per
connection.

| Pattern | Bound | Past it |
|---|---|---|
| Too many streams at once | `--http2-max-concurrent-streams` | RST_STREAM `REFUSED_STREAM` on the new stream. |

## Connection errors

Some errors end the whole connection, not just one stream. smock then
sends GOAWAY with the error code RFC 9113 gives, and closes the
connection. The streams answered before it stay answered, and the client
opens a new connection for the rest.

- A frame larger than 16,384 octets, the frame size smock advertises,
  gets `FRAME_SIZE_ERROR`.
- HEADERS on a stream ID that the client has already used get
  `PROTOCOL_ERROR` (RFC 9113, section 5.1.1). That covers a stream that
  has ended, one the client reset, and an ID the client skipped when it
  opened a higher one. Trailers on a stream still open are not affected.
- HEADERS on a stream that smock reset are ignored instead, since the
  client may have sent them before it learnt of the reset (section 5.1).
  smock remembers the last 256 streams it reset on a connection. HEADERS
  on one it reset before those end the connection.
- The other connection errors of RFC 9113, such as a frame that does not
  decode, get the code it gives them.

## Where HTTP/2 comes from

smock's HTTP/2 framing, header compression and connection state come from
the `http2` package of moonbitstack/moonhttp 0.14.0, a MoonBit module with
no I/O and no C ([ADR 0005](adr/0005-http2-comes-from-moonhttp.md)).
smock pins it to that exact version: CI fails when the build resolves
another one. CI also checks that moonhttp and the modules it imports bring
no C. A new version comes only on purpose, after h2spec, the e2e tests, a
check by hand with other clients and the benchmarks
([Upgrading moonhttp](releasing.md#upgrading-moonhttp)).

CI runs h2spec 2.6.0, which checks a server against RFC 7540 and RFC 7541,
against the plain port on every push.
[`scripts/h2spec/plain.txt`](../scripts/h2spec/plain.txt) lists the cases
that do not pass yet, each with its reason
([Build and test](../README.md#build-and-test)).
