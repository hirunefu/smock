// Seam 2 tests of flow control over h2c: a response body larger than the
// client's windows goes out as the windows allow, from a task of its own (a
// slow write), which resumes when the client widens a window, while the
// connection's other streams go on.

///|
/// A body of `lines` lines, each a number of seven digits and a newline,
/// counting from 0, so that a part sent twice, lost or out of order shows.
fn numbered(lines : Int32) -> String {
  let out = StringBuilder()
  for i in 0..<lines {
    let digits = i.to_string()
    out.write_string("0".repeat(7 - digits.length()))
    out.write_string(digits)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The body of `GET /big`: 150,000 octets, more than both of the windows a
/// client starts with (65,535 octets each).
let big_body : String = numbered(18_750)

///|
/// Mock `m`, for `localhost`, with Stubs that answer `GET /big` with
/// `big_body`, `GET /item` with a short body, and `GET /slow-big` with
/// `big_body` after a delay of 300 ms.
fn flow_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" } },
        #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "slow-big", "mock": "m", "request": { "path": "/slow-big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" },
        #|      "fault": { "delay": { "fixed": 300 } } } ] }
      ),
    ),
    ("files/big.txt", big_body),
  ]
}

///|
/// A response as a test shows it, with its body replaced by whether it is
/// `expected`, and its length.
fn H2Response::checked(self : H2Response, expected : String) -> String {
  let body = @utf8.decode_lossy(self.body)
  let shown : H2Response = { ..self, body: b"", }
  let gap = if self.ended == "end" { "" } else { "\n" }
  "\{shown.render()}\{gap}body: \{self.body.length()} octets, as the Stub gives it: \{body == expected}"
}

///|
async test "h2c: a response body larger than both of the client's windows goes out within them, as the client widens them, and arrives in full" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let response = client.request("GET", "/big", authority="localhost")
      let entries = smock.journal_once(1, within=1000)
      inspect(
        [response.checked(big_body), ..entries].join("\n"),
        content=(
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}
