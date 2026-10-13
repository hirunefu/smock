// The request parser as it was before its head scan and head parsing were
// made allocation-free, kept as the oracle for the parser of today: for any
// bytes, fed in any pieces, with any limits, both must take out the same
// requests and end the same way. Only the scan of the head and the reading
// of its lines are copied here; the framing helpers they share are not.

///|
/// The parser before the allocation-free head scan.
priv struct RefParser {
  mut buf : FixedArray[Byte]
  mut start : Int
  mut end : Int
  mut scanned : Int
  mut scan : RefHeadScan
  mut fields : Int
  mut head : RefHead?
  chunks : Chunks
  mut invalid : Int?
  header_size_limit : Int
  header_count_limit : Int
  body_limit : Int
}

///|
fn RefParser::new(
  header_size_limit~ : Int,
  header_count_limit~ : Int,
  body_limit~ : Int,
) -> RefParser {
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
    scan: Method(0),
    fields: 0,
    head: None,
    chunks: Chunks(limit=body_limit),
    invalid: None,
    header_size_limit,
    header_count_limit,
    body_limit,
  }
}

///|
fn RefParser::feed(self : RefParser, data : BytesView) -> Unit {
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
fn RefParser::in_request(self : RefParser) -> Bool {
  self.head is Some(_) || self.end > self.start
}

///|
fn RefParser::next(self : RefParser) -> Parsed {
  if self.invalid is Some(status) {
    return Invalid(status~)
  }
  let head = match self.head {
    Some(head) => head
    None => {
      let head_end = match self.scan_head() {
        RefEnded(head_end) => head_end
        RefPartial => return NeedMore
        RefRejected(status) => {
          self.invalid = Some(status)
          return Invalid(status~)
        }
      }
      match ref_parse_head(self.buf, self.start, head_end, self.body_limit) {
        Ok(head) => {
          self.head = Some(head)
          self.start = head_end
          self.scanned = 0
          self.scan = Method(0)
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
    RefLength(length) => {
      let body_end = self.start + length
      if self.end < body_end {
        return NeedMore
      }
      (
        self.buf.unsafe_reinterpret_as_bytes()[self.start:body_end].to_owned(),
        length,
      )
    }
    RefChunked =>
      match self.chunks.decode(self.buf, self.start, self.end) {
        Ok(Some(length)) => (self.chunks.take_body(), length)
        Ok(None) => {
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
priv struct RefHead {
  meth : String
  target : String
  version : Version
  headers : Array[Header]
  keep_alive : Bool
  framing : RefFraming
  expects_continue : Bool
}

///|
priv enum RefFraming {
  RefLength(Int)
  RefChunked
}

///|
priv enum RefHeadEnd {
  RefEnded(Int)
  RefPartial
  RefRejected(Int)
}

///|
fn RefParser::scan_head(self : RefParser) -> RefHeadEnd {
  while self.start + self.scanned < self.end {
    let before = self.scan
    self.scan = before.after(self.buf[self.start + self.scanned])
    self.scanned += 1
    if (before, self.scan) is (Fields(FieldStart), Fields(FieldName)) {
      self.fields += 1
    }
    match self.scan {
      Broken => return RefRejected(400)
      _ if self.scanned > self.header_size_limit ||
        self.fields > self.header_count_limit => return RefRejected(431)
      Fields(Ended) => return RefEnded(self.start + self.scanned)
      EmptyLine => {
        self.start += self.scanned
        self.scanned = 0
        self.scan = Method(0)
      }
      _ => ()
    }
  }
  RefPartial
}

///|
priv enum RefHeadScan {
  EmptyLineLf
  EmptyLine
  Method(Int)
  Target(Int)
  Version(Int)
  VersionLf
  Fields(RefSection)
  Broken
}

///|
fn RefHeadScan::after(self : RefHeadScan, c : Byte) -> RefHeadScan {
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
        5 | 7 => c >= b'0' && c <= b'9'
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
priv enum RefSection {
  FieldStart
  FieldName
  FieldValue
  FieldLf
  EndLf
  Ended
  Broken
}

///|
fn RefSection::after(self : RefSection, c : Byte) -> RefSection {
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
      } else if c == b'\t' || (c >= b' ' && c != b'\x7f') {
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
fn ref_parse_head(
  buf : FixedArray[Byte],
  start : Int,
  end : Int,
  body_limit : Int,
) -> Result[RefHead, Int] {
  let lines = ref_split_lines(buf, start, end)
  let (meth, target, version) = match ref_parse_request_line(buf, lines[0]) {
    Ok(line) => line
    Err(status) => return Err(status)
  }
  let headers = []
  let content_lengths = []
  let mut close = false
  let mut keep_alive = false
  let mut expect_continue = false
  let mut hosts = 0
  let transfer_encodings = []
  for line in lines[1:] {
    let header = ref_parse_field(buf, line)
    headers.push(header)
    let name = header.name.to_lower()
    if name == "host" {
      if !is_host_value(@utf8.decode_lossy(header.value)) {
        return Err(400)
      }
      hosts += 1
    } else if name == "transfer-encoding" {
      transfer_encodings.push(header.value)
    } else if name == "content-length" {
      content_lengths.push(header.value)
    } else if name == "connection" {
      for token in ref_list_elements(header.value) {
        match token.to_lower() {
          "close" => close = true
          "keep-alive" => keep_alive = true
          _ => ()
        }
      }
    } else if name == "expect" {
      for expectation in ref_list_elements(header.value) {
        if expectation.to_lower() == "100-continue" {
          expect_continue = true
        }
      }
    }
  }
  if hosts > 1 || (version is Http11 && hosts != 1) {
    return Err(400)
  }
  let framing = if transfer_encodings.is_empty() {
    match content_length(content_lengths, body_limit) {
      Ok(length) => RefLength(length)
      Err(status) => return Err(status)
    }
  } else {
    if !content_lengths.is_empty() {
      return Err(400)
    }
    if version is Http10 {
      return Err(400)
    }
    match check_transfer_codings(transfer_encodings) {
      Ok(_) => RefChunked
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
    expects_continue: expect_continue &&
    version is Http11 &&
    !(framing is RefLength(0)),
  })
}

///|
fn ref_list_elements(value : Bytes) -> Iter[StringView] {
  @utf8.decode_lossy(value)
  .split(",")
  .map(element => element.trim(char_set=" \t"))
}

///|
fn ref_split_lines(
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
fn ref_parse_request_line(
  buf : FixedArray[Byte],
  line : (Int, Int),
) -> Result[(String, String, Version), Int] {
  let (start, end) = line
  let mut space = start
  while buf[space] != b' ' {
    space += 1
  }
  let version = match (buf[end - 3], buf[end - 1]) {
    (b'1', b'0') => Http10
    (b'1', _) => Http11
    _ => return Err(505)
  }
  let meth = ref_ascii(buf, start, space)
  let target = ref_ascii(buf, space + 1, end - 9)
  if !is_request_target(target, meth~) {
    return Err(400)
  }
  Ok((meth, target, version))
}

///|
fn ref_parse_field(buf : FixedArray[Byte], line : (Int, Int)) -> Header {
  let (start, end) = line
  let mut colon = start
  while buf[colon] != b':' {
    colon += 1
  }
  let mut value_start = colon + 1
  while value_start < end && buf[value_start] is (b' ' | b'\t') {
    value_start += 1
  }
  let mut value_end = end
  while value_end > value_start && buf[value_end - 1] is (b' ' | b'\t') {
    value_end -= 1
  }
  {
    name: ref_ascii(buf, start, colon),
    value: buf.unsafe_reinterpret_as_bytes()[value_start:value_end].to_owned(),
  }
}

///|
fn ref_ascii(buf : FixedArray[Byte], start : Int, end : Int) -> String {
  let out = StringBuilder()
  for i in start..<end {
    out.write_char(buf[i].to_char())
  }
  out.to_string()
}

///|
/// A parse result as text, every field of a request included.
fn ref_render(parsed : Parsed) -> String {
  match parsed {
    Continue => "continue"
    NeedMore => "need more"
    Invalid(status~) => "invalid \{status}"
    Complete(req) => {
      let out = StringBuilder()
      out.write_string("\{req.meth.escape()} \{req.target.escape()} ")
      out.write_string(if req.version is Http10 { "1.0" } else { "1.1" })
      for header in req.headers {
        out.write_string(" | \{header.name.escape()}: \{header.value}")
      }
      out.write_string(" | body=\{req.body}")
      out.write_string(
        if req.keep_alive {
          " | keep-alive"
        } else {
          " | close"
        },
      )
      out.to_string()
    }
  }
}

///|
/// Request lines in every form and version, valid and not.
let ref_request_lines : Array[String] = [
  "GET / HTTP/1.1\r\n", "POST /orders?x=1&y=%20 HTTP/1.1\r\n", "HEAD /a HTTP/1.0\r\n",
  "OPTIONS * HTTP/1.1\r\n", "CONNECT a.example:443 HTTP/1.1\r\n", "GET http://a.example:8080/p HTTP/1.1\r\n",
  "GET /x HTTP/2.0\r\n", "GET /x HTTP/1.9\r\n", "GET /x#f HTTP/1.1\r\n", "PATCH /x HTTP/1.1\r\n",
  "GET * HTTP/1.1\r\n", "M /catalog/items/SKU-00317 HTTP/1.0\r\n",
]

///|
/// Header fields that steer framing and the connection, in any case, with
/// obs-text, whitespace and empty values.
let ref_fields : Array[String] = [
  "Host: a.example\r\n", "host:a.example:8080\r\n", "HOST: [::1]:80\r\n", "Host: bad host\r\n",
  "Host:\r\n", "Content-Length: 3\r\n", "content-length: 3, 3\r\n", "Content-Length: 4\r\n",
  "CONTENT-LENGTH: 007\r\n", "Content-Length: x\r\n", "Content-Length: 99999999999999\r\n",
  "Transfer-Encoding: chunked\r\n", "transfer-encoding: gzip, chunked\r\n", "Transfer-Encoding: Chunked\r\n",
  "Connection: close\r\n", "connection: Keep-Alive, Upgrade\r\n", "Connection: keep-alive\r\n",
  "Expect: 100-continue\r\n", "expect: 100-Continue , x\r\n", "X-Empty:\r\n", "X-Tab:\t v \t\r\n",
  "X-Obs: caf\u{e9}\r\n", "Accept: */*\r\n", "authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIi\r\n",
  "baggage: tenant=acme-eu,smock-session=s1,deployment=perf\r\n",
]

///|
/// Bodies, framed and not, and stray bytes.
let ref_bodies : Array[String] = [
  "", "", "abc", "abcd", "5\r\nhello\r\n0\r\n\r\n", "0\r\nTrailer: x\r\n\r\n", "\r\n",
  " ", ":", "\t", "\r", "\n", "x y",
]

///|
/// A random stream of bytes shaped like requests, with a few random bytes
/// changed, inserted or removed.
fn ref_stream(rand : @random.Rand) -> Bytes {
  let pick = (items : Array[String]) => items[rand.int(limit=items.length())]
  let out = @buffer.Buffer()
  if rand.int(limit=4) == 0 {
    out.write_string_utf8("\r\n")
  }
  for _ in 0..<(1 + rand.int(limit=3)) {
    if rand.int(limit=4) == 0 {
      // Loose pieces of heads, in any order.
      for _ in 0..<(1 + rand.int(limit=8)) {
        let items = match rand.int(limit=3) {
          0 => ref_request_lines
          1 => ref_fields
          _ => ref_bodies
        }
        out.write_string_utf8(pick(items))
      }
    } else {
      out.write_string_utf8(pick(ref_request_lines))
      if rand.int(limit=5) != 0 {
        out.write_string_utf8("Host: a.example\r\n")
      }
      for _ in 0..<rand.int(limit=6) {
        out.write_string_utf8(pick(ref_fields))
      }
      out.write_string_utf8("\r\n")
      out.write_string_utf8(pick(ref_bodies))
    }
  }
  let bytes = out.to_bytes().to_array()
  let interesting = b" \r\n:\t\x7f\x80\xffH/1.0aZ,;=%"
  for _ in 0..<rand.int(limit=4) {
    if bytes.is_empty() {
      break
    }
    let at = rand.int(limit=bytes.length())
    let byte = if rand.int(limit=4) == 0 {
      rand.int(limit=256).to_byte()
    } else {
      interesting[rand.int(limit=interesting.length())]
    }
    match rand.int(limit=3) {
      0 => bytes[at] = byte
      1 => bytes.insert(at, byte)
      _ => bytes.remove(at) |> ignore
    }
  }
  Bytes::from_array(bytes)
}

///|
/// What a parser makes of `pieces`: after each piece, every result `next`
/// gives until it needs more bytes or stops, and whether a request is in
/// progress then.
fn[P] ref_outcome(
  parser : P,
  pieces : Array[BytesView],
  feed : (P, BytesView) -> Unit,
  next : (P) -> Parsed,
  in_request : (P) -> Bool,
) -> Array[String] {
  let out = []
  for piece in pieces {
    feed(parser, piece)
    for ;; {
      let parsed = next(parser)
      out.push(ref_render(parsed))
      match parsed {
        Complete(_) | Continue => continue
        NeedMore => {
          out.push("in request: \{in_request(parser)}")
          break
        }
        Invalid(_) => break
      }
    }
  }
  out
}

///|
test "the parser takes out what the parser before the allocation-free head scan took out, for any bytes, pieces and limits" {
  let rand = @random.Rand::chacha8(seed=b"smock http1 head scan reference!")
  let size_limits = [0, 1, 2, 3, 10, 17, 30, 45, 60, 90, 150, 16 * 1024]
  let count_limits = [0, 1, 2, 3, 5, 100]
  let body_limits = [0, 3, 4, 5, 10 * 1024 * 1024]
  let differ = []
  let seen : Map[String, Bool] = Map([])
  for _ in 0..<20000 {
    let stream = ref_stream(rand)
    let header_size_limit = size_limits[rand.int(limit=size_limits.length())]
    let header_count_limit = count_limits[rand.int(limit=count_limits.length())]
    let body_limit = body_limits[rand.int(limit=body_limits.length())]
    let pieces = []
    let mut offset = 0
    let longest = 1 + rand.int(limit=40)
    while offset < stream.length() {
      let end = offset + 1 + rand.int(limit=longest)
      let end = if end < stream.length() { end } else { stream.length() }
      pieces.push(stream[offset:end])
      offset = end
    }
    let expected = ref_outcome(
      RefParser::new(header_size_limit~, header_count_limit~, body_limit~),
      pieces,
      (p, d) => p.feed(d),
      p => p.next(),
      p => p.in_request(),
    )
    let actual = ref_outcome(
      Parser(header_size_limit~, header_count_limit~, body_limit~),
      pieces,
      (p, d) => p.feed(d),
      p => p.next(),
      p => p.in_request(),
    )
    for line in expected {
      let kind = match line {
        "need more" | "continue" => line
        _ if line.has_prefix("invalid") || line.has_prefix("in request") => line
        _ => "complete"
      }
      seen[kind] = true
    }
    if actual != expected && differ.length() < 3 {
      differ.push(
        (stream, header_size_limit, header_count_limit, expected, actual),
      )
    }
  }
  debug_inspect(differ, content="[]")
  // The streams reach every outcome of the parser.
  let seen = seen.keys().collect()
  seen.sort_by((a, b) => a.lexical_compare(b))
  debug_inspect(
    seen,
    content=(
      #|[
      #|  "complete",
      #|  "continue",
      #|  "in request: false",
      #|  "in request: true",
      #|  "invalid 400",
      #|  "invalid 413",
      #|  "invalid 431",
      #|  "invalid 501",
      #|  "invalid 505",
      #|  "need more",
      #|]
    ),
  )
}
