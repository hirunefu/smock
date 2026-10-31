// Seam 2 tests of the mockoon log format: with `SMOCK_LOG_FORMAT=mockoon`
// or `--log-format mockoon`, smock writes a Transaction recorded line to
// stdout for each request a Mock handles, once, when it ends, however it
// ends. Lines are compared whole, byte for byte, with only the value of
// `timestamp` masked, once its form is checked.

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
        let lines = smock.transaction_lines(requests.length())
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
        out.push(masked_lines(smock.transaction_lines(1)))
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
    out.push(
      "Transaction recorded lines with the flag: \{transactions(flag_on.stdout).length()}",
    )
    out.push("stdout with --log-format json: \{flag_off.stdout.length()} lines")
    inspect(
      out.join("\n"),
      content=(
        #|HTTP/1.1 404 Not Found
        #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
        #|HTTP/1.1 404 Not Found
        #|Transaction recorded lines with the flag: 1
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
        "\{last_reload(status)}\n\{status_line(response)}\n\{masked_lines(smock.transaction_lines(1))}",
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
        out.push(masked_lines(smock.transaction_lines(1)))
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
      inspect(transactions(stopped.stdout).length(), content="1")
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

///|
/// The Transaction recorded lines among `lines`.
fn transactions(lines : Array[String]) -> Array[String] {
  lines.filter(line => line.contains("\"message\":\"Transaction recorded\""))
}

///|
/// Waits until smock has written `count` Transaction recorded lines to
/// stdout, while it runs, and returns them all.
async fn Smock::transaction_lines(self : Smock, count : Int32) -> Array[String] {
  let written = @async.with_timeout_opt(patience_ms, () => {
    while transactions(self.stdout).length() < count {
      @async.sleep(10)
    }
  })
  guard written is Some(_) else {
    fail(
      "smock wrote \{transactions(self.stdout).length()} of \{count} Transaction recorded lines in time:\n\{self.stdout.join("\n")}",
    )
  }
  transactions(self.stdout)
}

///|
async test "a reset or a close Fault logs fault and no responseStatus, and a partial Fault the status it wrote, on the plain and the TLS port" {
  let env = { "SMOCK_LOG_FORMAT": "mockoon" }
  let _ = on_both_ports(files=[("m.json", faults)], env~, (smock, over) => {
    let before = transactions(smock.stdout).length()
    let out = []
    let requests = [
      "POST /reset?attempt=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody",
      "GET /close HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET /partial HTTP/1.1\r\nHost: localhost\r\n\r\n",
    ]
    for request in requests {
      let conn = smock.connect(over~)
      defer conn.close()
      conn.write(request)
      let (received, ending) = sent_until_end(conn, within=patience_ms)
      let sent = if received.length() == 0 {
        "nothing"
      } else {
        status_line(
          @utf8.decode_lossy(received).replace_all(old="\r\n", new="\n"),
        )
      }
      out.push("\{sent}, then \{ending}")
    }
    let lines = smock.transaction_lines(before + requests.length())[before:]
    inspect(
      "\{out.join("\n")}\n\{masked_lines(lines.to_owned())}",
      content=(
        #|nothing, then an RST
        #|nothing, then a FIN
        #|HTTP/1.1 200 OK, then a FIN
        #|{"app":"smock","environmentName":"m","fault":"reset","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/reset","requestProxied":false,"timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"m","fault":"close","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/close","requestProxied":false,"timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/partial","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
      ),
    )
  })
}

///|
/// When smock wrote `line`, by its `timestamp`, in milliseconds since the
/// Unix epoch, as `@async.now()` gives times.
fn written_at(line : String) -> Int64 raise {
  guard @json.parse(line) is Object(fields) &&
    fields.get("timestamp") is Some(String(timestamp)) &&
    @log.parse_time(timestamp) is Some(at) else {
    fail("no timestamp in \{line}")
  }
  at
}

///|
async test "a delayed response logs after its delay, and a Server-Sent Event stream logs once, after its last event, with the time each line is written" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let conn = smock.connect()
      defer conn.close()
      let start = @async.now()
      conn.write("GET /delayed HTTP/1.1\r\nHost: localhost\r\n\r\n")
      @async.sleep(500)
      out.push("during the delay: \{transactions(smock.stdout).length()} lines")
      out.push("/delayed answers: \{status_line(read_response(conn))}")
      let line = smock.transaction_lines(1)[0]
      out.push(mask_timestamp(line))
      out.push("written after the delay: \{written_at(line) - start >= 1000}")
      let stream = smock.connect()
      defer stream.close()
      let start = @async.now()
      stream.write("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
      out.push("/stream answers: \{status_line(read_head(stream))}")
      guard stream.read_until("data: first\n\n") is Some(_) else {
        fail("no first event")
      }
      @async.sleep(300)
      out.push(
        "after the first event: \{transactions(smock.stdout).length() - 1} lines",
      )
      guard stream.read_until("data: last\n\n") is Some(_) &&
        stream.read_until("0\r\n\r\n") is Some(_) else {
        fail("the stream did not end")
      }
      let line = smock.transaction_lines(2)[1]
      out.push(mask_timestamp(line))
      out.push(
        "written after the last event: \{written_at(line) - start >= 1000}",
      )
      // The stream is one request: no more lines come.
      @async.sleep(300)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      inspect(
        out.join("\n"),
        content=(
          #|during the delay: 0 lines
          #|/delayed answers: HTTP/1.1 200 OK
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the delay: true
          #|/stream answers: HTTP/1.1 200 OK
          #|after the first event: 0 lines
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stream","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the last event: true
          #|lines in all: 2
        ),
      )
    })
  })
}

