// Seam 2 tests of the defence against Rapid Reset (CVE-2023-44487) and
// MadeYouReset (CVE-2025-8671), over h2c, sent as raw frames with
// moonhttp's frame encoder: a client whose streams end reset before smock
// has finished their responses, by the client's RST_STREAM or by moonhttp
// for a stream error the client's frames caused, gets GOAWAY
// ENHANCE_YOUR_CALM once more than 100 of them have, if they are also more
// than half of all the streams it opened. The connection closes, smock logs
// one line that names the pattern, and a fresh connection is served right
// after. smock's own resets never count.

///|
/// Mock `m` with Stubs that answer `GET /slow` after a fixed delay of
/// 2000 ms, `/fast` at once, `/events` with two events, the first after
/// 2000 ms, `/reset` with a reset Fault at probability 1, and a CONNECT
/// with 200 and no body.
let rapid : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "tunnel", "mock": "m", "request": { "method": "CONNECT" },
  #|      "response": { "status": 200 } },
  #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 2000 } } },
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } },
  #|    { "id": "events", "mock": "m", "request": { "path": "/events" },
  #|      "response": { "status": 200,
  #|        "events": [{ "delay": 2000, "data": "first" }, { "data": "last" }] } },
  #|    { "id": "reset", "mock": "m", "request": { "path": "/reset" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "reset", "probability": 1 } } } ] }

///|
/// `shown`, a frame as `render_frame` shows it, with the stream ID it
/// names as `n`, so that the like frames of many streams show alike.
fn any_stream(shown : String) -> String {
  let words = shown.split(" ").map(word => word.to_owned()).collect()
  if words.length() > 1 &&
    words[1] != "" &&
    words[1].iter().all(c => c >= '0' && c <= '9') {
    words[1] = "n"
  }
  words.join(" ")
}

///|
/// `lines`, each with its stream ID as `n` (`any_stream`), and each such
/// line once, in the order it first came, followed by ` x<n>` when it came
/// `n` times in all.
fn tally(lines : Array[String]) -> String {
  let counts : Map[String, Int32] = Map([])
  for line in lines {
    let key = any_stream(line)
    counts[key] = counts.get(key).unwrap_or(0) + 1
  }
  let out = []
  for line, n in counts {
    out.push(if n == 1 { line } else { "\{line} x\{n}" })
  }
  out.join("\n")
}

///|
/// Sends a PING, and shows what smock sends until it acknowledges it, as
/// `tally` does, or, when smock ends the connection first, that and how it
/// ended.
async fn RawH2::fenced(self : RawH2) -> String {
  self.send([fence])
  let frames = self.frames_until(@async.now(), frame => {
    frame is Ping(ack=true, ..)
  })
  if frames.how == "open" {
    tally(frames.shown)
  } else {
    "\{tally(frames.shown)}\nthen \{frames.how}"
  }
}

///|
/// Reads frames until smock ends the connection, and shows them as `tally`
/// does, then how it ended: `a FIN`, or `an RST`.
async fn RawH2::tally_until_closed(self : RawH2) -> String {
  let frames = self.frames_until(@async.now(), _ => false)
  "\{tally(frames.shown)}\nthen \{frames.how}"
}

///|
/// For each of `n` streams from `first` on, a request for `path` to
/// `localhost`, then the client's RST_STREAM CANCEL on that stream: a GET,
/// whose HEADERS end the stream, or with `unfinished`, a POST whose body
/// is still to come.
fn RawH2::cancelled(
  self : RawH2,
  first : Int32,
  n : Int32,
  path : String,
  unfinished~ : Bool = false,
) -> Array[@http2.Frame] {
  let meth = if unfinished { "POST" } else { "GET" }
  let frames = []
  for i in 0..<n {
    let stream = first + 2 * i
    frames.push(
      headers_frame(
        stream,
        self.block(request_fields(meth, path, "localhost")),
        end_stream=!unfinished,
      ),
    )
    frames.push(RstStream(stream_id=stream, error_code=@http2.error_cancel))
  }
  frames
}

