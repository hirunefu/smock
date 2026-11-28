///|
fn encoded(
  status : Int32,
  headers : Array[(String, String)],
  body : String,
) -> String {
  @utf8.decode_lossy(
    @http1.encode_response(status, headers, @utf8.encode(body)),
  )
}

///|
test "a response carries its status line, its headers in order, Content-Length and the body" {
  inspect(
    encoded(
      200,
      [("Content-Type", "application/json"), ("X-Trace", "a b")],
      "{\"id\":1}",
    ),
    content=(
      #|HTTP/1.1 200 OK
      #|Content-Type: application/json
      #|X-Trace: a b
      #|Content-Length: 8
      #|
      #|{"id":1}
    ).replace_all(old="\n", new="\r\n"),
  )
}

///|
test "an empty body has Content-Length 0" {
  inspect(
    encoded(404, [], ""),
    content="HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
  )
}

///|
test "a status without a known reason phrase gets an empty one" {
  inspect(
    encoded(299, [], ""),
    content="HTTP/1.1 299 \r\nContent-Length: 0\r\n\r\n",
  )
}

///|
test "the status line carries the reason phrase RFC 9110 gives each status it defines, and RFC 6585 gives 429 and 431" {
  // Each phrase is the heading of the status's section: RFC 9110, sections
  // 15.2 to 15.6, and RFC 6585, sections 4 and 5, for 429 and 431, which
  // RFC 9110 does not define. The line's form is RFC 9112, section 4's
  // `status-line = HTTP-version SP status-code SP [ reason-phrase ]`.
  let statuses = [
    100, 101, 200, 201, 202, 203, 204, 205, 206, 300, 301, 302, 303, 304, 305, 307,
    308, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414,
    415, 416, 417, 421, 422, 426, 429, 431, 500, 501, 502, 503, 504, 505,
  ]
  let lines = statuses.map(status => {
    let response = encoded(status, [], "")
    guard response.find("\r\n") is Some(end) else {
      abort("no status line: \{response}")
    }
    response[:end].to_owned()
  })
  inspect(
    lines.join("\n"),
    content=(
      #|HTTP/1.1 100 Continue
      #|HTTP/1.1 101 Switching Protocols
      #|HTTP/1.1 200 OK
      #|HTTP/1.1 201 Created
      #|HTTP/1.1 202 Accepted
      #|HTTP/1.1 203 Non-Authoritative Information
      #|HTTP/1.1 204 No Content
      #|HTTP/1.1 205 Reset Content
      #|HTTP/1.1 206 Partial Content
      #|HTTP/1.1 300 Multiple Choices
      #|HTTP/1.1 301 Moved Permanently
      #|HTTP/1.1 302 Found
      #|HTTP/1.1 303 See Other
      #|HTTP/1.1 304 Not Modified
      #|HTTP/1.1 305 Use Proxy
      #|HTTP/1.1 307 Temporary Redirect
      #|HTTP/1.1 308 Permanent Redirect
      #|HTTP/1.1 400 Bad Request
      #|HTTP/1.1 401 Unauthorized
      #|HTTP/1.1 402 Payment Required
      #|HTTP/1.1 403 Forbidden
      #|HTTP/1.1 404 Not Found
      #|HTTP/1.1 405 Method Not Allowed
      #|HTTP/1.1 406 Not Acceptable
      #|HTTP/1.1 407 Proxy Authentication Required
      #|HTTP/1.1 408 Request Timeout
      #|HTTP/1.1 409 Conflict
      #|HTTP/1.1 410 Gone
      #|HTTP/1.1 411 Length Required
      #|HTTP/1.1 412 Precondition Failed
      #|HTTP/1.1 413 Content Too Large
      #|HTTP/1.1 414 URI Too Long
      #|HTTP/1.1 415 Unsupported Media Type
      #|HTTP/1.1 416 Range Not Satisfiable
      #|HTTP/1.1 417 Expectation Failed
      #|HTTP/1.1 421 Misdirected Request
      #|HTTP/1.1 422 Unprocessable Content
      #|HTTP/1.1 426 Upgrade Required
      #|HTTP/1.1 429 Too Many Requests
      #|HTTP/1.1 431 Request Header Fields Too Large
      #|HTTP/1.1 500 Internal Server Error
      #|HTTP/1.1 501 Not Implemented
      #|HTTP/1.1 502 Bad Gateway
      #|HTTP/1.1 503 Service Unavailable
      #|HTTP/1.1 504 Gateway Timeout
      #|HTTP/1.1 505 HTTP Version Not Supported
    ),
  )
}

