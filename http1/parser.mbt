///|
/// An incremental HTTP/1.1 request parser for one connection. It does no
/// I/O: the caller feeds it the bytes it reads, in order, and takes complete
/// requests out with `next`.
///
/// ```mbt check
/// test {
///   let parser = @http1.Parser()
///   parser.feed(b"GET / HTTP/1.1\r\nHost: a.example\r\n\r\n")
///   guard parser.next() is Complete(req) else { fail("no request") }
///   inspect(req.target, content="/")
///   inspect(parser.next() is NeedMore, content="true")
/// }
/// ```
pub struct Parser {
  /// Bytes fed and not consumed yet are `buf[start:end]`.
  priv mut buf : FixedArray[Byte]
  priv mut start : Int
  priv mut end : Int
  /// The head of the next request and its length in bytes, once parsed.
  priv mut head : (Head, Int)?
  /// The status of the error that stopped the parser.
  priv mut invalid : Int?
}

///|
/// What `Parser::next` found in the bytes fed so far.
pub(all) enum Parsed {
  /// A complete request. Its bytes are consumed; the next call looks at the
  /// bytes after it.
  Complete(Request)
  /// The next request is not complete yet: feed more bytes.
  NeedMore
  /// The bytes are not a valid request. Answer with `status` and close the
  /// connection; the parser keeps returning this.
  Invalid(status~ : Int)
} derive(Debug)

///|
/// The HTTP version of a request.
pub(all) enum Version {
  Http10
  Http11
} derive(Debug, Eq)

///|
/// A header field, with its name as sent and its value without the
/// surrounding whitespace.
pub(all) struct Header {
  name : String
  value : Bytes
} derive(Debug, Eq)

///|
/// A complete request.
pub(all) struct Request {
  meth : String
  /// The request target as sent, such as `/users/1?x=y`.
  target : String
  version : Version
  /// The header fields in the order they were sent.
  headers : Array[Header]
  body : Bytes
  /// Whether the connection stays open after the response: HTTP/1.1 keeps
  /// it open unless the request says `Connection: close`, HTTP/1.0 closes it
  /// unless the request says `Connection: keep-alive`.
  keep_alive : Bool
} derive(Debug, Eq)

///|
/// Creates a parser with nothing fed yet.
pub fn Parser::Parser() -> Parser {
  {
    buf: FixedArray::make(4096, b'\x00'),
    start: 0,
    end: 0,
    head: None,
    invalid: None,
  }
}

///|
/// Appends `data` to the bytes to parse.
pub fn Parser::feed(self : Parser, data : BytesView) -> Unit {
  let used = self.end - self.start
  if self.buf.length() - self.end < data.length() {
    let mut capacity = self.buf.length()
    while capacity < used + data.length() {
      capacity *= 2
    }
    let target = if capacity == self.buf.length() {
      self.buf
    } else {
      FixedArray::make(capacity, b'\x00')
    }
    self.buf.blit_to(target, len=used, src_offset=self.start, dst_offset=0)
    self.buf = target
    self.start = 0
    self.end = used
  }
  self.buf.blit_from_bytesview(self.end, data)
  self.end += data.length()
}

