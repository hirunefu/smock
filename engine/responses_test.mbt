// Seam 1 tests of static responses: what a Stub answers, and what a Mock
// answers when no Stub matches.

///|
test "a Stub answers with its status, its headers in order, and its inline body" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "created", "mock": "m", "request": { "method": "POST" },
        #|      "response": { "status": 201,
        #|        "headers": { "Location": "/users/7", "Content-Type": "text/plain; charset=utf-8" },
        #|        "body": "créé\n" } },
        #|    { "id": "empty", "mock": "m", "response": { "status": 204 } } ] }
      ),
    ),
  ])
  inspect(
    response(h.send("POST", "/users")) +
    "\n---\n" +
    response(h.send("GET", "/")),
    content=(
      #|201
      #|Location: /users/7
      #|Content-Type: text/plain; charset=utf-8
      #|Smock-Mock: m; via=default
      #|créé
      #|
      #|---
      #|204
      #|Smock-Mock: m; via=default
      #|
    ),
  )
}

///|
test "a Stub answers with the bytes of its body file, named relative to the body-file subdirectory" {
  let h = harness(
    [
      (
        "m.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "user", "mock": "m", "request": { "path": "/users/1" },
          #|      "response": { "status": 200,
          #|        "headers": { "Content-Type": "application/json" },
          #|        "bodyFile": "users/1.json" } },
          #|    { "id": "again", "mock": "m", "request": { "path": "/again" },
          #|      "response": { "status": 200, "bodyFile": "users/1.json" } },
          #|    { "id": "binary", "mock": "m", "request": { "path": "/logo" },
          #|      "response": { "status": 200, "bodyFile": "logo.bin" } } ] }
        ),
      ),
    ],
    body_files=[
      ("users/1.json", b"{\"id\":1,\"name\":\"Alice\"}\n"),
      ("logo.bin", b"\x89PNG\r\n\x1a\n\x00\xff"),
      ("unused.txt", b"never served"),
    ],
  )
  inspect(
    response(h.send("GET", "/users/1")) +
    "\n---\n" +
    response(h.send("GET", "/again")),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"id":1,"name":"Alice"}
      #|
      #|---
      #|200
      #|Smock-Mock: m; via=default
      #|{"id":1,"name":"Alice"}
      #|
    ),
  )
  guard h.send("GET", "/logo").plan.body is Bytes(logo) else {
    fail("not a byte body")
  }
  assert_eq(logo, b"\x89PNG\r\n\x1a\n\x00\xff")
}

///|
test "when no Stub matches, the Mock answers 404 with a JSON body saying so" {
  let h = harness([
    (
      "users.json",
      (
        #|{ "mocks": [{ "name": "users" }],
        #|  "stubs": [{ "id": "get-user", "mock": "users",
        #|    "request": { "method": "GET", "path": "/users/1" },
        #|    "response": { "status": 200 } }] }
      ),
    ),
  ])
  inspect(
    describe(h.send("GET", "/users/2")),
    content=(
      #|plan:
      #|  status: 404
      #|  header: Content-Type: application/json
      #|  header: Smock-Near-Miss: get-user; failed=path
      #|  header: Smock-Mock: users; via=default
      #|  body: "{\"error\":\"no Stub matched\"}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  mock: Some("users")
      #|  request: GET /users/2
      #|  body: ""
      #|  stub: None
      #|  status: 404
      #|  received_at: 1791815405123
      #|near_miss: Some(
      #|  {
      #|    stub: "get-user",
      #|    failed: [{ condition: Path, expected: Exact("/users/1"), actual: ["/users/2"] }],
      #|  },
      #|)
    ),
  )
}

///|
test "a Mock's noMatch.status is the status when no Stub matches" {
  let answer = (mock : String) => {
    let h = harness([("m.json", "{ \"mocks\": [\{mock}] }")])
    response(h.send("GET", "/anything"))
  }
  inspect(
    [
      answer("{ \"name\": \"m\", \"noMatch\": { \"status\": 418 } }"),
      answer("{ \"name\": \"m\", \"noMatch\": { \"status\": 503 } }"),
      answer("{ \"name\": \"m\", \"noMatch\": {} }"),
      answer("{ \"name\": \"m\" }"),
    ].join("\n---\n"),
    content=(
      #|418
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|503
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
    ),
  )
}
