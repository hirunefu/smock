// Seam 2 tests of the request traffic metrics on /metrics: requests and
// their latency by Mock and Stub, and unmatched requests by Mock, for the
// requests served on the plain and TLS ports.

///|
/// `/metrics`, fetched without a token and checked against the OpenAPI
/// document, read as the Prometheus text format.
async fn Smock::metrics(self : Smock) -> (String, Array[Sample]) {
  let response = self.admin("GET", "/metrics", token=None)
  (response.body, parse_prometheus(response.body))
}

///|
/// The lines of `/metrics` about the metrics whose names start with
/// `prefix`, as `metric_lines` picks them, one per line.
async fn Smock::metric(
  self : Smock,
  prefix : String,
  help? : Bool = false,
) -> String {
  metric_lines(self.admin("GET", "/metrics").body, prefix, help~).join("\n")
}

///|
/// Whether `name` is the name of a sample of the request traffic metrics.
fn is_traffic(name : String) -> Bool {
  name.has_prefix("smock_request_duration_seconds") ||
  name == "smock_requests_total" ||
  name == "smock_unmatched_requests_total"
}

///|
/// The request traffic metrics in `/metrics`, `text`, with its `samples`:
///
/// - their `# TYPE` lines;
/// - their samples, one per line, sorted, without the latency histogram's
///   buckets and sum, whose values depend on timing;
/// - the label names of each sample name, buckets and sum included.
fn traffic(text : String, samples : Array[Sample]) -> String {
  let out = []
  for line in text.split("\n") {
    if line.strip_prefix("# TYPE ") is Some(rest) &&
      is_traffic(rest.split(" ").next().unwrap_or("").to_owned()) {
      out.push(line.to_owned())
    }
  }
  let lines = samples
    .filter(sample => {
      is_traffic(sample.name) &&
      !sample.name.has_suffix("_bucket") &&
      !sample.name.has_suffix("_sum")
    })
    .map(sample => sample.line())
  lines.sort_by((a, b) => a.lexical_compare(b))
  out.push_iter(lines.iter())
  let labels : Map[String, Array[String]] = Map([])
  for sample in samples {
    if is_traffic(sample.name) {
      let names = sample.labels.map(label => label.0).join(", ")
      match labels.get(sample.name) {
        Some(seen) if seen.contains(names) => ()
        Some(seen) => seen.push(names)
        None => labels[sample.name] = [names]
      }
    }
  }
  for name, names in labels {
    out.push("labels of \{name}: \{names.join(" | ")}")
  }
  out.join("\n")
}

///|
/// An Ephemeral Stub that answers `GET path` with 200.
fn ephemeral_get(path : String) -> String {
  "{\"request\":{\"method\":\"GET\",\"path\":\"\{path}\"},\"response\":{\"status\":200,\"body\":\"ephemeral\"}}"
}

///|
/// The status line of each response in `responses`, as `exchange_each`
/// renders them.
fn statuses(responses : String) -> String {
  responses
  .split("\n---\n")
  .map(response => response.split("\n").next().unwrap_or("").to_owned())
  .collect()
  .join(", ")
}

