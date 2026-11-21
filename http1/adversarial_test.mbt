// Adversarial input: request smuggling attempts, garbage bytes and input
// that is cut short, all through the parser's public interface.

///|
/// What a parser makes of `bytes` fed whole, one line per request it takes
/// out (method and target only), then how it ends.
fn verdict(bytes : Bytes) -> String {
  outcome([bytes[:]])
  .map(line => {
    guard line.find(" HTTP/") is Some(end) else { line }
    line[:end].to_owned()
  })
  .join(", ")
}

///|
test "garbage that cannot begin a request gets 400 at once, without waiting for an empty line" {
  let cases : Array[Bytes] = [
    b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03", b"\x00\x00\x00\x00", b"\xff\xfe",
    b"(GET / HTTP/1.1", b"GET\x00", b"GET /a\x00", b"GET /a\x7f", b"GET /a \x80",
    b"GET /a HTTP/1.1x", b"GET /a HTTP/1.1\r\nHost: a\r\nX\x00", b"GET /a HTTP/1.1\r\nHost: a\r\nX: 1\x01",
    b"GET /a HTTP/1.1\r\nHost: a\r\n\t", b"GET /a HTTP/1.1\r\nHost: a\r\nX: 1\rY",
  ]
  inspect(
    cases.map(case => "\{case} -> \{verdict(case)}").join("\n"),
    content=(
      #|b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" -> invalid 400
      #|b"\x00\x00\x00\x00" -> invalid 400
      #|b"\xff\xfe" -> invalid 400
      #|b"(GET / HTTP/1.1" -> invalid 400
      #|b"GET\x00" -> invalid 400
      #|b"GET /a\x00" -> invalid 400
      #|b"GET /a\x7f" -> invalid 400
      #|b"GET /a \x80" -> invalid 400
      #|b"GET /a HTTP/1.1x" -> invalid 400
      #|b"GET /a HTTP/1.1\x0d\x0aHost: a\x0d\x0aX\x00" -> invalid 400
      #|b"GET /a HTTP/1.1\x0d\x0aHost: a\x0d\x0aX: 1\x01" -> invalid 400
      #|b"GET /a HTTP/1.1\x0d\x0aHost: a\x0d\x0a\x09" -> invalid 400
      #|b"GET /a HTTP/1.1\x0d\x0aHost: a\x0d\x0aX: 1\x0dY" -> invalid 400
    ),
  )
}

///|
test "request smuggling attempts are rejected, and bytes inside a body are never read as a request" {
  let next = "GET /next HTTP/1.1\r\nHost: a\r\n\r\n"
  let post = "POST / HTTP/1.1\r\nHost: a\r\n"
  let cases = [
    // CL.TE and TE.CL
    "\{post}Content-Length: 13\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nSMUGGLED\{next}",
    "\{post}Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nSMUGGLED\r\n0\r\n\r\n\{next}",
    // TE.TE: a Transfer-Encoding hidden from one reader or the other
    "\{post}Transfer-Encoding: xchunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding : chunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\nTransfer-encoding: x\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding:\u{b}chunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding\t: chunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}X: 1\r\n Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: \"chunked\"\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding\n: chunked\r\n\r\n0\r\n\r\n\{next}",
    "\{post}X: 1\rTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n\{next}",
    "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n\{next}",
    // CL.CL
    "\{post}Content-Length: 0\r\nContent-Length: 8\r\n\r\nSMUGGLED\{next}",
    "\{post}Content-Length: 8, 0\r\n\r\nSMUGGLED\{next}",
    "\{post}Content-Length: +8\r\n\r\nSMUGGLED\{next}",
    "\{post}Content-Length : 8\r\n\r\nSMUGGLED\{next}",
    // chunk sizes and chunk framing read differently by different readers
    "\{post}Transfer-Encoding: chunked\r\n\r\n8;\nSMUGGLED\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n0x8\r\nSMUGGLED\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n8\nSMUGGLED\n0\n\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n8\r\nSMUGGLEDX\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n10000000000000008\r\nSMUGGLED\r\n0\r\n\r\n\{next}",
    // a request inside a body, and a trailer field that names a length
    "\{post}Content-Length: 35\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: a\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n23\r\nGET /smuggled HTTP/1.1\r\nHost: a\r\n\r\n\r\n0\r\n\r\n\{next}",
    "\{post}Transfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 50\r\n\r\n\{next}",
  ]
  inspect(
    cases
    .map(case => {
      let shown_case = shown(
        case
        .replace(old=post, new="POST..")
        .replace(old=next, new="GET /next.."),
      )
      "\{shown_case} -> \{verdict(@utf8.encode(case))}"
    })
    .join("\n"),
    content=(
      #|"POST..Content-Length: 13\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nSMUGGLEDGET /next.." -> invalid 400
      #|"POST..Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nSMUGGLED\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: xchunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 501
      #|"POST..Transfer-Encoding : chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\nTransfer-encoding: x\r\n\r\n0\r\n\r\nGET /next.." -> invalid 501
      #|"POST..Transfer-Encoding:\u{0b}chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding\t: chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..X: 1\r\n Transfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: \"chunked\"\r\n\r\n0\r\n\r\nGET /next.." -> invalid 501
      #|"POST..Transfer-Encoding\n: chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..X: 1\rTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Content-Length: 0\r\nContent-Length: 8\r\n\r\nSMUGGLEDGET /next.." -> invalid 400
      #|"POST..Content-Length: 8, 0\r\n\r\nSMUGGLEDGET /next.." -> invalid 400
      #|"POST..Content-Length: +8\r\n\r\nSMUGGLEDGET /next.." -> invalid 400
      #|"POST..Content-Length : 8\r\n\r\nSMUGGLEDGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\n\r\n8;\nSMUGGLED\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\n\r\n0x8\r\nSMUGGLED\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\n\r\n8\nSMUGGLED\n0\n\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\n\r\n8\r\nSMUGGLEDX\r\n0\r\n\r\nGET /next.." -> invalid 400
      #|"POST..Transfer-Encoding: chunked\r\n\r\n10000000000000008\r\nSMUGGLED\r\n0\r\n\r\nGET /next.." -> invalid 413
      #|"POST..Content-Length: 35\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: a\r\n\r\nGET /next.." -> POST /, GET /next, need more
      #|"POST..Transfer-Encoding: chunked\r\n\r\n23\r\nGET /smuggled HTTP/1.1\r\nHost: a\r\n\r\n\r\n0\r\n\r\nGET /next.." -> POST /, GET /next, need more
      #|"POST..Transfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 50\r\n\r\nGET /next.." -> POST /, GET /next, need more
    ),
  )
}

