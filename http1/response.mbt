///|
/// Encodes an HTTP/1.1 response: the status line, `headers` in the order
/// given, a Connection field when the connection decision needs one, a
/// Content-Length that `encode_response` sets from `body`, and then `body`.
///
/// - `request` is the request the response answers, when one was parsed.
///   The connection closes after the response when `close` is true or when
///   `request` does not keep it open (`Request::keep_alive`); the response
///   then says `Connection: close`. A response to an HTTP/1.0 request that
///   keeps the connection open says `Connection: keep-alive`, since HTTP/1.0
///   closes it by default.
/// - A response to HEAD carries the Content-Length that `body` has, but not
///   `body` (RFC 9110, section 9.3.2).
/// - Responses with status 1xx, 204 or 304 get neither Content-Length nor a
///   body (RFC 9110, sections 8.6, 15.2, 15.3.5 and 15.4.5).
///
/// The body is always framed by Content-Length, never chunked, so a response
/// suits HTTP/1.0 and HTTP/1.1 clients alike.
///
/// The caller passes valid field names (tokens) and values (no CR, LF or
/// other control characters except tab), and does not pass Connection,
/// Content-Length or Transfer-Encoding itself. Values are written as UTF-8.
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
  match request {
    _ if close => out.write_bytes(b"Connection: close\r\n")
    Some({ keep_alive: false, .. }) => out.write_bytes(b"Connection: close\r\n")
    Some({ version: Http10, .. }) =>
      out.write_bytes(b"Connection: keep-alive\r\n")
    _ => ()
  }
  let has_content = !(status is (100..=199 | 204 | 304))
  if has_content {
    out.write_string_utf8("Content-Length: \{body.length()}\r\n")
  }
  out.write_bytes(b"\r\n")
  if has_content && !(request is Some({ meth: "HEAD", .. })) {
    out.write_bytes(body)
  }
  out.to_bytes()
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
