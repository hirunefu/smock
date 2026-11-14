// Seam 2 tests of how smock tells a gRPC call, on h2c on the plain port and
// over h2 on the TLS port: an HTTP/2 request whose `content-type` is
// `application/grpc`, alone or followed by `+` or `;`, is a gRPC call. A
// call with no subtype, or `proto`, is served; one with any other subtype,
// such as `json`, gets Trailers-Only UNIMPLEMENTED as soon as its HEADERS
// arrive. Every other content type, and every HTTP/1.1 request, goes to the
// HTTP Stubs. The set is gRPC's helloworld.proto, and the messages are
// protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, the gRPC Stub
/// `hello` on SayHello, and the HTTP Stub `http-greeter`, which answers a
/// POST to any path of the Greeter service that sends `x-route: http`.
let detection_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }
  #|  - id: http-greeter
  #|    mock: greeter
  #|    request:
  #|      method: POST
  #|      path: { pattern: "/helloworld\\.Greeter/.*" }
  #|      headers: { x-route: http }
  #|    response: { status: 200, body: http }

///|
/// Runs `f` with smock serving `detection_example` on its plain port and on
/// its TLS port, with the test certificate for `localhost`, and `args`.
async fn with_detection(
  args~ : Array[String] = [],
  f : async (Smock) -> Unit,
) -> Unit {
  with_greeter_set([("greeter.yaml", detection_example)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", ..certs.args(), ..args],
        f,
      )
    })
  })
}

///|
/// An HTTP/2 client of smock's plain port for `"h2c"`, or of its TLS port
/// for `"h2"`.
async fn Smock::h2_on(self : Smock, port : String) -> H2Client {
  if port == "h2c" {
    self.h2c()
  } else {
    self.h2()
  }
}

///|
/// The reply in short: its `:status`, its `grpc-status` and `grpc-message`,
/// from the trailers or from a Trailers-Only answer's HEADERS, how many DATA
/// frames came, and how the stream ended.
fn GrpcReply::outline(self : GrpcReply) -> String {
  let out = []
  let fields = match self.trailers {
    Some(trailers) => [..self.head, ..trailers]
    None => self.head
  }
  for field in fields {
    if field.0 is (":status" | "grpc-status" | "grpc-message") {
      out.push("\{field.0}: \{field.1}")
    }
  }
  out.push("\{self.data.length()} DATA")
  "\{out.join(", ")} (\{self.ended})"
}

///|
/// The Journal's entries, one per line: the version, the request's
/// `content-type` in any case, the Stub that matched, the HTTP status and the gRPC
/// status, each as JSON, `-` for a member that is absent.
async fn routes_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "version": String(version), "headers": Array(headers), .. }
          ),
          "stub": stub,
          "status": status,
          ..
        } as members
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    let mut content_type = "-"
    for header in headers {
      if header is { "name": String(name), "value": String(value), .. } &&
        name.to_lower() == "content-type" {
        content_type = value
      }
    }
    let grpc_status = match members.get("grpcStatus") {
      Some(value) => value.stringify()
      None => "-"
    }
    out.push(
      "\{version} \{content_type}: \{stub.stringify()} \{status.stringify()} \{grpc_status}",
    )
  }
  out.join("\n")
}

///|
async test "on h2c and over TLS, a call whose content type is application/grpc, alone, with +proto, or with ; parameters, is served alike, and is journaled with its content type as sent" {
  with_detection(smock => {
    let hello_reply = framed(@fs.read_file(hello_reply_path).binary())
    let out = []
    for port in ["h2c", "h2"] {
      let client = smock.h2_on(port)
      let content_types = [
        "application/grpc", "application/grpc+proto", "application/grpc;v=1", "application/grpc+proto; charset=utf-8",
        "application/grpc+",
      ]
      for content_type in content_types {
        let reply = client.call("/helloworld.Greeter/SayHello", content_type~)
        out.push(
          "\{port} \{content_type}: \{reply.outline()}, the reply protoc encodes: \{reply.data == [hello_reply]}",
        )
      }
      client.close()
    }
    out.push("Journal:")
    out.push(routes_journaled(smock))
    out.push(smock.metric("smock_requests_total"))
    inspect(
      out.join("\n"),
      content=(
        #|h2c application/grpc: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2c application/grpc+proto: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2c application/grpc;v=1: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2c application/grpc+proto; charset=utf-8: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2c application/grpc+: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2 application/grpc: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2 application/grpc+proto: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2 application/grpc;v=1: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2 application/grpc+proto; charset=utf-8: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|h2 application/grpc+: :status: 200, grpc-status: 0, 1 DATA (end), the reply protoc encodes: true
        #|Journal:
        #|HTTP/2 application/grpc: "hello" 200 "OK"
        #|HTTP/2 application/grpc+proto: "hello" 200 "OK"
        #|HTTP/2 application/grpc;v=1: "hello" 200 "OK"
        #|HTTP/2 application/grpc+proto; charset=utf-8: "hello" 200 "OK"
        #|HTTP/2 application/grpc+: "hello" 200 "OK"
        #|HTTP/2 application/grpc: "hello" 200 "OK"
        #|HTTP/2 application/grpc+proto: "hello" 200 "OK"
        #|HTTP/2 application/grpc;v=1: "hello" 200 "OK"
        #|HTTP/2 application/grpc+proto; charset=utf-8: "hello" 200 "OK"
        #|HTTP/2 application/grpc+: "hello" 200 "OK"
        #|smock_requests_total{mock="greeter",stub="hello"} 10
      ),
    )
  })
}

