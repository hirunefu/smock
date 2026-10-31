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
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
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

///|
/// Mock `m`, for `localhost`, with the Stubs of `h2_news`, and `/late`,
/// which streams two events after a delay of 300 ms: the first at once,
/// the second 200 ms after it.
let h2_news_late : String =
  #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
  #|  "stubs": [
  #|    { "id": "stream", "mock": "m", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "headers": { "Cache-Control": "no-cache" },
  #|        "events": [
  #|          { "delay": 400, "data": "first" },
  #|          { "delay": 300, "event": "update", "id": "2", "data": "line 1\nline 2" },
  #|          { "data": "last" } ] } },
  #|    { "id": "late", "mock": "m", "request": { "path": "/late" },
  #|      "fault": { "delay": { "fixed": 300 } },
  #|      "response": { "status": 200,
  #|        "events": [{ "data": "a" }, { "delay": 200, "data": "b" }] } },
  #|    { "id": "hello", "mock": "m", "request": { "path": "/hello" },
  #|      "response": { "status": 200, "body": "hello" } } ] }

///|
/// Reads events until each stream of `due` has ended, been reset, or the
/// connection has closed, and shows, for each stream in the order of
/// `due`, what came on it, a line each: its HEADERS with their fields, each
/// DATA with its octets as text, and how it ended. `due` gives, for each
/// stream, when its HEADERS are due and then when each DATA is, in
/// milliseconds after `start`, and each line says whether it came then
/// (`arrival`).
async fn H2Client::timeline(
  self : H2Client,
  start~ : Int64,
  due~ : Array[(Int32, Array[Int32])],
) -> String {
  let seen : Map[Int32, Array[String]] = Map([])
  for stream in due {
    seen[stream.0] = []
  }
  let mut open = due.length()
  let when = (stream : Int32, ms : Int64) => {
    let lines = seen.get(stream).unwrap()
    let times = due.filter(entry => entry.0 == stream)[0].1
    if lines.length() < times.length() {
      arrival(ms, times[lines.length()])
    } else {
      "at \{ms} ms, after the frames due"
    }
  }
  while open > 0 {
    let event = self.read_event()
    let ms = @async.now() - start
    match event {
      Response(stream~, fields~) if seen.contains(stream) => {
        let shown = fields.map(field => {
          shown_field(
            @utf8.decode_lossy(field.name),
            @utf8.decode_lossy(field.value),
          )
        })
        let at = when(stream, ms)
        seen.get(stream).unwrap().push("HEADERS \{at}: \{shown.join(", ")}")
      }
      Data(stream~, data~) if seen.contains(stream) => {
        let at = when(stream, ms)
        seen
        .get(stream)
        .unwrap()
        .push("DATA \{at}: \{@utf8.decode_lossy(data).escape()}")
      }
      End(stream~) if seen.contains(stream) => {
        seen.get(stream).unwrap().push("end")
        open -= 1
      }
      Reset(stream~, code~, ..) if seen.contains(stream) => {
        seen.get(stream).unwrap().push("reset \{error_name(code)}")
        open -= 1
      }
      Closed => break
      _ => ()
    }
  }
  let out = []
  for stream in due {
    out.push("stream \{stream.0}:")
    for line in seen.get(stream.0).unwrap() {
      out.push("  \{line}")
    }
  }
  out.join("\n")
}

