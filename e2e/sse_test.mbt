// Server-Sent Event responses on the wire: a real HTTP/1.1 client and an
// HTTP/1.0 client over a raw connection read the stream as it arrives, and
// the time each part arrives is checked against the events' delays.

///|
/// A Mock that streams three events from `/events`: the first 400 ms after
/// the head, the second 300 ms later, and the last right after it. `/slow`
/// streams one event, 1000 ms after the head. `/hello` answers at once.
let news : String =
  #|{ "mocks": [{ "name": "news" }],
  #|  "stubs": [
  #|    { "id": "stream", "mock": "news", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "headers": { "Cache-Control": "no-cache" },
  #|        "events": [
  #|          { "delay": 400, "data": "first" },
  #|          { "delay": 300, "event": "update", "id": "2", "data": "line 1\nline 2" },
  #|          { "data": "last" } ] } },
  #|    { "id": "slow", "mock": "news", "request": { "path": "/slow" },
  #|      "response": { "status": 200,
  #|        "events": [{ "delay": 1000, "data": "late" }] } },
  #|    { "id": "hello", "mock": "news", "request": { "path": "/hello" },
  #|      "response": { "status": 200, "body": "hello" } } ] }

///|
/// When the events of `/events` in `news` are due, in milliseconds after
/// the request.
let news_due : Array[Int] = [400, 700, 700]

///|
/// How late an event may arrive after it is due, in milliseconds, before
/// the test says so. It is generous, so a busy machine does not fail the
/// test, yet shorter than the gaps between the events of `news`.
let lateness : Int = 250

///|
/// `at <due> ms` when an event that arrived `elapsed` milliseconds after
/// the request was due `due` milliseconds after it: not before, and less
/// than `lateness` after. Otherwise when it arrived.
fn arrival(elapsed : Int64, due : Int) -> String {
  // Timers and clocks tick in whole milliseconds.
  if elapsed >= (due - 2).to_int64() && elapsed < (due + lateness).to_int64() {
    "at \{due} ms"
  } else {
    "at \{elapsed} ms, due at \{due} ms"
  }
}

///|
/// `before <first> ms` when the head arrived `elapsed` milliseconds after
/// the request, before the first event was due at `first`. Otherwise when
/// it arrived.
fn head_arrival(elapsed : Int64, first : Int) -> String {
  if elapsed < first.to_int64() {
    "before \{first} ms"
  } else {
    "at \{elapsed} ms, after the first event was due"
  }
}

///|
async test "an events Stub streams to a real HTTP/1.1 client: the head at once, each event after its delay, chunked, and the stream ends after the last event" {
  with_definitions([("news.json", news)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = @http.Client("http://127.0.0.1:\{smock.port}")
      defer client.close()
      let start = @async.now()
      let response = client.get("/events")
      let out = [
        "head \{head_arrival(@async.now() - start, news_due[0])}:",
        render_response(response, "").trim_end(chars="\n").to_owned(),
      ]
      for due in news_due {
        let event = @async.with_timeout_opt(patience_ms, () => {
          client.read_until("\n\n")
        })
        guard event is Some(Some(event)) else {
          fail("the stream ended early:\n\{out.join("\n")}")
        }
        out.push(
          "event \{arrival(@async.now() - start, due)}: \{event.escape()}",
        )
      }
      let rest = @async.with_timeout_opt(patience_ms, () => client.read_some())
      out.push(if rest is Some(None) { "end of stream" } else { "more data" })
      // The stream ended with its framing, so the connection carries the
      // next request.
      let response = client.get("/hello")
      out.push(render_response(response, client.read_all().text()))
      inspect(
        out.join("\n"),
        content=(
          #|head before 400 ms:
          #|200 OK
          #|Content-Type: text/event-stream
          #|Cache-Control: no-cache
          #|Smock-Mock: news; via=default
          #|Transfer-Encoding: chunked
          #|event at 400 ms: "data: first"
          #|event at 700 ms: "event: update\nid: 2\ndata: line 1\ndata: line 2"
          #|event at 700 ms: "data: last"
          #|end of stream
          #|200 OK
          #|Smock-Mock: news; via=default
          #|Content-Length: 5
          #|
          #|hello
        ),
      )
    })
  })
}

