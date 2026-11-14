// Seam 1 tests of a gRPC Stub's reply in the plan: a static reply comes
// with its message encoded when the files were loaded, so that the server
// sends it as it is; a templated one comes as its rendered JSON alone,
// which the server encodes. The set is gRPC's helloworld.proto
// (greeter_set_test.mbt).

///|
test "a static reply's plan carries the message encoded when the files were loaded; a templated reply's carries none, and its body is the rendered JSON" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: templated
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-templated: "yes" } }
    #|    response: { template: true, json: { message: "Hello ${body.name}" } }
    #|  - id: static
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json: { message: Hi } }
  let h = harness([("greeter.yaml", yaml)], body_files=greeter_body_files())
  let static = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  // HelloReply { message: "Hi" }: field 1, length-delimited, 2 octets.
  debug_inspect(
    static.plan.grpc,
    content=(
      #|Some(
      #|  {
      #|    status: Ok,
      #|    encoded: Some(
      #|      EncodedMessage(
      #|        output="helloworld.HelloReply",
      #|        message=<Bytes: [0x0a, 0x02, 0x48, 0x69]>,
      #|      ),
      #|    ),
      #|  },
      #|)
    ),
  )
  let templated = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
    headers=[("content-type", "application/grpc"), ("x-templated", "yes")],
  )
  debug_inspect(
    templated.plan.grpc,
    content=(
      #|Some({ status: Ok, encoded: None })
    ),
  )
  guard templated.plan.body is Bytes(body) else { fail("events") }
  inspect(
    @utf8.decode(body),
    content=(
      #|{"message":"Hello Tom"}
    ),
  )
}
