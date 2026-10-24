// The mapping from an HTTP/2 stream onto the engine's request: a stream's
// request reaches the engine once it has ended, as one request with the
// version `HTTP/2`, and `:authority` as the engine's authority input.

///|
/// A request arriving on one HTTP/2 stream, from its HEADERS until the
/// client ends the stream.
priv struct H2Request {
  /// Its field section, as moonhttp decoded and checked it: the
  /// pseudo-header fields first, then the regular fields, in order.
  fields : Array[@header.Header]
  /// Its body: the first DATA received, until a second comes.
  mut body : Bytes
  /// Its body, once a second DATA has come.
  mut parts : @buffer.Buffer?
}

///|
/// A request that begins with the field section `fields`.
fn H2Request::new(fields : Array[@header.Header]) -> H2Request {
  { fields, body: b"", parts: None, }
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
/// The engine's view of the request: `:method` is the method, `:path` the
/// target as sent, and the version `HTTP/2`. The headers are the regular
/// fields in order, their names in lower case as HTTP/2 sends them, with
/// their values decoded as `header_text` decodes them; pseudo-header
/// fields are not among them.
fn H2Request::to_engine(self : H2Request) -> @engine.Request {
  let mut meth = ""
  let mut target = ""
  let headers = Array(capacity=self.fields.length())
  for field in self.fields {
    let name = field.name
    if name.length() > 0 && name[0] == b':' {
      if name == b":method" {
        meth = header_text(field.value)
      } else if name == b":path" {
        target = header_text(field.value)
      }
    } else {
      headers.push((header_text(name), header_text(field.value)))
    }
  }
  let body = match self.parts {
    Some(parts) => parts.to_bytes()
    None => self.body
  }
  { meth, target, version: "HTTP/2", headers, body, }
}

///|
/// The request's `:authority`, the engine's authority input, decoded as
/// `header_text` decodes it, or `None` without one.
fn H2Request::authority(self : H2Request) -> String? {
  for field in self.fields {
    if field.name == b":authority" {
      return Some(header_text(field.value))
    }
  }
  None
}
