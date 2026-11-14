// Seam 1 tests of the gRPC part of a plan: the status and the message a
// gRPC Stub's reply ends with, from its `response.grpc`, as written or
// rendered, with weighted `responses` that mix OK and an error, and the
// Journal's `grpcStatus`, which is the plan's status. The set is gRPC's
// helloworld.proto (greeter_set_test.mbt); `Harness::call` and `grpc_part`
// come from grpc_calls_test.mbt.

///|
/// The ticket's example: the Mock `greeter`, the Default Mock, with the
/// set, and a Stub on SayHello that answers OK nine times in ten and
/// UNAVAILABLE once in ten, with a Unicode message.
let flaky_greeter : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: flaky
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    responses:
  #|      - { weight: 9, json: { message: Hello } }
  #|      - { weight: 1, grpc: { status: UNAVAILABLE, message: "try again ☺" } }

///|
test "weighted responses that mix OK and an error plan each call with one of them, the error about one call in ten, with its status and message, which the Journal's grpcStatus records" {
  let h = harness(
    [("greeter.yaml", flaky_greeter)],
    body_files=greeter_body_files(),
  )
  let seen : Map[String, Int32] = Map([])
  let statuses : Map[String, Int32] = Map([])
  for _ in 0..<1000 {
    let outcome = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    let part = grpc_part(outcome)
    seen[part] = seen.get(part).unwrap_or(0) + 1
    guard outcome.journal is Some(entry) && entry.grpc_status is Some(status) else {
      fail("no entry, or no gRPC status")
    }
    let shown = "\{entry.status.unwrap_or(0)} \{status}"
    statuses[shown] = statuses.get(shown).unwrap_or(0) + 1
  }
  let errors = seen.get("UNAVAILABLE\ngrpc-message: try again ☺").unwrap_or(0)
  inspect(
    seen.keys().collect().join("\n---\n"),
    content=(
      #|OK
      #|---
      #|UNAVAILABLE
      #|grpc-message: try again ☺
    ),
  )
  // About one call in ten: within four standard deviations of 100.
  inspect(errors >= 60 && errors <= 140, content="true")
  // The HTTP status of a gRPC reply stays 200.
  inspect(statuses.get("200 UNAVAILABLE") == Some(errors), content="true")
  inspect(statuses.get("200 OK") == Some(1000 - errors), content="true")
}

///|
test "an error's plan carries no reply message, and the OK reply of a Stub without grpc keeps its encoded message" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: missing
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-missing: "yes" } }
    #|    response: { grpc: { status: NOT_FOUND } }
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hi } }
  let h = harness([("greeter.yaml", yaml)], body_files=greeter_body_files())
  let missing = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("content-type", "application/grpc"), ("x-missing", "yes")],
  )
  debug_inspect(
    missing.plan.grpc,
    content=(
      #|Some(
      #|  {
      #|    status: NotFound,
      #|    message: None,
      #|    trailers: <ReadOnlyArray: []>,
      #|    encoded: None,
      #|  },
      #|)
    ),
  )
  inspect(missing.plan.status, content="200")
  let hello = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  inspect(grpc_part(hello), content="OK")
  inspect(hello.plan.grpc.unwrap().encoded is Some(_), content="true")
}

///|
test "with template on, the message renders after the reply message, keeping the control characters it renders; a message that fails to render is a template failure at its pointer" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: broken
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-broken: "yes" } }
    #|    response: { template: true, grpc: { status: INTERNAL, message: "${add(body.name, 1)}" } }
    #|  - id: unknown
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response:
    #|      template: true
    #|      grpc: { status: NOT_FOUND, message: "no user called ${body.name}\t(${method})" }
  let h = harness([("greeter.yaml", yaml)], body_files=greeter_body_files())
  let unknown = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\\r\\nBob\"}",
    octets=10,
  )
  inspect(
    grpc_part(unknown).escape(),
    content=(
      #|"NOT_FOUND\ngrpc-message: no user called Ann\r\nBob\t(POST)"
    ),
  )
  let broken = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Ann\"}",
    octets=10,
    headers=[("content-type", "application/grpc"), ("x-broken", "yes")],
  )
  guard broken.content_error is Some({ failure: Template(error), .. }) else {
    fail("no template failure")
  }
  inspect(
    "\{error.at}: \{error.message}",
    content="/response/grpc/message: add(): argument 1 must be a number, or a string that is one, not \"Ann\"",
  )
}
