// Seam 1 tests of gRPC calls that cannot reach a gRPC Stub: a call whose
// Host reaches no Mock, a call to a Mock without a Descriptor set, and a
// call to a method the set lacks or to a streaming method. The server
// answers them as soon as their HEADERS arrive, and still hands each to the
// engine, with an empty body. The engine plans each Trailers-Only
// UNIMPLEMENTED with its own fixed message and the HTTP status 200, never
// the 404 of an HTTP request that reaches no Mock, and journals it as
// unmatched, with its Near miss when it has one. The set is gRPC's
// helloworld.proto (greeter_set_test.mbt).

///|
/// The Mock `greeter`, for the Host `greeter.svc`, with the set and two
/// gRPC Stubs on SayHello, the first for Ann; and the Mock `plain`, for the
/// Host `plain.svc`, without a set. There is no Default Mock.
let unserved_mocks : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: greeter.binpb }
  #|  - name: plain
  #|    hosts: [plain.svc]
  #|stubs:
  #|  - id: hello-ann
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      body: { json: { name: Ann } }
  #|    response: { json: { message: Hello Ann } }
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
  #|    response: { json: { message: Hello } }

///|
test "a call whose Host reaches no Mock, with no Default Mock, is planned UNIMPLEMENTED no Mock for this Host with the HTTP status 200, has no Near miss, and is journaled as unmatched" {
  let h = harness(
    [("mocks.yaml", unserved_mocks)],
    body_files=greeter_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "",
    octets=0,
    authority="other.svc",
  )
  inspect(
    grpc_part(outcome),
    content=(
      #|UNIMPLEMENTED
      #|grpc-message: no Mock for this Host
    ),
  )
  // No body, and none of the fields of an HTTP request's 404.
  inspect(
    response(outcome),
    content=(
      #|200
      #|
    ),
  )
  inspect(outcome.near_miss is None, content="true")
  guard outcome.journal is Some(entry) else { fail("no entry") }
  h.engine.commit(entry)
  json_inspect(h.unmatched(None), content={
    "entries": [
      {
        "request": "POST /helloworld.Greeter/SayHello",
        "host": "other.svc",
        "mock": null,
        "stub": null,
        "nearMiss": null,
        "status": 200,
      },
    ],
    "more": false,
    "evicted": 0,
  })
  json_inspect(answer_members(outcome), content={
    "stub": null,
    "status": 200,
    "grpcStatus": "UNIMPLEMENTED",
    "templateError": null,
  })
}
