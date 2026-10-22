// Seam 2 tests of pattern conditions: Stubs with patterns answer on the
// wire, and a pattern that does not compile keeps a definition set from
// loading in both smock check and smock serve.

///|
/// A Definition file whose Stub matches the path by a pattern.
let pattern_users : String =
  #|{ "mocks": [{ "name": "users" }],
  #|  "stubs": [{ "id": "get-user", "mock": "users",
  #|    "request": { "method": "GET", "path": { "pattern": "/users/[0-9]+" } },
  #|    "response": { "status": 200, "body": "a user" } }] }

///|
/// A Definition file in YAML with two patterns that do not compile: one is
/// not valid RE2 syntax, the other uses syntax outside smock's RE2 subset.
let bad_patterns : String =
  #|mocks: [{ name: orders }]
  #|stubs:
  #|  - id: get-order
  #|    mock: orders
  #|    request:
  #|      path: { pattern: "/orders/([0-9]+" }
  #|      headers:
  #|        X-Region: { pattern: '\p{Greek}+' }
  #|    response: { status: 200 }

///|
async test "smock serve answers a request whose path matches a Stub's pattern as a whole" {
  with_definitions([("users.json", pattern_users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let status = (response : String) => {
        response[:response.find("\n").unwrap_or(0)].to_owned()
      }
      inspect(
        [
          status(smock.get("/users/42")),
          status(smock.get("/users/42/orders")),
          status(smock.get("/users/me")),
        ].join("\n"),
        content=(
          #|200 OK
          #|404 Not Found
          #|404 Not Found
        ),
      )
    })
  })
}

///|
async test "smock check reports a pattern that does not compile on one line, with the file, the JSON Pointer of the pattern, the error and its position, and exits 1" {
  with_definitions(
    [("10-users.json", pattern_users), ("20-orders.yaml", bad_patterns)],
    dir => {
      inspect(
        check([dir]),
        content=(
          #|status 1
          #|20-orders.yaml: /stubs/0/request/path/pattern: is not a valid pattern: position 8: missing closing )
          #|20-orders.yaml: /stubs/0/request/headers/X-Region/pattern: is not a valid pattern: position 0: Unicode class \p{Greek} is not supported in smock's RE2 subset
          #|
        ),
      )
    },
  )
}

///|
async test "smock serve exits with status 1 at startup when a pattern does not compile, logging the same errors" {
  with_definitions(
    [("10-users.json", pattern_users), ("20-orders.yaml", bad_patterns)],
    dir => {
      let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
      inspect(
        "status \{stopped.status}\n" + log_entries(stopped.logs),
        content=(
          #|status 1
          #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
          #|{"level":"info","msg":"random seed","seed":"*"}
          #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
          #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
          #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
          #|{"level":"error","msg":"invalid definitions","file":"20-orders.yaml","pointer":"/stubs/0/request/path/pattern","error":"is not a valid pattern: position 8: missing closing )"}
          #|{"level":"error","msg":"invalid definitions","file":"20-orders.yaml","pointer":"/stubs/0/request/headers/X-Region/pattern","error":"is not a valid pattern: position 0: Unicode class \\p{Greek} is not supported in smock's RE2 subset"}
        ),
      )
    },
  )
}

///|
/// The Stub of issue #45, in YAML: a pattern on a member of a JSON body.
let json_pattern_users : String =
  #|mocks:
  #|  - name: users
  #|stubs:
  #|  - id: create-user
  #|    mock: users
  #|    request:
  #|      method: POST
  #|      path: /users
  #|      body: { json: { email: { pattern: ".*@example\\.com" } } }
  #|    response: { status: 201 }

///|
async test "smock serve matches a pattern on a member of a JSON body, and a body that holds the pattern object itself gets a Near miss on body" {
  with_definitions([("users.yaml", json_pattern_users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        [
          smock.send("POST", "/users", body="{\"email\": \"a@example.com\"}"),
          smock.send(
            "POST",
            "/users",
            body="{\"email\": {\"pattern\": \".*@example\\\\.com\"}}",
          ),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 201 Created
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Content-Length: 0
          #|
          #|
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: create-user; failed=body
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "smock check reports a pattern inside a json condition that does not compile at the JSON Pointer of its pattern field, and exits 1" {
  let bad =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [{ "id": "create-user", "mock": "users",
    #|    "request": { "body": { "json": { "emails": [{ "pattern": "[a-z+@example\\.com" }] } } },
    #|    "response": { "status": 201 } }] }
  with_definitions([("users.json", bad)], dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|users.json: /stubs/0/request/body/json/emails/0/pattern: is not a valid pattern: position 0: missing closing ]
        #|
      ),
    )
  })
}
