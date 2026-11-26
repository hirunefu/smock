// A property of the parser against a writer of requests: requests written
// as RFC 9112 defines them, one after another on a connection and cut into
// pieces anywhere, are read back as they were written. The writer is this
// file's, written from RFC 9112 and RFC 9110, not from the parser.

///|
/// The seed of the property that requests written as RFC 9112 defines them
/// are read back as written, however the bytes are cut. The tests run with
/// it on every push, in mutation runs and in kill confirmations, so a
/// failure reproduces. Each week, `scripts/random-seeds.py` writes a random
/// seed here in a working copy and prints it (CONTRIBUTING.md, "Seeds").
const REQUEST_SEED : UInt64 = 12823592355984658504

///|
/// What a field line of a written request is for. The writer writes Host,
/// Connection, Expect and the field that frames the body by their rules;
/// any other field is one the parser gives no meaning.
priv enum Role {
  Other
  Host
  Connection
  Expect
  Framing
}

///|
/// A field line as written (RFC 9112, section 5): `name ":" before value
/// after CRLF`, where `before` and `after` are OWS (RFC 9110, section
/// 5.6.3) and `value` a field value (RFC 9110, section 5.5). The value of
/// the framing field is written from the body, so `value` is not used for
/// a Content-Length.
priv struct Field {
  role : Role
  name : String
  before : String
  value : Bytes
  after : String
}

///|
/// A chunk of a chunked body (RFC 9112, section 7.1): its chunk-size in
/// hexadecimal with `zeros` leading zeros, in upper case when `upper`, its
/// chunk-ext elements as written, and its chunk-data, one octet or more.
priv struct Chunk {
  zeros : Int32
  upper : Bool
  exts : Array[Bytes]
  data : Bytes
}

///|
/// How a written request's body is framed (RFC 9112, section 6): none, a
/// Content-Length with `zeros` leading zeros and `data` followed by
/// `padding` octets of padding, or chunked with its chunks, a last-chunk of
/// `last_zeros` zeros and its chunk-ext elements, and its trailer fields.
priv enum Body {
  NoBody
  Length(zeros~ : Int32, data~ : Bytes, padding~ : Int32)
  Chunked(
    chunks~ : Array[Chunk],
    last_zeros~ : Int32,
    last_exts~ : Array[Bytes],
    trailers~ : Array[Field]
  )
}

///|
/// A request as the writer writes it: `empty_lines` empty lines before its
/// request line (RFC 9112, section 2.2), its request line, its field lines
/// and its body. `cuts` are where the bytes of this request are cut, as
/// offsets from its first byte, in increasing order.
priv struct Written {
  empty_lines : Int32
  meth : String
  target : String
  version : @http1.Version
  fields : Array[Field]
  body : Body
  cuts : Array[Int32]
}

///|
/// The octets a parser's buffer holds before it first makes room, as
/// `Parser::Parser` makes it today (4,096 bytes). When a stream passes them,
/// `Parser::feed` moves the bytes it holds to the front of its buffer, and
/// grows the buffer when they do not fit. No document states this length:
/// the writer only aims some streams past it, so that the property reaches
/// that code, and what the property expects does not depend on it.
let first_buffer : Int32 = 4096

///|
/// `length` octets of padding: the octets 0 to 250 in turn, so that a
/// copy that starts at another octet of it is not the same.
fn padding_octets(length : Int32) -> Bytes {
  Bytes::makei(length, i => (i % 251).to_byte())
}

///|
/// The value written for `field`: for a Content-Length, the length of the
/// body in decimal (RFC 9110, section 8.6), after its leading zeros.
fn Written::value(self : Written, field : Field) -> Bytes {
  match (field.role, self.body) {
    (Framing, Length(zeros~, data~, padding~)) =>
      @utf8.encode("0".repeat(zeros) + (data.length() + padding).to_string())
    _ => field.value
  }
}

///|
/// Writes a field line.
fn write_field(out : @buffer.Buffer, field : Field, value : Bytes) -> Unit {
  out.write_string_utf8("\{field.name}:\{field.before}")
  out.write_bytes(value)
  out.write_string_utf8("\{field.after}\r\n")
}

///|
/// The request's head: its empty lines, then RFC 9112's `start-line CRLF *(
/// field-line CRLF ) CRLF` (section 2.1), with the request line `method SP
/// request-target SP HTTP-version` (section 3).
fn Written::head(self : Written) -> Bytes {
  let out = @buffer.Buffer()
  for _ in 0..<self.empty_lines {
    out.write_bytes(b"\r\n")
  }
  let version = match self.version {
    Http10 => "HTTP/1.0"
    Http11 => "HTTP/1.1"
  }
  out.write_string_utf8("\{self.meth} \{self.target} \{version}\r\n")
  for field in self.fields {
    write_field(out, field, self.value(field))
  }
  out.write_bytes(b"\r\n")
  out.to_bytes()
}

///|
/// The request's bytes: RFC 9112's `HTTP-message`, `start-line CRLF *(
/// field-line CRLF ) CRLF [ message-body ]` (section 2.1), after its empty
/// lines, with a chunked body as section 7.1 writes it.
fn Written::bytes(self : Written) -> Bytes {
  let out = @buffer.Buffer()
  out.write_bytes(self.head())
  match self.body {
    NoBody => ()
    Length(..) => out.write_bytes(self.content())
    Chunked(chunks~, last_zeros~, last_exts~, trailers~) => {
      for chunk in chunks {
        let size = chunk.data.length().to_string(radix=16)
        let size = if chunk.upper { size.to_upper() } else { size }
        out.write_string_utf8("0".repeat(chunk.zeros) + size)
        for ext in chunk.exts {
          out.write_bytes(ext)
        }
        out.write_bytes(b"\r\n")
        out.write_bytes(chunk.data)
        out.write_bytes(b"\r\n")
      }
      out.write_string_utf8("0".repeat(last_zeros))
      for ext in last_exts {
        out.write_bytes(ext)
      }
      out.write_bytes(b"\r\n")
      for field in trailers {
        write_field(out, field, field.value)
      }
      out.write_bytes(b"\r\n")
    }
  }
  out.to_bytes()
}

