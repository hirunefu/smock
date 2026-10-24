// Seam 2 tests of the streams of one HTTP/2 connection over h2c: a delay
// waits in its own stream's task, so the connection's other streams are
// answered meanwhile, and every byte goes out through the connection's one
// writer.

///|
/// Mock `m` with Stubs that answer `GET /slow` after a fixed delay of
/// 1000 ms, and `GET /fast` at once.
let delays : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1000 } } },
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } } ] }

///|
/// How many of the events `client` has read and kept for later are about
/// `stream`.
fn H2Client::kept_for(self : H2Client, stream : Int32) -> Int32 {
  let mut n = 0
  for event in self.events {
    if event_stream(event) == Some(stream) {
      n += 1
    }
  }
  n
}

///|
async test "h2c: a delayed stream does not hold a fast one on the same connection: the fast stream is answered at once, and the delayed one after its delay" {
  with_definitions([("m.json", delays)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let slow = client.send("GET", "/slow", authority="localhost")
      let fast = client.send("GET", "/fast", authority="localhost")
      let fast_response = client.response(fast)
      let fast_ms = @async.now() - start
      // Events of the delayed stream read meanwhile would be kept for later.
      let early = client.kept_for(slow)
      let slow_response = client.response(slow)
      let slow_ms = @async.now() - start
      inspect(
        [
          "fast answered during the delay: \{fast_ms < 1000}",
          "nothing of the delayed stream came before: \{early == 0}",
          "delayed answered after at least 1000 ms: \{slow_ms >= 1000}",
          "---",
          fast_response.render(),
          "---",
          slow_response.render(),
        ].join("\n"),
        content=(
          #|fast answered during the delay: true
          #|nothing of the delayed stream came before: true
          #|delayed answered after at least 1000 ms: true
          #|---
          #|200
          #|smock-mock: m; via=default
          #|date: <now>
          #|content-length: 4
          #|
          #|fast
          #|---
          #|200
          #|smock-mock: m; via=default
          #|date: <now>
          #|content-length: 4
          #|
          #|slow
        ),
      )
    })
  })
}

///|
/// The HEADERS frame of a GET of `path` on `stream`, which ends the stream.
fn RawH2::get(self : RawH2, stream : Int32, path : String) -> @http2.Frame {
  Headers(
    stream_id=stream,
    fragment=self.block([
      (":method", "GET"),
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
/// Reads frames until one ends `stream`, and shows each as `render_frame`
/// does, one per line.
async fn RawH2::frames_until_end_of(self : RawH2, stream : Int32) -> String {
  let out = []
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    out.push(self.render_frame(frame))
    match frame {
      Data(stream_id~, end_stream=true, ..)
      | Headers(stream_id~, end_stream=true, ..)
      | RstStream(stream_id~, ..) if stream_id == stream => break
      _ => ()
    }
  }
  out.join("\n")
}

///|
/// The Journal's entries, each shown as its target, its Stub and its
/// status, once there are `count` of them, or as they are after `within`
/// milliseconds.
async fn Smock::journal_once(
  self : Smock,
  count : Int32,
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
              ..
            }
          ) else {
          return entry.stringify()
        }
        "\{target}: stub \{stub.stringify()}, status \{status.stringify()}"
      })
    }
    @async.sleep(20)
  }
}

///|
async test "h2c: a stream reset during its delay, by the client or by smock for the client's frames, ends its task at once: its entry is committed then, and no response is written" {
  with_definitions([("m.json", delays)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send([raw.get(1, "/slow"), raw.get(3, "/slow")])
      @async.sleep(200)
      // The client resets stream 1; a WINDOW_UPDATE of 0 on stream 3 is a
      // stream error, for which moonhttp resets it.
      raw.send([
        RstStream(stream_id=1, error_code=@http2.error_cancel),
        WindowUpdate(stream_id=3, increment=0),
      ])
      let entries = smock.journal_once(2, within=600)
      let committed_ms = @async.now() - start
      // Past the delays, a fast stream is answered, and nothing came on the
      // reset streams.
      @async.sleep((1300L - (@async.now() - start)).to_int())
      raw.send([raw.get(5, "/fast")])
      inspect(
        [
          "both committed before the delay was over: \{entries.length() == 2 && committed_ms < 1000}",
          ..entries,
          "---",
          raw.frames_until_end_of(5),
        ].join("\n"),
        content=(
          #|both committed before the delay was over: true
          #|/slow: stub "slow", status 200
          #|/slow: stub "slow", status 200
          #|---
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|RST_STREAM 3 PROTOCOL_ERROR
          #|HEADERS 5 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 5 END_STREAM 4 octets
        ),
      )
    })
  })
}

///|
async test "h2c: when the connection ends during its streams' delays, their tasks end with it: each entry is committed then, and smock goes on serving" {
  with_definitions([("m.json", delays)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      let start = @async.now()
      let _ = client.send("GET", "/slow", authority="localhost")
      let _ = client.send("GET", "/slow?again", authority="localhost")
      // What smock sent so far is read, so that the client's close is a
      // FIN, not a reset.
      for ;; {
        if client.read_event() is SettingsAcked(_) {
          break
        }
      }
      client.flush()
      @async.sleep(200)
      client.close()
      let entries = smock.journal_once(2, within=600)
      let committed_ms = @async.now() - start
      let next = smock.h2c()
      defer next.close()
      let fast = next.request("GET", "/fast", authority="localhost")
      inspect(
        [
          "both committed before the delay was over: \{entries.length() == 2 && committed_ms < 1000}",
          ..entries,
          "---",
          fast.render(),
        ].join("\n"),
        content=(
          #|both committed before the delay was over: true
          #|/slow: stub "slow", status 200
          #|/slow?again: stub "slow", status 200
          #|---
          #|200
          #|smock-mock: m; via=default
          #|date: <now>
          #|content-length: 4
          #|
          #|fast
        ),
      )
    })
  })
}
