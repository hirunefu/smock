// Seam 2 tests of HTTP/2 on the plain port by prior knowledge (h2c): the
// preface check, the mapping of a stream onto the engine's request, the
// response written on the stream, and what stays HTTP/1.1.

///|
async test "h2c: a request is answered by the Stub of the Mock its :authority names, and is in the Journal as HTTP/2, with its target and Host and no pseudo-header fields, once the response is read" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for host in ["orders.example.com", "users.example.com"] {
        let response = client.request("GET", "/x?a=1", authority=host, headers=[
          ("accept", "text/plain"),
        ])
        out.push(response.render())
        let (status, journal) = smock.journal()
        out.push("journal: \{status}")
        guard journal is Object({ "entries": Array(entries), .. }) else {
          fail("no entries: \{journal.stringify()}")
        }
        out.push(journal_shown(entries[entries.length() - 1]).stringify())
      }
      inspect(
        out.join("\n"),
        content=(
          #|200
          #|date: <now>
          #|content-length: 11
          #|
          #|from orders
          #|journal: 200
          #|{"seq":1,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"orders.example.com","mock":"orders","viaDefault":false,"digest":"<digest>","request":{"method":"GET","target":"/x?a=1","version":"HTTP/2","headers":[{"name":"accept","value":"text/plain"}],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"orders-x","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}
          #|200
          #|date: <now>
          #|content-length: 10
          #|
          #|from users
          #|journal: 200
          #|{"seq":2,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"users.example.com","mock":"users","viaDefault":false,"digest":"<digest>","request":{"method":"GET","target":"/x?a=1","version":"HTTP/2","headers":[{"name":"accept","value":"text/plain"}],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"users-x","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}
        ),
      )
    })
  })
}

///|
/// A Mock that answers every Host, with a Stub that takes uploads.
let uploads : String =
  #|{ "mocks": [{ "name": "files" }],
  #|  "stubs": [{ "id": "upload", "mock": "files",
  #|    "request": { "method": "POST", "path": "/upload" },
  #|    "response": { "status": 201, "body": "stored" } }] }

///|
async test "h2c: a request body larger than the initial windows arrives in full, since smock hands back the DATA octets it takes" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let body = Bytes::make(100_000, b'a')
      let response = client.request(
        "POST",
        "/upload",
        authority="localhost",
        body~,
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object(
          {
            "entries": [
              Object({ "request": Object({ "body": Object(body), .. }), .. }),
            ],
            ..
          }
        ) else {
        fail("not one entry: \{journal.stringify()}")
      }
      inspect(
        "\{response.render()}\nsize in the Journal: \{body.get("size").unwrap().stringify()}",
        content=(
          #|201
          #|smock-mock: files; via=default
          #|date: <now>
          #|content-length: 6
          #|
          #|stored
          #|size in the Journal: 100000
        ),
      )
    })
  })
}

///|
async test "h2c: a preface split across reads is still HTTP/2" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c(preface_in=5)
      defer client.close()
      let response = client.request("GET", "/x", authority="orders.example.com")
      inspect(
        response.render(),
        content=(
          #|200
          #|date: <now>
          #|content-length: 11
          #|
          #|from orders
        ),
      )
    })
  })
}

///|
async test "h2c: a near-preface, any other first octets and Upgrade: h2c stay HTTP/1.1 on the plain port, and the preface on the admin port gets 505" {
  with_definitions([("users.json", any_method)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let exchange = async fn(label : String, parts : Array[String]) {
        let conn = smock.connect()
        defer conn.close()
        for i, part in parts {
          if i > 0 {
            @async.sleep(50)
          }
          conn.write(part)
        }
        out.push("\{label}: \{status_line(read_response(conn))}")
      }
      // Proper prefixes of the preface, then octets that differ: the HTTP/1.1
      // codec answers them, here refusing PRI with an asterisk-form target,
      // which only OPTIONS may have.
      exchange("PRI * HTTP/1.1, in two reads", [
        "PRI * HTTP/", "1.1\r\nHost: localhost\r\n\r\n",
      ])
      exchange("the preface with its last octet changed", [
        "PRI * HTTP/2.0\r\n\r\nSM\r\n\r", "X",
      ])
      // Requests whose first octet is P, and any other.
      exchange("PUT", ["PUT /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"])
      exchange("POST", [
        "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
      ])
      exchange("GET", ["GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"])
      // The upgrade is ignored, and the connection stays HTTP/1.1.
      let conn = smock.connect()
      defer conn.close()
      conn.write(
        "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n",
      )
      out.push("Upgrade: h2c: \{status_line(read_response(conn))}")
      conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
      out.push(
        "then on the same connection: \{status_line(read_response(conn))}",
      )
      // The admin port never looks for the preface.
      let admin = PlainConn(
        @socket.Tcp::connect(
          @socket.Addr::parse("127.0.0.1:\{smock.admin_port}"),
        ),
      )
      defer admin.close()
      admin.write(
        @http2.preface + @http2.Frame::Settings(params=[], ack=false).encode(),
      )
      let response = read_response(admin)
      let body = response[response.find("\n\n").unwrap() + 2:]
      out.push(
        "the preface on the admin port: \{status_line(response)}, \{body}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|PRI * HTTP/1.1, in two reads: HTTP/1.1 400 Bad Request
          #|the preface with its last octet changed: HTTP/1.1 505 HTTP Version Not Supported
          #|PUT: HTTP/1.1 200 OK
          #|POST: HTTP/1.1 200 OK
          #|GET: HTTP/1.1 200 OK
          #|Upgrade: h2c: HTTP/1.1 200 OK
          #|then on the same connection: HTTP/1.1 200 OK
          #|the preface on the admin port: HTTP/1.1 505 HTTP Version Not Supported, {"error":"http_version_not_supported","message":"the request is not HTTP/1.0 or HTTP/1.1","warnings":[]}
        ),
      )
    })
  })
}

