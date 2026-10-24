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
/// It decides what a server must decide from the bytes alone: whether the
/// connection stays open after each request (`Request::keep_alive`), when
/// to answer `100 Continue` (`Continue`), and whether a request is over the
/// limits on header size, header count and body size that `Parser::Parser`
/// takes. Timeouts are the caller's; `Parser::in_request` tells which one
/// runs.
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
  priv mut start : Int32
  priv mut end : Int32
  /// How many bytes after `start` the head scan has looked at, and where in
  /// the head they leave it, so the scan resumes there: the part of the
  /// head, how many bytes of the method, the target or the version it has
  /// seen, and where in the header section it is.
  priv mut scanned : Int32
  priv mut scan : HeadScan
  priv mut scan_count : Int32
  priv mut section : Section
  /// Where each line of the head being scanned ends, as the index of its
  /// CR counted from `start`: the request line, then each field line.
  priv line_ends : Array[Int32]
  /// How many header fields the head scan has seen begin.
  priv mut fields : Int32
  /// The head of the next request, once parsed. Its bytes are consumed.
  priv mut head : Head?
  /// The head parsed last. A client tends to send the same method, target
  /// and header fields on a connection again and again, so the next head
  /// reuses its strings and fields where they are the same.
  priv mut previous : Head?
  /// How far the chunked body of the next request is decoded.
  priv chunks : Chunks
  /// The status of the error that stopped the parser.
  priv mut invalid : Int32?
  /// The most bytes a request head may take.
  priv header_size_limit : Int32
  /// The most header fields a request may have.
  priv header_count_limit : Int32
  /// The longest body a request may have, in bytes.
  priv body_limit : Int32
}

