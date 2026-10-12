// Host resolution and the Default Mock on the wire: requests with real
// Host headers and request targets, sent over raw TCP connections.

///|
/// Two Mocks with Hosts, `users` marked default and `orders`, each with a
/// Stub `GET /x` that answers with its name. With `default=false`, neither
/// is the Default Mock.
fn two_mocks(default~ : Bool) -> Array[(String, String)] {
  [
    (
      "orders.json",
      (
        #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"] }],
        #|  "stubs": [{ "id": "orders-x", "mock": "orders",
        #|    "request": { "method": "GET", "path": "/x" },
        #|    "response": { "status": 200, "body": "from orders" } }] }
      ),
    ),
    (
      "users.json",
      (
        $|{ "mocks": [{ "name": "users", "hosts": ["users.example.com", "[::1]:8080"],
        $|    "default": \{default} }],
        $|  "stubs": [{ "id": "users-x", "mock": "users",
        $|    "request": { "method": "GET", "path": "/x" },
        $|    "response": { "status": 200, "body": "from users" } }] }
      ),
    ),
  ]
}

///|
/// Sends each request in `requests` on its own connection and renders the
/// responses.
async fn exchange(smock : Smock, requests : Array[String]) -> String {
  let out = []
  for request in requests {
    let conn = smock.connect()
    defer conn.close()
    conn.write(request)
    out.push(read_response(conn))
  }
  out.join("\n---\n")
}

///|
async test "requests reach the Mock whose Hosts include their Host, whatever its case, port or trailing dot" {
  with_definitions(two_mocks(default=true), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        exchange(smock, [
          "GET /x HTTP/1.1\r\nHost: users.example.com\r\n\r\n", "GET /x HTTP/1.1\r\nHost: ORDERS.Example.com.:8080\r\n\r\n",
          "GET /x HTTP/1.1\r\nHost: [::1]:9999\r\n\r\n", "GET /x HTTP/1.1\r\nHost: orders.example.com.\r\n\r\n",
        ]),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 10
          #|
          #|from users
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Length: 11
          #|
          #|from orders
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Length: 10
          #|
          #|from users
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Length: 11
          #|
          #|from orders
        ),
      )
    })
  })
}

///|
async test "the authority of an absolute-form target wins over the Host header" {
  with_definitions(two_mocks(default=true), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        exchange(smock, [
          "GET http://orders.example.com/x HTTP/1.1\r\nHost: users.example.com\r\n\r\n",
          "GET http://Orders.Example.com:8080/x?page=2 HTTP/1.1\r\nHost: users.example.com\r\n\r\n",
          "GET http://unknown.example.com/x HTTP/1.1\r\nHost: orders.example.com\r\n\r\n",
        ]),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 11
          #|
          #|from orders
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Length: 11
          #|
          #|from orders
          #|---
          #|HTTP/1.1 200 OK
          #|Smock-Mock: users; via=default
          #|Content-Length: 10
          #|
          #|from users
        ),
      )
    })
  })
}

///|
async test "the Default Mock answers an unknown Host or no Host, and says so in Smock-Mock" {
  with_definitions(two_mocks(default=true), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        exchange(smock, [
          "GET /x HTTP/1.1\r\nHost: usres.example.com\r\n\r\n",
          // Its no-match response says so too.
           "GET /y HTTP/1.1\r\nHost: usres.example.com\r\n\r\n",
          // HTTP/1.0 requests may have no Host.
           "GET /x HTTP/1.0\r\n\r\n",
          // Its own Host reaches it without the header.
           "GET /y HTTP/1.1\r\nHost: users.example.com\r\n\r\n",
        ]),
        content=(
          #|HTTP/1.1 200 OK
          #|Smock-Mock: users; via=default
          #|Content-Length: 10
          #|
          #|from users
          #|---
          #|HTTP/1.1 404 Not Found
          #|Smock-Mock: users; via=default
          #|Content-Length: 0
          #|
          #|
          #|---
          #|HTTP/1.1 200 OK
          #|Smock-Mock: users; via=default
          #|Connection: close
          #|Content-Length: 10
          #|
          #|from users
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Length: 0
          #|
          #|
        ),
      )
    })
  })
}

///|
async test "without a Default Mock, an unknown Host or no Host gets 404 with the accepted Hosts" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        exchange(smock, [
          "GET /x HTTP/1.1\r\nHost: Usres.Example.com:8080\r\n\r\n", "GET /x HTTP/1.0\r\n\r\n",
        ]),
        content=(
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Content-Length: 127
          #|
          #|{"error":"no Mock for this Host","host":"usres.example.com","acceptedHosts":["orders.example.com","users.example.com","[::1]"]}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Connection: close
          #|Content-Length: 112
          #|
          #|{"error":"no Mock for this Host","host":null,"acceptedHosts":["orders.example.com","users.example.com","[::1]"]}
        ),
      )
    })
  })
}

///|
async test "two Mocks claiming one Host, or two Default Mocks, fail smock check and stop smock serve at startup" {
  let files = [
    (
      "a.json",
      (
        #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"], "default": true }] }
      ),
    ),
    (
      "b.yaml",
      (
        #|mocks:
        #|  - name: accounts
        #|    hosts: ["Users.Example.com.:8080"]
        #|    default: true
      ),
    ),
  ]
  with_definitions(files, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|b.yaml: /mocks/0/hosts/0: the Host "users.example.com" is already claimed by the Mock "users" at a.json: /mocks/0/hosts/0
        #|b.yaml: /mocks/0/default: the Default Mock is already "users", marked at a.json: /mocks/0/default
        #|
      ),
    )
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
    inspect(
      "status \{stopped.status}\n" + entries(stopped.logs),
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"invalid definitions","file":"b.yaml","pointer":"/mocks/0/hosts/0","error":"the Host \"users.example.com\" is already claimed by the Mock \"users\" at a.json: /mocks/0/hosts/0"}
        #|{"level":"error","msg":"invalid definitions","file":"b.yaml","pointer":"/mocks/0/default","error":"the Default Mock is already \"users\", marked at a.json: /mocks/0/default"}
      ),
    )
  })
}
