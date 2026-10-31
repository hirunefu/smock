// Seam 2 tests of Faults over h2c: each connection Fault takes its nearest
// HTTP/2 form. `reset` resets its stream alone, `partial` sends half the
// body or half the events and then resets the stream, and `close` sends
// GOAWAY and closes the connection. The engine decides them with the same
// draws and seeds as over HTTP/1.1.

///|
/// Mock `m` with Stubs for every Fault over HTTP/2: `/fast` at once,
/// `/reset`, `/close` and `/partial` (a body of ten octets) with their
/// connection Faults, and partial Faults on responses with no body to
/// halve, `/empty` (200 with no body) and `/no-content` (204), and on
/// Server-Sent Events, `/ticks` (four events, the third two seconds after
/// the second) and `/tick` (one event, after two seconds); `/later`
/// answers after a delay of 500 ms, and `/upload` any request at once.
/// After a delay, `/late-partial` (300 ms), `/late-ticks` (400 ms, three
/// events), `/late-reset` (500 ms) and `/late-close` (700 ms) take their
/// Faults; `/big-partial` has a partial Fault on the 150,000 octets of
/// `big_body`, from the body file `big.txt`.
let h2_faults : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } },
  #|    { "id": "reset", "mock": "m", "request": { "path": "/reset" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "reset" } } },
  #|    { "id": "close", "mock": "m", "request": { "path": "/close" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "close" } } },
  #|    { "id": "partial", "mock": "m", "request": { "path": "/partial" },
  #|      "response": { "status": 200, "headers": { "Content-Type": "text/plain" },
  #|        "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "empty", "mock": "m", "request": { "path": "/empty" },
  #|      "response": { "status": 200 },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "no-content", "mock": "m", "request": { "path": "/no-content" },
  #|      "response": { "status": 204 },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
  #|      "response": { "status": 200, "events": [
  #|        { "data": "one" }, { "delay": 200, "data": "two" },
  #|        { "delay": 2000, "data": "three" }, { "data": "four" } ] },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "tick", "mock": "m", "request": { "path": "/tick" },
  #|      "response": { "status": 200, "events": [
  #|        { "delay": 2000, "data": "one" } ] },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "later", "mock": "m", "request": { "path": "/later" },
  #|      "response": { "status": 200, "body": "later" },
  #|      "fault": { "delay": { "fixed": 500 } } },
  #|    { "id": "upload", "mock": "m", "request": { "path": "/upload" },
  #|      "response": { "status": 201, "body": "stored" } },
  #|    { "id": "late-partial", "mock": "m", "request": { "path": "/late-partial" },
  #|      "response": { "status": 200, "body": "0123456789" },
  #|      "fault": { "delay": { "fixed": 300 },
  #|        "connection": { "kind": "partial" } } },
  #|    { "id": "late-ticks", "mock": "m", "request": { "path": "/late-ticks" },
  #|      "response": { "status": 200, "events": [
  #|        { "data": "one" }, { "data": "two" }, { "data": "three" } ] },
  #|      "fault": { "delay": { "fixed": 400 },
  #|        "connection": { "kind": "partial" } } },
  #|    { "id": "late-reset", "mock": "m", "request": { "path": "/late-reset" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "delay": { "fixed": 500 },
  #|        "connection": { "kind": "reset" } } },
  #|    { "id": "late-close", "mock": "m", "request": { "path": "/late-close" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "delay": { "fixed": 700 },
  #|        "connection": { "kind": "close" } } },
  #|    { "id": "big-partial", "mock": "m", "request": { "path": "/big-partial" },
  #|      "response": { "status": 200, "bodyFile": "big.txt" },
  #|      "fault": { "connection": { "kind": "partial" } } } ] }

///|
/// The Definition files of the Fault tests: `h2_faults` and its body file.
fn fault_definitions() -> Array[(String, String)] {
  [("m.json", h2_faults), ("files/big.txt", big_body)]
}