///|
/// The request's bytes as a failure shows them: a bytes literal, and the
/// padding of a Content-Length body by its length.
fn Written::shown(self : Written) -> String {
  let bytes = self.bytes()
  match self.body {
    Length(padding~, ..) if padding > 0 =>
      "\{literal(bytes[:bytes.length() - padding])} + \{padding} octets of padding"
    _ => literal(bytes)
  }
}

///|
/// The body the request carries: its data and padding, or, decoded (RFC
/// 9112, section 7.1.3), the chunk-data of its chunks, in order.
fn Written::content(self : Written) -> Bytes {
  match self.body {
    NoBody => b""
    Length(data~, padding~, ..) => {
      let out = @buffer.Buffer()
      out.write_bytes(data)
      out.write_bytes(padding_octets(padding))
      out.to_bytes()
    }
    Chunked(chunks~, ..) => {
      let out = @buffer.Buffer()
      for chunk in chunks {
        out.write_bytes(chunk.data)
      }
      out.to_bytes()
    }
  }
}

///|
/// The connection options of the request's Connection fields, in lower case
/// (RFC 9110, section 7.6.1: `Connection = #connection-option`, compared
/// without regard to case), each element of the list without the white
/// space around it (section 5.6.1).
fn Written::options(self : Written) -> Array[String] {
  let options = []
  for field in self.fields {
    if field.role is Connection {
      for element in @utf8.decode_lossy(field.value).split(",") {
        options.push(element.trim(char_set=" \t").to_owned().to_lower())
      }
    }
  }
  options
}

///|
/// Whether the connection persists after the request (RFC 9112, section
/// 9.3): not when the "close" option is present; otherwise yes for
/// HTTP/1.1, and for HTTP/1.0 only with the "keep-alive" option, which
/// smock honours (`Request::keep_alive`).
fn Written::persists(self : Written) -> Bool {
  let options = self.options()
  if options.contains("close") {
    false
  } else {
    self.version is Http11 || options.contains("keep-alive")
  }
}

///|
/// Whether the parser asks to send `100 Continue` before the body: the
/// request is HTTP/1.1 and expects 100-continue, which the writer sends
/// only with content (RFC 9110, section 10.1.1; an HTTP/1.0 request's
/// expectation is ignored).
fn Written::asks(self : Written) -> Bool {
  self.version is Http11 &&
  self.fields.iter().any(field => field.role is Expect)
}

///|
/// The request the parser should read back: the method, target and version
/// as written, every field line of the header section in order with its
/// name as written and its value without the OWS around it (RFC 9110,
/// section 5.5), the body decoded, and whether the connection persists.
/// Trailer fields are not among the fields (`Request::headers`).
fn Written::expected(self : Written) -> @http1.Request {
  {
    meth: self.meth,
    target: self.target,
    version: self.version,
    headers: self.fields.map(field => {
      name: field.name,
      value: self.value(field),
    }),
    body: self.content(),
    keep_alive: self.persists(),
  }
}

///|
/// What reading a stream gives, in order: a request taken out, the parser
/// asking to send `100 Continue`, and how the stream ends.
#derive(Eq)
priv enum Read {
  Took(@http1.Request)
  Asked
  Needs
  Refused(Int32)
}

///|
/// What a parser reads from the pieces fed one after another, taking out
/// every request it can after each piece.
fn read_requests(pieces : Array[BytesView]) -> Array[Read] {
  let parser = @http1.Parser()
  let out = []
  for piece in pieces {
    parser.feed(piece)
    while true {
      match parser.next() {
        Complete(request) => out.push(Took(request))
        Continue => out.push(Asked)
        NeedMore => break
        Invalid(status~) => {
          out.push(Refused(status))
          return out
        }
      }
    }
  }
  out.push(Needs)
  out
}

///|
/// Requests one after another on a connection.
priv struct Requests {
  requests : Array[Written]
}

///|
/// The stream the requests make.
fn Requests::stream(self : Requests) -> Bytes {
  let out = @buffer.Buffer()
  for request in self.requests {
    out.write_bytes(request.bytes())
  }
  out.to_bytes()
}

///|
/// The stream cut at each request's cuts.
fn Requests::pieces(self : Requests) -> Array[BytesView] {
  let cuts = []
  let mut base = 0
  for request in self.requests {
    let length = request.bytes().length()
    for cut in request.cuts {
      if cut < length {
        cuts.push(base + cut)
      }
    }
    base += length
  }
  cut_at(self.stream(), cuts)
}

///|
/// What the parser should read: for each request, `100 Continue` asked
/// for when it expects it, then the request; then the stream needs more.
fn Requests::expected(self : Requests) -> Array[Read] {
  let out = []
  for request in self.requests {
    if request.asks() {
      out.push(Asked)
    }
    out.push(Took(request.expected()))
  }
  out.push(Needs)
  out
}

///|
/// Whether a Content-Length body of more than the octets a parser's buffer
/// holds at first arrives in more than one piece: the parser gives such a
/// body only whole, so it holds more than those octets at once and grows
/// its buffer.
fn Requests::grows(self : Requests, pieces : Array[BytesView]) -> Bool {
  pieces.length() > 1 &&
  self.requests
  .iter()
  .any(request => {
    request.body is Length(data~, padding~, ..) &&
    data.length() + padding > first_buffer
  })
}

