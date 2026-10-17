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
test "a header given an array is sent once per value, in order, where its name stands" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "login", "mock": "m", "request": { "path": "/login" },
        #|      "response": { "status": 200,
        #|        "headers": { "X-A": "1",
        #|          "Set-Cookie": ["session=abc; Path=/; HttpOnly", "theme=dark; Path=/"],
        #|          "X-B": ["only"] },
        #|        "json": { "ok": true } } } ] }
      ),
    ),
  ])
  inspect(
    response(h.send("GET", "/login")),
    content=(
      #|200
      #|X-A: 1
      #|Set-Cookie: session=abc; Path=/; HttpOnly
      #|Set-Cookie: theme=dark; Path=/
      #|X-B: only
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"ok":true}
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
      #|  host: None
      #|  mock: Some("users")
      #|  via_default: true
      #|  request: GET /users/2 HTTP/1.1
      #|  body: ""
      #|  stub: None
      #|  status: Some(404)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: Some(
      #|  {
      #|    stub: "get-user",
      #|    stub_source: File,
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

///|
test "a Mock's noMatch.headers are sent, untemplated, on its every no-match response, after Content-Type and before smock's own headers" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [
        #|    { "name": "web", "hosts": ["web.test"], "default": true,
        #|      "noMatch": { "status": 418,
        #|        "headers": { "Access-Control-Allow-Origin": "*",
        #|          "Vary": ["Origin", "Accept"], "X-Path": "${request.path}" } } },
        #|    { "name": "plain", "hosts": ["plain.test"] } ],
        #|  "stubs": [
        #|    { "id": "get-user", "mock": "web",
        #|      "request": { "method": "GET", "path": "/users/1" },
        #|      "response": { "status": 200, "body": "user" } } ] }
      ),
    ),
  ])
  let send = (host : String, meth : String, target : String) => {
    response(h.send(meth, target, headers=[("Host", host)]))
  }
  inspect(
    [
      send("web.test", "OPTIONS", "/users/1"),
      send("other.test", "GET", "/nothing"),
      send("web.test", "GET", "/users/1"),
      send("plain.test", "GET", "/nothing"),
    ].join("\n---\n"),
    content=(
      #|418
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|Vary: Origin
      #|Vary: Accept
      #|X-Path: ${request.path}
      #|Smock-Near-Miss: get-user; failed=method
      #|{"error":"no Stub matched"}
      #|---
      #|418
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|Vary: Origin
      #|Vary: Accept
      #|X-Path: ${request.path}
      #|Smock-Near-Miss: get-user; failed=path
      #|Smock-Mock: web; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|200
      #|user
      #|---
      #|404
      #|Content-Type: application/json
      #|{"error":"no Stub matched"}
    ),
  )
}

///|
test "a request for a Host that no Mock answers gets none of a Mock's noMatch.headers" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [
        #|    { "name": "web", "hosts": ["web.test"],
        #|      "noMatch": { "headers": { "Access-Control-Allow-Origin": "*" } } },
        #|    { "name": "plain", "hosts": ["plain.test"] } ] }
      ),
    ),
  ])
  inspect(
    response(h.send("GET", "/", headers=[("Host", "other.test")])),
    content=(
      #|404
      #|Content-Type: application/json
      #|{"error":"no Mock for this Host","host":"other.test","acceptedHosts":["web.test","plain.test"]}
    ),
  )
}

///|
test "a reload reports an invalid noMatch header at its JSON Pointer and keeps serving, and a valid one adds the headers" {
  let mock = (no_match : String) => {
    "{ \"mocks\": [{ \"name\": \"m\", \"noMatch\": \{no_match} }] }"
  }
  let h = harness([("m.json", mock("{}"))])
  let failed = h.reload([
    ("m.json", mock("{ \"headers\": { \"Smock-Near-Miss\": \"x\" } }")),
  ])
  let after_failed = response(h.send("GET", "/"))
  let swapped = h.reload([
    (
      "m.json",
      mock("{ \"headers\": { \"Access-Control-Allow-Origin\": \"*\" } }"),
    ),
  ])
  inspect(
    [
      reload_summary(failed).replace_all(old=failed.old_digest, new="<old>"),
      after_failed,
      @debug.to_string(swapped.result),
      response(h.send("GET", "/")),
    ].join("\n---\n"),
    content=(
      #|Failed at 1791815460000: <old> -> <old>
      #|m.json: /mocks/0/noMatch/headers/Smock-Near-Miss: is set by smock and cannot be given
      #|---
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|Swapped
      #|---
      #|404
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
    ),
  )
}
