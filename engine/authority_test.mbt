// The authority input of `Engine::handle`, which HTTP/2 gives from its
// `:authority`: when given, it is the request's Host, ahead of the target
// and of the `host` field, and it adds no header field.

///|
/// Two Mocks with Hosts, `users` and `orders`, and a Default Mock,
/// `fallback`. The Stub of `orders` matches only a request whose `host`
/// field names it.
let authority_mocks : Array[(String, String)] = [
  mock_file("users", "\"hosts\": [\"users.example.com\"]"),
  (
    "orders.json",
    (
      #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"] }],
      #|  "stubs": [{ "id": "by-host-field", "mock": "orders",
      #|    "request": { "method": "GET", "path": "/x",
      #|                 "headers": { "host": "orders.example.com" } },
      #|    "response": { "status": 200, "body": "from orders" } }] }
    ),
  ),
  mock_file("fallback", "\"default\": true"),
]

///|
/// Sends `GET target` over HTTP/2, with a `host` field when `host` is
/// given and the authority `authority` when it is, and returns the engine's
/// outcome.
fn Harness::send_http2(
  self : Harness,
  target : String,
  host? : String,
  authority? : String,
) -> @engine.Outcome {
  let headers = match host {
    Some(host) => [("host", host)]
    None => []
  }
  self.engine.handle(
    { meth: "GET", target, version: "HTTP/2", headers, body: b"", },
    authority?,
    session=None,
    now=self.now,
    rand=self.rand,
  )
}

///|
/// The Mock that answered each request of `requests`, given as (authority,
/// target, `host` field), one per line.
fn Harness::resolutions(
  self : Harness,
  requests : Array[(String?, String, String?)],
) -> String {
  requests
  .map(request => {
    let (authority, target, host) = request
    let outcome = self.send_http2(target, host?, authority?)
    let shown = [
      "authority=\{authority.unwrap_or("-")}",
      target,
      "host=\{host.unwrap_or("-")}",
    ]
    "\{shown.join(" ")} -> \{@debug.to_string(outcome.resolution)}"
  })
  .join("\n")
}

///|
test "an authority is the request's Host, ahead of an absolute-form target and of the host field" {
  let h = harness(authority_mocks)
  inspect(
    h.resolutions([
      (Some("orders.example.com"), "/x", None),
      (Some("orders.example.com"), "/x", Some("users.example.com")),
      (
        Some("orders.example.com"),
        "http://users.example.com/x",
        Some("users.example.com"),
      ),
      // Normalised as a Host field is.
      (Some("Orders.Example.com.:8443"), "/x", None),
      (Some("unknown.example.com"), "/x", Some("users.example.com")),
      // An empty authority names no Host, as an empty Host field does.
      (Some(""), "/x", Some("users.example.com")),
    ]),
    content=(
      #|authority=orders.example.com /x host=- -> ByHost("orders")
      #|authority=orders.example.com /x host=users.example.com -> ByHost("orders")
      #|authority=orders.example.com http://users.example.com/x host=users.example.com -> ByHost("orders")
      #|authority=Orders.Example.com.:8443 /x host=- -> ByHost("orders")
      #|authority=unknown.example.com /x host=users.example.com -> ViaDefault("fallback")
      #|authority= /x host=users.example.com -> ViaDefault("fallback")
    ),
  )
}

///|
test "without an authority, an absolute-form target and then the host field give the Host, as before" {
  let h = harness(authority_mocks)
  inspect(
    h.resolutions([
      (None, "/x", Some("orders.example.com")),
      (None, "http://orders.example.com/x", Some("users.example.com")),
      (None, "/x", None),
      (None, "/x", Some("unknown.example.com")),
    ]),
    content=(
      #|authority=- /x host=orders.example.com -> ByHost("orders")
      #|authority=- http://orders.example.com/x host=users.example.com -> ByHost("orders")
      #|authority=- /x host=- -> ViaDefault("fallback")
      #|authority=- /x host=unknown.example.com -> ViaDefault("fallback")
    ),
  )
}

///|
test "an authority adds no host field: header conditions see only a host field the client sent" {
  let h = harness(authority_mocks)
  inspect(
    [
      response(h.send_http2("/x", authority="orders.example.com")),
      response(
        h.send_http2(
          "/x",
          host="orders.example.com",
          authority="orders.example.com",
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: by-host-field; failed=header:host
      #|{"error":"no Stub matched"}
      #|---
      #|200
      #|from orders
    ),
  )
}
