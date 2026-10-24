// Seam 2 tests of the client stream IDs an HTTP/2 connection has used, sent
// as raw frames: HEADERS on a stream ID already used end the connection,
// unless this side reset that stream, and then they are ignored. These are
// the shapes of h2spec's http2/5.1.1/2 and http2/5.1/12.

///|
/// The fields of a request for `GET /x` to `orders.example.com`.
let get_x : Array[(String, String)] = [
  (":method", "GET"),
  (":scheme", "http"),
  (":path", "/x"),
  (":authority", "orders.example.com"),
]

///|
/// A HEADERS frame on `stream` that carries all of `block`, and ends the
/// stream unless `end_stream` is false.
fn headers_frame(
  stream : Int32,
  block : Bytes,
  end_stream~ : Bool = true,
) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment=block,
    end_stream~,
    end_headers=true,
    priority=None,
    padding=0,
  )
}

///|
async test "h2c: HEADERS on a stream ID already used, whose stream smock did not reset, end the connection with GOAWAY PROTOCOL_ERROR, and a fresh connection is served" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // Sends the frames `first` makes, then HEADERS on the stream `reused`.
      let reuse = async fn(
        label : String,
        first : (RawH2) -> Array[@http2.Frame],
        reused : Int32,
      ) {
        let raw = smock.raw_h2()
        defer raw.close()
        raw.send(first(raw))
        raw.send([headers_frame(reused, raw.block(get_x))])
        out.push("\{label}:")
        out.push(raw.frames_until_end())
        let client = smock.h2c()
        defer client.close()
        let response = client.request(
          "GET",
          "/x",
          authority="orders.example.com",
        )
        out.push(
          "then a fresh connection: \{response.status} \{response.ended}",
        )
      }
      reuse(
        "A stream that ended with its response (http2/5.1/12)",
        raw => [headers_frame(1, raw.block(get_x))],
        1,
      )
      reuse(
        "A stream ID below the highest seen, never opened (http2/5.1.1/2)",
        raw => [headers_frame(5, raw.block(get_x))],
        3,
      )
      reuse(
        "A stream the client reset",
        raw => {
          [
            headers_frame(1, raw.block(get_x), end_stream=false),
            RstStream(stream_id=1, error_code=@http2.error_cancel),
          ]
        },
        1,
      )
      inspect(
        out.join("\n"),
        content=(
          #|A stream that ended with its response (http2/5.1/12):
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 11]
          #|DATA 1 END_STREAM 11 octets
          #|GOAWAY last=1 PROTOCOL_ERROR
          #|closed
          #|then a fresh connection: 200 end
          #|A stream ID below the highest seen, never opened (http2/5.1.1/2):
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 11]
          #|DATA 5 END_STREAM 11 octets
          #|GOAWAY last=5 PROTOCOL_ERROR
          #|closed
          #|then a fresh connection: 200 end
          #|A stream the client reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|GOAWAY last=1 PROTOCOL_ERROR
          #|closed
          #|then a fresh connection: 200 end
        ),
      )
    })
  })
}

///|
async test "h2c: HEADERS on a stream that moonhttp refused at open, or reset after its HEADERS, for a field rule are ignored, and the connection serves the next stream" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      // A field name in upper case: refused at open, with no event.
      let upper_case = get_x.copy()
      upper_case.push(("Accept", "text/plain"))
      // A content-length the body does not match: reset after the `Request`
      // event, with a `Reset` event.
      let too_long = get_x.copy()
      too_long.push(("content-length", "5"))
      raw.send([
        headers_frame(1, raw.block(upper_case)),
        headers_frame(1, raw.block(get_x)),
        headers_frame(3, raw.block(too_long)),
        headers_frame(3, raw.block(get_x)),
        headers_frame(5, raw.block(get_x)),
      ])
      inspect(
        raw.frames_until_stream_ends(5),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|RST_STREAM 1 PROTOCOL_ERROR
          #|RST_STREAM 3 PROTOCOL_ERROR
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 11]
          #|DATA 5 END_STREAM 11 octets
        ),
      )
    })
  })
}
