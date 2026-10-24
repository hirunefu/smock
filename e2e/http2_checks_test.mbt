// Seam 2 tests of the requests an HTTP/2 stream may carry, over h2c on the
// plain port: a request that HTTP/1.1's rules refuse gets 400 on its stream
// alone, through the HTTP/1.1 codec's own checks, and a stream that breaks
// RFC 9113's field rules is reset with PROTOCOL_ERROR by moonhttp. Either
// way the request never reaches the Mocks, and the connection's other
// streams go on.

///|
/// The response on one stream as a test shows it, on one line: the status,
/// the header fields, and how the stream ended.
fn H2Response::line(self : H2Response) -> String {
  let fields = self.headers.map(header => shown_field(header.0, header.1))
  "\{self.status} [\{fields.join(", ")}] \{self.body.length()} octets, \{self.ended}"
}

///|
async test "h2c: a stream whose request HTTP/1.1 would refuse gets 400 on its stream alone, with no connection field, and the next stream on the connection is served" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let orders = "orders.example.com"
      let out = []
      for
        case in [
          ("a :path with a space", "GET", "/x y", Some(orders), []),
          ("a :path with a control octet", "GET", "/x\u{01}", Some(orders), []),
          ("a :path with DEL", "GET", "/x\u{7f}", Some(orders), []),
          (
            "a :path with an octet above 0x7E",
            "GET",
            "/caf\u{e9}",
            Some(orders),
            [],
          ),
          ("a :path with a fragment", "GET", "/x#top", Some(orders), []),
          (
            "an absolute-form :path",
            "GET",
            "http://orders.example.com/x",
            Some(orders),
            [],
          ),
          ("a :path of * with GET", "GET", "*", Some(orders), []),
          ("a method that is not a token", "GE T", "/x", Some(orders), []),
          (
            "an :authority that is not a Host value",
            "GET",
            "/x",
            Some("orders.example.com:http"),
            [],
          ),
          (
            "two host fields",
            "GET",
            "/x",
            None,
            [("host", orders), ("host", orders)],
          ),
          (
            "a host field that is not a Host value",
            "GET",
            "/x",
            None,
            [("host", "orders.example.com:http")],
          ),
          (
            "a host field that names another host than :authority",
            "GET",
            "/x",
            Some(orders),
            [("host", "users.example.com")],
          ),
          (
            "a host field that names the host of :authority in another case, with a port and a trailing dot",
            "GET",
            "/x",
            Some(orders),
            [("host", "ORDERS.Example.com.:8080")],
          ),
          (
            "a field name that is not a token",
            "GET",
            "/x",
            Some(orders),
            [("x(note)", "1")],
          ),
          (
            "a field value with 0x01",
            "GET",
            "/x",
            Some(orders),
            [("x-note", "a\u{01}b")],
          ),
          (
            "a field value with DEL",
            "GET",
            "/x",
            Some(orders),
            [("x-note", "a\u{7f}b")],
          ),
          (
            "a field value with a tab and characters beyond ASCII inside",
            "GET",
            "/x",
            Some(orders),
            [("x-note", "a\tcaf\u{e9}")],
          ),
          ("then a request HTTP/1.1 takes", "GET", "/x", Some(orders), []),
        ] {
        let (label, meth, path, authority, headers) = case
        let response = client.request(meth, path, authority?, headers~)
        out.push("\{label}: \{response.line()}")
      }
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      out.push("Journal entries: \{entries.length()}")
      inspect(
        out.join("\n"),
        content=(
          #|a :path with a space: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with a control octet: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with DEL: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with an octet above 0x7E: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with a fragment: 400 [date: <now>, content-length: 0] 0 octets, end
          #|an absolute-form :path: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path of * with GET: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a method that is not a token: 400 [date: <now>, content-length: 0] 0 octets, end
          #|an :authority that is not a Host value: 400 [date: <now>, content-length: 0] 0 octets, end
          #|two host fields: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a host field that is not a Host value: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a host field that names another host than :authority: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a host field that names the host of :authority in another case, with a port and a trailing dot: 200 [date: <now>, content-length: 11] 11 octets, end
          #|a field name that is not a token: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a field value with 0x01: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a field value with DEL: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a field value with a tab and characters beyond ASCII inside: 200 [date: <now>, content-length: 11] 11 octets, end
          #|then a request HTTP/1.1 takes: 200 [date: <now>, content-length: 11] 11 octets, end
          #|Journal entries: 3
        ),
      )
    })
  })
}

