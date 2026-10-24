// The HTTP/2 side of the Seam 2 harness, for every HTTP/2 test: an HTTP/2
// client, which is moonhttp's client-side `Conn` over a TCP socket to the
// plain port (h2c) or over TLS to the TLS port (h2), and raw-frame helpers,
// which send any frame, malformed ones included, with none of the checks a
// client makes, and read frames back. Over TLS, the octets go through the
// OpenSSL bindings' client side, which offers ALPN: moonbitlang/async's TLS
// client offers none.

///|
/// A TLS connection to smock's TLS port through the OpenSSL bindings'
/// client side. OpenSSL works on memory only, so this moves the octets
/// between it and the socket.
struct TlsClient {
  tcp : @socket.Tcp
  tls : @openssl.Connection
  /// What each socket read reads into.
  input : FixedArray[Byte]
}

///|
/// Opens a TLS connection to smock's TLS port that offers the protocols in
/// `alpn` by ALPN, or no ALPN when it is empty, sends `server_name` by SNI
/// and checks smock's certificate for it, trusting only the PEM
/// certificates in `trusted` (by default the test root CA). A handshake
/// that fails raises OpenSSL's reason, such as `tlsv1 alert no application
/// protocol`.
async fn Smock::tls(
  self : Smock,
  alpn~ : Array[String],
  server_name~ : String = "localhost",
  trusted~ : String = @testcerts.root_ca,
) -> TlsClient {
  let tls = @openssl.ClientConfig(trusted=@utf8.encode(trusted), alpn~).connect(
    server_name~,
  )
  let tcp = @socket.Tcp::connect(
    @socket.Addr::parse("127.0.0.1:\{self.tls_port}"),
  )
  errdefer tcp.close()
  let client = { tcp, tls, input: FixedArray::make(16 * 1024, b'\x00'), }
  let handshake = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let done = tls.handshake()
      client.flush()
      if done {
        break
      }
      let n = past_spurious_eagain(() => tcp.read(client.input))
      if n == 0 {
        fail("smock closed the connection during the handshake")
      }
      tls.receive(client.input.unsafe_reinterpret_as_bytes()[:n])
    }
  })
  guard handshake is Some(_) else { fail("no TLS handshake in time") }
  client
}

///|
/// The protocol ALPN selected: `none` when none was.
fn TlsClient::protocol(self : TlsClient) -> String {
  self.tls.alpn_protocol().unwrap_or("none")
}

///|
/// Sends what OpenSSL has written for smock.
async fn TlsClient::flush(self : TlsClient) -> Unit {
  let output = self.tls.take_output()
  if output.length() > 0 {
    self.tcp.write(output)
  }
}

///|
/// Encrypts `data` and sends it.
async fn TlsClient::write(self : TlsClient, data : BytesView) -> Unit {
  self.tls.write(data)
  self.flush()
}

///|
/// Reads plaintext into `buf`, and returns how many octets came: 0 once
/// smock has ended the connection, with close_notify, a FIN or a reset.
async fn TlsClient::read(self : TlsClient, buf : FixedArray[Byte]) -> Int32 {
  for ;; {
    match self.tls.read(buf, offset=0, max_len=buf.length()) {
      Data(n) => {
        self.flush()
        return n
      }
      Closed => return 0
      NeedInput => {
        self.flush()
        let n = past_spurious_eagain(() => self.tcp.read(self.input)) catch {
          _ => 0
        }
        if n == 0 {
          return 0
        }
        self.tls.receive(self.input.unsafe_reinterpret_as_bytes()[:n])
      }
    }
  }
}

///|
/// Reads plaintext until smock ends the connection, and returns all of it.
async fn TlsClient::read_all(self : TlsClient) -> Bytes {
  let buf = FixedArray::make(16 * 1024, b'\x00')
  let out = @buffer.Buffer()
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let n = self.read(buf)
      if n == 0 {
        break
      }
      out.write_bytes(buf.unsafe_reinterpret_as_bytes()[:n])
    }
  })
  guard result is Some(_) else { fail("the TLS connection stayed open") }
  out.to_bytes()
}

///|
fn TlsClient::close(self : TlsClient) -> Unit {
  self.tcp.close()
}

///|
/// What an HTTP/2 test client talks over: TCP to the plain port, or TLS to
/// the TLS port.
enum Wire {
  Cleartext(@socket.Tcp)
  Encrypted(TlsClient)
}

///|
async fn Wire::write(self : Wire, data : BytesView) -> Unit {
  match self {
    Cleartext(tcp) => tcp.write(data)
    Encrypted(tls) => tls.write(data)
  }
}

