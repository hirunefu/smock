///|
/// Every YAML Definition file these tests use, each with the JSON file
/// that means the same: (name, YAML text, JSON text).
let yaml_fixtures : Array[(String, String, String)] = [
  (
    "users",
    (
      #|# The users service, as `users` in engine_test.mbt.
      #|mocks:
      #|  - name: users
      #|stubs:
      #|  - id: get-user
      #|    mock: users
      #|    request:
      #|      method: GET
      #|      path: /users/1
      #|    response:
      #|      status: 200
      #|      headers:
      #|        Content-Type: application/json
      #|        X-Source: smock
      #|      body: '{"id":1,"name":"Alice"}'
    ),
    users,
  ),
  (
    "orders",
    (
      #|---
      #|mocks: [{ name: orders }]
      #|stubs:
      #|- id: list-orders
      #|  mock: orders
      #|  request: { method: GET, path: /orders }
      #|  response:
      #|    status: 200
      #|    headers: { Content-Type: application/json }
      #|    body: |
      #|      [{"id": 1}, {"id": 2}]
      #|- id: create-order
      #|  mock: orders
      #|  request:
      #|    method: POST
      #|    path: "/orders"
      #|  response:
      #|    status: 201
      #|    body: >-
      #|      created
      #|      order 3
      #|...
    ),
    (
      #|{ "mocks": [{ "name": "orders" }],
      #|  "stubs": [
      #|    { "id": "list-orders", "mock": "orders",
      #|      "request": { "method": "GET", "path": "/orders" },
      #|      "response": { "status": 200, "headers": { "Content-Type": "application/json" },
      #|        "body": "[{\"id\": 1}, {\"id\": 2}]\n" } },
      #|    { "id": "create-order", "mock": "orders",
      #|      "request": { "method": "POST", "path": "/orders" },
      #|      "response": { "status": 201, "body": "created order 3" } }
      #|  ] }
    ),
  ),
  (
    "JSON is YAML",
    (
      #|{ "mocks": [{ "name": "m" }],
      #|  "stubs": [{ "id": "s", "mock": "m", "response": { "status": 204, "body": "café" } }] }
    ),
    (
      #|{ "mocks": [{ "name": "m" }],
      #|  "stubs": [{ "id": "s", "mock": "m", "response": { "status": 204, "body": "café" } }] }
    ),
  ),
  ("mock m", "mocks: [{ name: m }]\n", "{ \"mocks\": [{ \"name\": \"m\" }] }"),
  ("stub from-aa", yaml_stub("from-aa"), json_stub("from-aa")),
  ("stub from-b", yaml_stub("from-b"), json_stub("from-b")),
  ("stub from-Z", yaml_stub("from-Z"), json_stub("from-Z")),
]

///|
/// A Definition file declaring one Stub of Mock `m` that answers `GET /x`
/// with 200 and its ID.
fn yaml_stub(id : String) -> String {
  (
    $|stubs:
    $|  - id: \{id}
    $|    mock: m
    $|    request: { method: GET, path: /x }
    $|    response: { status: 200, body: \{id} }
  )
}

///|
/// `yaml_stub` written in JSON.
fn json_stub(id : String) -> String {
  (
    $|{ "stubs": [{ "id": "\{id}", "mock": "m",
    $|  "request": { "method": "GET", "path": "/x" },
    $|  "response": { "status": 200, "body": "\{id}" } }] }
  )
}

///|
/// Loads one Definition file given as text: its snapshot, or its problems
/// without the file name.
fn load_one(
  name : String,
  text : String,
) -> Result[@definitions.Snapshot, Array[String]] {
  match
    @definitions.load({ files: [(name, @utf8.encode(text))], body_files: [], }) {
    Ok(snapshot) => Ok(snapshot)
    Err(diagnostics) => Err(diagnostics.map(d => "\{d.pointer}: \{d.message}"))
  }
}

///|
test "every YAML Definition file gives the same tree and the same snapshot as its JSON twin" {
  for fixture in yaml_fixtures {
    let (name, yaml, json) = fixture
    assert_eq(@yaml.parse(yaml), @json.parse(json), msg="tree of \{name}")
    let from_yaml = load_one("\{name}.yaml", yaml)
    assert_eq(
      from_yaml,
      load_one("\{name}.json", json),
      msg="snapshot of \{name}",
    )
    // A .yml file is read the same way.
    assert_eq(from_yaml, load_one("\{name}.yml", yaml), msg="\{name}.yml")
  }
  // The whole files are valid on their own.
  for name in ["users", "orders", "JSON is YAML", "mock m"] {
    guard load_one("\{name}.yaml", yaml_of(name)) is Ok(_) else {
      fail("\{name}.yaml is invalid")
    }
  }
}

///|
test "the engine answers a request with the response of a Stub declared in a YAML file" {
  let (_, orders, _) = yaml_fixtures[1]
  let h = harness([("orders.yaml", orders)])
  inspect(
    response(h.send("GET", "/orders?page=1")) +
    "\n---\n" +
    response(h.send("POST", "/orders")) +
    "\n---\n" +
    response(h.send("DELETE", "/orders")),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: orders; via=default
      #|[{"id": 1}, {"id": 2}]
      #|
      #|---
      #|201
      #|Smock-Mock: orders; via=default
      #|created order 3
      #|---
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: orders; via=default
      #|{"error":"no Stub matched"}
    ),
  )
}

///|
/// The YAML text of fixture `name`.
fn yaml_of(name : String) -> String {
  for fixture in yaml_fixtures {
    if fixture.0 == name {
      return fixture.1
    }
  }
  abort("no YAML fixture \{name}")
}

///|
/// The JSON text of fixture `name`.
fn json_of(name : String) -> String {
  for fixture in yaml_fixtures {
    if fixture.0 == name {
      return fixture.2
    }
  }
  abort("no YAML fixture \{name}")
}

///|
test "YAML and JSON Definition files mix, read in byte-wise name order whatever their extension" {
  // Byte-wise, "Z.yml" < "aa.json" < "b.yaml" < "mocks.yaml".
  let h = harness([
    ("b.yaml", yaml_of("stub from-b")),
    ("aa.json", json_of("stub from-aa")),
    ("mocks.yaml", yaml_of("mock m")),
  ])
  inspect(
    response(h.send("GET", "/x")),
    content=(
      #|200
      #|Smock-Mock: m; via=default
      #|from-aa
    ),
  )
  let h = harness([
    ("b.yaml", yaml_of("stub from-b")),
    ("aa.json", json_of("stub from-aa")),
    ("Z.yml", yaml_of("stub from-Z")),
    ("mocks.yaml", yaml_of("mock m")),
  ])
  inspect(
    response(h.send("GET", "/x")),
    content=(
      #|200
      #|Smock-Mock: m; via=default
      #|from-Z
    ),
  )
}
