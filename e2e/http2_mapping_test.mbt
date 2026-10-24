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

///|
/// A Mock that answers every Host: `checked` wants an `x-checksum` field,
/// and `upload` takes any POST and echoes its body and its `x-checksum`.
let trailer_uploads : String =
  #|{ "mocks": [{ "name": "files" }],
  #|  "stubs": [
  #|    { "id": "checked", "mock": "files",
  #|      "request": { "method": "POST", "path": "/upload", "headers": { "X-Checksum": "abc" } },
  #|      "response": { "status": 200, "body": "a checksum" } },
  #|    { "id": "upload", "mock": "files",
  #|      "request": { "method": "POST", "path": "/upload" },
  #|      "response": { "status": 201, "template": true,
  #|        "body": "${bodyText} checksum=${header.x-checksum ?? 'none'}" } } ] }

///|
async test "h2c: request trailers are accepted and ignored, as HTTP/1.1 chunked trailers are: no condition, template or Journal entry sees them" {
  with_definitions([("files.json", trailer_uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for body in [b"hello", b""] {
        let stream = client.send(
          "POST",
          "/upload",
          authority="localhost",
          body?=if body.length() > 0 { Some(body) } else { None },
          end=false,
        )
        client.conn.headers(
          stream,
          [@header.Header::of("x-checksum", "abc")],
          end=true,
        )
        client.flush()
        out.push(client.response(stream).render())
      }
      let conn = smock.connect()
      defer conn.close()
      conn.write(
        "POST /upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n",
      )
      out.push(read_response(conn))
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
          #|201
          #|smock-mock: files; via=default
          #|date: <now>
          #|content-length: 19
          #|
          #|hello checksum=none
          #|---
          #|201
          #|smock-mock: files; via=default
          #|date: <now>
          #|content-length: 14
          #|
          #| checksum=none
          #|---
          #|HTTP/1.1 201 Created
          #|Smock-Mock: files; via=default
          #|Date: <now>
          #|Content-Length: 19
          #|
          #|hello checksum=none
          #|---
          #|host="localhost" mock="files" viaDefault=true "HTTP/2" "/upload" headers=[]
          #|---
          #|host="localhost" mock="files" viaDefault=true "HTTP/2" "/upload" headers=[]
          #|---
          #|host="localhost" mock="files" viaDefault=true "HTTP/1.1" "/upload" headers=[{"name":"Host","value":"localhost"},{"name":"Transfer-Encoding","value":"chunked"}]
        ),
      )
    })
  })
}

