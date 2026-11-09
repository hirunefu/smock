// The mapping from an HTTP/2 stream onto the engine's request: a stream's
// request reaches the engine once it has ended, or a CONNECT once its
// HEADERS have arrived, as one request with the version `HTTP/2`, and
// `:authority` as the engine's authority input. Its field section is mapped
// when it arrives, on the stream's `Request` event, so that what is checked
// and counted there is what the engine will see.

///|
/// A request arriving on one HTTP/2 stream, from its HEADERS until the
/// client ends the stream. Its pseudo-header fields and its regular fields
/// are kept as the engine will see them, each value decoded as
/// `header_text` decodes it.
priv struct H2Request {
  /// `:method`.
  meth : String
  /// `:path`, the target as sent, or `:authority` for a CONNECT, which has
  /// no `:path`.
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
  /// The body length its `content-length` declares, or -1 without one. Of
  /// several, the largest, so that none over `--body-limit` passes.
  declared : Int64
  /// Whether it asks for `100 Continue` (`expect: 100-continue`) and has a
  /// body to send: not with a `content-length` of 0, as on HTTP/1.1.
  continues : Bool
  /// Its body: the first DATA received, until a second comes.
  mut body : Bytes
  /// Its body, once a second DATA has come.
  mut parts : @buffer.Buffer?
  /// When the read timeout ends it, in `@async.now()` milliseconds: the
  /// read timeout after the read that brought its first frame.
  deadline : Int64
}

///|
/// The fields of the requests of one HTTP/2 connection, decoded as
/// `header_text` decodes them. moonhttp gives a field that the client sends
/// again from its HPACK table the very octets it gave the time before, and
/// a field sent again as a literal has the same octets, so such a field
/// keeps its decoded name and value: a field a client sends with every
/// request is decoded once per connection, as over HTTP/1.1
/// (`DecodedHeaders`), and the Journal entries of its requests share it.
priv struct DecodedFields {
  /// The fields of the field section decoded last, by their place in it.
  fields : Array[@header.Header]
  /// Each of them, decoded.
  decoded : Array[(String, String)]
}

///|
fn DecodedFields::new() -> DecodedFields {
  { fields: [], decoded: [], }
}

///|
/// The name and value of `field`, the field at `place` in its field
/// section, decoded. Every field of a section is taken, in order, from
/// place 0.
fn DecodedFields::field(
  self : DecodedFields,
  place : Int32,
  field : @header.Header,
) -> (String, String) {
  if place < self.fields.length() {
    let last = self.fields[place]
    if same_octets(last.name, field.name) &&
      same_octets(last.value, field.value) {
      return self.decoded[place]
    }
  }
  let decoded = (header_text(field.name), header_text(field.value))
  if place < self.fields.length() {
    self.fields[place] = field
    self.decoded[place] = decoded
  } else {
    self.fields.push(field)
    self.decoded.push(decoded)
  }
  decoded
}

///|
/// Keeps the fields of the field section decoded last, of `count` fields,
/// and lets go of those past them, which a longer section before left:
/// the connection holds one section's fields at most, which
/// `--header-size-limit` bounds, rather than the last field each place
/// ever held.
fn DecodedFields::keep(self : DecodedFields, count : Int32) -> Unit {
  if count < self.fields.length() {
    // A truncated array still holds the elements past its length, until
    // they are overwritten.
    self.fields.truncate(count)
    self.fields.release_unused(placeholder=no_field)
    self.decoded.truncate(count)
    self.decoded.release_unused(placeholder=no_text)
  }
}

///|
/// What the places past the fields kept hold: nothing.
let no_field : @header.Header = { name: b"", value: b"", }

///|
/// What the places past the decoded fields kept hold: nothing.
let no_text : (String, String) = ("", "")

///|
/// Whether `a` and `b` hold the same octets: at once when they are the very
/// same, as a field from moonhttp's HPACK table is.
fn same_octets(a : Bytes, b : Bytes) -> Bool {
  physical_equal(a, b) || a == b
}

