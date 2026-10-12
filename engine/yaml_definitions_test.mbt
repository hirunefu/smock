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
]

///|
/// Loads one Definition file given as text.
fn load_one(
  name : String,
  text : String,
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  @definitions.load({ files: [(name, @utf8.encode(text))], body_files: [], })
}

///|
test "every YAML Definition file gives the same tree and the same snapshot as its JSON twin" {
  for fixture in yaml_fixtures {
    let (name, yaml, json) = fixture
    assert_eq(@yaml.parse(yaml), @json.parse(json), msg="tree of \{name}")
    let from_yaml = load_one("\{name}.yaml", yaml)
    guard from_yaml is Ok(_) else { fail("\{name}.yaml is invalid") }
    assert_eq(
      from_yaml,
      load_one("\{name}.json", json),
      msg="snapshot of \{name}",
    )
    // A .yml file is read the same way.
    assert_eq(from_yaml, load_one("\{name}.yml", yaml), msg="\{name}.yml")
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
      #|[{"id": 1}, {"id": 2}]
      #|
      #|---
      #|201
      #|created order 3
      #|---
      #|404
      #|
    ),
  )
}

///|
test "YAML and JSON Definition files mix, read in byte-wise name order whatever their extension" {
  // Byte-wise, "Z.yml" < "aa.json" < "b.yaml" < "mocks.yaml".
  let yaml_stub = (id : String) => {
    (
      $|stubs:
      $|  - id: \{id}
      $|    mock: m
      $|    request: { method: GET, path: /x }
      $|    response: { status: 200, body: \{id} }
    )
  }
  let json_stub = (id : String) => {
    (
      $|{ "stubs": [{ "id": "\{id}", "mock": "m",
      $|  "request": { "method": "GET", "path": "/x" },
      $|  "response": { "status": 200, "body": "\{id}" } }] }
    )
  }
  let h = harness([
    ("b.yaml", yaml_stub("from-b")),
    ("aa.json", json_stub("from-aa")),
    ("mocks.yaml", "mocks: [{ name: m }]\n"),
  ])
  inspect(response(h.send("GET", "/x")), content="200\nfrom-aa")
  let h = harness([
    ("b.yaml", yaml_stub("from-b")),
    ("aa.json", json_stub("from-aa")),
    ("Z.yml", yaml_stub("from-Z")),
    ("mocks.yaml", "mocks: [{ name: m }]\n"),
  ])
  inspect(response(h.send("GET", "/x")), content="200\nfrom-Z")
}
