///|
/// Sends `meth target` with `headers` and `body` on a new connection, and
/// renders the response with `read_response`.
async fn Smock::send(
  self : Smock,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> String {
  let conn = self.connect()
  defer conn.close()
  conn.write(raw_request(meth, target, host="localhost", headers~, body~))
  read_response(conn)
}

///|
/// A Mock whose unmatched requests get 501, with Stubs that answer from a
/// body file, match on the query, a header and a JSON body, or win by
/// priority.
let teapot : String =
  #|{ "mocks": [{ "name": "teapot", "noMatch": { "status": 501 } }],
  #|  "stubs": [
  #|    { "id": "get-user", "mock": "teapot", "priority": 10,
  #|      "request": { "method": "GET", "path": "/users/1" },
  #|      "response": { "status": 200,
  #|        "headers": { "Content-Type": "application/json" },
  #|        "bodyFile": "users/1.json" } },
  #|    { "id": "create-user", "mock": "teapot",
  #|      "request": { "method": "POST", "path": "/users",
  #|        "query": { "dry run": "yes" },
  #|        "headers": { "content-type": "application/json" },
  #|        "body": { "json": { "name": "Zoë" } } },
  #|      "response": { "status": 201, "body": "created" } },
  #|    { "id": "first", "mock": "teapot", "priority": 1,
  #|      "request": { "path": "/users/first" },
  #|      "response": { "status": 200, "body": "first" } },
  #|    { "id": "shadowed", "mock": "teapot",
  #|      "request": { "path": "/users/first" },
  #|      "response": { "status": 200, "body": "shadowed" } } ] }

///|
async test "smock serve answers from a body file, matches exact and json conditions, and sends the Mock's no-match status" {
  let user = "{\n  \"id\": 1,\n  \"name\": \"Alice\"\n}\n"
  with_definitions([("teapot.json", teapot), ("files/users/1.json", user)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = [
        smock.send("GET", "/users/1?full=1"),
        smock.send("GET", "/users/first"),
        smock.send(
          "POST",
          "/users?dry%20run=yes",
          headers=[("Content-Type", "application/json")],
          body="{\"id\": 7, \"name\": \"Zo\\u00eb\"}",
        ),
        smock.send(
          "POST",
          "/users?dry+run=yes",
          headers=[("Content-Type", "application/json")],
          body="{\"name\": \"Zoe\"}",
        ),
        smock.send("GET", "/users/2"),
      ]
      inspect(
        out.join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Accept-Ranges: bytes
          #|Smock-Mock: teapot; via=default
          #|Content-Length: 33
          #|
          #|{
          #|  "id": 1,
          #|  "name": "Alice"
          #|}
          #|
          #|---
          #|HTTP/1.1 200 OK
          #|Smock-Mock: teapot; via=default
          #|Content-Length: 5
          #|
          #|first
          #|---
          #|HTTP/1.1 201 Created
          #|Smock-Mock: teapot; via=default
          #|Content-Length: 7
          #|
          #|created
          #|---
          #|HTTP/1.1 501 Not Implemented
          #|Content-Type: application/json
          #|Smock-Near-Miss: first; failed=path
          #|Smock-Mock: teapot; via=default
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 501 Not Implemented
          #|Content-Type: application/json
          #|Smock-Near-Miss: first; failed=path
          #|Smock-Mock: teapot; via=default
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "smock serve sends a header given an array as one field line per value, in order, where its name stands" {
  let defs =
    #|mocks:
    #|  - name: users
    #|stubs:
    #|  - id: login
    #|    mock: users
    #|    request: { method: POST, path: /login }
    #|    response:
    #|      status: 200
    #|      headers:
    #|        X-A: "1"
    #|        Set-Cookie:
    #|          - session=abc; Path=/; HttpOnly
    #|          - theme=dark; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT
    #|        X-B: [only]
    #|      body: ok
  with_definitions([("users.yaml", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.send("POST", "/login"),
        content=(
          #|HTTP/1.1 200 OK
          #|X-A: 1
          #|Set-Cookie: session=abc; Path=/; HttpOnly
          #|Set-Cookie: theme=dark; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT
          #|X-B: only
          #|Smock-Mock: users; via=default
          #|Content-Length: 2
          #|
          #|ok
        ),
      )
    })
  })
}

///|
async test "smock serve reads body files from the body-file subdirectory its setting names" {
  let defs =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [{ "id": "get-user", "mock": "users",
    #|    "request": { "path": "/users/1" },
    #|    "response": { "status": 200, "bodyFile": "users/1.json" } }] }
  with_definitions(
    [
      ("users.json", defs),
      ("bodies/users/1.json", "from bodies/"),
      ("files/users/1.json", "from files/"),
    ],
    dir => {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", "--body-file-dir", "bodies"],
        smock => {
          inspect(
            smock.send("GET", "/users/1"),
            content=(
              #|HTTP/1.1 200 OK
              #|Accept-Ranges: bytes
              #|Smock-Mock: users; via=default
              #|Content-Length: 12
              #|
              #|from bodies/
            ),
          )
        },
      )
    },
  )
}

///|
async test "a missing body file or a body-file path that leaves its subdirectory stops smock serve and fails smock check, with file and JSON Pointer" {
  let defs =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [
    #|    { "id": "missing", "mock": "users",
    #|      "response": { "status": 200, "bodyFile": "users/2.json" } },
    #|    { "id": "outside", "mock": "users",
    #|      "response": { "status": 200, "bodyFile": "../users.json" } } ] }
  with_definitions([("users.json", defs), ("files/users/1.json", "{}")], dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}\n---\n\{check([dir])}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/0/response/bodyFile","error":"no body file \"users/2.json\" in the body-file subdirectory"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/1/response/bodyFile","error":"must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with ."}
        #|---
        #|status 1
        #|users.json: /stubs/0/response/bodyFile: no body file "users/2.json" in the body-file subdirectory
        #|users.json: /stubs/1/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
        #|
      ),
    )
  })
}

///|
async test "two header names in a response that differ only in case stop smock serve and fail smock check, at the later name" {
  let defs =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [{ "id": "login", "mock": "users",
    #|    "response": { "status": 200,
    #|      "headers": { "Set-Cookie": "a=1", "set-cookie": "b=2" } } }] }
  with_definitions([("users.json", defs)], dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}\n---\n\{check([dir])}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/0/response/headers/set-cookie","error":"the header name \"Set-Cookie\" is already given: header names are case-insensitive"}
        #|---
        #|status 1
        #|users.json: /stubs/0/response/headers/set-cookie: the header name "Set-Cookie" is already given: header names are case-insensitive
        #|
      ),
    )
  })
}

