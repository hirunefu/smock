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
/// the second) and `/tick` (one event, after two seconds).
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
  #|      "fault": { "connection": { "kind": "partial" } } } ] }

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
  with_definitions([("m.json", h2_faults)], dir => {
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
