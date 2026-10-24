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
/// Whether HTTP/1.1's rules refuse the request, so that its stream gets 400
/// as a malformed request (RFC 9113, section 8.1.1), checked with the
/// HTTP/1.1 codec's own checks:
///
/// - the method is not a token;
/// - `:path` is not an origin-form target, or `*` for OPTIONS, or holds an
///   octet outside 0x21 to 0x7E. A CONNECT has no `:path`, as moonhttp
///   sees to, so it has none to check;
/// - `:authority` is not a valid Host value;
/// - a field name is not a token, or a field value holds a control
///   character other than tab, or DEL;
/// - there is more than one `host` field, or its value is not a valid Host
///   value, or it names another host than `:authority` (section 8.3.1),
///   compared as Mock Hosts are: in any case, without the port or a
///   trailing dot.
///
/// moonhttp has already reset the streams that break RFC 9113's own field
/// rules, so names hold no upper case, and values no NUL, CR or LF.
fn H2Request::is_malformed(self : H2Request) -> Bool {
  let meth = self.meth
  if !@http1.is_token(meth) {
    return true
  }
  if meth != "CONNECT" &&
    !(@http1.is_origin_or_asterisk_form(self.target, meth~) &&
    @http1.is_visible_ascii(self.target)) {
    return true
  }
  if self.authority is Some(authority) && !@http1.is_host_value(authority) {
    return true
  }
  let mut host : String? = None
  for header in self.headers {
    if !@http1.is_token(header.0) || !@http1.is_field_value(header.1) {
      return true
    }
    if header.0 == "host" {
      if host is Some(_) || !@http1.is_host_value(header.1) {
        return true
      }
      host = Some(header.1)
    }
  }
  // Only a request that names its Host twice pays for the comparison.
  if self.authority is Some(authority) && host is Some(host) {
    return @definitions.normalize_host(authority) !=
      @definitions.normalize_host(host)
  }
  false
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