///|
/// Whether, when the first piece that ends past the octets a parser's
/// buffer holds at first arrives, a request has been taken out and part of
/// the next one's head, past its empty lines, has arrived: the parser holds
/// those bytes until the head ends, behind the request taken out, and
/// moves them to the front of its buffer when it makes room.
fn Requests::held_behind(self : Requests, pieces : Array[BytesView]) -> Bool {
  // The octets that arrive before that piece.
  let mut before = 0
  for piece in pieces {
    if before + piece.length() > first_buffer {
      break
    }
    before += piece.length()
  }
  let mut start = 0
  for request in self.requests {
    let end = start + request.bytes().length()
    if end > before {
      return start > 0 &&
        before > start + 2 * request.empty_lines &&
        before < start + request.head().length()
    }
    start = end
  }
  false
}

///|
/// Whether the first piece that ends past the octets a parser's buffer
/// holds at first makes the parser hold more than those octets at once,
/// while the octets it holds begin after a request or a head taken out:
/// the parser then grows its buffer and copies into it the octets it
/// holds, from where they begin. It holds a Content-Length body from the
/// end of its head, a head from its request line, and none of a chunked
/// body, which it decodes as it arrives.
fn Requests::grows_behind(self : Requests, pieces : Array[BytesView]) -> Bool {
  // The octets that arrive before that piece, and with it.
  let mut before = 0
  let mut after = 0
  for piece in pieces {
    after = before + piece.length()
    if after > first_buffer {
      break
    }
    before = after
  }
  guard after > first_buffer else { return false }
  let mut start = 0
  for request in self.requests {
    let end = start + request.bytes().length()
    if end > before {
      let head_end = start + request.head().length()
      // Where the octets the parser holds begin.
      let held = if before < head_end {
        start + 2 * request.empty_lines
      } else if request.body is Length(..) {
        head_end
      } else {
        before
      }
      return held > 0 && held < before && after - held > first_buffer
    }
    start = end
  }
  false
}

///|
/// The property: the parser reads back what the writer wrote.
fn Requests::holds(self : Requests) -> Bool {
  read_requests(self.pieces()) == self.expected()
}

///|
/// A read as a failure shows it, as `render` renders a parse; a body of
/// more than 1,024 octets by its first and last 32 and its length.
fn shown_read(read : Read) -> String {
  match read {
    Took(request) if request.body.length() > 1024 => {
      let body = request.body
      let brief = @buffer.Buffer()
      brief.write_bytes(body[:32])
      brief.write_bytes(b"...")
      brief.write_bytes(body[body.length() - 32:])
      let shown = render(Complete({ ..request, body: brief.to_bytes(), }))
      "\{shown} (a body of \{body.length()} octets)"
    }
    Took(request) => render(Complete(request))
    Asked => "continue"
    Needs => "need more"
    Refused(status) => "invalid \{status}"
  }
}

///|
/// What the parser made of failing requests: the stream, the lengths of
/// its pieces, what the writer wrote and what the parser read.
fn Requests::describe(self : Requests) -> String {
  let pieces = self.pieces()
  let lengths = @debug.to_string(pieces.map(piece => piece.length()))
  let written = self.expected().map(shown_read).join("\n  ")
  let read = read_requests(pieces).map(shown_read).join("\n  ")
  let stream = self.requests.map(Written::shown).join(" + ")
  "stream \{stream}\npieces of \{lengths} bytes\nwritten:\n  \{written}\nread:\n  \{read}"
}

///|
/// Requests as a failure shows them: each request's bytes, then its cuts.
impl @debug.Debug for Requests with fn to_repr(self) {
  let requests = self.requests.map(request => {
    "\{request.shown()} cut at \{@debug.to_string(request.cuts)}"
  })
  @debug.Repr::literal("[\{requests.join(", ")}]")
}

///|
/// The characters of a token (RFC 9110, section 5.6.2: tchar).
let tchars_text : String = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

///|
/// HEXDIG, in either case (RFC 5234, appendix B.1; ABNF strings ignore
/// case, section 2.3).
let hexdigits : String = "0123456789abcdefABCDEF"

///|
/// ALPHA and DIGIT (RFC 5234, appendix B.1).
let alphanumerics : String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

///|
/// `count` characters drawn from `chars`.
fn drawn(
  state : @quickcheck.RandomState,
  chars : String,
  count : Int32,
) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_char(chars[pick(state, chars.length())].unsafe_to_char())
  }
  out.to_string()
}

///|
/// `text` with each lower-case letter in upper case or not, at random:
/// field names, connection options, transfer codings and `100-continue` are
/// compared without regard to case (RFC 9110, sections 5.1, 7.6.1 and
/// 10.1.1; RFC 9112, section 7).
fn any_case(state : @quickcheck.RandomState, text : String) -> String {
  let out = StringBuilder()
  for c in text {
    let upper = c.is_ascii_lowercase() && pick(state, 2) == 0
    out.write_char(if upper { (c.to_int() - 0x20).unsafe_to_char() } else { c })
  }
  out.to_string()
}

///|
/// A token of 1 to `longest` characters.
fn token(state : @quickcheck.RandomState, longest : Int32) -> String {
  drawn(state, tchars_text, 1 + pick(state, longest))
}

///|
/// The names of the fields the parser reads, in lower case.
let read_names : Array[String] = [
  "host", "content-length", "transfer-encoding", "connection", "expect",
]

