// Seam 1 tests of unmatched gRPC calls: a call that no gRPC Stub matches
// gets a plan of its own, the gRPC status UNIMPLEMENTED with the fixed
// message `no Stub matched` and the HTTP status 200, with its Near miss as
// the `smock-near-miss` trailer, in the form of the HTTP `Smock-Near-Miss`
// header. The Mock's `noMatch` never reaches it. Its entry records the full
// Near miss and the gRPC status UNIMPLEMENTED, and the unmatched list
// includes it. The set is gRPC's helloworld.proto (greeter_set_test.mbt).

///|
/// The Mock `greeter`, the Default Mock, with the set and a `noMatch` of its
/// own, and one gRPC Stub on SayHello that requires the metadata
/// `x-tenant: acme`.
let tenant_stub : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|    noMatch: { status: 501, headers: { X-Missing: "yes" } }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
  #|    response: { json: { message: Hello } }

///|
test "an unmatched call is planned UNIMPLEMENTED with the message no Stub matched and HTTP status 200, its Near miss in the smock-near-miss trailer, and none of the Mock's noMatch" {
  for match_index in [true, false] {
    let h = harness(
      [("greeter.yaml", tenant_stub)],
      body_files=greeter_body_files(),
      match_index~,
    )
    let outcome = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    inspect(matched_id(outcome).unwrap_or("none"), content="none")
    inspect(
      grpc_part(outcome),
      content=(
        #|UNIMPLEMENTED
        #|grpc-message: no Stub matched
        #|smock-near-miss: hello; failed=header:x-tenant
      ),
    )
    // No body, and only smock's own field of the Default Mock: neither the
    // status nor the headers of `noMatch`.
    inspect(
      response(outcome),
      content=(
        #|200
        #|Smock-Mock: greeter; via=default
        #|
      ),
    )
  }
}

///|
test "an unmatched call's entry records its full Near miss, the HTTP status 200 and the gRPC status UNIMPLEMENTED, and the unmatched list includes it" {
  let h = harness(
    [("greeter.yaml", tenant_stub)],
    body_files=greeter_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("content-type", "application/grpc"), ("x-tenant", "other")],
  )
  guard outcome.journal is Some(entry) else { fail("no entry") }
  h.engine.commit(entry)
  json_inspect(h.unmatched(None), content={
    "entries": [
      {
        "request": "POST /helloworld.Greeter/SayHello",
        "host": null,
        "mock": "greeter",
        "stub": null,
        "nearMiss": {
          "stub": "hello",
          "stubSource": "file",
          "failed": [
            {
              "condition": "header:x-tenant",
              "expected": "acme",
              "actual": ["other"],
            },
          ],
        },
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

///|
test "the smock-near-miss trailer is ASCII, with names percent-encoded, and carries no expected or actual value" {
  let h = harness(
    [
      (
        "greeter.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    grpc: { descriptorSet: greeter.binpb }
          #|stubs:
          #|  - id: "hello ☺; failed=x"
          #|    mock: greeter
          #|    request:
          #|      path: /helloworld.Greeter/SayHello
          #|      headers: { "x-%": secret, x-tenant: acme }
          #|      body: { json: { name: Ann } }
          #|    response: { json: { message: Hello } }
        ),
      ),
    ],
    body_files=greeter_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("x-%", "sent")],
  )
  inspect(
    grpc_part(outcome),
    content=(
      #|UNIMPLEMENTED
      #|grpc-message: no Stub matched
      #|smock-near-miss: hello%20%E2%98%BA%3B%20failed%3Dx; failed=header:x-%25,header:x-tenant,body
    ),
  )
}