///|
async test "an empty header array and an array for Content-Type stop smock serve and fail smock check, at the header's name" {
  let defs =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [{ "id": "login", "mock": "users",
    #|    "response": { "status": 200,
    #|      "headers": { "Set-Cookie": [], "content-type": ["text/plain"] } } }] }
  with_definitions([("users.json", defs)], dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}\n---\n\{check([dir])}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/0/response/headers/Set-Cookie","error":"must not be an empty array"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/0/response/headers/content-type","error":"must be a string"}
        #|---
        #|status 1
        #|users.json: /stubs/0/response/headers/Set-Cookie: must not be an empty array
        #|users.json: /stubs/0/response/headers/content-type: must be a string
        #|
      ),
    )
  })
}

///|
async test "a Smock-Mock response header stops smock serve and fails smock check" {
  let defs =
    #|mocks:
    #|  - name: a
    #|stubs:
    #|  - id: s
    #|    mock: a
    #|    request: { method: GET, path: /x }
    #|    response:
    #|      status: 200
    #|      headers: { smock-mock: mine }
    #|      body: ok
  with_definitions([("a.yaml", defs)], dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}\n---\n\{check([dir])}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"invalid definitions","file":"a.yaml","pointer":"/stubs/0/response/headers/smock-mock","error":"is set by smock and cannot be given"}
        #|---
        #|status 1
        #|a.yaml: /stubs/0/response/headers/smock-mock: is set by smock and cannot be given
        #|
      ),
    )
  })
}

///|
async test "a cross-origin request that no Stub matches gets the Mock's noMatch headers with smock's body and Near miss, after a preflight Stub" {
  let defs =
    #|mocks:
    #|  - name: users
    #|    noMatch:
    #|      status: 404
    #|      headers:
    #|        Access-Control-Allow-Origin: "*"
    #|        Access-Control-Expose-Headers: Smock-Near-Miss, Smock-Mock
    #|stubs:
    #|  - id: get-user
    #|    mock: users
    #|    request: { method: GET, path: /users/1 }
    #|    response: { status: 200, json: { id: 1 } }
    #|  - id: preflight
    #|    mock: users
    #|    request: { method: OPTIONS }
    #|    response:
    #|      status: 204
    #|      headers:
    #|        Access-Control-Allow-Origin: "*"
    #|        Access-Control-Allow-Methods: GET, POST, PUT, DELETE
    #|        Access-Control-Allow-Headers: Content-Type, Authorization
  with_definitions([("users.yaml", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let origin = ("Origin", "http://localhost:5173")
      inspect(
        [
          smock.send("OPTIONS", "/users/2", headers=[
            origin,
            ("Access-Control-Request-Method", "DELETE"),
          ]),
          smock.send("GET", "/users/2", headers=[origin]),
          smock.send("GET", "/users/1", headers=[origin]),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 204 No Content
          #|Access-Control-Allow-Origin: *
          #|Access-Control-Allow-Methods: GET, POST, PUT, DELETE
          #|Access-Control-Allow-Headers: Content-Type, Authorization
          #|Smock-Mock: users; via=default
          #|
          #|
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Access-Control-Allow-Origin: *
          #|Access-Control-Expose-Headers: Smock-Near-Miss, Smock-Mock
          #|Smock-Near-Miss: get-user; failed=path
          #|Smock-Mock: users; via=default
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: users; via=default
          #|Content-Length: 8
          #|
          #|{"id":1}
        ),
      )
    })
  })
}

///|
async test "a noMatch header that smock sets stops smock serve and fails smock check, at the header's name" {
  let defs =
    #|{ "mocks": [{ "name": "users",
    #|  "noMatch": { "headers": { "content-type": "text/plain", "Smock-Near-Miss": "none" } } }] }
  with_definitions([("users.json", defs)], dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}\n---\n\{check([dir])}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/mocks/0/noMatch/headers/content-type","error":"is set by smock and cannot be given"}
        #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/mocks/0/noMatch/headers/Smock-Near-Miss","error":"is set by smock and cannot be given"}
        #|---
        #|status 1
        #|users.json: /mocks/0/noMatch/headers/content-type: is set by smock and cannot be given
        #|users.json: /mocks/0/noMatch/headers/Smock-Near-Miss: is set by smock and cannot be given
        #|
      ),
    )
  })
}