///|
async test "an events Stub streams to an HTTP/1.0 client over a raw connection without chunking, and closes the connection to end the stream" {
  let _ = on_both_ports(files=[("news.json", news)], (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    let start = @async.now()
    // A client that asks to keep the connection open still gets a stream
    // that ends when the connection closes.
    conn.write("GET /events HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
    let head = read_head(conn)
    let out = ["head \{head_arrival(@async.now() - start, news_due[0])}:", head]
    for due in news_due {
      let event = @async.with_timeout_opt(patience_ms, () => {
        conn.read_until("\n\n")
      })
      guard event is Some(Some(event)) else {
        fail("the stream ended early:\n\{out.join("\n")}")
      }
      out.push("event \{arrival(@async.now() - start, due)}: \{event.escape()}")
    }
    out.push(if closed(conn) { "closed" } else { "open" })
    inspect(
      out.join("\n"),
      content=(
        #|head before 400 ms:
        #|HTTP/1.1 200 OK
        #|Content-Type: text/event-stream
        #|Cache-Control: no-cache
        #|Smock-Mock: news; via=default
        #|Connection: close
        #|
        #|event at 400 ms: "data: first"
        #|event at 700 ms: "event: update\nid: 2\ndata: line 1\ndata: line 2"
        #|event at 700 ms: "data: last"
        #|closed
      ),
    )
  })
}

///|
async test "while a stream waits for an event's delay, smock answers requests on other connections" {
  with_definitions([("news.json", news)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let stream = smock.connect()
      defer stream.close()
      let start = @async.now()
      stream.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let _ = read_head(stream)
      let hello = smock.send("GET", "/hello")
      let elapsed = @async.now() - start
      let out = [
        if elapsed < 1000L {
          "answered while the stream waits:"
        } else {
          "answered at \{elapsed} ms, after the stream's event was due:"
        },
        hello,
      ]
      // The event's chunk, then the last chunk.
      let event = @async.with_timeout_opt(patience_ms, () => {
        stream.read_until("\r\n\r\n")
      })
      guard event is Some(Some(event)) else { fail("the stream ended early") }
      out.push(
        "stream \{arrival(@async.now() - start, 1000)}: \{event.escape()}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|answered while the stream waits:
          #|HTTP/1.1 200 OK
          #|Smock-Mock: news; via=default
          #|Content-Length: 5
          #|
          #|hello
          #|stream at 1000 ms: "c\r\ndata: late\n\n\r\n0"
        ),
      )
    })
  })
}

///|
/// How many files, sockets included, the process `pid` has open.
async fn open_files(pid : Int) -> Int {
  @fs.readdir("/proc/\{pid}/fd").length()
}

///|
async test "a client that closes the connection mid-stream ends that stream, and smock keeps serving" {
  // 200 events, one every 50 ms: the stream would last 10 s.
  let ticks = Array::make(200, "{ \"delay\": 50, \"data\": \"tick\" }")
  let defs =
    $|{ "mocks": [{ "name": "clock" }],
    $|  "stubs": [
    $|    { "id": "ticks", "mock": "clock", "request": { "path": "/ticks" },
    $|      "response": { "status": 200, "events": [\{ticks.join(", ")}] } },
    $|    { "id": "hello", "mock": "clock", "request": { "path": "/hello" },
    $|      "response": { "status": 200, "body": "hello" } } ] }
  with_definitions([("clock.json", defs)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      conn.write("GET /ticks HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let _ = read_head(conn)
      guard conn.read_until("\n\n") is Some(_) else {
        fail("the stream ended early")
      }
      let streaming = open_files(smock.pid)
      conn.close()
      // smock notices when it next writes to the closed connection, and
      // then closes its end of it.
      let ended = @async.with_timeout_opt(3000, () => {
        while open_files(smock.pid) >= streaming {
          @async.sleep(20)
        }
      })
      let out = [
        if ended is Some(_) {
          "the stream ended"
        } else {
          "the stream still runs 3 s after the client closed"
        },
        smock.send("GET", "/hello"),
      ]
      inspect(
        out.join("\n"),
        content=(
          #|the stream ended
          #|HTTP/1.1 200 OK
          #|Smock-Mock: clock; via=default
          #|Content-Length: 5
          #|
          #|hello
        ),
      )
    })
    // smock logged nothing about the closed connection, and stopped only
    // when the test sent SIGTERM.
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}",
      content=(
        #|status 0
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
async test "a response to HEAD from an events Stub is its head alone: smock writes it at once, records it in the Journal and reads the next request without waiting out the events' delays" {
  with_definitions([("news.json", news)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let start = @async.now()
      // `/slow` has one event, due 1000 ms after the head.
      conn.write(
        "HEAD /slow HTTP/1.1\r\nHost: localhost\r\nbaggage: smock-session=head-of-stream\r\n\r\nGET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n",
      )
      let head = read_head(conn)
      let recorded = smock.journal_count(
        "head-of-stream", "{ \"filter\": { \"method\": \"HEAD\" } }",
      )
      let hello = read_response(conn)
      let elapsed = @async.now() - start
      inspect(
        [
          head,
          "in the Journal right after: \{recorded}",
          if elapsed < 1000L {
            "the next request answered before the event was due:"
          } else {
            "the next request answered at \{elapsed} ms, after the event was due:"
          },
          hello,
        ].join("\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|Smock-Mock: news; via=default
          #|Transfer-Encoding: chunked
          #|
          #|in the Journal right after: 1
          #|the next request answered before the event was due:
          #|HTTP/1.1 200 OK
          #|Smock-Mock: news; via=default
          #|Content-Length: 5
          #|
          #|hello
        ),
      )
    })
  })
}