///|
/// A request that begins with the field section `fields`, as moonhttp
/// decoded and checked it: the pseudo-header fields first, then the regular
/// fields, in order, and that must have arrived by `deadline`. Each field is
/// decoded with `decoded`, the connection's, which then keeps `fields`
/// alone. `:scheme` is not passed on. A CONNECT's target is its
/// `:authority`.
fn H2Request::new(
  fields : Array[@header.Header],
  decoded : DecodedFields,
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
  let mut declared = -1L
  let mut expects = false
  for place in 0..<fields.length() {
    let field = fields[place]
    let name = field.name
    let text = decoded.field(place, field)
    let value = text.1
    if name.length() > 0 && name[0] == b':' {
      if name == b":method" {
        meth = value
      } else if name == b":path" {
        target = value
      } else if name == b":authority" {
        authority = Some(value)
      }
    } else if name == b"cookie" {
      if cookie < 0 {
        cookie = headers.length()
        headers.push(text)
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
      if name == b"content-length" {
        let length = declared_length(field.value)
        if length > declared {
          declared = length
        }
      } else if name == b"expect" && @http1.expects_continue(value) {
        expects = true
      }
      headers.push(text)
    }
  }
  decoded.keep(fields.length())
  if cookies is Some(joined) {
    headers[cookie] = ("cookie", joined.to_string())
  }
  // Only a CONNECT has no `:path`, as moonhttp sees to: its target is
  // `:authority`, as an HTTP/1.1 CONNECT's target is in authority-form.
  if target == "" && authority is Some(authority) {
    target = authority
  }
  {
    meth,
    target,
    authority,
    headers,
    declared,
    continues: expects && declared != 0L,
    body: b"",
    parts: None,
    deadline,
  }
}

///|
/// A body length longer than any `--body-limit`.
let too_long : Int64 = 0x1_0000_0000L

///|
/// The body length the `content-length` value `value` declares, `too_long`
/// for one longer than that. moonhttp has checked that `value` is digits
/// alone. smock reads them itself rather than take moonhttp's number, so
/// that a length too large for 32 bits cannot pass for a short one.
fn declared_length(value : Bytes) -> Int64 {
  let mut length = 0L
  for i in 0..<value.length() {
    length = length * 10L + (value[i].to_int() - 0x30).to_int64()
    if length >= too_long {
      return too_long
    }
  }
  length
}

///|
/// Whether the field section `fields`, as moonhttp decoded it, is larger
/// than `limit` octets, counted as RFC 7541, section 4.1, counts a header
/// list, and as moonhttp counts it against its own bound: each field's name
/// and value as received plus 32 octets, pseudo-header fields and every
/// `cookie` field included. It stops at the first field past `limit`.
fn is_list_over(fields : Array[@header.Header], limit : Int32) -> Bool {
  let mut size = 0
  for field in fields {
    size += field.cost()
    if size > limit {
      return true
    }
  }
  false
}

///|
/// Whether HTTP/1.1's rules refuse the request, so that its stream gets 400
/// as a malformed request (RFC 9113, section 8.1.1), checked with the
/// HTTP/1.1 codec's own checks:
///
/// - the method is not a token;
/// - `:path` is not an origin-form target, or `*` for OPTIONS, or holds an
///   octet outside 0x21 to 0x7E;
/// - for a CONNECT, which has no `:path`, as moonhttp sees to, its target,
///   `:authority`, is not in authority-form, a host and a port, as an
///   HTTP/1.1 CONNECT's target must be (RFC 9113, section 8.5);
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
  if meth == "CONNECT" {
    if !@http1.is_authority_form(self.target) {
      return true
    }
  } else if !(@http1.is_origin_or_asterisk_form(self.target, meth~) &&
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
/// How many octets of the body have arrived.
fn H2Request::received(self : H2Request) -> Int32 {
  match self.parts {
    Some(parts) => parts.length()
    None => self.body.length()
  }
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
/// The engine's view of the request, once it has ended, or for a CONNECT
/// once its HEADERS have arrived: `:method` is the method, `:path` the
/// target as sent (`:authority` for a CONNECT), the version `HTTP/2`, and
/// the headers the regular fields; pseudo-header fields are not among them.
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