///|
async test "h2c: Rapid Reset with a delayed Stub: 100 streams that the client resets during their delays leave the connection open, and the 101st gets GOAWAY ENHANCE_YOUR_CALM; the connection closes, smock logs one line, each reset stream's task has ended at once, and a fresh connection is served" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      raw.send(raw.cancelled(1, 100, "/slow"))
      let open = raw.fenced()
      raw.send(raw.cancelled(201, 1, "/slow"))
      let closed = raw.tally_until_closed()
      let fresh = smock.fresh()
      let entries = smock.journal_once(102, within=1000, limit=1000)
      let committed_ms = @async.now() - start
      inspect(
        [
          "100 streams reset:",
          open,
          "one more:",
          closed,
          fresh,
          "every entry committed before the delay was over: \{entries.length() == 102 && committed_ms < 2000}",
          tally(entries),
        ].join("\n"),
        content=(
          #|100 streams reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|PING ACK
          #|one more:
          #|GOAWAY last=201 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|every entry committed before the delay was over: true
          #|/slow: stub "slow", status 200 x101
          #|/fast: stub "fast", status 200
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
      ),
    )
  })
}

///|
async test "h2c: Rapid Reset with a fast Stub: streams answered at once have ended before the client's resets arrive, which do not count; 100 streams reset while their requests arrive leave the connection open, and the 101st gets GOAWAY ENHANCE_YOUR_CALM; after 150 streams answered, it takes more than 150 such resets, more than half of all the streams begun" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let raw = smock.raw_h2()
      raw.send(raw.cancelled(1, 50, "/fast"))
      out.push("50 streams answered, then reset:")
      out.push(raw.fenced())
      raw.send(raw.cancelled(101, 100, "/fast", unfinished=true))
      out.push("100 streams reset while their requests arrive:")
      out.push(raw.fenced())
      raw.send(raw.cancelled(301, 1, "/fast", unfinished=true))
      out.push("one more:")
      out.push(raw.tally_until_closed())
      raw.close()
      out.push(smock.fresh())
      let answered = smock.raw_h2()
      defer answered.close()
      let gets = []
      for i in 0..<150 {
        gets.push(answered.get(2 * i + 1, "/fast"))
      }
      answered.send(gets)
      out.push("150 streams answered:")
      out.push(answered.fenced())
      answered.send(answered.cancelled(301, 150, "/fast", unfinished=true))
      out.push("150 streams reset while their requests arrive:")
      out.push(answered.fenced())
      answered.send(answered.cancelled(601, 1, "/fast", unfinished=true))
      out.push("one more:")
      out.push(answered.tally_until_closed())
      out.push(smock.fresh())
      inspect(
        out.join("\n"),
        content=(
          #|50 streams answered, then reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS n END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4] x50
          #|DATA n END_STREAM 4 octets x50
          #|PING ACK
          #|100 streams reset while their requests arrive:
          #|PING ACK
          #|one more:
          #|GOAWAY last=301 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|150 streams answered:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS n END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4] x150
          #|DATA n END_STREAM 4 octets x150
          #|PING ACK
          #|150 streams reset while their requests arrive:
          #|PING ACK
          #|one more:
          #|GOAWAY last=601 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"RST_STREAM"}
      ),
    )
  })
}

///|
/// For each of `n` streams from `first` on, the HEADERS frame of a request
/// for `GET /fast` with the field `extra`, which ends the stream.
fn RawH2::gets_with(
  self : RawH2,
  first : Int32,
  n : Int32,
  extra : Array[(String, String)],
) -> Array[@http2.Frame] {
  let frames = []
  for i in 0..<n {
    frames.push(
      headers_frame(
        first + 2 * i,
        self.block([..request_fields("GET", "/fast", "localhost"), ..extra]),
      ),
    )
  }
  frames
}

///|
async test "h2c: streams that moonhttp refuses at open count toward the bound: 101 with an upper-case field name get GOAWAY ENHANCE_YOUR_CALM; REFUSED_STREAM past the concurrent-streams limit counts only once the client has acknowledged smock's SETTINGS" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "1"],
      smock => {
        let out = []
        let upper = smock.raw_h2()
        upper.send(upper.gets_with(1, 101, [("X-Upper", "1")]))
        out.push("101 streams with an upper-case field name:")
        out.push(upper.tally_until_closed())
        upper.close()
        out.push(smock.fresh())
        // An upload whose body is still to come holds the one stream the
        // limit allows.
        let held = (raw : RawH2) => {
          headers_frame(
            1,
            raw.block(request_fields("POST", "/fast", "localhost")),
            end_stream=false,
          )
        }
        let unacknowledged = smock.raw_h2()
        defer unacknowledged.close()
        unacknowledged.send(
          [held(unacknowledged), ..unacknowledged.gets_with(3, 101, [])],
        )
        out.push("101 streams past the limit, SETTINGS not acknowledged:")
        out.push(unacknowledged.fenced())
        let acknowledged = smock.raw_h2()
        defer acknowledged.close()
        out.push("101 streams past the limit, SETTINGS acknowledged:")
        out.push(acknowledged.acknowledge_settings())
        acknowledged.send(
          [held(acknowledged), ..acknowledged.gets_with(3, 101, [])],
        )
        out.push(acknowledged.tally_until_closed())
        out.push(smock.fresh())
        inspect(
          out.join("\n"),
          content=(
            #|101 streams with an upper-case field name:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|RST_STREAM n PROTOCOL_ERROR x101
            #|GOAWAY last=201 ENHANCE_YOUR_CALM
            #|then a FIN
            #|then a fresh connection: 200 fast
            #|101 streams past the limit, SETTINGS not acknowledged:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|RST_STREAM n REFUSED_STREAM x101
            #|PING ACK
            #|101 streams past the limit, SETTINGS acknowledged:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|RST_STREAM n REFUSED_STREAM x101
            #|GOAWAY last=203 ENHANCE_YOUR_CALM
            #|then a FIN
            #|then a fresh connection: 200 fast
          ),
        )
      },
    )
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"HEADERS"}
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"HEADERS"}
      ),
    )
  })
}

