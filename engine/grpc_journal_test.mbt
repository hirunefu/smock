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

///|
test "the final-status method sets the gRPC status a call really got, and keeps its HTTP status" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  // No gRPC Stub on the method: smock answers in its own way, so the plan
  // has no gRPC part, and the entry has no gRPC status yet.
  let unmatched = h.call(
    "/helloworld.Greeter/SayHelloStreamReply",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  debug_inspect(unmatched.plan.grpc, content="None")
  json_inspect(answer_members(unmatched), content={
    "stub": null,
    "status": 404,
    "templateError": null,
  })
  guard unmatched.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal)
  json_inspect(answer_members(unmatched), content={
    "stub": null,
    "status": 404,
    "grpcStatus": "INTERNAL",
    "templateError": null,
  })
  // A reply planned as OK may end otherwise, as at a deadline.
  let call = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  guard call.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(DeadlineExceeded)
  json_inspect(answer_members(call), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "DEADLINE_EXCEEDED",
    "templateError": null,
  })
}

///|
test "a template error the final-status method sets counts two bytes for each character of its text toward the entry's bytes, in place of the one the entry had" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let tom = () => {
    h.call("/helloworld.Greeter/SayHello", "{\"name\":\"Tom\"}", octets=10)
  }
  let committed = (outcome : @engine.Outcome) => {
    guard outcome.journal is Some(entry) else { abort("no entry") }
    let before = h.engine.journal_stats().bytes
    h.engine.commit(entry)
    h.engine.journal_stats().bytes - before
  }
  let plain = committed(tom())
  // `/response/json/mesage` has 21 characters and `is not a field of
  // helloworld.HelloReply` 39: 60 in all, two bytes each.
  let failed = tom()
  guard failed.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={
    at: "/response/json/mesage",
    message: "is not a field of helloworld.HelloReply",
  })
  inspect(committed(failed) - plain, content="120")
  json_inspect(answer_members(failed), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "INTERNAL",
    "templateError": {
      "at": "/response/json/mesage",
      "message": "is not a field of helloworld.HelloReply",
    },
  })
  // A second error replaces the first, and only its text counts: `/x`
  // and `y`, 3 characters.
  let twice = tom()
  guard twice.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={
    at: "/response/json/mesage",
    message: "is not a field of helloworld.HelloReply",
  })
  entry.set_grpc_status(Internal, template_error={ at: "/x", message: "y", })
  inspect(committed(twice) - plain, content="6")
  // Without one, the entry keeps its own.
  let kept = tom()
  guard kept.journal is Some(entry) else { fail("no entry") }
  entry.set_grpc_status(Internal, template_error={ at: "/x", message: "y", })
  entry.set_grpc_status(Unavailable)
  inspect(committed(kept) - plain, content="6")
  json_inspect(answer_members(kept), content={
    "stub": "hello",
    "status": 200,
    "grpcStatus": "UNAVAILABLE",
    "templateError": { "at": "/x", "message": "y" },
  })
}
