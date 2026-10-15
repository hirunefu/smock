///|
/// Encodes an HTTP/1.1 response: the status line, `headers` in the order
/// given, a Connection field when the connection decision needs one, a
/// Content-Length that `encode_response` sets from `body`, and then `body`.
///
/// - `request` is the request the response answers, when one was parsed.
///   The connection closes after the response when `close` is true or when
///   `request` does not keep it open (`Request::keep_alive`); the response
///   then says `Connection: close`, and `keeps_open` says so. A response to
///   an HTTP/1.0 request that keeps the connection open says
///   `Connection: keep-alive`, since HTTP/1.0 closes it by default.
/// - A response to HEAD carries the Content-Length that `body` has, but not
///   `body` (RFC 9110, section 9.3.2).
/// - Responses with status 1xx, 204 or 304 get neither Content-Length nor a
///   body (RFC 9110, sections 8.6, 15.2, 15.3.5 and 15.4.5).
///
/// The body is always framed by Content-Length, never chunked, so a response
/// suits HTTP/1.0 and HTTP/1.1 clients alike.
///
/// The caller passes valid field names (`is_token`) and values
/// (`is_field_value`), and does not pass Connection, Content-Length or
/// Transfer-Encoding itself. Values are written as UTF-8.
///
/// ```mbt check
/// test {
///   let parser = @http1.Parser()
///   parser.feed(b"HEAD /a HTTP/1.0\r\n\r\n")
///   guard parser.next() is Complete(request) else { fail("no request") }
///   let response = @http1.encode_response(200, [], b"hello", request~)
///   inspect(
///     @utf8.decode_lossy(response),
///     content="HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\n",
///   )
/// }
/// ```
pub fn encode_response(
  status : Int,
  headers : ArrayView[(String, String)],
  body : BytesView,
  request? : Request,
  close? : Bool = false,
) -> Bytes {
  // Every response goes through here, so it is written straight into one
  // array of its exact length, which becomes the Bytes without a copy.
  let reason = reason_phrase(status)
  let connection = connection_field(keeps_open(request?, close~), request)
  let content = has_content(status)
  let with_body = writes_body(status, request)
  let mut length = 9 + decimal_length(status) + 1 + reason.length() + 2
  for header in headers {
    length += utf8_length(header.0) + 2 + utf8_length(header.1) + 2
  }
  length += connection.length() + 2
  if content {
    length += 16 + decimal_length(body.length()) + 2
  }
  if with_body {
    length += body.length()
  }
  let out = FixedArray::make(length, b'\x00')
  let mut at = write_ascii_bytes(out, 0, b"HTTP/1.1 ")
  at = write_decimal(out, at, status)
  out[at] = b' '
  at = write_utf8(out, at + 1, reason)
  at = write_ascii_bytes(out, at, b"\r\n")
  for header in headers {
    at = write_utf8(out, at, header.0)
    at = write_ascii_bytes(out, at, b": ")
    at = write_utf8(out, at, header.1)
    at = write_ascii_bytes(out, at, b"\r\n")
  }
  at = write_ascii_bytes(out, at, connection)
  if content {
    at = write_ascii_bytes(out, at, b"Content-Length: ")
    at = write_decimal(out, at, body.length())
    at = write_ascii_bytes(out, at, b"\r\n")
  }
  at = write_ascii_bytes(out, at, b"\r\n")
  if with_body {
    out.blit_from_bytesview(at, body)
  }
  out.unsafe_reinterpret_as_bytes()
}

///|
/// The Connection field of a response to `request` whose connection stays
/// open after it when `keep_open`, as `write_connection` writes it.
fn connection_field(keep_open : Bool, request : Request?) -> Bytes {
  if !keep_open {
    b"Connection: close\r\n"
  } else if request is Some({ version: Http10, .. }) {
    b"Connection: keep-alive\r\n"
  } else {
    b""
  }
}

