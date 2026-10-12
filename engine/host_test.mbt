// Host resolution and the Default Mock: which Mock answers a request.

///|
/// A Definition file declaring the Mock `name` with `mock_fields` added to
/// it, such as `"hosts": ["a.example"]`, and one Stub of it, `GET /x`,
/// that answers with the Mock's name.
fn mock_file(name : String, mock_fields : String) -> (String, String) {
  let fields = if mock_fields == "" { "" } else { ", \{mock_fields}" }
  (
    "\{name}.json",
    (
      $|{ "mocks": [{ "name": "\{name}"\{fields} }],
      $|  "stubs": [{ "id": "\{name}-x", "mock": "\{name}",
      $|    "request": { "method": "GET", "path": "/x" },
      $|    "response": { "status": 200, "body": "from \{name}" } }] }
    ),
  )
}

///|
/// Sends `GET target` with the header fields `headers` and renders which
/// Mock answered and the response.
fn answer(
  h : Harness,
  target : String,
  headers : Array[(String, String)],
) -> String {
  let outcome = h.send("GET", target, headers~)
  "\{@debug.to_string(outcome.resolution)}\n\{response(outcome)}"
}

///|
test "a request reaches the Mock whose Hosts include its Host" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\", \"users.internal\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  inspect(
    [
      answer(h, "/x", [("Host", "users.example.com")]),
      answer(h, "/x", [("Host", "users.internal")]),
      answer(h, "/x", [("Host", "orders.example.com")]),
    ].join("\n---\n"),
    content=(
      #|ByHost("users")
      #|200
      #|from users
      #|---
      #|ByHost("users")
      #|200
      #|from users
      #|---
      #|ByHost("orders")
      #|200
      #|from orders
    ),
  )
}

///|
test "Hosts are compared case-insensitively, without the port and without a trailing dot, on both sides" {
  let h = harness([
    mock_file(
      "users", "\"hosts\": [\"Users.Example.com:8080\", \"[::1]:9000\"]",
    ),
    mock_file(
      "orders", "\"hosts\": [\"orders.example.com.\", \"10.0.0.7\", \"fe80::1\"]",
    ),
  ])
  let hosts = [
    "users.example.com", "USERS.EXAMPLE.COM", "users.example.com:80", "users.example.com.",
    "Users.Example.Com.:8443", "[::1]", "[::1]:8080", "orders.example.com", "orders.example.com:443",
    "Orders.Example.Com.", "10.0.0.7:8080", "[FE80::1]:443", "fe80::1",
  ]
  inspect(
    hosts
    .map(host => {
      let outcome = h.send("GET", "/x", headers=[("Host", host)])
      "\{host} -> \{@debug.to_string(outcome.resolution)}"
    })
    .join("\n"),
    content=(
      #|users.example.com -> ByHost("users")
      #|USERS.EXAMPLE.COM -> ByHost("users")
      #|users.example.com:80 -> ByHost("users")
      #|users.example.com. -> ByHost("users")
      #|Users.Example.Com.:8443 -> ByHost("users")
      #|[::1] -> ByHost("users")
      #|[::1]:8080 -> ByHost("users")
      #|orders.example.com -> ByHost("orders")
      #|orders.example.com:443 -> ByHost("orders")
      #|Orders.Example.Com. -> ByHost("orders")
      #|10.0.0.7:8080 -> ByHost("orders")
      #|[FE80::1]:443 -> ByHost("orders")
      #|fe80::1 -> ByHost("orders")
    ),
  )
}

///|
test "Hosts are exact names: a parent domain, a subdomain or a near miss of a Host does not reach its Mock" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  let hosts = [
    "example.com", "api.users.example.com", "users.example.co", "users", "users.example.com..",
    "[users.example.com]",
  ]
  inspect(
    hosts
    .map(host => {
      let outcome = h.send("GET", "/x", headers=[("Host", host)])
      "\{host} -> \{@debug.to_string(outcome.resolution)}"
    })
    .join("\n"),
    content=(
      #|example.com -> NoMock
      #|api.users.example.com -> NoMock
      #|users.example.co -> NoMock
      #|users -> NoMock
      #|users.example.com.. -> NoMock
      #|[users.example.com] -> NoMock
    ),
  )
}

