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

///|
async test "--log-format mockoon wins over SMOCK_LOG_FORMAT, and a request the Default Mock answers through an unknown Host names it" {
  with_definitions(mockoon_mocks(default=true), dir => {
    let out = []
    let flag_on = with_smock(
      ["--dir", dir, "--port", "0", "--log-format", "mockoon"],
      env={ "SMOCK_LOG_FORMAT": "json" },
      smock => {
        out.push(
          status_line(
            smock.exchange(
              Plain,
              "GET /orders/1 HTTP/1.1\r\nHost: unknown.example.com\r\n\r\n",
            ),
          ),
        )
        out.push(masked_lines(smock.stdout_lines(1)))
      },
    )
    let flag_off = with_smock(
      ["--dir", dir, "--port", "0", "--log-format", "json"],
      env={ "SMOCK_LOG_FORMAT": "mockoon" },
      smock => {
        out.push(
          status_line(
            smock.exchange(
              Plain,
              "GET /orders/1 HTTP/1.1\r\nHost: unknown.example.com\r\n\r\n",
            ),
          ),
        )
      },
    )
    out.push("stdout with the flag: \{flag_on.stdout.length()} line")
    out.push("stdout with --log-format json: \{flag_off.stdout.length()} lines")
    inspect(
      out.join("\n"),
      content=(
        #|HTTP/1.1 404 Not Found
        #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
        #|HTTP/1.1 404 Not Found
        #|stdout with the flag: 1 line
        #|stdout with --log-format json: 0 lines
      ),
    )
  })
}

///|
async test "a Mock that a reload adds is named on the line of the next request it answers" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let before = smock.status()
      write(
        dir,
        "payments.json",
        (
          #|{ "mocks": [{ "name": "payments", "hosts": ["payments.example.com"] }],
          #|  "stubs": [{ "id": "charge", "mock": "payments",
          #|    "request": { "method": "POST", "path": "/charges" },
          #|    "response": { "status": 201 } }] }
        ),
      )
      let status = smock.reloaded(before)
      let response = smock.exchange(
        Plain,
        "POST /charges HTTP/1.1\r\nHost: payments.example.com\r\nContent-Length: 0\r\n\r\n",
      )
      inspect(
        "\{last_reload(status)}\n\{status_line(response)}\n\{masked_lines(smock.stdout_lines(1))}",
        content=(
          #|"swapped"
          #|HTTP/1.1 201 Created
          #|{"app":"smock","environmentName":"payments","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/charges","requestProxied":false,"responseStatus":201,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}

///|
async test "with the reading end of stdout closed, smock drops its lines, answers every request and exits 0 on SIGTERM" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let stopped = with_smock(
      ["--dir", dir, "--port", "0"],
      env~,
      close_stdout=true,
      smock => {
        // More lines than a pipe holds (64 KiB on Linux), so that a write
        // that waited for a reader instead of failing would stall smock.
        let conn = smock.connect()
        defer conn.close()
        let mut ok = 0
        for _ in 0..<400 {
          conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
          if status_line(read_response(conn)) == "HTTP/1.1 200 OK" {
            ok += 1
          }
        }
        inspect(
          "\{ok} of 400 answered 200 OK",
          content="400 of 400 answered 200 OK",
        )
      },
    )
    inspect(stopped.status, content="0")
  })
}

///|
async test "a request the codec rejects, an Admin API call, a probe and a scrape write no Transaction recorded line" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let stopped = with_smock(args, env~, smock => {
        let out = []
        for over in [Plain, Tls(certs)] {
          out.push(
            status_line(
              smock.exchange(
                over, "GET /users/1 HTTP/1.1\r\nHost : bad\r\n\r\n",
              ),
            ),
          )
          out.push(
            status_line(
              smock.exchange(
                over, "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: x\r\n\r\n",
              ),
            ),
          )
        }
        for path in ["/v1/status", "/startupz", "/readyz", "/livez", "/metrics"] {
          out.push("\{path}: \{smock.admin("GET", path).status}")
        }
        // Lines come in the order requests end, so once this request's line
        // is there, any line of the requests before it would be too.
        out.push(
          status_line(
            smock.exchange(
              Plain,
              "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
            ),
          ),
        )
        out.push(masked_lines(smock.stdout_lines(1)))
        inspect(
          out.join("\n"),
          content=(
            #|HTTP/1.1 400 Bad Request
            #|HTTP/1.1 400 Bad Request
            #|HTTP/1.1 400 Bad Request
            #|HTTP/1.1 400 Bad Request
            #|/v1/status: 200
            #|/startupz: 200
            #|/readyz: 200
            #|/livez: 200
            #|/metrics: 200
            #|HTTP/1.1 200 OK
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          ),
        )
      })
      inspect(stopped.stdout.length(), content="1")
    })
  })
}

///|
async test "with the json log format, the default, smock writes nothing to stdout" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let stopped = with_smock(args, smock => {
        for over in [Plain, Tls(certs)] {
          let _ = smock.exchange(
            over, "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
          )
          let _ = smock.exchange(
            over, "GET /users/2 HTTP/1.1\r\nHost: unknown.example.com\r\n\r\n",
          )
        }
      })
      inspect(stopped.stdout.length(), content="0")
    })
  })
}