///|
/// Reads into `buf`, and returns how many octets came: 0 once smock has
/// ended the connection.
async fn Wire::read(self : Wire, buf : FixedArray[Byte]) -> Int32 {
  match self {
    Cleartext(tcp) => past_spurious_eagain(() => tcp.read(buf))
    Encrypted(tls) => tls.read(buf)
  }
}

///|
fn Wire::close(self : Wire) -> Unit {
  match self {
    Cleartext(tcp) => tcp.close()
    Encrypted(tls) => tls.close()
  }
}

///|
/// An HTTP/2 connection to smock: moonhttp's client-side `Conn` over TCP to
/// the plain port by prior knowledge (h2c), or over TLS to the TLS port by
/// ALPN (h2). It sends the preface and its SETTINGS when it opens, hands
/// back every DATA octet it receives, so that smock's windows stay open,
/// and keeps the events of streams no one has asked about yet.
struct H2Client {
  wire : Wire
  conn : @http2.Conn
  /// What each read reads into.
  buf : FixedArray[Byte]
  /// The events read but not yet taken, oldest first.
  events : Array[@http2.Event]
}

///|
/// An HTTP/2 client over `wire`, which has sent nothing yet.
fn H2Client::new(wire : Wire) -> H2Client {
  {
    wire,
    conn: @http2.Conn::new(Client),
    buf: FixedArray::make(16 * 1024, b'\x00'),
    events: [],
  }
}

///|
/// Opens an HTTP/2 connection to smock's plain port and sends the preface
/// and the client's SETTINGS. With `preface_in` greater than 0, the preface
/// goes out in pieces of that many octets, with a pause between them, so
/// that smock reads it in parts.
async fn Smock::h2c(self : Smock, preface_in~ : Int32 = 0) -> H2Client {
  let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}"))
  let client = H2Client::new(Cleartext(tcp))
  if preface_in > 0 {
    let opening = client.conn.take()
    let preface = @http2.preface.length()
    let mut at = 0
    while at < preface {
      let end = if at + preface_in < preface {
        at + preface_in
      } else {
        preface
      }
      tcp.write(opening[at:end])
      @async.sleep(50)
      at = end
    }
    tcp.write(opening[preface:])
  } else {
    client.flush()
  }
  client
}

///|
/// Opens an HTTP/2 connection to smock's TLS port, a TLS connection that
/// offers `h2` alone by ALPN, as `Smock::tls` opens it with `server_name`
/// and `trusted`, and sends the preface and the client's SETTINGS. Fails
/// unless ALPN selected `h2`.
async fn Smock::h2(
  self : Smock,
  server_name~ : String = "localhost",
  trusted~ : String = @testcerts.root_ca,
) -> H2Client {
  let tls = self.tls(alpn=["h2"], server_name~, trusted~)
  if tls.protocol() != "h2" {
    tls.close()
    fail("ALPN selected \{tls.protocol()}, not h2")
  }
  H2Client::over(Encrypted(tls))
}

///|
/// An HTTP/2 client over `wire`, once it has sent the preface and its
/// SETTINGS.
async fn H2Client::over(wire : Wire) -> H2Client {
  let client = H2Client::new(wire)
  client.flush()
  client
}

///|
fn H2Client::close(self : H2Client) -> Unit {
  self.wire.close()
}

///|
/// Writes what the client's `Conn` has queued.
async fn H2Client::flush(self : H2Client) -> Unit {
  let out = self.conn.take()
  if out.length() > 0 {
    self.wire.write(out)
  }
}

///|
/// The next event from smock, read from the socket when the `Conn` needs
/// more: `Closed` once smock has closed the connection. DATA is handed back
/// as it is read.
async fn H2Client::read_event(self : H2Client) -> @http2.Event {
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let event = self.conn.next()
      match event {
        NeedData => {
          self.flush()
          let n = self.wire.read(self.buf) catch { _ => 0 }
          self.conn.receive(self.buf.unsafe_reinterpret_as_bytes()[:n])
        }
        Data(stream~, data~) => {
          self.conn.acknowledge(stream, data.length())
          break event
        }
        _ => break event
      }
    }
  })
  guard result is Some(event) else { fail("no HTTP/2 event in time") }
  event
}

///|
/// The next event about `stream`, keeping the events of other streams for
/// later, or `Closed` once smock has closed the connection.
async fn H2Client::stream_event(
  self : H2Client,
  stream : Int32,
) -> @http2.Event {
  for i, event in self.events {
    if event_stream(event) == Some(stream) {
      self.events.remove(i) |> ignore
      return event
    }
  }
  for ;; {
    let event = self.read_event()
    if event is Closed || event_stream(event) == Some(stream) {
      return event
    }
    if event_stream(event) is Some(_) {
      self.events.push(event)
    }
  }
}

