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
async test "h2c: a content-length over --body-limit gets 413 at once, then RST_STREAM NO_ERROR, frames that later arrive on that stream are ignored, the other streams go on, and the stream counts as rejected traffic with no Journal entry" {
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
      out.push("Journal:")
      out.push(uploads_journaled(smock))
      out.push(requests_counted(smock))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
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
          #|Journal:
          #|POST /upload abc 201
          #|POST /upload 0123456789 201
          #|smock_requests_total{mock="",stub=""} 1
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
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
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
