// Seam 2 tests of the drain of HTTP/2 connections on SIGTERM, over h2c:
// smock's first GOAWAY, which names the highest stream ID there is, and its
// PING; the final GOAWAY, naming the last stream smock received, once the
// client acknowledges the PING or a second later; the streams that finish
// and those the client sends again elsewhere; and the close after the
// GOAWAY, or at the drain timeout.

///|
/// Whether `frame` is the PING smock sends, not an acknowledgement.
fn is_ping(frame : @http2.Frame) -> Bool {
  frame is Ping(ack=false, ..)
}

///|
/// Reads frames from smock as `frames_until` does, until smock's PING, and
/// acknowledges it, as a client does.
async fn RawH2::frames_until_ping_acked(self : RawH2, since : Int64) -> Frames {
  let payload = Ref(b"")
  let frames = self.frames_until(since, frame => {
    guard frame is Ping(payload=p, ack=false) else { return false }
    payload.val = p
    true
  })
  self.send([Ping(payload=payload.val, ack=true)])
  frames
}

///|
async test "h2c: on SIGTERM, a connection with no stream in progress gets GOAWAY NO_ERROR naming 2^31-1 and a PING; then the final GOAWAY, naming the last stream received, once the client acknowledges the PING, or a second later when it does not; and a FIN a second after that, well before the drain timeout" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let acking = smock.raw_h2()
        defer acking.close()
        let silent = smock.raw_h2()
        defer silent.close()
        // A stream answered first on each, so that the final GOAWAY names
        // it.
        for raw in [acking, silent] {
          raw.send([
            headers_frame(
              1,
              raw.block(request_fields("GET", "/fast", "localhost")),
            ),
          ])
          let _ = raw.frames_until_stream_ends(1)
        }
        let start = @async.now()
        smock.terminate()
        let (acked, unacked) = @async.with_task_group(group => {
          let acked = group.spawn(() => {
            let warned = acking.frames_until_ping_acked(start)
            let told = acking.frames_until(start, is_goaway)
            let after = acking.frames_until(start, _ => false)
            [
              "a client that acknowledges the PING:",
              ..warned.shown,
              "both at once: \{warned.end_ms < 1000}",
              ..told.shown,
              "at once after the acknowledgement: \{told.end_ms - warned.end_ms < 500}",
              "then: \{after.shown.length()} frames, \{after.how}, about a second after the final GOAWAY: \{after.end_ms - told.end_ms >= 800 && after.end_ms - told.end_ms < 2000}",
            ]
          })
          let unacked = group.spawn(() => {
            let warned = silent.frames_until(start, is_ping)
            let told = silent.frames_until(start, is_goaway)
            let after = silent.frames_until(start, _ => false)
            [
              "a client that does not:",
              ..warned.shown,
              "both at once: \{warned.end_ms < 1000}",
              ..told.shown,
              "about a second after the PING: \{told.end_ms - warned.end_ms >= 800 && told.end_ms - warned.end_ms < 2000}",
              "then: \{after.shown.length()} frames, \{after.how}, about a second after the final GOAWAY: \{after.end_ms - told.end_ms >= 800 && after.end_ms - told.end_ms < 2000}",
            ]
          })
          (acked.wait(), unacked.wait())
        })
        let status = smock.exited()
        let exited = @async.now() - start
        inspect(
          [
            ..acked,
            ..unacked,
            "exit status \{status}, well before the drain timeout: \{exited < 5000}",
          ].join("\n"),
          content=(
            #|a client that acknowledges the PING:
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|both at once: true
            #|GOAWAY last=1 NO_ERROR
            #|at once after the acknowledgement: true
            #|then: 0 frames, a FIN, about a second after the final GOAWAY: true
            #|a client that does not:
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|both at once: true
            #|GOAWAY last=1 NO_ERROR
            #|about a second after the PING: true
            #|then: 0 frames, a FIN, about a second after the final GOAWAY: true
            #|exit status 0, well before the drain timeout: true
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":10000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
async test "h2c: of requests sent continuously while SIGTERM arrives, each is answered or above the final GOAWAY's last stream ID, and none ends in a connection reset" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        // A client that sends a request every 20 ms and reads nothing
        // meanwhile, so that it neither sees the GOAWAYs nor acknowledges
        // the PING: ten requests before SIGTERM, then more for 1.5 s.
        let sent = []
        let mut signalled = None
        for i = 0; ; i = i + 1 {
          if i == 10 {
            smock.terminate()
            signalled = Some((@async.now(), 2 * i + 1))
          }
          if signalled is Some((at, _)) && @async.now() - at >= 1500 {
            break
          }
          let stream = 2 * i + 1
          raw.send([
            headers_frame(
              stream,
              raw.block(request_fields("GET", "/fast", "localhost")),
            ),
          ])
          sent.push(stream)
          @async.sleep(20)
        }
        guard signalled is Some((_, first_after)) else { fail("no SIGTERM") }
        let answered = []
        let goaways = []
        let reset = []
        let frames = raw.frames_until(@async.now(), frame => {
          match frame {
            Data(stream_id~, end_stream=true, ..) => answered.push(stream_id)
            GoAway(last_stream_id~, ..) => goaways.push(last_stream_id)
            RstStream(stream_id~, ..) => reset.push(stream_id)
            _ => ()
          }
          false
        })
        guard goaways is [0x7FFF_FFFF, last] else {
          fail(
            "GOAWAY frames naming \{goaways.map(id => id.to_string()).join(", ")}",
          )
        }
        let below = sent.filter(stream => stream <= last)
        let above = sent.filter(stream => stream > last)
        inspect(
          [
            "two GOAWAYs, the final naming a stream the client sent: \{sent.contains(last)}",
            "every stream up to it answered: \{answered == below}",
            "some of them sent after SIGTERM: \{last >= first_after}",
            "some streams above it: \{above.length() > 0}, none of them answered: \{answered.iter().all(stream => stream <= last)}",
            "streams reset: \{reset.length()}",
            "then \{frames.how}",
          ].join("\n"),
          content=(
            #|two GOAWAYs, the final naming a stream the client sent: true
            #|every stream up to it answered: true
            #|some of them sent after SIGTERM: true
            #|some streams above it: true, none of them answered: true
            #|streams reset: 0
            #|then a FIN
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":10000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
/// The frames of `frames` that are not DATA, as `render_frame` shows them.
fn Frames::besides_data(self : Frames) -> Array[String] {
  self.shown.filter(shown => !shown.has_prefix("DATA "))
}

///|
/// How many DATA frames `frames` hold.
fn Frames::data_count(self : Frames) -> Int32 {
  self.shown.filter(shown => shown.has_prefix("DATA ")).length()
}

///|
async test "h2c: an event stream goes on through the drain until it ends, after both GOAWAYs, and its connection then closes with a FIN a second later, well before the drain timeout" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        let start = @async.now()
        // Ten events, one every 100 ms.
        raw.send([
          headers_frame(
            1,
            raw.block(request_fields("GET", "/brief", "localhost")),
          ),
        ])
        let _ = raw.frames_until(start, frame => frame is Headers(..))
        @async.sleep(settle_ms)
        smock.terminate()
        let warned = raw.frames_until_ping_acked(start)
        let told = raw.frames_until(start, is_goaway)
        let rest = raw.frames_until(start, frame => {
          frame is Data(stream_id=1, end_stream=true, ..)
        })
        let after = raw.frames_until(start, _ => false)
        let status = smock.exited()
        let exited = @async.now() - start
        let events = warned.data_count() + told.data_count() + rest.data_count()
        inspect(
          [
            ..warned.besides_data(),
            ..told.besides_data(),
            ..rest.besides_data(),
            "events: \{events}, the last ending the stream: \{rest.shown is [.., "DATA 1 END_STREAM 12 octets"]}, about a second after the request: \{rest.end_ms >= 900}",
            "then: \{after.shown.length()} frames, \{after.how}, about a second after the stream ended: \{after.end_ms - rest.end_ms >= 800 && after.end_ms - rest.end_ms < 2000}",
            "exit status \{status}, well before the drain timeout: \{exited < 5000}",
          ].join("\n"),
          content=(
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|GOAWAY last=1 NO_ERROR
            #|events: 10, the last ending the stream: true, about a second after the request: true
            #|then: 0 frames, a FIN, about a second after the stream ended: true
            #|exit status 0, well before the drain timeout: true
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":10000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
async test "h2c: an event stream that outlasts the drain timeout goes on until the drain timeout cuts its connection, which is counted in connectionsCut" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "1500"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        // A hundred events, one every 100 ms.
        raw.send([
          headers_frame(
            1,
            raw.block(request_fields("GET", "/ticks", "localhost")),
          ),
        ])
        let _ = raw.frames_until(@async.now(), frame => frame is Headers(..))
        @async.sleep(settle_ms)
        let start = @async.now()
        smock.terminate()
        let warned = raw.frames_until_ping_acked(start)
        let rest = raw.frames_until(start, _ => false)
        inspect(
          [
            ..warned.besides_data(),
            ..rest.besides_data(),
            "events during the drain: \{warned.data_count() + rest.data_count() >= 10}, none ending the stream: \{!rest.shown.iter().any(shown => shown.contains("END_STREAM"))}",
            "cut at the drain timeout: \{rest.end_ms >= 1500 && rest.end_ms < 3000}",
          ].join("\n"),
          content=(
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|GOAWAY last=1 NO_ERROR
            #|events during the drain: true, none ending the stream: true
            #|cut at the drain timeout: true
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":1500}
        #|{"level":"info","msg":"drain ended","connectionsCut":1}
      ),
    )
  })
}
