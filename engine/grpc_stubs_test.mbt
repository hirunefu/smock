// Seam 1 tests of gRPC Stubs and HTTP requests: a gRPC Stub, whose exact
// path names a method of its Mock's Descriptor set, is never among an HTTP
// request's candidates, nor its Near miss. The set is gRPC's
// helloworld.proto, as scripts/gen-protobuf-fixtures.sh builds it
// (greeter_set_test.mbt).

///|
/// The Mock `greeter`, the Default Mock, whose set is gRPC's
/// helloworld.proto, with the gRPC Stub `hello` on SayHello, and an HTTP
/// Stub `greet` on `GET /hello`.
let greeter_files : Array[(String, String)] = [
  (
    "greeter.yaml",
    (
      #|mocks:
      #|  - name: greeter
      #|    grpc: { descriptorSet: greeter.binpb }
      #|stubs:
      #|  - id: hello
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello }
      #|    response: { json: { message: Hello Tom } }
      #|  - id: greet
      #|    mock: greeter
      #|    request: { method: GET, path: /hello }
      #|    response: { status: 200, body: Hello }
    ),
  ),
]

///|
/// The engine of `greeter_files`, with or without its match index.
fn greeter(match_index~ : Bool) -> Harness raise {
  harness(
    greeter_files,
    body_files=[
      (
        "greeter.binpb",
        @hex.decode(greeter_set.replace_all(old="\n", new="")),
      ),
    ],
    match_index~,
  )
}

///|
test "an HTTP POST to a gRPC Stub's path matches no Stub, and its Near miss names an HTTP Stub, never the gRPC Stub" {
  for match_index in [true, false] {
    let outcome = greeter(match_index~).send(
      "POST",
      "/helloworld.Greeter/SayHello",
      headers=[("Content-Type", "application/grpc")],
    )
    inspect(
      response(outcome),
      content=(
        #|404
        #|Content-Type: application/json
        #|Smock-Near-Miss: greet; failed=method,path
        #|Smock-Mock: greeter; via=default
        #|{"error":"no Stub matched"}
      ),
    )
    inspect(matched_id(outcome).unwrap_or("none"), content="none")
  }
}

///|
test "an HTTP request still matches the HTTP Stubs of a Mock with gRPC Stubs" {
  for match_index in [true, false] {
    let outcome = greeter(match_index~).send("GET", "/hello")
    inspect(matched_id(outcome).unwrap_or("none"), content="greet")
  }
}
