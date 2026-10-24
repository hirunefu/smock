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
