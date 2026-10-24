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

///|
/// Mock `m` with a Stub that answers `GET /coin` after a delay drawn from
/// its own generator, seeded: half of the time, from 1 to 1000 ms.
let seeded_delays : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "coin", "mock": "m", "request": { "path": "/coin" },
  #|      "response": { "status": 200, "body": "coin" },
  #|      "fault": {
  #|        "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
  #|        "seed": 42 } } ] }

///|
/// `ms`, how long a request took, as a test shows it against `drawn`, the
/// delay it should have had: `as drawn` when it took at least that long,
/// and not much longer.
fn against_drawn(ms : Int64, drawn : Int64) -> String {
  if ms >= drawn && ms < drawn + 300L {
    "as drawn"
  } else {
    "\{ms} ms"
  }
}

///|
async test "h2c: a delay drawn from a Stub's seed is the same over HTTP/1.1 and HTTP/2, where the streams of one connection wait at once" {
  with_definitions([("m.json", seeded_delays)], dir => {
    let args = ["--dir", dir, "--port", "0"]
    // Each run starts the Stub's generator from its seed. Over HTTP/1.1,
    // the requests go one after another.
    let over_http1 = []
    let _ = with_smock(args, smock => {
      for _ in 0..<8 {
        let conn = smock.connect()
        defer conn.close()
        let start = @async.now()
        conn.write("GET /coin HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let _ = read_response(conn)
        over_http1.push(@async.now() - start)
      }
    })
    // Over HTTP/2, the eight streams of one connection are sent at once,
    // so each takes its own delay from when it was sent.
    let over_http2 = []
    let _ = with_smock(args, smock => {
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let streams = []
      for _ in 0..<8 {
        streams.push(client.send("GET", "/coin", authority="localhost"))
      }
      let ended = Map([])
      while ended.length() < streams.length() {
        match client.read_event() {
          End(stream~) => ended[stream] = @async.now() - start
          Closed => fail("smock closed the connection")
          _ => ()
        }
      }
      for stream in streams {
        over_http2.push(ended.get(stream).unwrap())
      }
    })
    // The delays the engine's own tests pin for seed 42: each request draws
    // whether it waits, then how long, before anything else.
    let drawn = [0L, 0, 395, 572, 818, 0, 594, 0]
    let out = []
    for i, ms in drawn {
      out.push(
        "\{ms} ms: HTTP/1.1 \{against_drawn(over_http1[i], ms)}, HTTP/2 \{against_drawn(over_http2[i], ms)}",
      )
    }
    inspect(
      out.join("\n"),
      content=(
        #|0 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|0 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|395 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|572 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|818 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|0 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|594 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
        #|0 ms: HTTP/1.1 as drawn, HTTP/2 as drawn
      ),
    )
  })
}

///|
/// Mock `m` with a Stub that answers `GET /big` with a body of 65,536
/// octets after a fixed delay of 300 ms.
fn big_delayed() -> String {
  let body = StringBuilder()
  for _ in 0..<65536 {
    body.write_char('x')
  }
  (
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
    #|      "fault": { "delay": { "fixed": 300 } },
  ) +
  "\"response\": { \"status\": 200, \"body\": \"\{body.to_string()}\" } } ] }"
}

///|
async test "h2c: 100 delayed streams whose responses are queued at once, while the client reads nothing, all go out through the connection's one writer, and a 101st stream, past the concurrent streams, is refused" {
  with_definitions([("m.json", big_delayed())], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      // Windows wide open, so that each body fits them and is queued whole
      // once its delay is over.
      raw.send([
        Settings(params=[(0x4, 0x7fffffff)], ack=false),
        WindowUpdate(stream_id=0, increment=0x7fffffff - 65535),
      ])
      let requests = []
      for i in 0..<101 {
        requests.push(raw.get(2 * i + 1, "/big"))
      }
      raw.send(requests)
      // The delays end together, and the responses fill the socket long
      // before the client reads.
      @async.sleep(1000)
      let received = Map([])
      let ended = []
      let others = []
      while ended.length() + others.length() < 101 {
        guard raw.read_frame() is Some(frame) else {
          others.push("closed")
          break
        }
        match frame {
          Data(stream_id~, data~, end_stream~, ..) => {
            received[stream_id] = received.get(stream_id).unwrap_or(0) +
              data.length()
            if end_stream {
              ended.push(stream_id)
            }
          }
          Headers(..) | Settings(..) => ()
          _ => others.push(raw.render_frame(frame))
        }
      }
      let whole = ended.filter(stream => received.get(stream) == Some(65536))
      inspect(
        [
          "streams answered in full: \{whole.length()}",
          "the last answered: \{ended.iter().fold(init=0, Int32::max)}",
          ..others,
        ].join("\n"),
        content=(
          #|streams answered in full: 100
          #|the last answered: 199
          #|RST_STREAM 201 REFUSED_STREAM
        ),
      )
    })
  })
}

///|
async test "h2c: a delayed response is framed as one answered at once: to HEAD, its HEADERS carry the length of the body and end the stream" {
  with_definitions([("m.json", delays)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        Headers(
          stream_id=1,
          fragment=raw.block([
            (":method", "HEAD"),
            (":scheme", "http"),
            (":path", "/slow"),
            (":authority", "localhost"),
          ]),
          end_stream=true,
          end_headers=true,
          priority=None,
          padding=0,
        ),
      ])
      inspect(
        raw.frames_until_end_of(1),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=65536]
          #|SETTINGS ACK
          #|HEADERS 1 END_STREAM END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
        ),
      )
    })
  })
}
