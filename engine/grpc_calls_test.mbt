// Seam 1 tests of gRPC calls: the call that finds a call's Mock and its
// Descriptor set, and `handle` with the gRPC call marker. A gRPC call is
// matched only against its Mock's gRPC Stubs on its method, in matching
// order, its Near miss is chosen among them, and its Journal entry records
// the decoded JSON body with the octets its DATA frames brought as its
// size. The set is gRPC's helloworld.proto (greeter_set_test.mbt).

///|
/// The body files of these tests: the set of helloworld.proto.
fn greeter_body_files() -> Array[(String, Bytes)] raise {
  [("greeter.binpb", @hex.decode(greeter_set.replace_all(old="\n", new="")))]
}

///|
/// Sends a gRPC call to the method `path` names, such as
/// `/helloworld.Greeter/SayHello`, whose message was decoded as `json` from
/// `octets` octets of DATA, by default without a Session, and returns the
/// engine's outcome.
fn Harness::call(
  self : Harness,
  path : String,
  json : String,
  octets~ : Int32,
  authority? : String,
  headers~ : Array[(String, String)] = [("content-type", "application/grpc")],
) -> @engine.Outcome {
  self.engine.handle(
    {
      meth: "POST",
      target: path,
      version: "HTTP/2",
      headers,
      body: @utf8.encode(json),
    },
    authority?,
    grpc={ path, octets, },
    session=None,
    now=self.now,
    rand=self.rand,
  )
}

///|
/// Two Mocks: `greeter`, for the Host `greeter.svc`, with the set, and
/// `plain`, the Default Mock, without one.
let two_mocks : String =
  #|mocks:
  #|  - name: greeter
  #|    hosts: [greeter.svc]
  #|    grpc: { descriptorSet: greeter.binpb }
  #|  - name: plain
  #|    default: true

///|
test "a call's Mock is the Mock that lists its Host, or else the Default Mock, each with its set; without either there is none" {
  let h = harness([("mocks.yaml", two_mocks)], body_files=greeter_body_files())
  let shown = (authority : String) => {
    let request : @engine.Request = {
      meth: "POST",
      target: "/helloworld.Greeter/SayHello",
      version: "HTTP/2",
      headers: [],
      body: b"",
    }
    match h.engine.mock_for_call(request, authority~) {
      Some(mock) =>
        "\{authority}: \{mock.name}, set: \{mock.descriptor_set is Some(_)}"
      None => "\{authority}: no Mock"
    }
  }
  inspect(
    [shown("greeter.svc"), shown("GREETER.svc:8080"), shown("other.svc")].join(
      "\n",
    ),
    content=(
      #|greeter.svc: greeter, set: true
      #|GREETER.svc:8080: greeter, set: true
      #|other.svc: plain, set: false
    ),
  )
  let no_default = harness(
    [
      (
        "mocks.yaml",
        (
          #|mocks:
          #|  - name: greeter
          #|    hosts: [greeter.svc]
          #|    grpc: { descriptorSet: greeter.binpb }
          #|  - name: other
          #|    hosts: [other.svc]
        ),
      ),
    ],
    body_files=greeter_body_files(),
  )
  let request : @engine.Request = {
    meth: "POST",
    target: "/helloworld.Greeter/SayHello",
    version: "HTTP/2",
    headers: [("host", "nowhere.svc")],
    body: b"",
  }
  inspect(no_default.engine.mock_for_call(request) is None, content="true")
  // Without :authority, the host field gives the Host, as for `handle`.
  inspect(
    no_default.engine
    .mock_for_call({ ..request, headers: [("host", "other.svc")], })
    .map(mock => mock.name)
    .unwrap_or("none"),
    content="other",
  )
}