///|
async test "h2c: several event streams on one connection each stream their events at their own times, one delayed by its Stub among them, while a fast stream on the connection is answered at once" {
  with_definitions([("m.json", h2_news_late)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let first = client.send("GET", "/events", authority="localhost")
      let second = client.send("GET", "/events", authority="localhost")
      let late = client.send("GET", "/late", authority="localhost")
      let hello = client.send("GET", "/hello", authority="localhost")
      let shown = client.timeline(start~, due=[
        (first, [0, ..news_due]),
        (second, [0, ..news_due]),
        (late, [300, 300, 500]),
        (hello, [0, 0]),
      ])
      let entries = smock.journal_once(4, within=0)
      inspect(
        [shown, "---", ..entries].join("\n"),
        content=(
          #|stream 1:
          #|  HEADERS at 0 ms: :status: 200, content-type: text/event-stream, cache-control: no-cache, date: <now>
          #|  DATA at 400 ms: "data: first\n\n"
          #|  DATA at 700 ms: "event: update\nid: 2\ndata: line 1\ndata: line 2\n\n"
          #|  DATA at 700 ms: "data: last\n\n"
          #|  end
          #|stream 3:
          #|  HEADERS at 0 ms: :status: 200, content-type: text/event-stream, cache-control: no-cache, date: <now>
          #|  DATA at 400 ms: "data: first\n\n"
          #|  DATA at 700 ms: "event: update\nid: 2\ndata: line 1\ndata: line 2\n\n"
          #|  DATA at 700 ms: "data: last\n\n"
          #|  end
          #|stream 5:
          #|  HEADERS at 300 ms: :status: 200, content-type: text/event-stream, date: <now>
          #|  DATA at 300 ms: "data: a\n\n"
          #|  DATA at 500 ms: "data: b\n\n"
          #|  end
          #|stream 7:
          #|  HEADERS at 0 ms: :status: 200, date: <now>, content-length: 5
          #|  DATA at 0 ms: "hello"
          #|  end
          #|---
          #|/hello: stub "hello", status 200
          #|/late: stub "late", status 200
          #|/events: stub "stream", status 200
          #|/events: stub "stream", status 200
        ),
      )
    })
  })
}

///|
/// Mock `m`, for `localhost`, whose Stub streams from `/ticks` an event
/// at once, then one every 1000 ms, ten in all, and answers `/hello` at
/// once.
fn h2_ticks() -> String {
  let ticks = [
    "{ \"data\": \"tick\" }",
    ..Array::make(9, "{ \"delay\": 1000, \"data\": \"tick\" }"),
  ]
  (
    $|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
    $|  "stubs": [
    $|    { "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
    $|      "response": { "status": 200, "events": [\{ticks.join(", ")}] } },
    $|    { "id": "hello", "mock": "m", "request": { "path": "/hello" },
    $|      "response": { "status": 200, "body": "hello" } } ] }
  )
}

///|
/// The Journal's entries, each shown as its target, its Stub, its status
/// and whether its `durationMs` is below `below`, once there are `count`
/// of them, or as they are after `within` milliseconds.
async fn Smock::journal_durations(
  self : Smock,
  count : Int32,
  below~ : Int32,
  within~ : Int32,
) -> Array[String] {
  let start = @async.now()
  for ;; {
    let (_, journal) = self.journal()
    guard journal is Object({ "entries": Array(entries), .. }) else {
      fail("no entries: \{journal.stringify()}")
    }
    if entries.length() >= count || @async.now() - start >= within.to_int64() {
      return entries.map(entry => {
        guard entry
          is Object(
            {
              "request": Object({ "target": String(target), .. }),
              "stub": stub,
              "status": status,
              "durationMs": Number(duration, ..),
              ..
            }
          ) else {
          return entry.stringify()
        }
        let short = duration < below.to_double()
        "\{target}: stub \{stub.stringify()}, status \{status.stringify()}, durationMs below \{below}: \{short}"
      })
    }
    @async.sleep(20)
  }
}