///|
/// A field name that is none of `read_names`: a common one, or any token.
fn other_name(state : @quickcheck.RandomState) -> String {
  let name = match pick(state, 3) {
    0 =>
      [
        "Accept", "User-Agent", "Content-Type", "X-Request-Id", "Cookie", "If-None-Match",
      ][pick(state, 6)]
    _ => token(state, 12)
  }
  if read_names.contains(name.to_lower()) {
    "X-\{name}"
  } else {
    name
  }
}

///|
/// OWS (RFC 9110, section 5.6.3): up to two spaces or tabs, mostly none or
/// one space.
fn ows(state : @quickcheck.RandomState) -> String {
  match pick(state, 6) {
    0 | 1 | 2 => ""
    3 => " "
    4 => "\t"
    _ => drawn(state, " \t", 2)
  }
}

///|
/// A byte that is a field-vchar (RFC 9110, section 5.5): VCHAR or obs-text.
fn field_vchar(state : @quickcheck.RandomState) -> Byte {
  if pick(state, 5) == 0 {
    (0x80 + pick(state, 0x80)).to_byte()
  } else {
    (0x21 + pick(state, 0x7f - 0x21)).to_byte()
  }
}

///|
/// A field value (RFC 9110, section 5.5): `*field-content`, where
/// field-content begins and ends with a field-vchar and may hold spaces and
/// tabs between. Empty one time in eight.
fn field_value(state : @quickcheck.RandomState) -> Bytes {
  if pick(state, 8) == 0 {
    return b""
  }
  let length = 1 + pick(state, 16)
  Bytes::makei(length, i => {
    if i == 0 || i == length - 1 || pick(state, 4) != 0 {
      field_vchar(state)
    } else if pick(state, 2) == 0 {
      b' '
    } else {
      b'\t'
    }
  })
}

///|
/// A field line of `role` named `name` with `value` and OWS around it.
fn field(
  state : @quickcheck.RandomState,
  role : Role,
  name : String,
  value : Bytes,
) -> Field {
  { role, name, before: ows(state), value, after: ows(state), }
}

///|
/// A field that the parser gives no meaning: any name but those it reads,
/// and any field value.
fn other_field(state : @quickcheck.RandomState) -> Field {
  field(state, Other, other_name(state), field_value(state))
}

///|
/// A percent-encoded octet (RFC 3986, section 2.1).
fn pct_encoded(state : @quickcheck.RandomState) -> String {
  "%" + drawn(state, hexdigits, 2)
}

///|
/// A registered name (RFC 3986, section 3.2.2): unreserved characters,
/// sub-delims and percent-encoded octets, here 1 to 12 of them, mostly
/// letters, digits, `-` and `.`.
fn reg_name(state : @quickcheck.RandomState) -> String {
  let out = StringBuilder()
  for _ in 0..<(1 + pick(state, 12)) {
    match pick(state, 10) {
      0 => out.write_string(drawn(state, "-._~!$&'()*+,;=", 1))
      1 => out.write_string(pct_encoded(state))
      _ =>
        out.write_string(
          drawn(state, "abcdefghijklmnopqrstuvwxyz0123456789", 1),
        )
    }
  }
  out.to_string()
}

///|
/// A dec-octet of an IPv4address (RFC 3986, section 3.2.2): 0 to 255, with
/// no leading zero.
fn dec_octet(state : @quickcheck.RandomState) -> String {
  match pick(state, 4) {
    0 => "0"
    1 => "255"
    _ => pick(state, 256).to_string()
  }
}

///|
/// An IPv4address (RFC 3986, section 3.2.2).
fn ipv4(state : @quickcheck.RandomState) -> String {
  "\{dec_octet(state)}.\{dec_octet(state)}.\{dec_octet(state)}.\{dec_octet(state)}"
}

///|
/// `count` h16 groups of an IPv6address (RFC 3986, section 3.2.2), each
/// one to four hexadecimal digits, joined by `:`.
fn h16s(state : @quickcheck.RandomState, count : Int32) -> String {
  Array::makei(count, _ => drawn(state, hexdigits, 1 + pick(state, 4))).join(
    ":",
  )
}

///|
/// An IP-literal (RFC 3986, section 3.2.2): an IPv6address in brackets,
/// with eight groups, with `::` standing for one or more, or with an
/// IPv4address for the last two; or an IPvFuture.
fn ip_literal(state : @quickcheck.RandomState) -> String {
  let address = match pick(state, 4) {
    0 => h16s(state, 8)
    1 => {
      let before = pick(state, 7)
      let after = pick(state, 8 - before)
      "\{h16s(state, before)}::\{h16s(state, after)}"
    }
    2 => "\{h16s(state, 6)}:\{ipv4(state)}"
    _ =>
      "v\{drawn(state, hexdigits, 1 + pick(state, 2))}.\{drawn(state, "abc019-._~!$&'()*+,;=:", 1 + pick(state, 6))}"
  }
  "[\{address}]"
}

///|
/// `uri-host [":" port]` (RFC 3986, sections 3.2.2 and 3.2.3): the value of
/// a Host field (RFC 9110, section 7.2), and the authority of an
/// absolute-form or authority-form target. A port is `*DIGIT`, so it may
/// be empty; `port_required` writes one.
fn host_and_port(
  state : @quickcheck.RandomState,
  port_required~ : Bool,
) -> String {
  let host = match pick(state, 4) {
    0 => ipv4(state)
    1 => ip_literal(state)
    _ => reg_name(state)
  }
  if port_required || pick(state, 2) == 0 {
    "\{host}:\{drawn(state, "0123456789", pick(state, 6))}"
  } else {
    host
  }
}

