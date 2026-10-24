// Seam 2 tests of the requests an HTTP/2 stream may carry, over h2c on the
// plain port: a request that HTTP/1.1's rules refuse gets 400 on its stream
// alone, through the HTTP/1.1 codec's own checks, and a stream that breaks
// RFC 9113's field rules is reset with PROTOCOL_ERROR by moonhttp. Either
// way the request never reaches the Mocks, and the connection's other
// streams go on.

///|
/// The response on one stream as a test shows it, on one line: the status,
/// the header fields, and how the stream ended.
fn H2Response::line(self : H2Response) -> String {
  let fields = self.headers.map(header => shown_field(header.0, header.1))
  "\{self.status} [\{fields.join(", ")}] \{self.body.length()} octets, \{self.ended}"
}

///|
async test "h2c: a stream whose request HTTP/1.1 would refuse gets 400 on its stream alone, with no connection field, and the next stream on the connection is served" {
  with_definitions(two_mocks(default=false), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let orders = "orders.example.com"
      let out = []
      for
        case in [
          ("a :path with a space", "GET", "/x y", Some(orders), []),
          ("a :path with a control octet", "GET", "/x\u{01}", Some(orders), []),
          ("a :path with DEL", "GET", "/x\u{7f}", Some(orders), []),
          (
            "a :path with an octet above 0x7E",
            "GET",
            "/caf\u{e9}",
            Some(orders),
            [],
          ),
          ("a :path with a fragment", "GET", "/x#top", Some(orders), []),
          (
            "an absolute-form :path",
            "GET",
            "http://orders.example.com/x",
            Some(orders),
            [],
          ),
          ("a :path of * with GET", "GET", "*", Some(orders), []),
          ("then a request HTTP/1.1 takes", "GET", "/x", Some(orders), []),
        ] {
        let (label, meth, path, authority, headers) = case
        let response = client.request(meth, path, authority?, headers~)
        out.push("\{label}: \{response.line()}")
      }
      let (_, journal) = smock.journal()
      guard journal is Object({ "entries": Array(entries), .. }) else {
        fail("no entries: \{journal.stringify()}")
      }
      out.push("Journal entries: \{entries.length()}")
      inspect(
        out.join("\n"),
        content=(
          #|a :path with a space: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with a control octet: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with DEL: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with an octet above 0x7E: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path with a fragment: 400 [date: <now>, content-length: 0] 0 octets, end
          #|an absolute-form :path: 400 [date: <now>, content-length: 0] 0 octets, end
          #|a :path of * with GET: 400 [date: <now>, content-length: 0] 0 octets, end
          #|then a request HTTP/1.1 takes: 200 [date: <now>, content-length: 11] 11 octets, end
          #|Journal entries: 1
        ),
      )
    })
  })
}