///|
test "the Mock marked default answers a request whose Host no Mock lists, and its responses say so in Smock-Mock" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"], \"default\": true"),
    mock_file(
      "orders", "\"hosts\": [\"orders.example.com\"], \"default\": false",
    ),
  ])
  inspect(
    [
      answer(h, "/x", [("Host", "unknown.example.com")]),
      // The no-match response of the Default Mock carries it too.
      answer(h, "/nothing-here", [("Host", "unknown.example.com")]),
      // A Host the Default Mock lists itself reaches it by its Host.
      answer(h, "/x", [("Host", "users.example.com")]),
      answer(h, "/nothing-here", [("Host", "users.example.com")]),
      answer(h, "/x", [("Host", "orders.example.com")]),
    ].join("\n---\n"),
    content=(
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
      #|---
      #|ViaDefault("users")
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: users-x; failed=path
      #|Smock-Mock: users; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|ByHost("users")
      #|200
      #|from users
      #|---
      #|ByHost("users")
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: users-x; failed=path
      #|{"error":"no Stub matched"}
      #|---
      #|ByHost("orders")
      #|200
      #|from orders
    ),
  )
}

///|
test "Smock-Mock follows the Stub's own headers" {
  let h = harness([
    (
      "users.json",
      (
        #|{ "mocks": [{ "name": "users" }],
        #|  "stubs": [{ "id": "a", "mock": "users",
        #|    "response": { "status": 201, "headers": { "Content-Type": "text/plain", "X-A": "1" },
        #|      "body": "a" } }] }
      ),
    ),
  ])
  inspect(
    answer(h, "/", [("Host", "localhost")]),
    content=(
      #|ViaDefault("users")
      #|201
      #|Content-Type: text/plain
      #|X-A: 1
      #|Smock-Mock: users; via=default
      #|a
    ),
  )
}

///|
test "a lone Mock is the Default Mock, so it answers on localhost without Hosts" {
  let lone = [
    mock_file("users", ""),
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    // Not marking it does not stop a lone Mock from being the Default Mock.
    mock_file("users", "\"default\": false"),
  ]
  inspect(
    lone
    .map(file => {
      let h = harness([file])
      answer(h, "/x", [("Host", "localhost:8080")])
    })
    .join("\n---\n"),
    content=(
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
      #|---
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
      #|---
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
    ),
  )
}

