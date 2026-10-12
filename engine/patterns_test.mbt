// Seam 1 tests of pattern conditions: RE2 patterns that must match the
// whole path, query parameter value, header value or body.

///|
test "a path pattern must match the whole percent-decoded path, without the query" {
  let h = stubs([
    (
      #|{ "id": "user", "mock": "m",
      #|  "request": { "path": { "pattern": "/users/[0-9]+" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "file", "mock": "m",
      #|  "request": { "path": { "pattern": "/files/[^/]+ [^/]+" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "café", "mock": "m",
      #|  "request": { "path": { "pattern": "/caf./(?i)menu" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/users/42", [], ""),
      ("GET", "/users/42?page=2", [], ""),
      ("GET", "/users/%34%32", [], ""),
      ("GET", "/users/", [], ""),
      ("GET", "/users/4a", [], ""),
      ("GET", "/files/a%20b", [], ""),
      ("GET", "/files/a+b", [], ""),
      ("GET", "/caf%C3%A9/MENU", [], ""),
      ("GET", "/café/Menu", [], ""),
      ("GET", "http://localhost/users/7?x=1", [], ""),
    ]),
    content=(
      #|GET /users/42 -> user
      #|GET /users/42?page=2 -> user
      #|GET /users/%34%32 -> user
      #|GET /users/ -> none
      #|GET /users/4a -> none
      #|GET /files/a%20b -> file
      #|GET /files/a+b -> none
      #|GET /caf%C3%A9/MENU -> café
      #|GET /café/Menu -> café
      #|GET http://localhost/users/7?x=1 -> user
    ),
  )
}

///|
test "a query parameter with a pattern must be present, and its decoded value must match the pattern as a whole; others are ignored" {
  let h = stubs([
    (
      #|{ "id": "paged", "mock": "m",
      #|  "request": { "query": { "page": { "pattern": "[1-9][0-9]*" }, "q": { "pattern": "a b.*" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?page=1&q=a+b", [], ""),
      ("GET", "/?q=a%20bc&page=20&sort=asc", [], ""),
      ("GET", "/?page=%31%30&q=a+b", [], ""),
      ("GET", "/?page=0&q=a+b", [], ""),
      ("GET", "/?page=&q=a+b", [], ""),
      ("GET", "/?page&q=a+b", [], ""),
      ("GET", "/?q=a+b", [], ""),
      ("GET", "/?Page=1&q=a+b", [], ""),
      ("GET", "/?page=1&q=xa+b", [], ""),
    ]),
    content=(
      #|GET /?page=1&q=a+b -> paged
      #|GET /?q=a%20bc&page=20&sort=asc -> paged
      #|GET /?page=%31%30&q=a+b -> paged
      #|GET /?page=0&q=a+b -> none
      #|GET /?page=&q=a+b -> none
      #|GET /?page&q=a+b -> none
      #|GET /?q=a+b -> none
      #|GET /?Page=1&q=a+b -> none
      #|GET /?page=1&q=xa+b -> none
    ),
  )
}

///|
test "a repeated query parameter meets a pattern when any of its values matches it" {
  let h = stubs([
    (
      #|{ "id": "numbered", "mock": "m",
      #|  "request": { "query": { "id": { "pattern": "[0-9]+" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?id=x&id=7&id=y", [], ""),
      ("GET", "/?id=7&id=x", [], ""),
      ("GET", "/?id=x&id=y", [], ""),
      ("GET", "/?id=1,2", [], ""),
    ]),
    content=(
      #|GET /?id=x&id=7&id=y -> numbered
      #|GET /?id=7&id=x -> numbered
      #|GET /?id=x&id=y -> none
      #|GET /?id=1,2 -> none
    ),
  )
}

///|
test "a header with a pattern must be present, whatever the case of its name, and its value must match the pattern as a whole" {
  let h = stubs([
    (
      #|{ "id": "bearer", "mock": "m",
      #|  "request": { "headers": { "Authorization": { "pattern": "Bearer [A-Za-z0-9._-]+" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Authorization", "Bearer abc.def-1")], ""),
      ("GET", "/", [("authorization", "Bearer x")], ""),
      ("GET", "/", [("Host", "localhost"), ("AUTHORIZATION", "Bearer x")], ""),
      ("GET", "/", [("Authorization", "Bearer ")], ""),
      ("GET", "/", [("Authorization", "bearer x")], ""),
      ("GET", "/", [("Authorization", "Basic eDp5")], ""),
      ("GET", "/", [("X-Authorization", "Bearer x")], ""),
      ("GET", "/?Authorization=Bearer+x", [], ""),
    ]),
    content=(
      #|GET / [Authorization: Bearer abc.def-1] -> bearer
      #|GET / [authorization: Bearer x] -> bearer
      #|GET / [Host: localhost] [AUTHORIZATION: Bearer x] -> bearer
      #|GET / [Authorization: Bearer ] -> none
      #|GET / [Authorization: bearer x] -> none
      #|GET / [Authorization: Basic eDp5] -> none
      #|GET / [X-Authorization: Bearer x] -> none
      #|GET /?Authorization=Bearer+x -> none
    ),
  )
}