///|
async test "h2c: streams above the final GOAWAY's last stream ID during a drain, which are ignored, do not count toward the bound: 150 of them leave the connection open, and the stream in progress is answered" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let raw = smock.raw_h2()
        defer raw.close()
        raw.send([raw.get(1, "/slow")])
        let start = @async.now()
        smock.terminate()
        let warned = raw.frames_until_ping_acked(start)
        let told = raw.frames_until(start, is_goaway)
        let ignored = []
        for i in 1..<=150 {
          ignored.push(raw.get(2 * i + 1, "/fast"))
        }
        raw.send(ignored)
        let after = raw.frames_until(start, _ => false)
        inspect(
          [
            tally(warned.shown),
            tally(told.shown),
            "150 streams above it:",
            ..after.shown,
            "then \{after.how}",
          ].join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|GOAWAY last=2147483647 NO_ERROR
            #|PING
            #|GOAWAY last=1 NO_ERROR
            #|150 streams above it:
            #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
            #|DATA 1 END_STREAM 4 octets
            #|then a FIN
          ),
        )
      },
    )
    inspect(defence_entries(stopped.logs), content="")
  })
}

///|
async test "h2c: streams that smock resets on its own never count toward the bound: on a connection each, 201 streams end with a reset Fault at probability 1, the read timeout's CANCEL, the CANCEL of a stream window held at zero, NO_ERROR after 413, NO_ERROR after 431, or PROTOCOL_ERROR after 400, and the connection stays open" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(
      [
        "--dir",
        "\{dir}",
        "--port",
        "0",
        "--http2-max-concurrent-streams",
        "1000",
        "--read-timeout-ms",
        "500",
        "--write-timeout-ms",
        "500",
        "--body-limit",
        "16",
        "--header-count-limit",
        "1",
      ],
      smock => {
        // Each kind: its label, the client's SETTINGS, and the request on a
        // stream that smock then resets.
        let kinds : Array[
          (String, Array[(Int32, Int32)], (RawH2, Int32) -> @http2.Frame),
        ] = [
          (
            "a reset Fault at probability 1",
            [],
            (raw, stream) => raw.get(stream, "/reset"),
          ),
          (
            "a request that does not arrive within the read timeout",
            [],
            (raw, stream) => {
              headers_frame(
                stream,
                raw.block(request_fields("POST", "/fast", "localhost")),
                end_stream=false,
              )
            },
          ),
          (
            "a stream window held at zero for the write timeout",
            [(@http2.settings_initial_window_size, 0)],
            (raw, stream) => raw.get(stream, "/fast"),
          ),
          (
            "a body over --body-limit",
            [],
            (raw, stream) => {
              headers_frame(
                stream,
                raw.block(
                  [
                    ..request_fields("POST", "/fast", "localhost"),
                    ("content-length", "17"),
                  ],
                ),
                end_stream=false,
              )
            },
          ),
          (
            "more fields than --header-count-limit",
            [],
            (raw, stream) => {
              headers_frame(
                stream,
                raw.block(
                  [
                    ..request_fields("POST", "/fast", "localhost"),
                    ("x-a", "1"),
                    ("x-b", "2"),
                  ],
                ),
                end_stream=false,
              )
            },
          ),
          (
            "a host that differs from :authority",
            [],
            (raw, stream) => {
              headers_frame(
                stream,
                raw.block(
                  [
                    ..request_fields("POST", "/fast", "localhost"),
                    ("host", "other.example"),
                  ],
                ),
                end_stream=false,
              )
            },
          ),
        ]
        let out = []
        for kind in kinds {
          let (label, params, request) = kind
          let raw = smock.raw_h2(settings=false)
          defer raw.close()
          let frames = [@http2.Frame::Settings(params~, ack=false)]
          for i in 0..<201 {
            frames.push(request(raw, 2 * i + 1))
          }
          raw.send(frames)
          let mut resets = 0
          let reset = raw.frames_until(@async.now(), frame => {
            if frame is RstStream(..) {
              resets += 1
            }
            resets == 201 || is_goaway(frame)
          })
          out.push("\{label}:")
          out.push(tally(reset.shown))
          out.push(raw.fenced())
        }
        inspect(
          out.join("\n"),
          content=(
            #|a reset Fault at probability 1:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|RST_STREAM n INTERNAL_ERROR x201
            #|PING ACK
            #|a request that does not arrive within the read timeout:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|RST_STREAM n CANCEL x201
            #|PING ACK
            #|a stream window held at zero for the write timeout:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS n END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4] x201
            #|RST_STREAM n CANCEL x201
            #|PING ACK
            #|a body over --body-limit:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS n END_STREAM END_HEADERS [:status: 413, date: <now>, content-length: 0] x201
            #|RST_STREAM n NO_ERROR x201
            #|PING ACK
            #|more fields than --header-count-limit:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS n END_STREAM END_HEADERS [:status: 431, date: <now>, content-length: 0] x201
            #|RST_STREAM n NO_ERROR x201
            #|PING ACK
            #|a host that differs from :authority:
            #|SETTINGS [MAX_CONCURRENT_STREAMS=1000, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS n END_STREAM END_HEADERS [:status: 400, date: <now>, content-length: 0] x201
            #|RST_STREAM n PROTOCOL_ERROR x201
            #|PING ACK
          ),
        )
      },
    )
    inspect(defence_entries(stopped.logs), content="")
  })
}

