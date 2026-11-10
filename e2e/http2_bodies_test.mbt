// Seam 2 tests of request bodies over HTTP/2, over h2c on the plain port:
// `--body-limit` applies per stream, so a body over it gets 413 on its
// stream alone, then RST_STREAM NO_ERROR while the client still sends it,
// and the connection's other streams go on. The DATA octets smock takes or
// discards are handed back, so the connection's one shared window stays
// open. A request that asks for `100 Continue` gets it, as on HTTP/1.1.

///|
/// The requests counted in `smock_requests_total`, one line per pair of
/// labels.
async fn requests_counted(smock : Smock) -> String {
  let (_, samples) = smock.metrics()
  let out = []
  for sample in samples {
    if sample.name == "smock_requests_total" {
      out.push(sample.line())
    }
  }
  out.sort()
  out.join("\n")
}

///|
/// The fields of an upload to `/upload` that declares a body of `length`
/// octets, followed by `more`.
fn upload_fields(
  length : Int32,
  more~ : Array[(String, String)] = [],
) -> Array[(String, String)] {
  let fields = request_fields("POST", "/upload", "localhost")
  fields.push(("content-length", length.to_string()))
  fields.append(more)
  fields
}

///|
async test "h2c: a content-length over --body-limit gets 413 at once, then RST_STREAM NO_ERROR, or 413 alone when the request has ended, frames that later arrive on that stream are ignored, the other streams go on, and the stream counts as rejected traffic with no Journal entry" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "10"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      raw.send([
        headers_frame(1, raw.block(upload_fields(11)), end_stream=false),
        // An upload in progress beside it.
        headers_frame(3, raw.block(upload_fields(3)), end_stream=false),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push("Uploads of 11 and 3 octets declared:")
      out.push(raw.frames_until_ping_ack())
      raw.send([
        // Sent before the client learnt of the 413, as a client does:
        // ignored.
        Data(stream_id=1, data=b"late", end_stream=false, padding=0),
        Data(stream_id=3, data=b"abc", end_stream=true, padding=0),
      ])
      out.push("More of stream 1, and the rest of stream 3:")
      out.push(raw.frames_until_stream_ends(3))
      raw.send([
        headers_frame(5, raw.block(upload_fields(10)), end_stream=false),
        Data(stream_id=5, data=b"0123456789", end_stream=true, padding=0),
      ])
      out.push("An upload of 10 octets, the limit:")
      out.push(raw.frames_until_stream_ends(5))
      raw.send([headers_frame(7, raw.block(upload_fields(11)))])
      out.push(
        "HEADERS that end the stream and declare 11 octets, which moonhttp resets first, since no body follows:",
      )
      out.push(raw.frames_until_stream_ends(7))
      let huge = request_fields("POST", "/upload", "localhost")
      huge.push(("content-length", "4294967296"))
      raw.send([headers_frame(9, raw.block(huge))])
      // moonhttp 0.14.0 reads that length in 32 bits, as 0, so it lets
      // the stream end with no body; smock reads it as sent.
      out.push(
        "HEADERS that end the stream and declare 2^32 octets, a request that has ended:",
      )
      out.push(raw.frames_until_stream_ends(9))
      out.push("Journal:")
      out.push(uploads_journaled(smock))
      out.push(requests_counted(smock))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|Uploads of 11 and 3 octets declared:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 1 NO_ERROR
          #|More of stream 1, and the rest of stream 3:
          #|HEADERS 3 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 3 END_STREAM 6 octets
          #|An upload of 10 octets, the limit:
          #|HEADERS 5 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 5 END_STREAM 6 octets
          #|HEADERS that end the stream and declare 11 octets, which moonhttp resets first, since no body follows:
          #|RST_STREAM 7 PROTOCOL_ERROR
          #|HEADERS that end the stream and declare 2^32 octets, a request that has ended:
          #|HEADERS 9 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|Journal:
          #|POST /upload abc 201
          #|POST /upload 0123456789 201
          #|smock_requests_total{mock="",stub=""} 2
          #|smock_requests_total{mock="files",stub="upload"} 2
        ),
      )
    })
  })
}

