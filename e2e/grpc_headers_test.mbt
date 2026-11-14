// Seam 2 tests of gRPC calls answered from their HEADERS, over h2c: a call
// whose Host reaches no Mock, whose Mock has no Descriptor set, or whose
// `:path` names no method of the set or a streaming method, gets
// Trailers-Only UNIMPLEMENTED with a fixed message as soon as its HEADERS
// arrive, without waiting for its message, then RST_STREAM NO_ERROR while
// the client still sends. It is still journaled, as unmatched, with an
// empty body. The set is gRPC's helloworld.proto, and the messages are
// protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, for the Host `greeter.svc`, with the set and one gRPC
/// Stub on SayHello that requires the metadata `x-tenant: acme`; and the
/// Mock `plain`, for the Host `plain.svc`, without a set. There is no
/// Default Mock.
let unserved_example : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: greeter.binpb }
  #|  - name: plain
  #|    hosts: [plain.svc]
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
  #|    response: { json: { message: Hello Tom } }

///|
/// The fields of a gRPC call to `path` at `authority`, as gRPC clients send
/// them, then `more`.
fn call_fields(
  path : String,
  authority : String,
  more~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  let fields = request_fields("POST", path, authority)
  fields.push(("content-type", "application/grpc"))
  fields.push(("te", "trailers"))
  fields.append(more)
  fields
}

///|
/// The Journal's entries, one per line: the Mock, the target, the body's
/// data and size, the HTTP status, the gRPC status and the Stub of the Near
/// miss, each as JSON.
async fn calls_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "mock": mock,
          "request": Object(
            {
              "target": String(target),
              "body": Object({ "data": data, "size": size, .. }),
              ..
            }
          ),
          "status": status,
          "grpcStatus": grpc_status,
          "nearMiss": near_miss,
          ..
        }
      ) else {
      fail("not a gRPC call's entry: \{entry.stringify()}")
    }
    let near = match near_miss {
      Object({ "stub": stub, .. }) => stub.stringify()
      _ => "null"
    }
    out.push(
      "\{mock.stringify()} \{target} \{data.stringify()}/\{size.stringify()} \{status.stringify()} \{grpc_status.stringify()} near miss \{near}",
    )
  }
  out.join("\n")
}

///|
async test "calls that cannot reach a gRPC Stub get Trailers-Only UNIMPLEMENTED as soon as their HEADERS arrive, then RST_STREAM NO_ERROR while the client still sends, or the answer alone when the HEADERS end the request; each is journaled as unmatched with an empty body" {
  with_greeter_set([("greeter.yaml", unserved_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      let tenant = [("x-tenant", "acme")]
      raw.send([
        headers_frame(
          1,
          raw.block(call_fields("/helloworld.Greeter/SayHello", "other.svc")),
          end_stream=false,
        ),
        headers_frame(
          3,
          raw.block(call_fields("/helloworld.Greeter/SayHello", "plain.svc")),
          end_stream=false,
        ),
        headers_frame(
          5,
          raw.block(
            call_fields("/helloworld.Greeter/SayGoodbye", "greeter.svc"),
          ),
          end_stream=false,
        ),
        headers_frame(
          7,
          raw.block(
            call_fields(
              "/helloworld.Greeter/SayHelloStreamReply",
              "greeter.svc",
              more=tenant,
            ),
          ),
          end_stream=false,
        ),
        // A call to the unary method waits for its message.
        headers_frame(
          9,
          raw.block(
            call_fields("/helloworld.Greeter/SayHello", "greeter.svc", more=tenant),
          ),
          end_stream=false,
        ),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "No Mock, no set, an unknown method, a streaming method, and the unary method, none of them ended:",
      )
      out.push(raw.frames_until_ping_ack())
      let hello = framed(@fs.read_file(hello_request_path).binary())
      raw.send([
        // Sent before the client learnt of the answer, as a client does:
        // ignored.
        Data(stream_id=5, data=hello, end_stream=true, padding=0),
        Data(stream_id=9, data=hello, end_stream=true, padding=0),
      ])
      out.push("The message of the unknown method, and of the unary method:")
      out.push(raw.frames_until_stream_ends(9))
      raw.send([
        headers_frame(
          11,
          raw.block(
            call_fields("/helloworld.Greeter/SayGoodbye", "greeter.svc"),
          ),
        ),
      ])
      out.push("An unknown method whose HEADERS end the request:")
      out.push(raw.frames_until_stream_ends(11))
      out.push("Journal:")
      out.push(calls_journaled(smock))
      out.push(smock.metric("smock_requests_total"))
      out.push(smock.metric("smock_unmatched_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|No Mock, no set, an unknown method, a streaming method, and the unary method, none of them ended:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: no Mock for this Host, date: <now>]
          #|RST_STREAM 1 NO_ERROR
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: the Mock has no Descriptor set, date: <now>]
          #|RST_STREAM 3 NO_ERROR
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: unknown method, smock-near-miss: hello; failed=path,header:x-tenant, date: <now>]
          #|RST_STREAM 5 NO_ERROR
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: streaming methods are not served yet, smock-near-miss: hello; failed=path, date: <now>]
          #|RST_STREAM 7 NO_ERROR
          #|The message of the unknown method, and of the unary method:
          #|HEADERS 9 END_HEADERS [:status: 200, content-type: application/grpc, date: <now>]
          #|DATA 9 16 octets
          #|HEADERS 9 END_STREAM END_HEADERS [grpc-status: 0]
          #|An unknown method whose HEADERS end the request:
          #|HEADERS 11 END_STREAM END_HEADERS [:status: 200, content-type: application/grpc, grpc-status: 12, grpc-message: unknown method, smock-near-miss: hello; failed=path,header:x-tenant, date: <now>]
          #|Journal:
          #|null /helloworld.Greeter/SayHello ""/0 200 "UNIMPLEMENTED" near miss null
          #|"plain" /helloworld.Greeter/SayHello ""/0 200 "UNIMPLEMENTED" near miss null
          #|"greeter" /helloworld.Greeter/SayGoodbye ""/0 200 "UNIMPLEMENTED" near miss "hello"
          #|"greeter" /helloworld.Greeter/SayHelloStreamReply ""/0 200 "UNIMPLEMENTED" near miss "hello"
          #|"greeter" /helloworld.Greeter/SayHello "{\"name\":\"Tom\"}"/10 200 "OK" near miss null
          #|"greeter" /helloworld.Greeter/SayGoodbye ""/0 200 "UNIMPLEMENTED" near miss "hello"
          #|smock_requests_total{mock="",stub=""} 1
          #|smock_requests_total{mock="plain",stub=""} 1
          #|smock_requests_total{mock="greeter",stub=""} 3
          #|smock_requests_total{mock="greeter",stub="hello"} 1
          #|smock_unmatched_requests_total{mock=""} 1
          #|smock_unmatched_requests_total{mock="plain"} 1
          #|smock_unmatched_requests_total{mock="greeter"} 3
        ),
      )
    })
  })
}