///|
/// The Journal's entries, one per line: each request's method and target,
/// with the status and the Fault of its entry.
async fn fault_journal(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  entries
  .map(entry => {
    guard entry
      is Object(
        {
          "request": Object(
            { "method": String(meth), "target": String(target), .. }
          ),
          "status": status,
          "fault": fault,
          ..
        }
      ) else {
      return entry.stringify()
    }
    "\{meth} \{target}: status \{status.stringify()}, fault \{fault.stringify()}"
  })
  .join("\n")
}

///|
async test "h2c: a partial Fault sends HEADERS with the whole content-length and half the body, or half the events, then RST_STREAM INTERNAL_ERROR; a response with no body sends its HEADERS without ending the stream, then the reset; the Journal entry keeps its status" {
  with_definitions(fault_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      let mut stream = 1
      for
        request in [
          ("GET", "/partial"),
          ("HEAD", "/partial"),
          ("GET", "/empty"),
          ("GET", "/no-content"),
          ("GET", "/ticks"),
          ("GET", "/tick"),
          ("HEAD", "/ticks"),
        ] {
        let start = @async.now()
        raw.send([
          headers_frame(
            stream,
            raw.block(request_fields(request.0, request.1, "localhost")),
          ),
        ])
        out.push("\{request.0} \{request.1}:")
        out.push(raw.frames_until_stream_ends(stream))
        let ms = @async.now() - start
        out.push("reset before 1000 ms: \{ms < 1000}")
        stream += 2
      }
      inspect(
        [..out, "---", fault_journal(smock)].join("\n"),
        content=(
          #|GET /partial:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, content-type: text/plain, smock-mock: m; via=default, date: <now>, content-length: 10]
          #|DATA 1 5 octets
          #|RST_STREAM 1 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|HEAD /partial:
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: text/plain, smock-mock: m; via=default, date: <now>, content-length: 10]
          #|RST_STREAM 3 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|GET /empty:
          #|HEADERS 5 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 0]
          #|RST_STREAM 5 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|GET /no-content:
          #|HEADERS 7 END_HEADERS [:status: 204, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 7 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|GET /ticks:
          #|HEADERS 9 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|DATA 9 11 octets
          #|DATA 9 11 octets
          #|RST_STREAM 9 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|GET /tick:
          #|HEADERS 11 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 11 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|HEAD /ticks:
          #|HEADERS 13 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 13 INTERNAL_ERROR
          #|reset before 1000 ms: true
          #|---
          #|GET /partial: status 200, fault "partial"
          #|HEAD /partial: status 200, fault "partial"
          #|GET /empty: status 200, fault "partial"
          #|GET /no-content: status 204, fault "partial"
          #|GET /ticks: status 200, fault "partial"
          #|GET /tick: status 200, fault "partial"
          #|HEAD /ticks: status 200, fault "partial"
        ),
      )
    })
  })
}

