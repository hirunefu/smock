// Seam 2 tests of the timeouts of an HTTP/2 connection over h2c, which one
// watchdog per connection keeps: each stream's read timeout, the idle
// timeout, and the close that follows a GOAWAY with NO_ERROR.

///|
/// Mock `m` with Stubs that answer `/upload`, whatever the method, and
/// `/fast` at once.
let slow_uploads : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "upload", "mock": "m", "request": { "path": "/upload" },
  #|      "response": { "status": 200, "body": "uploaded" } },
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } } ] }

///|
/// A response in one line: its status and its body, or that none came, and
/// how its stream ended.
fn H2Response::brief(self : H2Response) -> String {
  let response = if self.status == 0 {
    "no response"
  } else {
    "\{self.status} \{@utf8.decode_lossy(self.body)}"
  }
  "\{response} (\{self.ended})"
}

///|
async test "h2c: a stream whose request does not arrive within the read timeout is reset with CANCEL, alone: the other streams are answered, and a stream that began later has the read timeout from its own first frame" {
  with_definitions([("m.json", slow_uploads)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "800", "--idle-timeout-ms",
        "10000",
      ],
      smock => {
        let client = smock.h2c()
        defer client.close()
        let start = @async.now()
        // Half a body, then nothing more.
        let stalled = client.send(
          "POST",
          "/upload",
          authority="localhost",
          headers=[("content-length", "10")],
          body=b"01234",
          end=false,
        )
        @async.sleep(400)
        // Half a body, and the rest 400 to 800 ms later: past the stalled
        // stream's deadline, within its own.
        let later = client.send(
          "POST",
          "/upload",
          authority="localhost",
          headers=[("content-length", "10")],
          body=b"01234",
          end=false,
        )
        let fast = client.request("GET", "/fast", authority="localhost")
        let fast_ms = @async.now() - start
        let reset = client.response(stalled)
        let reset_ms = @async.now() - start
        client.send_data(later, b"56789")
        let completed = client.response(later)
        let completed_ms = @async.now() - start
        let after = client.request("GET", "/fast", authority="localhost")
        inspect(
          [
            "fast, during the stalled upload: \{fast.brief()}, before its deadline: \{fast_ms < 800}",
            "stalled: \{reset.brief()}, after at least 800 ms: \{reset_ms >= 800}",
            "later: \{completed.brief()}, after the stalled stream's deadline: \{completed_ms >= 800}",
            "after: \{after.brief()}",
            "Journal:",
            ..smock.journal_once(3, within=0),
          ].join("\n"),
          content=(
            #|fast, during the stalled upload: 200 fast (end), before its deadline: true
            #|stalled: no response (reset CANCEL), after at least 800 ms: true
            #|later: 200 uploaded (end), after the stalled stream's deadline: true
            #|after: 200 fast (end)
            #|Journal:
            #|/fast: stub "fast", status 200
            #|/upload: stub "upload", status 200
            #|/fast: stub "fast", status 200
          ),
        )
      },
    )
  })
}

///|
/// The log lines of a smock process started with `--port 0` and no
/// certificate, that wrote nothing between starting and draining when it
/// was stopped: timeouts are not logged.
let startup_only_h2c : String =
  #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
  #|{"level":"info","msg":"random seed","seed":"*"}
  #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
  #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
  #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
  #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
  #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*"}
  #|{"level":"info","msg":"drain started","timeoutMs":20000}
  #|{"level":"info","msg":"drain ended","connectionsCut":0}

///|
/// The frames smock sent, as `RawH2::frames_until` read them.
struct Frames {
  /// Each frame, as `render_frame` shows it.
  shown : Array[String]
  /// How they ended: `open` when a frame met the condition, else how
  /// smock ended the connection, `a FIN` for a clean end of stream or `an
  /// RST` for a reset.
  how : String
  /// When the last frame came or the connection ended, in milliseconds
  /// after the time the caller gave.
  end_ms : Int64
}