///|
/// How the Journal says each request it holds ended, oldest first, one per
/// line: `<method> <target>: <status>`, or `<method> <target>: fault
/// <name>` for a reset or a close Fault.
async fn Smock::journal_endings(self : Smock) -> String {
  guard self.journal() is (200, Object({ "entries": Array(entries), .. })) else {
    fail("no Journal")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            { "method": String(meth), "target": String(target), .. }
          ),
          "status": status,
          "fault": fault,
          ..
        }
      ) else {
      fail("unexpected entry: \{entry.stringify()}")
    }
    let ended = match (status, fault) {
      (Number(status, ..), _) => status.to_int().to_string()
      (_, String(fault)) => "fault \{fault}"
      _ => "neither a status nor a Fault"
    }
    out.push("\{meth} \{target}: \{ended}")
  }
  out.join("\n")
}

///|
async test "a request whose client goes away during its delay logs the planned status, as the Journal records it, once the delay is over" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let conn = smock.connect()
      let start = @async.now()
      conn.write("GET /delayed HTTP/1.1\r\nHost: localhost\r\n\r\n")
      @async.sleep(200)
      conn.close()
      let line = smock.transaction_lines(1)[0]
      inspect(
        (
          $|\{mask_timestamp(line)}
          $|written once the delay was over: \{written_at(line) - start >= 1000}
          $|\{smock.journal_endings()}
        ),
        content=(
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written once the delay was over: true
          #|GET /delayed: 200
        ),
      )
    })
  })
}