///|
test "without a Default Mock, a request whose Host no Mock lists gets 404 with the accepted Hosts" {
  let h = harness([
    mock_file(
      "users", "\"hosts\": [\"users.example.com\", \"Users.Internal:8080\"]",
    ),
    mock_file("orders", "\"hosts\": [\"orders.example.com.\", \"[::1]:8080\"]"),
    mock_file("payments", ""),
  ])
  inspect(
    describe(h.send("GET", "/x", headers=[("Host", "Usres.Example.com:8080")])),
    content=(
      #|plan:
      #|  status: 404
      #|  header: Content-Type: application/json
      #|  body: "{\"error\":\"no Mock for this Host\",\"host\":\"usres.example.com\",\"acceptedHosts\":[\"orders.example.com\",\"[::1]\",\"users.example.com\",\"users.internal\"]}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: Some("usres.example.com")
      #|  mock: None
      #|  via_default: false
      #|  request: GET /x HTTP/1.1
      #|  header: Host: Usres.Example.com:8080
      #|  body: ""
      #|  stub: None
      #|  status: Some(404)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
  inspect(
    @debug.to_string(
      h.send("GET", "/x", headers=[("Host", "nowhere")]).resolution,
    ),
    content="NoMock",
  )
}

///|
test "a request without a Host resolves like one whose Host no Mock lists" {
  let with_default = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"], \"default\": true"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  let without_default = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  // HTTP/1.0 requests may have no Host header; an empty one names no Host.
  inspect(
    [
      answer(with_default, "/x", []),
      answer(with_default, "/x", [("Host", "")]),
      answer(without_default, "/x", []),
      answer(without_default, "/x", [("Host", "")]),
    ].join("\n---\n"),
    content=(
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
      #|---
      #|ViaDefault("users")
      #|200
      #|Smock-Mock: users; via=default
      #|from users
      #|---
      #|NoMock
      #|404
      #|Content-Type: application/json
      #|{"error":"no Mock for this Host","host":null,"acceptedHosts":["orders.example.com","users.example.com"]}
      #|---
      #|NoMock
      #|404
      #|Content-Type: application/json
      #|{"error":"no Mock for this Host","host":null,"acceptedHosts":["orders.example.com","users.example.com"]}
    ),
  )
}

///|
test "when no Definition file declares a Mock, one empty Default Mock named default answers with its no-match response" {
  let sets = [
    [],
    [("empty.json", "{}")],
    [("stubs-only.json", "{ \"stubs\": [] }"), ("version.yaml", "version: 1\n")],
  ]
  inspect(
    sets
    .map(files => answer(harness(files), "/anything", [("Host", "localhost")]))
    .join("\n---\n"),
    content=(
      #|ViaDefault("default")
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: default; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|ViaDefault("default")
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: default; via=default
      #|{"error":"no Stub matched"}
      #|---
      #|ViaDefault("default")
      #|404
      #|Content-Type: application/json
      #|Smock-Mock: default; via=default
      #|{"error":"no Stub matched"}
    ),
  )
}

///|
test "the authority of an absolute-form target is the Host, and wins over the Host header" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  inspect(
    [
      answer(h, "http://orders.example.com/x", [("Host", "users.example.com")]),
      answer(h, "HTTPS://user:pw@Orders.Example.com.:8443/x?q=1", [
        ("Host", "users.example.com"),
      ]),
      answer(h, "http://orders.example.com:8080/x", []),
      answer(h, "http://unknown.example.com/x", [("Host", "users.example.com")]),
    ].join("\n---\n"),
    content=(
      #|ByHost("orders")
      #|200
      #|from orders
      #|---
      #|ByHost("orders")
      #|200
      #|from orders
      #|---
      #|ByHost("orders")
      #|200
      #|from orders
      #|---
      #|NoMock
      #|404
      #|Content-Type: application/json
      #|{"error":"no Mock for this Host","host":"unknown.example.com","acceptedHosts":["orders.example.com","users.example.com"]}
    ),
  )
}

///|
test "an absolute-form target is matched on its path, which is / when it has none" {
  let h = harness([
    (
      "users.json",
      (
        #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] }],
        #|  "stubs": [
        #|    { "id": "root", "mock": "users", "request": { "path": "/" },
        #|      "response": { "status": 200, "body": "root" } },
        #|    { "id": "user", "mock": "users", "request": { "path": "/users/1" },
        #|      "response": { "status": 200, "body": "user" } } ] }
      ),
    ),
  ])
  inspect(
    [
      "http://users.example.com/users/1", "http://users.example.com/users/1?x=1",
      "http://users.example.com", "http://users.example.com?x=1", "http://users.example.com/",
    ]
    .map(target => {
      let outcome = h.send("GET", target)
      "\{target} -> \{@debug.to_string(matched_id(outcome))}"
    })
    .join("\n"),
    content=(
      #|http://users.example.com/users/1 -> Some("user")
      #|http://users.example.com/users/1?x=1 -> Some("user")
      #|http://users.example.com -> Some("root")
      #|http://users.example.com?x=1 -> Some("root")
      #|http://users.example.com/ -> Some("root")
    ),
  )
}

///|
test "a Mock name that is not an HTTP token is percent-encoded in Smock-Mock, so the header stays one ASCII line" {
  let names = [
    "ユーザー API", "a; via=host", "a\r\nSet-Cookie: x=1", "50%", "v1.2_x-y~",
  ]
  inspect(
    names
    .map(name => {
      let file = "{ \"mocks\": [{ \"name\": \{name.escape()} }] }"
      let outcome = harness([("m.json", file)]).send("GET", "/")
      outcome.plan.headers
      .filter(h => h.0 == "Smock-Mock")
      .map(h => "\{h.0}: \{h.1}")
      .join("\n")
    })
    .join("\n"),
    content=(
      #|Smock-Mock: %E3%83%A6%E3%83%BC%E3%82%B6%E3%83%BC%20API; via=default
      #|Smock-Mock: a%3B%20via%3Dhost; via=default
      #|Smock-Mock: a%0D%0ASet-Cookie%3A%20x%3D1; via=default
      #|Smock-Mock: 50%25; via=default
      #|Smock-Mock: v1.2_x-y~; via=default
    ),
  )
}

///|
test "the Mock for a Host, as certificate selection by SNI asks for it: compared as Host resolution compares Hosts, never the Default Mock, and from the snapshot served" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"], \"default\": true"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  let names = [
    "users.example.com", "USERS.Example.COM.", "orders.example.com", "unknown.example.com",
    "",
  ]
  let lookup = () => {
    names
    .map(name => {
      "\{name.escape()} -> \{@debug.to_string(h.engine.mock_for_host(name))}"
    })
    .join("\n")
  }
  let before = lookup()
  let _ = h.reload([
    mock_file("users", "\"hosts\": [\"people.example.com\"]"),
    mock_file(
      "orders", "\"hosts\": [\"orders.example.com\", \"users.example.com\"]",
    ),
  ])
  let people = h.engine.mock_for_host("people.example.com")
  inspect(
    (
      $|\{before}
      $|after a reload:
      $|\{lookup()}
      $|"people.example.com" -> \{@debug.to_string(people)}
    ),
    content=(
      #|"users.example.com" -> Some("users")
      #|"USERS.Example.COM." -> Some("users")
      #|"orders.example.com" -> Some("orders")
      #|"unknown.example.com" -> None
      #|"" -> None
      #|after a reload:
      #|"users.example.com" -> Some("orders")
      #|"USERS.Example.COM." -> Some("orders")
      #|"orders.example.com" -> Some("orders")
      #|"unknown.example.com" -> None
      #|"" -> None
      #|"people.example.com" -> Some("users")
    ),
  )
}