///|
async test "h2c: an event stream that the client resets, or that moonhttp resets for the client's frames, ends at once: its entry is committed then, its duration up to the reset, and no more of its events is sent" {
  with_definitions([("m.json", h2_ticks())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send([raw.get(1, "/ticks"), raw.get(3, "/ticks")])
      // The HEADERS and the first event of both streams.
      let out = [raw.runs_until(data_seen(3, 1))]
      // The client resets stream 1; a WINDOW_UPDATE of 0 on stream 3 is a
      // stream error, for which moonhttp resets it.
      raw.send([
        RstStream(stream_id=1, error_code=@http2.error_cancel),
        WindowUpdate(stream_id=3, increment=0),
      ])
      let entries = smock.journal_durations(2, below=1000, within=600)
      let committed_ms = @async.now() - start
      // Past the next event's time, a fast stream is answered, and nothing
      // more came on the reset streams.
      @async.sleep((1300L - (@async.now() - start)).to_int())
      raw.send([raw.get(5, "/hello")])
      out.push("--- the resets sent")
      out.push(raw.runs_until(frame => ends_stream(frame, 5)))
      inspect(
        [
          ..out,
          "--- both committed before the next event was due: \{entries.length() == 2 && committed_ms < 1000}",
          ..entries,
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
          #|DATA 1: 1 frames, 12 octets
          #|DATA 3: 1 frames, 12 octets
          #|--- the resets sent
          #|RST_STREAM 3 PROTOCOL_ERROR
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 5 END_STREAM: 1 frames, 5 octets
          #|--- both committed before the next event was due: true
          #|/ticks: stub "ticks", status 200, durationMs below 1000: true
          #|/ticks: stub "ticks", status 200, durationMs below 1000: true
        ),
      )
    })
  })
}

///|
/// Mock `m`, for `localhost`, whose Stub streams from `/big` an event of
/// 20,008 octets, more than a DATA frame carries, then one of 13.
fn h2_big_event() -> String {
  let data = "x".repeat(20_000)
  (
    $|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
    $|  "stubs": [
    $|    { "id": "big", "mock": "m", "request": { "path": "/big" },
    $|      "response": { "status": 200,
    $|        "events": [{ "data": "\{data}" }, { "data": "small" }] } } ] }
  )
}

///|
async test "h2c: an event larger than the client's frame size goes out in several DATA frames, and one larger than the stream's window waits for the client to widen it" {
  with_definitions([("m.json", h2_big_event())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([raw.get(1, "/big")])
      // Each DATA frame of the stream's task is as large as the output bound
      // allows: 16,384 octets with its header of 9.
      let out = [raw.frames_until_end_of(1)]
      // A stream window of 10,000 octets holds half the first event.
      out.push("--- an initial window of 10000")
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 10_000)],
          ack=false,
        ),
        raw.get(3, "/big"),
      ])
      out.push(raw.runs_until(data_seen(3, 10_000)))
      // Nothing more comes on stream 3 until the client widens its window.
      raw.send([fence])
      let before = raw.frames_until_ping_ack()
      out.push(
        "before the PING's acknowledgement: \{if before == "" { "nothing" } else { before }}",
      )
      out.push("--- the stream's window widened")
      raw.send([WindowUpdate(stream_id=3, increment=20_000)])
      out.push(raw.frames_until_end_of(3))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
          #|DATA 1 16375 octets
          #|DATA 1 3633 octets
          #|DATA 1 END_STREAM 13 octets
          #|--- an initial window of 10000
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
          #|DATA 3: 1 frames, 10000 octets
          #|before the PING's acknowledgement: nothing
          #|--- the stream's window widened
          #|DATA 3 10008 octets
          #|DATA 3 END_STREAM 13 octets
        ),
      )
    })
  })
}

///|
/// Mock `m`, for `localhost`, with events Stubs whose responses have no
/// body: `/events` and `/late`, those of `h2_news_late`, when the request
/// is a HEAD; `/gone`, with status 204; and `/empty`, with no events.
let h2_no_events : String =
  #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
  #|  "stubs": [
  #|    { "id": "stream", "mock": "m", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "events": [{ "delay": 400, "data": "first" }, { "data": "last" }] } },
  #|    { "id": "late", "mock": "m", "request": { "path": "/late" },
  #|      "fault": { "delay": { "fixed": 300 } },
  #|      "response": { "status": 200,
  #|        "events": [{ "data": "a" }, { "delay": 200, "data": "b" }] } },
  #|    { "id": "gone", "mock": "m", "request": { "path": "/gone" },
  #|      "response": { "status": 204, "events": [{ "delay": 400, "data": "never" }] } },
  #|    { "id": "empty", "mock": "m", "request": { "path": "/empty" },
  #|      "response": { "status": 200, "events": [] } } ] }

