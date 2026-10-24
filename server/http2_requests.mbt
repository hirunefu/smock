// The mapping from an HTTP/2 stream onto the engine's request: a stream's
// request reaches the engine once it has ended, as one request with the
// version `HTTP/2`, and `:authority` as the engine's authority input. Its
// field section is mapped when it arrives, on the stream's `Request` event,
// so that what is checked and counted there is what the engine will see.

///|
/// A request arriving on one HTTP/2 stream, from its HEADERS until the
/// client ends the stream. Its pseudo-header fields and its regular fields
/// are kept as the engine will see them, each value decoded as
/// `header_text` decodes it.
priv struct H2Request {
  /// `:method`.
  meth : String
  /// `:path`, the target as sent, or empty without one.
  target : String
  /// `:authority`, or `None` without one. When given, it is the Host,
  /// ahead of any `host` field; without it, the engine reads the Host from
  /// the `host` field, and a request with neither has none.
  authority : String?
  /// The regular fields, in the order received, with their names in lower
  /// case as HTTP/2 sends them. Several `cookie` fields are one field, their
  /// values joined with `; `, in their order, at the place of the first
  /// (RFC 9113, section 8.2.3), as one Cookie line is over HTTP/1.1.
  headers : Array[(String, String)]
  /// Its body: the first DATA received, until a second comes.
  mut body : Bytes
  /// Its body, once a second DATA has come.
  mut parts : @buffer.Buffer?
  /// When the read timeout ends it, in `@async.now()` milliseconds: the
  /// read timeout after the read that brought its first frame.
  deadline : Int64
}

///|
/// A request that begins with the field section `fields`, as moonhttp
/// decoded and checked it: the pseudo-header fields first, then the regular
/// fields, in order, and that must have arrived by `deadline`. `:scheme` is
/// not passed on.
fn H2Request::new(
  fields : Array[@header.Header],
  deadline~ : Int64,
) -> H2Request {
  let mut meth = ""
  let mut target = ""
  let mut authority = None
  let headers = Array(capacity=fields.length())
  // Where the first `cookie` field sits among `headers`, and, once a
  // second has come, the values joined so far.
  let mut cookie = -1
  let mut cookies : StringBuilder? = None
  for field in fields {
    let name = field.name
    if name.length() > 0 && name[0] == b':' {
      if name == b":method" {
        meth = header_text(field.value)
      } else if name == b":path" {
        target = header_text(field.value)
      } else if name == b":authority" {
        authority = Some(header_text(field.value))
      }
    } else if name == b"cookie" {
      let value = header_text(field.value)
      if cookie < 0 {
        cookie = headers.length()
        headers.push(("cookie", value))
      } else {
        let joined = match cookies {
          Some(joined) => joined
          None => {
            let joined = StringBuilder()
            joined.write_string(headers[cookie].1)
            cookies = Some(joined)
            joined
          }
        }
        joined.write_string("; ")
        joined.write_string(value)
      }
    } else {
      headers.push((header_text(name), header_text(field.value)))
    }
  }
  if cookies is Some(joined) {
    headers[cookie] = ("cookie", joined.to_string())
  }
  { meth, target, authority, headers, body: b"", parts: None, deadline, }
}

///|
/// Adds `data`, the next DATA octets of the stream, to the body.
fn H2Request::receive(self : H2Request, data : Bytes) -> Unit {
  match self.parts {
    Some(parts) => parts.write_bytes(data)
    None if self.body.length() == 0 => self.body = data
    None => {
      let parts = @buffer.Buffer(size_hint=self.body.length() + data.length())
      parts.write_bytes(self.body)
      parts.write_bytes(data)
      self.parts = Some(parts)
      self.body = b""
    }
  }
}

///|
/// The engine's view of the request, once it has ended: `:method` is the
/// method, `:path` the target as sent, the version `HTTP/2`, and the
/// headers the regular fields; pseudo-header fields are not among them.
/// `authority` goes to the engine beside it.
fn H2Request::to_engine(self : H2Request) -> @engine.Request {
  let body = match self.parts {
    Some(parts) => parts.to_bytes()
    None => self.body
  }
  {
    meth: self.meth,
    target: self.target,
    version: "HTTP/2",
    headers: self.headers,
    body,
  }
}
