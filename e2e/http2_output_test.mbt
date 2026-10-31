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
