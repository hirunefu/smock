// Seam 2 tests of the operators in query and header values: a running smock
// matches with them, and the Admin API shows them in the Near miss and takes
// them in Journal filters. Every Admin API response is checked against the
// OpenAPI document (contract_test.mbt).

///|
async test "over HTTP, $not and $exists decide which requests a Stub answers; the Journal shows them in the Near miss, and a Journal filter takes them" {
  let defs =
    #|{ "mocks": [{ "name": "users", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "no-bearer", "mock": "users",
    #|      "request": { "path": "/a",
    #|        "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } } },
    #|        "query": { "debug": { "$exists": false } } },
    #|      "response": { "status": 401, "body": "no token" } } ] }
  with_definitions([("users.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("operators")
      let host = ("Host", "localhost")
      inspect(
        [
          smock.request("GET", "/a", headers=[host, session]),
          smock.request("GET", "/a", headers=[
            host,
            session,
            ("Authorization", "Bearer x"),
          ]),
          smock.request("GET", "/a?debug", headers=[host, session]),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 401 Unauthorized
          #|Date: <now>
          #|Content-Length: 8
          #|
          #|no token
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: no-bearer; failed=header:authorization
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: no-bearer; failed=query:debug
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let unmatched = smock.admin(
        "GET",
        "/v1/journal/unmatched",
        headers=session_headers(Some("operators")),
      )
      inspect(unmatched.status, content="200")
      guard unmatched.json() is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{unmatched.body}")
      }
      let near_misses = entries.map(entry => {
        guard entry is Object({ "nearMiss": near_miss, .. }) else {
          return Json::null()
        }
        near_miss
      })
      json_inspect(near_misses, content=[
        {
          "stub": "no-bearer",
          "stubSource": "file",
          "failed": [
            {
              "condition": "header:authorization",
              "expected": { "$not": { "pattern": "Bearer .*" } },
              "actual": ["Bearer x"],
            },
          ],
        },
        {
          "stub": "no-bearer",
          "stubSource": "file",
          "failed": [
            {
              "condition": "query:debug",
              "expected": { "$exists": false },
              "actual": [""],
            },
          ],
        },
      ])
      let counts = []
      for
        headers in [
          "{ \"Authorization\": { \"$exists\": true } }", "{ \"Authorization\": { \"$not\": { \"pattern\": \"Bearer .*\" } } }",
        ] {
        let query = "{ \"filter\": { \"headers\": \{headers} } }"
        counts.push("\{headers} -> \{smock.journal_count("operators", query)}")
      }
      inspect(
        counts.join("\n"),
        content=(
          #|{ "Authorization": { "$exists": true } } -> 1
          #|{ "Authorization": { "$not": { "pattern": "Bearer .*" } } } -> 2
        ),
      )
    })
  })
}
