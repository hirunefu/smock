// gRPC Stubs at load: a Stub whose exact path names a unary method of its
// Mock's Descriptor set. The sets are those scripts/gen-protobuf-fixtures.sh
// builds with protoc: gRPC's helloworld.proto (greeter_set_test.mbt) and
// fixtures/protobuf/catalog/catalog.proto (catalog_set_test.mbt).

///|
/// The bytes of a set that the fixture script wrote in hex.
fn set_bytes(hex : String) -> Bytes raise {
  @hex.decode(hex.replace_all(old="\n", new=""))
}

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, the Mock `catalog`, whose set is catalog.proto, the
/// Mock `plain`, with no set, and then `stubs`, the lines of its `stubs`
/// array. Renders what `smock check` would print: every problem, one per
/// line; or, for a valid set, each Stub with its kind, then each warning.
fn check_stubs(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: greeter.binpb } }
    #|  - { name: catalog, grpc: { descriptorSet: catalog.binpb } }
    #|  - { name: plain }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [
        ("greeter.binpb", set_bytes(greeter_set)),
        ("catalog.binpb", set_bytes(catalog_set)),
      ],
    }) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          let kind = match stub.serves {
            Ordinary({ grpc_method: Some(rpc), .. }) =>
              "gRPC Stub of \{rpc.name}"
            Ordinary(_) | Crud(_) => "HTTP Stub"
          }
          lines.push("\{mock.name}: \{stub.id}: \{kind}")
        }
      }
      for warning in snapshot.warnings() {
        lines.push(warning.to_string())
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "a Stub whose exact path names a unary method of its Mock's set is a gRPC Stub, which needs no status; an HTTP Stub still does" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { json: { message: Hello Tom } }
        #|  - id: hello-http
        #|    mock: plain
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { json: { message: Hello Tom } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/1/response: needs "status"
    ),
  )
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { json: { message: Hello Tom } }
        #|  - id: count
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/CountItems }
        #|    response: { json: { count: 3 } }
        #|  - id: hello-http
        #|    mock: plain
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { status: 200, json: { message: Hello Tom } }
      ),
    ),
    content=(
      #|greeter: hello: gRPC Stub of SayHello
      #|catalog: count: gRPC Stub of CountItems
      #|plain: hello-http: HTTP Stub
    ),
  )
}
