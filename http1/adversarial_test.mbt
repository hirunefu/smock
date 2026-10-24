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
/// Starts for garbage, so that it also reaches the header section and a
/// chunked body.
let starts : Array[Bytes] = [
  b"", b"POST / HTTP/1.1\r\nHost: a\r\n", b"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
]

///|
/// Random bytes: one of `starts` followed by `fragments` when `shaped`,
/// otherwise any bytes.
fn garbage(rand : @random.Rand, shaped~ : Bool) -> Bytes {
  let out = @buffer.Buffer()
  if shaped {
    out.write_bytes(starts[rand.int(limit=starts.length())])
  }
  for _ in 0..<(1 + rand.int(limit=40)) {
    if shaped {
      out.write_bytes(fragments[rand.int(limit=fragments.length())])
    } else {
      out.write_byte(rand.int(limit=256).to_byte())
    }
  }
  out.to_bytes()
}

///|
test "random garbage is parsed the same way however it is split, and never crashes the parser" {
  let rand = @random.Rand::chacha8(seed=b"smock http1 garbage, any splits.")
  let differ = []
  let endings : Map[String, Int32] = Map([])
  for round in 0..<2000 {
    let stream = garbage(rand, shaped=round % 4 != 0)
    let whole = outcome([stream[:]])
    let bytes = (0).until(stream.length()).map(i => stream[i:i + 1]).collect()
    if outcome(bytes) != whole ||
      outcome(random_pieces(stream, rand, longest=7)) != whole {
      differ.push(stream)
    }
    let ending = if whole.length() > 1 {
      "complete, then \{whole[whole.length() - 1]}"
    } else {
      whole[0]
    }
    endings[ending] = endings.get(ending).unwrap_or(0) + 1
  }
  debug_inspect(differ, content="[]")
  // The garbage reaches every part of the parser: some of it even holds
  // whole requests.
  let endings = endings.keys().collect()
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
