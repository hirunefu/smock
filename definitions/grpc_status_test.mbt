// A gRPC Stub's `response.grpc` at load: the status its reply ends with, by
// name, `OK` when left out, and a status message, as written or a text
// template. The set is gRPC's helloworld.proto (greeter_set_test.mbt), and
// `check_stubs` (grpc_stubs_test.mbt) renders the problems.

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, then `stubs`, the lines of its `stubs` array. Shows
/// the `grpc` of each response of each Stub, one Stub per line: its status
/// and its message, as written or as a template's source; `-` for a
/// response without `grpc`. Or every problem, one per line.
fn grpc_replies(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: greeter.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("greeter.binpb", set_bytes(greeter_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for stub in snapshot.mocks[0].stubs {
        guard stub.serves is Ordinary(ordinary) else { continue }
        let replies = []
        for weighted in ordinary.responses {
          replies.push(
            match weighted.response.grpc {
              None => "-"
              Some({ status, message: None, }) => "\{status}"
              Some({ status, message: Some(Written(text)), }) =>
                "\{status} \{text.escape()}"
              Some({ status, message: Some(Templated(text)), }) =>
                "\{status} template \{text.source.escape()}"
            },
          )
        }
        lines.push("\{stub.id}: \{replies.join(" | ")}")
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "a gRPC Stub's reply gives its status by name and a Unicode message, OK without either, and each of its responses its own" {
  inspect(
    grpc_replies(
      (
        #|  - id: flaky
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - { weight: 9, json: { message: Hello } }
        #|      - { weight: 1, grpc: { status: UNAVAILABLE, message: "try again ☺" } }
        #|      - { grpc: { status: NOT_FOUND } }
        #|      - { grpc: { message: "fine, thanks" } }
        #|  - id: templated
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response:
        #|      template: true
        #|      grpc: { status: NOT_FOUND, message: "no user called ${body.name}" }
      ),
    ),
    content=(
      #|flaky: - | UNAVAILABLE "try again ☺" | NOT_FOUND | OK "fine, thanks"
      #|templated: NOT_FOUND template "no user called ${body.name}"
    ),
  )
}

///|
test "a status that is not one of gRPC's seventeen names, a message that is not a string and an unknown member of grpc are load errors" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - grpc: { status: NOT_A_STATUS }
        #|      - grpc: { status: not_found }
        #|      - grpc: { status: 5 }
        #|      - grpc: { message: 5 }
        #|      - grpc: { code: 5 }
        #|      - grpc: NOT_FOUND
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/grpc/status: must be a gRPC status name: OK, CANCELLED, UNKNOWN, INVALID_ARGUMENT, DEADLINE_EXCEEDED, NOT_FOUND, ALREADY_EXISTS, PERMISSION_DENIED, RESOURCE_EXHAUSTED, FAILED_PRECONDITION, ABORTED, OUT_OF_RANGE, UNIMPLEMENTED, INTERNAL, UNAVAILABLE, DATA_LOSS or UNAUTHENTICATED
      #|a.yaml: /stubs/0/responses/1/grpc/status: must be a gRPC status name: OK, CANCELLED, UNKNOWN, INVALID_ARGUMENT, DEADLINE_EXCEEDED, NOT_FOUND, ALREADY_EXISTS, PERMISSION_DENIED, RESOURCE_EXHAUSTED, FAILED_PRECONDITION, ABORTED, OUT_OF_RANGE, UNIMPLEMENTED, INTERNAL, UNAVAILABLE, DATA_LOSS or UNAUTHENTICATED
      #|a.yaml: /stubs/0/responses/2/grpc/status: must be a gRPC status name: OK, CANCELLED, UNKNOWN, INVALID_ARGUMENT, DEADLINE_EXCEEDED, NOT_FOUND, ALREADY_EXISTS, PERMISSION_DENIED, RESOURCE_EXHAUSTED, FAILED_PRECONDITION, ABORTED, OUT_OF_RANGE, UNIMPLEMENTED, INTERNAL, UNAVAILABLE, DATA_LOSS or UNAUTHENTICATED
      #|a.yaml: /stubs/0/responses/3/grpc/message: must be a string
      #|a.yaml: /stubs/0/responses/4/grpc/code: is not a known field
      #|a.yaml: /stubs/0/responses/5/grpc: must be an object
    ),
  )
}

///|
test "an error reply that also gives json is a load error, at its json, and its json is not checked further; OK with json is not" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses:
        #|      - { grpc: { status: NOT_FOUND }, json: { mesage: Hello } }
        #|      - { grpc: { status: OK }, json: { message: Hello } }
        #|      - { template: true, grpc: { status: INTERNAL }, json: { message: "${body.name}" } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/responses/0/json: is not allowed with the gRPC status NOT_FOUND: a gRPC call gets a reply message or an error, never both
      #|a.yaml: /stubs/0/responses/2/json: is not allowed with the gRPC status INTERNAL: a gRPC call gets a reply message or an error, never both
    ),
  )
}

///|
test "grpc on an HTTP Stub is a load error" {
  inspect(
    check_stubs(
      (
        #|  - id: hello-http
        #|    mock: plain
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { status: 503, grpc: { status: UNAVAILABLE } }
        #|  - id: typo
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHelo }
        #|    response: { status: 200, grpc: { status: OK } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/grpc: is only for gRPC Stubs, and this is an HTTP Stub: its exact path names no method of its Mock's Descriptor set
      #|a.yaml: /stubs/1/response/grpc: is only for gRPC Stubs, and this is an HTTP Stub: its exact path names no method of its Mock's Descriptor set
    ),
  )
}

///|
test "a templated message is parsed as a text template when the files load, and its problems are reported at its pointer" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { template: true, grpc: { status: NOT_FOUND, message: "no ${body.name" } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/grpc/message: template: column 4: the ${ is not closed
    ),
  )
}
