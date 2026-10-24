// Seam 2 tests of the client stream IDs an HTTP/2 connection has used, sent
// as raw frames: HEADERS on a stream ID already used end the connection,
// unless this side reset that stream, and then they are ignored. These are
// the shapes of h2spec's http2/5.1.1/2 and http2/5.1/12.

///|
/// The fields of a request with the method `meth` for `path` to
/// `authority`.
fn request_fields(
  meth : String,
  path : String,
  authority : String,
) -> Array[(String, String)] {
  [
    (":method", meth),
    (":scheme", "http"),
    (":path", path),
    (":authority", authority),
  ]
}

///|
/// The fields of a request for `GET /x` to `orders.example.com`.
let get_x : Array[(String, String)] = request_fields(
  "GET", "/x", "orders.example.com",
)

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
        "A stream whose field block came in HEADERS and CONTINUATION",
        raw => {
          let block = raw.block(get_x)
          [
            Headers(
              stream_id=1,
              fragment=block[:4].to_owned(),
              end_stream=true,
              end_headers=false,
              priority=None,
              padding=0,
            ),
            Continuation(
              stream_id=1,
              fragment=block[4:].to_owned(),
              end_headers=true,
            ),
          ]
        },
        1,
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
          #|A stream whose field block came in HEADERS and CONTINUATION:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 11]
          #|DATA 1 END_STREAM 11 octets
          #|GOAWAY last=1 PROTOCOL_ERROR
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

///|
async test "h2c: HEADERS on a stream still open are its trailers, and the stream is answered" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let upload = request_fields("POST", "/upload", "localhost")
      raw.send([
        headers_frame(1, raw.block(upload), end_stream=false),
        Data(stream_id=1, data=b"abc", end_stream=false, padding=0),
        headers_frame(1, raw.block([("x-checksum", "abc")])),
        headers_frame(3, raw.block(upload)),
      ])
      inspect(
        raw.frames_until_stream_ends(3),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 1 END_STREAM 6 octets
          #|HEADERS 3 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 3 END_STREAM 6 octets
        ),
      )
    })
  })
}

///|
async test "h2c: HEADERS on a stream that a reset Fault ended are ignored, and the connection serves the next stream" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("GET", "/reset", "localhost")),
        ),
        headers_frame(1, raw.block(request_fields("GET", "/fast", "localhost"))),
        headers_frame(3, raw.block(request_fields("GET", "/fast", "localhost"))),
      ])
      inspect(
        raw.frames_until_stream_ends(3),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|RST_STREAM 1 INTERNAL_ERROR
          #|HEADERS 3 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 3 END_STREAM 4 octets
        ),
      )
    })
  })
}

///|
async test "h2c: smock remembers the last 256 streams it reset: HEADERS on the oldest of them are ignored, and HEADERS on one reset before them end the connection" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let reset = request_fields("GET", "/reset", "localhost")
      let fast = request_fields("GET", "/fast", "localhost")
      // Streams 1 to 513, each reset by its Fault.
      let frames = []
      for stream = 1; stream <= 513; stream = stream + 2 {
        frames.push(headers_frame(stream, raw.block(reset)))
      }
      frames.push(headers_frame(3, raw.block(fast)))
      frames.push(headers_frame(515, raw.block(fast)))
      frames.push(headers_frame(1, raw.block(fast)))
      raw.send(frames)
      let out = []
      let mut resets = 0
      while raw.read_frame() is Some(frame) {
        if frame is RstStream(error_code=0x2, ..) {
          resets += 1
        } else {
          out.push(raw.render_frame(frame))
        }
      }
      out.push("closed")
      out.push("RST_STREAM INTERNAL_ERROR on \{resets} streams")
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 515 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 515 END_STREAM 4 octets
          #|GOAWAY last=515 PROTOCOL_ERROR
          #|closed
          #|RST_STREAM INTERNAL_ERROR on 257 streams
        ),
      )
    })
  })
}