///|
async test "after a matched request, two Ephemeral Stub matches, an unmatched request and an unknown-Host request on each port, /metrics counts them by Mock and Stub alone, and parses as the Prometheus text format" {
  with_definitions(two_mocks(default=false), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let _ = with_smock(args, smock => {
        let out = []
        for path in ["/a", "/b"] {
          let stubs = "/v1/mocks/orders/stubs"
          let response = smock.admin("POST", stubs, body=ephemeral_get(path))
          out.push("add GET \{path} to orders: \{response.status}")
        }
        for over in [Plain, Tls(certs)] {
          let responses = exchange_each(smock, over, [
            "GET /x HTTP/1.1\r\nHost: users.example.com\r\n\r\n", "GET /a HTTP/1.1\r\nHost: orders.example.com\r\n\r\n",
            "GET /b HTTP/1.1\r\nHost: orders.example.com\r\n\r\n", "GET /nope HTTP/1.1\r\nHost: users.example.com\r\n\r\n",
            "GET /x HTTP/1.1\r\nHost: elsewhere.example.com\r\n\r\n",
          ])
          let port = if over is Plain { "plain" } else { "TLS" }
          out.push("\{port}: \{statuses(responses)}")
        }
        let (text, samples) = smock.metrics()
        out.push(traffic(text, samples))
        inspect(
          out.join("\n"),
          content=(
            #|add GET /a to orders: 201
            #|add GET /b to orders: 201
            #|plain: HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 404 Not Found, HTTP/1.1 404 Not Found
            #|TLS: HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 200 OK, HTTP/1.1 404 Not Found, HTTP/1.1 404 Not Found
            #|# TYPE smock_requests_total counter
            #|# TYPE smock_request_duration_seconds histogram
            #|# TYPE smock_unmatched_requests_total counter
            #|smock_request_duration_seconds_count{mock="",stub=""} 2
            #|smock_request_duration_seconds_count{mock="orders",stub="ephemeral"} 4
            #|smock_request_duration_seconds_count{mock="users",stub=""} 2
            #|smock_request_duration_seconds_count{mock="users",stub="users-x"} 2
            #|smock_requests_total{mock="",stub=""} 2
            #|smock_requests_total{mock="orders",stub="ephemeral"} 4
            #|smock_requests_total{mock="users",stub=""} 2
            #|smock_requests_total{mock="users",stub="users-x"} 2
            #|smock_unmatched_requests_total{mock=""} 2
            #|smock_unmatched_requests_total{mock="users"} 2
            #|labels of smock_requests_total: mock, stub
            #|labels of smock_request_duration_seconds_bucket: mock, stub, le
            #|labels of smock_request_duration_seconds_sum: mock, stub
            #|labels of smock_request_duration_seconds_count: mock, stub
            #|labels of smock_unmatched_requests_total: mock
          ),
        )
      })
    })
  })
}

///|
async test "a request the Default Mock answers because no Mock lists its Host is labelled with the Default Mock's name" {
  with_definitions(two_mocks(default=true), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let responses = exchange_each(smock, Plain, [
        "GET /x HTTP/1.1\r\nHost: usres.example.com\r\n\r\n", "GET /y HTTP/1.1\r\nHost: usres.example.com\r\n\r\n",
        "GET /x HTTP/1.0\r\n\r\n",
      ])
      let (text, samples) = smock.metrics()
      inspect(
        "\{statuses(responses)}\n\{traffic(text, samples)}",
        content=(
          #|HTTP/1.1 200 OK, HTTP/1.1 404 Not Found, HTTP/1.1 200 OK
          #|# TYPE smock_requests_total counter
          #|# TYPE smock_request_duration_seconds histogram
          #|# TYPE smock_unmatched_requests_total counter
          #|smock_request_duration_seconds_count{mock="users",stub=""} 1
          #|smock_request_duration_seconds_count{mock="users",stub="users-x"} 2
          #|smock_requests_total{mock="users",stub=""} 1
          #|smock_requests_total{mock="users",stub="users-x"} 2
          #|smock_unmatched_requests_total{mock="users"} 1
          #|labels of smock_requests_total: mock, stub
          #|labels of smock_request_duration_seconds_bucket: mock, stub, le
          #|labels of smock_request_duration_seconds_sum: mock, stub
          #|labels of smock_request_duration_seconds_count: mock, stub
          #|labels of smock_unmatched_requests_total: mock
        ),
      )
    })
  })
}