///|
async test "h2c: a body that passes --body-limit gets 413, then RST_STREAM NO_ERROR, or 413 alone when the DATA that passes it ends the stream, while the other streams go on" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "10"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      let upload = request_fields("POST", "/upload", "localhost")
      raw.send([
        headers_frame(1, raw.block(upload), end_stream=false),
        headers_frame(3, raw.block(upload), end_stream=false),
        Data(stream_id=1, data=b"abcdef", end_stream=false, padding=0),
        Data(stream_id=3, data=b"0123", end_stream=false, padding=0),
        Data(stream_id=1, data=b"ghijkl", end_stream=false, padding=0),
        Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
      ])
      out.push(
        "Two uploads with no content-length, the first past the limit by its second DATA:",
      )
      out.push(raw.frames_until_ping_ack())
      raw.send([
        // Sent before the client learnt of the 413, as a client does:
        // ignored.
        Data(stream_id=1, data=b"late", end_stream=true, padding=0),
        Data(stream_id=3, data=b"456789", end_stream=true, padding=0),
      ])
      out.push("More of stream 1, and the rest of stream 3, the limit:")
      out.push(raw.frames_until_stream_ends(3))
      raw.send([
        headers_frame(5, raw.block(upload), end_stream=false),
        Data(stream_id=5, data=b"0123456789a", end_stream=true, padding=0),
      ])
      out.push("An upload whose one DATA passes the limit and ends it:")
      out.push(raw.frames_until_stream_ends(5))
      out.push("Journal:")
      out.push(uploads_journaled(smock))
      out.push(requests_counted(smock))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|Two uploads with no content-length, the first past the limit by its second DATA:
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 1 NO_ERROR
          #|More of stream 1, and the rest of stream 3, the limit:
          #|HEADERS 3 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 3 END_STREAM 6 octets
          #|An upload whose one DATA passes the limit and ends it:
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|Journal:
          #|POST /upload 0123456789 201
          #|smock_requests_total{mock="",stub=""} 2
          #|smock_requests_total{mock="files",stub="upload"} 1
        ),
      )
    })
  })
}

///|
/// A raw connection that keeps to the connection's flow-control window, as
/// a client must: it sends DATA only within the window, and reads smock's
/// frames, WINDOW_UPDATE among them, while the window is shut. So it waits
/// for good if smock does not hand back what it takes.
struct Uploader {
  raw : RawH2
  /// The DATA octets the connection's window still allows.
  mut window : Int32
  /// The DATA octets sent.
  mut sent : Int32
  /// The octets smock handed back to the connection's window.
  mut handed_back : Int32
  /// The frames read, as `render_frame` shows them, without WINDOW_UPDATE.
  frames : Array[String]
}

///|
/// An uploader on `raw`, whose window is RFC 9113's initial 65,535 octets.
fn Uploader::new(raw : RawH2) -> Uploader {
  { raw, window: 65535, sent: 0, handed_back: 0, frames: [], }
}

///|
/// Reads the next frame from smock: a WINDOW_UPDATE of the connection
/// widens the window, and any frame other than a WINDOW_UPDATE is kept.
async fn Uploader::read(self : Uploader) -> @http2.Frame {
  guard self.raw.read_frame() is Some(frame) else {
    fail("smock closed the connection")
  }
  match frame {
    WindowUpdate(stream_id=0, increment~) => {
      self.window += increment
      self.handed_back += increment
    }
    WindowUpdate(..) => ()
    _ => self.frames.push(self.raw.render_frame(frame))
  }
  frame
}

///|
/// Reads frames until smock resets `stream`.
async fn Uploader::until_reset(self : Uploader, stream : Int32) -> Unit {
  for ;; {
    if self.read() is RstStream(stream_id~, ..) && stream_id == stream {
      return
    }
  }
}

///|
/// Reads frames until smock ends `stream` with END_STREAM.
async fn Uploader::until_ends(self : Uploader, stream : Int32) -> Unit {
  for ;; {
    match self.read() {
      Data(stream_id~, end_stream=true, ..)
      | Headers(stream_id~, end_stream=true, ..) if stream_id == stream =>
        return
      _ => ()
    }
  }
}

///|
/// Sends `size` octets of DATA on `stream`, in frames of at most 16,384
/// octets, the frame size smock allows, each once the window has room for
/// it. The last ends the stream when `end` is true.
async fn Uploader::data(
  self : Uploader,
  stream : Int32,
  size : Int32,
  end~ : Bool = false,
) -> Unit {
  let mut left = size
  while left > 0 {
    let n = if left < 16384 { left } else { 16384 }
    while self.window < n {
      self.read() |> ignore
    }
    self.raw.send([
      Data(
        stream_id=stream,
        data=Bytes::make(n, b'x'),
        end_stream=end && n == left,
        padding=0,
      ),
    ])
    self.window -= n
    self.sent += n
    left -= n
  }
}

