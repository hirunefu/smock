// Seam 1 tests of a gRPC call's status in the Journal: the plan of a call
// carries its gRPC part, whose status the entry records as `grpcStatus`,
// and the entry's final-status method sets the status the call really got
// before the entry is committed. An HTTP request's plan and entry have
// none. The set is gRPC's helloworld.proto (greeter_set_test.mbt), and the
// Stubs are those of grpc_calls_test.mbt.

///|
/// The members of the Admin JSON of the Journal entry of `outcome` that
/// tell how its request was answered: `stub`, `status`, `grpcStatus` when
/// it has one, and `templateError`.
fn answer_members(outcome : @engine.Outcome) -> Json {
  guard outcome.journal is Some(entry) && entry.to_json() is Object(members) else {
    abort("no entry")
  }
  let shown = Map([])
  for name in ["stub", "status", "grpcStatus", "templateError"] {
    if members.get(name) is Some(value) {
      shown[name] = value
    }
  }
  Json::object(shown)
}

///|
test "a call answered by a gRPC Stub has a plan with the gRPC status OK, which its entry records as grpcStatus; an HTTP request's has none" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let call = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  debug_inspect(call.plan.grpc, content="Some({ status: Ok })")
  json_inspect(answer_members(call), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "OK",
    "templateError": null,
  })
  let http = h.send(
    "POST",
    "/helloworld.Greeter/SayHello",
    body="{\"name\":\"Tom\"}",
  )
  debug_inspect(http.plan.grpc, content="None")
  json_inspect(answer_members(http), content={
    "stub": "any-post",
    "status": 200,
    "templateError": null,
  })
}