///|
test "204 and 304 responses have neither Content-Length nor a body" {
  inspect(
    encoded(204, [("X-A", "1")], "ignored") + encoded(304, [], "ignored"),
    content="HTTP/1.1 204 No Content\r\nX-A: 1\r\n\r\nHTTP/1.1 304 Not Modified\r\n\r\n",
  )
}

///|
test "header values are written as UTF-8" {
  inspect(
    encoded(200, [("X-Name", "café")], ""),
    content="HTTP/1.1 200 OK\r\nX-Name: café\r\nContent-Length: 0\r\n\r\n",
  )
  // The first and the last character that UTF-8 writes in two, three and
  // four octets, U+0080 and U+07FF, U+0800 and U+FFFF, U+10000 and
  // U+10FFFF, each as the octets RFC 3629 gives it (sections 3 and 4);
  // Python's UTF-8 codec writes the same octets. Bytes show CR LF as
  // \x0d\x0a.
  inspect(
    @http1.encode_response(
      200,
      [
        ("A", "\u{80}"),
        ("B", "\u{7ff}"),
        ("C", "\u{800}"),
        ("D", "\u{ffff}"),
        ("E", "\u{10000}"),
        ("F", "\u{10ffff}"),
      ],
      b"",
    ),
    content=(
      #|b"HTTP/1.1 200 OK\x0d\x0aA: \xc2\x80\x0d\x0aB: \xdf\xbf\x0d\x0aC: \xe0\xa0\x80\x0d\x0aD: \xef\xbf\xbf\x0d\x0aE: \xf0\x90\x80\x80\x0d\x0aF: \xf4\x8f\xbf\xbf\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a"
    ),
  )
}

