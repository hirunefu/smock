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
/// 2000 ms, and `/reset` with a reset Fault at probability 1.
let rapid : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
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
