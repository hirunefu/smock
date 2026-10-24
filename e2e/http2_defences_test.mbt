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
/// What a fresh connection gets for `GET /fast`, as a test shows it.
async fn Smock::fresh(self : Smock) -> String {
  let client = self.h2c()
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
async test "h2c: 100 frames that do no work in one second, the client's SETTINGS and 99 PINGs, are answered, and one more PING gets GOAWAY ENHANCE_YOUR_CALM, after which the connection closes, smock logs one line, and a fresh connection is served" {
  with_definitions([("faults.json", faults)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send(times(ping, 99))
      let answered = raw.frames_until(
        @async.now(),
        {
          let mut acks = 0
          frame => {
            if frame is Ping(ack=true, ..) {
              acks += 1
            }
            acks == 99 || is_goaway(frame)
          }
        },
      )
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