///|
async test "h2c: a close Fault sends GOAWAY NO_ERROR naming the highest stream the client has opened, so at least every stream still open; nothing more goes out, smock discards what the client sends, and closes with a FIN a second later; its Journal entry has no status" {
  with_definitions(fault_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        headers_frame(1, raw.block(request_fields("GET", "/fast", "localhost"))),
      ])
      let answered = raw.frames_until_stream_ends(1)
      // The Fault's stream, with its body still to come, then two later
      // streams: one that waits for its delay, and an upload in progress.
      raw.send([
        headers_frame(
          3,
          raw.block(request_fields("POST", "/close", "localhost")),
          end_stream=false,
        ),
        Data(stream_id=3, data=b"abc", end_stream=false, padding=0),
        headers_frame(
          5,
          raw.block(request_fields("GET", "/later", "localhost")),
        ),
        headers_frame(
          7,
          raw.block(request_fields("POST", "/upload", "localhost")),
          end_stream=false,
        ),
        Data(stream_id=7, data=b"half", end_stream=false, padding=0),
      ])
      @async.sleep(100)
      let start = @async.now()
      // The end of the upload comes in the same read as the end of the
      // Fault's request, after it: it goes no further.
      raw.send([
        Data(stream_id=3, data=b"de", end_stream=true, padding=0),
        Data(stream_id=7, data=b" more", end_stream=true, padding=0),
      ])
      let goaway = raw.frames_until(start, is_goaway)
      // A PING, as a client might send before it reads the GOAWAY, is not
      // answered, and the delayed stream's response, due before the
      // connection closes, does not come.
      raw.send([Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false)])
      let after = raw.frames_until(start, _ => false)
      // smock carries on with other connections.
      let fresh = smock.h2c()
      defer fresh.close()
      let next = fresh.request("GET", "/fast", authority="localhost")
      inspect(
        [
          answered,
          "---",
          ..goaway.shown,
          "GOAWAY at once: \{goaway.end_ms < 400}",
          "then: \{after.shown.length()} frames, \{after.how}, about a second after the GOAWAY: \{after.end_ms - goaway.end_ms >= 800 && after.end_ms - goaway.end_ms < 2000}",
          "a fresh connection: \{next.brief()}",
          "---",
          fault_journal(smock),
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|---
          #|GOAWAY last=7 NO_ERROR
          #|GOAWAY at once: true
          #|then: 0 frames, a FIN, about a second after the GOAWAY: true
          #|a fresh connection: 200 fast (end)
          #|---
          #|GET /fast: status 200, fault null
          #|POST /close: status null, fault "close"
          #|GET /later: status 200, fault null
          #|GET /fast: status 200, fault null
        ),
      )
    })
  })
}

///|
async test "h2c: a reset Fault reads the whole request, body included, then resets its stream alone with RST_STREAM INTERNAL_ERROR, while the connection's other streams are answered; its Journal entry has no status" {
  with_definitions(fault_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      // Half the body: smock waits for the rest, and answers another
      // stream meanwhile.
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("POST", "/reset", "localhost")),
          end_stream=false,
        ),
        Data(stream_id=1, data=b"01234", end_stream=false, padding=0),
        headers_frame(3, raw.block(request_fields("GET", "/fast", "localhost"))),
        fence,
      ])
      out.push(raw.frames_until_ping_ack())
      out.push("--- the rest of the body")
      raw.send([
        Data(stream_id=1, data=b"56789", end_stream=true, padding=0),
        headers_frame(5, raw.block(request_fields("GET", "/fast", "localhost"))),
      ])
      out.push(raw.frames_until_stream_ends(1))
      out.push(raw.frames_until_stream_ends(5))
      inspect(
        [..out, "---", fault_journal(smock)].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 3 END_STREAM 4 octets
          #|--- the rest of the body
          #|RST_STREAM 1 INTERNAL_ERROR
          #|HEADERS 5 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 5 END_STREAM 4 octets
          #|---
          #|GET /fast: status 200, fault null
          #|POST /reset: status null, fault "reset"
          #|GET /fast: status 200, fault null
        ),
      )
    })
  })
}