///|
/// A path segment (RFC 3986, section 3.3): `*pchar`, where pchar is
/// unreserved, pct-encoded, sub-delims, `:` or `@`. `extra` holds more
/// characters to draw from: a query also takes `/` and `?` (section 3.4).
fn pchars(state : @quickcheck.RandomState, extra : String) -> String {
  let out = StringBuilder()
  for _ in 0..<pick(state, 7) {
    match pick(state, 8) {
      0 => out.write_string(pct_encoded(state))
      1 => out.write_string(drawn(state, "-._~!$&'()*+,;=:@" + extra, 1))
      _ => out.write_string(drawn(state, alphanumerics, 1))
    }
  }
  out.to_string()
}

///|
/// An origin-form target (RFC 9112, section 3.2.1): `absolute-path [ "?"
/// query ]`, where absolute-path is `1*( "/" segment )` (RFC 9110, section
/// 4.1).
fn origin_form(state : @quickcheck.RandomState) -> String {
  let path = Array::makei(1 + pick(state, 4), _ => "/" + pchars(state, "")).join(
    "",
  )
  if pick(state, 3) == 0 {
    "\{path}?\{pchars(state, "/?")}"
  } else {
    path
  }
}

///|
/// A scheme (RFC 3986, section 3.1): `ALPHA *( ALPHA / DIGIT / "+" / "-" /
/// "." )`, mostly http or https.
fn scheme(state : @quickcheck.RandomState) -> String {
  match pick(state, 3) {
    0 => "http"
    1 => "https"
    _ =>
      drawn(state, "abcdefghijklmnopqrstuvwxyz", 1) +
      drawn(state, "abcdefghijklmnopqrstuvwxyz0123456789+-.", pick(state, 6))
  }
}

///|
/// The methods a request is written with: those RFC 9110 defines (section
/// 9), a PATCH, and any other token.
fn request_method(state : @quickcheck.RandomState) -> String {
  match pick(state, 11) {
    10 => token(state, 10)
    i =>
      [
        "GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH",
        "GET",
      ][i]
  }
}

///|
/// Bytes of a body: runs of any octets, and bytes that look like the end
/// of a head, the end of a chunked body or a whole request.
fn body_data(state : @quickcheck.RandomState, longest : Int32) -> Bytes {
  let out = @buffer.Buffer()
  while out.length() < longest && pick(state, 6) != 0 {
    match pick(state, 5) {
      0 => out.write_bytes(b"\r\n\r\n")
      1 => out.write_bytes(b"0\r\n\r\n")
      2 => out.write_bytes(b"GET / HTTP/1.1\r\nHost: a\r\n\r\n")
      _ =>
        for _ in 0..<(1 + pick(state, 16)) {
          out.write_byte(pick(state, 256).to_byte())
        }
    }
  }
  out.to_bytes()
}

///|
/// A quoted-string (RFC 9110, section 5.6.4): qdtext (HTAB, SP, `!`, `#`
/// to `[`, `]` to `~`, obs-text) and quoted-pairs (`\` before HTAB, SP,
/// VCHAR or obs-text) between DQUOTEs.
fn quoted_string(state : @quickcheck.RandomState) -> Bytes {
  let out = @buffer.Buffer()
  out.write_byte(b'"')
  for _ in 0..<pick(state, 8) {
    match pick(state, 6) {
      0 => {
        out.write_byte(b'\\')
        out.write_byte(
          match pick(state, 4) {
            0 => b'"'
            1 => b'\\'
            2 => b'\t'
            _ => field_vchar(state)
          },
        )
      }
      1 => out.write_byte(b' ')
      2 => out.write_byte(b'\t')
      _ => {
        let c = field_vchar(state)
        out.write_byte(if c == b'"' || c == b'\\' { b'a' } else { c })
      }
    }
  }
  out.write_byte(b'"')
  out.to_bytes()
}

///|
/// A chunk-ext element (RFC 9112, section 7.1.1): `BWS ";" BWS
/// chunk-ext-name [ BWS "=" BWS chunk-ext-val ]`, where chunk-ext-val is a
/// token or a quoted-string. A sender does not write BWS, but a recipient
/// parses it (RFC 9110, section 5.6.3), so the writer writes some.
fn chunk_ext(state : @quickcheck.RandomState) -> Bytes {
  let bws = () => if pick(state, 4) == 0 { ows(state) } else { "" }
  let out = @buffer.Buffer()
  out.write_string_utf8("\{bws()};\{bws()}\{token(state, 8)}")
  match pick(state, 3) {
    0 => ()
    1 => out.write_string_utf8("\{bws()}=\{bws()}\{token(state, 8)}")
    _ => {
      out.write_string_utf8("\{bws()}=\{bws()}")
      out.write_bytes(quoted_string(state))
    }
  }
  out.to_bytes()
}

///|
/// Up to `most` chunk-ext elements.
fn chunk_exts(state : @quickcheck.RandomState, most : Int32) -> Array[Bytes] {
  if pick(state, 2) == 0 {
    []
  } else {
    Array::makei(1 + pick(state, most), _ => chunk_ext(state))
  }
}

///|
/// A chunk (RFC 9112, section 7.1): 1 to 64 octets of data, its size with
/// up to two leading zeros, in either case, and chunk-ext elements.
fn chunk(state : @quickcheck.RandomState) -> Chunk {
  let data = body_data(state, 64)
  {
    zeros: if pick(state, 4) == 0 {
      1 + pick(state, 2)
    } else {
      0
    },
    upper: pick(state, 2) == 0,
    exts: chunk_exts(state, 2),
    data: if data.is_empty() {
      [field_vchar(state)]
    } else {
      data
    },
  }
}

