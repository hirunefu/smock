// Seam 2 tests of the defences of an HTTP/2 connection, over h2c, sent as
// raw frames with moonhttp's frame encoder: a client that sends more than
// 100 frames that do no work in one second gets GOAWAY ENHANCE_YOUR_CALM,
// the connection closes, and smock logs one line that names the pattern.
// A fresh connection is served right after.

///|
/// `lines`, one per line, with a run of the same line shown once, followed
/// by ` x<n>` when it comes `n` times in a row.
fn runs(lines : Array[String]) -> String {
  let out = []
  let mut i = 0
  while i < lines.length() {
    let mut n = 1
    while i + n < lines.length() && lines[i + n] == lines[i] {
      n += 1
    }
    out.push(if n == 1 { lines[i] } else { "\{lines[i]} x\{n}" })
    i += n
  }
  out.join("\n")
}

///|
/// Reads frames until smock ends the connection, and shows them as `runs`
/// does, then how it ended: `a FIN`, or `an RST`.
async fn RawH2::runs_until_closed(self : RawH2) -> String {
  let frames = self.frames_until(@async.now(), _ => false)
  "\{runs(frames.shown)}\nthen \{frames.how}"
}

///|
/// The PING frame a test floods smock with.
let ping : @http2.Frame = Ping(
  payload=b"\x00\x00\x00\x00\x00\x00\x00\x07",
  ack=false,
)

///|
/// `frame`, `n` times.
fn times(frame : @http2.Frame, n : Int32) -> Array[@http2.Frame] {
  Array::make(n, frame)
}

///|
/// What a fresh connection gets for `GET /fast`, as a test shows it: to the
/// plain port, or with `tls` to the TLS port.
async fn Smock::fresh(self : Smock, tls~ : Bool = false) -> String {
  let client = if tls { self.h2() } else { self.h2c() }
  defer client.close()
  let response = client.request("GET", "/fast", authority="localhost")
  "then a fresh connection: \{response.status} \{@utf8.decode_lossy(response.body)}"
}

///|
/// The log lines of the connections a defence closed, as `log_entries`
/// shows them.
fn defence_entries(logs : Array[String]) -> String {
  log_entries(logs.filter(line => line.contains("closed by a defence")))
}

///|
/// Sends `n` PINGs on `raw` in one write, and reads smock's answers until
/// it has acknowledged them all, or sent a GOAWAY.
async fn RawH2::pings(self : RawH2, n : Int32) -> Frames {
  self.send(times(ping, n))
  let mut acks = 0
  self.frames_until(@async.now(), frame => {
    if frame is Ping(ack=true, ..) {
      acks += 1
    }
    acks == n || is_goaway(frame)
  })
}

///|
/// Opens a connection, sends the frames `setup` makes, and reads smock's
/// answers until `ready` holds for one; then sends the frames `flood`
/// makes, in one write, and shows, after `label`, what smock sends until
/// it ends the connection, then what a fresh connection gets. The client's
/// SETTINGS is one frame that does no work, so a flood that comes to 100
/// more passes the bound with its last frame. With `tls`, both connections
/// go to the TLS port.
async fn Smock::flood(
  self : Smock,
  label : String,
  setup~ : (RawH2) -> Array[@http2.Frame] = _ => [],
  ready~ : (@http2.Frame) -> Bool = frame => frame is Settings(ack=true, ..),
  tls~ : Bool = false,
  flood : (RawH2) -> Array[@http2.Frame],
) -> String {
  let raw = self.raw_h2(tls~)
  defer raw.close()
  raw.send(setup(raw))
  let before = raw.frames_until(@async.now(), frame => {
    ready(frame) || is_goaway(frame)
  })
  raw.send(flood(raw))
  [
    "\{label}:",
    runs(before.shown),
    "flood:",
    raw.runs_until_closed(),
    self.fresh(tls~),
  ].join("\n")
}

///|
async test "h2c: 100 frames that do no work in one second, the client's SETTINGS and 99 PINGs, are answered, and one more PING gets GOAWAY ENHANCE_YOUR_CALM, after which the connection closes, smock logs one line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let answered = raw.pings(99)
      raw.send([ping])
      inspect(
        [
          runs(answered.shown),
          "one more PING:",
          raw.runs_until_closed(),
          smock.fresh(),
        ].join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|PING ACK x99
          #|one more PING:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
      ),
    )
  })
}