///|
async test "on h2c and over TLS, a call with another subtype, such as +json, gets Trailers-Only UNIMPLEMENTED as soon as its HEADERS arrive, then RST_STREAM NO_ERROR while the client still sends; it is not journaled, and counts as rejected traffic" {
  with_detection(smock => {
    let hello = framed(@fs.read_file(hello_request_path).binary())
    let path = "/helloworld.Greeter/SayHello"
    let out = []
    for tls in [false, true] {
      let raw = smock.raw_h2(tls~)
      out.push(if tls { "Over TLS:" } else { "On h2c:" })
      out.push(raw.acknowledge_settings())
      raw.send([
        headers_frame(
          1,
          raw.block(
            call_fields(path, "localhost", content_type="application/grpc+json"),
          ),
          end_stream=false,
        ),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push("+json, its request not ended:")
      out.push(raw.frames_until_ping_ack())
      raw.send([
        // Sent before the client learnt of the answer, as a client does:
        // ignored.
        Data(stream_id=1, data=hello, end_stream=true, padding=0),
        headers_frame(
          3,
          raw.block(
            call_fields(
              path,
              "localhost",
              content_type="application/grpc+protobuf; charset=utf-8",
            ),
          ),
        ),
      ])
      out.push("Its message, then +protobuf, whose HEADERS end the request:")
      out.push(raw.frames_until_stream_ends(3))
      raw.send([
        headers_frame(
          5,
          raw.block(call_fields(path, "localhost")),
          end_stream=false,
        ),
        Data(stream_id=5, data=hello, end_stream=true, padding=0),
      ])
      out.push("Then a call with no subtype:")
      out.push(raw.frames_until_stream_ends(5))
      raw.close()
    }
    out.push("Journal:")
    out.push(routes_journaled(smock))
    out.push(smock.metric("smock_requests_total"))
    out.push(smock.metric("smock_unmatched_requests_total"))
    inspect(
      out.join("\n"),
      content=(
        #|On h2c:
        #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
        #|+json, its request not ended:
        #|SETTINGS ACK
        #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: only the proto content subtype is served, date: <now>]
        #|RST_STREAM 1 NO_ERROR
        #|Its message, then +protobuf, whose HEADERS end the request:
        #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: only the proto content subtype is served, date: <now>]
        #|Then a call with no subtype:
        #|HEADERS 5 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
        #|DATA 5 16 octets
        #|HEADERS 5 END_STREAM END_HEADERS [grpc-status: 0]
        #|Over TLS:
        #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
        #|+json, its request not ended:
        #|SETTINGS ACK
        #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: only the proto content subtype is served, date: <now>]
        #|RST_STREAM 1 NO_ERROR
        #|Its message, then +protobuf, whose HEADERS end the request:
        #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: only the proto content subtype is served, date: <now>]
        #|Then a call with no subtype:
        #|HEADERS 5 END_HEADERS [:status: 200, content-type: application/grpc, smock-mock: greeter; via=default, date: <now>]
        #|DATA 5 16 octets
        #|HEADERS 5 END_STREAM END_HEADERS [grpc-status: 0]
        #|Journal:
        #|HTTP/2 application/grpc: "hello" 200 "OK"
        #|HTTP/2 application/grpc: "hello" 200 "OK"
        #|smock_requests_total{mock="",stub=""} 4
        #|smock_requests_total{mock="greeter",stub="hello"} 2
        #|
      ),
    )
  })
}

///|
/// What smock answers `request`, raw HTTP/1.1 that closes the connection,
/// on its plain port, or with `tls` on its TLS port, over a connection that
/// offers `http/1.1` alone by ALPN: the status line, each header field but
/// Date and Content-Length, then the body.
async fn Smock::http1_answer(
  self : Smock,
  request : String,
  tls~ : Bool,
) -> String {
  let received = if tls {
    let client = self.tls(alpn=["http/1.1"])
    defer client.close()
    client.write(@utf8.encode(request))
    client.read_all()
  } else {
    let conn = self.connect()
    defer conn.close()
    conn.write(request)
    let (_, _, received) = received_until_end(conn, @async.now())
    received
  }
  let text = @utf8.decode_lossy(received)
  let (head, body) = match text.find("\r\n\r\n") {
    Some(at) => (text[:at].to_owned(), text[at + 4:].to_owned())
    None => (text, "")
  }
  let kept = head
    .split("\r\n")
    .filter(line => {
      !(line.has_prefix("Date:") || line.has_prefix("Content-Length:"))
    })
    .map(line => line.to_owned())
    .collect()
  "\{kept.join(" | ")} | \{body}"
}

///|
async test "on h2c and over TLS, every other content type, gRPC-Web's included, goes to the HTTP Stubs, and so does a gRPC content type over HTTP/1.1 on both ports, then to noMatch" {
  with_detection(smock => {
    let path = "/helloworld.Greeter/SayHello"
    let out = []
    for port in ["h2c", "h2"] {
      let client = smock.h2_on(port)
      let content_types = [
        Some("application/grpc-web"),
        Some("application/grpc-web+proto"),
        Some("application/grpcx"),
        Some("application/json"),
        None,
      ]
      for content_type in content_types {
        let headers = [("x-route", "http")]
        if content_type is Some(value) {
          headers.push(("content-type", value))
        }
        let response = client.request(
          "POST",
          path,
          authority="localhost",
          headers~,
          body=b"x",
        )
        out.push(
          "\{port} \{content_type.unwrap_or("no content type")}: \{response.status} \{@utf8.decode_lossy(response.body)}",
        )
      }
      client.close()
    }
    let hello = @utf8.decode_lossy(
      framed(@fs.read_file(hello_request_path).binary()),
    )
    for tls in [false, true] {
      let port = if tls { "TLS" } else { "plain" }
      for route in [[("x-route", "http")], []] {
        let request = raw_request(
          "POST",
          path,
          host="localhost",
          headers=[
            ("Content-Type", "application/grpc"),
            ("TE", "trailers"),
            ("Connection", "close"),
            ..route,
          ],
          body=hello,
        )
        out.push(
          "HTTP/1.1 on the \{port} port, \{if route.is_empty() { "no x-route" } else { "x-route: http" }}: \{smock.http1_answer(request, tls~)}",
        )
      }
    }
    out.push("Journal:")
    out.push(routes_journaled(smock))
    out.push(smock.metric("smock_requests_total"))
    out.push(smock.metric("smock_unmatched_requests_total"))
    inspect(
      out.join("\n"),
      content=(
        #|h2c application/grpc-web: 200 http
        #|h2c application/grpc-web+proto: 200 http
        #|h2c application/grpcx: 200 http
        #|h2c application/json: 200 http
        #|h2c no content type: 200 http
        #|h2 application/grpc-web: 200 http
        #|h2 application/grpc-web+proto: 200 http
        #|h2 application/grpcx: 200 http
        #|h2 application/json: 200 http
        #|h2 no content type: 200 http
        #|HTTP/1.1 on the plain port, x-route: http: HTTP/1.1 200 OK | Smock-Mock: greeter; via=default | Connection: close | http
        #|HTTP/1.1 on the plain port, no x-route: HTTP/1.1 404 Not Found | Content-Type: application/json | Smock-Near-Miss: http-greeter; failed=header:x-route | Smock-Mock: greeter; via=default | Connection: close | {"error":"no Stub matched"}
        #|HTTP/1.1 on the TLS port, x-route: http: HTTP/1.1 200 OK | Smock-Mock: greeter; via=default | Connection: close | http
        #|HTTP/1.1 on the TLS port, no x-route: HTTP/1.1 404 Not Found | Content-Type: application/json | Smock-Near-Miss: http-greeter; failed=header:x-route | Smock-Mock: greeter; via=default | Connection: close | {"error":"no Stub matched"}
        #|Journal:
        #|HTTP/2 application/grpc-web: "http-greeter" 200 -
        #|HTTP/2 application/grpc-web+proto: "http-greeter" 200 -
        #|HTTP/2 application/grpcx: "http-greeter" 200 -
        #|HTTP/2 application/json: "http-greeter" 200 -
        #|HTTP/2 -: "http-greeter" 200 -
        #|HTTP/2 application/grpc-web: "http-greeter" 200 -
        #|HTTP/2 application/grpc-web+proto: "http-greeter" 200 -
        #|HTTP/2 application/grpcx: "http-greeter" 200 -
        #|HTTP/2 application/json: "http-greeter" 200 -
        #|HTTP/2 -: "http-greeter" 200 -
        #|HTTP/1.1 application/grpc: "http-greeter" 200 -
        #|HTTP/1.1 application/grpc: null 404 -
        #|HTTP/1.1 application/grpc: "http-greeter" 200 -
        #|HTTP/1.1 application/grpc: null 404 -
        #|smock_requests_total{mock="greeter",stub="http-greeter"} 12
        #|smock_requests_total{mock="greeter",stub=""} 2
        #|smock_unmatched_requests_total{mock="greeter"} 2
      ),
    )
  })
}

///|
async test "on h2c and over TLS, spec E's checks come first: a call over --header-size-limit gets 431, and a malformed one 400, with no gRPC status, whatever its subtype" {
  with_detection(args=["--header-size-limit", "1000"], smock => {
    let path = "/helloworld.Greeter/SayHello"
    let out = []
    for tls in [false, true] {
      let raw = smock.raw_h2(tls~)
      out.push(if tls { "Over TLS:" } else { "On h2c:" })
      out.push(raw.acknowledge_settings())
      let mut stream = 1
      for content_type in ["application/grpc", "application/grpc+json"] {
        let call = call_fields(path, "localhost", content_type~)
        raw.send([
          headers_frame(stream, raw.block(padded(call, 1001)), end_stream=false),
          headers_frame(
            stream + 2,
            raw.block([..call, ("x(bad)", "1")]),
            end_stream=false,
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        out.push(
          "\{content_type}, over the limit on stream \{stream}, and malformed on stream \{stream + 2}:",
        )
        out.push(raw.frames_until_ping_ack())
        stream += 4
      }
      raw.close()
    }
    out.push("Journal:")
    out.push(routes_journaled(smock))
    out.push(smock.metric("smock_requests_total"))
    inspect(
      out.join("\n"),
      content=(
        #|On h2c:
        #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2000]
        #|application/grpc, over the limit on stream 1, and malformed on stream 3:
        #|SETTINGS ACK
        #|HEADERS 1 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
        #|RST_STREAM 1 NO_ERROR
        #|HEADERS 3 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
        #|RST_STREAM 3 PROTOCOL_ERROR
        #|application/grpc+json, over the limit on stream 5, and malformed on stream 7:
        #|HEADERS 5 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
        #|RST_STREAM 5 NO_ERROR
        #|HEADERS 7 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
        #|RST_STREAM 7 PROTOCOL_ERROR
        #|Over TLS:
        #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=2000]
        #|application/grpc, over the limit on stream 1, and malformed on stream 3:
        #|SETTINGS ACK
        #|HEADERS 1 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
        #|RST_STREAM 1 NO_ERROR
        #|HEADERS 3 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
        #|RST_STREAM 3 PROTOCOL_ERROR
        #|application/grpc+json, over the limit on stream 5, and malformed on stream 7:
        #|HEADERS 5 END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0]
        #|RST_STREAM 5 NO_ERROR
        #|HEADERS 7 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
        #|RST_STREAM 7 PROTOCOL_ERROR
        #|Journal:
        #|
        #|smock_requests_total{mock="",stub=""} 8
      ),
    )
  })
}

///|
async test "with --tls-http2 off, the TLS port serves no gRPC: a client offering h2 alone fails the handshake, and a call sent over the HTTP/1.1 that one offering both gets goes to the HTTP Stubs; the plain port still serves calls" {
  with_detection(args=["--tls-http2", "off"], smock => {
    let path = "/helloworld.Greeter/SayHello"
    let out = ["offers [h2]: \{smock.alpn_offer(["h2"], path~)}"]
    let tls = smock.tls(alpn=["h2", "http/1.1"])
    out.push("offers [h2, http/1.1]: ALPN \{tls.protocol()}")
    let hello = @utf8.decode_lossy(
      framed(@fs.read_file(hello_request_path).binary()),
    )
    tls.write(
      @utf8.encode(
        raw_request(
          "POST",
          path,
          host="localhost",
          headers=[
            ("Content-Type", "application/grpc"),
            ("TE", "trailers"),
            ("Connection", "close"),
          ],
          body=hello,
        ),
      ),
    )
    out.push(
      "a call over HTTP/1.1: \{status_line(@utf8.decode_lossy(tls.read_all())).trim_end(chars="\r")}",
    )
    tls.close()
    let client = smock.h2c()
    out.push("a call on h2c: \{client.call(path).outline()}")
    client.close()
    out.push("Journal:")
    out.push(routes_journaled(smock))
    inspect(
      out.join("\n"),
      content=(
        #|offers [h2]: handshake failed: smock sent alert no_application_protocol
        #|offers [h2, http/1.1]: ALPN http/1.1
        #|a call over HTTP/1.1: HTTP/1.1 404 Not Found
        #|a call on h2c: :status: 200, grpc-status: 0, 1 DATA (end)
        #|Journal:
        #|HTTP/1.1 application/grpc: null 404 -
        #|HTTP/2 application/grpc: "hello" 200 "OK"
      ),
    )
  })
}
