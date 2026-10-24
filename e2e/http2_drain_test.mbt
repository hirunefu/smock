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
