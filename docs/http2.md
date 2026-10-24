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

The response carries the Stub's status and headers, with the names in
lower case, and its body.

## The Journal

An HTTP/2 request is in the Journal like any other, with `version`
`HTTP/2`. Its `target` is `:path`, its `host` is the Host from
`:authority` or the `host` field, and its `headers` are the regular fields
as the Stubs saw them, cookies joined. So an HTTP/1.1 request and an
HTTP/2 request for the same call read alike, and Journal queries,
verification and the unmatched requests count both.
The request metrics count HTTP/2 requests with the same `mock` and `stub`
labels as HTTP/1.1 ones.

## Where HTTP/2 comes from

smock's HTTP/2 framing, header compression and connection state come from
the `http2` package of moonbitstack/moonhttp 0.14.0, a MoonBit module with
no I/O and no C ([ADR 0005](adr/0005-http2-comes-from-moonhttp.md)).
smock pins it to that exact version: CI fails when the build resolves
another one. CI also checks that moonhttp and the modules it imports bring
no C. A new version comes only on purpose, after h2spec, the e2e tests, a
check by hand with other clients and the benchmarks
([Upgrading moonhttp](releasing.md#upgrading-moonhttp)).
