// gRPC Stubs at load: a Stub whose exact path names a unary method of its
// Mock's Descriptor set. The sets are those scripts/gen-protobuf-fixtures.sh
// builds with protoc: gRPC's helloworld.proto (greeter_set_test.mbt),
// fixtures/protobuf/catalog/catalog.proto (catalog_set_test.mbt),
// fixtures/protobuf/oneofs/oneofs.proto (oneofs_set_test.mbt) and
// fixtures/protobuf/scalars/scalars.proto (scalars_set_test.mbt).

///|
/// The bytes of a set that the fixture script wrote in hex.
fn set_bytes(hex : String) -> Bytes raise {
  @hex.decode(hex.replace_all(old="\n", new=""))
}

///|
/// Loads `a.yaml`, which declares the Mock `greeter`, whose set is gRPC's
/// helloworld.proto, the Mock `catalog`, whose set is catalog.proto, the
/// Mock `oneofs`, whose set is oneofs.proto, the Mock `scalars`, whose set
/// is scalars.proto, the Mock `plain`, with no set, and then `stubs`, the
/// lines of its `stubs` array. Renders what `smock check` would print:
/// every problem, one per line; or, for a valid set, each Stub with its
/// kind, then each warning.
fn check_stubs(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: greeter, grpc: { descriptorSet: greeter.binpb } }
    #|  - { name: catalog, grpc: { descriptorSet: catalog.binpb } }
    #|  - { name: oneofs, grpc: { descriptorSet: oneofs.binpb } }
    #|  - { name: scalars, grpc: { descriptorSet: scalars.binpb } }
    #|  - { name: plain }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [
        ("greeter.binpb", set_bytes(greeter_set)),
        ("catalog.binpb", set_bytes(catalog_set)),
        ("oneofs.binpb", set_bytes(oneofs_set)),
        ("scalars.binpb", set_bytes(scalars_set)),
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
test "a gRPC Stub's json reply is read as ProtoJSON and checked against the method's output type: its first problem is at its pointer" {
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
        #|      - { json: { count: "-2147483649" } }
        #|      - { json: { count: 1.5, exact: null } }
        #|      - { json: [] }
        #|      - { json: { count: "2147483647", exact: true, shelf: "" } }
        #|      - { json: { count: -2147483648, exact: null } }
        #|      - { json: { shelf: A1, in_stock: true } }
        #|      - { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/json/mesage: is not a field of helloworld.HelloReply
      #|a.yaml: /stubs/1/responses/0/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply has the type int32
      #|a.yaml: /stubs/1/responses/1/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply has the type int32
      #|a.yaml: /stubs/1/responses/2/json/count: must be an integer from -2147483648 to 2147483647: the field count of catalog.CountReply has the type int32
      #|a.yaml: /stubs/1/responses/3/json: must be an object: the message is a catalog.CountReply
      #|a.yaml: /stubs/1/responses/6/json/in_stock: is not a field of catalog.CountReply
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

///|
test "a Stub on a client-, server- or bidi-streaming method is a problem at its path that points to R3" {
  inspect(
    check_stubs(
      (
        #|  - id: stream-reply
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHelloStreamReply }
        #|    response: { json: { mesage: Hi } }
        #|  - id: bidi
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHelloBidiStream }
        #|    response: { json: {} }
        #|  - id: upload
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/UploadItems }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/path: the method helloworld.Greeter/SayHelloStreamReply is server-streaming, and smock serves only unary methods: streaming methods are planned for R3
      #|a.yaml: /stubs/1/request/path: the method helloworld.Greeter/SayHelloBidiStream is bidi-streaming, and smock serves only unary methods: streaming methods are planned for R3
      #|a.yaml: /stubs/2/request/path: the method catalog.Catalog/UploadItems is client-streaming, and smock serves only unary methods: streaming methods are planned for R3
    ),
  )
}

