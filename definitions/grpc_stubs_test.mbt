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

///|
test "a gRPC Stub's json reply is checked against the method's output type: an unknown field, a value of the wrong type and an int32 out of range are problems at their pointers" {
  inspect(
    check_stubs(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { json: { mesage: Hi } }
        #|  - id: count
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/CountItems }
        #|    responses:
        #|      - { weight: 2, json: { count: 2147483648, exact: "yes", shelf: 1 } }
        #|      - { json: { count: -2147483649 } }
        #|      - { json: { count: 1.5, exact: null } }
        #|      - { json: [] }
        #|      - { json: { count: 2147483647, exact: true, shelf: "" } }
        #|      - { json: { count: -2147483648, exact: false } }
        #|      - { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
      #|a.yaml: /stubs/1/responses/0/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply is an int32
      #|a.yaml: /stubs/1/responses/0/json/exact: must be true or false: the field exact of catalog.CountReply is a bool
      #|a.yaml: /stubs/1/responses/0/json/shelf: must be a string: the field shelf of catalog.CountReply is a string
      #|a.yaml: /stubs/1/responses/1/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply is an int32
      #|a.yaml: /stubs/1/responses/2/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply is an int32
      #|a.yaml: /stubs/1/responses/2/json/exact: must be true or false: the field exact of catalog.CountReply is a bool
      #|a.yaml: /stubs/1/responses/3/json: must be an object: the reply is a catalog.CountReply message
    ),
  )
}

///|
/// The names of the header fields of each response of each Stub that
/// `check_stubs` loads, one Stub per line, or every problem.
fn reply_headers(stubs : String) -> String raise {
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
    Ok(snapshot) =>
      snapshot.mocks[0].stubs
      .iter()
      .map(stub => {
        guard stub.serves is Ordinary(ordinary) else { return stub.id }
        let names = ordinary.responses
          .iter()
          .map(weighted => {
            let names = match weighted.response.headers {
              Written(headers) => headers.iter().map(header => header.0)
              Templated(headers) => headers.iter().map(header => header.0)
            }
            "[\{names.collect().join(", ")}]"
          })
          .collect()
        "\{stub.id}: \{names.join(" ")}"
      })
      .collect()
      .join("\n")
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "a gRPC Stub's json reply gets no Content-Type, and a templated one is not checked when the files load" {
  inspect(
    reply_headers(
      (
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    responses: [{ json: { message: Hello Tom } }, { json: {} }]
        #|  - id: hello-templated
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-name: Tom } }
        #|    response: { template: true, json: { mesage: "${body.name}" } }
        #|  - id: hello-http
        #|    mock: greeter
        #|    request: { path: /hello }
        #|    response: { status: 200, json: { message: Hello Tom } }
      ),
    ),
    content=(
      #|hello: [] []
      #|hello-templated: []
      #|hello-http: [Content-Type]
    ),
  )
}
