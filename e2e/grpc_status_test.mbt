// Seam 2 tests of a gRPC Stub's status and message over h2c: a reply ends
// with the status its `response.grpc` names, OK by default, and an error
// goes out as Trailers-Only, one HEADERS block that ends the stream, with
// `:status` 200, `content-type`, `grpc-status`, `grpc-message` when given,
// and smock's own fields, never `content-length` or `grpc-encoding`. The
// message is percent-encoded, and the client decodes it back. The set is
// gRPC's helloworld.proto, and the request is its protoc-encoded
// HelloRequest `{name: "Tom"}` (scripts/gen-protobuf-fixtures.sh).

///|
/// gRPC's seventeen status names, in the order of their codes, as gRPC's
/// status code list gives them
/// (https://grpc.github.io/grpc/core/md_doc_statuscodes.html).
let grpc_status_names : Array[String] = [
  "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND",
  "ALREADY_EXISTS", "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION",
  "ABORTED", "OUT_OF_RANGE", "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
  "UNAUTHENTICATED",
]

///|
/// The value of the field `name` of the reply, as a client reads its
/// status: from its trailers, or from its one HEADERS block when the reply
/// is Trailers-Only.
fn GrpcReply::status_field(self : GrpcReply, name : String) -> String? {
  let fields = match self.trailers {
    Some(trailers) => trailers
    None => self.head
  }
  for field in fields {
    if field.0 == name {
      return Some(field.1)
    }
  }
  None
}

///|
/// How the client reads the reply's end: its `grpc-status`, whether it came
/// as Trailers-Only or after a reply message, and its `grpc-message`, as
/// sent and as the client percent-decodes it, when it has one.
fn GrpcReply::status_line(self : GrpcReply) -> String raise {
  let form = if self.trailers is None && self.data.is_empty() {
    "trailers-only"
  } else {
    "message, then trailers"
  }
  let status = self.status_field("grpc-status").unwrap_or("none")
  let line = "grpc-status \{status}, \{form}"
  match self.status_field("grpc-message") {
    Some(sent) =>
      "\{line}\n  sent: \{sent}\n  decoded: \{@percent.decode(sent).escape()}"
    None => line
  }
}

///|
/// The gRPC status of each entry of `page`, a Journal page, with its HTTP
/// status, one entry per line.
fn grpc_statuses(page : Json) -> Array[String] raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  entries.map(entry => {
    guard entry is Object(members) else { return "not an entry" }
    let shown = (name : String) => {
      members.get(name).map_or("-", value => value.stringify())
    }
    "\{shown("status")} \{shown("grpcStatus")}"
  })
}

///|
async test "a Stub answers with each of gRPC's seventeen statuses by name, OK with its message and every error as Trailers-Only, and the Journal records each" {
  let stubs = StringBuilder()
  for name in grpc_status_names {
    stubs.write_string(
      (
        $|  - id: status-\{name.to_lower()}
        $|    mock: greeter
        $|    request: { path: /helloworld.Greeter/SayHello, headers: { x-status: \{name} } }
        $|    response: { grpc: { status: \{name} } }
        $|
      ),
    )
  }
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    hosts: [localhost]
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|
  with_greeter_set([("greeter.yaml", yaml + stubs.to_string())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let lines = []
      for name in grpc_status_names {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-status", name),
        ])
        lines.push("\{name}: \{reply.status_line()}")
        if name == "NOT_FOUND" || name == "OK" {
          lines.push(reply.render())
        }
      }
      inspect(
        lines.join("\n"),
        content=(
          #|OK: grpc-status 0, message, then trailers
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 0000000000
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|CANCELLED: grpc-status 1, trailers-only
          #|UNKNOWN: grpc-status 2, trailers-only
          #|INVALID_ARGUMENT: grpc-status 3, trailers-only
          #|DEADLINE_EXCEEDED: grpc-status 4, trailers-only
          #|NOT_FOUND: grpc-status 5, trailers-only
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 5
          #|  date: <now>
          #|(end)
          #|ALREADY_EXISTS: grpc-status 6, trailers-only
          #|PERMISSION_DENIED: grpc-status 7, trailers-only
          #|RESOURCE_EXHAUSTED: grpc-status 8, trailers-only
          #|FAILED_PRECONDITION: grpc-status 9, trailers-only
          #|ABORTED: grpc-status 10, trailers-only
          #|OUT_OF_RANGE: grpc-status 11, trailers-only
          #|UNIMPLEMENTED: grpc-status 12, trailers-only
          #|INTERNAL: grpc-status 13, trailers-only
          #|UNAVAILABLE: grpc-status 14, trailers-only
          #|DATA_LOSS: grpc-status 15, trailers-only
          #|UNAUTHENTICATED: grpc-status 16, trailers-only
        ),
      )
      // Each call is journaled with its gRPC status by name, and the HTTP
      // status 200.
      let (_, page) = smock.journal()
      inspect(
        grpc_statuses(page) == grpc_status_names.map(name => "200 \"\{name}\""),
        content="true",
      )
    })
  })
}