///|
async test "h2c: on one connection, several uploads past --body-limit and one still arriving after a 400 are handed back to the connection's window, so a normal upload after them completes" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "10"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let up = Uploader::new(raw)
      up.frames.push(raw.acknowledge_settings())
      let upload = request_fields("POST", "/upload", "localhost")
      // Each upload past the limit sends three frames of 16,384 octets,
      // 49,152 in all, two of them after smock has answered. Four take
      // three times the connection's initial window.
      for stream in [1, 3] {
        // The body passes the limit by its first DATA.
        raw.send([headers_frame(stream, raw.block(upload), end_stream=false)])
        up.data(stream, 16384)
        up.until_reset(stream)
        up.data(stream, 2 * 16384, end=true)
      }
      // A content-length over the limit.
      raw.send([
        headers_frame(5, raw.block(upload_fields(49152)), end_stream=false),
      ])
      up.until_reset(5)
      up.data(5, 3 * 16384, end=true)
      // A malformed request.
      raw.send([
        headers_frame(
          7,
          raw.block(request_fields("POST", "/upload x", "localhost")),
          end_stream=false,
        ),
      ])
      up.until_reset(7)
      up.data(7, 3 * 16384, end=true)
      raw.send([headers_frame(9, raw.block(upload), end_stream=false)])
      up.data(9, 10, end=true)
      up.until_ends(9)
      up.frames.push(
        "\{up.sent} DATA octets sent, \{up.handed_back} handed back to the connection's window",
      )
      up.frames.push("Journal:")
      up.frames.push(uploads_journaled(smock))
      up.frames.push(requests_counted(smock))
      inspect(
        up.frames.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 1 NO_ERROR
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 3 NO_ERROR
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 5 NO_ERROR
          #|HEADERS 7 END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0]
          #|RST_STREAM 7 PROTOCOL_ERROR
          #|HEADERS 9 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 9 END_STREAM 6 octets
          #|196618 DATA octets sent, 196608 handed back to the connection's window
          #|Journal:
          #|POST /upload xxxxxxxxxx 201
          #|smock_requests_total{mock="",stub=""} 4
          #|smock_requests_total{mock="files",stub="upload"} 1
        ),
      )
    })
  })
}

///|
async test "h2c: a request whose HEADERS ask for 100-continue and do not end the stream gets 100, or 413 when its content-length is over --body-limit, and one that has no body to send gets its response alone" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0", "--body-limit", "10"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = [raw.acknowledge_settings()]
      let ping = @http2.Frame::Ping(
        payload=b"\x00\x00\x00\x00\x00\x00\x00\x01",
        ack=false,
      )
      let expect = [("expect", "100-continue")]
      raw.send([
        headers_frame(
          1,
          raw.block(upload_fields(6, more=expect)),
          end_stream=false,
        ),
        ping,
      ])
      out.push("A body of 6 octets declared:")
      out.push(raw.frames_until_ping_ack())
      raw.send([Data(stream_id=1, data=b"abcdef", end_stream=true, padding=0)])
      out.push("Then the body:")
      out.push(raw.frames_until_stream_ends(1))
      raw.send([
        headers_frame(
          3,
          raw.block(upload_fields(11, more=expect)),
          end_stream=false,
        ),
        ping,
      ])
      out.push("A body of 11 octets declared:")
      out.push(raw.frames_until_ping_ack())
      let unknown = request_fields("POST", "/upload", "localhost")
      unknown.append(expect)
      raw.send([headers_frame(5, raw.block(unknown), end_stream=false), ping])
      out.push("A body of no declared length:")
      out.push(raw.frames_until_ping_ack())
      raw.send([
        Data(stream_id=5, data=b"0123456789a", end_stream=false, padding=0),
        ping,
      ])
      out.push("Then a body of 11 octets:")
      out.push(raw.frames_until_ping_ack())
      raw.send([headers_frame(7, raw.block(upload_fields(0, more=expect)))])
      out.push("HEADERS that end the stream:")
      out.push(raw.frames_until_stream_ends(7))
      raw.send([
        headers_frame(
          9,
          raw.block(upload_fields(0, more=expect)),
          end_stream=false,
        ),
        ping,
      ])
      out.push(
        "A body of 0 octets declared, which gets no 100, as on HTTP/1.1:",
      )
      let frames = raw.frames_until_ping_ack()
      out.push(if frames.is_empty() { "(no frame)" } else { frames })
      raw.send([Data(stream_id=9, data=b"", end_stream=true, padding=0)])
      out.push("Then the end of the stream:")
      out.push(raw.frames_until_stream_ends(9))
      out.push("Journal:")
      out.push(uploads_journaled(smock))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|A body of 6 octets declared:
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 100]
          #|Then the body:
          #|HEADERS 1 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 1 END_STREAM 6 octets
          #|A body of 11 octets declared:
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 3 NO_ERROR
          #|A body of no declared length:
          #|HEADERS 5 END_HEADERS [:status: 100]
          #|Then a body of 11 octets:
          #|HEADERS 5 END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0]
          #|RST_STREAM 5 NO_ERROR
          #|HEADERS that end the stream:
          #|HEADERS 7 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 7 END_STREAM 6 octets
          #|A body of 0 octets declared, which gets no 100, as on HTTP/1.1:
          #|(no frame)
          #|Then the end of the stream:
          #|HEADERS 9 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
          #|DATA 9 END_STREAM 6 octets
          #|Journal:
          #|POST /upload abcdef 201
          #|POST /upload  201
          #|POST /upload  201
        ),
      )
    })
  })
}
