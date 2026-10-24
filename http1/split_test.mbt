// Properties of how a stream is fed: however it is split into pieces, the
// parser takes out the same requests and ends the same way.

///|
/// Valid requests, one after another, using every framing the parser reads:
/// no body, a Content-Length body, a chunked body with extensions and
/// trailer fields, HTTP/1.0, a repeated Content-Length and an empty line
/// before a request line. Bodies hold bytes that look like the end of a
/// head or of a chunked body.
let valid_stream : String = "GET /a?x=y HTTP/1.1\r\nHost: a.example\r\nAccept: */*\r\n\r\n" +
  "POST /b HTTP/1.1\r\nHost: a.example\r\nContent-Length: 12\r\n\r\n{\"id\":1}\r\n\r\n\r\n" +
  "PUT /c HTTP/1.1\r\nHost: a.example\r\nTransfer-Encoding: chunked\r\n\r\n" +
  "5;ext=\"a;b\"\r\n0\r\n\r\n\r\n6\r\nGET / \r\n0\r\nChecksum: x\r\n\r\n" +
  "GET /d HTTP/1.0\r\nConnection: keep-alive\r\nX-Name: café\r\n\r\n" +
  "POST /e HTTP/1.1\r\nHost: a.example\r\nContent-Length: 3, 3\r\n\r\nabc" +
  "DELETE /f HTTP/1.1\r\nHost: a.example\r\nConnection: close\r\n\r\n"

///|
/// What a parser makes of a stream fed in `pieces`: each request it takes
/// out, rendered, then how it ends (`need more` or `invalid <status>`).
fn outcome(pieces : Array[BytesView]) -> Array[String] {
  let parser = @http1.Parser()
  let out = []
  for piece in pieces {
    parser.feed(piece)
    while parser.next() is Complete(request) {
      out.push(render(Complete(request)))
    }
  }
  out.push(render(parser.next()))
  out
}

///|
/// The positions `i` at which feeding `stream[:i]` and then `stream[i:]`
/// gives another outcome than feeding `stream` whole.
fn splits_that_differ(stream : Bytes) -> Array[Int32] {
  let whole = outcome([stream[:]])
  (0)
  .until(stream.length(), inclusive=true)
  .filter(i => outcome([stream[:i], stream[i:]]) != whole)
  .collect()
}

///|
/// `stream` cut into pieces of random lengths, up to `longest` bytes each.
fn random_pieces(
  stream : Bytes,
  rand : @random.Rand,
  longest~ : Int32,
) -> Array[BytesView] {
  let pieces = []
  let mut offset = 0
  while offset < stream.length() {
    let length = 1 + rand.int(limit=longest)
    let end = if offset + length < stream.length() {
      offset + length
    } else {
      stream.length()
    }
    pieces.push(stream[offset:end])
    offset = end
  }
  pieces
}

///|
test "valid requests fed whole come out in order" {
  inspect(
    outcome([@utf8.encode(valid_stream)[:]]).join("\n"),
    content=(
      #|GET /a?x=y HTTP/1.1 | Host: a.example | Accept: */* | body="" | keep-alive
      #|POST /b HTTP/1.1 | Host: a.example | Content-Length: 12 | body="{\"id\":1}\r\n\r\n" | keep-alive
      #|PUT /c HTTP/1.1 | Host: a.example | Transfer-Encoding: chunked | body="0\r\n\r\nGET / " | keep-alive
      #|GET /d HTTP/1.0 | Connection: keep-alive | X-Name: café | body="" | keep-alive
      #|POST /e HTTP/1.1 | Host: a.example | Content-Length: 3, 3 | body="abc" | keep-alive
      #|DELETE /f HTTP/1.1 | Host: a.example | Connection: close | body="" | close
      #|need more
    ),
  )
}

///|
test "valid requests split in two at any byte come out as when fed whole" {
  debug_inspect(splits_that_differ(@utf8.encode(valid_stream)), content="[]")
}

///|
test "valid requests fed one byte at a time come out as when fed whole" {
  let stream = @utf8.encode(valid_stream)
  let bytes = (0).until(stream.length()).map(i => stream[i:i + 1]).collect()
  inspect(outcome(bytes) == outcome([stream[:]]), content="true")
}

///|
test "valid requests cut into random pieces come out as when fed whole" {
  let stream = @utf8.encode(valid_stream)
  let whole = outcome([stream[:]])
  let rand = @random.Rand::chacha8(seed=b"smock http1 split reads property")
  let differ = []
  for round in 0..<300 {
    let longest = if round % 2 == 0 { 8 } else { 100 }
    let pieces = random_pieces(stream, rand, longest~)
    if outcome(pieces) != whole {
      differ.push(pieces.map(piece => piece.length()))
    }
  }
  debug_inspect(differ, content="[]")
}

///|
test "a stream that turns invalid ends the same way however it is split" {
  let stream = @utf8.encode(
    valid_stream.replace(old="Connection: close\r\n", new="") +
    "POST /x HTTP/1.1\r\nHost: a.example\r\nContent-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nG",
  )
  let whole = outcome([stream[:]])
  inspect(
    whole[whole.length() - 2:].join("\n"),
    content=(
      #|DELETE /f HTTP/1.1 | Host: a.example | body="" | keep-alive
      #|invalid 400
    ),
  )
  debug_inspect(splits_that_differ(stream), content="[]")
}

///|
test "a stream cut short anywhere gives the requests it holds whole, then needs more" {
  let stream = @utf8.encode(valid_stream)
  let whole = outcome([stream[:]])
  let wrong = (0)
    .until(stream.length())
    .filter(length => {
      let out = outcome([stream[:length]])
      let complete = out.length() - 1
      out[complete] != "need more" || out[:complete] != whole[:complete]
    })
    .collect()
  debug_inspect(wrong, content="[]")
}
