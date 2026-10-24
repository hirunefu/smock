// Seam 2 tests of the concurrent-streams limit of an HTTP/2 connection,
// `--http2-max-concurrent-streams`, sent as raw frames, since a client's
// `Conn` never opens a stream past the limit: smock advertises the limit in
// its SETTINGS and holds the client to it from the first stream, and a
// stream past it gets REFUSED_STREAM and never reaches the Mocks.

///|
/// Reads smock's SETTINGS, the first frame it sends on a connection,
/// acknowledges them, and shows them as `render_frame` does.
async fn RawH2::acknowledge_settings(self : RawH2) -> String {
  guard self.read_frame() is Some(Settings(ack=false, ..) as frame) else {
    fail("smock's SETTINGS did not come first")
  }
  self.send([Settings(params=[], ack=true)])
  self.render_frame(frame)
}

///|
/// The Journal's entries, one per line, as `<method> <target> <body>
/// <status>`.
async fn uploads_journaled(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "request": Object(
            {
              "method": String(meth),
              "target": String(target),
              "body": Object({ "data": String(body), .. }),
              ..
            }
          ),
          "status": status,
          ..
        }
      ) else {
      fail("an entry without a request: \{entry.stringify()}")
    }
    out.push("\{meth} \{target} \{body} \{status.stringify()}")
  }
  out.join("\n")
}

///|
async test "h2c: with --http2-max-concurrent-streams 3, three unfinished uploads hold the streams, a fourth gets REFUSED_STREAM and never reaches the Mocks, its later frames are ignored, and the three complete" {
  with_definitions([("files.json", uploads)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "3"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        let out = [raw.acknowledge_settings()]
        let upload = request_fields("POST", "/upload", "localhost")
        let refused = request_fields("POST", "/upload?refused", "localhost")
        raw.send([
          headers_frame(1, raw.block(upload), end_stream=false),
          headers_frame(3, raw.block(upload), end_stream=false),
          headers_frame(5, raw.block(upload), end_stream=false),
          headers_frame(7, raw.block(refused), end_stream=false),
          // Sent before the client learnt of the refusal, as a client
          // does: ignored.
          Data(stream_id=7, data=b"late", end_stream=false, padding=0),
          headers_frame(7, raw.block([("x-trailer", "late")])),
          Data(stream_id=1, data=b"one", end_stream=true, padding=0),
          Data(stream_id=3, data=b"three", end_stream=true, padding=0),
          Data(stream_id=5, data=b"five", end_stream=true, padding=0),
        ])
        out.push(raw.frames_until_stream_ends(5))
        // The three streams have ended, so a new one is served.
        raw.send([headers_frame(9, raw.block(upload))])
        out.push(raw.frames_until_stream_ends(9))
        out.push("Journal:")
        out.push(uploads_journaled(smock))
        inspect(
          out.join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=3, MAX_HEADER_LIST_SIZE=65536]
            #|SETTINGS ACK
            #|RST_STREAM 7 REFUSED_STREAM
            #|HEADERS 1 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
            #|DATA 1 END_STREAM 6 octets
            #|HEADERS 3 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
            #|DATA 3 END_STREAM 6 octets
            #|HEADERS 5 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
            #|DATA 5 END_STREAM 6 octets
            #|HEADERS 9 END_HEADERS [:status: 201, smock-mock: files; via=default, date: <now>, content-length: 6]
            #|DATA 9 END_STREAM 6 octets
            #|Journal:
            #|POST /upload one 201
            #|POST /upload three 201
            #|POST /upload five 201
            #|POST /upload  201
          ),
        )
      },
    )
  })
}
