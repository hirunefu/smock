///|
/// An HTTP/1.1 response whose body is written in parts as they become
/// ready, such as a stream of Server-Sent Events, so that its length is not
/// known when its head is written. It does no I/O: the caller writes
/// `head`, then each `part` as it is ready, then `end`, and then keeps the
/// connection open only when `keeps_open` says so.
///
/// How the body is delimited depends on the request it answers:
///
/// - To HTTP/1.1, the body is chunked (RFC 9112, section 7.1): the head
///   says `Transfer-Encoding: chunked`, each part is one chunk and `end` is
///   the last chunk. The connection stays open unless `close` is true or
///   the request does not keep it open (`Request::keep_alive`); the head
///   then says `Connection: close`.
/// - To HTTP/1.0, which has no chunked coding, the body is never chunked:
///   the parts are written as they are, and closing the connection ends the
///   body (RFC 9112, section 6.3). The head says `Connection: close`, and
///   the connection never stays open, even when the request asks for it.
/// - A response to HEAD has the head a GET would get, but no body: the
///   parts and `end` are empty (RFC 9110, section 9.3.2).
/// - A response with status 1xx, 204 or 304 has no body, so it needs no
///   framing (RFC 9110, sections 15.2, 15.3.5 and 15.4.5): the parts and
///   `end` are empty, and the connection stays open as for
///   `encode_response`.
///
/// The caller passes valid field names (tokens) and values (no CR, LF or
/// other control characters except tab), and does not pass Connection,
/// Content-Length or Transfer-Encoding itself. Values are written as UTF-8.
///
/// ```mbt check
/// test {
///   let parser = @http1.Parser()
///   parser.feed(b"GET /events HTTP/1.1\r\nHost: a\r\n\r\n")
///   guard parser.next() is Complete(request) else { fail("no request") }
///   let response = @http1.ResponseStream(
///     200,
///     [("Content-Type", "text/event-stream")],
///     request~,
///   )
///   let out = @buffer.Buffer()
///   out.write_bytes(response.head())
///   out.write_bytes(response.part(@http1.encode_sse_event("hi")))
///   out.write_bytes(response.end())
///   inspect(
///     @utf8.decode_lossy(out.to_bytes()),
///     content="HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\na\r\ndata: hi\n\n\r\n0\r\n\r\n",
///   )
///   inspect(response.keeps_open(), content="true")
/// }
/// ```
pub struct ResponseStream {
  priv head : Bytes
  priv framing : BodyEnd
  /// Whether the body is written: not in a response to HEAD, nor with a
  /// status that allows no body.
  priv body : Bool
  priv keep_open : Bool
}

///|
/// How the body of a streamed response is delimited.
priv enum BodyEnd {
  /// By chunked transfer coding.
  Chunked
  /// By closing the connection.
  UntilClose
  /// It has none: the status allows no body.
  NoContent
}

///|
/// Starts a streamed response with `status` and `headers`, in the order
/// given, as the answer to `request`, the request it answers when one was
/// parsed. With `close`, the connection closes after the response whatever
/// the request says.
pub fn ResponseStream::ResponseStream(
  status : Int,
  headers : ArrayView[(String, String)],
  request? : Request,
  close? : Bool = false,
) -> ResponseStream {
  let http10 = request is Some({ version: Http10, .. })
  let framing : BodyEnd = if status is (100..=199 | 204 | 304) {
    NoContent
  } else if http10 {
    UntilClose
  } else {
    Chunked
  }
  let keep_open = !(framing is UntilClose) &&
    !close &&
    !(request is Some({ keep_alive: false, .. }))
  let out = @buffer.Buffer(size_hint=128)
  write_status_and_headers(out, status, headers)
  if !keep_open {
    out.write_bytes(b"Connection: close\r\n")
  } else if http10 {
    // HTTP/1.0 closes the connection by default.
    out.write_bytes(b"Connection: keep-alive\r\n")
  }
  if framing is Chunked {
    out.write_bytes(b"Transfer-Encoding: chunked\r\n")
  }
  out.write_bytes(b"\r\n")
  let body = !(framing is NoContent) && !(request is Some({ meth: "HEAD", .. }))
  { head: out.to_bytes(), framing, body, keep_open, }
}

///|
/// The status line and the header section, to write first.
pub fn ResponseStream::head(self : ResponseStream) -> Bytes {
  self.head
}

///|
/// The bytes that carry `data`, the next part of the body: one chunk, or
/// `data` itself when the body is not chunked. An empty `data` gives no
/// bytes, so it cannot end a chunked body early.
pub fn ResponseStream::part(self : ResponseStream, data : BytesView) -> Bytes {
  match self.framing {
    _ if !self.body || data.is_empty() => b""
    Chunked => {
      let out = @buffer.Buffer(size_hint=data.length() + 12)
      out.write_string_utf8(data.length().to_string(radix=16))
      out.write_bytes(b"\r\n")
      out.write_bytes(data)
      out.write_bytes(b"\r\n")
      out.to_bytes()
    }
    UntilClose | NoContent => data.to_owned()
  }
}

///|
/// The bytes that end the body: the last chunk of a chunked body, and
/// otherwise none.
pub fn ResponseStream::end(self : ResponseStream) -> Bytes {
  match self.framing {
    Chunked if self.body => b"0\r\n\r\n"
    _ => b""
  }
}

///|
/// Whether the connection stays open after the response. When it does not,
/// the caller closes it after writing `end`; for a body that is not
/// chunked, that is what ends the body.
pub fn ResponseStream::keeps_open(self : ResponseStream) -> Bool {
  self.keep_open
}