///|
async test "h2c: frames that do no work, no more than 100 in any one second, are never cut, however many come in all: three rounds of 60 PINGs, 1.1 seconds apart, are answered, and so is a request after them" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let out = []
      for round in 1..<=3 {
        if round > 1 {
          @async.sleep(1100)
        }
        out.push("round \{round}:")
        out.push(runs(raw.pings(60).shown))
      }
      raw.send([raw.get(1, "/fast")])
      out.push(raw.frames_until_stream_ends(1))
      inspect(
        out.join("\n"),
        content=(
          #|round 1:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|PING ACK x60
          #|round 2:
          #|PING ACK x60
          #|round 3:
          #|PING ACK x60
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a client that sends a PING after each DATA frame it receives is not cut, at over 100 PINGs a second, while a body streams to it, since smock sent DATA since its last PING; the same PINGs with no traffic are cut" {
  with_definitions(flow_definitions(), dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      // Windows of 1,000 octets on each stream, and a connection window
      // wide enough for the whole body: one DATA frame for each grant.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1000)],
          ack=false,
        ),
        WindowUpdate(stream_id=0, increment=1_000_000),
        raw.get(1, "/big"),
      ])
      // When each PING went out.
      let sent_at = []
      let shown = []
      // The DATA frames of stream 1 so far, and their octets.
      let mut frames = 0
      let mut octets = 0
      for ;; {
        guard raw.read_frame() is Some(frame) else {
          shown.push("closed")
          break
        }
        match frame {
          Data(stream_id=1, data~, end_stream~, ..) => {
            frames += 1
            octets += data.length()
            if end_stream {
              shown.push(
                "DATA 1 END_STREAM: \{frames} frames, \{octets} octets",
              )
              break
            }
            sent_at.push(@async.now())
            raw.send([ping, WindowUpdate(stream_id=1, increment=data.length())])
          }
          Ping(ack=true, ..) => ()
          _ => shown.push(raw.render_frame(frame))
        }
      }
      // Whether 101 PINGs went out within one second.
      let mut fast = false
      for i = 0; i + 100 < sent_at.length(); i = i + 1 {
        if sent_at[i + 100] - sent_at[i] < 1000 {
          fast = true
        }
      }
      raw.send([raw.get(3, "/item")])
      shown.push(raw.frames_until_stream_ends(3))
      shown.push(
        "\{sent_at.length()} PINGs, over 100 within one second: \{fast}",
      )
      // One PING at a time, each after the acknowledgement of the last,
      // with nothing else.
      let idle = smock.raw_h2()
      defer idle.close()
      let mut pings = 0
      let alone = for ;; {
        idle.send([ping])
        pings += 1
        let frames = idle.frames_until(@async.now(), frame => {
          frame is Ping(ack=true, ..)
        })
        if frames.how != "open" || pings == 150 {
          break frames
        }
      }
      shown.push("with no traffic, after \{pings} PINGs:")
      shown.push(runs(alone.shown))
      shown.push("then \{alone.how}")
      inspect(
        shown.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1 END_STREAM: 150 frames, 150000 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM 5 octets
          #|149 PINGs, over 100 within one second: true
          #|with no traffic, after 100 PINGs:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
      ),
    )
  })
}

///|
async test "h2c: floods of PRIORITY frames, frames of unknown types, PING acknowledgements and SETTINGS acknowledgements past those smock is owed each get GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      out.push(
        smock.flood("PRIORITY on a stream not yet used", _ => {
          times(
            Priority(stream_id=3, priority={
              exclusive: false,
              stream_dependency: 0,
              weight: 16,
            }),
            100,
          )
        }),
      )
      out.push(
        smock.flood("frames of an unknown type", _ => {
          times(Unknown(ftype=0xfa, flags=0, stream_id=0, payload=b"x"), 100)
        }),
      )
      out.push(
        smock.flood("PING acknowledgements, while smock sent no PING", _ => {
          times(
            Ping(payload=b"\x00\x00\x00\x00\x00\x00\x00\x07", ack=true),
            100,
          )
        }),
      )
      out.push(
        smock.flood("SETTINGS acknowledgements, while smock is owed one", _ => {
          times(Settings(params=[], ack=true), 101)
        }),
      )
      inspect(
        out.join("\n"),
        content=(
          #|PRIORITY on a stream not yet used:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|frames of an unknown type:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|PING acknowledgements, while smock sent no PING:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|SETTINGS acknowledgements, while smock is owed one:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=0 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PRIORITY"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"unknown type"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING acknowledgement"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"SETTINGS acknowledgement"}
      ),
    )
  })
}

