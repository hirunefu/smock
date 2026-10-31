// Seam 2 tests of the defence against CONTINUATION floods over h2c, sent as
// raw frames with moonhttp's frame encoder: a header block, its HEADERS and
// CONTINUATION frames, is held to moonhttp's bound as received, twice
// `--header-size-limit`, and must end within the read timeout; empty
// CONTINUATION frames count as frames that do no work. Each test checks what
// the client receives, the log line, and that a fresh connection is served
// right after.

///|
/// A CONTINUATION frame on `stream` with no octets, which ends its header
/// block when `end_headers` is true.
fn empty_continuation(
  stream : Int32,
  end_headers~ : Bool = false,
) -> @http2.Frame {
  Continuation(stream_id=stream, fragment=b"", end_headers~)
}

///|
/// A HEADERS frame on `stream` that begins a header block with `fragment`
/// and does not end it, and ends the stream.
fn opening(stream : Int32, fragment : Bytes) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment~,
    end_stream=true,
    end_headers=false,
    priority=None,
    padding=0,
  )
}

///|
async test "h2c: empty CONTINUATION frames that end no header block count as frames that do no work: the 100th after the client's SETTINGS gets GOAWAY ENHANCE_YOUR_CALM and one log line, while an empty one that ends its block does not count; a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // A stream answered first, so that the GOAWAY names it.
      out.push(
        smock.flood(
          "a header block, then 100 empty CONTINUATION frames",
          setup=raw => [raw.get(1, "/fast")],
          ready=frame => ends_stream(frame, 1),
          raw => {
            [
              opening(3, raw.block(request_fields("GET", "/fast", "localhost"))),
              ..times(empty_continuation(3), 100),
            ]
          },
        ),
      )
      // The client's SETTINGS and 99 empty CONTINUATION frames make 100;
      // the one that ends the block does not count, so the stream is
      // answered, and one PRIORITY frame then passes the bound.
      out.push(
        smock.flood(
          "a header block, 99 empty CONTINUATION frames and an empty one that ends it",
          setup=raw => {
            [
              opening(1, raw.block(request_fields("GET", "/fast", "localhost"))),
              ..times(empty_continuation(1), 99),
              empty_continuation(1, end_headers=true),
            ]
          },
          ready=frame => ends_stream(frame, 1),
          _ => {
            [
              Priority(stream_id=3, priority={
                exclusive: false,
                stream_dependency: 0,
                weight: 16,
              }),
            ]
          },
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|a header block, then 100 empty CONTINUATION frames:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|a header block, 99 empty CONTINUATION frames and an empty one that ends it:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"empty CONTINUATION"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PRIORITY"}
      ),
    )
  })
}
