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