///|
test "a method whose input type has a repeated field, or whose input or output type comes from a file that is not proto3, is not served yet, each side on its own; a nested type is served" {
  inspect(
    check_stubs(
      (
        #|  - id: get-item
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetItem }
        #|    response: { json: { price: 1, tags: [], sku: x } }
        #|  - id: find-items
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/FindItems }
        #|    response: { json: { count: 1 } }
        #|  - id: get-shelf
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetShelf }
        #|    response: { json: {} }
        #|  - id: get-legacy-item
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetLegacyItem }
        #|    response: { json: {} }
        #|  - id: get-edition-item
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetEditionItem }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/response/json/sku: is not a field of catalog.Item
      #|a.yaml: /stubs/3/request/path: the input type legacy.LegacyRequest is not served yet: legacy.proto, which defines it, is a proto2 file, and gRPC Stubs serve only types of proto3 files so far
      #|a.yaml: /stubs/4/request/path: the input type edition.EditionRequest is not served yet: edition.proto, which defines it, is an editions file, and gRPC Stubs serve only types of proto3 files so far
    ),
  )
}

///|
test "a gRPC Stub's fields other than those served so far are not served yet, each at its pointer" {
  inspect(
    check_stubs(
      (
        #|  - id: served
        #|    mock: greeter
        #|    priority: 1
        #|    scenario: { name: greeting, requires: Started, moveTo: Greeted }
        #|    variables: { name: "${body.name}" }
        #|    fault: { seed: 7 }
        #|    request:
        #|      method: POST
        #|      path: /helloworld.Greeter/SayHello
        #|      headers: { x-tenant: acme }
        #|      body: { json: { name: Tom } }
        #|    responses:
        #|      - { weight: 2, template: true, json: { message: "Hello ${body.name}" } }
        #|      - { json: {} }
        #|  - id: not-served
        #|    mock: greeter
        #|    fault: { delay: { fixed: 50 }, connection: { kind: reset, probability: 1 } }
        #|    request:
        #|      path: /helloworld.Greeter/SayHello
        #|      query: { page: "1" }
        #|      cookies: { session: abc }
        #|      body: Tom
        #|    response: { status: 200, headers: { x-served-by: smock }, body: hi }
        #|  - id: body-pattern
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello, body: { pattern: ".*" } }
        #|    responses:
        #|      - { bodyFile: greeter.binpb }
        #|      - { events: [{ data: hi }] }
        #|      - { llm: { api: openai-chat, text: hi } }
        #|  - id: body-form
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello, body: { form: {} } }
        #|    response: {}
        #|  - id: body-xml
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello, body: { xml: {} } }
        #|    response: {}
      ),
    ),
    content=(
      #|a.yaml: /stubs/1/fault/delay: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/fault/connection: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/request/query: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/request/cookies: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/request/body: an exact-text condition is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/response/status: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/response/headers: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/1/response/body: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/2/request/body/pattern: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/2/responses/0/bodyFile: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/2/responses/1/events: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/2/responses/2/llm: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/3/request/body/form: is not served on gRPC Stubs yet
      #|a.yaml: /stubs/4/request/body/xml: is not served on gRPC Stubs yet
    ),
  )
}

