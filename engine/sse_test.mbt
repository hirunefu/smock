// Seam 1 tests of Server-Sent Event responses: the response plan of a Stub
// that streams events.

///|
test "an events Stub plans Content-Type: text/event-stream with its status and headers, then each event with its own delay" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["m.example"] }],
        #|  "stubs": [{ "id": "stream", "mock": "m",
        #|    "request": { "path": "/events" },
        #|    "response": { "status": 201,
        #|      "headers": { "Cache-Control": "no-cache", "X-Trace": "a" },
        #|      "events": [
        #|        { "data": "first" },
        #|        { "delay": 250, "event": "update", "id": "2", "data": "line 1\nline 2" },
        #|        { "delay": 1000, "id": "", "data": "" } ] } }] }
      ),
    ),
  ])
  inspect(
    describe(h.send("GET", "/events", headers=[("Host", "m.example")])),
    content=(
      #|plan:
      #|  status: 201
      #|  header: Content-Type: text/event-stream
      #|  header: Cache-Control: no-cache
      #|  header: X-Trace: a
      #|  event: after 0 ms: event -, id -, data "first"
      #|  event: after 250 ms: event "update", id "2", data "line 1\nline 2"
      #|  event: after 1000 ms: event -, id "", data ""
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: Some("m.example")
      #|  mock: Some("m")
      #|  via_default: false
      #|  request: GET /events HTTP/1.1
      #|  header: Host: m.example
      #|  body: ""
      #|  stub: Some("stream")
      #|  status: Some(201)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "an events Stub's own Content-Type is replaced by text/event-stream" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "stream", "mock": "m",
        #|    "response": { "status": 200,
        #|      "headers": { "content-type": "application/json", "X-Trace": "a" },
        #|      "events": [{ "data": "x" }] } }] }
      ),
    ),
  ])
  inspect(
    response(h.send("GET", "/events")),
    content=(
      #|200
      #|Content-Type: text/event-stream
      #|X-Trace: a
      #|Smock-Mock: m; via=default
      #|after 0 ms: event -, id -, data "x"
      #|
    ),
  )
}