///|
test "requests before garbage come out, then the garbage gets 400" {
  inspect(
    verdict(
      b"GET /a HTTP/1.1\r\nHost: a\r\n\r\nPOST /b HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nokGET /c HTTP/1.1\r\nHost: a\r\n\r\n\x16\x03\x01\x02\x00",
    ),
    content="GET /a, POST /b, GET /c, invalid 400",
  )
}

///|
/// Pieces of HTTP that random garbage is built from, so that it reaches
/// every part of the parser instead of failing at its first byte.
let fragments : Array[Bytes] = [
  b"GET", b"POST /", b" ", b"/a", b"HTTP/1.1", b"HTTP/1.0", b"\r\n", b"\r\n\r\n",
  b"\r", b"\n", b"Host: a", b"Content-Length: ", b"Transfer-Encoding: chunked", b"0",
  b"5", b"f", b";", b"=", b"\"", b"\\", b":", b",", b"\t", b"\x00", b"\x7f", b"\xff",
  b"hello",
]

///|
/// Starts for garbage, so that it also reaches the header section, a
/// chunked body, a transfer coding (for 501), and a body of 64 bytes after
/// a whole request (for a request, then more needed).
let starts : Array[Bytes] = [
  b"", b"POST / HTTP/1.1\r\nHost: a\r\n", b"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
  b"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: ", b"GET / HTTP/1.1\r\nHost: a\r\n\r\nPOST / HTTP/1.1\r\nHost: a\r\nContent-Length: 64\r\n\r\n",
]

///|
/// The seed of the property that random garbage is parsed the same way
/// however it is split. The tests run with it on every push, in mutation
/// runs and in kill confirmations, so a failure reproduces. Each week,
/// `scripts/random-seeds.py` writes a random seed here in a working copy and
/// prints it (CONTRIBUTING.md, "Seeds").
const GARBAGE_SEED : UInt64 = 3347435453365427818

///|
/// Random bytes, and where they are cut into the pieces they are fed in.
/// When `shaped`, the parts are one of `starts` and then 1 to 40 of
/// `fragments`; otherwise they are 1 to 40 bytes of any value, a part each.
/// `cuts` are offsets into the bytes, in increasing order.
priv struct Garbage {
  shaped : Bool
  parts : Array[Bytes]
  cuts : Array[Int32]
}

///|
/// Garbage as a failure shows it: each part as a bytes literal, then the
/// cuts.
impl @debug.Debug for Garbage with fn to_repr(self) {
  let parts = self.parts.map(part => literal(part)).join(", ")
  let shape = if self.shaped { "pieces of HTTP" } else { "any bytes" }
  @debug.Repr::literal(
    "\{shape} [\{parts}], cut at \{@debug.to_string(self.cuts)}",
  )
}

///|
/// The bytes the parts make, one after another.
fn Garbage::stream(self : Garbage) -> Bytes {
  let out = @buffer.Buffer()
  for part in self.parts {
    out.write_bytes(part)
  }
  out.to_bytes()
}