///|
/// The stream an event is about, if it is about one.
fn event_stream(event : @http2.Event) -> Int32? {
  match event {
    Response(stream~, ..)
    | Informational(stream~, ..)
    | Trailers(stream~, ..)
    | Data(stream~, ..)
    | End(stream~)
    | Reset(stream~, ..) => Some(stream)
    WindowUpdated(stream~, ..) if stream != 0 => Some(stream)
    _ => None
  }
}

///|
/// Opens a new stream with a request: `:method` `meth`, `:scheme` `http`,
/// `:path` `path` and `:authority` `authority` when given, then `headers`
/// in order. Sends `body`, when given, within the windows smock gives, and
/// ends the stream unless `end` is false. Returns the stream's ID.
async fn H2Client::send(
  self : H2Client,
  meth : String,
  path : String,
  authority? : String,
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
  end~ : Bool = true,
) -> Int32 {
  let fields = [
    @header.Header::of(":method", meth),
    @header.Header::of(":scheme", "http"),
    @header.Header::of(":path", path),
  ]
  if authority is Some(authority) {
    fields.push(@header.Header::of(":authority", authority))
  }
  for header in headers {
    fields.push({ name: @utf8.encode(header.0), value: @utf8.encode(header.1), })
  }
  let stream = self.conn.next_stream()
  match body {
    None => self.conn.headers(stream, fields, end~)
    Some(body) => {
      self.conn.headers(stream, fields)
      self.send_data(stream, body, end~)
    }
  }
  self.flush()
  stream
}

///|
/// Sends `body` on `stream`, as much at a time as the windows allow,
/// waiting for smock to widen them, and ends the stream unless `end` is
/// false.
async fn H2Client::send_data(
  self : H2Client,
  stream : Int32,
  body : Bytes,
  end~ : Bool = true,
) -> Unit {
  let mut at = 0
  while at < body.length() {
    let room = self.conn.window(stream)
    if room == 0 {
      self.flush()
      match self.read_event() {
        Closed => fail("smock closed the connection while a body was sent")
        event => if event_stream(event) is Some(_) { self.events.push(event) }
      }
      continue
    }
    let n = if body.length() - at < room { body.length() - at } else { room }
    self.conn.data(stream, body[at:at + n], end=end && at + n == body.length())
    at += n
  }
  if body.length() == 0 && end {
    self.conn.end(stream)
  }
  self.flush()
}

///|
/// Sends a request as `send` does and reads its response.
async fn H2Client::request(
  self : H2Client,
  meth : String,
  path : String,
  authority? : String,
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
) -> H2Response {
  self.response(self.send(meth, path, authority?, headers~, body?))
}

///|
/// A response on one stream as the client got it.
struct H2Response {
  /// The status, or 0 when none came.
  status : Int32
  /// The header fields, pseudo-header fields left out, in the order they
  /// came.
  headers : Array[(String, String)]
  body : Bytes
  /// How the stream ended: `"end"`, `"reset <code>"` with the code's name,
  /// or `"closed"` when the connection closed first.
  ended : String
}

///|
/// Reads the response on `stream` until the stream ends, is reset or the
/// connection closes.
async fn H2Client::response(self : H2Client, stream : Int32) -> H2Response {
  let mut status = 0
  let headers = []
  let body = @buffer.Buffer()
  for ;; {
    match self.stream_event(stream) {
      Response(fields~, ..) =>
        for field in fields {
          let (name, value) = (
            @utf8.decode_lossy(field.name),
            @utf8.decode_lossy(field.value),
          )
          if name == ":status" {
            status = @string.parse_int(value)
          } else {
            headers.push((name, value))
          }
        }
      Data(data~, ..) => body.write_bytes(data)
      End(_) => return { status, headers, body: body.to_bytes(), ended: "end", }
      Reset(code~, ..) =>
        return {
          status,
          headers,
          body: body.to_bytes(),
          ended: "reset \{error_name(code)}",
        }
      Closed =>
        return { status, headers, body: body.to_bytes(), ended: "closed", }
      _ => ()
    }
  }
}