///|
/// What `Parser::next` found in the bytes fed so far.
pub(all) enum Parsed {
  /// A complete request. Its bytes are consumed; the next call looks at the
  /// bytes after it.
  Complete(Request)
  /// The head of the next request asks whether to send its body
  /// (`Expect: 100-continue`), and the body is within the body limit: write
  /// a `100 Continue` response, such as `encode_response(100, [], b"")`,
  /// then call `next` again. Only HTTP/1.1 requests with a body ask, and
  /// each asks once, right after its head, whether or not its body has
  /// arrived (RFC 9110, section 10.1.1).
  Continue
  /// The next request is not complete yet: feed more bytes.
  NeedMore
  /// The bytes are not a valid request. Answer with `status` and close the
  /// connection; the parser keeps returning this. The status is:
  ///
  /// - 400 for a malformed request line or header field (RFC 9112), such as
  ///   a request target in none of the four forms of RFC 9112, section 3.2,
  ///   or with a fragment, or in a form its method does not take
  ///   (asterisk-form is only for OPTIONS, authority-form only for CONNECT,
  ///   and CONNECT takes no other form), or a Host field whose value is not
  ///   a host and an optional port; and for framing that is broken or
  ///   ambiguous: a bad chunk size, broken chunk framing, both
  ///   Content-Length and Transfer-Encoding, Content-Length values that
  ///   disagree or are not numbers, or Transfer-Encoding in an HTTP/1.0
  ///   request;
  /// - 413 for a body over the body limit;
  /// - 431 for a head over the header size limit or the header count limit;
  /// - 501 for a transfer coding other than `chunked`;
  /// - 505 for an HTTP major version other than 1.
  ///
  /// Bytes that cannot begin a request head get 400 as soon as they arrive.
  Invalid(status~ : Int32)
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
///
/// - `header_size_limit` is the most bytes a request head may take: its
///   request line, its header fields and the empty line that ends them.
///   Empty lines before the request line do not count. A head that grows
///   past it gets 431 at once.
/// - `header_count_limit` is the most header fields a request may have. A
///   request gets 431 as soon as a field over it begins.
/// - `body_limit` is the longest body a request may have, in bytes, counted
///   after chunked decoding: chunk sizes, chunk extensions and trailer
///   fields do not count. A declared Content-Length over it gets 413 before
///   any of the body is read, and a chunked body gets 413 as soon as a chunk
///   size would take it past the limit, before that chunk's data. The parser
///   keeps the body and not the framing around it, so neither the framing
///   nor the body can make it hold much more than the body limit.
///
/// The defaults are 16 KiB, 100 header fields and 10 MiB.
pub fn Parser::Parser(
  header_size_limit~ : Int32 = 16 * 1024,
  header_count_limit~ : Int32 = 100,
  body_limit~ : Int32 = 10 * 1024 * 1024,
) -> Parser {
  let body_limit = if body_limit < 0 {
    0
  } else if body_limit >= max_length {
    max_length - 1
  } else {
    body_limit
  }
  {
    buf: FixedArray::make(4096, b'\x00'),
    start: 0,
    end: 0,
    scanned: 0,
    scan: Method,
    scan_count: 0,
    section: FieldStart,
    line_ends: [],
    fields: 0,
    head: None,
    previous: None,
    chunks: Chunks(limit=body_limit),
    invalid: None,
    header_size_limit,
    header_count_limit,
    body_limit,
  }
}

///|
/// Appends `data` to the bytes to parse.
pub fn Parser::feed(self : Parser, data : BytesView) -> Unit {
  let used = self.end - self.start
  if self.buf.length() - self.end < data.length() {
    let needed = used + data.length()
    let mut capacity = self.buf.length()
    while capacity < needed {
      capacity = if capacity >= 0x40000000 { needed } else { capacity * 2 }
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
/// Whether part of a request has been fed and not taken out by `next` yet.
/// A server uses it to tell a request that is still arriving (the read
/// timeout runs) from a connection waiting for its next request (the idle
/// timeout runs).
///
/// Empty lines before a request line are not part of a request once `next`
/// has skipped them, so ask after `next` returns `NeedMore`.
pub fn Parser::in_request(self : Parser) -> Bool {
  self.head is Some(_) || self.end > self.start
}

///|
/// Takes the next request out of the bytes fed so far.
pub fn Parser::next(self : Parser) -> Parsed {
  if self.invalid is Some(status) {
    return Invalid(status~)
  }
  let head = match self.head {
    Some(head) => head
    None => {
      let head_end = match self.scan_head() {
        Ended(head_end) => head_end
        Partial => return NeedMore
        Rejected(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
      let parsed = parse_head(
        self.buf,
        self.start,
        self.line_ends,
        self.body_limit,
        self.previous,
      )
      self.line_ends.clear()
      match parsed {
        Ok(head) => {
          self.head = Some(head)
          self.previous = Some(head)
          self.start = head_end
          self.scanned = 0
          self.scan = Method
          self.scan_count = 0
          self.fields = 0
          if head.expects_continue {
            return Continue
          }
          head
        }
        Err(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
    }
  }
  let (body, consumed) = match head.framing {
    Length(length) => {
      let body_end = self.start + length
      if self.end < body_end {
        return NeedMore
      }
      (
        self.buf.unsafe_reinterpret_as_bytes()[self.start:body_end].to_owned(),
        length,
      )
    }
    Chunked =>
      match self.chunks.decode(self.buf, self.start, self.end) {
        Ok(Some(length)) => (self.chunks.take_body(), length)
        Ok(None) => {
          // The decoder holds what it needs of these bytes.
          self.start = self.end
          return NeedMore
        }
        Err(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
  }
  self.head = None
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
  /// Whether to answer `100 Continue` before the body.
  expects_continue : Bool
}

///|
/// How the body of a request is framed.
priv enum Framing {
  /// The body is that many bytes long.
  Length(Int32)
  /// The body is chunked (RFC 9112, section 7.1).
  Chunked
}

///|
/// How far a scan of the head of the next request got.
priv enum HeadEnd {
  /// The head ends just before this index.
  Ended(Int32)
  /// The end of the head has not arrived.
  Partial
  /// The head gets this error status.
  Rejected(Int32)
}

///|
/// Scans the head of the next request, from where the last scan stopped.
///
/// Each byte is checked as it arrives, so bytes that cannot be part of a
/// request head, and heads over the limits, are rejected at once instead of
/// waiting for an empty line that may never come.
///
/// The scan runs on local variables and allocates nothing, since it looks at
/// every byte of every head. The bytes of a target, a field name or a field
/// value, most of a head, are taken in an inner loop: up to the header size
/// limit, so that the byte past it still gets 431 or 400 as it would alone.
/// It records where each line ends, for `parse_head`.
fn Parser::scan_head(self : Parser) -> HeadEnd {
  let buf = self.buf
  let end = self.end
  let size_limit = self.header_size_limit
  let count_limit = self.header_count_limit
  let mut start = self.start
  let mut at = self.start + self.scanned
  let mut scan = self.scan
  let mut count = self.scan_count
  let mut section = self.section
  let mut fields = self.fields
  let line_ends = self.line_ends
  let mut result : HeadEnd = Partial
  while at < end {
    let c = buf[at]
    at += 1
    match scan {
      EmptyLineLf => scan = if c == b'\n' { EmptyLine } else { Broken }
      Method =>
        if is_tchar(c) {
          count += 1
        } else if c == b' ' && count > 0 {
          scan = Target
          count = 0
        } else if c == b'\r' && count == 0 {
          scan = EmptyLineLf
        } else {
          scan = Broken
        }
      Target =>
        if c > b' ' && c < b'\x7f' {
          count += 1
        } else if c == b' ' && count > 0 {
          scan = Version
          count = 0
        } else {
          scan = Broken
        }
      Version => {
        let expected = match count {
          0 => c == b'H'
          1 | 2 => c == b'T'
          3 => c == b'P'
          4 => c == b'/'
          5 | 7 => is_digit(c)
          6 => c == b'.'
          _ => c == b'\r'
        }
        if !expected {
          scan = Broken
        } else if count == 8 {
          scan = VersionLf
          line_ends.push(at - 1 - start)
        } else {
          count += 1
        }
      }
      VersionLf =>
        if c == b'\n' {
          scan = Fields
          section = FieldStart
        } else {
          scan = Broken
        }
      Fields => {
        let before = section
        section = before.after(c)
        match section {
          Broken => scan = Broken
          FieldName if before is FieldStart => fields += 1
          FieldLf => line_ends.push(at - 1 - start)
          _ => ()
        }
      }
      EmptyLine | Broken => scan = Broken
    }
    if scan is Broken {
      result = Rejected(400)
      break
    }
    if at - start > size_limit || fields > count_limit {
      result = Rejected(431)
      break
    }
    // The rest of a run of bytes that leave the scan where it is.
    let stop = if end - start < size_limit { end } else { start + size_limit }
    if scan is EmptyLine {
      // An empty line before the request line is consumed and ignored.
      start = at
      scan = Method
      count = 0
    } else if scan is Fields {
      if section is Ended {
        result = Ended(at)
        break
      }
      if section is FieldValue {
        // Eight bytes at a time while none of them ends the value.
        let bytes = buf.unsafe_reinterpret_as_bytes()
        while at + 8 <= stop && !has_control(bytes.unsafe_read_uint64_le(at)) {
          at += 8
        }
        while at < stop && is_field_value_byte(buf[at]) {
          at += 1
        }
      } else if section is FieldName {
        while at < stop && is_tchar(buf[at]) {
          at += 1
        }
      }
    } else if scan is Target {
      let from = at
      // Eight bytes at a time while all of them are visible characters.
      let bytes = buf.unsafe_reinterpret_as_bytes()
      while at + 8 <= stop && is_visible(bytes.unsafe_read_uint64_le(at)) {
        at += 8
      }
      while at < stop && buf[at] > b' ' && buf[at] < b'\x7f' {
        at += 1
      }
      count += at - from
    }
  }
  self.start = start
  self.scanned = at - start
  self.scan = scan
  self.scan_count = count
  self.section = section
  self.fields = fields
  result
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
  /// In the method.
  Method
  /// In the request target.
  Target
  /// In the HTTP version, `HTTP/D.D`, then the CR that ends the line.
  Version
  /// The LF ending the request line is next.
  VersionLf
  /// In the header section.
  Fields
  /// The bytes so far cannot begin a request.
  Broken
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
/// `0x01` in each of the eight bytes of a word.
const ONES : UInt64 = 0x0101010101010101

///|
/// `0x80` in each of the eight bytes of a word.
const HIGHS : UInt64 = 0x8080808080808080

///|
/// Whether one of the eight bytes of `word` is below 0x20 or is 0x7f: a
/// byte `is_field_value_byte` refuses, or a tab. With no such byte, all
/// eight may appear in a field value.
fn has_control(word : UInt64) -> Bool {
  // A byte below n sets its high bit in (word - n) & !word, for n <= 0x80;
  // a borrow can only set the bits of bytes above such a byte.
  let below_space = (word - ONES * 0x20) & word.lnot()
  let del = word ^ (ONES * 0x7f)
  let is_del = (del - ONES) & del.lnot()
  ((below_space | is_del) & HIGHS) != 0
}

///|
/// Whether each of the eight bytes of `word` is a visible ASCII character,
/// 0x21 to 0x7e, as a request target is made of.
fn is_visible(word : UInt64) -> Bool {
  let below = (word - ONES * 0x21) & word.lnot()
  // A byte of 0x7f or more sets its high bit in word + 1 or in word.
  let above = (word + ONES) | word
  ((below | above) & HIGHS) == 0
}

///|
/// Parses the head that starts at `buf[start]`, which the head scan has
/// checked and which ends with an empty line, and decides how the body is
/// framed. `line_ends` are where its lines end, as the head scan recorded
/// them. The method, the target and each header field that are the same as
/// in the `previous` head, field by field in order, are its own strings and
/// fields.
fn parse_head(
  buf : FixedArray[Byte],
  start : Int32,
  line_ends : Array[Int32],
  body_limit : Int32,
  previous : Head?,
) -> Result[Head, Int32] {
  let (meth, target, version) = match
    parse_request_line(buf, start, start + line_ends[0], previous) {
    Ok(line) => line
    Err(status) => return Err(status)
  }
  let previous_headers = match previous {
    Some(previous) => previous.headers
    None => []
  }
  let headers = []
  let content_lengths = []
  let mut close = false
  let mut keep_alive = false
  let mut expect_continue = false
  let mut hosts = 0
  let transfer_encodings = []
  for line in 1..<line_ends.length() {
    let header = parse_field(
      buf,
      start + line_ends[line - 1] + 2,
      start + line_ends[line],
      previous_headers.get(line - 1),
    )
    headers.push(header)
    let name = header.name
    if is_name(name, "host") {
      // A Host field with an invalid value gets 400 (RFC 9112, section 3.2).
      if !is_host_value(@utf8.decode_lossy(header.value)) {
        return Err(400)
      }
      hosts += 1
    } else if is_name(name, "transfer-encoding") {
      transfer_encodings.push(header.value)
    } else if is_name(name, "content-length") {
      content_lengths.push(header.value)
    } else if is_name(name, "connection") {
      for token in list_elements(header.value) {
        match token.to_lower() {
          "close" => close = true
          "keep-alive" => keep_alive = true
          _ => ()
        }
      }
    } else if is_name(name, "expect") {
      for expectation in list_elements(header.value) {
        if expectation.to_lower() == "100-continue" {
          expect_continue = true
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
    match content_length(content_lengths, body_limit) {
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
    // An HTTP/1.0 client cannot ask for 100 Continue, and there is nothing
    // to confirm without a body (RFC 9110, section 10.1.1).
    expects_continue: expect_continue &&
    version is Http11 &&
    !(framing is Length(0)),
  })
}

///|
/// Checks the transfer codings that the Transfer-Encoding fields `values`
/// list: only `chunked` is implemented, so any other coding gets 501, and
/// `chunked` must be listed exactly once, or the request gets 400.
fn check_transfer_codings(values : Array[Bytes]) -> Result[Unit, Int32] {
  let mut chunked = 0
  for value in values {
    for coding in list_elements(value) {
      match coding.to_lower() {
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
/// length over `limit` gets 413.
fn content_length(values : Array[Bytes], limit : Int32) -> Result[Int32, Int32] {
  // Lengths are compared as digits without leading zeros, so that lengths
  // too large to hold still compare.
  let mut digits : String? = None
  for value in values {
    for element in list_elements(value) {
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
    if length > limit.to_int64() {
      return Err(413)
    }
  }
  Ok(length.to_int())
}

///|
/// The elements of the comma-separated list in the field value `value`
/// (RFC 9110, section 5.6.1), without the white space around each. Empty
/// elements are among them; the caller decides whether to allow them.
fn list_elements(value : Bytes) -> Iter[StringView] {
  @utf8.decode_lossy(value)
  .split(",")
  .map(element => element.trim(char_set=" \t"))
}

///|
/// Reads `method SP request-target SP HTTP-version` from the line
/// `buf[start:end]`, which the head scan has checked. A version whose major
/// number is not 1 gets 505; a later minor version than 1 is read as
/// HTTP/1.1 (RFC 9110, section 2.5). A target in none of the forms of a
/// request target, or in a form its method does not take, gets 400.
fn parse_request_line(
  buf : FixedArray[Byte],
  start : Int32,
  end : Int32,
  previous : Head?,
) -> Result[(String, String, Version), Int32] {
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
  let (meth, target) = match previous {
    Some(previous) =>
      (
        ascii_reusing(buf, start, space, previous.meth),
        ascii_reusing(buf, space + 1, end - 9, previous.target),
      )
    None => (ascii(buf, start, space), ascii(buf, space + 1, end - 9))
  }
  if !is_request_target(target, meth~) {
    return Err(400)
  }
  Ok((meth, target, version))
}

///|
fn is_digit(c : Byte) -> Bool {
  c >= b'0' && c <= b'9'
}

///|
/// Reads `field-name ":" OWS field-value OWS` from the line
/// `buf[start:end]`, which the head scan has checked. It is `previous`, or
/// has its name, when that is the same.
fn parse_field(
  buf : FixedArray[Byte],
  start : Int32,
  end : Int32,
  previous : Header?,
) -> Header {
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
  let value = buf.unsafe_reinterpret_as_bytes()[value_start:value_end]
  match previous {
    Some(previous) => {
      let name = ascii_reusing(buf, start, colon, previous.name)
      if physical_equal(name, previous.name) && value == previous.value[:] {
        previous
      } else {
        { name, value: value.to_owned(), }
      }
    }
    None => { name: ascii(buf, start, colon), value: value.to_owned(), }
  }
}

///|
/// Whether `c` may appear in a token, such as a method or a field name.
fn is_tchar(c : Byte) -> Bool {
  tchars[c.to_int()]
}

///|
/// Whether each byte may appear in a token: ASCII letters, digits and
/// ``!#$%&'*+-.^_`|~``, looked up since the head scan asks for every byte of
/// every method and field name.
let tchars : FixedArray[Bool] = {
  let table = FixedArray::make(256, false)
  for
    c in b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" {
    table[c.to_int()] = true
  }
  table
}

///|
fn is_ows(c : Byte) -> Bool {
  c == b' ' || c == b'\t'
}

///|
/// `buf[start:end]`, which holds only ASCII, as a string. ASCII is UTF-8, so
/// it is decoded as UTF-8, all at once.
fn ascii(buf : FixedArray[Byte], start : Int32, end : Int32) -> String {
  @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[start:end])
}

///|
/// `buf[start:end]`, which holds only ASCII, as a string: `same` itself when
/// it is that text, so that text sent again shares one string.
fn ascii_reusing(
  buf : FixedArray[Byte],
  start : Int32,
  end : Int32,
  same : String,
) -> String {
  if same.length() == end - start {
    let mut i = 0
    while i < end - start && same[i].to_int() == buf[start + i].to_int() {
      i += 1
    }
    if i == end - start {
      return same
    }
  }
  ascii(buf, start, end)
}

///|
/// Whether the field name `name` is `lower`, which is in lower case, in any
/// case. Field names are ASCII.
fn is_name(name : String, lower : String) -> Bool {
  if name.length() != lower.length() {
    return false
  }
  for i in 0..<name.length() {
    let c = name[i]
    let c = if c >= 'A' && c <= 'Z' { c + 0x20 } else { c }
    if c != lower[i] {
      return false
    }
  }
  true
}