///|
async test "Admin API, probe and /metrics requests on the admin port are not request traffic" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let calls = [
        ("GET", "/v1/status", Some(test_token)),
        ("GET", "/v1/status", None),
        ("GET", "/v1/mocks/users/stubs", Some(test_token)),
        ("GET", "/users/1", Some(test_token)),
        ("GET", "/startupz", None),
        ("GET", "/readyz", None),
        ("GET", "/livez", None),
        ("GET", "/metrics", None),
      ]
      for call in calls {
        let (meth, path, token) = call
        let _ = smock.admin(meth, path, token~)
      }
      let (text, samples) = smock.metrics()
      let before = traffic(text, samples)
      // One request on the plain port, to show what is counted.
      let _ = smock.get("/users/1")
      let (text, samples) = smock.metrics()
      inspect(
        "after admin calls only:\n\{before}\nafter one request on the plain port:\n\{traffic(text, samples)}",
        content=(
          #|after admin calls only:
          #|# TYPE smock_requests_total counter
          #|# TYPE smock_request_duration_seconds histogram
          #|# TYPE smock_unmatched_requests_total counter
          #|after one request on the plain port:
          #|# TYPE smock_requests_total counter
          #|# TYPE smock_request_duration_seconds histogram
          #|# TYPE smock_unmatched_requests_total counter
          #|smock_request_duration_seconds_count{mock="users",stub="get-user"} 1
          #|smock_requests_total{mock="users",stub="get-user"} 1
          #|labels of smock_requests_total: mock, stub
          #|labels of smock_request_duration_seconds_bucket: mock, stub, le
          #|labels of smock_request_duration_seconds_sum: mock, stub
          #|labels of smock_request_duration_seconds_count: mock, stub
        ),
      )
    })
  })
}

///|
/// A Mock whose `/delayed` answers after a delay of 1 s, whose `/quick`
/// answers at once, and whose `/stream` sends one event at once and the
/// last one 1 s later.
let slow : String =
  #|{ "mocks": [{ "name": "slow" }],
  #|  "stubs": [
  #|    { "id": "delayed", "mock": "slow", "request": { "path": "/delayed" },
  #|      "fault": { "delay": { "fixed": 1000 } },
  #|      "response": { "status": 200, "body": "late" } },
  #|    { "id": "quick", "mock": "slow", "request": { "path": "/quick" },
  #|      "response": { "status": 200, "body": "quick" } },
  #|    { "id": "stream", "mock": "slow", "request": { "path": "/stream" },
  #|      "response": { "status": 200,
  #|        "events": [{ "data": "first" }, { "delay": 1000, "data": "last" }] } } ] }

///|
/// The latency of the requests to the Stub `stub` in `samples`: how many
/// there are, and how many took up to 0.5 s and up to 5 s. Nothing when
/// none has been counted.
fn latency(samples : Array[Sample], stub : String) -> String {
  let parts = []
  for sample in samples {
    guard sample.name.has_prefix("smock_request_duration_seconds") &&
      sample.label("stub") == Some(stub) else {
      continue
    }
    match (sample.name, sample.label("le")) {
      ("smock_request_duration_seconds_count", _) =>
        parts.push("count \{sample.value}")
      (_, Some("0.5" | "5" as le)) =>
        parts.push("up to \{le} s: \{sample.value}")
      _ => ()
    }
  }
  if parts.is_empty() {
    "not counted"
  } else {
    parts.join(", ")
  }
}

///|
async test "the latency histogram runs from the request to the last byte of its response, so an injected delay and an SSE stream count, and a request is counted only once its response is written" {
  with_definitions([("slow.json", slow)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let conn = smock.connect()
      defer conn.close()
      conn.write("GET /delayed HTTP/1.1\r\nHost: localhost\r\n\r\n")
      out.push(
        "/delayed, while it waits: \{latency(smock.metrics().1, "delayed")}",
      )
      let response = read_response(conn)
      out.push("/delayed answers: \{statuses(response)}")
      out.push("/delayed, after: \{latency(smock.metrics().1, "delayed")}")
      let client = @http.Client("http://127.0.0.1:\{smock.port}")
      defer client.close()
      let response = client.get("/stream")
      out.push("/stream answers: \{response.code}")
      let first = client.read_until("\n\n")
      out.push("/stream sends: \{first.unwrap_or("nothing").escape()}")
      out.push(
        "/stream, while it streams: \{latency(smock.metrics().1, "stream")}",
      )
      let last = client.read_until("\n\n")
      out.push("/stream sends: \{last.unwrap_or("nothing").escape()}")
      let rest = @async.with_timeout_opt(patience_ms, () => client.read_some())
      out.push(if rest is Some(None) { "end of stream" } else { "more data" })
      out.push("/stream, after: \{latency(smock.metrics().1, "stream")}")
      inspect(
        out.join("\n"),
        content=(
          #|/delayed, while it waits: not counted
          #|/delayed answers: HTTP/1.1 200 OK
          #|/delayed, after: up to 0.5 s: 0, up to 5 s: 1, count 1
          #|/stream answers: 200
          #|/stream sends: "data: first"
          #|/stream, while it streams: not counted
          #|/stream sends: "data: last"
          #|end of stream
          #|/stream, after: up to 0.5 s: 0, up to 5 s: 1, count 1
        ),
      )
    })
  })
}

