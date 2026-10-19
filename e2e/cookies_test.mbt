// Seam 2 tests of cookie conditions: a running smock reads the cookies of
// every Cookie line of a request, and names a failed cookie in the
// Smock-Near-Miss header and in the Journal's Near miss. Every Admin API
// response is checked against the OpenAPI document (contract_test.mbt).

///|
async test "over HTTP, cookies from two Cookie lines decide which Stub answers, and a failed cookie is named in the Near miss" {
  let defs =
    #|{ "mocks": [{ "name": "shop", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "cart", "mock": "shop",
    #|      "request": { "path": "/cart",
    #|        "cookies": { "session": { "pattern": "sess_.*" }, "debug": { "$not": "1" } } },
    #|      "response": { "status": 200, "body": "cart" } } ] }
  with_definitions([("shop.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("cookies")
      let host = ("Host", "localhost")
      inspect(
        [
          smock.request("GET", "/cart", headers=[
            host,
            session,
            ("Cookie", "theme=dark; session=sess_1"),
            ("Cookie", "debug=0"),
          ]),
          smock.request("GET", "/cart", headers=[
            host,
            session,
            ("Cookie", "session=sess_1"),
            ("Cookie", "debug=1"),
          ]),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 4
          #|
          #|cart
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: cart; failed=cookie:debug
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let unmatched = smock.admin(
        "GET",
        "/v1/journal/unmatched",
        headers=session_headers(Some("cookies")),
      )
      inspect(unmatched.status, content="200")
      guard unmatched.json()
        is Object({ "entries": [Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not one entry with a Near miss: \{unmatched.body}")
      }
      json_inspect(near_miss, content={
        "stub": "cart",
        "stubSource": "file",
        "failed": [
          {
            "condition": "cookie:debug",
            "expected": { "$not": "1" },
            "actual": ["1"],
          },
        ],
      })
    })
  })
}