///|
test "a repeated header meets a pattern when any of its values matches it" {
  let h = stubs([
    (
      #|{ "id": "json", "mock": "m",
      #|  "request": { "headers": { "accept": { "pattern": "application/(.+\\+)?json" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Accept", "text/html"), ("ACCEPT", "application/json")], ""),
      ("GET", "/", [("Accept", "application/problem+json"), ("Accept", "x")], ""),
      ("GET", "/", [("Accept", "text/html"), ("Accept", "application/xml")], ""),
    ]),
    content=(
      #|GET / [Accept: text/html] [ACCEPT: application/json] -> json
      #|GET / [Accept: application/problem+json] [Accept: x] -> json
      #|GET / [Accept: text/html] [Accept: application/xml] -> none
    ),
  )
}

///|
test "a body pattern must match the whole body" {
  let h = stubs([
    (
      #|{ "id": "form", "mock": "m",
      #|  "request": { "body": { "pattern": "name=[^&]+&age=[0-9]+" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "multiline", "mock": "m",
      #|  "request": { "method": "PUT", "body": { "pattern": "(?s)BEGIN.*END\n?" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "name=Zoë&age=30"),
      ("POST", "/", [], "name=&age=30"),
      ("POST", "/", [], "name=Zoë&age=30&x=1"),
      ("POST", "/", [], ""),
      ("PUT", "/", [], "BEGIN\nline 1\nline 2\nEND\n"),
      ("PUT", "/", [], "BEGIN END"),
      ("PUT", "/", [], "BEGIN\nEND\n\n"),
    ]),
    content=(
      #|POST / "name=Zoë&age=30" -> form
      #|POST / "name=&age=30" -> none
      #|POST / "name=Zoë&age=30&x=1" -> none
      #|POST / -> none
      #|PUT / "BEGIN\nline 1\nline 2\nEND\n" -> multiline
      #|PUT / "BEGIN END" -> multiline
      #|PUT / "BEGIN\nEND\n\n" -> none
    ),
  )
}

///|
test "a pattern that matches only part of a value does not match it" {
  let h = stubs([
    (
      #|{ "id": "path", "mock": "m", "request": { "path": { "pattern": "/users" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "query", "mock": "m", "request": { "query": { "id": { "pattern": "[0-9]" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "header", "mock": "m", "request": { "headers": { "X-Key": { "pattern": "k[a-z]" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "body", "mock": "m", "request": { "body": { "pattern": "Alice" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/users", [], ""),
      ("GET", "/users/1", [], ""),
      ("GET", "/api/users", [], ""),
      ("GET", "/x?id=7", [], ""),
      ("GET", "/x?id=77", [], ""),
      ("GET", "/x?id=a7", [], ""),
      ("GET", "/x", [("X-Key", "ka")], ""),
      ("GET", "/x", [("X-Key", "kab")], ""),
      ("GET", "/x", [("X-Key", "aka")], ""),
      ("POST", "/x", [], "Alice"),
      ("POST", "/x", [], "Alice and Bob"),
      ("POST", "/x", [], "Bob and Alice"),
      ("POST", "/x", [], "Alice\n"),
    ]),
    content=(
      #|GET /users -> path
      #|GET /users/1 -> none
      #|GET /api/users -> none
      #|GET /x?id=7 -> query
      #|GET /x?id=77 -> none
      #|GET /x?id=a7 -> none
      #|GET /x [X-Key: ka] -> header
      #|GET /x [X-Key: kab] -> none
      #|GET /x [X-Key: aka] -> none
      #|POST /x "Alice" -> body
      #|POST /x "Alice and Bob" -> none
      #|POST /x "Bob and Alice" -> none
      #|POST /x "Alice\n" -> none
    ),
  )
}