///|
async test "h2c: header conditions and header.NAME, written in any case, match the lower-case names HTTP/2 sends, and the Near miss names a failed one in lower case" {
  let defs =
    #|{ "mocks": [{ "name": "api", "hosts": ["localhost"] }],
    #|  "stubs": [{ "id": "keyed", "mock": "api",
    #|    "request": { "path": "/keyed",
    #|      "headers": { "X-Api-Key": "k1", "Accept": { "pattern": "text/.*" } } },
    #|    "response": { "status": 200, "template": true, "body": "key ${header.X-API-KEY}" } }] }
  with_definitions([("api.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for key in ["k1", "k2"] {
        let response = client.request("GET", "/keyed", authority="localhost", headers=[
          ("x-api-key", key),
          ("accept", "text/plain"),
        ])
        out.push(response.render())
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 6
          #|
          #|key k1
          #|---
          #|404
          #|content-type: application/json
          #|smock-near-miss: keyed; failed=header:x-api-key
          #|date: <now>
          #|content-length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
/// A Mock `shop`, the only one, so it answers every Host: a CRUD Stub on
/// the keyed bucket `items`, the Scenario `cart`, which `POST /cart` moves
/// from `Started` to `Filled`, and the Variable `user`, which `POST /login`
/// stores and `GET /me` reads.
let session_shop : String =
  #|mocks:
  #|  - name: shop
  #|data:
  #|  - { mock: shop, name: items, key: id, json: [{ id: 1, name: pen }] }
  #|stubs:
  #|  - id: items
  #|    mock: shop
  #|    crud: { bucket: items, path: /items }
  #|  - id: cart-empty
  #|    mock: shop
  #|    request: { method: GET, path: /cart }
  #|    scenario: { name: cart, requires: Started }
  #|    response: { status: 200, body: empty }
  #|  - id: fill-cart
  #|    mock: shop
  #|    request: { method: POST, path: /cart }
  #|    scenario: { name: cart, requires: Started, moveTo: Filled }
  #|    response: { status: 200, body: filled }
  #|  - id: cart-full
  #|    mock: shop
  #|    request: { method: GET, path: /cart }
  #|    scenario: { name: cart, requires: Filled }
  #|    response: { status: 200, body: full }
  #|  - id: login
  #|    mock: shop
  #|    request: { method: POST, path: /login }
  #|    variables:
  #|      user: ${body.user}
  #|    response: { status: 200, template: true, body: "hello ${vars.user}" }
  #|  - id: whoami
  #|    mock: shop
  #|    request: { method: GET, path: /me }
  #|    response: { status: 200, template: true, body: "me: ${vars.user ?? 'nobody'}" }

///|
async test "h2c: each stream's Session comes from its own baggage, so Ephemeral Stubs, Scenarios, Variables and CRUD Stubs keep the Sessions that share one connection apart" {
  with_definitions([("shop.yaml", session_shop)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let added = smock.call(
        "POST",
        "/v1/mocks/shop/stubs",
        session="test-a",
        body=ephemeral_user(503, "down"),
      )
      let out = ["test-a adds an Ephemeral Stub: \{added}"]
      let client = smock.h2c()
      defer client.close()
      let json = ("content-type", "application/json")
      for
        round in [
          [("GET", "/users/1", "")],
          [("POST", "/cart", ""), ("GET", "/cart", "")],
          [("POST", "/login", "{\"user\":\"ann\"}"), ("GET", "/me", "")],
          [("POST", "/items", "{\"name\":\"ink\"}"), ("GET", "/items", "")],
        ] {
        // test-a's requests come first; then test-b and a request without
        // a Session send the round's last request, on streams opened before
        // any of them is answered.
        let streams = []
        for request in round {
          let (meth, path, body) = request
          let headers = if body == "" { [] } else { [json] }
          let stream = client.send(
            meth,
            path,
            authority="localhost",
            headers=[baggage("test-a"), ..headers],
            body?=if body == "" { None } else { Some(@utf8.encode(body)) },
          )
          streams.push(("test-a \{meth} \{path}", stream))
        }
        let (meth, path, _) = round[round.length() - 1]
        for session in [Some("test-b"), None] {
          let stream = client.send(
            meth,
            path,
            authority="localhost",
            headers=session_headers(session),
          )
          streams.push(
            ("\{session.unwrap_or("no Session")} \{meth} \{path}", stream),
          )
        }
        for sent in streams {
          let (label, stream) = sent
          let response = client.response(stream)
          out.push(
            "\{label}: \{response.status} \{@utf8.decode(response.body)}",
          )
        }
      }
      inspect(
        out.join("\n"),
        content=(
          #|test-a adds an Ephemeral Stub: 201 {"stub":{"id":"eph-1","mock":"shop","session":"test-a","request":{"method":"GET","path":"/users/1"},"response":{"status":503,"body":"down"}},"warnings":[]}
          #|test-a GET /users/1: 503 down
          #|test-b GET /users/1: 404 {"error":"no Stub matched"}
          #|no Session GET /users/1: 404 {"error":"no Stub matched"}
          #|test-a POST /cart: 200 filled
          #|test-a GET /cart: 200 full
          #|test-b GET /cart: 200 empty
          #|no Session GET /cart: 200 empty
          #|test-a POST /login: 200 hello ann
          #|test-a GET /me: 200 me: ann
          #|test-b GET /me: 200 me: nobody
          #|no Session GET /me: 200 me: nobody
          #|test-a POST /items: 201 {"name":"ink","id":2}
          #|test-a GET /items: 200 [{"id":1,"name":"pen"},{"name":"ink","id":2}]
          #|test-b GET /items: 200 [{"id":1,"name":"pen"}]
          #|no Session GET /items: 200 [{"id":1,"name":"pen"}]
        ),
      )
    })
  })
}

///|
async test "h2c: Journal queries, verification and the unmatched requests count a Session's HTTP/2 requests like its HTTP/1.1 ones" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let session = baggage("h2-counted")
      for
        request in [
          ("GET", "/users/1", "users.example.com"),
          ("GET", "/users/2", "localhost"),
          ("POST", "/users/1", "users.example.com"),
          ("GET", "/users/x", "nowhere.example.com"),
        ] {
        let (meth, path, host) = request
        let _ = client.request(meth, path, authority=host, headers=[session])
      }
      // The same Session over HTTP/1.1, and another Session over HTTP/2.
      smock.get_user("/users/1", "h2-counted")
      let _ = client.request("GET", "/users/1", authority="localhost", headers=[
        baggage("other"),
      ])
      let out = []
      let verdict = smock.call(
        "POST",
        "/v1/journal/verify",
        session="h2-counted",
        body="{\"filter\":{\"method\":\"GET\",\"path\":\"/users/1\"},\"exactly\":2}",
      )
      out.push("verify GET /users/1 exactly 2: \{verdict}")
      let count = smock.journal_count(
        "h2-counted", "{\"filter\":{\"method\":\"GET\"}}",
      )
      out.push("query GET: \{count} entries")
      let (status, page) = smock.unmatched("h2-counted")
      guard page is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{page.stringify()}")
      }
      out.push("unmatched: \{status}")
      for entry in entries {
        guard entry
          is Object(
            {
              "request": Object(
                { "method": meth, "target": target, "version": version, .. }
              ),
              "host": host,
              "mock": mock,
              "nearMiss": near_miss,
              ..
            }
          ) else {
          fail("not an entry: \{entry.stringify()}")
        }
        let near_miss = match near_miss {
          Object({ "stub": stub, "failed": failed, .. }) =>
            "\{stub.stringify()} failed \{failed.stringify()}"
          other => other.stringify()
        }
        out.push(
          "\{meth.stringify()} \{target.stringify()} \{version.stringify()} host=\{host.stringify()} mock=\{mock.stringify()} nearMiss=\{near_miss}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|verify GET /users/1 exactly 2: 200 {"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
          #|query GET: 4 entries
          #|unmatched: 200
          #|"POST" "/users/1" "HTTP/2" host="users.example.com" mock="users" nearMiss="get-user" failed [{"condition":"method","expected":"GET","actual":["POST"]}]
          #|"GET" "/users/x" "HTTP/2" host="nowhere.example.com" mock=null nearMiss=null

        ),
      )
    })
  })
}
