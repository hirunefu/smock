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
