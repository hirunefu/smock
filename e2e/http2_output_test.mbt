// Seam 2 tests of the output bound over h2c: whenever what smock has queued
// for a connection and not yet written passes 16 KiB, smock writes it before
// it reads on, and a stream's task queues no more DATA until what it queued
// is written. So a client that opens wide windows and never reads cannot
// make smock hold its responses, and the write timeout closes the
// connection; a client that pauses and then reads again gets every
// response.

///|
/// The body of `/large`: 131,072 octets (128 KiB).
let large_body : String = numbered(16_384)

///|
/// The body of `/larger`: 524,288 octets (512 KiB).
let larger_body : String = numbered(65_536)

///|
/// Mock `m`, for `localhost`, with Stubs that answer `/large` with
/// `large_body`, `/small` with a short body, and `/late` with
/// `larger_body` after a delay of 100 ms.
fn output_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "large", "mock": "m", "request": { "path": "/large" },
        #|      "response": { "status": 200, "bodyFile": "large.txt" } },
        #|    { "id": "small", "mock": "m", "request": { "path": "/small" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "late", "mock": "m", "request": { "path": "/late" },
        #|      "response": { "status": 200, "bodyFile": "larger.txt" },
        #|      "fault": { "delay": { "fixed": 100 } } } ] }
      ),
    ),
    ("files/large.txt", large_body),
    ("files/larger.txt", larger_body),
  ]
}

///|
/// The HEADERS frame of a request with method `meth` for `path` on
/// `stream`, with no body: they end the stream.
fn RawH2::ask(
  self : RawH2,
  stream : Int32,
  meth : String,
  path : String,
) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment=self.block([
      (":method", meth),
      (":scheme", "http"),
      (":path", path),
      (":authority", "localhost"),
    ]),
    end_stream=true,
    end_headers=true,
    priority=None,
    padding=0,
  )
}

///|
/// The frames that open the windows of a connection wide: an initial window
/// of 2^31-1 octets for every stream, and a connection window 1,000,000
/// octets short of that, so that later WINDOW_UPDATE frames of a few octets
/// on the connection keep within it.
let wide_open : Array[@http2.Frame] = [
  Settings(
    params=[(@http2.settings_initial_window_size, 0x7fffffff)],
    ack=false,
  ),
  WindowUpdate(stream_id=0, increment=0x7fffffff - 65535 - 1_000_000),
]

///|
/// What a client that never reads saw of smock (`Smock::never_read`).
struct Unread {
  /// The requests the client sent before smock closed the connection.
  sent : Int32
  /// The requests that reached the Mocks, as `smock_requests_total`
  /// counts them once the connection has closed.
  reached : Int32
  /// The most smock's RSS reached while the connection was open, in
  /// bytes, read every 50 ms.
  peak : Double
  /// When smock closed the connection, in milliseconds after the client
  /// began to send.
  closed_ms : Int64
}

///|
/// Sends `batch(0)`, `batch(1)` and so on on `raw`, one write each,
/// `pause_ms` apart, and never reads, until a write fails because smock
/// has closed the connection. Meanwhile it reads smock's RSS every 50 ms.
async fn Smock::never_read(
  self : Smock,
  raw : RawH2,
  batch : (Int32) -> Array[@http2.Frame],
  pause_ms~ : Int32,
) -> Unread {
  let start = @async.now()
  let mut sent = 0
  let mut closed_ms = -1L
  let mut peak = 0.0
  let finished = @async.with_timeout_opt(patience_ms, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        for i = 0; ; i = i + 1 {
          let frames = batch(i)
          raw.send(frames) catch {
            _ => break
          }
          for frame in frames {
            if frame is Headers(..) {
              sent += 1
            }
          }
          @async.sleep(pause_ms)
        }
        closed_ms = @async.now() - start
      })
      while closed_ms < 0 {
        peak = Double::max(peak, resident_set(self.pid))
        @async.sleep(50)
      }
    })
  })
  guard finished is Some(_) else { fail("the connection stayed open") }
  let (_, samples) = self.metrics()
  let mut reached = 0.0
  for sample in samples {
    if sample.name == "smock_requests_total" {
      reached += sample.value
    }
  }
  { sent, reached: reached.to_int(), peak, closed_ms, }
}

///|
/// 32 MiB, smock's target for its peak RSS.
let peak_target : Double = 32.0 * 1024.0 * 1024.0

///|
async test "h2c: a client that opens wide windows, sends many HEAD and GET requests for a large body and never reads makes smock stop reading: fewer requests reach the Mocks than it sends, smock's RSS stays within 32 MiB, and the write timeout closes the connection" {
  with_definitions(output_definitions(), dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "1000"],
      smock => {
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        raw.send(wide_open)
        // A thousand requests a write, each in a HEADERS frame of a few
        // octets once the client's HPACK table holds its fields: one read
        // of smock's could otherwise queue a few hundred whole bodies.
        let mut stream = 1
        let unread = smock.never_read(
          raw,
          _ => {
            let frames = []
            for i in 0..<1000 {
              frames.push(
                match i % 3 {
                  0 => raw.ask(stream, "HEAD", "/large")
                  1 => raw.ask(stream, "GET", "/large")
                  _ => raw.ask(stream, "GET", "/small")
                },
              )
              stream += 2
            }
            frames
          },
          pause_ms=50,
        )
        let client = smock.h2c()
        defer client.close()
        let after = client.request("GET", "/small", authority="localhost")
        inspect(
          [
            "fewer requests reached the Mocks than the client sent: \{unread.reached < unread.sent}",
            "peak RSS within 32 MiB: \{unread.peak <= peak_target}",
            "closed after at least 1000 ms: \{unread.closed_ms >= 1000}, within 5000 ms: \{unread.closed_ms < 5000}",
            "a new connection: \{after.brief()}",
          ].join("\n"),
          content=(
            #|fewer requests reached the Mocks than the client sent: true
            #|peak RSS within 32 MiB: true
            #|closed after at least 1000 ms: true, within 5000 ms: true
            #|a new connection: 200 hello (end)
          ),
        )
      },
    )
    // Timeouts are not logged.
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}