///|
async test "h2c: a lone P, and a proper prefix of the preface, then a stall, are cut at the read timeout, which runs from the first octet" {
  with_definitions([("users.json", any_method)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "300", "--idle-timeout-ms",
        "10000",
      ],
      smock => {
        let out = []
        for first in ["P", "PRI * HTTP/2.0\r\n\r\nSM\r\n"] {
          let conn = smock.connect()
          defer conn.close()
          let since = @async.now()
          conn.write(first)
          let (elapsed, rest) = ended(conn, since)
          out.push(
            "\{first.escape()}: \{rest.escape()}, ended after at least 300 ms: \{elapsed >= 300}, long before the idle timeout: \{elapsed < 5000}",
          )
        }
        inspect(
          out.join("\n"),
          content=(
            #|"P": "", ended after at least 300 ms: true, long before the idle timeout: true
            #|"PRI * HTTP/2.0\r\n\r\nSM\r\n": "", ended after at least 300 ms: true, long before the idle timeout: true
          ),
        )
      },
    )
  })
}

///|
async test "h2c: a stream the client resets after HEADERS and part of its body never reaches the engine: no Journal entry, and its Scenario does not move" {
  with_definitions([("payments.json", checkout)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let pay = client.send(
        "POST",
        "/orders/42/pay",
        authority="localhost",
        headers=[("content-length", "10")],
        body=b"01234",
        end=false,
      )
      client.conn.reset(pay, code=@http2.error_cancel)
      client.flush()
      let order = client.request("GET", "/orders/42", authority="localhost")
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
      inspect(
        "\{order.render()}\nJournal: \{shown.join(", ")}",
        content=(
          #|200
          #|content-type: application/json
          #|smock-mock: payments; via=default
          #|date: <now>
          #|content-length: 20
          #|
          #|{"status":"pending"}
          #|Journal: "GET" "/orders/42"
        ),
      )
    })
  })
}

///|
async test "h2c: a frame larger than the 16,384 octets smock advertises ends the connection with GOAWAY FRAME_SIZE_ERROR, after the streams before it are answered" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let request = raw.block([
        (":method", "GET"),
        (":scheme", "http"),
        (":path", "/x"),
        (":authority", "orders.example.com"),
      ])
      raw.send([
        Headers(
          stream_id=1,
          fragment=request,
          end_stream=true,
          end_headers=true,
          priority=None,
          padding=0,
        ),
      ])
      let head : @http2.FrameHeader = {
        length: 16385,
        ftype: @http2.frame_headers,
        flags: @http2.flag_end_headers,
        stream_id: 3,
      }
      raw.send_bytes(head.encode())
      inspect(
        raw.frames_until_end(),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 11]
          #|DATA 1 END_STREAM 11 octets
          #|GOAWAY last=1 FRAME_SIZE_ERROR
          #|closed
        ),
      )
    })
  })
}

///|
async test "h2c: requests are counted in the request metrics with the same mock and stub labels as over HTTP/1.1" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for
        request in [
          ("orders.example.com", "/x"),
          ("users.example.com", "/x"),
          ("users.example.com", "/nope"),
          ("elsewhere.example.com", "/x"),
        ] {
        let (host, path) = request
        let response = client.request("GET", path, authority=host)
        out.push("\{host}\{path}: \{response.status}")
      }
      let (text, samples) = smock.metrics()
      out.push(traffic(text, samples))
      inspect(
        out.join("\n"),
        content=(
          #|orders.example.com/x: 200
          #|users.example.com/x: 200
          #|users.example.com/nope: 404
          #|elsewhere.example.com/x: 404
          #|# TYPE smock_requests_total counter
          #|# TYPE smock_request_duration_seconds histogram
          #|# TYPE smock_unmatched_requests_total counter
          #|smock_request_duration_seconds_count{mock="",stub=""} 1
          #|smock_request_duration_seconds_count{mock="orders",stub="orders-x"} 1
          #|smock_request_duration_seconds_count{mock="users",stub=""} 1
          #|smock_request_duration_seconds_count{mock="users",stub="users-x"} 1
          #|smock_requests_total{mock="",stub=""} 1
          #|smock_requests_total{mock="orders",stub="orders-x"} 1
          #|smock_requests_total{mock="users",stub=""} 1
          #|smock_requests_total{mock="users",stub="users-x"} 1
          #|smock_unmatched_requests_total{mock=""} 1
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
