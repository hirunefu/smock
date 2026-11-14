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
/// `content-type`, the Stub that matched, the HTTP status and the gRPC
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
      if header is { "name": "content-type", "value": String(value), .. } {
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
