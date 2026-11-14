// Seam 2 tests of request messages over h2c: singular fields of every
// scalar type, enums and nested messages, decoded into smock's decoded
// form, which the Journal records and conditions match. The set is
// fixtures/protobuf/scalars/scalars.proto, and the messages are what
// protoc encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
/// The directory of the scalars fixtures.
let scalars_dir : String = "fixtures/protobuf/scalars"

///|
/// The framed message that protoc encoded from `<name>.txtpb` in the
/// scalars fixtures.
async fn scalars_message(name : String) -> Bytes {
  framed(@fs.read_file("\{scalars_dir}/\{name}.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `orders.yaml`, whose text
/// is `yaml`, and the set of scalars.proto at `files/scalars.binpb`.
async fn with_scalars_set(yaml : String, f : async (String) -> Unit) -> Unit {
  with_definitions([("orders.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/scalars.binpb",
      @fs.read_file("\{scalars_dir}/scalars.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// Each Journal entry, oldest first, one per line: the Stub that answered
/// it, or `null`, then its body as the Stubs saw it.
async fn Smock::bodies(self : Smock) -> String {
  guard self.journal() is (200, Object({ "entries": Array(entries), .. })) else {
    fail("no Journal")
  }
  let lines = []
  for entry in entries {
    guard entry
      is Object(
        {
          "stub": stub,
          "request": Object(
            { "body": Object({ "data": String(data), .. }), .. }
          ),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    lines.push("\{stub.stringify()}: \{data}")
  }
  lines.join("\n")
}

///|
async test "the ticket's example: an Order with the largest int64, a float of 9.99, an enum, an empty string and a nested message is journaled in smock's decoded form, meets a Stub whose condition is written so, never one whose int64 is one less, and is what templates and the Near miss read" {
  let yaml =
    #|mocks:
    #|  - name: orders
    #|    grpc: { descriptorSet: scalars.binpb }
    #|stubs:
    #|  - id: one-less
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place, body: { json: { id: 9223372036854775806 } } }
    #|    response: { json: { id: one-less } }
    #|  - id: pending
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place, body: { json: { status: PENDING } } }
    #|    response: { json: { id: pending } }
    #|  - id: active-at-9.99
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place, body: { json: { price: 9.99, status: ACTIVE } } }
    #|    response: { template: true, json: { id: "order ${body.id}" } }
  with_scalars_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call(
        "/scalars.Orders/Place",
        body=scalars_message("order"),
      )
      // Placed { id: "order 9223372036854775807" }: field 1, 25 octets,
      // framed.
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: orders; via=default
          #|  date: <now>
          #|DATA 000000001b0a196f726465722039323233333732303336383534373735383037
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      inspect(
        smock.last_entry(),
        content=(
          #|{"seq":1,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"localhost","mock":"orders","viaDefault":true,"digest":"<digest>","request":{"method":"POST","target":"/scalars.Orders/Place","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"id\":9223372036854775807,\"price\":9.99,\"status\":\"ACTIVE\",\"note\":\"\",\"address\":{\"city\":\"Kyoto\"}}","size":31,"truncated":false}},"stub":"active-at-9.99","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"grpcStatus":"OK","fault":null,"templateError":null}
        ),
      )
      // An Order with the id 42 and the status of value 0 meets no Stub.
      // Its Near miss is the first Stub that fails one condition.
      let _ = client.call(
        "/scalars.Orders/Place",
        body=scalars_message("order-twice"),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object({ "entries": [_, Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not two entries: \{journal.stringify()}")
      }
      inspect(
        near_miss.stringify(),
        content=(
          #|{"stub":"one-less","stubSource":"file","failed":[{"condition":"body","expected":{"json":{"id":9223372036854775806}},"actual":["{\"id\":42,\"price\":0,\"status\":\"STATUS_UNSPECIFIED\",\"note\":\"\"}"]}]}
        ),
      )
    })
  })
}

///|
async test "every scalar type, 64-bit integers at their limits, floats, NaN and the infinities, defaults, presence, enums by name, through an alias and by number, unknown fields and the last of two values are journaled as smock prints them" {
  let yaml =
    #|mocks:
    #|  - name: orders
    #|    grpc: { descriptorSet: scalars.binpb }
    #|stubs:
    #|  - id: optional-set
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Check, body: { json: { maybeCount: { $exists: true } } } }
    #|    response: { json: {} }
    #|  - id: at-defaults
    #|    mock: orders
    #|    request:
    #|      path: /scalars.Orders/Check
    #|      body: { json: { aDouble: 0, aString: "", aStatus: STATUS_UNSPECIFIED, anAddress: { $exists: false } } }
    #|    response: { json: {} }
    #|  - id: any-every
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Check }
    #|    response: { json: {} }
    #|  - id: unknown-status
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place, body: { json: { status: 7 } } }
    #|    response: { json: {} }
    #|  - id: any-order
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place }
    #|    response: { json: {} }
  with_scalars_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let calls = [
        ("/scalars.Orders/Check", scalars_message("every-max")),
        ("/scalars.Orders/Check", scalars_message("every-min")),
        ("/scalars.Orders/Check", scalars_message("every-floats")),
        ("/scalars.Orders/Check", scalars_message("every-specials")),
        ("/scalars.Orders/Check", scalars_message("every-infinity")),
        ("/scalars.Orders/Check", framed(b"")),
        ("/scalars.Orders/Check", scalars_message("every-presence")),
        ("/scalars.Orders/Place", scalars_message("order-twice")),
        ("/scalars.Orders/Place", scalars_message("order-newer")),
      ]
      for call in calls {
        let reply = client.call(call.0, body=call.1)
        guard reply.trailers is Some([("grpc-status", "0")]) else {
          fail("\{call.0}: \{reply.render()}")
        }
      }
      inspect(
        smock.bodies(),
        content=(
          #|"any-every": {"aDouble":1.7976931348623157e+308,"aFloat":3.4028235e+38,"anInt64":9223372036854775807,"aUint64":18446744073709551615,"anInt32":2147483647,"aFixed64":18446744073709551615,"aFixed32":4294967295,"aBool":true,"aString":"Kyōto \"quoted\"\n","aBytes":"AAH7/w==","aUint32":4294967295,"anSfixed32":2147483647,"anSfixed64":9223372036854775807,"anSint32":2147483647,"anSint64":9223372036854775807,"aStatus":"ACTIVE"}
          #|"any-every": {"aDouble":-1.7976931348623157e+308,"aFloat":-3.4028235e+38,"anInt64":-9223372036854775808,"aUint64":0,"anInt32":-2147483648,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"YQ==","aUint32":0,"anSfixed32":-2147483648,"anSfixed64":-9223372036854775808,"anSint32":-2147483648,"anSint64":-9223372036854775808,"aStatus":"STATUS_UNSPECIFIED"}
          #|"any-every": {"aDouble":0.1,"aFloat":0.1,"anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED"}
          #|"any-every": {"aDouble":"NaN","aFloat":"-Infinity","anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED"}
          #|"any-every": {"aDouble":"Infinity","aFloat":"NaN","anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED"}
          #|"at-defaults": {"aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED"}
          #|"optional-set": {"aDouble":0,"aFloat":0,"anInt64":0,"aUint64":0,"anInt32":0,"aFixed64":0,"aFixed32":0,"aBool":false,"aString":"","aBytes":"","aUint32":0,"anSfixed32":0,"anSfixed64":0,"anSint32":0,"anSint64":0,"aStatus":"STATUS_UNSPECIFIED","anAddress":{"city":""},"maybeCount":0,"maybeName":""}
          #|"any-order": {"id":42,"price":0,"status":"STATUS_UNSPECIFIED","note":""}
          #|"unknown-status": {"id":5,"price":0,"status":7,"note":"","address":{"city":"Kyoto"}}
        ),
      )
    })
  })
}