///|
/// Takes the next request out of the bytes fed so far.
pub fn Parser::next(self : Parser) -> Parsed {
  if self.invalid is Some(status) {
    return Invalid(status~)
  }
  let (head, head_length) = match self.head {
    Some(parsed) => parsed
    None => {
      let head_end = match find_head_end(self.buf, self.start, self.end) {
        Some(head_end) => head_end
        None => return NeedMore
      }
      match parse_head(self.buf, self.start, head_end) {
        Ok(head) => {
          self.head = Some((head, head_end - self.start))
          (head, head_end - self.start)
        }
        Err(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
    }
  }
  let body_start = self.start + head_length
  let body_end = body_start + head.content_length
  if self.end < body_end {
    return NeedMore
  }
  let body = self.buf.unsafe_reinterpret_as_bytes()[body_start:body_end].to_owned()
  self.head = None
  self.start = body_end
  Complete({
    meth: head.meth,
    target: head.target,
    version: head.version,
    headers: head.headers,
    body,
    keep_alive: head.keep_alive,
  })
}

///|
/// The request line and header fields of a request.
priv struct Head {
  meth : String
  target : String
  version : Version
  headers : Array[Header]
  keep_alive : Bool
  /// The length of the body that follows the head.
  content_length : Int
}

///|
/// The index just after the empty line that ends the head in
/// `buf[from:end]`, or `None` while that line has not arrived.
fn find_head_end(buf : FixedArray[Byte], from : Int, end : Int) -> Int? {
  for i in from..<(end - 3) {
    if buf[i] == b'\r' &&
      buf[i + 1] == b'\n' &&
      buf[i + 2] == b'\r' &&
      buf[i + 3] == b'\n' {
      return Some(i + 4)
    }
  }
  None
}

///|
/// Parses the head in `buf[start:end]`, which ends with an empty line.
fn parse_head(
  buf : FixedArray[Byte],
  start : Int,
  end : Int,
) -> Result[Head, Int] {
  let lines = split_lines(buf, start, end)
  let (meth, target, version) = match parse_request_line(buf, lines[0]) {
    Some(line) => line
    None => return Err(400)
  }
  let headers = []
  let mut content_length = None
  let mut close = false
  let mut keep_alive = false
  let mut hosts = 0
  let mut transfer_encoding = false
  for line in lines[1:] {
    let header = match parse_field(buf, line) {
      Some(header) => header
      None => return Err(400)
    }
    headers.push(header)
    let name = header.name.to_lower()
    if name == "host" {
      hosts += 1
    } else if name == "transfer-encoding" {
      transfer_encoding = true
    } else if name == "content-length" {
      let length = match parse_content_length(header.value) {
        Ok(length) => length
        Err(status) => return Err(status)
      }
      if content_length is Some(previous) && previous != length {
        return Err(400)
      }
      content_length = Some(length)
    } else if name == "connection" {
      for token in @utf8.decode_lossy(header.value).split(",") {
        match token.trim(char_set=" \t").to_lower() {
          "close" => close = true
          "keep-alive" => keep_alive = true
          _ => ()
        }
      }
    }
  }
  // An HTTP/1.1 request names exactly one Host (RFC 9112, section 3.2).
  if version is Http11 && hosts != 1 {
    return Err(400)
  }
  if transfer_encoding {
    return Err(501)
  }
  Ok({
    meth,
    target,
    version,
    headers,
    keep_alive: !close && (version is Http11 || keep_alive),
    content_length: content_length.unwrap_or(0),
  })
}

///|
/// A Content-Length value: one or more digits. A length too large to hold
/// gets 413.
fn parse_content_length(value : Bytes) -> Result[Int, Int] {
  if value.length() == 0 {
    return Err(400)
  }
  let mut length = 0L
  for c in value {
    if c < b'0' || c > b'9' {
      return Err(400)
    }
    length = length * 10L + (c - b'0').to_int64()
    if length > 0x7fffffffL {
      return Err(413)
    }
  }
  Ok(length.to_int())
}

///|
/// The `(start, end)` of each line of the head in `buf[start:end]`, without
/// its CRLF and without the final empty line.
fn split_lines(
  buf : FixedArray[Byte],
  start : Int,
  end : Int,
) -> Array[(Int, Int)] {
  let lines = []
  let mut line_start = start
  for i in start..<(end - 2) {
    if buf[i] == b'\r' && buf[i + 1] == b'\n' {
      lines.push((line_start, i))
      line_start = i + 2
    }
  }
  lines
}

///|
/// Parses `method SP request-target SP HTTP-version`.
fn parse_request_line(
  buf : FixedArray[Byte],
  line : (Int, Int),
) -> (String, String, Version)? {
  let (start, end) = line
  let mut i = start
  while i < end && is_tchar(buf[i]) {
    i += 1
  }
  if i == start || i >= end || buf[i] != b' ' {
    return None
  }
  let meth = ascii(buf, start, i)
  let target_start = i + 1
  i = target_start
  while i < end && buf[i] > b' ' && buf[i] < b'\x7f' {
    i += 1
  }
  if i == target_start || i >= end || buf[i] != b' ' {
    return None
  }
  let target = ascii(buf, target_start, i)
  let version = match ascii(buf, i + 1, end) {
    "HTTP/1.1" => Http11
    "HTTP/1.0" => Http10
    _ => return None
  }
  Some((meth, target, version))
}

///|
/// Parses `field-name ":" OWS field-value OWS`.
fn parse_field(buf : FixedArray[Byte], line : (Int, Int)) -> Header? {
  let (start, end) = line
  let mut i = start
  while i < end && is_tchar(buf[i]) {
    i += 1
  }
  if i == start || i >= end || buf[i] != b':' {
    return None
  }
  let name = ascii(buf, start, i)
  let mut value_start = i + 1
  while value_start < end && is_ows(buf[value_start]) {
    value_start += 1
  }
  let mut value_end = end
  while value_end > value_start && is_ows(buf[value_end - 1]) {
    value_end -= 1
  }
  for k in value_start..<value_end {
    let c = buf[k]
    if (c < b' ' && c != b'\t') || c == b'\x7f' {
      return None
    }
  }
  Some({
    name,
    value: buf.unsafe_reinterpret_as_bytes()[value_start:value_end].to_owned(),
  })
}

///|
/// Whether `c` may appear in a token, such as a method or a field name.
fn is_tchar(c : Byte) -> Bool {
  (c >= b'a' && c <= b'z') ||
  (c >= b'A' && c <= b'Z') ||
  (c >= b'0' && c <= b'9') ||
  c
  is (b'!'
  | b'#'
  | b'$'
  | b'%'
  | b'&'
  | b'\''
  | b'*'
  | b'+'
  | b'-'
  | b'.'
  | b'^'
  | b'_'
  | b'`'
  | b'|'
  | b'~')
}

///|
fn is_ows(c : Byte) -> Bool {
  c == b' ' || c == b'\t'
}

///|
/// `buf[start:end]`, which holds only ASCII, as a string.
fn ascii(buf : FixedArray[Byte], start : Int, end : Int) -> String {
  let out = StringBuilder()
  for i in start..<end {
    out.write_char(buf[i].to_char())
  }
  out.to_string()
}