///|
/// A request that `last` says whether it is the last on the connection. A
/// request that is not the last persists, since a client sends no request
/// after one that closes the connection (RFC 9112, section 9.6), nor after
/// a CONNECT, whose connection becomes a tunnel (RFC 9110, section 9.3.6).
/// HTTP/1.1 requests carry exactly one Host, HTTP/1.0 ones at most one
/// (RFC 9112, section 3.2); the Host of a target with an authority is that
/// authority. Only HTTP/1.1 requests are chunked (RFC 9112, section 6.1).
/// A CONNECT has no content (RFC 9110, section 9.3.6). Expect:
/// 100-continue goes only with content (RFC 9110, section 10.1.1).
fn written(state : @quickcheck.RandomState, last~ : Bool) -> Written {
  let version : @http1.Version = if pick(state, 4) == 0 {
    Http10
  } else {
    Http11
  }
  let meth = request_method(state)
  let meth = if meth == "CONNECT" && !last { "GET" } else { meth }
  let authority = host_and_port(state, port_required=meth == "CONNECT")
  let (target, host) = if meth == "CONNECT" {
    (authority, authority)
  } else if meth == "OPTIONS" && pick(state, 3) == 0 {
    ("*", host_and_port(state, port_required=false))
  } else if pick(state, 4) == 0 {
    ("\{scheme(state)}://\{authority}\{origin_form(state)}", authority)
  } else {
    (origin_form(state), host_and_port(state, port_required=false))
  }
  let fields = Array::makei(pick(state, 5), _ => other_field(state))
  let insert = (field : Field) => {
    fields.insert(pick(state, fields.length() + 1), field)
  }
  if version is Http11 || pick(state, 2) == 0 {
    insert(field(state, Host, any_case(state, "host"), @utf8.encode(host)))
  }
  // Connection options: a request that is not the last persists.
  let options = []
  let close = last && pick(state, 3) == 0
  if close {
    options.push("close")
  }
  if (version is Http10 && !last) || pick(state, 3) == 0 {
    options.push("keep-alive")
  }
  if pick(state, 4) == 0 {
    let option = token(state, 8)
    if !["close", "keep-alive"].contains(option.to_lower()) {
      options.push(option)
    }
  }
  if !options.is_empty() {
    let value = options
      .map(option => any_case(state, option))
      .join("\{ows(state)},\{ows(state)}")
    insert(
      field(
        state,
        Connection,
        any_case(state, "connection"),
        @utf8.encode(value),
      ),
    )
  }
  let body : Body = match pick(state, 3) {
    _ if meth == "CONNECT" => NoBody
    0 => NoBody
    1 =>
      Length(
        zeros=if pick(state, 5) == 0 { 1 } else { 0 },
        data=body_data(state, 300),
        padding=0,
      )
    _ if version is Http10 =>
      Length(zeros=0, data=body_data(state, 300), padding=0)
    _ =>
      Chunked(
        chunks=Array::makei(pick(state, 4), _ => chunk(state)),
        last_zeros=1 + (if pick(state, 4) == 0 { pick(state, 3) } else { 0 }),
        last_exts=chunk_exts(state, 2),
        trailers=Array::makei(
          if pick(state, 2) == 0 {
            0
          } else {
            1 + pick(state, 2)
          },
          _ => other_field(state),
        ),
      )
  }
  match body {
    NoBody => ()
    Length(..) =>
      insert(field(state, Framing, any_case(state, "content-length"), b""))
    Chunked(..) =>
      insert(
        field(
          state,
          Framing,
          any_case(state, "transfer-encoding"),
          @utf8.encode(any_case(state, "chunked")),
        ),
      )
  }
  let request = {
    empty_lines: if pick(state, 5) == 0 {
      1 + pick(state, 2)
    } else {
      0
    },
    meth,
    target,
    version,
    fields,
    body,
    cuts: [],
  }
  if !request.content().is_empty() && pick(state, 4) == 0 {
    insert(
      field(
        state,
        Expect,
        any_case(state, "expect"),
        @utf8.encode(any_case(state, "100-continue")),
      ),
    )
  }
  request
}

///|
/// The requests, one connection in three with a Content-Length body
/// padded, when one of its requests has such a body, so that the stream
/// passes the octets a parser's buffer holds at first. Either the body
/// grows past them by 1 to 2,048 octets, so that the parser holds more at
/// once; or, when a request follows, the padded request ends so that the
/// first octet past them is in the next request's head, after the first
/// octet of its request line, so that bytes of that head can be held
/// behind a request taken out when the parser makes room.
fn lengthened(
  state : @quickcheck.RandomState,
  requests : Array[Written],
) -> Array[Written] {
  guard pick(state, 3) == 0 else { return requests }
  let framed = []
  for i, request in requests {
    if request.body is Length(..) {
      framed.push(i)
    }
  }
  guard !framed.is_empty() else { return requests }
  let i = framed[pick(state, framed.length())]
  guard requests[i].body is Length(zeros~, data~, ..) else { return requests }
  let padding = if i + 1 < requests.length() && pick(state, 2) == 0 {
    let mut end = 0
    for request in requests[:i + 1] {
      end += request.bytes().length()
    }
    // How many octets of the next request fit before the first octet past
    // the buffer: more than its empty lines, fewer than its head.
    let next = requests[i + 1]
    let before = 2 * next.empty_lines
    let fit = before + 1 + pick(state, next.head().length() - before - 1)
    first_buffer - fit - end
  } else {
    first_buffer + 1 + pick(state, 2048) - data.length()
  }
  guard padding > 0 else { return requests }
  let changed = requests.copy()
  changed[i] = { ..requests[i], body: Length(zeros~, data~, padding~), }
  changed
}