///|
async test "a message is percent-encoded and decoded back by the client: gRPC's interop message, spaces at both ends, a templated message, and a message on OK, in its trailers" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: interop
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: interop } }
    #|    response:
    #|      grpc:
    #|        status: UNKNOWN
    #|        message: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    #|  - id: spaces
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: spaces } }
    #|    response: { grpc: { status: UNAVAILABLE, message: "  try again, 100% sure  " } }
    #|  - id: templated
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: templated } }
    #|    response:
    #|      template: true
    #|      grpc: { status: NOT_FOUND, message: "no user called ${body.name}\t☺" }
    #|  - id: fine
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-case: fine } }
    #|    response: { json: { message: Hello Tom }, grpc: { message: "fine ☺" } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let lines = []
      for case in ["interop", "spaces", "templated", "fine"] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-case", case),
        ])
        lines.push("\{case}: \{reply.status_line()}")
      }
      inspect(
        lines.join("\n"),
        content=(
          #|interop: grpc-status 2, trailers-only
          #|  sent: %09%0Atest with whitespace%0D%0Aand Unicode BMP %E2%98%BA and non-BMP %F0%9F%98%88%09%0A
          #|  decoded: "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
          #|spaces: grpc-status 14, trailers-only
          #|  sent: %20 try again, 100%25 sure %20
          #|  decoded: "  try again, 100% sure  "
          #|templated: grpc-status 5, trailers-only
          #|  sent: no user called Tom%09%E2%98%BA
          #|  decoded: "no user called Tom\t☺"
          #|fine: grpc-status 0, message, then trailers
          #|  sent: fine %E2%98%BA
          #|  decoded: "fine ☺"
        ),
      )
    })
  })
}

///|
async test "weighted responses that mix OK and an error fail about one call in ten with Trailers-Only UNAVAILABLE, whose message the client decodes, and the Journal records each call's status" {
  let yaml =
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
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let seen : Map[String, Int32] = Map([])
      let sent = []
      for _ in 0..<100 {
        let reply = client.call("/helloworld.Greeter/SayHello")
        let line = reply.status_line()
        seen[line] = seen.get(line).unwrap_or(0) + 1
        sent.push(
          if reply.status_field("grpc-status") == Some("0") {
            "200 \"OK\""
          } else {
            "200 \"UNAVAILABLE\""
          },
        )
      }
      let kinds = seen.keys().collect()
      kinds.sort()
      inspect(
        kinds.join("\n"),
        content=(
          #|grpc-status 0, message, then trailers
          #|grpc-status 14, trailers-only
          #|  sent: try again %E2%98%BA
          #|  decoded: "try again ☺"
        ),
      )
      // About one call in ten: within four standard deviations of 10.
      let errors = seen
        .get(
          "grpc-status 14, trailers-only\n  sent: try again %E2%98%BA\n  decoded: \"try again ☺\"",
        )
        .unwrap_or(0)
      inspect(errors >= 1 && errors <= 22, content="true")
      // The Journal records the status each call got.
      let (_, page) = smock.journal()
      inspect(grpc_statuses(page) == sent, content="true")
    })
  })
}

///|
async test "smock check reports an error reply that also gives json, grpc on an HTTP Stub and an unknown status name, each at its pointer" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: not-found
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { grpc: { status: NOT_FOUND, message: no such user }, json: { message: Hello } }
    #|  - id: greet
    #|    mock: greeter
    #|    request: { method: GET, path: /hello }
    #|    response: { status: 503, grpc: { status: UNAVAILABLE } }
    #|  - id: missing
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { grpc: { status: NOTFOUND } }
  with_greeter(yaml, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|greeter.yaml: /stubs/0/response/json: is not allowed with the gRPC status NOT_FOUND: a gRPC call gets a reply message or an error, never both
        #|greeter.yaml: /stubs/1/response/grpc: is only for gRPC Stubs, and this is an HTTP Stub: its exact path names no method of its Mock's Descriptor set
        #|greeter.yaml: /stubs/2/response/grpc/status: must be a gRPC status name: OK, CANCELLED, UNKNOWN, INVALID_ARGUMENT, DEADLINE_EXCEEDED, NOT_FOUND, ALREADY_EXISTS, PERMISSION_DENIED, RESOURCE_EXHAUSTED, FAILED_PRECONDITION, ABORTED, OUT_OF_RANGE, UNIMPLEMENTED, INTERNAL, UNAVAILABLE, DATA_LOSS or UNAUTHENTICATED
        #|
      ),
    )
  })
}
