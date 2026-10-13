// `encode_response` as it was before it wrote responses straight into one
// array of their exact length, kept as the oracle for the one of today:
// for any status, header fields, body and request, both must give the same
// bytes.

///|
fn reference_encode_response(
  status : Int,
  headers : ArrayView[(String, String)],
  body : BytesView,
  request? : Request,
  close? : Bool = false,
) -> Bytes {
  let out = @buffer.Buffer(size_hint=128 + body.length())
  out.write_string_utf8("HTTP/1.1 \{status} \{reason_phrase(status)}\r\n")
  for header in headers {
    let (name, value) = header
    out.write_string_utf8(name)
    out.write_bytes(b": ")
    out.write_string_utf8(value)
    out.write_bytes(b"\r\n")
  }
  let keep_open = !close && !(request is Some({ keep_alive: false, .. }))
  if !keep_open {
    out.write_bytes(b"Connection: close\r\n")
  } else if request is Some({ version: Http10, .. }) {
    out.write_bytes(b"Connection: keep-alive\r\n")
  }
  let content = !(status is (100..=199 | 204 | 304))
  if content {
    out.write_string_utf8("Content-Length: \{body.length()}\r\n")
  }
  out.write_bytes(b"\r\n")
  if content && !(request is Some({ meth: "HEAD", .. })) {
    out.write_bytes(body)
  }
  out.to_bytes()
}

///|
test "encode_response gives the bytes it gave before it wrote responses into one array, for any status, fields, body and request" {
  let rand = @random.Rand::chacha8(seed=b"smock http1 encode reference!!!!")
  let statuses = [
    100, 101, 199, 200, 201, 204, 206, 304, 305, 400, 404, 418, 431, 500, 505, 599,
    0, 7, 1000, 12345, -1, -42,
  ]
  // Text of one-, two-, three- and four-byte characters, and surrogates
  // that are not part of a pair.
  let pieces = [
    "a", "Content-Type", "text/plain; charset=utf-8", " ", "\t", "é", "€", "😀",
    "", "x-\u{7ff}", "\u{800}",
  ]
  let lone : Array[String] = [
    String::from_array([(0xD83D).unsafe_to_char()]),
    String::from_array([(0xDE00).unsafe_to_char()]),
    String::from_array(['a', (0xD800).unsafe_to_char(), 'b']),
  ]
  let text = () => {
    let out = StringBuilder()
    for _ in 0..<rand.int(limit=4) {
      out.write_string(
        if rand.int(limit=8) == 0 {
          lone[rand.int(limit=lone.length())]
        } else {
          pieces[rand.int(limit=pieces.length())]
        },
      )
    }
    out.to_string()
  }
  let requests = [
    b"GET / HTTP/1.1\r\nHost: a\r\n\r\n", b"HEAD / HTTP/1.1\r\nHost: a\r\n\r\n",
    b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", b"GET / HTTP/1.0\r\n\r\n",
    b"HEAD / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", b"GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
  ].map(raw => {
    let parser = Parser()
    parser.feed(raw[:])
    guard parser.next() is Complete(request) else { abort("no request") }
    Some(request)
  })
  requests.push(None)
  let differ = []
  for _ in 0..<20000 {
    let status = statuses[rand.int(limit=statuses.length())]
    let headers = Array::makei(rand.int(limit=4), _ => (text(), text()))
    let body = Bytes::makei(rand.int(limit=300), i => (i * 7).to_byte())
    let request = requests[rand.int(limit=requests.length())]
    let close = rand.int(limit=3) == 0
    let expected = reference_encode_response(
      status,
      headers[:],
      body[:],
      request?,
      close~,
    )
    let actual = encode_response(status, headers[:], body[:], request?, close~)
    if actual != expected && differ.length() < 5 {
      differ.push((status, headers, request, close, expected, actual))
    }
  }
  debug_inspect(differ.length(), content="0")
}
