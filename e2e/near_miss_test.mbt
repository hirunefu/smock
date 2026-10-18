// Seam 2 tests of the Near miss: an unmatched request gets the closest Stub
// and the conditions it failed in the Smock-Near-Miss header.

///|
async test "an unmatched request gets the Smock-Near-Miss header over HTTP, and a matched one does not" {
  let defs =
    #|{ "mocks": [{ "name": "users", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "get-user", "mock": "users",
    #|      "request": { "method": "GET", "path": "/users/1",
    #|        "headers": { "X-Api-Key": "secret" } },
    #|      "response": { "status": 200, "body": "a user" } },
    #|    { "id": "create-user", "mock": "users",
    #|      "request": { "method": "POST", "path": "/users",
    #|        "query": { "dry": "yes" }, "body": { "json": { "name": "Zoë" } } },
    #|      "response": { "status": 201 } } ] }
  with_definitions([("users.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        [
          smock.send("GET", "/users/1", headers=[("X-Api-Key", "secret")]),
          smock.send("POST", "/users/1", headers=[("X-Api-Key", "wrong")]),
          smock.send("POST", "/users?dry=no", body="{\"name\": \"Zoe\"}"),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 6
          #|
          #|a user
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: get-user; failed=method,header:x-api-key
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: create-user; failed=query:dry,body
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "over HTTP, a second payment that only the Scenario state stops gets Smock-Near-Miss naming the Scenario, percent-encoded; the Scenario adds no header" {
  let defs =
    #|{ "mocks": [{ "name": "payments", "hosts": ["localhost"] }],
    #|  "stubs": [
    #|    { "id": "pay", "mock": "payments",
    #|      "request": { "method": "POST", "path": "/orders/42/pay" },
    #|      "scenario": { "name": "check out", "requires": "Started", "moveTo": "Paid" },
    #|      "response": { "status": 200, "body": "paid" } } ] }
  with_definitions([("payments.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        [
          smock.send("POST", "/orders/42/pay"),
          smock.send("POST", "/orders/42/pay"),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 4
          #|
          #|paid
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: pay; failed=scenario:check%20out
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}
