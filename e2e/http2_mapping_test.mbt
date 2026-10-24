// Seam 2 tests of the mapping from an HTTP/2 stream onto the engine's
// request, over h2c on the plain port: the Host from `:authority` or the
// `host` field, the target, the header fields and joined cookies, request
// trailers, and the Mocks, Sessions and state of streams that share one
// connection. Every Admin API response is checked against the OpenAPI
// document (contract_test.mbt).

///|
/// A Mock on `localhost` whose Stubs read cookies: `line` wants the one
/// Cookie line an HTTP/1.1 client would send, and `cart` wants a `session`
/// cookie and no `debug` cookie of `1`. Each echoes what it read.
let cookie_shop : String =
  #|{ "mocks": [{ "name": "shop", "hosts": ["localhost"] }],
  #|  "stubs": [
  #|    { "id": "line", "mock": "shop",
  #|      "request": { "path": "/line", "headers": { "Cookie": "theme=dark; session=sess_1" } },
  #|      "response": { "status": 200, "template": true, "body": "line: ${header.cookie}" } },
  #|    { "id": "cart", "mock": "shop",
  #|      "request": { "path": "/cart",
  #|        "cookies": { "session": { "pattern": "sess_.*" }, "debug": { "$not": "1" } } },
  #|      "response": { "status": 200, "template": true, "body": "cart: ${cookie.session}" } } ] }

///|
async test "h2c: cookie fields are joined into one with ; at the place of the first, so header and cookie conditions, templates and the Journal see what one Cookie line gives" {
  with_definitions([("shop.json", cookie_shop)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let session = baggage("h2-cookies")
      let out = []
      for
        request in [
          (
            "/line",
            [
              ("cookie", "theme=dark"),
              ("accept", "text/plain"),
              ("cookie", "session=sess_1"),
            ],
          ),
          (
            "/cart",
            [("cookie", "theme=dark; session=sess_1"), ("cookie", "debug=0")],
          ),
          ("/cart", [("cookie", "session=sess_1"), ("cookie", "debug=1")]),
        ] {
        let (path, headers) = request
        let response = client.request(
          "GET",
          path,
          authority="localhost",
          headers=[session, ..headers],
        )
        out.push(response.render())
      }
      let (_, journal) = smock.journal(session="h2-cookies")
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      for entry in entries {
        guard entry
          is Object({ "request": Object({ "headers": headers, .. }), .. }) else {
          fail("no headers: \{entry.stringify()}")
        }
        out.push("Journal: \{headers.stringify()}")
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 32
          #|
          #|line: theme=dark; session=sess_1
          #|---
          #|200
          #|date: <now>
          #|content-length: 12
          #|
          #|cart: sess_1
          #|---
          #|404
          #|content-type: application/json
          #|smock-near-miss: cart; failed=cookie:debug
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|Journal: [{"name":"baggage","value":"userId=alice,smock-session=h2-cookies;ttl=60"},{"name":"cookie","value":"theme=dark; session=sess_1"},{"name":"accept","value":"text/plain"}]
          #|---
          #|Journal: [{"name":"baggage","value":"userId=alice,smock-session=h2-cookies;ttl=60"},{"name":"cookie","value":"theme=dark; session=sess_1; debug=0"}]
          #|---
          #|Journal: [{"name":"baggage","value":"userId=alice,smock-session=h2-cookies;ttl=60"},{"name":"cookie","value":"session=sess_1; debug=1"}]
        ),
      )
    })
  })
}

///|
/// Two Mocks with Hosts, `users`, the Default Mock, and `orders`. Each has
/// a Stub for `PATCH /orders/7?x=1` that echoes the method, the path, the
/// query and the `host` field, if any. `orders` also has a Stub that wants
/// a `host` field, and `users` one for `OPTIONS *` that echoes its path.
let echo_hosts : String =
  #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"], "default": true },
  #|            { "name": "orders", "hosts": ["orders.example.com"] }],
  #|  "stubs": [
  #|    { "id": "orders-echo", "mock": "orders",
  #|      "request": { "method": "PATCH", "path": "/orders/7", "query": { "x": "1" } },
  #|      "response": { "status": 200, "template": true,
  #|        "body": "orders: ${method} ${path} x=${query.x} host=${header.host ?? 'none'}" } },
  #|    { "id": "users-echo", "mock": "users",
  #|      "request": { "method": "PATCH", "path": "/orders/7", "query": { "x": "1" } },
  #|      "response": { "status": 200, "template": true,
  #|        "body": "users: ${method} ${path} x=${query.x} host=${header.host ?? 'none'}" } },
  #|    { "id": "host-field", "mock": "orders",
  #|      "request": { "path": "/host", "headers": { "Host": "orders.example.com" } },
  #|      "response": { "status": 200, "body": "a host field" } },
  #|    { "id": "options", "mock": "users",
  #|      "request": { "method": "OPTIONS", "path": { "pattern": "\\*" } },
  #|      "response": { "status": 200, "template": true, "body": "options: ${path}" } } ] }

