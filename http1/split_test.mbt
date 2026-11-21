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
/// The index of a random one of `n` choices.
fn pick(state : @quickcheck.RandomState, n : Int32) -> Int32 {
  state.next_uint(limit=n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// Where a stream of `length` bytes is cut into pieces of random lengths,
/// from 1 to `longest` bytes each: the offset at which each piece but the
/// first begins.
fn random_cuts(
  length : Int32,
  state : @quickcheck.RandomState,
  longest~ : Int32,
) -> Array[Int32] {
  let cuts = []
  let mut offset = 1 + pick(state, longest)
  while offset < length {
    cuts.push(offset)
    offset += 1 + pick(state, longest)
  }
  cuts
}

///|
/// `stream` cut at `cuts`, offsets in increasing order. A cut at 0 or at
/// the end or past it, which a shrunk stream may leave, cuts nothing.
fn cut_at(stream : Bytes, cuts : Array[Int32]) -> Array[BytesView] {
  let pieces = []
  let mut from = 0
  for cut in cuts {
    if cut > from && cut < stream.length() {
      pieces.push(stream[from:cut])
      from = cut
    }
  }
  pieces.push(stream[from:])
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
/// The seed of the property that valid requests cut into random pieces come
/// out as when fed whole. The tests run with it on every push, in mutation
/// runs and in kill confirmations, so a failure reproduces. Each week,
/// `scripts/random-seeds.py` writes a random seed here in a working copy and
/// prints it (CONTRIBUTING.md, "Seeds").
const SPLIT_SEED : UInt64 = 8975720889551314310

///|
/// The requests of `valid_stream`, each from the first byte of its request
/// line to the first byte of the next one's, so that an empty line before a
/// request line goes with the request before it. Any of them, in order, is
/// a valid stream too.
let valid_requests : Array[Bytes] = {
  let stream = @utf8.encode(valid_stream)
  let starts = [
    b"GET /a?x=y ", b"POST /b ", b"PUT /c ", b"GET /d ", b"POST /e ", b"DELETE /f ",
  ].map(line => stream.find(line).unwrap())
  starts.mapi((i, start) => {
    let end = if i + 1 < starts.length() {
      starts[i + 1]
    } else {
      stream.length()
    }
    stream[start:end].to_owned()
  })
}

///|
/// A stream of valid requests and where it is cut into the pieces it is fed
/// in: `requests` are indexes into `valid_requests`, in increasing order,
/// and `cuts` offsets into the stream they make, in increasing order. The
/// cuts were drawn as pieces of up to `longest` bytes.
priv struct Split {
  requests : Array[Int32]
  cuts : Array[Int32]
  longest : Int32
}

///|
/// A case as a failure shows it: each request by its method and target,
/// then the cuts.
impl @debug.Debug for Split with fn to_repr(self) {
  let requests = self.requests.map(i => {
    let request = valid_requests[i]
    let line = request[:request.find(b" HTTP/").unwrap()]
    @utf8.decode_lossy(line)
  })
  @debug.Repr::literal(
    "requests \{@debug.to_string(requests)}, cut at \{@debug.to_string(self.cuts)}",
  )
}

///|
/// The stream the requests make, one after another.
fn Split::stream(self : Split) -> Bytes {
  let out = @buffer.Buffer()
  for i in self.requests {
    out.write_bytes(valid_requests[i])
  }
  out.to_bytes()
}

///|
/// All of `valid_requests`, cut into pieces of random lengths up to 8 bytes
/// or up to 100, each as likely.
impl @quickcheck.Arbitrary for Split with fn arbitrary(_size, state) {
  let requests = Array::makei(valid_requests.length(), i => i)
  let longest = if pick(state, 2) == 0 { 8 } else { 100 }
  let length = { requests, cuts: [], longest, }.stream().length()
  { requests, cuts: random_cuts(length, state, longest~), longest, }
}

///|
/// Smaller cases: each without one of its requests, the cuts inside it
/// dropped and those after it moved with the bytes after it, and each
/// without one of its cuts. Each has fewer requests or cuts, so shrinking
/// ends.
impl @quickcheck.Shrink for Split with fn shrink(self) {
  let out : Array[Split] = []
  let mut start = 0
  for i, request in self.requests {
    let length = valid_requests[request].length()
    let rest = self.requests.copy()
    rest.remove(i) |> ignore
    let cuts = []
    for cut in self.cuts {
      if cut <= start {
        cuts.push(cut)
      } else if cut >= start + length {
        cuts.push(cut - length)
      }
    }
    out.push({ ..self, requests: rest, cuts, })
    start += length
  }
  for i in 0..<self.cuts.length() {
    let rest = self.cuts.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, cuts: rest, })
  }
  out.iter()
}

///|
/// The property, by Parser's documentation ("However the bytes are split
/// into pieces, it takes out the same requests"): the stream fed in its
/// pieces gives the requests and the ending it gives fed whole.
fn Split::holds(self : Split) -> Bool {
  let stream = self.stream()
  outcome(cut_at(stream, self.cuts)) == outcome([stream[:]])
}

///|
/// What the parser made of a failing case: the stream, the lengths of its
/// pieces, and the outcome fed whole and fed in the pieces.
fn Split::describe(self : Split) -> String {
  let stream = self.stream()
  let pieces = cut_at(stream, self.cuts)
  let whole = outcome([stream[:]]).join("\n  ")
  let cut = outcome(pieces).join("\n  ")
  let lengths = @debug.to_string(pieces.map(piece => piece.length()))
  "stream \{literal(stream)}\npieces of \{lengths} bytes\nfed whole:\n  \{whole}\nfed in pieces:\n  \{cut}"
}

///|
/// `bytes` as a bytes literal, `b"..."`: printable ASCII as it is, but for
/// `"` and `\`, and every other byte escaped, so a failure shows every
/// byte of a stream on one line.
fn literal(bytes : BytesView) -> String {
  let out = StringBuilder()
  out.write_string("b\"")
  for byte in bytes {
    match byte {
      b'"' => out.write_string("\\\"")
      b'\\' => out.write_string("\\\\")
      b'\r' => out.write_string("\\r")
      b'\n' => out.write_string("\\n")
      b'\t' => out.write_string("\\t")
      b' '..<=b'~' => out.write_char(byte.to_char())
      _ => {
        let hex = byte.to_int().to_string(radix=16)
        out.write_string(
          if hex.length() == 1 {
            "\\x0\{hex}"
          } else {
            "\\x\{hex}"
          },
        )
      }
    }
  }
  out.write_string("\"")
  out.to_string()
}

///|
/// Where in the stream its parts lie, as (part, from, to): each request
/// line (up to its CR), each header section after it (up to the empty
/// line's LF), each body with the empty lines after it, the chunk extension
/// `;ext="a;b"`, the trailer field and the two bytes of `é`. A cut at `c`
/// is inside a part when `from < c < to`.
fn Split::parts(self : Split) -> Array[(String, Int32, Int32)] {
  let parts = []
  let mut base = 0
  for i in self.requests {
    let request = valid_requests[i]
    let line = request.find(b"\r\n").unwrap()
    let head = request.find(b"\r\n\r\n").unwrap() + 4
    parts.push(("a request line", base, base + line))
    parts.push(("a header section", base + line + 2, base + head))
    if request.length() > head {
      parts.push(("a body", base + head, base + request.length()))
    }
    for
      part in [
        ("a chunk extension", b";ext=\"a;b\""),
        ("a trailer field", b"Checksum: x\r\n"),
        ("a character of two bytes", b"\xc3\xa9"),
      ] {
      if request.find(part.1) is Some(at) {
        parts.push((part.0, base + at, base + at + part.1.length()))
      }
    }
    base += request.length()
  }
  parts
}

///|
test "valid requests cut into random pieces come out as when fed whole" {
  @quickcheck.check(
    (split : Split) => split.holds(),
    observe=split => {
      let stream = split.stream()
      let parts = split.parts()
      let cuts = split.cuts.filter(cut => cut > 0 && cut < stream.length())
      let inside = (part : String) => {
        parts
        .iter()
        .any(p => p.0 == part && cuts.iter().any(cut => cut > p.1 && cut < p.2))
      }
      [
        @quickcheck.classify(split.longest == 8, "pieces of up to 8 bytes"),
        @quickcheck.classify(
          cuts
          .iter()
          .any(cut => stream[cut - 1] == b'\r' && stream[cut] == b'\n'),
          "a cut between a CR and its LF",
        ),
        @quickcheck.classify(
          inside("a request line"),
          "a cut inside a request line",
        ),
        @quickcheck.classify(
          inside("a header section"),
          "a cut inside a header section",
        ),
        @quickcheck.classify(inside("a body"), "a cut inside a body"),
        @quickcheck.classify(
          inside("a chunk extension"),
          "a cut inside a chunk extension",
        ),
        @quickcheck.classify(
          inside("a trailer field"),
          "a cut inside a trailer field",
        ),
        @quickcheck.classify(
          inside("a character of two bytes"),
          "a cut inside a character of two bytes",
        ),
      ]
    },
    counterexample_context=Split::describe,
    count=300,
    max_shrinks=1000,
    seed=SPLIT_SEED,
  )
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