///|
async test "h2c: delayed responses to a client that opens wide windows and never reads go out at most 16 KiB of DATA at a time: smock's RSS stays within 32 MiB until the write timeout closes the connection" {
  with_definitions(output_definitions(), dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "1000"],
      smock => {
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        raw.send(wide_open)
        // As many delayed streams as one connection may have at once, each
        // for 512 KiB, whose delays end together; then a WINDOW_UPDATE of one
        // octet on the connection every 50 ms, which asks smock for nothing.
        let unread = smock.never_read(
          raw,
          i => {
            if i > 0 {
              return [WindowUpdate(stream_id=0, increment=1)]
            }
            let frames = []
            for j in 0..<100 {
              frames.push(raw.ask(2 * j + 1, "GET", "/late"))
            }
            frames
          },
          pause_ms=50,
        )
        let client = smock.h2c()
        defer client.close()
        let after = client.request("GET", "/small", authority="localhost")
        inspect(
          [
            "requests that reached the Mocks: \{unread.reached} of \{unread.sent}",
            "peak RSS within 32 MiB: \{unread.peak <= peak_target}",
            "closed after at least 1000 ms: \{unread.closed_ms >= 1000}, within 5000 ms: \{unread.closed_ms < 5000}",
            "a new connection: \{after.brief()}",
          ].join("\n"),
          content=(
            #|requests that reached the Mocks: 100 of 100
            #|peak RSS within 32 MiB: true
            #|closed after at least 1000 ms: true, within 5000 ms: true
            #|a new connection: 200 hello (end)
          ),
        )
      },
    )
    // Timeouts are not logged.
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}

///|
async test "h2c: a client that opens wide windows, sends many HEAD and GET requests for a large body and pauses before it reads makes smock stop reading meanwhile, and gets every response in full once it reads" {
  with_definitions(output_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      raw.send(wide_open)
      // 600 requests in one write: 200 each of HEAD and GET for 128 KiB,
      // and GET for a short body. Their responses, 25 MiB in all, fill the
      // socket's buffers long before the client reads.
      let paths = ["/large", "/large", "/small"]
      let frames = []
      for i in 0..<600 {
        let meth = if i % 3 == 0 { "HEAD" } else { "GET" }
        frames.push(raw.ask(2 * i + 1, meth, paths[i % 3]))
      }
      raw.send(frames)
      @async.sleep(500)
      let (_, samples) = smock.metrics()
      let mut before = 0.0
      for sample in samples {
        if sample.name == "smock_requests_total" {
          before += sample.value
        }
      }
      // Each stream's status, DATA octets, whether its DATA is the Stub's
      // body so far, and whether it has ended.
      let statuses = Map([])
      let octets = Map([])
      let as_given = Map([])
      let ended = []
      let others = []
      let expected = @utf8.encode(large_body)
      while ended.length() + others.length() < 600 {
        guard raw.read_frame() is Some(frame) else {
          others.push("closed")
          break
        }
        match frame {
          Headers(stream_id~, fragment~, end_stream~, ..) => {
            for field in raw.fields(fragment) {
              if field.0 == ":status" {
                statuses[stream_id] = field.1
              }
            }
            if end_stream {
              ended.push(stream_id)
            }
          }
          Data(stream_id~, data~, end_stream~, ..) => {
            let at = octets.get(stream_id).unwrap_or(0)
            let fits = at + data.length() <= expected.length() &&
              data[:] == expected[at:at + data.length()]
            as_given[stream_id] = as_given.get(stream_id).unwrap_or(true) &&
              fits
            octets[stream_id] = at + data.length()
            if end_stream {
              ended.push(stream_id)
            }
          }
          Settings(..) => ()
          _ => others.push(raw.render_frame(frame))
        }
      }
      // What each kind of request got, one line per kind and outcome.
      let got = Map([])
      for stream in ended {
        let i = (stream - 1) / 2
        let length = octets.get(stream).unwrap_or(0)
        let body = match i % 3 {
          0 => "no body"
          1 =>
            "\{length} octets, as the Stub gives them: \{as_given.get(stream).unwrap_or(false)}"
          _ => "\{length} octets"
        }
        let line = "\{if i % 3 == 0 { "HEAD" } else { "GET" }} \{paths[i % 3]}: \{statuses.get(stream).unwrap_or("no status")}, \{body}"
        got[line] = got.get(line).unwrap_or(0) + 1
      }
      // Sorted as `String` compares, shorter lines first.
      let lines = []
      for line, count in got {
        lines.push("\{line}: \{count}")
      }
      lines.sort()
      inspect(
        [
          "before the client read, fewer requests reached the Mocks than it sent: \{before < 600.0}",
          ..lines,
          ..others,
        ].join("\n"),
        content=(
          #|before the client read, fewer requests reached the Mocks than it sent: true
          #|GET /small: 200, 5 octets: 200
          #|HEAD /large: 200, no body: 200
          #|GET /large: 200, 131072 octets, as the Stub gives them: true: 200
        ),
      )
    })
  })
}