///|
/// One to four requests, the stream cut into pieces of one byte, of up to
/// 7 or up to 100 bytes, or not cut. A stream that passes the octets a
/// parser's buffer holds at first is not cut a byte at a time, so that the
/// property stays quick and a failure shrinks in few steps. Half of those
/// that would not be cut are cut into pieces of up to that many octets
/// instead, so that the piece that passes them can make the parser hold
/// more than them at once, behind what it has taken out.
impl @quickcheck.Arbitrary for Requests with fn arbitrary(_size, state) {
  let count = 1 + pick(state, 4)
  let requests = Array::makei(count, i => written(state, last=i == count - 1))
  let requests = lengthened(state, requests)
  let mut base = 0
  let length = { requests, }.stream().length()
  let longest = if length > first_buffer {
    let longest = [7, 100, 0][pick(state, 3)]
    if longest == 0 && pick(state, 2) == 0 {
      first_buffer
    } else {
      longest
    }
  } else {
    [1, 7, 100, 0][pick(state, 4)]
  }
  let cuts = if longest == 0 {
    []
  } else {
    random_cuts(length, state, longest~)
  }
  let requests = requests.map(request => {
    let length = request.bytes().length()
    let mine = cuts
      .filter(cut => cut >= base && cut < base + length)
      .map(cut => cut - base)
    base += length
    { ..request, cuts: mine, }
  })
  { requests, }
}

///|
/// A request with the Expect field left out.
fn Written::without_expect(self : Written) -> Written {
  { ..self, fields: self.fields.filter(field => !(field.role is Expect)), }
}

///|
/// Smaller requests, each still one the writer could write when it is the
/// `last` on the connection or not: each field that the parser gives no
/// meaning left out, emptied, cut to half its value or without its OWS; a
/// Connection field left out where the request still persists when it
/// must; no empty lines; the target `/` and the method GET where the method
/// and the form allow them; a smaller body (half its data, a chunk,
/// chunk-ext or trailer field left out, or no body), with Expect left out
/// when no content is left; half the cuts or each cut left out. Less
/// padding is `less_padding`'s.
fn Written::smaller(self : Written, last~ : Bool) -> Array[Written] {
  let out : Array[Written] = []
  for i, field in self.fields {
    let without = () => {
      let fields = self.fields.copy()
      fields.remove(i) |> ignore
      { ..self, fields, }
    }
    if field.role is Other {
      out.push(without())
      if !field.value.is_empty() {
        let fields = self.fields.copy()
        fields[i] = { ..field, value: b"", }
        out.push({ ..self, fields, })
        // Half the value, without the white space it may then end with,
        // which no field value ends with.
        let half = field.value[:field.value.length() / 2].to_owned()
        let mut end = half.length()
        while end > 0 && (half[end - 1] == b' ' || half[end - 1] == b'\t') {
          end -= 1
        }
        if end > 0 {
          let fields = self.fields.copy()
          fields[i] = { ..field, value: half[:end].to_owned(), }
          out.push({ ..self, fields, })
        }
      }
    }
    if field.role is Connection && (last || self.version is Http11) {
      out.push(without())
    }
    if field.before != "" || field.after != "" {
      let fields = self.fields.copy()
      fields[i] = { ..field, before: "", after: "", }
      out.push({ ..self, fields, })
    }
  }
  if self.empty_lines > 0 {
    out.push({ ..self, empty_lines: 0, })
  }
  // The shortest origin-form, and a plain method, where the method and the
  // form allow them: CONNECT takes only authority-form, and `*` only
  // OPTIONS.
  if self.meth != "CONNECT" {
    if self.target != "/" {
      out.push({ ..self, target: "/", })
    }
    if self.meth != "GET" && self.target != "*" {
      out.push({ ..self, meth: "GET", })
    }
  }
  let with_body = (body : Body) => {
    let request = { ..self, body, }
    if request.content().is_empty() {
      request.without_expect()
    } else {
      request
    }
  }
  match self.body {
    NoBody => ()
    Length(zeros~, data~, padding~) => {
      out.push(with_body(NoBody).without_framing())
      if !data.is_empty() {
        out.push(
          with_body(
            Length(zeros~, data=data[:data.length() / 2].to_owned(), padding~),
          ),
        )
      }
      if zeros > 0 {
        out.push(with_body(Length(zeros=0, data~, padding~)))
      }
    }
    Chunked(chunks~, last_zeros~, last_exts~, trailers~) => {
      out.push(with_body(NoBody).without_framing())
      let chunked = (
        chunks : Array[Chunk],
        last_exts : Array[Bytes],
        trailers : Array[Field],
      ) => with_body(Chunked(chunks~, last_zeros~, last_exts~, trailers~))
      for i, chunk in chunks {
        let rest = chunks.copy()
        rest.remove(i) |> ignore
        out.push(chunked(rest, last_exts, trailers))
        if chunk.data.length() > 1 {
          let changed = chunks.copy()
          changed[i] = {
            ..chunk,
            data: chunk.data[:chunk.data.length() / 2].to_owned(),
          }
          out.push(chunked(changed, last_exts, trailers))
        }
        for j in 0..<chunk.exts.length() {
          let exts = chunk.exts.copy()
          exts.remove(j) |> ignore
          let changed = chunks.copy()
          changed[i] = { ..chunk, exts, }
          out.push(chunked(changed, last_exts, trailers))
        }
        if chunk.zeros > 0 || chunk.upper {
          let changed = chunks.copy()
          changed[i] = { ..chunk, zeros: 0, upper: false, }
          out.push(chunked(changed, last_exts, trailers))
        }
      }
      for j in 0..<last_exts.length() {
        let exts = last_exts.copy()
        exts.remove(j) |> ignore
        out.push(chunked(chunks, exts, trailers))
      }
      for j in 0..<trailers.length() {
        let rest = trailers.copy()
        rest.remove(j) |> ignore
        out.push(chunked(chunks, last_exts, rest))
      }
      if last_zeros > 1 {
        out.push(
          with_body(Chunked(chunks~, last_zeros=1, last_exts~, trailers~)),
        )
      }
    }
  }
  // The first or the second half of the cuts left out, before each cut
  // alone, so that the many cuts of a long stream go in few steps.
  if self.cuts.length() > 2 {
    let half = self.cuts.length() / 2
    out.push({ ..self, cuts: self.cuts[half:].to_owned(), })
    out.push({ ..self, cuts: self.cuts[:half].to_owned(), })
  }
  for i in 0..<self.cuts.length() {
    let cuts = self.cuts.copy()
    cuts.remove(i) |> ignore
    out.push({ ..self, cuts, })
  }
  out
}

