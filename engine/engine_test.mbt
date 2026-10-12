///|
let users : String =
  #|{
  #|  "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    {
  #|      "id": "get-user",
  #|      "mock": "users",
  #|      "request": { "method": "GET", "path": "/users/1" },
  #|      "response": {
  #|        "status": 200,
  #|        "headers": { "Content-Type": "application/json", "X-Source": "smock" },
  #|        "body": "{\"id\":1,\"name\":\"Alice\"}"
  #|      }
  #|    }
  #|  ]
  #|}

///|
test "a request whose method and path equal a Stub's gets that Stub's response" {
  let h = harness([("users.json", users)])
  inspect(
    describe(h.send("GET", "/users/1", headers=[("Host", "localhost:8080")])),
    content=(
      #|plan:
      #|  status: 200
      #|  header: Content-Type: application/json
      #|  header: X-Source: smock
      #|  body: "{\"id\":1,\"name\":\"Alice\"}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  mock: Some("users")
      #|  request: GET /users/1
      #|  header: Host: localhost:8080
      #|  body: ""
      #|  stub: Some("get-user")
      #|  status: 200
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "the path is compared without the query" {
  let h = harness([("users.json", users)])
  inspect(
    response(h.send("GET", "/users/1?fields=name&x")),
    content=(
      #|200
      #|Content-Type: application/json
      #|X-Source: smock
      #|{"id":1,"name":"Alice"}
    ),
  )
}

///|
test "any other request gets 404 with an empty body" {
  let h = harness([("users.json", users)])
  let requests = [
    ("POST", "/users/1"),
    ("get", "/users/1"),
    ("GET", "/users/2"),
    ("GET", "/users/1/"),
    ("GET", "/USERS/1"),
    ("GET", "/"),
  ]
  inspect(
    requests
    .map(r => {
      let outcome = h.send(r.0, r.1)
      "\{r.0} \{r.1} -> \{response(outcome)} stub=\{@debug.to_string(outcome.journal.stub)}"
    })
    .join("\n"),
    content=(
      #|POST /users/1 -> 404
      #| stub=None
      #|get /users/1 -> 404
      #| stub=None
      #|GET /users/2 -> 404
      #| stub=None
      #|GET /users/1/ -> 404
      #| stub=None
      #|GET /USERS/1 -> 404
      #| stub=None
      #|GET / -> 404
      #| stub=None
    ),
  )
}

///|
test "with no Definition file, one empty Mock named default answers 404" {
  let h = harness([])
  inspect(
    describe(h.send("GET", "/anything")),
    content=(
      #|plan:
      #|  status: 404
      #|  body: ""
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  mock: Some("default")
      #|  request: GET /anything
      #|  body: ""
      #|  stub: None
      #|  status: 404
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "Definition files are read in byte-wise name order, so the first matching Stub of the earliest file wins" {
  // Byte-wise, "Z.json" < "aa.json" < "b.json"; by length first, "b.json"
  // would come before "aa.json".
  let stub = (id : String) => {
    (
      $|{ "stubs": [{ "id": "\{id}", "mock": "m",
      $|  "request": { "method": "GET", "path": "/x" },
      $|  "response": { "status": 200, "body": "\{id}" } }] }
    )
  }
  let h = harness([
    ("b.json", stub("from-b")),
    ("aa.json", stub("from-aa")),
    ("mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }"),
  ])
  inspect(response(h.send("GET", "/x")), content="200\nfrom-aa")
  let h = harness([
    ("b.json", stub("from-b")),
    ("aa.json", stub("from-aa")),
    ("Z.json", stub("from-Z")),
    ("mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }"),
  ])
  inspect(response(h.send("GET", "/x")), content="200\nfrom-Z")
}