///|
/// A Journal entry as these tests show it: its Host, its Mock, whether the
/// Default Mock answered, its version, its target and its header fields.
fn mapped(entry : Json) -> String {
  guard entry
    is Object(
      {
        "host": host,
        "mock": mock,
        "viaDefault": via_default,
        "request": Object(
          { "target": target, "version": version, "headers": headers, .. }
        ),
        ..
      }
    ) else {
    return entry.stringify()
  }
  "host=\{host.stringify()} mock=\{mock.stringify()} viaDefault=\{via_default.stringify()} \{version.stringify()} \{target.stringify()} headers=\{headers.stringify()}"
}

///|
async test "h2c: :method and :path reach the Stubs as over HTTP/1.1, the Host comes from :authority, else the host field, a request with neither goes to the Default Mock, and header.host and host conditions see only a host field the client sent" {
  with_definitions([("mocks.json", echo_hosts)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let orders = "orders.example.com"
      let out = []
      for
        request in [
          ("/orders/7?x=1", Some(orders), []),
          ("/orders/7?x=1", None, [("host", orders)]),
          ("/orders/7?x=1", Some(orders), [("host", "ORDERS.example.com:8080")]),
          ("/orders/7?x=1", None, []),
          ("/host", Some(orders), []),
          ("/host", None, [("host", orders)]),
        ] {
        let (path, authority, headers) = request
        let meth = if path == "/host" { "GET" } else { "PATCH" }
        let response = client.request(meth, path, authority?, headers~)
        out.push(response.render())
      }
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      for entry in entries {
        out.push(mapped(entry))
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 37
          #|
          #|orders: PATCH /orders/7 x=1 host=none
          #|---
          #|200
          #|date: <now>
          #|content-length: 51
          #|
          #|orders: PATCH /orders/7 x=1 host=orders.example.com
          #|---
          #|200
          #|date: <now>
          #|content-length: 56
          #|
          #|orders: PATCH /orders/7 x=1 host=ORDERS.example.com:8080
          #|---
          #|200
          #|smock-mock: users; via=default
          #|date: <now>
          #|content-length: 36
          #|
          #|users: PATCH /orders/7 x=1 host=none
          #|---
          #|404
          #|content-type: application/json
          #|smock-near-miss: host-field; failed=header:host
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|200
          #|date: <now>
          #|content-length: 12
          #|
          #|a host field
          #|---
          #|host="orders.example.com" mock="orders" viaDefault=false "HTTP/2" "/orders/7?x=1" headers=[]
          #|---
          #|host="orders.example.com" mock="orders" viaDefault=false "HTTP/2" "/orders/7?x=1" headers=[{"name":"host","value":"orders.example.com"}]
          #|---
          #|host="orders.example.com" mock="orders" viaDefault=false "HTTP/2" "/orders/7?x=1" headers=[{"name":"host","value":"ORDERS.example.com:8080"}]
          #|---
          #|host=null mock="users" viaDefault=true "HTTP/2" "/orders/7?x=1" headers=[]
          #|---
          #|host="orders.example.com" mock="orders" viaDefault=false "HTTP/2" "/host" headers=[]
          #|---
          #|host="orders.example.com" mock="orders" viaDefault=false "HTTP/2" "/host" headers=[{"name":"host","value":"orders.example.com"}]
        ),
      )
    })
  })
}

///|
async test "h2c: OPTIONS * is the asterisk form and reaches the Stub an HTTP/1.1 OPTIONS * reaches" {
  with_definitions([("mocks.json", echo_hosts)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let h2 = client.request("OPTIONS", "*", authority="users.example.com")
      let http1 = smock.request("OPTIONS", "*", headers=[
        ("Host", "users.example.com"),
      ])
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      inspect(
        [h2.render(), http1, ..entries.map(mapped)].join("\n---\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 10
          #|
          #|options: *
          #|---
          #|HTTP/1.1 200 OK
          #|Date: <now>
          #|Content-Length: 10
          #|
          #|options: *
          #|---
          #|host="users.example.com" mock="users" viaDefault=false "HTTP/2" "*" headers=[]
          #|---
          #|host="users.example.com" mock="users" viaDefault=false "HTTP/1.1" "*" headers=[{"name":"Host","value":"users.example.com"},{"name":"Content-Length","value":"0"}]
        ),
      )
    })
  })
}

///|
async test "h2c: streams of one connection, all sent before the first is answered, reach the Mocks their own :authority names, the Default Mock included" {
  with_definitions(two_mocks(default=true), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let streams = []
      for
        authority in [
          Some("orders.example.com"),
          Some("users.example.com"),
          Some("elsewhere.example.com"),
          Some("ORDERS.example.com.:443"),
          None,
        ] {
        let stream = client.send("GET", "/x", authority?)
        streams.push((authority.unwrap_or("(none)"), stream))
      }
      let out = []
      for sent in streams {
        let (authority, stream) = sent
        let response = client.response(stream)
        let mock = response.headers
          .filter(header => header.0 == "smock-mock")
          .map(header => " [\{header.1}]")
          .join("")
        out.push(
          "\{authority}: \{response.status} \{@utf8.decode(response.body)}\{mock}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|orders.example.com: 200 from orders
          #|users.example.com: 200 from users
          #|elsewhere.example.com: 200 from users [users; via=default]
          #|ORDERS.example.com.:443: 200 from orders
          #|(none): 200 from users [users; via=default]
        ),
      )
    })
  })
}
