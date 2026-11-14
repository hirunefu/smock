// Seam 2 tests of gRPC unary calls over h2c: a call reaches the gRPC Stubs
// of its Mock, decoded from protobuf into JSON, and gets its reply encoded
// with the method's output type, framed in one DATA frame, then trailers
// with grpc-status 0. Calls this branch cannot serve yet get Trailers-Only
// INTERNAL. The set is gRPC's helloworld.proto, and the messages are
// protoc-encoded fixtures (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and the gRPC Stub
/// `hello` of #205's example.
let greeter_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello Tom } }

///|
async test "a call over h2c gets HEADERS, one DATA frame with the framed reply protoc encodes, and trailers with grpc-status 0, and is journaled with its decoded body" {
  with_greeter_set([("greeter.yaml", greeter_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello")
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 000000000b0a0948656c6c6f20546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      // One message, the HelloReply protoc encodes, framed.
      inspect(
        reply.data == [framed(@fs.read_file(hello_reply_path).binary())],
        content="true",
      )
      inspect(
        smock.last_entry(),
        content=(
          #|{"seq":1,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"localhost","mock":"greeter","viaDefault":true,"digest":"<digest>","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":"hello","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":"OK","fault":null,"templateError":null}
        ),
      )
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="greeter",stub="hello"} 1
        ),
      )
    })
  })
}

///|
async test "a call meets the json body condition of a gRPC Stub on the decoded message, and passes one it does not meet" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello-ann
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { name: Ann } } }
    #|    response: { json: { message: Hello Ann } }
    #|  - id: hello-tom
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { name: Tom } } }
    #|    response: { json: { message: Hello Tom } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello")
      inspect(
        reply.data == [framed(@fs.read_file(hello_reply_path).binary())],
        content="true",
      )
      debug_inspect(reply.trailers, content="Some([(\"grpc-status\", \"0\")])")
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": [Object({ "stub": stub, .. })], .. }) else {
        fail("not one entry: \{journal.stringify()}")
      }
      inspect(stub.stringify(), content="\"hello-tom\"")
    })
  })
}

///|
async test "an unmatched call gets Trailers-Only INTERNAL, and is journaled as unmatched, with a Near miss that names a gRPC Stub, never an HTTP Stub on its path" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: greeter-paths
    #|    mock: greeter
    #|    request: { method: POST, path: { pattern: "/helloworld\\.Greeter/.*" }, body: { json: { name: Tom } } }
    #|    response: { status: 200, body: http }
    #|  - id: hello-ann
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { name: Ann } } }
    #|    response: { json: { message: Hello Ann } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.call("/helloworld.Greeter/SayHello").render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: no Stub matched
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          {
            "entries": [
              Object(
                { "stub": stub, "nearMiss": near_miss, "status": status, .. }
              ),
            ],
            ..
          }
        ) else {
        fail("not one entry: \{journal.stringify()}")
      }
      inspect(
        "stub \{stub.stringify()}, status \{status.stringify()}\nnear miss \{near_miss.stringify()}",
        content=(
          #|stub null, status 404
          #|near miss {"stub":"hello-ann","stubSource":"file","failed":[{"condition":"body","expected":{"json":{"name":"Ann"}},"actual":["{\"name\":\"Tom\"}"]}]}
        ),
      )
      inspect(
        smock.metric("smock_unmatched_requests_total"),
        content=(
          #|smock_unmatched_requests_total{mock="greeter"} 1
        ),
      )
    })
  })
}