///|
/// What a client sends on `stream`, whose request has ended, for which
/// moonhttp resets the stream (MadeYouReset), of the five `kinds` in turn:
/// a WINDOW_UPDATE of 0, a window overflow, DATA or HEADERS after
/// END_STREAM, or a PRIORITY frame that makes the stream depend on itself.
fn RawH2::made_reset(
  self : RawH2,
  kind : Int32,
  stream : Int32,
) -> @http2.Frame {
  match kind % 5 {
    0 => WindowUpdate(stream_id=stream, increment=0)
    1 => WindowUpdate(stream_id=stream, increment=0x7FFF_FFFF)
    2 => Data(stream_id=stream, data=b"x", end_stream=false, padding=0)
    3 => headers_frame(stream, self.block([("x-late", "1")]))
    _ =>
      Priority(stream_id=stream, priority={
        exclusive: false,
        stream_dependency: stream,
        weight: 16,
      })
  }
}

///|
/// The labels of `RawH2::made_reset`'s kinds.
let made_reset_kinds : Array[String] = [
  "a WINDOW_UPDATE of 0", "a window overflow", "DATA after END_STREAM", "HEADERS after END_STREAM",
  "PRIORITY on the stream itself",
]

///|
async test "h2c: MadeYouReset: delayed and event streams whose requests have ended, reset by moonhttp for a WINDOW_UPDATE of 0, a window overflow, DATA or HEADERS after END_STREAM, or PRIORITY on the stream itself, end their tasks at once; the connection goes on, and a fresh connection is served at once" {
  with_definitions([("m.json", rapid)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      let frames = []
      for kind in 0..<5 {
        for path in ["/slow", "/events"] {
          let stream = frames.length() + 1
          frames.push(raw.get(stream, path))
          frames.push(raw.made_reset(kind, stream))
        }
      }
      raw.send(frames)
      let mut resets = 0
      let reset = raw.frames_until(start, frame => {
        if frame is RstStream(..) {
          resets += 1
        }
        resets == 10 || is_goaway(frame)
      })
      let entries = smock.journal_once(10, within=1000)
      let committed_ms = @async.now() - start
      raw.send([raw.get(21, "/fast")])
      let next = raw.frames_until_stream_ends(21)
      let out = []
      for i, label in made_reset_kinds {
        out.push("\{label}: streams \{4 * i + 1} and \{4 * i + 3}")
      }
      inspect(
        [
          ..out,
          "---",
          ..reset.shown,
          "every entry committed before the delays were over: \{entries.length() == 10 && committed_ms < 2000}",
          tally(entries),
          "---",
          next,
          smock.fresh(),
        ].join("\n"),
        content=(
          #|a WINDOW_UPDATE of 0: streams 1 and 3
          #|a window overflow: streams 5 and 7
          #|DATA after END_STREAM: streams 9 and 11
          #|HEADERS after END_STREAM: streams 13 and 15
          #|PRIORITY on the stream itself: streams 17 and 19
          #|---
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|RST_STREAM 1 PROTOCOL_ERROR
          #|HEADERS 3 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 3 PROTOCOL_ERROR
          #|RST_STREAM 5 FLOW_CONTROL_ERROR
          #|HEADERS 7 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 7 FLOW_CONTROL_ERROR
          #|RST_STREAM 9 STREAM_CLOSED
          #|HEADERS 11 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 11 STREAM_CLOSED
          #|RST_STREAM 13 STREAM_CLOSED
          #|HEADERS 15 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 15 STREAM_CLOSED
          #|RST_STREAM 17 PROTOCOL_ERROR
          #|HEADERS 19 END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>]
          #|RST_STREAM 19 PROTOCOL_ERROR
          #|every entry committed before the delays were over: true
          #|/slow: stub "slow", status 200 x5
          #|/events: stub "events", status 200 x5
          #|---
          #|HEADERS 21 END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>, content-length: 4]
          #|DATA 21 END_STREAM 4 octets
          #|then a fresh connection: 200 fast
        ),
      )
    })
  })
}