///|
/// A request with the framing field left out, for a request left with no
/// body.
fn Written::without_framing(self : Written) -> Written {
  { ..self, fields: self.fields.filter(field => !(field.role is Framing)), }
}

///|
/// The request with less padding after its Content-Length body's data: all
/// of it left out, then half of it, a quarter, and so on down to one octet,
/// so that a failure that needs the stream to pass the first buffer shrinks
/// to the padding it needs in few steps; with Expect left out when no
/// content is left.
fn Written::less_padding(self : Written) -> Array[Written] {
  guard self.body is Length(zeros~, data~, padding~) else { return [] }
  let out = []
  let mut less = padding
  while less > 0 {
    let request = {
      ..self,
      body: Length(zeros~, data~, padding=padding - less),
    }
    out.push(
      if request.content().is_empty() {
        request.without_expect()
      } else {
        request
      },
    )
    less = less / 2
  }
  out
}

///|
/// Smaller streams: each without one of its requests, and each with one
/// request made smaller. Each has fewer requests, or a request with fewer
/// fields, chunks, chunk-ext elements, trailer fields, octets or cuts, or
/// with GET for another method, and none with more, so shrinking ends.
/// Less padding comes last, so that while a stream passes the first buffer
/// by more than a failure needs, the requests after the padded one lose
/// their fields first.
impl @quickcheck.Shrink for Requests with fn shrink(self) {
  let out : Array[Requests] = []
  for i in 0..<self.requests.length() {
    let rest = self.requests.copy()
    rest.remove(i) |> ignore
    out.push({ requests: rest, })
  }
  let changed = (i : Int32, request : Written) => {
    let requests = self.requests.copy()
    requests[i] = request
    out.push({ requests, })
  }
  for i, request in self.requests {
    for smaller in request.smaller(last=i == self.requests.length() - 1) {
      changed(i, smaller)
    }
  }
  for i, request in self.requests {
    for smaller in request.less_padding() {
      changed(i, smaller)
    }
  }
  out.iter()
}

///|
test "requests written as RFC 9112 defines them are read back as written, however the bytes are cut" {
  @quickcheck.check(
    (requests : Requests) => requests.holds(),
    observe=requests => {
      let any = (f : (Written) -> Bool) => requests.requests.iter().any(f)
      let fields = (f : (Field) -> Bool) => {
        any(request => request.fields.iter().any(f))
      }
      let pieces = requests.pieces()
      [
        @quickcheck.classify(requests.requests.length() > 1, "several requests"),
        @quickcheck.classify(any(r => r.body is NoBody), "no body"),
        @quickcheck.classify(any(r => r.body is Length(..)), "a Content-Length"),
        @quickcheck.classify(any(r => r.body is Chunked(..)), "chunked"),
        @quickcheck.classify(
          any(r => {
            r.body is Chunked(chunks~, last_exts~, ..) &&
            (
              !last_exts.is_empty() ||
              chunks.iter().any(chunk => !chunk.exts.is_empty())
            )
          }),
          "chunk extensions",
        ),
        @quickcheck.classify(
          any(r => r.body is Chunked(trailers~, ..) && !trailers.is_empty()),
          "trailer fields",
        ),
        @quickcheck.classify(any(r => r.version is Http10), "HTTP/1.0"),
        @quickcheck.classify(any(r => r.asks()), "100-continue asked for"),
        @quickcheck.classify(any(r => !r.persists()), "the connection closes"),
        @quickcheck.classify(
          any(r => r.empty_lines > 0),
          "empty lines before a request",
        ),
        @quickcheck.classify(
          any(r => r.target.contains("://")),
          "absolute-form",
        ),
        @quickcheck.classify(any(r => r.meth == "CONNECT"), "authority-form"),
        @quickcheck.classify(any(r => r.target == "*"), "asterisk-form"),
        @quickcheck.classify(
          fields(f => f.value.iter().any(b => b >= b'\x80')),
          "obs-text in a field value",
        ),
        @quickcheck.classify(
          fields(f => f.value.is_empty() && f.role is Other),
          "an empty field value",
        ),
        @quickcheck.classify(
          pieces.iter().all(piece => piece.length() <= 1),
          "one byte at a time",
        ),
        @quickcheck.classify(pieces.length() == 1, "fed whole"),
        @quickcheck.classify(
          requests.grows(pieces),
          "a body of more than 4,096 octets, in pieces",
        ),
        @quickcheck.classify(
          requests.held_behind(pieces),
          "part of a head held behind a request taken out, past 4,096 octets",
        ),
        @quickcheck.classify(
          requests.grows_behind(pieces),
          "more than 4,096 octets held at once, behind what was taken out",
        ),
      ]
    },
    counterexample_context=Requests::describe,
    count=1000,
    max_shrinks=2000,
    seed=REQUEST_SEED,
  )
}
