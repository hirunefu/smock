// Seam 2 tests of gRPC Stubs: a Stub whose exact path names a unary method
// of its Mock's Descriptor set. smock check reads and checks them, and HTTP
// requests never reach them. The set is gRPC's helloworld.proto, as
// scripts/gen-protobuf-fixtures.sh builds it.

///|
/// The Mock `greeter`, the Default Mock, whose set is `files/greeter.binpb`
/// and whose unmatched requests get 501, with the gRPC Stub `hello`, whose
/// reply is `json`, written in YAML, and the HTTP Stub `greet`.
fn greeter_stubs(json : String) -> String {
  (
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|    noMatch: { status: 501 }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello }
    #|    response: { json:
  ) +
  " \{json} }\n" +
  (
    #|  - id: greet
    #|    mock: greeter
    #|    request: { method: GET, path: /hello }
    #|    response: { status: 200, body: Hello }
  )
}

///|
/// Runs `f` with a definitions directory holding `greeter.yaml` and the set
/// of gRPC's helloworld.proto at `files/greeter.binpb`.
async fn with_greeter(
  yaml : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([("greeter.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    f(dir)
  })
}

///|
async test "smock check passes a gRPC Stub without status, and reports an unknown field of its reply at its pointer" {
  let out = []
  for json in ["{ message: Hello Tom }", "{ mesage: Hi }"] {
    with_greeter(greeter_stubs(json), dir => out.push(check([dir])))
  }
  inspect(
    out.join("---\n"),
    content=(
      #|status 0
      #|---
      #|status 1
      #|greeter.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
      #|
    ),
  )
}

///|
async test "an HTTP/1.1 POST to a gRPC Stub's path gets the Mock's noMatch answer, and its Near miss names an HTTP Stub, never the gRPC Stub" {
  with_greeter(greeter_stubs("{ message: Hello Tom }"), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.send(
          "POST",
          "/helloworld.Greeter/SayHello",
          headers=[("Content-Type", "application/grpc")],
          body="\u{0}\u{0}\u{0}\u{0}\u{5}\n\u{3}Tom",
        ),
        content=(
          #|HTTP/1.1 501 Not Implemented
          #|Content-Type: application/json
          #|Smock-Near-Miss: greet; failed=method,path
          #|Smock-Mock: greeter; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}