///|
/// The Mock `greeter`, the Default Mock, with the set: an HTTP Stub that
/// answers every POST, tried first, then two gRPC Stubs on SayHello, the
/// first for Ann, and an HTTP Stub whose path pattern takes every method of
/// the service.
let greeter_calls : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: any-post
  #|    mock: greeter
  #|    priority: 0
  #|    request: { method: POST }
  #|    response: { status: 200, body: http }
  #|  - id: hello-ann
  #|    mock: greeter
  #|    request:
  #|      path: /helloworld.Greeter/SayHello
  #|      body: { json: { name: Ann } }
  #|    response: { json: { message: Hello Ann } }
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello } }
  #|  - id: greeter-paths
  #|    mock: greeter
  #|    request: { method: POST, path: { pattern: "/helloworld\\.Greeter/.*" } }
  #|    response: { status: 200, body: pattern }

///|
test "a gRPC call matches only the gRPC Stubs on its method, in matching order, never an HTTP Stub" {
  for match_index in [true, false] {
    let h = harness(
      [("greeter.yaml", greeter_calls)],
      body_files=greeter_body_files(),
      match_index~,
    )
    let ann = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Ann\"}",
      octets=10,
    )
    let tom = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    inspect(
      "\{matched_id(ann).unwrap_or("none")} \{matched_id(tom).unwrap_or("none")}",
      content="hello-ann hello",
    )
    inspect(
      response(tom),
      content=(
        #|200
        #|Smock-Mock: greeter; via=default
        #|{"message":"Hello"}
      ),
    )
    inspect(tom.is_grpc_reply(), content="true")
    // The same request without the marker is an HTTP request.
    let http = h.send(
      "POST",
      "/helloworld.Greeter/SayHello",
      body="{\"name\":\"Tom\"}",
    )
    inspect(matched_id(http).unwrap_or("none"), content="any-post")
  }
}

///|
test "a call to a method without a gRPC Stub matches nothing, and has no Near miss, though HTTP Stubs would take its path" {
  for match_index in [true, false] {
    let h = harness(
      [("greeter.yaml", greeter_calls)],
      body_files=greeter_body_files(),
      match_index~,
    )
    let outcome = h.call(
      "/helloworld.Greeter/SayHelloStreamReply",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    inspect(matched_id(outcome).unwrap_or("none"), content="none")
    inspect(outcome.near_miss is None, content="true")
    inspect(outcome.is_grpc_reply(), content="false")
  }
}

///|
test "an unmatched call's Near miss is chosen among the gRPC Stubs on its method, never an HTTP Stub" {
  let files = [
    (
      "greeter.yaml",
      (
        #|mocks:
        #|  - name: greeter
        #|    grpc: { descriptorSet: greeter.binpb }
        #|stubs:
        #|  - id: greeter-paths
        #|    mock: greeter
        #|    request: { method: POST, path: { pattern: "/helloworld\\.Greeter/.*" }, body: { json: { name: Tom } } }
        #|    response: { status: 200, body: pattern }
        #|  - id: hello-ann
        #|    mock: greeter
        #|    request:
        #|      path: /helloworld.Greeter/SayHello
        #|      headers: { x-tenant: acme }
        #|      body: { json: { name: Ann } }
        #|    response: { json: { message: Hello Ann } }
      ),
    ),
  ]
  for match_index in [true, false] {
    let h = harness(files, body_files=greeter_body_files(), match_index~)
    let outcome = h.call(
      "/helloworld.Greeter/SayHello",
      "{\"name\":\"Tom\"}",
      octets=10,
    )
    inspect(matched_id(outcome).unwrap_or("none"), content="none")
    guard outcome.near_miss is Some(near_miss) else { fail("no Near miss") }
    inspect(
      "\{near_miss.stub}: \{near_miss.failed.length()} failed",
      content="hello-ann: 2 failed",
    )
    inspect(outcome.is_grpc_reply(), content="false")
  }
}

///|
/// The body of the Journal entry of `outcome`, as the Admin API shows it.
fn entry_body(outcome : @engine.Outcome) -> Json {
  guard outcome.journal is Some(entry) &&
    entry.to_json() is Object({ "request": Object({ "body": body, .. }), .. }) else {
    abort("no entry")
  }
  body
}

///|
test "a call's entry records the decoded JSON, with the octets received as its size" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  json_inspect(entry_body(outcome), content={
    "encoding": "utf-8",
    "data": "{\"name\":\"Tom\"}",
    "size": 10,
    "truncated": false,
  })
  // The JSON is longer than the octets, or shorter: truncated says only
  // whether the JSON was cut.
  let unknown = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"\"}",
    octets=40,
  )
  json_inspect(entry_body(unknown), content={
    "encoding": "utf-8",
    "data": "{\"name\":\"\"}",
    "size": 40,
    "truncated": false,
  })
  guard unknown.journal is Some(entry) else { fail("no entry") }
  inspect(
    "\{entry.request.meth} \{entry.request.target} \{entry.request.version}",
    content="POST /helloworld.Greeter/SayHello HTTP/2",
  )
}