///|
/// Three in four shaped, as pieces of HTTP; the rest any bytes. The bytes
/// are cut into pieces of 1 to 7 bytes.
impl @quickcheck.Arbitrary for Garbage with fn arbitrary(_size, state) {
  let shaped = pick(state, 4) != 0
  let parts = if shaped {
    [
      starts[pick(state, starts.length())],
      ..Array::makei(1 + pick(state, 40), _ => {
        fragments[pick(state, fragments.length())]
      }),
    ]
  } else {
    Array::makei(1 + pick(state, 40), _ => [pick(state, 256).to_byte()])
  }
  let length = { shaped, parts, cuts: [], }.stream().length()
  { shaped, parts, cuts: random_cuts(length, state, longest=7), }
}

///|
/// Smaller garbage: each without one of its parts, the cuts inside it
/// dropped and those after it moved with the bytes after it, and each
/// without one of its cuts. Each has fewer parts or cuts, so shrinking
/// ends.
impl @quickcheck.Shrink for Garbage with fn shrink(self) {
  let out : Array[Garbage] = []
  let mut start = 0
  for i, part in self.parts {
    let rest = self.parts.copy()
    rest.remove(i) |> ignore
    let cuts = []
    for cut in self.cuts {
      if cut <= start {
        cuts.push(cut)
      } else if cut >= start + part.length() {
        cuts.push(cut - part.length())
      }
    }
    out.push({ ..self, parts: rest, cuts, })
    start += part.length()
  }
  for i in 0..<self.cuts.length() {
    let rest = self.cuts.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, cuts: rest, })
  }
  out.iter()
}

///|
/// The bytes fed one at a time.
fn bytes_one_by_one(stream : Bytes) -> Array[BytesView] {
  (0).until(stream.length()).map(i => stream[i:i + 1]).collect()
}

///|
/// The property, by Parser's documentation ("However the bytes are split
/// into pieces, it takes out the same requests"): the bytes fed one at a
/// time, and fed in their pieces, give the requests and the ending they
/// give fed whole. A parser that crashes fails the test as well.
fn Garbage::holds(self : Garbage) -> Bool {
  let stream = self.stream()
  let whole = outcome([stream[:]])
  outcome(bytes_one_by_one(stream)) == whole &&
  outcome(cut_at(stream, self.cuts)) == whole
}

///|
/// How the bytes end when fed whole: as `outcome` renders the ending, after
/// "complete, then" when a request came out first.
fn Garbage::ending(self : Garbage) -> String {
  let whole = outcome([self.stream()[:]])
  if whole.length() > 1 {
    "complete, then \{whole[whole.length() - 1]}"
  } else {
    whole[0]
  }
}

///|
/// What the parser made of failing garbage: the bytes, the lengths of the
/// pieces, and the outcome fed whole, one byte at a time and in the pieces.
fn Garbage::describe(self : Garbage) -> String {
  let stream = self.stream()
  let pieces = cut_at(stream, self.cuts)
  let lengths = @debug.to_string(pieces.map(piece => piece.length()))
  let whole = outcome([stream[:]]).join("\n  ")
  let one_by_one = outcome(bytes_one_by_one(stream)).join("\n  ")
  let cut = outcome(pieces).join("\n  ")
  "bytes \{literal(stream)}\npieces of \{lengths} bytes\nfed whole:\n  \{whole}\nfed one byte at a time:\n  \{one_by_one}\nfed in pieces:\n  \{cut}"
}

///|
/// The endings that the garbage reaches, each an input class of the
/// property.
let garbage_endings : Array[String] = [
  "complete, then invalid 400", "complete, then need more", "invalid 400", "invalid 501",
  "need more",
]

///|
test "random garbage is parsed the same way however it is split, and never crashes the parser" {
  let reached : Map[String, Int32] = Map([])
  @quickcheck.check(
    (garbage : Garbage) => garbage.holds(),
    observe=garbage => {
      let ending = garbage.ending()
      reached[ending] = reached.get(ending).unwrap_or(0) + 1
      [
        ..garbage_endings.map(known => {
          @quickcheck.classify(ending == known, known)
        }),
        @quickcheck.classify(
          !garbage_endings.contains(ending),
          "another ending",
        ),
        @quickcheck.classify(!garbage.shaped, "any bytes"),
      ]
    },
    counterexample_context=Garbage::describe,
    count=2000,
    max_shrinks=2000,
    seed=GARBAGE_SEED,
  )
  // The garbage reaches every part of the parser: some of it even holds
  // whole requests.
  let endings = reached.keys().collect()
  endings.sort_by((a, b) => a.lexical_compare(b))
  debug_inspect(
    endings,
    content=(
      #|[
      #|  "complete, then invalid 400",
      #|  "complete, then need more",
      #|  "invalid 400",
      #|  "invalid 501",
      #|  "need more",
      #|]
    ),
  )
}