///|
async test "a request whose write times out against a client that stops reading logs the planned status when the write timeout cuts it, on the plain and the TLS port" {
  let env = { "SMOCK_LOG_FORMAT": "mockoon", "SMOCK_WRITE_TIMEOUT_MS": "500" }
  let _ = on_both_ports(files=big_files(), env~, (smock, over) => {
    let before = transactions(smock.stdout).length()
    let conn = smock.connect(over~)
    defer conn.close()
    let start = @async.now()
    // The client reads nothing, so the 16 MiB body fills the socket buffers
    // and smock's write waits on it until the write timeout.
    conn.write("GET /big?client=stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let line = smock.transaction_lines(before + 1)[before]
    inspect(
      (
        $|\{mask_timestamp(line)}
        $|written once the write timed out: \{written_at(line) - start >= 500}
      ),
      content=(
        #|{"app":"smock","environmentName":"big","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/big","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
        #|written once the write timed out: true
      ),
    )
  })
}

///|
async test "a stream and a delayed response that the drain timeout cuts each log the planned status when they are cut, before drain ended and Server stopped" {
  with_definitions([("m.json", drain_defs)], dir => {
    let env = {
      "SMOCK_LOG_FORMAT": "mockoon",
      "SMOCK_DRAIN_TIMEOUT_MS": "1500",
    }
    let stopped = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let stream = smock.connect()
      defer stream.close()
      stream.write("GET /ticks HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let _ = read_head(stream)
      let stalled = smock.connect()
      defer stalled.close()
      stalled.write("GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
      @async.sleep(settle_ms)
      let start = @async.now()
      smock.terminate()
      let status = smock.exited()
      let lines = smock.transaction_lines(2)
      // Both are cut at once, so their lines may come in either order.
      lines.sort_by((a, b) => a.lexical_compare(b))
      let cut = lines
        .iter()
        .all(line => (written_at(line) - start >= 1500) catch { _ => false })
      inspect(
        (
          $|\{masked_lines(lines)}
          $|written once the drain timeout cut them: \{cut}
          $|exit status \{status}
        ),
        content=(
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stalled","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/ticks","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written once the drain timeout cut them: true
          #|exit status 0
        ),
      )
    })
    // The lines of the drain, in order: the cut requests' lines come
    // before the drain ends.
    guard stopped.stdout.search_by(line => message_of(line) == "drain started")
      is Some(started) else {
      fail("no drain started line:\n\{stopped.stdout.join("\n")}")
    }
    inspect(
      stopped.stdout[started:].map(message_of).join("\n"),
      content=(
        #|drain started
        #|Transaction recorded
        #|Transaction recorded
        #|drain ended
        #|Server stopped
      ),
    )
  })
}

///|
async test "three pipelined requests log three lines, in the order they are answered" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let conn = smock.connect()
      defer conn.close()
      // The first is delayed, so the two behind it wait for it.
      conn.write(
        "GET /delayed HTTP/1.1\r\nHost: localhost\r\n\r\nGET /quick HTTP/1.1\r\nHost: localhost\r\n\r\nGET /nope HTTP/1.1\r\nHost: localhost\r\n\r\n",
      )
      let statuses = []
      for _ in 0..<3 {
        statuses.push(status_line(read_response(conn)))
      }
      inspect(
        "\{statuses.join("\n")}\n\{masked_lines(smock.transaction_lines(3))}",
        content=(
          #|HTTP/1.1 200 OK
          #|HTTP/1.1 200 OK
          #|HTTP/1.1 404 Not Found
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/quick","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/nope","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}

///|
async test "with no codec rejection, the Transaction recorded lines number the requests that smock_requests_total counts, on the plain and the TLS port" {
  with_definitions([("m.json", faults)], dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      // Requests that end every way, each on a connection of its own, which
      // smock closes after them: a whole response, a 404, two pipelined
      // requests, each connection Fault, and a client that goes away during
      // a delay.
      let requests = [
        "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", "GET /nope HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        "GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\nGET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        "GET /reset HTTP/1.1\r\nHost: localhost\r\n\r\n", "GET /close HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /partial HTTP/1.1\r\nHost: localhost\r\n\r\n",
      ]
      let per_port = requests.length() + 2
      let stopped = with_smock(args, env~, smock => {
        for over in [Plain, Tls(certs)] {
          for request in requests {
            let conn = smock.connect(over~)
            defer conn.close()
            conn.write(request)
            let _ = sent_until_end(conn, within=patience_ms)
          }
          let gone = smock.connect(over~)
          gone.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
          gone.close()
        }
        let lines = smock.transaction_lines(2 * per_port).length()
        let mut counted = 0.0
        for sample in smock.metrics().1 {
          if sample.name == "smock_requests_total" {
            counted += sample.value
          }
        }
        inspect(
          "requests counted: \{counted}\nlines: \{lines}",
          content=(
            #|requests counted: 16
            #|lines: 16
          ),
        )
      })
      inspect(transactions(stopped.stdout).length(), content="16")
    })
  })
}