///|
test "exact, pattern and json conditions combine on one Stub, which matches only when all of them hold" {
  let h = stubs([
    (
      #|{ "id": "create", "mock": "m",
      #|  "request": {
      #|    "method": "POST",
      #|    "path": { "pattern": "/teams/[a-z]+/users" },
      #|    "query": { "dryRun": "true", "v": { "pattern": "[0-9]+" } },
      #|    "headers": { "Content-Type": { "pattern": "application/json(;.*)?" }, "X-Api-Key": "k" },
      #|    "body": { "json": { "name": "Alice" } } },
      #|  "response": { "status": 201 } }
    ),
  ])
  let headers = [
    ("Content-Type", "application/json; charset=utf-8"),
    ("X-Api-Key", "k"),
  ]
  let body = "{\"name\":\"Alice\",\"age\":30}"
  inspect(
    winners(h, [
      ("POST", "/teams/red/users?dryRun=true&v=2", headers, body),
      ("PUT", "/teams/red/users?dryRun=true&v=2", headers, body),
      ("POST", "/teams/Red/users?dryRun=true&v=2", headers, body),
      ("POST", "/teams/red/users?dryRun=false&v=2", headers, body),
      ("POST", "/teams/red/users?dryRun=true&v=two", headers, body),
      (
        "POST",
        "/teams/red/users?dryRun=true&v=2",
        [("Content-Type", "text/plain"), ("X-Api-Key", "k")],
        body,
      ),
      (
        "POST",
        "/teams/red/users?dryRun=true&v=2",
        [("Content-Type", "application/json"), ("X-Api-Key", "K")],
        body,
      ),
      ("POST", "/teams/red/users?dryRun=true&v=2", headers, "{\"name\":\"Bob\"}"),
    ]),
    content=(
      #|POST /teams/red/users?dryRun=true&v=2 [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> create
      #|PUT /teams/red/users?dryRun=true&v=2 [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/Red/users?dryRun=true&v=2 [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/red/users?dryRun=false&v=2 [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/red/users?dryRun=true&v=two [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/red/users?dryRun=true&v=2 [Content-Type: text/plain] [X-Api-Key: k] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/red/users?dryRun=true&v=2 [Content-Type: application/json] [X-Api-Key: K] "{\"name\":\"Alice\",\"age\":30}" -> none
      #|POST /teams/red/users?dryRun=true&v=2 [Content-Type: application/json; charset=utf-8] [X-Api-Key: k] "{\"name\":\"Bob\"}" -> none
    ),
  )
}

///|
test "Stubs with patterns are tried by priority, then in declaration order, like any other Stub" {
  let h = harness([
    mock_m,
    (
      "a.json",
      stub_file([
        stub("any-user", request="\"path\": { \"pattern\": \"/users/.*\" }"),
        stub(
          "numbered-user",
          priority=5,
          request="\"path\": { \"pattern\": \"/users/[0-9]+\" }",
        ),
        stub("user-1", priority=5, request="\"path\": \"/users/1\""),
        stub("first-pattern", request="\"path\": { \"pattern\": \"/x.*\" }"),
        stub("second-pattern", request="\"path\": { \"pattern\": \"/x.*\" }"),
      ]),
    ),
    (
      "b.json",
      stub_file([
        stub("me", priority=1, request="\"path\": { \"pattern\": \"/users/me\" }"),
      ]),
    ),
  ])
  inspect(
    ["/users/1", "/users/2", "/users/me", "/users/you", "/xyz"]
    .map(target => "\{target} -> \{winner(h, target)}")
    .join("\n"),
    content=(
      #|/users/1 -> numbered-user
      #|/users/2 -> numbered-user
      #|/users/me -> me
      #|/users/you -> any-user
      #|/xyz -> first-pattern
    ),
  )
}

///|
test "pathological patterns against long inputs are answered in linear time" {
  // A backtracking matcher takes time exponential in the input's length on
  // each of these patterns when the input almost matches; the RE2 module
  // takes time linear in it, so these requests are answered at once.
  let h = stubs([
    (
      #|{ "id": "path", "mock": "m", "request": { "path": { "pattern": "/(a|aa)*b" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "header", "mock": "m", "request": { "headers": { "X-A": { "pattern": "(a*)*c" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "query", "mock": "m", "request": { "query": { "q": { "pattern": "(x+x+)+y" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "body", "mock": "m", "request": { "body": { "pattern": "(a+)+" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let n = 100_000
  let a = "a".repeat(n)
  let x = "x".repeat(n)
  let send = (target : String, headers : Array[(String, String)], body) => {
    h.send("POST", target, headers~, body~).journal.stub.unwrap_or("none")
  }
  inspect(
    [
      send("/\{a}!", [], ""),
      send("/\{a}b", [], ""),
      send("/", [("X-A", "\{a}!")], ""),
      send("/", [("X-A", "\{a}c")], ""),
      send("/?q=\{x}!", [], ""),
      send("/?q=\{x}y", [], ""),
      send("/", [], "\{a}!"),
      send("/", [], a),
    ].join(" "),
    content="none path none header none query none body",
  )
}

///|
test "a body that is not valid UTF-8 never matches a body pattern as a whole, even one that matches any text" {
  let h = stubs([
    (
      #|{ "id": "anything", "mock": "m", "request": { "body": { "pattern": "(?s).*" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let send = (body : Bytes) => {
    h.engine.handle(
      { meth: "POST", target: "/", headers: [], body, },
      session=None,
      now=h.now,
      rand=h.rand,
    ).journal.stub
  }
  debug_inspect(
    [
      send(b""),
      send(b"caf\xc3\xa9\n\x00"),
      send(b"\xff"),
      send(b"ab\xffcd"),
      send(b"caf\xc3"),
      send(b"\xc0\xaf"),
      send(b"\xed\xa0\x80"),
    ],
    content=(
      #|[Some("anything"), Some("anything"), None, None, None, None, None]
    ),
  )
}