///|
async test "h2c: a Fault with a delay runs in its stream's task, while the connection's other streams are answered: a partial one, on a body and on events, a reset one and a close one, each after its delay" {
  with_definitions(fault_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send([
        raw.get(1, "/late-partial"),
        raw.get(3, "/late-ticks"),
        raw.get(5, "/late-reset"),
        raw.get(7, "/fast"),
        raw.get(9, "/late-close"),
      ])
      let fast = raw.frames_until(start, frame => ends_stream(frame, 7))
      let partial = raw.frames_until(start, frame => ends_stream(frame, 1))
      let ticks = raw.frames_until(start, frame => ends_stream(frame, 3))
      let reset = raw.frames_until(start, frame => ends_stream(frame, 5))
      let close = raw.frames_until(start, is_goaway)
      inspect(
        [
          ..fast.shown,
          "at once: \{fast.end_ms < 300}",
          ..partial.shown,
          "after 300 ms: \{partial.end_ms >= 300}",
          ..ticks.shown,
          "after 400 ms: \{ticks.end_ms >= 400}",
          ..reset.shown,
          "after 500 ms: \{reset.end_ms >= 500}",
          ..close.shown,
          "after 700 ms: \{close.end_ms >= 700}",
          "---",
          fault_journal(smock),
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 7 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 7 END_STREAM 4 octets
          #|at once: true
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 10]
          #|DATA 1 5 octets
          #|RST_STREAM 1 INTERNAL_ERROR
          #|after 300 ms: true
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|DATA 3 11 octets
          #|RST_STREAM 3 INTERNAL_ERROR
          #|after 400 ms: true
          #|RST_STREAM 5 INTERNAL_ERROR
          #|after 500 ms: true
          #|GOAWAY last=9 NO_ERROR
          #|after 700 ms: true
          #|---
          #|GET /fast: status 200, fault null
          #|GET /late-partial: status 200, fault "partial"
          #|GET /late-ticks: status 200, fault "partial"
          #|GET /late-reset: status null, fault "reset"
          #|GET /late-close: status null, fault "close"
        ),
      )
    })
  })
}

///|
async test "h2c: a partial Fault whose half body is larger than the client's windows sends it from the stream's task as the client widens them, then resets the stream" {
  with_definitions(fault_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      // Half the body is 75,000 octets: the windows, 65,535 octets each,
      // hold back the rest.
      raw.send([raw.get(1, "/big-partial"), fence])
      out.push(raw.runs_until(frame => frame is Ping(ack=true, ..)))
      out.push("--- both windows widened by 20,000")
      raw.send([
        WindowUpdate(stream_id=1, increment=20_000),
        WindowUpdate(stream_id=0, increment=20_000),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 1)))
      inspect(
        [..out, "---", fault_journal(smock)].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, smock-mock: m; via=default, date: <now>, content-length: 150000]
          #|DATA 1: 4 frames, 65535 octets
          #|PING ACK
          #|--- both windows widened by 20,000
          #|DATA 1: 1 frames, 9465 octets
          #|RST_STREAM 1 INTERNAL_ERROR
          #|---
          #|GET /big-partial: status 200, fault "partial"
        ),
      )
    })
  })
}

///|
/// Mock `m` with Stubs whose connection Faults apply to half of the
/// matched requests: `/flaky` resets, as its own generator, seeded with
/// 2026, draws, and `/coin-partial` and `/coin-close` send half the body
/// and close, as the process generator draws, which `--seed` seeds.
let coin_faults : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "flaky", "mock": "m", "request": { "path": "/flaky" },
  #|      "response": { "status": 200, "body": "answered" },
  #|      "fault": { "connection": { "kind": "reset", "probability": 0.5 },
  #|        "seed": 2026 } },
  #|    { "id": "coin-partial", "mock": "m", "request": { "path": "/coin-partial" },
  #|      "response": { "status": 200, "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial", "probability": 0.5 } } },
  #|    { "id": "coin-close", "mock": "m", "request": { "path": "/coin-close" },
  #|      "response": { "status": 200, "body": "heads" },
  #|      "fault": { "connection": { "kind": "close", "probability": 0.5 } } } ] }

///|
/// What became of `GET <path>`, sent over HTTP/1.1 on a connection of its
/// own: `reset` for an RST with nothing written, `close` for a FIN with
/// nothing written, `cut: <body>` for a body shorter than its
/// `Content-Length`, else the body.
async fn http1_fault_outcome(smock : Smock, path : String) -> String {
  let conn = smock.connect()
  defer conn.close()
  conn.write(
    "GET \{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
  )
  let (received, ending) = sent_until_end(conn, within=patience_ms)
  let text = @utf8.decode_lossy(received)
  match ending {
    "an RST" if received.length() == 0 => "reset"
    "a FIN" if received.length() == 0 => "close"
    "a FIN" => {
      guard text.find("\r\n\r\n") is Some(end) &&
        text.find("Content-Length: ") is Some(at) else {
        return "no head: \{text.escape()}"
      }
      let length = text[at + 16:].split("\r\n").to_array()[0].to_owned()
      let body = text[end + 4:].to_owned()
      if body.length().to_string() == length {
        body
      } else {
        "cut: \{body}"
      }
    }
    _ => "\{received.length()} bytes, then \{ending}"
  }
}

