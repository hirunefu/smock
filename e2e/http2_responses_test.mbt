// Seam 2 tests of the responses smock writes on an HTTP/2 stream, over h2c:
// a Stub's status, headers and body adapted to HTTP/2's rules, framed as
// HTTP/1.1 frames them, compared with the same Stub's HTTP/1.1 response.

///|
/// A Mock that answers every Host, with a Stub whose headers HTTP/2 must
/// adapt: names in mixed case, a value with spaces and a tab around it, and
/// the fields HTTP/2 forbids in a response.
let adapted_headers : String =
  #|{ "mocks": [{ "name": "shop", "hosts": ["localhost"] }],
  #|  "stubs": [{ "id": "page", "mock": "shop",
  #|    "request": { "method": "GET", "path": "/page" },
  #|    "response": { "status": 200,
  #|      "headers": { "Cache-Control": "no-cache", "X-Request-Id": "  abc \t",
  #|        "Keep-Alive": "timeout=5", "Upgrade": "websocket",
  #|        "Proxy-Connection": "keep-alive", "TE": "trailers",
  #|        "X-Empty": " " },
  #|      "body": "page" } }] }

///|
async test "h2c: a Stub's header names go out in lower case, its values trimmed of spaces and tabs, and the fields HTTP/2 forbids in a response left out, where HTTP/1.1 sends them as written" {
  with_definitions([("shop.json", adapted_headers)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let h2 = client.request("GET", "/page", authority="localhost")
      let conn = smock.connect()
      defer conn.close()
      conn.write(raw_request("GET", "/page", host="localhost"))
      inspect(
        "\{h2.render()}\n---\n\{read_response(conn).escape()}",
        content=(
          #|200
          #|cache-control: no-cache
          #|x-request-id: abc
          #|x-empty: 
          #|date: <now>
          #|content-length: 4
          #|
          #|page
          #|---
          #|"HTTP/1.1 200 OK\nCache-Control: no-cache\nX-Request-Id:   abc \t\nKeep-Alive: timeout=5\nUpgrade: websocket\nProxy-Connection: keep-alive\nTE: trailers\nX-Empty:  \nDate: <now>\nContent-Length: 4\n\npage"
        ),
      )
    })
  })
}

///|
/// A Mock that answers every Host, with Stubs that answer any method: 200
/// with a short body, 200 with a body file larger than the initial windows,
/// and 204 and 304, each with a body HTTP never sends.
fn framed_responses() -> Array[(String, String)] {
  [
    (
      "items.json",
      (
        #|{ "mocks": [{ "name": "items", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "item", "mock": "items", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "big", "mock": "items", "request": { "path": "/big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" } },
        #|    { "id": "gone", "mock": "items", "request": { "path": "/gone" },
        #|      "response": { "status": 204, "body": "never sent" } },
        #|    { "id": "cached", "mock": "items", "request": { "path": "/cached" },
        #|      "response": { "status": 304, "headers": { "ETag": "\"v1\"" },
        #|        "body": "never sent" } } ] }
      ),
    ),
    ("files/big.txt", "x".repeat(70_000)),
  ]
}

///|
/// Reads frames until the acknowledgement of a PING, and shows each frame
/// before it as `render_frame` does, one per line. smock answers frames in
/// order, so the frames of the streams the client ended before its PING
/// come first.
async fn RawH2::frames_until_ping_ack(self : RawH2) -> String {
  let out = []
  while self.read_frame() is Some(frame) {
    if frame is Ping(ack=true, ..) {
      return out.join("\n")
    }
    out.push(self.render_frame(frame))
  }
  out.push("closed")
  out.join("\n")
}

///|
async test "h2c: HEAD gets the headers with the length and no DATA, even for a body past the windows, 204 and 304 get neither, a GET gets both, and no response has a connection field or a PUSH_PROMISE" {
  with_definitions(framed_responses(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let frames = []
      for
        i, request in [
          ("HEAD", "/item"),
          ("GET", "/item"),
          ("HEAD", "/big"),
          ("GET", "/gone"),
          ("HEAD", "/gone"),
          ("GET", "/cached"),
        ] {
        frames.push(
          @http2.Frame::Headers(
            stream_id=2 * i + 1,
            fragment=raw.block([
              (":method", request.0),
              (":scheme", "http"),
              (":path", request.1),
              (":authority", "localhost"),
            ]),
            end_stream=true,
            end_headers=true,
            priority=None,
            padding=0,
          ),
        )
      }
      frames.push(Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false))
      raw.send(frames)
      inspect(
        raw.frames_until_ping_ack(),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM 5 octets
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 70000]
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 204, date: <now>]
          #|HEADERS 9 END_STREAM END_HEADERS [:status: 204, date: <now>]
          #|HEADERS 11 END_STREAM END_HEADERS [:status: 304, etag: "v1", date: <now>]
        ),
      )
    })
  })
}