///|
/// The response as a test shows it: the status, each header field, with a
/// `date` that is the current time shown as `<now>` (`mask_date`), an
/// empty line and the body, then how the stream ended when it did not end
/// as usual.
fn H2Response::render(self : H2Response) -> String {
  let out = StringBuilder()
  out.write_string("\{self.status}\n")
  for header in self.headers {
    out.write_string("\{shown_field(header.0, header.1)}\n")
  }
  out.write_string("\n")
  out.write_string(@utf8.decode_lossy(self.body))
  if self.ended != "end" {
    out.write_string("\n(\{self.ended})")
  }
  out.to_string()
}

///|
/// A field received from smock as a test shows it, `name: value`, with a
/// `date` that is the current time shown as `<now>` (`mask_date`).
fn shown_field(name : String, value : String) -> String {
  if name == "date" && mask_date("Date: \{value}") == "Date: <now>" {
    "date: <now>"
  } else {
    "\{name}: \{value}"
  }
}

///|
/// The name RFC 9113, section 7, gives an error code.
fn error_name(code : Int32) -> String {
  match code {
    0x0 => "NO_ERROR"
    0x1 => "PROTOCOL_ERROR"
    0x2 => "INTERNAL_ERROR"
    0x3 => "FLOW_CONTROL_ERROR"
    0x4 => "SETTINGS_TIMEOUT"
    0x5 => "STREAM_CLOSED"
    0x6 => "FRAME_SIZE_ERROR"
    0x7 => "REFUSED_STREAM"
    0x8 => "CANCEL"
    0x9 => "COMPRESSION_ERROR"
    0xa => "CONNECT_ERROR"
    0xb => "ENHANCE_YOUR_CALM"
    0xc => "INADEQUATE_SECURITY"
    0xd => "HTTP_1_1_REQUIRED"
    _ => "0x\{code.to_string(radix=16)}"
  }
}

///|
/// A connection to smock's plain port, or by ALPN `h2` to its TLS port,
/// that sends frames exactly as a test builds them, with moonhttp's frame
/// encoder and header blocks from its HPACK encoder, and none of the checks
/// a client makes, so that malformed requests can be sent; and reads frames
/// back, decoding their header blocks with its HPACK decoder.
struct RawH2 {
  wire : Wire
  encoder : @hpack.Encoder
  decoder : @hpack.Decoder
  /// What each read reads into.
  buf : FixedArray[Byte]
  /// The octets received and not yet read as frames.
  mut received : Bytes
}

///|
/// Opens a connection to smock's plain port, or with `tls` to its TLS port,
/// offering `h2` alone by ALPN, and sends the preface and, unless
/// `settings` is false, an empty SETTINGS frame.
async fn Smock::raw_h2(
  self : Smock,
  settings~ : Bool = true,
  tls~ : Bool = false,
) -> RawH2 {
  let wire = if tls {
    let tls = self.tls(alpn=["h2"])
    if tls.protocol() != "h2" {
      tls.close()
      fail("ALPN selected \{tls.protocol()}, not h2")
    }
    Encrypted(tls)
  } else {
    Cleartext(
      @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}")),
    )
  }
  let raw = {
    wire,
    encoder: @hpack.Encoder::new(),
    decoder: @hpack.Decoder::new(),
    buf: FixedArray::make(16 * 1024, b'\x00'),
    received: b"",
  }
  wire.write(@http2.preface)
  if settings {
    raw.send([Settings(params=[], ack=false)])
  }
  raw
}

///|
fn RawH2::close(self : RawH2) -> Unit {
  self.wire.close()
}

///|
/// Sends `frames`, in one write.
async fn RawH2::send(self : RawH2, frames : Array[@http2.Frame]) -> Unit {
  let out = @buffer.Buffer()
  for frame in frames {
    out.write_bytes(frame.encode())
  }
  self.wire.write(out.to_bytes())
}

///|
/// Sends `bytes` as they are.
async fn RawH2::send_bytes(self : RawH2, bytes : Bytes) -> Unit {
  self.wire.write(bytes)
}

///|
/// The header block of `fields`, names and values as UTF-8, from the
/// connection's HPACK encoder, for a HEADERS or CONTINUATION frame.
fn RawH2::block(self : RawH2, fields : Array[(String, String)]) -> Bytes {
  let headers = fields.map(field => @header.Header::{
    name: @utf8.encode(field.0),
    value: @utf8.encode(field.1),
  })
  self.encoder.encode(headers[:])
}

///|
/// The fields of a header block received from smock, as text, decoded
/// with the connection's HPACK decoder.
fn RawH2::fields(self : RawH2, block : Bytes) -> Array[(String, String)] raise {
  self.decoder
  .decode(block[:])
  .map(field => {
    (@utf8.decode_lossy(field.name), @utf8.decode_lossy(field.value))
  })
}