///|
/// Reads frames from smock until one meets `stop`, or smock ends the
/// connection, timing the last from `since`, and tells a FIN from a reset.
async fn RawH2::frames_until(
  self : RawH2,
  since : Int64,
  stop : (@http2.Frame) -> Bool,
) -> Frames {
  let shown = []
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let (frame, used) = @http2.decode(self.received) catch {
        Incomplete => {
          let more = past_spurious_eagain(() => self.tcp.read_some()) catch {
            @os_error.OSError(_, ..) as err if is_reset(err) => break "an RST"
            err => break "an error: \{err}"
          }
          guard more is Some(more) else { break "a FIN" }
          self.received = self.received + more
          continue
        }
        err => fail("smock sent a frame that does not decode: \{err}")
      }
      self.received = self.received[used:].to_owned()
      shown.push(self.render_frame(frame))
      if stop(frame) {
        break "open"
      }
    }
  })
  guard result is Some(how) else { fail("no frame and no end in time") }
  { shown, how, end_ms: @async.now() - since, }
}

///|
/// Whether `frame` is a GOAWAY.
fn is_goaway(frame : @http2.Frame) -> Bool {
  frame is GoAway(..)
}

///|
async test "h2c: a field block still open at the read timeout, after HEADERS and a CONTINUATION, gets GOAWAY NO_ERROR, unlogged; smock then reads and discards what the client sends, and closes with a FIN a second later" {
  with_definitions([("m.json", slow_uploads)], dir => {
    let stopped = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "600", "--idle-timeout-ms",
        "10000",
      ],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        // A stream answered first, so that the GOAWAY names it.
        raw.send([
          headers_frame(
            1,
            raw.block(request_fields("GET", "/fast", "localhost")),
          ),
        ])
        let answered = raw.frames_until_stream_ends(1)
        let block = raw.block(request_fields("GET", "/fast", "localhost"))
        let half = block.length() / 2
        let start = @async.now()
        raw.send([
          Headers(
            stream_id=3,
            fragment=block[:half].to_owned(),
            end_stream=true,
            end_headers=false,
            priority=None,
            padding=0,
          ),
        ])
        // More of the block, but not its end: the deadline still counts
        // from the HEADERS.
        @async.sleep(300)
        raw.send([
          Continuation(
            stream_id=3,
            fragment=block[half:half + 1].to_owned(),
            end_headers=false,
          ),
        ])
        let goaway = raw.frames_until(start, is_goaway)
        // The rest of the block, and a PING, as a client might send before
        // it reads the GOAWAY: neither is answered.
        raw.send([
          Continuation(
            stream_id=3,
            fragment=block[half + 1:].to_owned(),
            end_headers=true,
          ),
          Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x01", ack=false),
        ])
        let after = raw.frames_until(start, _ => false)
        inspect(
          [
            answered,
            "---",
            ..goaway.shown,
            "GOAWAY after at least 600 ms: \{goaway.end_ms >= 600}, before 900 ms: \{goaway.end_ms < 900}",
            "then: \{after.shown.length()} frames, \{after.how}, about a second after the GOAWAY: \{after.end_ms - goaway.end_ms >= 800 && after.end_ms - goaway.end_ms < 2000}",
          ].join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
            #|DATA 1 END_STREAM 4 octets
            #|---
            #|GOAWAY last=1 NO_ERROR
            #|GOAWAY after at least 600 ms: true, before 900 ms: true
            #|then: 0 frames, a FIN, about a second after the GOAWAY: true
          ),
        )
      },
    )
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}

///|
async test "h2c: a connection with no stream gets GOAWAY NO_ERROR at the idle timeout, although its client sends PING, SETTINGS and WINDOW_UPDATE all along; a PING after it is read and not answered, and the connection ends with a FIN a second later" {
  with_definitions([("m.json", slow_uploads)], dir => {
    let stopped = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "10000", "--idle-timeout-ms",
        "1000",
      ],
      smock => {
        // Timed from before smock can have started its idle timeout.
        let start = @async.now()
        let raw = smock.raw_h2()
        defer raw.close()
        let ping = b"\x00\x00\x00\x00\x00\x00\x00\x02"
        // Every 200 ms, until the GOAWAY comes: each round is answered.
        let mut rounds = 0
        let goaway = for ;; {
          raw.send([
            Settings(params=[], ack=false),
            WindowUpdate(stream_id=0, increment=1),
            Ping(payload=ping, ack=false),
          ])
          let frames = raw.frames_until(start, frame => {
            frame is Ping(ack=true, ..) || is_goaway(frame)
          })
          if frames.shown is [.., last] && last.has_prefix("GOAWAY") {
            break frames
          }
          rounds += 1
          @async.sleep(200)
        }
        raw.send([Ping(payload=ping, ack=false)])
        let after = raw.frames_until(start, _ => false)
        guard goaway.shown is [.., shown] else { fail("no GOAWAY") }
        inspect(
          [
            "rounds answered before it: \{rounds >= 3}",
            "\{shown}, after at least 1000 ms: \{goaway.end_ms >= 1000}, before 2000 ms: \{goaway.end_ms < 2000}",
            "then: \{after.shown.length()} frames, \{after.how}, about a second after the GOAWAY: \{after.end_ms - goaway.end_ms >= 800 && after.end_ms - goaway.end_ms < 2000}",
          ].join("\n"),
          content=(
            #|rounds answered before it: true
            #|GOAWAY last=0 NO_ERROR, after at least 1000 ms: true, before 2000 ms: true
            #|then: 0 frames, a FIN, about a second after the GOAWAY: true
          ),
        )
      },
    )
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}