///|
async test "a request message that does not parse, such as one whose string is not UTF-8, gets Trailers-Only INTERNAL, is not journaled, and counts as rejected traffic" {
  let yaml =
    #|mocks:
    #|  - name: orders
    #|    grpc: { descriptorSet: scalars.binpb }
    #|stubs:
    #|  - id: any-order
    #|    mock: orders
    #|    request: { path: /scalars.Orders/Place }
    #|    response: { json: {} }
  with_scalars_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client
        .call("/scalars.Orders/Place", body=scalars_message("order-not-utf8"))
        .render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: the request message cannot be decoded
          #|  date: <now>
          #|(end)
        ),
      )
      inspect(smock.last_entry(), content="no entry")
      inspect(
        smock.metric("smock_requests_total"),
        content=(
          #|smock_requests_total{mock="",stub=""} 1
        ),
      )
    })
  })
}

///|
async test "smock check refuses a gRPC Stub whose input type has fields of a well-known type, singular, repeated or as a map's values, which are not served yet" {
  let yaml =
    #|mocks:
    #|  - name: clock
    #|    grpc: { descriptorSet: stamped.binpb }
    #|stubs:
    #|  - id: stamp
    #|    mock: clock
    #|    request: { path: /stamped.Clock/Stamp }
    #|    response: { json: { ok: true } }
  with_definitions([("clock.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/stamped.binpb",
      @fs.read_file("fixtures/protobuf/stamped/stamped.binpb").binary(),
    )
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|clock.yaml: /stubs/0/request/path: the input type stamped.Stamped is not served yet: its field at has the well-known type google.protobuf.Timestamp, and gRPC Stubs serve no well-known types so far
        #|clock.yaml: /stubs/0/request/path: the input type stamped.Stamped is not served yet: its field history has the well-known type google.protobuf.Timestamp, and gRPC Stubs serve no well-known types so far
        #|clock.yaml: /stubs/0/request/path: the input type stamped.Stamped is not served yet: its field by_name is a map whose values have the well-known type google.protobuf.Timestamp, and gRPC Stubs serve no well-known types so far
        #|
      ),
    )
  })
}