///|
/// The next frame from smock, or `None` once smock has ended the
/// connection, by a FIN or a reset alike.
async fn RawH2::read_frame(self : RawH2) -> @http2.Frame? {
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let (frame, used) = @http2.decode(self.received) catch {
        Incomplete => {
          let n = self.wire.read(self.buf) catch { _ => 0 }
          guard n > 0 else { break None }
          self.received = self.received +
            self.buf.unsafe_reinterpret_as_bytes()[:n].to_owned()
          continue
        }
        err => fail("smock sent a frame that does not decode: \{err}")
      }
      self.received = self.received[used:].to_owned()
      break Some(frame)
    }
  })
  guard result is Some(frame) else { fail("no HTTP/2 frame in time") }
  frame
}

///|
/// Reads frames until smock ends the connection, and shows each as
/// `render_frame` does, one per line, then `closed`.
async fn RawH2::frames_until_end(self : RawH2) -> String {
  let out = []
  while self.read_frame() is Some(frame) {
    out.push(self.render_frame(frame))
  }
  out.push("closed")
  out.join("\n")
}

///|
/// Reads frames until one ends `stream` (DATA or HEADERS with END_STREAM,
/// or RST_STREAM) or smock ends the connection, and shows each as
/// `render_frame` does, one per line, with `closed` at the end of the
/// connection.
async fn RawH2::frames_until_stream_ends(
  self : RawH2,
  stream : Int32,
) -> String {
  let out = []
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    out.push(self.render_frame(frame))
    match frame {
      Data(stream_id~, end_stream=true, ..)
      | Headers(stream_id~, end_stream=true, ..)
      | RstStream(stream_id~, ..) if stream_id == stream => break
      _ => ()
    }
  }
  out.join("\n")
}

///|
/// A frame as a test shows it: its type, its stream, its flags and what
/// it carries, header blocks decoded.
fn RawH2::render_frame(self : RawH2, frame : @http2.Frame) -> String {
  match frame {
    Data(stream_id~, data~, end_stream~, ..) =>
      "DATA \{stream_id}\{flag(end_stream, " END_STREAM")} \{data.length()} octets"
    Headers(stream_id~, fragment~, end_stream~, end_headers~, ..) => {
      let fields = self.fields(fragment) catch {
        err => [("undecodable", err.to_string())]
      }
      let shown = fields.map(field => shown_field(field.0, field.1)).join(", ")
      "HEADERS \{stream_id}\{flag(end_stream, " END_STREAM")}\{flag(end_headers, " END_HEADERS")} [\{shown}]"
    }
    Priority(stream_id~, ..) => "PRIORITY \{stream_id}"
    RstStream(stream_id~, error_code~) =>
      "RST_STREAM \{stream_id} \{error_name(error_code)}"
    Settings(params~, ack~) =>
      if ack {
        "SETTINGS ACK"
      } else {
        let shown = params.map(param => "\{setting_name(param.0)}=\{param.1}")
        "SETTINGS [\{shown.join(", ")}]"
      }
    PushPromise(stream_id~, promised_id~, ..) =>
      "PUSH_PROMISE \{stream_id} promising \{promised_id}"
    Ping(ack~, ..) => "PING\{flag(ack, " ACK")}"
    GoAway(last_stream_id~, error_code~, ..) =>
      "GOAWAY last=\{last_stream_id} \{error_name(error_code)}"
    WindowUpdate(stream_id~, increment~) =>
      "WINDOW_UPDATE \{stream_id} +\{increment}"
    Continuation(stream_id~, end_headers~, ..) =>
      "CONTINUATION \{stream_id}\{flag(end_headers, " END_HEADERS")}"
    Unknown(ftype~, stream_id~, ..) => "frame of type \{ftype} on \{stream_id}"
  }
}

///|
/// `text` when `set`, else nothing.
fn flag(set : Bool, text : String) -> String {
  if set {
    text
  } else {
    ""
  }
}

///|
/// The name RFC 9113, section 6.5.2, gives a setting.
fn setting_name(id : Int32) -> String {
  match id {
    0x1 => "HEADER_TABLE_SIZE"
    0x2 => "ENABLE_PUSH"
    0x3 => "MAX_CONCURRENT_STREAMS"
    0x4 => "INITIAL_WINDOW_SIZE"
    0x5 => "MAX_FRAME_SIZE"
    0x6 => "MAX_HEADER_LIST_SIZE"
    0x8 => "ENABLE_CONNECT_PROTOCOL"
    _ => "0x\{id.to_string(radix=16)}"
  }
}
