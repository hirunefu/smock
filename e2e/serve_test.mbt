///|
let users : String =
  #|{
  #|  "mocks": [{ "name": "users" }],
  #|  "stubs": [
  #|    {
  #|      "id": "get-user",
  #|      "mock": "users",
  #|      "request": { "method": "GET", "path": "/users/1" },
  #|      "response": {
  #|        "status": 200,
  #|        "headers": { "Content-Type": "application/json", "X-Source": "smock" },
  #|        "body": "{\"id\":1,\"name\":\"Alice\"}"
  #|      }
  #|    }
  #|  ]
  #|}

///|
async test "smock serve answers a request that matches a Stub with that Stub's response" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/1"),
        content=(
          #|200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
    })
  })
}

///|
/// `users` written in YAML.
let users_yaml : String =
  #|mocks:
  #|  - name: users
  #|stubs:
  #|  - id: get-user
  #|    mock: users
  #|    request: { method: GET, path: /users/1 }
  #|    response:
  #|      status: 200
  #|      headers:
  #|        Content-Type: application/json
  #|        X-Source: smock
  #|      body: '{"id":1,"name":"Alice"}'

///|
async test "smock serve answers a request that matches a Stub declared in a YAML file" {
  with_definitions([("users.yaml", users_yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/1"),
        content=(
          #|200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
    })
  })
}

///|
async test "any other request gets the no-match response" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/2"),
        content=(
          #|404 Not Found
          #|Content-Type: application/json
          #|Smock-Mock: users; via=default
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "with an invalid definition set, smock logs every error with its file and JSON Pointer and exits with status 1" {
  with_definitions(
    [
      ("users.json", users),
      ("broken.json", "{ \"stubs\": [{ \"id\": 7, \"mock\": \"users\" }] }"),
      (
        "orders.yaml", "stubs:\n  - id: get-order\n    mock: users\n    request: { method: on }\n",
      ),
      ("payments.yml", "mocks:\n  - name: \"payments\n"),
      ("refunds.yaml", "mocks: [{ name: refunds }]\n---\nstubs: []\n"),
    ],
    dir => {
      let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
      inspect(
        "status \{stopped.status}\n" + entries(stopped.logs),
        content=(
          #|status 1
          #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
          #|{"level":"error","msg":"invalid definitions","file":"broken.json","pointer":"/stubs/0/id","error":"must be a non-empty string"}
          #|{"level":"error","msg":"invalid definitions","file":"broken.json","pointer":"/stubs/0","error":"needs \"response\""}
          #|{"level":"error","msg":"invalid definitions","file":"orders.yaml","pointer":"/stubs/0/request/method","error":"\"on\" may be read as a boolean; quote this value"}
          #|{"level":"error","msg":"invalid definitions","file":"payments.yml","pointer":"/mocks/0/name","error":"unterminated double-quoted value"}
          #|{"level":"error","msg":"invalid definitions","file":"refunds.yaml","pointer":"","error":"multiple documents are not supported"}
        ),
      )
    },
  )
}

///|
async test "when the port is taken, smock logs that it cannot listen and exits with status 1" {
  let _ = with_smock(["--port", "0"], first => {
    let second = run_smock(["serve", "--port", first.port.to_string()])
    inspect(
      "status \{second.status}\n\{entries(second.logs)}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"error","msg":"cannot listen","listener":"plain","address":"0.0.0.0:*","error":"OSError(\"@socket.TcpServer::new(): Address already in use\")"}
      ),
    )
  })
}

///|
async test "logs start with the startup entry, then the random seed and the listening address, and have no per-request lines" {
  // SIGTERM ends smock at once for now; the drain comes with "Probes and
  // graceful shutdown".
  with_definitions([("users.json", users)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let _ = smock.get("/users/1")
      let _ = smock.get("/users/2")
    })
    inspect(
      "status \{stopped.status}\n" + entries(stopped.logs),
      content=(
        #|status -15
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
      ),
    )
  })
}