///|
async test "calls this branch cannot serve yet get Trailers-Only INTERNAL with a fixed message, are not journaled, and count as rejected traffic" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    hosts: [greeter.svc]
    #|    grpc: { descriptorSet: greeter.binpb }
    #|  - name: plain
    #|    hosts: [plain.svc]
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello Tom } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let hello = framed(@fs.read_file(hello_request_path).binary())
      let calls : Array[(String, String, String, Bytes)] = [
        (
          "a Host no Mock lists", "other.svc", "/helloworld.Greeter/SayHello", hello,
        ),
        (
          "a Mock without a set", "plain.svc", "/helloworld.Greeter/SayHello", hello,
        ),
        (
          "an unknown method", "greeter.svc", "/helloworld.Greeter/SayGoodbye", hello,
        ),
        (
          "a streaming method", "greeter.svc", "/helloworld.Greeter/SayHelloStreamReply",
          hello,
        ),
        (
          "a message that does not parse", "greeter.svc", "/helloworld.Greeter/SayHello",
          b"\x00\x00\x00\x00\x03\x0a\x05T",
        ),
        (
          "a body that ends inside a message", "greeter.svc", "/helloworld.Greeter/SayHello",
          b"\x00\x00\x00\x00\x05\x0a\x03T",
        ),
        (
          "two messages",
          "greeter.svc",
          "/helloworld.Greeter/SayHello",
          hello + hello,
        ),
        ("no message", "greeter.svc", "/helloworld.Greeter/SayHello", b""),
      ]
      let out = []
      for call in calls {
        let (what, authority, path, body) = call
        let reply = client.call(path, authority~, body~)
        guard reply.trailers is None && reply.data is [] else {
          fail("\{what}: not Trailers-Only: \{reply.render()}")
        }
        let fields = reply.head
          .filter(field => {
            field.0 is (":status" | "grpc-status" | "grpc-message")
          })
          .map(field => "\{field.0}: \{field.1}")
        out.push("\{what}: \{fields.join(", ")} (\{reply.ended})")
      }
      out.push("journal: \{smock.last_entry()}")
      out.push(smock.metric("smock_requests_total"))
      inspect(
        out.join("\n"),
        content=(
          #|a Host no Mock lists: :status: 200, grpc-status: 13, grpc-message: no Mock for this Host (end)
          #|a Mock without a set: :status: 200, grpc-status: 13, grpc-message: the Mock has no Descriptor set (end)
          #|an unknown method: :status: 200, grpc-status: 13, grpc-message: unknown method (end)
          #|a streaming method: :status: 200, grpc-status: 13, grpc-message: streaming methods are not served yet (end)
          #|a message that does not parse: :status: 200, grpc-status: 13, grpc-message: the request message cannot be decoded (end)
          #|a body that ends inside a message: :status: 200, grpc-status: 13, grpc-message: the request is not one uncompressed message (end)
          #|two messages: :status: 200, grpc-status: 13, grpc-message: the request is not one uncompressed message (end)
          #|no message: :status: 200, grpc-status: 13, grpc-message: the request is not one uncompressed message (end)
          #|journal: no entry
          #|smock_requests_total{mock="",stub=""} 8
        ),
      )
    })
  })
}

///|
async test "a gRPC Stub whose template fails gets Trailers-Only INTERNAL, and is journaled with smock's own answer as planned" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { template: true, json: { message: "${body.missing.name}" } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.call("/helloworld.Greeter/SayHello").render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          {
            "entries": [
              Object(
                { "stub": stub, "status": status, "templateError": error, .. }
              ),
            ],
            ..
          }
        ) else {
        fail("not one entry: \{journal.stringify()}")
      }
      inspect(
        "\{stub.stringify()} \{status.stringify()} \{error.stringify()}",
        content=(
          #|"hello" 500 {"at":"/response/json/message","message":"body.missing.name is missing"}
        ),
      )
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="greeter",stub="hello"} 1
        ),
      )
    })
  })
}

///|
async test "HTTP requests to the port that serves gRPC are unchanged: over HTTP/1.1, and over h2c without a gRPC content type" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hello Tom } }
    #|  - id: greet
    #|    mock: greeter
    #|    request: { method: GET, path: /hello }
    #|    response: { status: 200, body: Hello }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.send("GET", "/hello"),
        content=(
          #|HTTP/1.1 200 OK
          #|Smock-Mock: greeter; via=default
          #|Date: <now>
          #|Content-Length: 5
          #|
          #|Hello
        ),
      )
      let client = smock.h2c()
      defer client.close()
      inspect(
        client
        .request(
          "POST",
          "/helloworld.Greeter/SayHello",
          authority="localhost",
          headers=[("content-type", "application/grpc-web")],
        )
        .render(),
        content=(
          #|404
          #|content-type: application/json
          #|smock-near-miss: greet; failed=method,path
          #|smock-mock: greeter; via=default
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      // The gRPC call on the same connection is still served.
      debug_inspect(
        client.call("/helloworld.Greeter/SayHello").trailers,
        content="Some([(\"grpc-status\", \"0\")])",
      )
    })
  })
}

///|
async test "a reply larger than the windows is sent as the client widens them, then the trailers end the stream" {
  let long = "a".repeat(100_000)
  let yaml = (
      #|mocks:
      #|  - name: greeter
      #|    grpc: { descriptorSet: greeter.binpb }
      #|stubs:
      #|  - id: hello
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello }
    ) +
    "\n    response: { json: { message: \{long} } }\n"
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/helloworld.Greeter/SayHello")
      let data = @buffer.Buffer()
      for octets in reply.data {
        data.write_bytes(octets)
      }
      let data = data.to_bytes()
      // The prefix announces 100,004 octets: the tag of field 1, the
      // varint 100,000, then the string.
      inspect(
        "\{reply.data.length() > 1} \{data.length()} \{hex(data[0:9].to_owned())} \{reply.ended}",
        content="true 100009 00000186a40aa08d06 end",
      )
      debug_inspect(reply.trailers, content="Some([(\"grpc-status\", \"0\")])")
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="greeter",stub="hello"} 1
        ),
      )
    })
  })
}