///|
test "a call's JSON is cut at the Journal's body limit, and its size is still the octets received" {
  let h = harness(
    [("greeter.yaml", greeter_calls)],
    body_files=greeter_body_files(),
    journal=@engine.JournalSettings(body_limit=5),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  json_inspect(entry_body(outcome), content={
    "encoding": "utf-8",
    "data": "{\"nam",
    "size": 10,
    "truncated": true,
  })
}

///|
test "a gRPC Stub that fails to render its reply plans smock's own answer, which is not a gRPC reply" {
  let h = harness(
    [
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
          #|    response: { template: true, json: { message: "${body.missing.deeper}" } }
        ),
      ),
    ],
    body_files=greeter_body_files(),
  )
  let outcome = h.call(
    "/helloworld.Greeter/SayHello",
    "{\"name\":\"Tom\"}",
    octets=10,
  )
  inspect(matched_id(outcome).unwrap_or("none"), content="hello")
  inspect(outcome.plan.status, content="500")
  inspect(outcome.is_grpc_reply(), content="false")
}

///|
test "a call's Mock names the method of its set that the call's path names, with its types, or none" {
  let h = harness([("mocks.yaml", two_mocks)], body_files=greeter_body_files())
  let request : @engine.Request = {
    meth: "POST",
    target: "/",
    version: "HTTP/2",
    headers: [],
    body: b"",
  }
  let shown = (authority : String, path : String) => {
    guard h.engine.mock_for_call(request, authority~) is Some(mock) else {
      return "no Mock"
    }
    match mock.grpc_method(path) {
      Some(found) => {
        let rpc = found.rpc
        let types = "\{found.input.map_or("none", m => m.name)} -> \{found.output.map_or("none", m => m.name)}"
        "\{mock.name} \{path}: \{rpc.name}, streams \{rpc.client_streaming || rpc.server_streaming}, \{types}"
      }
      None => "\{mock.name} \{path}: no method"
    }
  }
  inspect(
    [
      shown("greeter.svc", "/helloworld.Greeter/SayHello"),
      shown("greeter.svc", "/helloworld.Greeter/SayHelloStreamReply"),
      shown("greeter.svc", "/helloworld.Greeter/SayGoodbye"),
      shown("greeter.svc", "/helloworld.Greeter/SayHello/x"),
      shown("greeter.svc", "helloworld.Greeter/SayHello"),
      shown("other.svc", "/helloworld.Greeter/SayHello"),
    ].join("\n"),
    content=(
      #|greeter /helloworld.Greeter/SayHello: SayHello, streams false, HelloRequest -> HelloReply
      #|greeter /helloworld.Greeter/SayHelloStreamReply: SayHelloStreamReply, streams true, HelloRequest -> HelloReply
      #|greeter /helloworld.Greeter/SayGoodbye: no method
      #|greeter /helloworld.Greeter/SayHello/x: no method
      #|greeter helloworld.Greeter/SayHello: no method
      #|plain /helloworld.Greeter/SayHello: no method
    ),
  )
}
