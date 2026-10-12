///|
/// Encodes an HTTP/1.1 response: the status line, `headers` in the order
/// given, a Content-Length that `encode_response` sets from `body`, and then
/// `body`.
///
/// Responses with status 204 or 304 get neither Content-Length nor a body
/// (RFC 9110, sections 8.6 and 15.4.5).
///
/// The caller passes valid field names (tokens) and values (no CR, LF or
/// other control characters except tab), and does not pass Content-Length
/// or Transfer-Encoding itself. Values are written as UTF-8.
pub fn encode_response(
  status : Int,
  headers : ArrayView[(String, String)],
  body : BytesView,
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
  let has_body = !(status is (204 | 304))
  if has_body {
    out.write_string_utf8("Content-Length: \{body.length()}\r\n")
  }
  out.write_bytes(b"\r\n")
  if has_body {
    out.write_bytes(body)
  }
  out.to_bytes()
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
