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
  let out = @buffer.Buffer(size_hint=128 + body.length())
  write_status_and_headers(out, status, headers)
  write_connection(out, keeps_open(request?, close~), request)
  if has_content(status) {
    out.write_string_utf8("Content-Length: \{body.length()}\r\n")
  }
  out.write_bytes(b"\r\n")
  if writes_body(status, request) {
    out.write_bytes(body)
  }
  out.to_bytes()
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
  if !keep_open {
    out.write_bytes(b"Connection: close\r\n")
  } else if request is Some({ version: Http10, .. }) {
    out.write_bytes(b"Connection: keep-alive\r\n")
  }
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
