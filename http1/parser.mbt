///|
/// An incremental HTTP/1.1 request parser for one connection. It does no
/// I/O: the caller feeds it the bytes it reads, in order, and takes complete
/// requests out with `next`. However the bytes are split into pieces, it
/// takes out the same requests, so pipelined requests and requests that
/// arrive over many reads come out alike.
///
/// Bodies are framed by Content-Length or by chunked transfer coding. Chunk
/// extensions and trailer fields are accepted and ignored. An empty line
/// before a request line is ignored (RFC 9112, section 2.2).
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
  /// How many bytes after `start` the head scan has looked at, and where in
  /// the head they leave it, so the scan resumes there.
  priv mut scanned : Int
  priv mut scan : HeadScan
  /// The head of the next request and its length in bytes, once parsed.
  priv mut head : (Head, Int)?
  /// How far the chunked body of the next request is decoded.
  priv chunks : Chunks
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
  /// connection; the parser keeps returning this. The status is:
  ///
  /// - 400 for a malformed request line or header field (RFC 9112), and for
  ///   framing that is broken or ambiguous: a bad chunk size, broken chunk
  ///   framing, both Content-Length and Transfer-Encoding, Content-Length
  ///   values that disagree or are not numbers, or Transfer-Encoding in an
  ///   HTTP/1.0 request;
  /// - 413 for a body too large to hold;
  /// - 501 for a transfer coding other than `chunked`;
  /// - 505 for an HTTP major version other than 1.
  ///
  /// Bytes that cannot begin a request head get 400 as soon as they arrive.
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
  /// The header fields in the order they were sent. Trailer fields of a
  /// chunked body are not among them.
  headers : Array[Header]
  /// The body, decoded when it was chunked.
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
    scanned: 0,
    scan: Method(0),
    head: None,
    chunks: Chunks(),
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
      let head_end = match self.scan_head() {
        Some(head_end) => head_end
        None if self.scan is Broken => {
          self.invalid = Some(400)
          return Invalid(status=400)
        }
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
  let (body, consumed) = match head.framing {
    Length(length) => {
      let body_end = body_start + length
      if self.end < body_end {
        return NeedMore
      }
      (
        self.buf.unsafe_reinterpret_as_bytes()[body_start:body_end].to_owned(),
        head_length + length,
      )
    }
    Chunked =>
      match self.chunks.decode(self.buf, body_start, self.end) {
        Ok(Some(length)) => (self.chunks.take_body(), head_length + length)
        Ok(None) => return NeedMore
        Err(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
  }
  self.head = None
  self.scanned = 0
  self.scan = Method(0)
  self.start += consumed
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
  /// How the body that follows the head is framed.
  framing : Framing
}

///|
/// How the body of a request is framed.
priv enum Framing {
  /// The body is that many bytes long.
  Length(Int)
  /// The body is chunked (RFC 9112, section 7.1).
  Chunked
}

///|
/// Scans the head of the next request, from where the last scan stopped,
/// and returns the index just after the empty line that ends it, or `None`
/// while that line has not arrived or once `self.scan` is `Broken`.
///
/// Each byte is checked as it arrives, so bytes that cannot be part of a
/// request head are rejected at once instead of waiting for an empty line
/// that may never come.
fn Parser::scan_head(self : Parser) -> Int? {
  while self.start + self.scanned < self.end {
    self.scan = self.scan.after(self.buf[self.start + self.scanned])
    self.scanned += 1
    match self.scan {
      Fields(Ended) => return Some(self.start + self.scanned)
      Broken => return None
      EmptyLine => {
        // An empty line before the request line is consumed and ignored.
        self.start += self.scanned
        self.scanned = 0
        self.scan = Method(0)
      }
      _ => ()
    }
  }
  None
}

///|
/// Where a scan of a request head is (RFC 9112, sections 3 and 5):
/// `method SP request-target SP HTTP-version CRLF`, then the header section.
priv enum HeadScan {
  /// The LF of an empty line before the request line is next.
  EmptyLineLf
  /// An empty line before the request line has ended; servers ignore it
  /// (RFC 9112, section 2.2).
  EmptyLine
  /// In the method, after that many bytes of it.
  Method(Int)
  /// In the request target, after that many bytes of it.
  Target(Int)
  /// In the HTTP version, after that many bytes of `HTTP/D.D`.
  Version(Int)
  /// The LF ending the request line is next.
  VersionLf
  /// In the header section.
  Fields(Section)
  /// The bytes so far cannot begin a request.
  Broken
}

///|
/// The scan after the byte `c`.
fn HeadScan::after(self : HeadScan, c : Byte) -> HeadScan {
  match self {
    EmptyLineLf => if c == b'\n' { EmptyLine } else { Broken }
    Method(n) =>
      if is_tchar(c) {
        Method(n + 1)
      } else if c == b' ' && n > 0 {
        Target(0)
      } else if c == b'\r' && n == 0 {
        EmptyLineLf
      } else {
        Broken
      }
    Target(n) =>
      if c > b' ' && c < b'\x7f' {
        Target(n + 1)
      } else if c == b' ' && n > 0 {
        Version(0)
      } else {
        Broken
      }
    Version(n) => {
      let expected = match n {
        0 => c == b'H'
        1 | 2 => c == b'T'
        3 => c == b'P'
        4 => c == b'/'
        5 | 7 => is_digit(c)
        6 => c == b'.'
        _ => c == b'\r'
      }
      match (expected, n) {
        (false, _) => Broken
        (true, 8) => VersionLf
        (true, _) => Version(n + 1)
      }
    }
    VersionLf => if c == b'\n' { Fields(FieldStart) } else { Broken }
    Fields(section) =>
      match section.after(c) {
        Broken => Broken
        section => Fields(section)
      }
    EmptyLine | Broken => Broken
  }
}

///|
/// Where a scan of a header or trailer section is (RFC 9112, section 5):
/// field lines `field-name ":" OWS field-value OWS CRLF`, then an empty
/// line. Lines end with CRLF; a bare CR or LF breaks the section.
priv enum Section {
  /// A field line or the empty line is next.
  FieldStart
  /// In a field name.
  FieldName
  /// In a field value.
  FieldValue
  /// The LF ending a field line is next.
  FieldLf
  /// The LF of the empty line is next.
  EndLf
  /// The empty line has ended the section.
  Ended
  /// The section is not valid.
  Broken
}

///|
/// The scan after the byte `c`. Obsolete line folding and whitespace before
/// a colon break the section (RFC 9112, sections 5.1 and 5.2).
fn Section::after(self : Section, c : Byte) -> Section {
  match self {
    FieldStart =>
      if c == b'\r' {
        EndLf
      } else if is_tchar(c) {
        FieldName
      } else {
        Broken
      }
    FieldName =>
      if is_tchar(c) {
        FieldName
      } else if c == b':' {
        FieldValue
      } else {
        Broken
      }
    FieldValue =>
      if c == b'\r' {
        FieldLf
      } else if is_field_value_byte(c) {
        FieldValue
      } else {
        Broken
      }
    FieldLf => if c == b'\n' { FieldStart } else { Broken }
    EndLf => if c == b'\n' { Ended } else { Broken }
    Ended | Broken => Broken
  }
}

///|
/// Whether `c` may appear in a field value: visible characters, space, tab
/// and bytes above 0x7f (obs-text).
fn is_field_value_byte(c : Byte) -> Bool {
  c == b'\t' || (c >= b' ' && c != b'\x7f')
}

///|
/// Parses the head in `buf[start:end]`, which the head scan has checked and
/// which ends with an empty line, and decides how the body is framed.
fn parse_head(
  buf : FixedArray[Byte],
  start : Int,
  end : Int,
) -> Result[Head, Int] {
  let lines = split_lines(buf, start, end)
  let (meth, target, version) = match parse_request_line(buf, lines[0]) {
    Ok(line) => line
    Err(status) => return Err(status)
  }
  let headers = []
  let content_lengths = []
  let mut close = false
  let mut keep_alive = false
  let mut hosts = 0
  let transfer_encodings = []
  for line in lines[1:] {
    let header = parse_field(buf, line)
    headers.push(header)
    let name = header.name.to_lower()
    if name == "host" {
      hosts += 1
    } else if name == "transfer-encoding" {
      transfer_encodings.push(header.value)
    } else if name == "content-length" {
      content_lengths.push(header.value)
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
  // An HTTP/1.1 request names exactly one Host, and no request names more
  // (RFC 9112, section 3.2).
  if hosts > 1 || (version is Http11 && hosts != 1) {
    return Err(400)
  }
  let framing = if transfer_encodings.is_empty() {
    match content_length(content_lengths) {
      Ok(length) => Length(length)
      Err(status) => return Err(status)
    }
  } else {
    // A request with both is how requests are smuggled past a proxy that
    // reads the other one (RFC 9112, section 6.3).
    if !content_lengths.is_empty() {
      return Err(400)
    }
    // HTTP/1.0 has no Transfer-Encoding, so its framing cannot be trusted
    // (RFC 9112, section 6.1).
    if version is Http10 {
      return Err(400)
    }
    match check_transfer_codings(transfer_encodings) {
      Ok(_) => Chunked
      Err(status) => return Err(status)
    }
  }
  Ok({
    meth,
    target,
    version,
    headers,
    keep_alive: !close && (version is Http11 || keep_alive),
    framing,
  })
}

///|
/// Checks the transfer codings that the Transfer-Encoding fields `values`
/// list: only `chunked` is implemented, so any other coding gets 501, and
/// `chunked` must be listed exactly once, or the request gets 400.
fn check_transfer_codings(values : Array[Bytes]) -> Result[Unit, Int] {
  let mut chunked = 0
  for value in values {
    for coding in @utf8.decode_lossy(value).split(",") {
      match coding.trim(char_set=" \t").to_lower() {
        "" => ()
        "chunked" => chunked += 1
        _ => return Err(501)
      }
    }
  }
  if chunked == 1 {
    Ok(())
  } else {
    Err(400)
  }
}

///|
/// The body length that the Content-Length fields `values` give, 0 without
/// any.
///
/// Each field holds one or more comma-separated lengths, each one or more
/// digits, or the request gets 400. Lengths that disagree get 400 as well;
/// the same length repeated is not a conflict (RFC 9110, section 8.6). A
/// length too large to hold gets 413.
fn content_length(values : Array[Bytes]) -> Result[Int, Int] {
  // Lengths are compared as digits without leading zeros, so that lengths
  // too large to hold still compare.
  let mut digits : String? = None
  for value in values {
    for element in @utf8.decode_lossy(value).split(",") {
      let element = element.trim(char_set=" \t")
      if element.is_empty() || element.iter().any(c => c < '0' || c > '9') {
        return Err(400)
      }
      let significant = element.trim_start(char_set="0").to_owned()
      if digits is Some(previous) && previous != significant {
        return Err(400)
      }
      digits = Some(significant)
    }
  }
  let mut length = 0L
  for c in digits.unwrap_or("") {
    length = length * 10L + (c.to_int() - '0'.to_int()).to_int64()
    if length >= max_length.to_int64() {
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
/// Reads `method SP request-target SP HTTP-version` from the line
/// `buf[start:end]`, which the head scan has checked. A version whose major
/// number is not 1 gets 505; a later minor version than 1 is read as
/// HTTP/1.1 (RFC 9110, section 2.5).
fn parse_request_line(
  buf : FixedArray[Byte],
  line : (Int, Int),
) -> Result[(String, String, Version), Int] {
  let (start, end) = line
  // The method holds no space, and the version is the last 8 bytes,
  // `HTTP/D.D`.
  let mut space = start
  while buf[space] != b' ' {
    space += 1
  }
  let version = match (buf[end - 3], buf[end - 1]) {
    (b'1', b'0') => Http10
    (b'1', _) => Http11
    _ => return Err(505)
  }
  Ok((ascii(buf, start, space), ascii(buf, space + 1, end - 9), version))
}

///|
fn is_digit(c : Byte) -> Bool {
  c >= b'0' && c <= b'9'
}

///|
/// Reads `field-name ":" OWS field-value OWS` from the line
/// `buf[start:end]`, which the head scan has checked.
fn parse_field(buf : FixedArray[Byte], line : (Int, Int)) -> Header {
  let (start, end) = line
  let mut colon = start
  while buf[colon] != b':' {
    colon += 1
  }
  let mut value_start = colon + 1
  while value_start < end && is_ows(buf[value_start]) {
    value_start += 1
  }
  let mut value_end = end
  while value_end > value_start && is_ows(buf[value_end - 1]) {
    value_end -= 1
  }
  {
    name: ascii(buf, start, colon),
    value: buf.unsafe_reinterpret_as_bytes()[value_start:value_end].to_owned(),
  }
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