///|
async test "h2c: floods of empty DATA frames, padded or not, of WINDOW_UPDATE, RST_STREAM and DATA frames on a closed stream, and of HEADERS on a stream smock reset each get GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      // A request whose body is still to come keeps stream 1 open.
      out.push(
        smock.flood(
          "DATA frames that carry no data and end no stream",
          setup=raw => {
            [
              headers_frame(
                1,
                raw.block(request_fields("POST", "/fast", "localhost")),
                end_stream=false,
              ),
            ]
          },
          _ => {
            let frames = []
            for i in 0..<100 {
              frames.push(
                @http2.Frame::Data(
                  stream_id=1,
                  data=b"",
                  end_stream=false,
                  padding=i % 2 * 4,
                ),
              )
            }
            frames
          },
        ),
      )
      // Stream 1 is closed once its response has ended it.
      let closed = (label, frame) => {
        smock.flood(
          label,
          setup=raw => [raw.get(1, "/fast")],
          ready=frame => ends_stream(frame, 1),
          _ => times(frame, 100),
        )
      }
      out.push(
        closed(
          "WINDOW_UPDATE on a closed stream",
          WindowUpdate(stream_id=1, increment=1),
        ),
      )
      out.push(
        closed(
          "RST_STREAM on a closed stream",
          RstStream(stream_id=1, error_code=@http2.error_cancel),
        ),
      )
      out.push(
        closed(
          "DATA on a closed stream",
          Data(stream_id=1, data=b"x", end_stream=false, padding=0),
        ),
      )
      // A reset Fault ends stream 1 with RST_STREAM.
      out.push(
        smock.flood(
          "HEADERS on a stream smock reset",
          setup=raw => [raw.get(1, "/reset")],
          ready=frame => ends_stream(frame, 1),
          raw => {
            let frames = []
            for _ in 0..<100 {
              frames.push(raw.get(1, "/fast"))
            }
            frames
          },
        ),
      )
      inspect(
        out.join("\n"),
        content=(
          #|DATA frames that carry no data and end no stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|WINDOW_UPDATE on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|RST_STREAM on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|DATA on a closed stream:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|flood:
          #|RST_STREAM 1 STREAM_CLOSED x99
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|HEADERS on a stream smock reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|RST_STREAM 1 INTERNAL_ERROR
          #|flood:
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"empty DATA"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"WINDOW_UPDATE on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"RST_STREAM on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"DATA on a closed stream"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"HEADERS on a stream smock reset"}
      ),
    )
  })
}

///|
async test "h2c: when a defence closes the connection, its streams in progress end with it: a delayed stream's task is cancelled at once, and its entry is committed then" {
  with_definitions([("faults.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let start = @async.now()
      // `GET /slow` waits 1,500 ms before its response.
      let flooded = smock.flood(
        "a PING flood while a delayed stream waits",
        setup=raw => [raw.get(1, "/slow")],
        _ => times(ping, 100),
      )
      let entries = smock.journal_once(2, within=1000)
      let committed_ms = @async.now() - start
      inspect(
        [
          flooded,
          "both committed before the delay was over: \{entries.length() == 2 && committed_ms < 1500}",
          ..entries,
        ].join("\n"),
        content=(
          #|a PING flood while a delayed stream waits:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|flood:
          #|PING ACK x99
          #|GOAWAY last=1 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|both committed before the delay was over: true
          #|/slow: stub "slow", status 200
          #|/fast: stub "fast", status 200
        ),
      )
    })
  })
}

///|
async test "h2 over TLS: a PING flood gets GOAWAY ENHANCE_YOUR_CALM and one log line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    with_certificates(certs => {
      let stopped = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        inspect(
          smock.flood("PING over TLS", tls=true, _ => times(ping, 100)),
          content=(
            #|PING over TLS:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|flood:
            #|PING ACK x99
            #|GOAWAY last=0 ENHANCE_YOUR_CALM
            #|then a FIN
            #|then a fresh connection: 200 fast
          ),
        )
      })
      inspect(
        defence_entries(stopped.logs),
        content=(
          #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"frames that do no work","frame":"PING"}
        ),
      )
    })
  })
}
