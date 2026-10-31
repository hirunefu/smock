// Seam 2 tests of the mockoon log format: with `SMOCK_LOG_FORMAT=mockoon`
// or `--log-format mockoon`, smock writes a Transaction recorded line to
// stdout for each request a Mock handles. Lines are compared whole, byte for
// byte, with only the value of `timestamp` masked, once its form is checked.

///|
/// Two Mocks, neither of them the Default Mock: `users`, at the Hosts
/// `localhost` and `127.0.0.1`, with a Stub for `GET /users/1`, and
/// `orders`, at `orders.example.com`. With `default=true`, `users` is the
/// Default Mock.
fn mockoon_mocks(default~ : Bool = false) -> Array[(String, String)] {
  [
    (
      "users.json",
      (
        $|{ "mocks": [
        $|    { "name": "users", "hosts": ["localhost", "127.0.0.1"], "default": \{default} },
        $|    { "name": "orders", "hosts": ["orders.example.com"] }],
        $|  "stubs": [{ "id": "get-user", "mock": "users",
        $|    "request": { "method": "GET", "path": "/users/1" },
        $|    "response": { "status": 200, "body": "Alice" } }] }
      ),
    ),
  ]
}

///|
/// `line` with the value of its `timestamp`, its last key, shown as
/// `<timestamp>` when it has the form `YYYY-MM-DDTHH:mm:ss.sssZ`. A value of
/// any other form stays, so that it shows.
fn mask_timestamp(line : String) -> String {
  let key = ",\"timestamp\":\""
  guard line.rev_find(key) is Some(i) else { return line }
  let start = i + key.length()
  let rest = line[start:]
  let form = "0000-00-00T00:00:00.000Z\"}"
  guard rest.length() == form.length() else { return line }
  for j, c in form {
    let ok = if c == '0' {
      rest[j] >= '0' && rest[j] <= '9'
    } else {
      rest[j] == c.to_int().to_uint16()
    }
    if !ok {
      return line
    }
  }
  "\{line[:start]}<timestamp>\"}"
}

///|
/// `lines` with their timestamps masked, one per line.
fn masked_lines(lines : Array[String]) -> String {
  lines.map(mask_timestamp).join("\n")
}

///|
async test "with SMOCK_LOG_FORMAT=mockoon, each request a Mock handles writes one Transaction recorded line to stdout, on the plain and the TLS port" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let _ = with_smock(args, env~, smock => {
        let requests = [
          (
            Plain,
            "GET /users/1?verbose=true HTTP/1.1\r\nHost: localhost\r\n\r\n",
          ),
          (Plain, "GET /users/a%20b HTTP/1.1\r\nHost: localhost\r\n\r\n"),
          (
            Plain,
            "GET http://unknown.example.com/orders/1 HTTP/1.1\r\nHost: unknown.example.com\r\n\r\n",
          ),
          (
            Plain,
            "GET http://localhost/users/1?verbose=true HTTP/1.1\r\nHost: localhost\r\n\r\n",
          ),
          (Plain, "GET http://localhost HTTP/1.1\r\nHost: localhost\r\n\r\n"),
          (Plain, "get /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"),
          (
            Tls(certs),
            "GET /users/1?verbose=true HTTP/1.1\r\nHost: localhost\r\n\r\n",
          ),
        ]
        let statuses = []
        for request in requests {
          let (over, raw) = request
          statuses.push(status_line(smock.exchange(over, raw)))
        }
        // Read while smock runs: a line held in a buffer would not come.
        let lines = smock.stdout_lines(requests.length())
        let on_stderr = smock.logs
          .iter()
          .any(line => line.contains("Transaction recorded"))
        inspect(
          "\{statuses.join("\n")}\n\{masked_lines(lines)}\non stderr: \{on_stderr}",
          content=(
            #|HTTP/1.1 200 OK
            #|HTTP/1.1 404 Not Found
            #|HTTP/1.1 404 Not Found
            #|HTTP/1.1 200 OK
            #|HTTP/1.1 404 Not Found
            #|HTTP/1.1 404 Not Found
            #|HTTP/1.1 200 OK
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/a%20b","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"get","requestPath":"/users/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|on stderr: false
          ),
        )
      })
    })
  })
}
