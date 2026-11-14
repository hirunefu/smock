// Seam 2 tests of the Descriptor set that serves a gRPC call, over h2c:
// `:authority` chooses the call's Mock, and the call is decoded and
// answered with that Mock's own set, the Default Mock's for a Host that no
// Mock lists. The call's Mock and set are looked up again when its request
// ends, and the decoding, the engine and the encoding then use one version
// of the definition set, so a reload never makes a call decoded with one
// version of a set and answered with another. The sets are versions 1 and
// 2 of gRPC's helloworld.proto, version 2 with a field `version` in each
// message, and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh).

///|
/// HelloRequest `{name: "Tom", version: 2}` of version 2 of
/// helloworld.proto, which version 1 decodes as `{name: "Tom"}`.
let hello_v2_request_path : String = "fixtures/protobuf/helloworld-v2/hello-request.binpb"

///|
/// The framed HelloRequest of version 2.
async fn hello_v2_request() -> Bytes {
  framed(@fs.read_file(hello_v2_request_path).binary())
}

///|
/// The entries of the Journal, one per line: the Mock, the Stub and the
/// body's data and size, each as JSON.
async fn answered_by(smock : Smock) -> String {
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
          "stub": stub,
          "request": Object(
            { "body": Object({ "data": data, "size": size, .. }), .. }
          ),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    out.push(
      "\{mock.stringify()} \{stub.stringify()} \{data.stringify()}/\{size.stringify()}",
    )
  }
  out.join("\n")
}

///|
/// Two Mocks whose sets are versions 1 and 2 of helloworld.proto, each with
/// a Stub on SayHello: `greeter-v1`, the Default Mock, and `greeter-v2`,
/// for the Host `v2.greeter.svc`, whose Stub requires the field `version`
/// that only its set has.
let two_versions : String =
  #|mocks:
  #|  - name: greeter-v1
  #|    default: true
  #|    grpc: { descriptorSet: v1/greeter.binpb }
  #|  - name: greeter-v2
  #|    hosts: [v2.greeter.svc]
  #|    grpc: { descriptorSet: v2/greeter.binpb }
  #|stubs:
  #|  - id: hello-v1
  #|    mock: greeter-v1
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello from v1 } }
  #|  - id: hello-v2
  #|    mock: greeter-v2
  #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { version: 2 } } }
  #|    response: { json: { message: Hello from v2, version: 2 } }

///|
async test "two Mocks whose sets define one package in two versions each decode and answer a call with their own set, chosen by :authority, and the Default Mock answers other Hosts with its own" {
  with_definitions([("greeter.yaml", two_versions)], dir => {
    @fs.mkdir("\{dir}/files")
    @fs.mkdir("\{dir}/files/v1")
    @fs.mkdir("\{dir}/files/v2")
    write_bytes(
      dir,
      "files/v1/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    write_bytes(
      dir,
      "files/v2/greeter.binpb",
      @fs.read_file(greeter_v2_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for authority in ["v2.greeter.svc", "v1.greeter.svc", "other.svc"] {
        out.push("\{authority}:")
        out.push(
          client
          .call(
            "/helloworld.Greeter/SayHello",
            authority~,
            body=hello_v2_request(),
          )
          .render(),
        )
      }
      out.push("Journal:")
      out.push(answered_by(smock))
      inspect(
        out.join("\n"),
        content=(
          #|v2.greeter.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 00000000110a0d48656c6c6f2066726f6d2076321002
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|v1.greeter.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter-v1; via=default
          #|  date: <now>
          #|DATA 000000000f0a0d48656c6c6f2066726f6d207631
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|other.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter-v1; via=default
          #|  date: <now>
          #|DATA 000000000f0a0d48656c6c6f2066726f6d207631
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|Journal:
          #|"greeter-v2" "hello-v2" "{\"name\":\"Tom\",\"version\":2}"/12
          #|"greeter-v1" "hello-v1" "{\"name\":\"Tom\"}"/12
          #|"greeter-v1" "hello-v1" "{\"name\":\"Tom\"}"/12
        ),
      )
    })
  })
}
