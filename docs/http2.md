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

## h2 on the TLS port

On the TLS port, ALPN chooses the protocol. smock offers `h2`, then
`http/1.1`, with every certificate: the certificate files, the self-signed
certificate and a Mock's own. `--tls-http2 off` offers `http/1.1` alone
([Turning h2 off](#turning-h2-off)), and over TLS 1.2 `h2` needs a suite
that HTTP/2 allows ([TLS 1.2](#tls-12)).

- A client that offers `h2` gets HTTP/2, whether it also offers `http/1.1`
  or not. So a client that offers only `h2`, as some load generators do,
  completes the handshake.
- A client that offers only `http/1.1`, or sends no ALPN, gets HTTP/1.1, as
  before.
- A client that offers neither fails the handshake, with the
  `no_application_protocol` alert.

```sh
curl --http2 --insecure https://localhost:8443/users/1
```

curl's `--http2` offers `h2` and `http/1.1`. `--insecure` skips the check
of smock's self-signed certificate; leave it out with a certificate the
client trusts.

The TLS port never looks for the preface, since HTTP/2 over TLS needs ALPN
(RFC 9113, section 3.3). A connection that chose `http/1.1`, or no ALPN, is
HTTP/1.1, so a preface sent on it gets `505 HTTP Version Not Supported`.

SNI only chooses the certificate. Each stream goes to the Mock its own
`:authority` names, as the next section says. So a browser that sends
requests for several Hosts that the certificate covers over one connection
reaches each Host's Mock, and smock never answers `421 Misdirected
Request`.

Each port's `listening` log entry names the protocols it serves:
`["http/1.1", "h2c"]` on the plain port, `["h2", "http/1.1"]` on the TLS
port (`["http/1.1"]` with `--tls-http2 off`) and `["http/1.1"]` on the
admin port.

### Turning h2 off

`--tls-http2 off` (`SMOCK_TLS_HTTP2=off`) takes `h2` out of the TLS port's
ALPN, for every certificate, after reloads too. The TLS port then offers
`http/1.1` alone, as smock did before it served HTTP/2:

- A client that offers `h2` and `http/1.1` gets HTTP/1.1.
- A client that offers only `h2` fails the handshake, with the
  `no_application_protocol` alert.
- The TLS port's `listening` log entry names `["http/1.1"]`.

```sh
smock serve --dir defs --tls-http2 off
```

The flag is `on` by default. It does not change the plain port, which
still serves h2c to a client that sends the preface.

### TLS 1.2

The TLS port accepts TLS 1.2 and 1.3. Over TLS 1.3, HTTP/2 may use any
suite. Over TLS 1.2, RFC 9113 prohibits most suites (its Appendix A): every
suite without an ephemeral key exchange, such as `AES128-GCM-SHA256`, and
every suite without an AEAD cipher, such as the CBC suites. A strict client
fails a connection that negotiated `h2` over one of them. So on a TLS 1.2
connection whose suite is prohibited, smock leaves `h2` out of ALPN:

- A client that also offers `http/1.1` gets HTTP/1.1, as RFC 9113, section
  9.2.2, suggests.
- A client that offers only `h2` fails the handshake, with the
  `no_application_protocol` alert.

So over TLS 1.2, `h2` needs ECDHE or DHE with an AEAD cipher. smock sets
no DH parameters, so in practice it is ECDHE with AES-GCM or
ChaCha20-Poly1305. smock does not change which suites the TLS port
accepts: OpenSSL chooses the suite as before, and ALPN follows it.

The RFC's mandatory TLS 1.2 suite, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
with the P-256 curve, needs an RSA certificate. smock's self-signed
certificate is ECDSA P-256, so with it, HTTP/2 over TLS 1.2 uses ECDHE-ECDSA
suites, such as TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256. A client that
offers only the mandatory suite over TLS 1.2 needs certificate files with an
RSA key (`--tls-cert-file` and `--tls-key-file`). TLS 1.3 suites do not
depend on the key's type.

## What a Stub sees

Each HTTP/2 stream carries one request, which reaches the Mocks once the
client has sent all of it, except a CONNECT ([below](#connect)):

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

### CONNECT

A CONNECT carries `:authority` and no `:path`. It reaches the Mocks as soon
as its HEADERS arrive, without waiting for the client to end the stream:
it is the one request that does not. Its target is `:authority`, as the
authority-form target of an HTTP/1.1 CONNECT is, and so is its Host. So a
CONNECT to `proxy.example.com:443` goes to the Mock for
`proxy.example.com`, and a Stub matches it with `"method": "CONNECT"` and
a path pattern, such as `{ "pattern": "proxy\\.example\\.com:443" }`.

smock opens no tunnel. The response ends the stream, as any other does. A
2xx carries no `content-length` and no body, as RFC 9110, section 9.3.6,
requires, since after a 2xx the stream would carry the tunnel. Any other
status is sent as for any request, with its length and body, and an
unmatched CONNECT gets the same 404 as over HTTP/1.1. DATA the client
sends after the HEADERS is discarded, and its octets are handed back, so
the connection's window stays open.

## Requests smock refuses

smock refuses on a stream what it refuses over HTTP/1.1, with the HTTP/1.1
codec's own checks. Such a stream gets `400 Bad Request`, with no body:

- a method that is not a token;
- a `:path` that is not a path starting with `/`, or `*` with OPTIONS. So
  an absolute URI gets 400, and so does a fragment (`#`);
- a `:path` with a space, a control octet, DEL or an octet above 0x7E;
- an `:authority` that is not a valid Host;
- a CONNECT whose `:authority` is not a host and a port, such as
  `proxy.example.com:443`, which an HTTP/1.1 CONNECT's target must be (RFC
  9113, section 8.5);
- more than one `host` field, or a `host` that is not a valid Host;
- a `host` that names another host than `:authority` (RFC 9113, section
  8.3.1). Hosts are compared as Mock Hosts are: in any case, without the
  port and without a trailing dot. So `:authority` `orders.example.com` and
  `host` `ORDERS.example.com:8080` agree;
- a field name that is not a token;
- a field value with a control character other than tab, or with DEL.

A header list over `--header-size-limit`, or with more fields than
`--header-count-limit`, gets 431 instead, before these checks: see
[Header lists](#header-lists).

The 400 ends only its stream: it has no `connection` field, and the
connection's other streams go on. When the client has not sent all of the
request yet, the 400 is followed by RST_STREAM `PROTOCOL_ERROR`, so that
the client stops sending (RFC 9113, section 8.1.1). Frames that still
arrive on that stream are ignored. A request the client has sent in full
gets the 400 alone.

moonhttp itself resets a stream that breaks one of RFC 9113's field rules,
with RST_STREAM `PROTOCOL_ERROR` and no status:

- a field name with an upper-case letter, a space, a control octet, DEL or
  an octet above it, or a colon, and an empty field name;
- a field value with NUL, CR or LF, or with a space or a tab at either end;
- a field that is specific to an HTTP/1.1 connection, such as `connection`,
  `keep-alive`, `transfer-encoding` or `upgrade`, and a `te` other than
  `trailers`;
- a pseudo-header field that is missing, repeated, unknown, or after a
  regular field;
- a `content-length` that the body does not match.

Neither kind of stream reaches the Mocks: it has no Journal entry, and it
moves no Scenario. A stream refused with 400 counts in the request metrics
with `mock=""` and `stub=""`, as a request the HTTP/1.1 codec rejects does.
A stream that moonhttp resets is not counted.

A body over `--body-limit` gets `413 Content Too Large` on its stream
instead ([Request bodies](#request-bodies)).

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
  of the body but not the body, and a 204 or 304 carries neither, nor does
  a 2xx to a [CONNECT](#connect).
- Templates, several responses, body files and Range requests work as over
  HTTP/1.1, with the same statuses and bytes.

smock never pushes: it sends no PUSH_PROMISE.

## Streams that wait

A Stub's [delay](definition-files.md#delays) delays only its own stream.
The other streams of the connection are answered meanwhile, so a slow call
does not hold up the fast ones a client sends beside it on the same
connection, as with a real server.

A response body larger than the client's flow-control windows waits in
its own stream too. smock sends what the windows allow, in DATA frames no
larger than the client's frame size, and sends more each time the client
widens a window: with WINDOW_UPDATE for the stream or for the connection,
or with a SETTINGS frame that raises the initial window. So a client with
small windows still gets the whole body, and the other streams of the
connection go on meanwhile. When several streams wait for the connection
window, they get it in the order they began to wait, and a stream that has
sent what it was given waits behind the others. Priority signals are
accepted and ignored.

A client that keeps a window at zero does not hold a body for good: the
write timeout runs while the body waits ([Timeouts](#timeouts)).

A stream that the client resets during its delay, or while its body waits
for window, stops waiting at once, and gets no more of its response. So do
a stream that smock resets because a frame the client sent on it breaks the
protocol, and every stream of a connection that closes. Each such request
is in the Journal, as a request whose client goes away is.

## Server-Sent Events

An [events Stub](definition-files.md#server-sent-events) streams one event
stream per HTTP/2 stream. So one connection can carry several event
streams at once, as a browser with several EventSources on one connection
opens them, and its other streams are answered meanwhile.

- The HEADERS go out at once, or after the Stub's delay, with the Stub's
  status and headers. They carry `content-type: text/event-stream` and no
  `content-length`.
- Each event is encoded as over HTTP/1.1 and goes out as DATA after its
  delay. An event larger than the client's frame size goes out in several
  DATA frames. One larger than the flow-control windows waits for the
  client to widen them, as a large body does
  ([Streams that wait](#streams-that-wait)).
- The DATA of the last event ends the HTTP/2 stream. The request is in the
  Journal before the last event goes out, so a client that has all the
  events finds it there.
- A response with no body, to HEAD, with status 204 or 304, a 2xx to a
  [CONNECT](#connect), or with no events, is its HEADERS alone, which end
  the HTTP/2 stream at once.
- A client that resets the HTTP/2 stream ends the event stream at once, and
  so does a reset that smock sends because a frame the client sent on it
  breaks the protocol. No more events go out on it, and its request is in
  the Journal, as a request whose client goes away is. Over HTTP/1.1, smock
  learns that a client has gone only when it next writes an event; over
  HTTP/2, the RST_STREAM tells it at once.
- On SIGTERM, event streams go on until they end or the drain timeout cuts
  them, as over HTTP/1.1 ([The drain](#the-drain)).

## The Journal

An HTTP/2 request is in the Journal like any other, with `version`
`HTTP/2`. Its `target` is `:path`, or `:authority` for a CONNECT, its
`host` is the Host from `:authority` or the `host` field, and its
`headers` are the regular fields as the Stubs saw them, cookies joined. So
an HTTP/1.1 request and an HTTP/2 request for the same call read alike,
and Journal queries, verification and the unmatched requests count both.
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

### Request bodies

`--body-limit` applies to each stream alone, as it applies to each request
over HTTP/1.1.

- A `content-length` over the limit gets `413 Content Too Large` at once,
  before any of the body is read.
- A body that passes the limit as it arrives gets 413 then. smock keeps
  none of it past the limit.
- When the client has not sent all of the request yet, the 413 is followed
  by RST_STREAM `NO_ERROR`, which tells the client to stop sending the body
  (RFC 9113, section 8.1). Frames that still arrive on that stream are
  ignored. A request the client has sent in full gets the 413 alone.
- The 413 has no body, and ends only its stream: the connection's other
  streams go on. The stream never reaches the Mocks: it has no Journal
  entry, and it moves no Scenario. It counts in the request metrics with
  `mock=""` and `stub=""`, as a 400 does.

smock hands back to the client's flow-control windows every DATA octet it
takes, whether it keeps it or not. That covers the part of a body past the
limit, and what still arrives on a stream smock has answered. So refused
uploads do not use up the window that all the streams of a connection
share, and the next upload on the connection goes through.

A request whose HEADERS carry `expect: 100-continue` and do not end the
stream gets `100 Continue` at once, as over HTTP/1.1, so a client that
waits for it sends its body. One whose `content-length` is over the limit
gets 413 instead. One with a `content-length` of 0 has no body to send, so
it gets no `100 Continue`, as over HTTP/1.1.

### Header lists

`--header-size-limit` and `--header-count-limit` apply to the header list
of each stream: the fields of its HEADERS. A stream over either gets
`431 Request Header Fields Too Large` on that stream alone, as a request
over HTTP/1.1 does, and the connection's other streams go on.

- HTTP/2 counts a header list as RFC 7541 does (section 4.1): each field's
  name and value, as sent, plus 32 octets. The pseudo-header fields count,
  and so does every `cookie` field, before smock joins them. HTTP/1.1
  counts the octets of a request head, about 4 per field beyond its name
  and value (`: ` and the line end). So each field counts about 28 octets
  more over HTTP/2, and a head that fits over HTTP/1.1 can get 431 over
  HTTP/2: with 100 fields, it counts about 2,800 octets more. Raise
  `--header-size-limit` for clients that send many fields.
- `--header-count-limit` counts the regular fields. The pseudo-header
  fields do not count, so neither does `:authority`, where an HTTP/1.1
  `Host` field does. Several `cookie` fields count as one, as the one
  Cookie line of an HTTP/1.1 client does.
- When the client has not sent all of the request yet, the 431 is followed
  by RST_STREAM `NO_ERROR`, so that the client stops sending (RFC 9113,
  section 8.1). Frames that still arrive on that stream are ignored. A
  request the client has sent in full gets the 431 alone.
- The stream never reaches the Mocks: it has no Journal entry, and it
  moves no Scenario. It counts in the request metrics with `mock=""` and
  `stub=""`, as a request the HTTP/1.1 codec rejects does.

moonhttp, which decodes the header blocks, has a larger bound of its own:
twice `--header-size-limit`, at most 2^31-1 octets, so 32,768 octets (32
KiB) with the default. smock advertises it to the client as
SETTINGS_MAX_HEADER_LIST_SIZE, and moonhttp holds the client to it from the
first stream:

- A header list over the bound, counted as above once decoded, gets
  RST_STREAM `ENHANCE_YOUR_CALM` from moonhttp, with no status. The stream
  has no Journal entry, and no metric counts it.
- A header block over the bound as received, its HEADERS and CONTINUATION
  frames together, ends the connection with GOAWAY `ENHANCE_YOUR_CALM`.
  Every stream of the connection ends with it, and the client opens a new
  connection for the rest.

So a list just over the limit gets a 431, which tells the client why,
while what moonhttp holds of one header block, and of the list it decodes
to, stays within twice the limit.

### Timeouts

Over HTTP/2, the read, idle and write timeouts work per stream and per
connection.

- `--read-timeout-ms` applies to each stream alone, from the first frame of
  its request to its end. A stream whose request has not all arrived by
  then gets RST_STREAM `CANCEL`, and the connection's other streams go on.
  Its request never reaches the Mocks, so it has no Journal entry. A header
  block still open by then holds up the whole connection, since no other
  frame may come between its frames, so the connection gets GOAWAY
  `NO_ERROR` and closes instead.
- `--idle-timeout-ms` applies to a connection with no stream in progress.
  PING, SETTINGS and WINDOW_UPDATE frames do not restart it, and a header
  block that has begun holds it off. A new stream restarts it, and it runs
  again from the response that ends the last stream in progress. Past it,
  the connection gets GOAWAY `NO_ERROR` and closes. It also bounds the wait
  for a connection's first octet, as over HTTP/1.1. On the plain port, the
  rest of the preface has the read timeout from that octet. On the TLS
  port, where ALPN has already chosen HTTP/2, the idle timeout bounds the
  whole preface.
- `--write-timeout-ms` closes a connection that takes nothing of what smock
  writes for that long, without GOAWAY, as over HTTP/1.1. It also runs
  while a response body waits for the client to widen a flow-control
  window, so that a client cannot hold the body for good by keeping its
  windows at zero:
  - While a body waits for the connection window, the write timeout runs
    for the connection. A WINDOW_UPDATE for the connection starts it again.
    Past it, the connection closes, without GOAWAY, as when the client
    takes nothing.
  - While a body waits for its stream's own window, and the connection
    window is open, the write timeout runs for that stream alone. A
    WINDOW_UPDATE for the stream, or a SETTINGS frame that raises the
    initial window, starts it again. Past it, the stream gets RST_STREAM
    `CANCEL`, and the connection's other streams go on. Its request is in
    the Journal, as a request whose client goes away is.

  So a client that widens its windows slowly but steadily, a few octets at
  a time, gets its whole response, however long it takes in all. A
  WINDOW_UPDATE for one stream does not start the connection's write
  timeout again, nor does a SETTINGS frame, since neither lets smock send
  while the connection window is at zero. A client that stops widening a
  window for longer than the write timeout, as one that pauses to limit
  its download rate may, is cut, even where an HTTP/1.1 client pausing as
  long would not be, since the socket's buffers can take what smock writes
  meanwhile. Keep `--write-timeout-ms` above the longest pause your
  clients make.
- smock's own waits, such as a delay, count toward none of them.

After a GOAWAY with `NO_ERROR`, smock reads what the client still sends and
discards it, until the client closes the connection, or for one second at
most, and then closes. Closing a connection with unread input would make
the kernel send a reset, which can discard the GOAWAY before the client
reads it.

No timeout is logged, and none has a metric.

### Defences

smock bounds what a client can make one connection cost. Each bound is per
connection.

| Pattern | Bound | Past it |
|---|---|---|
| Too many streams at once | `--http2-max-concurrent-streams` | RST_STREAM `REFUSED_STREAM` on the new stream. |
| Frames that do no work: SETTINGS, PING, PRIORITY, reset and empty-frame floods (CVE-2019-9512, -9513, -9514, -9515, -9518) | At most 100 in any one second ([Frames that do no work](#frames-that-do-no-work)). | GOAWAY `ENHANCE_YOUR_CALM`, and the connection closes. |
| A client that stops reading or keeps its windows at zero (CVE-2019-9517) | `--write-timeout-ms`: a write that makes no progress, or a body that waits for a window, for that long ([Timeouts](#timeouts)). | The connection closes, without GOAWAY. A stream whose own window alone stays at zero gets RST_STREAM `CANCEL`, and the connection goes on. |
| Data Dribble (CVE-2019-9511): windows opened a few octets at a time | The concurrent-streams limit and the size of the responses, not time. Each window update lets smock send, which starts the write timeout again, so a client that grants window an octet at a time gets its whole response, as a slow reader does over HTTP/1.1. | Nothing: smock sends one small DATA frame for each window update. |
| Header fields with empty names (CVE-2019-9516) | moonhttp refuses an empty field name. | RST_STREAM `PROTOCOL_ERROR` on that stream. |
| Request bodies | `--body-limit` per stream, under the concurrent-streams limit. | 413, then RST_STREAM `NO_ERROR` on that stream ([Request bodies](#request-bodies)). |

A defence that closes a connection with GOAWAY uses `ENHANCE_YOUR_CALM`,
and names the pattern in the GOAWAY's debug data. The connection then
closes at once. Its streams in progress end with it. A response still
waiting, for its delay or for the client's windows, goes no further, and
its request's Journal entry is committed then. A request still arriving
never reaches the Mocks. The client opens a new connection for the rest.

Unlike a timeout, such a close is logged: one line per connection, at
level `warn`, that names the pattern and the kind of frame that passed the
bound. No metric counts it.

```json
{"time":"2026-10-25T09:00:00.000Z","level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
```

### Frames that do no work

Some frames cost smock a little work each, or make it queue a reply, but
ask nothing of the Mocks. A client that sends more than 100 of them in any
one second, on one connection, gets GOAWAY `ENHANCE_YOUR_CALM`, as above.
The log line's `frame` names the kind of the frame that passed the bound.
These frames count:

- SETTINGS frames (`SETTINGS`). An acknowledgement counts only beyond the
  one smock is owed for its own SETTINGS (`SETTINGS acknowledgement`).
- PING frames (`PING`), each only when smock has sent no HEADERS or DATA
  since the client's last PING. gRPC counts PINGs this way, so a client
  that sends a PING for each DATA frame it receives, to estimate its
  bandwidth, is not cut while responses stream to it. A PING
  acknowledgement counts when it answers no PING that smock sent
  (`PING acknowledgement`).
- PRIORITY frames (`PRIORITY`): smock ignores priority signals.
- DATA frames that carry no data, padded or not, and do not end their
  stream (`empty DATA`).
- DATA, WINDOW_UPDATE and RST_STREAM frames on a stream that has closed
  (`DATA on a closed stream`, and so on), and HEADERS on a stream that
  smock reset, which are ignored (`HEADERS on a stream smock reset`).
  HEADERS on another stream that has closed end the connection at once
  ([Connection errors](#connection-errors)).
- Frames of a type that HTTP/2 does not define (`unknown type`).

The bound holds for any one second, however long the connection lives: a
client that sends such frames now and then is never cut. Frames that do
some work never count: HEADERS that open a stream, DATA that carries a
body, and WINDOW_UPDATE frames on the connection or on a stream in
progress.

## The drain

On SIGTERM, smock drains each HTTP/2 connection in two steps, as RFC 9113
suggests (section 6.8), so that no request the client has sent is lost.

1. The connection, idle or not, gets GOAWAY with `NO_ERROR` and the
   highest stream ID there is, 2^31-1, then a PING. The client opens no
   more streams, and the streams it has already sent, which smock may not
   have received yet, are still served.
2. A client that answers the PING has read the GOAWAY. smock then sends a
   second GOAWAY with `NO_ERROR`, which names the last stream it received.
   When no answer comes, it sends it a second after the first.
3. The streams up to that ID finish, delays and event streams among them.
   The streams above it never reach the Mocks: the client sends them again
   on a new connection.
4. Once no stream is in progress, the connection closes, as after any
   GOAWAY with `NO_ERROR` ([Timeouts](#timeouts)). So a connection with no
   stream in progress closes about two seconds after SIGTERM at the latest,
   and sooner when its client answers the PING or closes the connection.

At the drain timeout (`--drain-timeout-ms`), what is still open is cut and
counted in `connectionsCut`, as over HTTP/1.1. See [Run](../README.md#run).

## Connection errors

Some errors end the whole connection, not just one stream. smock then
sends GOAWAY with the error code RFC 9113 gives, and closes the
connection. The streams answered before it stay answered, and the client
opens a new connection for the rest.

- A frame larger than 16,384 octets, the frame size smock advertises,
  gets `FRAME_SIZE_ERROR`.
- A header block over twice `--header-size-limit` as received gets
  `ENHANCE_YOUR_CALM` ([Header lists](#header-lists)).
- A connection that a defence closes with GOAWAY gets `ENHANCE_YOUR_CALM`,
  and is logged ([Defences](#defences)).
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
no C, and that [NOTICE](../NOTICE) and the image's SBOM name them all. A
new version comes only on purpose, after h2spec, the e2e tests, a check by
hand with other clients and the benchmarks
([Upgrading moonhttp](releasing.md#upgrading-moonhttp)).

CI runs h2spec 2.6.0, which checks a server against RFC 7540 and RFC 7541,
against the plain port and the TLS port on every push.
[`scripts/h2spec/plain.txt`](../scripts/h2spec/plain.txt) and
[`scripts/h2spec/tls.txt`](../scripts/h2spec/tls.txt) list the cases that
do not pass yet on each port, with their reasons
([Build and test](../README.md#build-and-test)).
