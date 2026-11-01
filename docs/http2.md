# HTTP/2

smock serves HTTP/2 beside HTTP/1.1, with the same Mocks and Stubs. This
guide says how clients reach smock over HTTP/2, on a machine and behind a
load balancer, and what a Stub and the Journal see of an HTTP/2 request.
It then says how smock bounds what one HTTP/2 connection can cost: its
limits, timeouts and defences.

## Contents

- [h2c on the plain port](#h2c-on-the-plain-port)
- [h2 on the TLS port](#h2-on-the-tls-port)
  - [Turning h2 off](#turning-h2-off)
  - [TLS 1.2](#tls-12)
- [Clients](#clients)
  - [curl](#curl)
  - [Go](#go)
  - [The JVM](#the-jvm)
  - [Browsers](#browsers)
- [Kubernetes and load balancers](#kubernetes-and-load-balancers)
- [What a Stub sees](#what-a-stub-sees)
  - [CONNECT](#connect)
- [Requests smock refuses](#requests-smock-refuses)
- [Responses](#responses)
- [Streams that wait](#streams-that-wait)
- [Server-Sent Events](#server-sent-events)
- [Faults](#faults)
- [The Journal](#the-journal)
- [Logs](#logs)
- [Limits and timeouts](#limits-and-timeouts)
  - [The output bound](#the-output-bound)
  - [Request bodies](#request-bodies)
  - [Header lists](#header-lists)
  - [Timeouts](#timeouts)
  - [Defences](#defences)
  - [Frames that do no work](#frames-that-do-no-work)
- [The drain](#the-drain)
- [Connection errors](#connection-errors)
- [Where HTTP/2 comes from](#where-http2-comes-from)

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

## Clients

A client reaches smock over HTTP/2 in one of two ways: h2c on the plain
port, when it knows in advance that the port speaks HTTP/2, or h2 on the
TLS port, when it offers `h2` by ALPN. A client that asks for h2c with
`Upgrade: h2c` gets HTTP/1.1 instead, since smock ignores the upgrade.

| Client | Plain port | TLS port |
|---|---|---|
| [curl](#curl) | HTTP/2 with `--http2-prior-knowledge`, else HTTP/1.1 | HTTP/2 |
| [Go](#go) | HTTP/2 when unencrypted HTTP/2 is the transport's only protocol, else HTTP/1.1 | HTTP/2 |
| [Java's built-in client](#the-jvm) | HTTP/1.1: it asks for h2c only by `Upgrade` | HTTP/2 |
| [OkHttp](#the-jvm) | HTTP/2 when `H2_PRIOR_KNOWLEDGE` is its only protocol, else HTTP/1.1 | HTTP/2 |
| [Browsers](#browsers) | HTTP/1.1: no browser speaks h2c | HTTP/2, with a certificate the browser trusts |

On the TLS port, each of them must trust smock's certificate, as the
sections below say, and gets HTTP/1.1 with `--tls-http2 off`. A request's
Journal entry tells which protocol it used, in its `version`
([The Journal](#the-journal)).

### curl

```sh
curl --http2-prior-knowledge http://localhost:8080/users/1   # h2c
curl --cacert smock.pem https://localhost:8443/users/1       # h2, by ALPN
```

- `--http2-prior-knowledge` sends the HTTP/2 preface at once, so the plain
  port serves the request over h2c.
- On the plain port, `--http2` alone asks for h2c with `Upgrade: h2c`, so
  it gets HTTP/1.1.
- On the TLS port, curl offers `h2` and `http/1.1` by default, when it is
  built with HTTP/2 support, as `--http2` asks it to. `--http1.1` offers
  `http/1.1` alone, and gets HTTP/1.1.
- `smock.pem` is smock's self-signed certificate, read from the handshake
  as [Run](../README.md#run) shows. `--insecure` skips the check instead.
  With a certificate that curl trusts, leave both out.
- `-w '%{http_version}\n'` prints `2` for a response over HTTP/2, and `-v`
  shows what ALPN chose, such as `ALPN: server accepted h2`.

### Go

From Go 1.24, `net/http` speaks h2c by prior knowledge when unencrypted
HTTP/2 is the transport's only protocol. Every request to an `http://` URL
then goes over h2c:

```go
protocols := new(http.Protocols)
protocols.SetUnencryptedHTTP2(true)
client := &http.Client{Transport: &http.Transport{Protocols: protocols}}
resp, err := client.Get("http://localhost:8080/users/1")
```

Before Go 1.24, the `Transport` of `golang.org/x/net/http2` does the same,
with `AllowHTTP` set and a `DialTLSContext` that dials plain TCP. A
transport with the default protocols speaks HTTP/1.1 to the plain port.

Over TLS, Go's default transport, which `http.Get` uses, offers `h2` and
`http/1.1`, and gets HTTP/2 when the system trusts smock's certificate.
On Linux, `SSL_CERT_FILE=smock.pem` makes a Go program trust smock's
self-signed certificate in place of the system's certificates. A
transport with a `TLSClientConfig` of its own, such as one that trusts
smock's self-signed certificate, turns HTTP/2 off, and gets HTTP/1.1,
unless `ForceAttemptHTTP2` is set:

```go
pem, err := os.ReadFile("smock.pem")
if err != nil {
	log.Fatal(err)
}
roots := x509.NewCertPool()
roots.AppendCertsFromPEM(pem)
client := &http.Client{Transport: &http.Transport{
	TLSClientConfig:   &tls.Config{RootCAs: roots},
	ForceAttemptHTTP2: true,
}}
resp, err := client.Get("https://localhost:8443/users/1")
```

`resp.Proto` is `HTTP/2.0` for a response over HTTP/2.

### The JVM

Java's built-in client, `java.net.http.HttpClient` (Java 11 and later),
prefers HTTP/2 by default. But it asks for h2c only with `Upgrade: h2c`,
and has no way to send the preface by prior knowledge:

- On the TLS port, it offers `h2` and `http/1.1` by ALPN, and gets HTTP/2:
  `response.version()` is `HTTP_2`.
- On the plain port, smock ignores the upgrade and answers over HTTP/1.1:
  `response.version()` is `HTTP_1_1`, and the Journal entry's `version` is
  `HTTP/1.1`.

```java
HttpClient client = HttpClient.newHttpClient();
HttpRequest request =
    HttpRequest.newBuilder(URI.create("https://localhost:8443/users/1")).build();
HttpResponse<String> response =
    client.send(request, HttpResponse.BodyHandlers.ofString());
```

To trust smock's self-signed certificate, add it to a trust store with
`keytool -importcert`, and give the JVM that trust store and its password,
or build the client with an `SSLContext` that trusts it. The password is
needed: `keytool` encrypts the certificates in the PKCS12 store it makes,
so a JVM given the store without its password finds no certificate in it,
and the handshake fails. OkHttp, below, reads the same store.

```sh
keytool -importcert -noprompt -alias smock -file smock.pem \
  -keystore smock.p12 -storepass changeit
java -Djavax.net.ssl.trustStore=smock.p12 \
  -Djavax.net.ssl.trustStorePassword=changeit ...
```

OkHttp sends the preface by prior knowledge when
`Protocol.H2_PRIOR_KNOWLEDGE` is its only protocol, so such a client speaks
h2c to the plain port:

```java
OkHttpClient client = new OkHttpClient.Builder()
    .protocols(List.of(Protocol.H2_PRIOR_KNOWLEDGE))
    .build();
```

With its default protocols, OkHttp offers `h2` and `http/1.1` on the TLS
port, and gets HTTP/2, but speaks HTTP/1.1 to the plain port.

### Browsers

Browsers speak HTTP/2 over TLS only. On the plain port, they get HTTP/1.1,
as any client that sends no preface does. On the TLS port, they offer `h2`
and `http/1.1`, and get HTTP/2, with a certificate they trust:

- A browser does not trust smock's self-signed certificate, which is new
  each time smock starts. Give smock certificate files from a certificate
  authority that the browser trusts, with a name for each Host the page
  calls (`--tls-cert-file` and `--tls-key-file`, or a Mock's own with
  `--tls-mock-certs`; see [Run](../README.md#run)). For local use, a
  certificate authority of your own, added to the trust store of the
  system or of the browser, will do.
- The developer tools' network panel shows each request's protocol: `h2`
  for HTTP/2.

A browser sends the requests of a page over as few connections as it can.
It may send those for several Hosts over one connection, when the
certificate covers them all. Each request still reaches the Mock that its
own `:authority` names ([h2 on the TLS port](#h2-on-the-tls-port)). The
EventSources of a page can share one connection too, each on an HTTP/2
stream of its own ([Server-Sent Events](#server-sent-events)).

## Kubernetes and load balancers

A load balancer or a gateway in front of smock often ends TLS itself, and
sends the requests on to smock's plain port. It can speak h2c to that
port, so that HTTP/2 reaches smock end to end: the client speaks h2 to the
load balancer, and the load balancer speaks HTTP/2 by prior knowledge to
the Pod. smock serves such a connection as any other h2c connection. Each
request's Host comes from the `:authority` that the load balancer sends,
and its Journal entry has the version `HTTP/2`.

A load balancer that speaks HTTP/1.1 to the plain port still works, since
the port serves both. smock then sees HTTP/1.1, whatever the client spoke
to the load balancer, and the Journal records `HTTP/1.1`. A load balancer
that passes TLS through to the TLS port, without ending it, leaves the
choice to ALPN, between the client and smock
([h2 on the TLS port](#h2-on-the-tls-port)).

Some gateways and load balancers choose the protocol they speak to the
Pods from the `appProtocol` of the Service's port. The Helm chart sets
none by default: the plain port serves both HTTP/1.1 and h2c, so no single
value describes it. The chart's values `service.appProtocol.plain` and
`service.appProtocol.tls` set it on the traffic Service's plain and TLS
ports. For a gateway that speaks h2c to smock, set `kubernetes.io/h2c`,
which Kubernetes defines for HTTP/2 over cleartext, on the plain port:

```sh
helm install smock oci://ghcr.io/hirunefu/charts/smock --version <version> \
  --namespace mocks \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set service.appProtocol.plain=kubernetes.io/h2c
```

For the TLS port, use the value your gateway documents. See
[Ports, Services and probes](../charts/smock/README.md#ports-services-and-probes)
in the chart's README.

The admin port stays HTTP/1.1 only, so the probes, `/metrics` and the
Admin API work as before.

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
- a CONNECT whose `:authority` is not in the form a CONNECT needs (RFC
  9113, section 8.5): a host and a port, such as `proxy.example.com:443`,
  as the target of an HTTP/1.1 CONNECT is;
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
write timeout runs while the body waits ([Timeouts](#timeouts)). Nor does a
client that stops reading: a stream that waits sends at most 16 KiB at a
time, and more only once that has gone out
([The output bound](#the-output-bound)).

A stream that the client resets during its delay, or while its body waits
for window, stops waiting at once, and gets no more of its response. So do
a stream that smock resets because a frame the client sent on it breaks the
protocol, and every stream of a connection that closes. Each such request
is in the Journal, as a request whose client goes away is.

## Server-Sent Events

An [events Stub](definition-files.md#server-sent-events) streams one event
stream per HTTP/2 stream. So one connection can carry several event
streams at once, as a browser with several EventSources on one connection
opens them, and its other HTTP/2 streams are answered meanwhile.

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

## Faults

A Stub's [connection Fault](definition-files.md#connection-faults) takes
its nearest HTTP/2 form: it fails the request on its own stream, or, for
`close`, the connection. smock decides Faults as over HTTP/1.1, with the
same draws, so a probability and [`fault.seed` or
`--seed`](definition-files.md#seeds) give the same Faults over both.

| Fault | What the client receives | Journal entry |
|---|---|---|
| `reset` | Once the request has arrived in full, body included, RST_STREAM with `INTERNAL_ERROR` on its stream. The other streams of the connection go on. | No status. |
| `partial` | HEADERS, with the `content-length` of the whole body, and the first half of the body, or the first half of the events, rounded down, each after its delay. Then RST_STREAM with `INTERNAL_ERROR`. A response with no body to halve, such as one to HEAD, a 204, or an event stream of a single event, sends its HEADERS without ending the HTTP/2 stream, then the reset. | Its status. |
| `close` | GOAWAY with `NO_ERROR`, naming the highest stream the client has opened, then nothing more. smock reads and discards what the client sends, and closes the connection when the client closes it, or after a second. | No status. |

- A Fault with a delay comes once the delay is over, and holds up only its
  own stream, as any delay does ([Streams that wait](#streams-that-wait)).
  Half a body larger than the client's windows goes out as the client
  widens them, then the reset.
- `close` ends the other streams of the connection with it. An HTTP/2
  stream whose response waits, for a delay, for window or for its next
  event, gets nothing more, and is in the Journal, as a request whose
  client goes away is. A stream whose request is still arriving never
  reaches the Mocks: smock reads no more frames once it has sent the
  GOAWAY. The stream ID the GOAWAY names is at least that of every stream
  smock has begun to answer, so a client knows that any of them may have
  reached the Mocks (RFC 9113, section 8.7), and that the streams above it
  did not.
- The request is in the Journal before its RST_STREAM or GOAWAY goes out.
- Over HTTP/2, no Fault resets the TCP connection: `reset` and `partial`
  reset a stream with RST_STREAM, a frame, and the connection that `close`
  ends closes with a FIN.

## The Journal

An HTTP/2 request is in the Journal like any other, with `version`
`HTTP/2`. Its `target` is `:path`, or `:authority` for a CONNECT, its
`host` is the Host from `:authority` or the `host` field, and its
`headers` are the regular fields as the Stubs saw them, cookies joined. So
an HTTP/1.1 request and an HTTP/2 request for the same call read alike,
and Journal queries, verification and the unmatched requests count both.
The request metrics count HTTP/2 requests with the same `mock` and `stub`
labels as HTTP/1.1 ones.

## Logs

In the `mockoon` log format ([Run](../README.md#run)), each HTTP/2 request
a Mock handles gets a `Transaction recorded` line, as an HTTP/1.1 request
does. Its `requestMethod` is `:method`, and its `requestPath` is `:path`
up to the `?`, or `:authority` for a CONNECT. The line comes once the
stream's response has ended, with the time then:

- A response sent at once logs once its last frame is written, before
  smock reads more from the connection.
- A response that waits, for a delay, for the client's windows or for its
  events, logs once its last frame is written: after the delay, or after
  the last event. It holds up no other stream's line.
- A `reset` Fault logs `"fault":"reset"` and a `close` Fault
  `"fault":"close"`, with no `responseStatus`, once the RST_STREAM or the
  GOAWAY is written. A `partial` Fault logs its status.
- A stream whose response waits when the client resets it, or when a
  `close` Fault on another stream ends the connection, logs its planned
  status at once, as the Journal records it.
- The write timeout: a stream it resets logs when the RST_STREAM is
  written, and the streams of a connection it closes log when the
  connection ends, each with its planned status.
- The streams of a connection that ends while they wait, as when the
  client closes it, or the drain timeout cuts it, log when it ends, before
  `drain ended`.

A stream that never reaches a Mock gets no line, as a request the HTTP/1.1
codec rejects gets none: one that gets 400, 413 or 431, one refused past
`--http2-max-concurrent-streams`, one reset because its request is late,
one the client resets before its request has arrived, and one above the
final GOAWAY of a drain. When a Stub's template or data write fails, the
`Error while serving the content: …` line comes just before its stream's
line. A defence's line ([Defences](#defences)) is one of smock's own, in
the same envelope.

A reader of stdout that stops reading holds up a connection with a line to
write: its reader, before it reads again, and the task of a stream whose
response waited, as it ends. Other connections go on.

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
So the request bodies one connection holds in memory at once can reach
the concurrent-streams limit times the body limit: 100 × 10 MiB, about
1 GiB, with the defaults, against 10 MiB for an HTTP/1.1 connection. Flow
control does not bound it, since smock hands back the window of each DATA
frame as soon as the frame arrives. For a small Pod, lower either flag,
such as `--http2-max-concurrent-streams 10` or a smaller `--body-limit`.

### The output bound

What smock queues for one connection to write is bounded too, by 16 KiB
(16,384 octets):

- Once the output smock has queued for the connection, and not yet
  written, passes 16 KiB, smock writes it before it reads the client's
  next frame. That output is everything smock sends: responses, resets,
  and the replies it owes, such as PING acknowledgements.
- An HTTP/2 stream that waits, for its delay, for window or between its
  events, sends at most 16 KiB at a time, its DATA frame's header
  included, and only once what was queued before has gone out.

So a client that stops reading makes smock stop reading too, even with
its windows open wide. One connection then holds no more than 16 KiB of
output, plus the replies and responses to the last frame smock read, such
as a body that fits the client's windows, and the write timeout closes
the connection in the end ([Timeouts](#timeouts)). A client that pauses
and then reads again gets every response.

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
  connection for the rest. smock logs it as a CONTINUATION flood
  ([Defences](#defences)).

So a list just over the limit gets a 431, which tells the client why,
while what moonhttp holds of one header block, and of the list it decodes
to, stays within twice the limit.

moonhttp 0.14.0 counts a decoded list in 32 bits, so its count wraps past
2^31 octets, and moonhttp then passes the list on instead of resetting the
stream. A block reaches that only when it may be over 524,288 octets, with
a `--header-size-limit` over 262,144: each octet names at most one table
entry, of at most 4,096 octets. smock's own count still refuses such a list
with 431.

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
  for a connection's first octet, as over HTTP/1.1. From that octet, the
  rest of the preface has the read timeout instead, on either port, and
  the idle timeout runs again once the preface is whole. On the TLS port,
  a preface that does not arrive in time gets GOAWAY `NO_ERROR`, after
  smock's SETTINGS, and the connection closes.
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
| Rapid Reset (CVE-2023-44487) and MadeYouReset (CVE-2025-8671): streams opened, then reset before smock has finished their responses | More than 100 such streams, which are also more than half of all the streams the client opened. A stream counts when the client resets it, or when moonhttp resets it for a stream error the client's frames caused, whatever the code: a WINDOW_UPDATE of 0 or one that overflows the window, DATA or HEADERS after the end of the request, or a PRIORITY frame that makes the stream depend on itself. A stream refused at open counts too, but `REFUSED_STREAM` past the concurrent-streams limit only once the client has acknowledged smock's SETTINGS, since it may not know the limit before. smock's own resets never count: Faults, timeouts, a stream window held at zero, and the resets after 400, 413 and 431. Nor do the streams ignored after the final GOAWAY of [the drain](#the-drain). A stream that smock answered at once has ended before the client's reset arrives, so that reset is a frame that does no work instead ([Frames that do no work](#frames-that-do-no-work)). A reset stream stops at once ([Streams that wait](#streams-that-wait)). | GOAWAY `ENHANCE_YOUR_CALM`, and the connection closes. |
| Too many streams at once | `--http2-max-concurrent-streams` | RST_STREAM `REFUSED_STREAM` on the new stream. |
| CONTINUATION flood (2024): a header block that never ends, as CONTINUATION frames keep coming | A header block, its HEADERS and CONTINUATION frames together, holds at most twice `--header-size-limit` octets as received, the bound moonhttp keeps ([Header lists](#header-lists)), and ends within `--read-timeout-ms` ([Timeouts](#timeouts)). An empty CONTINUATION frame that does not end its block is a frame that does no work ([Frames that do no work](#frames-that-do-no-work)). | GOAWAY `ENHANCE_YOUR_CALM`, and the connection closes, for a block over the bound. A block still open at the read timeout is a timeout instead: GOAWAY `NO_ERROR`, and the connection closes, with no log line. |
| HPACK bomb: a small header block that decodes to a large list, such as one that names a large table entry over and over | moonhttp keeps no more of a decoded list than twice `--header-size-limit`, counted as RFC 7541 counts it. smock then holds the list to `--header-size-limit` and `--header-count-limit` ([Header lists](#header-lists)). The table smock decodes header blocks with is 4,096 octets. So is the one it encodes responses with, however large a table the client allows: smock lowers a larger SETTINGS_HEADER_TABLE_SIZE to 4,096 before moonhttp sees it, since an encoder may use any table up to the size the client allows (RFC 7541, section 4.2). | 431 for a list over `--header-size-limit` or with too many fields. RST_STREAM `ENHANCE_YOUR_CALM`, with no status, for a list over twice it. A block that does not decode is a connection error, not a defence: GOAWAY `COMPRESSION_ERROR`, with no log line ([Connection errors](#connection-errors)). |
| Frames that do no work: SETTINGS, PING, PRIORITY, reset and empty-frame floods (CVE-2019-9512, -9513, -9514, -9515, -9518) | At most 100 in any one second ([Frames that do no work](#frames-that-do-no-work)). | GOAWAY `ENHANCE_YOUR_CALM`, and the connection closes. |
| A client that stops reading or keeps its windows at zero (CVE-2019-9517) | The output bound: once what smock has queued for the connection and not yet written passes 16 KiB, it stops reading and queues no more ([The output bound](#the-output-bound)). Then `--write-timeout-ms`: a write that makes no progress, or a body that waits for a window, for that long ([Timeouts](#timeouts)). | The connection closes, without GOAWAY. A stream whose own window alone stays at zero gets RST_STREAM `CANCEL`, and the connection goes on. |
| Data Dribble (CVE-2019-9511): windows opened a few octets at a time | The concurrent-streams limit and the size of the responses, not time. Each window update lets smock send, which starts the write timeout again, so a client that grants window an octet at a time gets its whole response, as a slow reader does over HTTP/1.1. | Nothing: smock sends one small DATA frame for each window update. |
| Header fields with empty names (CVE-2019-9516) | moonhttp refuses an empty field name. | RST_STREAM `PROTOCOL_ERROR` on that stream. |
| Request bodies | `--body-limit` per stream, under the concurrent-streams limit. | 413, then RST_STREAM `NO_ERROR` on that stream ([Request bodies](#request-bodies)). |

A defence that closes a connection with GOAWAY uses `ENHANCE_YOUR_CALM`,
and names the pattern in the GOAWAY's debug data. A header block over the
bound is the exception: moonhttp keeps that bound and sends the GOAWAY,
whose debug data gives its own reason, `a field block past
SETTINGS_MAX_HEADER_LIST_SIZE`. The connection then closes at once. Its
streams in progress end with it. A response still waiting, for its delay
or for the client's windows, goes no further, and its request's Journal
entry is committed then. A request still arriving never reaches the Mocks.
The client opens a new connection for the rest.

Unlike a timeout, such a close is logged: one line per connection, at
level `warn`, that names the pattern and the kind of frame that passed the
bound. No metric counts it. For a header block over the bound, the
pattern is `CONTINUATION flood`, and the frame `HEADERS` or
`CONTINUATION`, whichever took the block past the bound. For Rapid Reset
and MadeYouReset, the pattern is `Rapid Reset`, and the frame the one that
made the last stream count: `RST_STREAM` for the client's reset, the frame
for which moonhttp reset the stream, such as `WINDOW_UPDATE`, or `HEADERS`
or `CONTINUATION` for a stream refused at open.

```json
{"time":"2026-10-25T09:00:00.000Z","level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
{"time":"2026-10-25T09:00:00.000Z","level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"CONTINUATION flood","frame":"CONTINUATION"}
{"time":"2026-10-25T09:00:00.000Z","level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
```

### Frames that do no work

Some frames cost smock a little work each, or make it queue a reply, but
ask nothing of the Mocks. A client that sends more than 100 of them in any
one second, on one connection, gets GOAWAY `ENHANCE_YOUR_CALM`, as above.
The log line's `frame` names the kind of the frame that passed the bound.
These frames count:

- SETTINGS frames (`SETTINGS`). An acknowledgement counts only beyond the
  one smock is owed for its own SETTINGS (`SETTINGS acknowledgement`).
- PING frames (`PING`), beyond one for each HEADERS or DATA frame smock
  has sent on the connection. smock saves up at most 100 of these. So a
  client that sends a PING for each DATA frame it receives, to estimate
  its bandwidth, is not cut while responses stream to it, however many
  frames come between its PINGs. A PING acknowledgement counts when it
  answers no PING that smock sent (`PING acknowledgement`).
- PRIORITY frames (`PRIORITY`): smock ignores priority signals.
- DATA frames that carry no data, padded or not, and do not end their
  stream (`empty DATA`).
- CONTINUATION frames with no octets that do not end their header block
  (`empty CONTINUATION`).
- DATA, WINDOW_UPDATE and RST_STREAM frames on a stream that has closed
  (`DATA on a closed stream`, and so on), and HEADERS on a stream that
  smock reset, which are ignored (`HEADERS on a stream smock reset`).
  HEADERS on another stream that has closed end the connection at once
  ([Connection errors](#connection-errors)).
- Frames of a type that HTTP/2 does not define (`unknown type`).

The bound holds for any one second, however long the connection lives: a
client that sends such frames now and then is never cut. Frames that do
some work never count: HEADERS that open a stream, CONTINUATION frames
that carry part of a header block or end it, DATA that carries a body, and
WINDOW_UPDATE frames on the connection or on a stream in progress. The
replies these frames make smock owe fall under
[the output bound](#the-output-bound).

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
  `ENHANCE_YOUR_CALM` ([Header lists](#header-lists)), and is logged as a
  CONTINUATION flood ([Defences](#defences)).
- A connection that a defence closes with GOAWAY gets `ENHANCE_YOUR_CALM`,
  and is logged ([Defences](#defences)).
- A header block that does not decode gets `COMPRESSION_ERROR`: one with a
  Huffman code that holds EOS or is badly padded, an index that names no
  entry, or a table size update past 4,096 octets, the size of the table
  smock decodes with.
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