///|
/// What became of `GET <path>`, sent on `stream` of `raw`: `reset` for
/// RST_STREAM with no HEADERS, `close` for GOAWAY, `cut: <body>` for
/// RST_STREAM after HEADERS, else the body.
async fn h2_fault_outcome(raw : RawH2, stream : Int32, path : String) -> String {
  raw.send([raw.get(stream, path)])
  let body = @buffer.Buffer()
  let mut headers = false
  for ;; {
    guard raw.read_frame() is Some(frame) else { return "closed" }
    // Every header block is decoded, to keep the decoder in step.
    let _ = raw.render_frame(frame)
    match frame {
      Headers(stream_id~, ..) if stream_id == stream => headers = true
      Data(stream_id~, data~, end_stream~, ..) if stream_id == stream => {
        body.write_bytes(data)
        if end_stream {
          return @utf8.decode_lossy(body.to_bytes())
        }
      }
      RstStream(stream_id~, ..) if stream_id == stream =>
        return if headers {
          "cut: \{@utf8.decode_lossy(body.to_bytes())}"
        } else {
          "reset"
        }
      GoAway(..) => return "close"
      _ => ()
    }
  }
}

///|
async test "h2c: Fault probabilities and seeds replay the same over HTTP/2 as over HTTP/1.1: with the same --seed, and a Stub's own seed, the same requests get the same Faults" {
  with_definitions([("m.json", coin_faults)], dir => {
    let paths = []
    for _ in 0..<6 {
      paths.push("/flaky")
      paths.push("/coin-partial")
      paths.push("/coin-close")
    }
    let args = ["--dir", dir, "--port", "0", "--seed", "7"]
    let http1 = []
    let _ = with_smock(args, smock => {
      for path in paths {
        http1.push(http1_fault_outcome(smock, path))
      }
    })
    let http2 = []
    let _ = with_smock(args, smock => {
      let mut raw = smock.raw_h2()
      let mut stream = 1
      for path in paths {
        let outcome = h2_fault_outcome(raw, stream, path)
        http2.push(outcome)
        stream += 2
        // A close Fault ends the connection: the next request opens one.
        if outcome == "close" {
          raw.close()
          raw = smock.raw_h2()
          stream = 1
        }
      }
      raw.close()
    })
    let out = []
    for i, path in paths {
      out.push("\{path}: \{http1[i]} | \{http2[i]}")
    }
    inspect(
      [..out, "the same over both: \{http1 == http2}"].join("\n"),
      content=(
        #|/flaky: answered | answered
        #|/coin-partial: cut: 01234 | cut: 01234
        #|/coin-close: heads | heads
        #|/flaky: reset | reset
        #|/coin-partial: cut: 01234 | cut: 01234
        #|/coin-close: heads | heads
        #|/flaky: reset | reset
        #|/coin-partial: cut: 01234 | cut: 01234
        #|/coin-close: close | close
        #|/flaky: answered | answered
        #|/coin-partial: 0123456789 | 0123456789
        #|/coin-close: heads | heads
        #|/flaky: reset | reset
        #|/coin-partial: cut: 01234 | cut: 01234
        #|/coin-close: heads | heads
        #|/flaky: reset | reset
        #|/coin-partial: 0123456789 | 0123456789
        #|/coin-close: close | close
        #|the same over both: true
      ),
    )
  })
}