///|
async test "h2c: a 400 sent while the request still arrives is followed by RST_STREAM PROTOCOL_ERROR, frames that later arrive on that stream are ignored, a request that has ended gets the 400 alone, and the next stream is served" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("POST", "/upload x", "localhost")),
          end_stream=false,
        ),
        Data(stream_id=1, data=b"abc", end_stream=false, padding=0),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push("A request whose HEADERS do not end the stream:")
      out.push(raw.frames_until_ping_ack())
      raw.send([
        Data(stream_id=1, data=b"def", end_stream=false, padding=0),
        headers_frame(1, raw.block([("x-checksum", "abcdef")])),
        headers_frame(
          3,
          raw.block(request_fields("GET", "/upload x", "localhost")),
        ),
        headers_frame(
          5,
          raw.block(request_fields("POST", "/upload", "localhost")),
        ),
      ])
      out.push(
        "Then more of stream 1, a request whose HEADERS end the stream, and one HTTP/1.1 takes:",
      )
      out.push(raw.frames_until_stream_ends(5))
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      let shown = entries.map(entry => {
        guard entry is Object({ "request": Object(request), .. }) else {
          return entry.stringify()
        }
        "\{request.get("method").unwrap().stringify()} \{request.get("target").unwrap().stringify()}"
      })
      out.push("Journal: \{shown.join(", ")}")
      inspect(
        out.join("\n"),
        content=(
          #|A request whose HEADERS do not end the stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
          #|RST_STREAM 1 PROTOCOL_ERROR
          #|Then more of stream 1, a request whose HEADERS end the stream, and one HTTP/1.1 takes:
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
          #|HEADERS 5 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 5 END_STREAM 6 octets
          #|Journal: "POST" "/upload"
        ),
      )
    })
  })
}

///|
async test "h2c: a stream refused with 400 counts as rejected traffic, with mock=\"\" and stub=\"\", and is not journaled, while a stream moonhttp resets, such as HEADERS that end the stream with content-length: 5, has no status, no Journal entry, no Scenario move and no metric" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let pay = request_fields("POST", "/orders/42/pay", "localhost")
      pay.push(("content-length", "5"))
      let pay_malformed = request_fields(
        "POST", "/orders/42/pay x", "localhost",
      )
      pay_malformed.push(("content-length", "5"))
      let pay_upper_case = request_fields("POST", "/orders/42/pay", "localhost")
      pay_upper_case.push(("X-Note", "1"))
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("GET", "/orders/42 x", "localhost")),
        ),
        headers_frame(3, raw.block(pay)),
        headers_frame(5, raw.block(pay_malformed)),
        headers_frame(7, raw.block(pay_upper_case)),
        headers_frame(
          9,
          raw.block(request_fields("GET", "/orders/42", "localhost")),
        ),
      ])
      let out = [raw.frames_until_stream_ends(9)]
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      let shown = entries.map(entry => {
        guard entry is Object({ "request": Object(request), .. }) else {
          return entry.stringify()
        }
        "\{request.get("method").unwrap().stringify()} \{request.get("target").unwrap().stringify()}"
      })
      out.push("Journal: \{shown.join(", ")}")
      let (text, samples) = smock.metrics()
      out.push(traffic(text, samples))
      for line in text.split("\n") {
        if line.strip_prefix("# HELP ") is Some(rest) &&
          is_traffic(rest.split(" ").next().unwrap_or("").to_owned()) {
          out.push(line.to_owned())
        }
      }
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
          #|RST_STREAM 3 PROTOCOL_ERROR
          #|RST_STREAM 5 PROTOCOL_ERROR
          #|RST_STREAM 7 PROTOCOL_ERROR
          #|HEADERS 9 END_HEADERS [:status: 200, content-type: application/json, smock-mock: payments; via=default, date: <now>, content-length: 20]
          #|DATA 9 END_STREAM 20 octets
          #|Journal: "GET" "/orders/42"
          #|# TYPE smock_requests_total counter
          #|# TYPE smock_request_duration_seconds histogram
          #|# TYPE smock_unmatched_requests_total counter
          #|smock_request_duration_seconds_count{mock="",stub=""} 1
          #|smock_request_duration_seconds_count{mock="payments",stub="order-pending"} 1
          #|smock_requests_total{mock="",stub=""} 1
          #|smock_requests_total{mock="payments",stub="order-pending"} 1
          #|labels of smock_requests_total: mock, stub
          #|labels of smock_request_duration_seconds_bucket: mock, stub, le
          #|labels of smock_request_duration_seconds_sum: mock, stub
          #|labels of smock_request_duration_seconds_count: mock, stub
          #|# HELP smock_requests_total Requests served on the plain and TLS ports, by the Mock that answered (mock="" for none) and the Stub that matched: its ID for a Stub from a Definition file, stub="ephemeral" for every Ephemeral Stub, stub="" for none. A request the protocol layer rejects (HTTP/1.1: 400, 413, 431, 501, 505; HTTP/2: 400, 413, 431 on its stream) counts with mock="" and stub="".
          #|# HELP smock_request_duration_seconds Time from a request being read in full to the last byte of its response being written, injected delays and Server-Sent Event streams included, in seconds, labelled as smock_requests_total. For a request the protocol layer rejects (HTTP/1.1: 400, 413, 431, 501, 505; HTTP/2: 400, 413, 431 on its stream), the time runs from the read that brought what it rejects.
          #|# HELP smock_unmatched_requests_total Requests served on the plain and TLS ports that matched no Stub, by the Mock that answered them (mock="" for a Host no Mock answers). A request the protocol layer rejects (HTTP/1.1: 400, 413, 431, 501, 505; HTTP/2: 400, 413, 431 on its stream) is not among them.
        ),
      )
    })
  })
}
