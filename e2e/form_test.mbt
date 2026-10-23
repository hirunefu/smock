// Seam 2 tests of form conditions: a running smock matches the fields of a
// form POST, names the failed ones in the Smock-Near-Miss header, and shows
// them in the Journal's Near miss. Every Admin API response is checked
// against the OpenAPI document (contract_test.mbt).

///|
async test "over HTTP, a form POST matches a Stub by its fields; one that fails gets the failed fields in Smock-Near-Miss, and the Journal shows them" {
  let defs =
    #|{ "mocks": [{ "name": "users", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "login", "mock": "users",
    #|      "request": { "method": "POST", "path": "/login",
    #|        "body": { "form": { "user name": "alice", "remember": { "$not": "1" } } } },
    #|      "response": { "status": 204 } } ] }
  with_definitions([("users.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("form")
      let host = ("Host", "localhost")
      let form = ("Content-Type", "application/x-www-form-urlencoded")
      inspect(
        [
          smock.request(
            "POST",
            "/login",
            headers=[host, session, form],
            body="remember=0&user+name=alice",
          ),
          smock.request(
            "POST",
            "/login",
            headers=[host, session, form],
            body="user%20name=bob&remember=1",
          ),
          smock.request(
            "POST",
            "/login",
            headers=[host, session, ("Content-Type", "application/json")],
            body="user+name=alice",
          ),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 204 No Content
          #|Date: <now>
          #|
          #|
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: login; failed=form:user%20name,form:remember
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: login; failed=form:user%20name,form:remember
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let unmatched = smock.admin(
        "GET",
        "/v1/journal/unmatched",
        headers=session_headers(Some("form")),
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
          "stub": "login",
          "stubSource": "file",
          "failed": [
            {
              "condition": "form:user name",
              "expected": "alice",
              "actual": ["bob"],
            },
            {
              "condition": "form:remember",
              "expected": { "$not": "1" },
              "actual": ["1"],
            },
          ],
        },
        {
          "stub": "login",
          "stubSource": "file",
          "failed": [
            { "condition": "form:user name", "expected": "alice", "actual": [] },
            {
              "condition": "form:remember",
              "expected": { "$not": "1" },
              "actual": [],
            },
          ],
        },
      ])
    })
  })
}
