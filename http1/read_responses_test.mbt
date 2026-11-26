// A property of the response encoder and the response stream against a
// reader of responses: what they write, read as RFC 9112 defines a
// response, gives the status, the fields and the body they were given, and
// ends where the message ends. The reader is this file's, written from RFC
// 9112 and RFC 9110, not from the encoder.

///|
/// The seed of the property that responses read as RFC 9112 defines them
/// give the status, fields and body they were written with. The tests run
/// with it on every push, in mutation runs and in kill confirmations, so a
/// failure reproduces. Each week, `scripts/random-seeds.py` writes a random
/// seed here in a working copy and prints it (CONTRIBUTING.md, "Seeds").
const RESPONSE_SEED : UInt64 = 14307300340560152372

///|
/// A response as the reader reads it: the HTTP-version of its status line,
/// its status code, its field lines (name, and value without the OWS
/// around it), its body, whether the connection persists after it, and
/// how many bytes follow the message.
priv struct Reading {
  version : Bytes
  status : Int32
  fields : Array[(Bytes, Bytes)]
  body : Bytes
  persists : Bool
  rest : Int32
}

///|
/// Whether `c` is a tchar (RFC 9110, section 5.6.2).
fn reader_tchar(c : Byte) -> Bool {
  c
  is (b'0'..<=b'9'
  | b'a'..<=b'z'
  | b'A'..<=b'Z'
  | b'!'
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
/// Whether `c` may be in a field value (RFC 9110, section 5.5): a
/// field-vchar (VCHAR or obs-text), a space or a tab.
fn reader_field_byte(c : Byte) -> Bool {
  c == b' ' || c == b'\t' || (c >= b'\x21' && c != b'\x7f')
}

///|
/// The value of a hexadecimal digit (RFC 5234, appendix B.1: HEXDIG, in
/// either case).
fn reader_hex(c : Byte) -> Int32? {
  match c {
    b'0'..<=b'9' => Some(c.to_int() - 0x30)
    b'a'..<=b'f' => Some(c.to_int() - 0x61 + 10)
    b'A'..<=b'F' => Some(c.to_int() - 0x41 + 10)
    _ => None
  }
}

///|
/// The line that starts at `at`, without its CRLF, and where the next line
/// starts.
fn reader_line(bytes : Bytes, at : Int32) -> (BytesView, Int32)? {
  guard bytes[at:].find(b"\r\n") is Some(length) else { return None }
  Some((bytes[at:at + length], at + length + 2))
}

///|
/// Reads field lines from `at` up to the empty line that ends them (RFC
/// 9112, section 5): `field-name ":" OWS field-value OWS`, with no white
/// space before the colon. Returns the fields and where the bytes after
/// the empty line start.
fn reader_fields(
  bytes : Bytes,
  at : Int32,
) -> Result[(Array[(Bytes, Bytes)], Int32), String] {
  let fields = []
  let mut at = at
  while true {
    guard reader_line(bytes, at) is Some((line, next)) else {
      return Err("a field section that does not end")
    }
    at = next
    if line.is_empty() {
      break
    }
    guard line.find(b":") is Some(colon) &&
      colon > 0 &&
      line[:colon].iter().all(reader_tchar) else {
      return Err("a field line without a token and a colon")
    }
    let mut first = colon + 1
    let mut last = line.length()
    while first < last && line[first] is (b' ' | b'\t') {
      first += 1
    }
    while last > first && line[last - 1] is (b' ' | b'\t') {
      last -= 1
    }
    guard line[first:last].iter().all(reader_field_byte) else {
      return Err("a field value with a byte no field value holds")
    }
    fields.push((line[:colon].to_owned(), line[first:last].to_owned()))
  }
  Ok((fields, at))
}

///|
/// The elements of the lists in the values of the fields named `name`, in
/// lower case and without the white space around each (RFC 9110, section
/// 5.6.1; field names and the tokens read here ignore case).
fn reader_list(fields : Array[(Bytes, Bytes)], name : String) -> Array[String] {
  let out = []
  for field in fields {
    if @utf8.decode_lossy(field.0).to_lower() == name {
      for element in @utf8.decode_lossy(field.1).split(",") {
        out.push(element.trim(char_set=" \t").to_owned().to_lower())
      }
    }
  }
  out
}

///|
/// Where the BWS that starts at `at` in `line` ends: spaces and tabs (RFC
/// 9110, section 5.6.3, where BWS is OWS).
fn reader_bws(line : BytesView, at : Int32) -> Int32 {
  let mut at = at
  while at < line.length() && line[at] is (b' ' | b'\t') {
    at += 1
  }
  at
}

///|
/// Where the token that starts at `at` in `line` ends, or `at` when none
/// starts there (RFC 9110, section 5.6.2: `token = 1*tchar`).
fn reader_token_end(line : BytesView, at : Int32) -> Int32 {
  let mut at = at
  while at < line.length() && reader_tchar(line[at]) {
    at += 1
  }
  at
}

///|
/// Where the quoted-string that starts at `at` in `line` ends, after its
/// closing DQUOTE, or `None` when none starts there (RFC 9110, section
/// 5.6.4): `DQUOTE *( qdtext / quoted-pair ) DQUOTE`, where qdtext is HTAB,
/// SP, VCHAR but `"` and `\`, or obs-text, and a quoted-pair is `\` before
/// HTAB, SP, VCHAR or obs-text.
fn reader_quoted_end(line : BytesView, at : Int32) -> Int32? {
  guard at < line.length() && line[at] == b'"' else { return None }
  let mut at = at + 1
  while at < line.length() {
    match line[at] {
      b'"' => return Some(at + 1)
      b'\\' => {
        guard at + 1 < line.length() && reader_field_byte(line[at + 1]) else {
          return None
        }
        at += 2
      }
      c => {
        guard reader_field_byte(c) else { return None }
        at += 1
      }
    }
  }
  None
}

///|
/// Reads a chunk's first line, without its CRLF (RFC 9112, section 7.1):
/// `chunk-size [ chunk-ext ]`, where chunk-size is `1*HEXDIG`, and a
/// last-chunk's, `1*("0") [ chunk-ext ]`, which is a size of 0. chunk-ext
/// is `*( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )`, its
/// name a token and its value a token or a quoted-string (section 7.1.1).
/// Returns the size, at most `most`, the octets left in the message; a line
/// that holds anything else is no chunk's.
fn reader_chunk_line(line : BytesView, most : Int32) -> Result[Int32, String] {
  let mut size = 0
  let mut at = 0
  while at < line.length() && reader_hex(line[at]) is Some(digit) {
    size = size * 16 + digit
    guard size <= most else {
      return Err("a chunk size past the end of the message")
    }
    at += 1
  }
  guard at > 0 else { return Err("a chunk size without a digit") }
  while at < line.length() {
    at = reader_bws(line, at)
    guard at < line.length() && line[at] == b';' else {
      return Err("a chunk size followed by bytes of no chunk extension")
    }
    let name = reader_bws(line, at + 1)
    at = reader_token_end(line, name)
    guard at > name else { return Err("a chunk extension without a name") }
    let equals = reader_bws(line, at)
    if equals < line.length() && line[equals] == b'=' {
      let value = reader_bws(line, equals + 1)
      at = reader_token_end(line, value)
      if at == value {
        guard reader_quoted_end(line, value) is Some(end) else {
          return Err(
            "a chunk extension's value that is no token or quoted-string",
          )
        }
        at = end
      }
    }
  }
  Ok(size)
}

///|
/// Reads a chunked body from `at` (RFC 9112, section 7.1): chunks of a
/// hexadecimal size, chunk extensions, which it reads by their grammar and
/// ignores, and data, then the last chunk and the trailer section. Returns
/// the data and where the bytes after the body start.
fn reader_chunked(bytes : Bytes, at : Int32) -> Result[(Bytes, Int32), String] {
  let out = @buffer.Buffer()
  let mut at = at
  while true {
    guard reader_line(bytes, at) is Some((line, next)) else {
      return Err("a chunk size line that does not end")
    }
    let size = match reader_chunk_line(line, bytes.length() - next) {
      Ok(size) => size
      Err(error) => return Err(error)
    }
    at = next
    if size == 0 {
      // The trailer section, whose fields are not the body's.
      match reader_fields(bytes, at) {
        Ok((_, after)) => return Ok((out.to_bytes(), after))
        Err(error) => return Err("in the trailer section: \{error}")
      }
    }
    guard at + size + 2 <= bytes.length() &&
      bytes[at + size] == b'\r' &&
      bytes[at + size + 1] == b'\n' else {
      return Err("chunk data that is not as long as its size")
    }
    out.write_bytes(bytes[at:at + size])
    at += size + 2
  }
  Err("unreachable")
}

///|
/// Reads `bytes` as one response to a request that was HEAD when `to_head`
/// (RFC 9112): the status line `HTTP-version SP status-code SP [
/// reason-phrase ]` (section 4), the field lines (section 5), and a body
/// whose length is decided as section 6.3 says for a response: none after
/// HEAD or with a status 1xx, 204 or 304; chunked when chunked is the last
/// transfer coding; read until the connection closes for another coding;
/// as long as the Content-Length; otherwise until the connection closes.
/// The connection persists unless the "close" option is present (section
/// 9.3, for a response of HTTP/1.1) or the body runs until it closes.
fn read_response(bytes : Bytes, to_head~ : Bool) -> Result[Reading, String] {
  guard reader_line(bytes, 0) is Some((line, at)) else {
    return Err("no status line")
  }
  guard line.length() >= 13 &&
    line[:5] == b"HTTP/" &&
    line[5] is (b'0'..<=b'9') &&
    line[6] == b'.' &&
    line[7] is (b'0'..<=b'9') &&
    line[8] == b' ' &&
    line[9:12].iter().all(c => c is (b'0'..<=b'9')) &&
    line[12] == b' ' &&
    line[13:].iter().all(c => c == b'\t' || reader_field_byte(c)) else {
    return Err("a status line that is not one")
  }
  let status = line[9:12]
    .iter()
    .fold(init=0, (n, c) => n * 10 + c.to_int() - 0x30)
  let (fields, at) = match reader_fields(bytes, at) {
    Ok(read) => read
    Err(error) => return Err(error)
  }
  let codings = reader_list(fields, "transfer-encoding")
  let lengths = reader_list(fields, "content-length")
  let (body, end, until_close) = if to_head ||
    status is (100..<=199 | 204 | 304) {
    (b"", at, false)
  } else if !codings.is_empty() {
    if codings[codings.length() - 1] == "chunked" {
      match reader_chunked(bytes, at) {
        Ok((body, end)) => (body, end, false)
        Err(error) => return Err(error)
      }
    } else {
      (bytes[at:].to_owned(), bytes.length(), true)
    }
  } else if !lengths.is_empty() {
    guard lengths.iter().all(length => length == lengths[0]) &&
      lengths[0].length() is (1..<=9) &&
      lengths[0].iter().all(c => c is ('0'..<='9')) else {
      return Err("a Content-Length that is not one length")
    }
    let length = lengths[0]
      .iter()
      .fold(init=0, (n, c) => n * 10 + c.to_int() - 0x30)
    guard at + length <= bytes.length() else {
      return Err("a body shorter than its Content-Length")
    }
    (bytes[at:at + length].to_owned(), at + length, false)
  } else {
    (bytes[at:].to_owned(), bytes.length(), true)
  }
  Ok({
    version: line[:8].to_owned(),
    status,
    fields,
    body,
    persists: !reader_list(fields, "connection").contains("close") &&
    !until_close,
    rest: bytes.length() - end,
  })
}

///|
/// The request a response answers, as far as the encoder looks at it.
priv struct Answered {
  meth : String
  version : @http1.Version
  keep_alive : Bool
}

///|
/// A response to write: its status, its header fields (each a token and a
/// field value), its body in parts, the request it answers, `close` and the
/// Date field's value, written by `encode_response` (the parts joined) or,
/// when `streamed`, by a `ResponseStream`.
priv struct Response {
  status : Int32
  headers : Array[(String, String)]
  parts : Array[Bytes]
  request : Answered?
  close : Bool
  date : String?
  streamed : Bool
}

///|
/// The request, as the parser would have given it.
fn Answered::parsed(self : Answered) -> @http1.Request {
  {
    meth: self.meth,
    target: "/",
    version: self.version,
    headers: [],
    body: b"",
    keep_alive: self.keep_alive,
  }
}

///|
/// The request the response answers, as the parser would have given it.
fn Response::parsed(self : Response) -> @http1.Request? {
  self.request.map(Answered::parsed)
}

///|
/// The body given: the parts, one after another.
fn Response::body(self : Response) -> Bytes {
  let out = @buffer.Buffer()
  for part in self.parts {
    out.write_bytes(part)
  }
  out.to_bytes()
}

///|
/// What the encoder or the stream writes, and whether it says the
/// connection stays open.
fn Response::written(self : Response) -> (Bytes, Bool) {
  let request = self.parsed()
  if self.streamed {
    let stream = @http1.ResponseStream(
      self.status,
      self.headers,
      request?,
      close=self.close,
      date?=self.date,
    )
    let out = @buffer.Buffer()
    out.write_bytes(stream.head())
    for part in self.parts {
      out.write_bytes(stream.part(part))
    }
    out.write_bytes(stream.end())
    (out.to_bytes(), stream.keeps_open())
  } else {
    let bytes = @http1.encode_response(
      self.status,
      self.headers,
      self.body(),
      request?,
      close=self.close,
      date?=self.date,
    )
    (bytes, @http1.keeps_open(request?, close=self.close))
  }
}

///|
/// Whether the response has content: not with a status 1xx, 204 or 304
/// (RFC 9110, sections 15.2, 15.3.5 and 15.4.5).
fn Response::content(self : Response) -> Bool {
  !(self.status is (100..<=199 | 204 | 304))
}

///|
/// Whether the request is HTTP/1.0.
fn Response::to_http10(self : Response) -> Bool {
  self.request is Some({ version: Http10, .. })
}

///|
/// Whether the connection stays open after the response, as
/// `encode_response` and `ResponseStream` document it: unless `close` is
/// true or the request does not keep it open; and never after a streamed
/// response with content to HTTP/1.0, whose body ends when the connection
/// closes.
///
/// Two cases of a streamed response rest on sentences of `ResponseStream`'s
/// doc comment, which the maintainer confirmed on 2026-11-26 (#324). To no
/// parsed request, it stays open unless `close` is true: "A ResponseStream
/// made with no request is written as to an HTTP/1.1 request other than
/// HEAD that keeps the connection open". With status 1xx, 204 or 304 to an
/// HTTP/1.0 request that keeps the connection open, it stays open unless
/// `close` is true: "Even to an HTTP/1.0 request, when that request keeps
/// the connection open, such a response says `Connection: keep-alive` and
/// keeps it open unless `close` is true".
fn Response::keeps(self : Response) -> Bool {
  !self.close &&
  !(self.request is Some({ keep_alive: false, .. })) &&
  !(self.streamed && self.content() && self.to_http10())
}

///|
/// The fields the encoder adds after the given ones, as `encode_response`
/// and `ResponseStream` document them, sorted: a Date field with the date
/// given unless the headers give one by a name in any case; `Connection:
/// close` when the connection does not stay open, and `Connection:
/// keep-alive` when it stays open after an HTTP/1.0 request; with content,
/// the Content-Length of the body (even to HEAD) or, streamed to HTTP/1.1
/// or to no parsed request, `Transfer-Encoding: chunked`.
///
/// Streamed, two of these rest on sentences of `ResponseStream`'s doc
/// comment (#324, confirmed on 2026-11-26): to no parsed request,
/// `Transfer-Encoding: chunked` with content, and no Connection field while
/// the connection stays open ("A ResponseStream made with no request is
/// written as to an HTTP/1.1 request other than HEAD that keeps the
/// connection open"); with status 1xx, 204 or 304 to an HTTP/1.0 request
/// that keeps the connection open, `Connection: keep-alive` unless `close`
/// is true ("Even to an HTTP/1.0 request, when that request keeps the
/// connection open, such a response says `Connection: keep-alive` and keeps
/// it open unless `close` is true").
fn Response::added(self : Response) -> Array[(Bytes, Bytes)] {
  let out = []
  if self.date is Some(date) &&
    !self.headers.iter().any(header => header.0.to_lower() == "date") {
    out.push((b"Date", @utf8.encode(date)))
  }
  if !self.keeps() {
    out.push((b"Connection", b"close"))
  } else if self.to_http10() {
    out.push((b"Connection", b"keep-alive"))
  }
  if self.content() {
    if !self.streamed {
      out.push(
        (b"Content-Length", @utf8.encode(self.body().length().to_string())),
      )
    } else if !self.to_http10() {
      out.push((b"Transfer-Encoding", b"chunked"))
    }
  }
  out.sort()
  out
}

///|
/// The body a client gets: none after HEAD or without content, else the
/// parts.
fn Response::carried(self : Response) -> Bytes {
  if self.content() && !(self.request is Some({ meth: "HEAD", .. })) {
    self.body()
  } else {
    b""
  }
}

///|
/// What the reader made of the response, and what the encoder said of the
/// connection.
fn Response::read(self : Response) -> (Result[Reading, String], Bool) {
  let (bytes, keeps_open) = self.written()
  let to_head = self.request is Some({ meth: "HEAD", .. })
  (read_response(bytes, to_head~), keeps_open)
}

///|
/// The property, by the documentation of `encode_response` and
/// `ResponseStream` read through RFC 9112: the response reads as HTTP/1.1
/// with the status given; its fields are the headers given, in order, each
/// name and value as UTF-8, then the fields the encoder adds; its body is
/// the one a client gets, and nothing follows the message; and the
/// connection persists exactly when the encoder says it stays open.
fn Response::holds(self : Response) -> Bool {
  let (reading, keeps_open) = self.read()
  guard reading is Ok(reading) else { return false }
  let given = self.headers.map(header => {
    (@utf8.encode(header.0), @utf8.encode(header.1))
  })
  let n = given.length()
  guard reading.fields.length() >= n else { return false }
  let added = reading.fields[n:].iter().collect()
  added.sort()
  reading.version == b"HTTP/1.1" &&
  reading.status == self.status &&
  reading.fields[:n] == given[:] &&
  added == self.added() &&
  reading.body == self.carried() &&
  reading.rest == 0 &&
  keeps_open == self.keeps() &&
  reading.persists == keeps_open
}

///|
/// What the reader made of a failing response: the bytes written, the
/// reading, and what the encoder said of the connection.
fn Response::describe(self : Response) -> String {
  let (bytes, _) = self.written()
  let (reading, keeps_open) = self.read()
  let reading = match reading {
    Err(error) => "not read: \{error}"
    Ok(reading) => {
      let fields = reading.fields.map(field => {
        "\{literal(field.0)}: \{literal(field.1)}"
      })
      "status \{reading.status}, fields [\{fields.join(", ")}], body \{literal(reading.body)}, persists \{reading.persists}, \{reading.rest} bytes after it"
    }
  }
  let added = self
    .added()
    .map(field => "\{literal(field.0)}: \{literal(field.1)}")
  "written \{literal(bytes)}\nread: \{reading}\nkeeps_open \{keeps_open}, expected \{self.keeps()}; fields added expected [\{added.join(", ")}], body expected \{literal(self.carried())}"
}

///|
/// A response as a failure shows it.
impl @debug.Debug for Response with fn to_repr(self) {
  let request = match self.request {
    None => "no request"
    Some(request) => {
      let version = match request.version {
        Http10 => "HTTP/1.0"
        Http11 => "HTTP/1.1"
      }
      "\{request.meth} \{version}, keep_alive \{request.keep_alive}"
    }
  }
  let parts = self.parts.map(part => literal(part)).join(", ")
  let kind = if self.streamed { "streamed" } else { "encode_response" }
  @debug.Repr::literal(
    "\{kind} \{self.status} \{@debug.to_string(self.headers)} [\{parts}] to \{request}, close \{self.close}, date \{@debug.to_string(self.date)}",
  )
}

///|
/// A character of a field value beyond ASCII, written as UTF-8: of two,
/// three or four octets, around the edges between them.
fn beyond_ascii(state : @quickcheck.RandomState) -> Char {
  let code = match pick(state, 4) {
    0 => 0x80 + pick(state, 0x800 - 0x80)
    1 => 0x800 + pick(state, 0xD800 - 0x800)
    2 => 0xE000 + pick(state, 0x10000 - 0xE000)
    _ => 0x10000 + pick(state, 0x110000 - 0x10000)
  }
  code.unsafe_to_char()
}

///|
/// A field value as a string (RFC 9110, section 5.5): visible ASCII and
/// characters beyond ASCII, with spaces and tabs only between them. Empty
/// one time in eight.
fn header_value(state : @quickcheck.RandomState) -> String {
  if pick(state, 8) == 0 {
    return ""
  }
  let length = 1 + pick(state, 12)
  let out = StringBuilder()
  for i in 0..<length {
    let c = if i > 0 && i < length - 1 && pick(state, 4) == 0 {
      if pick(state, 2) == 0 {
        ' '
      } else {
        '\t'
      }
    } else if pick(state, 4) == 0 {
      beyond_ascii(state)
    } else {
      (0x21 + pick(state, 0x7f - 0x21)).unsafe_to_char()
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
/// A header field to give the encoder: a token that is not Connection,
/// Content-Length or Transfer-Encoding, which the caller does not pass, in
/// any case; a Date field one time in eight.
fn header(state : @quickcheck.RandomState) -> (String, String) {
  let name = match pick(state, 8) {
    0 => any_case(state, "date")
    1 => "Content-Type"
    _ => token(state, 12)
  }
  let name = if ["connection", "content-length", "transfer-encoding"].contains(
      name.to_lower(),
    ) {
    "X-\{name}"
  } else {
    name
  }
  (name, header_value(state))
}

///|
/// A status (RFC 9110, section 15: three digits, 100 to 599), often one
/// without content, 200, or one that RFC 9110 gives no reason phrase.
fn status(state : @quickcheck.RandomState) -> Int32 {
  match pick(state, 6) {
    0 => 100 + pick(state, 100)
    1 => [204, 304][pick(state, 2)]
    2 => 200
    3 => [299, 418, 599, 103][pick(state, 4)]
    _ => 100 + pick(state, 500)
  }
}

///|
/// Up to `most` random octets.
fn octets(state : @quickcheck.RandomState, most : Int32) -> Bytes {
  Bytes::makei(pick(state, most + 1), _ => pick(state, 256).to_byte())
}

///|
/// A response: any status, up to four header fields, a body in up to four
/// parts (some empty), and a request it answers (GET, HEAD, POST or
/// another method, but not CONNECT, after whose 2xx the connection becomes
/// a tunnel, RFC 9112, section 6.3), or none.
impl @quickcheck.Arbitrary for Response with fn arbitrary(_size, state) {
  let request : Answered? = if pick(state, 5) == 0 {
    None
  } else {
    Some({
      meth: ["GET", "HEAD", "POST", "DELETE"][pick(state, 4)],
      version: if pick(state, 3) == 0 {
        Http10
      } else {
        Http11
      },
      keep_alive: pick(state, 3) != 0,
    })
  }
  {
    status: status(state),
    headers: Array::makei(pick(state, 5), _ => header(state)),
    parts: Array::makei(pick(state, 5), _ => {
      if pick(state, 5) == 0 {
        b""
      } else {
        octets(state, 100)
      }
    }),
    request,
    close: pick(state, 4) == 0,
    date: if pick(state, 2) == 0 {
      None
    } else {
      Some(@http1.DateCache().at(pick(state, 0x7fffffff).to_int64() * 1000L))
    },
    streamed: pick(state, 2) == 0,
  }
}

///|
/// Smaller responses: each without one of its header fields, with a field
/// value emptied, without one of its parts or with a part cut to half or
/// one octet shorter;
/// with status 200, no request, no `close`, no date, or written by
/// `encode_response` instead of a stream. Each has fewer fields, parts,
/// octets or code units, or one of status 200, no request, no close, no
/// date and not streamed where it had the other, so shrinking ends.
impl @quickcheck.Shrink for Response with fn shrink(self) {
  let out : Array[Response] = []
  for i, header in self.headers {
    let rest = self.headers.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, headers: rest, })
    if header.1 != "" {
      let changed = self.headers.copy()
      changed[i] = (header.0, "")
      out.push({ ..self, headers: changed, })
    }
  }
  for i, part in self.parts {
    let rest = self.parts.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, parts: rest, })
    if part.length() > 1 {
      let changed = self.parts.copy()
      changed[i] = part[:part.length() / 2].to_owned()
      out.push({ ..self, parts: changed, })
    }
    if part.length() > 0 {
      let changed = self.parts.copy()
      changed[i] = part[:part.length() - 1].to_owned()
      out.push({ ..self, parts: changed, })
    }
  }
  if self.status != 200 {
    out.push({ ..self, status: 200, })
  }
  if self.request is Some(_) {
    out.push({ ..self, request: None, })
  }
  if self.close {
    out.push({ ..self, close: false, })
  }
  if self.date is Some(_) {
    out.push({ ..self, date: None, })
  }
  if self.streamed {
    out.push({ ..self, streamed: false, })
  }
  out.iter()
}

///|
test "responses that the encoder and the response stream write, read as RFC 9112 defines a response, give the status, fields and body written" {
  @quickcheck.check(
    (response : Response) => response.holds(),
    observe=response => {
      let headers = (f : ((String, String)) -> Bool) => {
        response.headers.iter().any(f)
      }
      let to_head = response.request is Some({ meth: "HEAD", .. })
      [
        @quickcheck.classify(response.streamed, "streamed"),
        @quickcheck.classify(!response.content(), "a status without content"),
        @quickcheck.classify(to_head, "to HEAD"),
        @quickcheck.classify(response.to_http10(), "to HTTP/1.0"),
        @quickcheck.classify(response.request is None, "to no parsed request"),
        @quickcheck.classify(
          response.streamed && response.request is None,
          "streamed to no parsed request",
        ),
        @quickcheck.classify(
          response.streamed &&
          !response.content() &&
          response.request is Some({ version: Http10, keep_alive: true, .. }),
          "streamed without content to HTTP/1.0 that keeps the connection open",
        ),
        @quickcheck.classify(!response.keeps(), "the connection closes"),
        @quickcheck.classify(response.date is Some(_), "a date given"),
        @quickcheck.classify(
          headers(header => header.0.to_lower() == "date"),
          "a Date field given",
        ),
        @quickcheck.classify(
          headers(header => header.1.iter().any(c => c.to_int() >= 0x80)),
          "a character beyond ASCII in a field value",
        ),
        @quickcheck.classify(
          response.parts.iter().any(part => part.is_empty()),
          "an empty part",
        ),
        @quickcheck.classify(
          response.content() && !to_head && !response.body().is_empty(),
          "a body",
        ),
      ]
    },
    counterexample_context=Response::describe,
    count=1000,
    max_shrinks=1000,
    seed=RESPONSE_SEED,
  )
}
