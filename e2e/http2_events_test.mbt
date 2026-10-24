// Seam 2 tests of Server-Sent Events over h2c: an events Stub streams one
// event stream per HTTP/2 stream, from the stream's own task, and the DATA
// of its last event ends the HTTP/2 stream.

///|
/// Mock `m`, for `localhost`, whose Stub streams the three events of
/// `news` from `/events`, due as `news_due` says, with a `Cache-Control`
/// header, and answers `/hello` at once.
let h2_news : String =
  #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
  #|  "stubs": [
  #|    { "id": "stream", "mock": "m", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "headers": { "Cache-Control": "no-cache" },
  #|        "events": [
  #|          { "delay": 400, "data": "first" },
  #|          { "delay": 300, "event": "update", "id": "2", "data": "line 1\nline 2" },
  #|          { "data": "last" } ] } },
  #|    { "id": "hello", "mock": "m", "request": { "path": "/hello" },
  #|      "response": { "status": 200, "body": "hello" } } ] }

///|
/// Reads frames until one ends `stream`, or smock ends the connection, and
/// shows each as `render_frame` does, one per line, except the HEADERS and
/// DATA of `stream`: its HEADERS show whether they came before the first
/// of the times `due` (in milliseconds after `start`), and its i-th DATA
/// frame its octets as text and whether it came at the i-th of them
/// (`arrival`).
async fn RawH2::events_until_end(
  self : RawH2,
  stream : Int32,
  start~ : Int64,
  due~ : Array[Int32],
) -> String {
  let out = []
  let mut events = 0
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    let elapsed = @async.now() - start
    match frame {
      Headers(stream_id~, ..) if stream_id == stream =>
        out.push(
          "\{head_arrival(elapsed, due[0])}: \{self.render_frame(frame)}",
        )
      Data(stream_id~, data~, end_stream~, ..) if stream_id == stream => {
        let at = if events < due.length() {
          arrival(elapsed, due[events])
        } else {
          "at \{elapsed} ms, after the events due"
        }
        events += 1
        let ended = if end_stream { " END_STREAM" } else { "" }
        out.push(
          "DATA \{stream}\{ended} \{at}: \{@utf8.decode_lossy(data).escape()}",
        )
      }
      _ => out.push(self.render_frame(frame))
    }
    if ends_stream(frame, stream) {
      break
    }
  }
  out.join("\n")
}

///|
async test "h2c: an events Stub sends HEADERS with text/event-stream and no content-length at once, then each event as DATA after its delay, and the DATA of the last event ends the stream, its entry committed by then" {
  with_definitions([("m.json", h2_news)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send([raw.get(1, "/events")])
      let frames = raw.events_until_end(1, start~, due=news_due)
      // Read right after the last event.
      let entries = smock.journal_once(1, within=0)
      inspect(
        [frames, "---", ..entries].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|before 400 ms: HEADERS 1 END_HEADERS [:status: 200, content-type: text/event-stream, cache-control: no-cache, date: <now>]
          #|DATA 1 at 400 ms: "data: first\n\n"
          #|DATA 1 at 700 ms: "event: update\nid: 2\ndata: line 1\ndata: line 2\n\n"
          #|DATA 1 END_STREAM at 700 ms: "data: last\n\n"
          #|---
          #|/events: stub "stream", status 200
        ),
      )
    })
  })
}