///|
async test "h2c: a new stream restarts the idle timeout: a request still arriving at the idle deadline holds it off, and the idle timeout then runs from its response" {
  with_definitions([("m.json", slow_uploads)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "10000", "--idle-timeout-ms",
        "1000",
      ],
      smock => {
        let start = @async.now()
        let raw = smock.raw_h2()
        defer raw.close()
        @async.sleep(600)
        // An upload that begins before the idle deadline and ends after it.
        raw.send([
          headers_frame(
            1,
            raw.block(request_fields("POST", "/upload", "localhost")),
            end_stream=false,
          ),
        ])
        @async.sleep(700)
        raw.send([Data(stream_id=1, data=b"body", end_stream=true, padding=0)])
        let answered = raw.frames_until_stream_ends(1)
        let answered_ms = @async.now() - start
        let goaway = raw.frames_until(start, is_goaway)
        let after = raw.frames_until(start, _ => false)
        inspect(
          [
            answered,
            "---",
            ..goaway.shown,
            "a second after the response, not after the connection opened: \{goaway.end_ms >= 2300 && goaway.end_ms - answered_ms >= 900}",
            "then \{after.how}",
          ].join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 8]
            #|DATA 1 END_STREAM 8 octets
            #|---
            #|GOAWAY last=1 NO_ERROR
            #|a second after the response, not after the connection opened: true
            #|then a FIN
          ),
        )
      },
    )
  })
}

///|
async test "h2c: a field block that has begun holds off the idle timeout, so a read timeout longer than it gives the block the whole read timeout to arrive" {
  with_definitions([("m.json", slow_uploads)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "1500", "--idle-timeout-ms",
        "300",
      ],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        let block = raw.block(request_fields("GET", "/fast", "localhost"))
        let half = block.length() / 2
        raw.send([
          Headers(
            stream_id=1,
            fragment=block[:half].to_owned(),
            end_stream=true,
            end_headers=false,
            priority=None,
            padding=0,
          ),
        ])
        @async.sleep(800)
        raw.send([
          Continuation(
            stream_id=1,
            fragment=block[half:].to_owned(),
            end_headers=true,
          ),
        ])
        inspect(
          raw.frames_until_stream_ends(1),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
            #|DATA 1 END_STREAM 4 octets
          ),
        )
      },
    )
  })
}

///|
async test "h2c: smock's own waits do not count: neither timeout runs while a delayed response waits, and the idle timeout runs from that response" {
  with_definitions([("m.json", delays)], dir => {
    let _ = with_smock(
      [
        "--dir", dir, "--port", "0", "--read-timeout-ms", "300", "--idle-timeout-ms",
        "500",
      ],
      smock => {
        let start = @async.now()
        let raw = smock.raw_h2()
        defer raw.close()
        raw.send([
          headers_frame(
            1,
            raw.block(request_fields("GET", "/slow", "localhost")),
          ),
        ])
        let answered = raw.frames_until_stream_ends(1)
        let answered_ms = @async.now() - start
        let goaway = raw.frames_until(start, is_goaway)
        inspect(
          [
            answered,
            "---",
            ..goaway.shown,
            "answered after the delay: \{answered_ms >= 1000}, GOAWAY about 500 ms after it: \{goaway.end_ms - answered_ms >= 400 && goaway.end_ms - answered_ms < 1500}",
          ].join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
            #|DATA 1 END_STREAM 4 octets
            #|---
            #|GOAWAY last=1 NO_ERROR
            #|answered after the delay: true, GOAWAY about 500 ms after it: true
          ),
        )
      },
    )
  })
}