///|
test "a response given a Date value carries it after its headers, before the fields that frame it" {
  let request = request_of(
    "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
  )
  inspect(
    one_line(
      @http1.encode_response(
        200,
        [("Content-Type", "text/plain")],
        b"hi",
        request~,
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    ),
    content="HTTP/1.1 200 OK|Content-Type: text/plain|Date: Thu, 22 Oct 2026 14:37:10 GMT|Connection: close|Content-Length: 2||hi",
  )
}

///|
test "a response whose headers give a Date field, in any case, carries that one alone" {
  let given = ["Date", "date", "DATE", "dAtE"].map(name => {
    one_line(
      @http1.encode_response(
        200,
        [(name, "Mon, 01 Jan 2001 00:00:00 GMT"), ("X-A", "1")],
        b"",
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    )
  })
  inspect(
    given.join("\n"),
    content=(
      #|HTTP/1.1 200 OK|Date: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|date: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|DATE: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
      #|HTTP/1.1 200 OK|dAtE: Mon, 01 Jan 2001 00:00:00 GMT|X-A: 1|Content-Length: 0||
    ),
  )
  // Names that only start or end like it are other fields.
  inspect(
    one_line(
      @http1.encode_response(
        204,
        [("Dates", "a"), ("X-Date", "b")],
        b"",
        date="Thu, 22 Oct 2026 14:37:10 GMT",
      ),
    ),
    content="HTTP/1.1 204 No Content|Dates: a|X-Date: b|Date: Thu, 22 Oct 2026 14:37:10 GMT||",
  )
}

///|
/// The text of one code unit, `unit`, which may be half of a surrogate
/// pair.
fn code_unit(unit : Int32) -> String {
  String::from_array([unit.unsafe_to_char()])
}

///|
test "field_octets writes a surrogate that is not part of a pair as the three bytes of its code unit" {
  let texts = [
    "a" + code_unit(0xD800) + "b",
    code_unit(0xDC00),
    code_unit(0xDE00) + code_unit(0xD83D),
    code_unit(0xD83D) + code_unit(0xDE00),
    "",
  ]
  inspect(
    texts.map(text => "\{@http1.field_octets(text)}").join("\n"),
    content=(
      #|b"a\xed\xa0\x80b"
      #|b"\xed\xb0\x80"
      #|b"\xed\xb8\x80\xed\xa0\xbd"
      #|b"\xf0\x9f\x98\x80"
      #|b""
    ),
  )
  // A pair is a high surrogate, 0xD800 to 0xDBFF, then a low one, 0xDC00 to
  // 0xDFFF (RFC 2781, section 2.2). Its four corners are U+10000, U+103FF,
  // U+10FC00 and U+10FFFF, written in four octets (RFC 3629, section 3).
  // A code unit just outside one of the four edges makes no pair: 0xD7FF
  // and 0xE000 are characters of their own, and the surrogates are each
  // written as the three octets of their code unit. The expected octets
  // are Python's: the code units decoded as UTF-16 and encoded as UTF-8,
  // both with "surrogatepass".
  let edges = [
    code_unit(0xD800) + code_unit(0xDC00),
    code_unit(0xD800) + code_unit(0xDFFF),
    code_unit(0xDBFF) + code_unit(0xDC00),
    code_unit(0xDBFF) + code_unit(0xDFFF),
    code_unit(0xD7FF) + code_unit(0xDC00),
    code_unit(0xDC00) + code_unit(0xDFFF),
    code_unit(0xD800) + code_unit(0xDBFF),
    code_unit(0xDBFF) + code_unit(0xE000),
  ]
  inspect(
    edges.map(text => "\{@http1.field_octets(text)}").join("\n"),
    content=(
      #|b"\xf0\x90\x80\x80"
      #|b"\xf0\x90\x8f\xbf"
      #|b"\xf4\x8f\xb0\x80"
      #|b"\xf4\x8f\xbf\xbf"
      #|b"\xed\x9f\xbf\xed\xb0\x80"
      #|b"\xed\xb0\x80\xed\xbf\xbf"
      #|b"\xed\xa0\x80\xed\xaf\xbf"
      #|b"\xed\xaf\xbf\xee\x80\x80"
    ),
  )
}

///|
test "field_octets gives the octets encode_response writes for a field value, for every text of up to three pieces of one to four bytes, tabs, spaces and lone surrogates" {
  let pieces = [
    "a",
    " ",
    "\t",
    "\u{7f}",
    "\u{80}",
    "é",
    "\u{7ff}",
    "\u{800}",
    "€",
    "\u{ffff}",
    "😀",
    "\u{10ffff}",
    code_unit(0xD800),
    code_unit(0xDBFF),
    code_unit(0xDC00),
    code_unit(0xDFFF),
  ]
  let texts = [""]
  let mut from = 0
  for _ in 0..<3 {
    let to = texts.length()
    for i in from..<to {
      for piece in pieces {
        texts.push(texts[i] + piece)
      }
    }
    from = to
  }
  let prefix = b"HTTP/1.1 200 OK\r\nX: "
  let suffix = b"\r\nContent-Length: 0\r\n\r\n"
  let mut differ = 0
  for text in texts {
    let response = @http1.encode_response(200, [("X", text)], b"")
    let written = response[prefix.length():response.length() - suffix.length()]
    if @http1.field_octets(text) != written.to_owned() {
      differ += 1
    }
  }
  inspect(
    "\{texts.length()} texts, \{differ} differ",
    content="4369 texts, 0 differ",
  )
}