///|
async test "h2c: MadeYouReset past the bound: 100 delayed and event streams that moonhttp resets for the client's frames, of the five kinds in turn, leave the connection open, and the 101st gets GOAWAY ENHANCE_YOUR_CALM; smock logs one line, and a fresh connection is served" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let start = @async.now()
      // Each stream on its own, to mix the kinds with both Stubs.
      let made = (first : Int32, n : Int32) => {
        let frames = []
        for i in 0..<n {
          let stream = first + 2 * i
          let path = if i % 2 == 0 { "/slow" } else { "/events" }
          frames.push(raw.get(stream, path))
          frames.push(raw.made_reset(i, stream))
        }
        frames
      }
      raw.send(made(1, 100))
      let open = raw.fenced()
      raw.send(made(201, 1))
      let closed = raw.tally_until_closed()
      let fresh = smock.fresh()
      let entries = smock.journal_once(102, within=1000, limit=1000)
      let committed_ms = @async.now() - start
      inspect(
        [
          "100 streams reset:",
          open,
          "one more:",
          closed,
          fresh,
          "every entry committed before the delays were over: \{entries.length() == 102 && committed_ms < 2000}",
          tally(entries),
        ].join("\n"),
        content=(
          #|100 streams reset:
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|RST_STREAM n PROTOCOL_ERROR x40
          #|HEADERS n END_HEADERS [:status: 200, content-type: text/event-stream, smock-mock: m; via=default, date: <now>] x50
          #|RST_STREAM n FLOW_CONTROL_ERROR x20
          #|RST_STREAM n STREAM_CLOSED x40
          #|PING ACK
          #|one more:
          #|RST_STREAM n PROTOCOL_ERROR
          #|GOAWAY last=201 ENHANCE_YOUR_CALM
          #|then a FIN
          #|then a fresh connection: 200 fast
          #|every entry committed before the delays were over: true
          #|/slow: stub "slow", status 200 x51
          #|/events: stub "events", status 200 x50
          #|/fast: stub "fast", status 200
        ),
      )
    })
    inspect(
      defence_entries(stopped.logs),
      content=(
        #|{"level":"warn","msg":"HTTP/2 connection closed by a defence","pattern":"Rapid Reset","frame":"WINDOW_UPDATE"}
      ),
    )
  })
}

///|
async test "h2c: a stream whose response smock has finished does not count when the client resets it: 101 CONNECTs, each answered with a 2xx that ends the stream on smock's side, then reset by the client while its side is still open, leave the connection open" {
  with_definitions([("m.json", rapid)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let frames = []
      for i in 0..<101 {
        let stream = 2 * i + 1
        frames.push(
          headers_frame(
            stream,
            raw.block(connect_fields("proxy.example.com:443")),
            end_stream=false,
          ),
        )
        frames.push(RstStream(stream_id=stream, error_code=@http2.error_cancel))
      }
      raw.send(frames)
      inspect(
        raw.fenced(),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS n END_STREAM END_HEADERS [:status: 200, smock-mock: m; via=default, date: <now>] x101
          #|PING ACK
        ),
      )
    })
    inspect(defence_entries(stopped.logs), content="")
  })
}