///|
async test "the latency of a request pipelined behind a slow response runs from when it was read, so its wait behind that response counts" {
  with_definitions([("slow.json", slow)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      conn.write(
        "GET /delayed HTTP/1.1\r\nHost: localhost\r\n\r\nGET /quick HTTP/1.1\r\nHost: localhost\r\n\r\n",
      )
      let delayed = read_response(conn)
      let quick = read_response(conn)
      inspect(
        [
          "answers: \{statuses(delayed)}, \{statuses(quick)}",
          "/quick: \{latency(smock.metrics().1, "quick")}",
        ].join("\n"),
        content=(
          #|answers: HTTP/1.1 200 OK, HTTP/1.1 200 OK
          #|/quick: up to 0.5 s: 0, up to 5 s: 1, count 1
        ),
      )
    })
  })
}

///|
async test "the latency buckets resolve sub-millisecond latencies and reach long delays" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let _ = smock.get("/users/1")
      let bounds = smock.metrics().1
        .filter(sample => sample.name == "smock_request_duration_seconds_bucket")
        .map(sample => sample.label("le").unwrap_or("?"))
      inspect(
        bounds.join(" "),
        content="0.0001 0.00025 0.0005 0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10 30 60 120 300 +Inf",
      )
    })
  })
}

///|
async test "smock writes no log line per request: traffic on the plain and TLS ports leaves nothing in the log" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let _ = with_smock(args, smock => {
        let before = smock.logs.length()
        let out = []
        for over in [Plain, Tls(certs)] {
          let responses = exchange_each(smock, over, [
            "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n", "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}",
            "GET /users/1 HTTP/1.1\r\nHost: elsewhere.example.com\r\n\r\n", "GET /users/1 HTTP/1.1\r\nHost : bad\r\n\r\n",
          ])
          out.push(statuses(responses))
        }
        // An Admin API change is logged before its response is sent. Once
        // its line is in the log, so is every line written before it.
        let stubs = "/v1/mocks/users/stubs"
        let response = smock.admin("POST", stubs, body=ephemeral_get("/x"))
        out.push("add an Ephemeral Stub: \{response.status}")
        let logged = @async.with_timeout_opt(patience_ms, () => {
          while !smock.logs[before:]
                .iter()
                .any(line => line.contains("Ephemeral Stub added")) {
            @async.sleep(10)
          }
        })
        guard logged is Some(_) else {
          fail("the Admin API change was not logged")
        }
        out.push("logged since the traffic began:")
        out.push(log_entries(smock.logs[before:].to_owned()))
        inspect(
          out.join("\n"),
          content=(
            #|HTTP/1.1 200 OK, HTTP/1.1 404 Not Found, HTTP/1.1 200 OK, HTTP/1.1 400 Bad Request
            #|HTTP/1.1 200 OK, HTTP/1.1 404 Not Found, HTTP/1.1 200 OK, HTTP/1.1 400 Bad Request
            #|add an Ephemeral Stub: 201
            #|logged since the traffic began:
            #|{"level":"info","msg":"Ephemeral Stub added","mock":"users","session":null,"id":"eph-1"}
          ),
        )
      })
    })
  })
}