///|
async test "h2c: an events response with no body, to HEAD, with status 204 or with no events, is its HEADERS alone, which end the stream at once, or after the Stub's delay, with no content-length" {
  with_definitions([("m.json", h2_no_events)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let head = client.send("HEAD", "/events", authority="localhost")
      let late = client.send("HEAD", "/late", authority="localhost")
      let gone = client.send("GET", "/gone", authority="localhost")
      let empty = client.send("GET", "/empty", authority="localhost")
      let shown = client.timeline(start~, due=[
        (head, [0]),
        (late, [300]),
        (gone, [0]),
        (empty, [0]),
      ])
      let entries = smock.journal_once(4, within=0)
      inspect(
        [shown, "---", ..entries].join("\n"),
        content=(
          #|stream 1:
          #|  HEADERS at 0 ms: :status: 200, content-type: text/event-stream, date: <now>
          #|  end
          #|stream 3:
          #|  HEADERS at 300 ms: :status: 200, content-type: text/event-stream, date: <now>
          #|  end
          #|stream 5:
          #|  HEADERS at 0 ms: :status: 204, content-type: text/event-stream, date: <now>
          #|  end
          #|stream 7:
          #|  HEADERS at 0 ms: :status: 200, content-type: text/event-stream, date: <now>
          #|  end
          #|---
          #|/events: stub "stream", status 200
          #|/gone: stub "gone", status 204
          #|/empty: stub "empty", status 200
          #|/late: stub "late", status 200
        ),
      )
    })
  })
}

///|
/// A Mock for the Host `proxy.example.com`, whose events Stubs answer a
/// CONNECT to its port 443 at once, and one to its port 8000 after a delay,
/// each with a 200 and one event.
let h2_connect_events : String =
  #|{ "mocks": [{ "name": "proxy", "hosts": ["proxy.example.com"] }],
  #|  "stubs": [
  #|    { "id": "events", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:443" } },
  #|      "response": { "status": 200, "events": [{ "data": "never" }] } },
  #|    { "id": "late-events", "mock": "proxy",
  #|      "request": { "method": "CONNECT",
  #|        "path": { "pattern": "proxy\\.example\\.com:8000" } },
  #|      "response": { "status": 200, "events": [{ "data": "never" }] },
  #|      "fault": { "delay": { "fixed": 200 } } } ] }

///|
async test "h2c: a 2xx events response to a CONNECT is its HEADERS alone, which end the stream at once, or after the Stub's delay, with no DATA, as any 2xx to a CONNECT" {
  with_definitions([("proxy.json", h2_connect_events)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        headers_frame(
          1,
          raw.block(connect_fields("proxy.example.com:8000")),
          end_stream=false,
        ),
        headers_frame(
          3,
          raw.block(connect_fields("proxy.example.com:443")),
          end_stream=false,
        ),
      ])
      inspect(
        raw.frames_until_stream_ends(1),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_STREAM END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, content-type: text/event-stream, date: <now>]
        ),
      )
      inspect(
        connect_journal(smock),
        content=(
          #|HTTP/2 CONNECT "proxy.example.com:443" host="proxy.example.com" mock="proxy" stub="events" status=200 body=0 octets
          #|HTTP/2 CONNECT "proxy.example.com:8000" host="proxy.example.com" mock="proxy" stub="late-events" status=200 body=0 octets
        ),
      )
    })
  })
}