///|
/// The number of characters of `n` in decimal, its sign included.
fn decimal_length(n : Int) -> Int {
  if n < 0 {
    return n.to_string().length()
  }
  let mut length = 1
  let mut rest = n / 10
  while rest > 0 {
    length += 1
    rest = rest / 10
  }
  length
}

///|
/// Writes `n` in decimal at `at` in `out`, and returns the index after it.
fn write_decimal(out : FixedArray[Byte], at : Int, n : Int) -> Int {
  if n < 0 {
    return write_utf8(out, at, n.to_string())
  }
  let end = at + decimal_length(n)
  let mut rest = n
  let mut i = end
  while i > at {
    i -= 1
    out[i] = (rest % 10 + 0x30).to_byte()
    rest = rest / 10
  }
  end
}

///|
/// Writes `bytes` at `at` in `out`, and returns the index after them.
fn write_ascii_bytes(out : FixedArray[Byte], at : Int, bytes : Bytes) -> Int {
  out.blit_from_bytes(at, bytes, 0, bytes.length())
  at + bytes.length()
}

///|
/// The length of `s` in UTF-8, as `write_utf8` writes it.
fn utf8_length(s : String) -> Int {
  let n = s.length()
  let mut length = 0
  let mut i = 0
  while i < n {
    let u = s[i].to_int()
    if u < 0x80 {
      length += 1
    } else if u < 0x800 {
      length += 2
    } else if is_pair(s, i) {
      length += 4
      i += 1
    } else {
      length += 3
    }
    i += 1
  }
  length
}

///|
/// Whether a surrogate pair starts at index `i` of `s`.
fn is_pair(s : String, i : Int) -> Bool {
  let u = s[i].to_int()
  u >= 0xD800 &&
  u <= 0xDBFF &&
  i + 1 < s.length() &&
  s[i + 1].to_int() >= 0xDC00 &&
  s[i + 1].to_int() <= 0xDFFF
}

///|
/// Writes `s` as UTF-8 at `at` in `out`, and returns the index after it. A
/// surrogate that is not part of a pair is written as the three bytes of
/// its code unit, as `@buffer.Buffer::write_string_utf8` writes it.
fn write_utf8(out : FixedArray[Byte], at : Int, s : String) -> Int {
  let n = s.length()
  let mut at = at
  let mut i = 0
  while i < n {
    let u = s[i].to_int()
    if u < 0x80 {
      out[at] = u.to_byte()
      at += 1
    } else if u < 0x800 {
      out[at] = (0xC0 | (u >> 6)).to_byte()
      out[at + 1] = (0x80 | (u & 0x3F)).to_byte()
      at += 2
    } else if is_pair(s, i) {
      let c = 0x10000 + ((u - 0xD800) << 10) + (s[i + 1].to_int() - 0xDC00)
      out[at] = (0xF0 | (c >> 18)).to_byte()
      out[at + 1] = (0x80 | ((c >> 12) & 0x3F)).to_byte()
      out[at + 2] = (0x80 | ((c >> 6) & 0x3F)).to_byte()
      out[at + 3] = (0x80 | (c & 0x3F)).to_byte()
      at += 4
      i += 1
    } else {
      out[at] = (0xE0 | (u >> 12)).to_byte()
      out[at + 1] = (0x80 | ((u >> 6) & 0x3F)).to_byte()
      out[at + 2] = (0x80 | (u & 0x3F)).to_byte()
      at += 3
    }
    i += 1
  }
  at
}

///|
/// Whether the connection stays open after the response that
/// `encode_response` encodes with the same `request` and `close`: unless
/// `close` is true or `request` does not keep it open
/// (`Request::keep_alive`). A response that answers no parsed request keeps
/// it open unless `close` is true.
///
/// ```mbt check
/// test {
///   let parser = @http1.Parser()
///   parser.feed(b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
///   guard parser.next() is Complete(request) else { fail("no request") }
///   inspect(@http1.keeps_open(request~), content="true")
///   inspect(@http1.keeps_open(request~, close=true), content="false")
/// }
/// ```
pub fn keeps_open(request? : Request, close? : Bool = false) -> Bool {
  !close && !(request is Some({ keep_alive: false, .. }))
}