///|
test "a gRPC Stub and an HTTP Stub never shadow each other: a catch-all HTTP Stub before a gRPC Stub gets no warning, and a gRPC Stub after an identical one does" {
  inspect(
    check_stubs(
      (
        #|  - id: catch-all
        #|    mock: greeter
        #|    request: {}
        #|    response: { status: 404 }
        #|  - id: any-greeter-path
        #|    mock: greeter
        #|    request: { method: POST, path: { pattern: "/helloworld[.]Greeter/.*" } }
        #|    response: { status: 404 }
        #|  - id: hello
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello }
        #|    response: { json: { message: Hello } }
        #|  - id: hello-again
        #|    mock: greeter
        #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { name: Tom } } }
        #|    response: { json: { message: Hello Tom } }
        #|  - id: after-hello
        #|    mock: greeter
        #|    request: { path: /hello }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|greeter: catch-all: HTTP Stub
      #|greeter: any-greeter-path: HTTP Stub
      #|greeter: hello: gRPC Stub of SayHello
      #|greeter: hello-again: gRPC Stub of SayHello
      #|greeter: after-hello: HTTP Stub
      #|a.yaml: /stubs/1: warning: the Stub "any-greeter-path" can never match: the Stub "catch-all" at a.yaml: /stubs/0 is tried first and matches every request this one would
      #|a.yaml: /stubs/3: warning: the Stub "hello-again" can never match: the Stub "hello" at a.yaml: /stubs/2 is tried first and matches every request this one would
      #|a.yaml: /stubs/4: warning: the Stub "after-hello" can never match: the Stub "catch-all" at a.yaml: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
test "a method whose input and output types have fields in a oneof and proto3 optional fields is served" {
  inspect(
    check_stubs(
      (
        #|  - id: choose
        #|    mock: oneofs
        #|    request: { path: /oneofs.Picker/Choose }
        #|    response: { json: { name: x } }
      ),
    ),
    content=(
      #|oneofs: choose: gRPC Stub of Choose
    ),
  )
}

///|
/// The reply message of each response of each Stub that `check_stubs`
/// loads, as the files' load encoded it, in hex, one Stub per line, or
/// every problem. A response that the load did not encode shows as
/// `none`.
fn reply_messages(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: catalog, grpc: { descriptorSet: catalog.binpb } }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("catalog.binpb", set_bytes(catalog_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for stub in snapshot.mocks[0].stubs {
        guard stub.serves is Ordinary(ordinary) else { continue }
        let messages = []
        for weighted in ordinary.responses {
          messages.push(
            match weighted.response.encoded {
              Some(encoded) => "[\{@hex.encode(encoded.message)}]"
              None => "none"
            },
          )
        }
        lines.push("\{stub.id}: \{messages.join(" ")}")
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "a static reply is encoded when the files load, with every proto3 field type its output type has; a templated one is encoded once rendered, and an HTTP Stub's reply never" {
  // protoc encodes `price: 12 tags: "a" kind: BOOK stock { count: 1 }
  // picture: "\001"` as 080c1201611801220208012a0101.
  inspect(
    reply_messages(
      (
        #|  - id: item
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetItem }
        #|    responses:
        #|      - json: { price: "12", tags: [a], kind: BOOK, stock: { count: 1 }, picture: AQ== }
        #|      - json: { picture: AQ, stock: { count: 1 }, kind: 1, tags: [a], price: 12 }
        #|      - json: {}
        #|      - {}
        #|  - id: item-templated
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/GetItem, headers: { x-id: a } }
        #|    response: { template: true, json: { tags: ["${body.id}"] } }
        #|  - id: item-http
        #|    mock: catalog
        #|    request: { path: /item }
        #|    response: { status: 200, json: { price: 12 } }
      ),
    ),
    content=(
      #|item: [080c1201611801220208012a0101] [080c1201611801220208012a0101] [] []
      #|item-templated: none
      #|item-http: none
    ),
  )
}

///|
test "an input type of fields of every scalar type, enums, nested messages, proto3 optional fields, repeated fields, maps and oneofs is served, a type that nests itself included" {
  inspect(
    check_stubs(
      (
        #|  - id: place
        #|    mock: scalars
        #|    request: { path: /scalars.Orders/Place, body: { json: { price: 9.99, status: ACTIVE } } }
        #|    response: { json: { id: "1" } }
        #|  - id: check
        #|    mock: scalars
        #|    request: { path: /scalars.Orders/Check }
        #|    response: { json: {} }
        #|  - id: walk
        #|    mock: scalars
        #|    request: { path: /scalars.Orders/Walk }
        #|    response: { json: {} }
        #|  - id: send
        #|    mock: scalars
        #|    request: { path: /scalars.Orders/Send }
        #|    response: { json: {} }
        #|  - id: find-items
        #|    mock: catalog
        #|    request: { path: /catalog.Catalog/FindItems }
        #|    response: { json: { count: 1 } }
      ),
    ),
    content=(
      #|catalog: find-items: gRPC Stub of FindItems
      #|scalars: place: gRPC Stub of Place
      #|scalars: check: gRPC Stub of Check
      #|scalars: walk: gRPC Stub of Walk
      #|scalars: send: gRPC Stub of Send
    ),
  )
}

///|
test "an input type that is, or reaches, a type of a file that is not proto3 is not served yet" {
  inspect(
    check_stubs(
      (
        #|  - id: remember
        #|    mock: scalars
        #|    request: { path: /scalars.Orders/Remember }
        #|    response: { json: {} }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/path: the input type scalars.Memo is not served yet: legacy.proto, which defines legacy.Note, a type it reaches, is a proto2 file, and gRPC Stubs serve only types of proto3 files so far
    ),
  )
}