///|
/// Writes the Connection field of a response to `request`, when one was
/// parsed: `close` when the connection does not stay open after it, and
/// `keep-alive` when it stays open after an HTTP/1.0 request, since
/// HTTP/1.0 closes it by default.
fn write_connection(
  out : @buffer.Buffer,
  keep_open : Bool,
  request : Request?,
) -> Unit {
  out.write_bytes(connection_field(keep_open, request))
}

///|
/// Whether a response with `status` has content: one with status 1xx, 204
/// or 304 has none (RFC 9110, sections 15.2, 15.3.5 and 15.4.5).
fn has_content(status : Int) -> Bool {
  !(status is (100..=199 | 204 | 304))
}

///|
/// Whether a response with `status` to `request` carries its body: it has
/// content, and it does not answer HEAD (RFC 9110, section 9.3.2).
fn writes_body(status : Int, request : Request?) -> Bool {
  has_content(status) && !(request is Some({ meth: "HEAD", .. }))
}

///|
/// Whether `s` is a token (RFC 9110, section 5.6.2), as a field name and a
/// method are: one or more ASCII letters, digits and ``!#$%&'*+-.^_`|~``.
///
/// ```mbt check
/// test {
///   inspect(@http1.is_token("Content-Type"), content="true")
///   inspect(@http1.is_token("Content Type"), content="false")
///   inspect(@http1.is_token(""), content="false")
/// }
/// ```
pub fn is_token(s : StringView) -> Bool {
  !s.is_empty() &&
  s.iter().all(c => c.is_ascii() && is_tchar(c.to_int().to_byte()))
}

///|
/// Whether `s` can be written as a field value (RFC 9110, section 5.5): it
/// holds no control character other than tab, so no CR or LF. Characters
/// beyond ASCII are written as UTF-8.
///
/// ```mbt check
/// test {
///   inspect(@http1.is_field_value("text/plain;\tcharset=utf-8"), content="true")
///   inspect(@http1.is_field_value("caf\u{e9}"), content="true")
///   inspect(@http1.is_field_value("a\r\nSet-Cookie: x"), content="false")
/// }
/// ```
pub fn is_field_value(s : StringView) -> Bool {
  s.iter().all(c => !c.is_ascii() || is_field_value_byte(c.to_int().to_byte()))
}

///|
/// Writes the status line and `headers`, in the order given, each line
/// ending with CRLF. Names and values are written as UTF-8.
fn write_status_and_headers(
  out : @buffer.Buffer,
  status : Int,
  headers : ArrayView[(String, String)],
) -> Unit {
  out.write_string_utf8("HTTP/1.1 \{status} \{reason_phrase(status)}\r\n")
  for header in headers {
    let (name, value) = header
    out.write_string_utf8(name)
    out.write_bytes(b": ")
    out.write_string_utf8(value)
    out.write_bytes(b"\r\n")
  }
}

///|
/// The reason phrase RFC 9110 gives `status`, or `""` for a status it does
/// not name.
fn reason_phrase(status : Int) -> String {
  match status {
    100 => "Continue"
    101 => "Switching Protocols"
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    203 => "Non-Authoritative Information"
    204 => "No Content"
    205 => "Reset Content"
    206 => "Partial Content"
    300 => "Multiple Choices"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    305 => "Use Proxy"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    402 => "Payment Required"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    406 => "Not Acceptable"
    407 => "Proxy Authentication Required"
    408 => "Request Timeout"
    409 => "Conflict"
    410 => "Gone"
    411 => "Length Required"
    412 => "Precondition Failed"
    413 => "Content Too Large"
    414 => "URI Too Long"
    415 => "Unsupported Media Type"
    416 => "Range Not Satisfiable"
    417 => "Expectation Failed"
    421 => "Misdirected Request"
    422 => "Unprocessable Content"
    426 => "Upgrade Required"
    429 => "Too Many Requests"
    431 => "Request Header Fields Too Large"
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    505 => "HTTP Version Not Supported"
    _ => ""
  }
}
