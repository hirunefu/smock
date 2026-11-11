///|
/// The protocols the TLS port accepts by ALPN, for every certificate, in
/// order of preference, as `--tls-http2` (`http2`) sets them: HTTP/2, then
/// HTTP/1.1, or HTTP/1.1 alone when it is off. The protocol selected
/// decides how a connection is served: `h2` is HTTP/2, and `http/1.1`, or
/// no ALPN, is HTTP/1.1 (`TlsStream::is_http2`). Over a TLS 1.2 suite that
/// RFC 9113 prohibits, the bindings' ALPN callback skips `h2`.
fn tls_alpn(http2 : Bool) -> Array[String] {
  if http2 {
    ["h2", "http/1.1"]
  } else {
    ["http/1.1"]
  }
}

///|
/// Reads the certificate and key files: their bytes, or what keeps them
/// from being read, as one sentence that names the file at fault.
async fn read_pair(
  files : @settings.TlsFiles,
) -> Result[(Bytes, Bytes), String] {
  let cert = match read_file(files.cert_file) {
    Ok(cert) => cert
    Err(reason) => return Err("cannot read the certificate file: \{reason}")
  }
  let key = match read_file(files.key_file) {
    Ok(key) => key
    Err(reason) => return Err("cannot read the key file: \{reason}")
  }
  Ok((cert, key))
}

///|
/// Loads a certificate chain and its key, as read from their files, for
/// the TLS port, accepting the protocols `alpn` (`tls_alpn`). Returns what
/// is wrong with them otherwise, as one sentence that names the file at
/// fault.
fn load_pair(
  cert : Bytes,
  key : Bytes,
  alpn~ : Array[String],
) -> Result[@openssl.ServerConfig, String] {
  try
    @openssl.ServerConfig(certificate_chain=cert, private_key=key, alpn~)
  catch {
    InvalidCertificate(_) as err => Err("certificate file: \{err.message()}")
    InvalidPrivateKey(_) as err => Err("key file: \{err.message()}")
    err => Err(err.message())
  } noraise {
    config => Ok(config)
  }
}

///|
/// One TLS connection on top of a TCP connection: the byte stream that
/// the HTTP/1.1 loop (`serve_connection`) or the HTTP/2 loop
/// (`MockPorts::serve_http2`) reads requests from and writes responses to.
/// OpenSSL works on memory buffers only, so this moves the bytes between it
/// and the socket.
priv struct TlsStream {
  tcp : @socket.Tcp
  tls : @openssl.Connection
  // Every @io.Reader keeps a read buffer that only moonbitlang/async can
  // create, so this one uses the buffer of a pipe that is never read.
  buffer : @io.PipeRead
  input : FixedArray[Byte]
  /// Whether a read leaves the records OpenSSL writes for the client while
  /// it reads to the connection's writer (`ReadOutput`), as on an HTTP/2
  /// connection, rather than send them itself.
  mut holds_read_output : Bool
  /// Whether a read may have left output that nothing has sent since.
  mut read_output_left : Bool
}

///|
/// The most plaintext one `write_once` encrypts and sends: one TLS record.
const MAX_WRITE = 16384

///|
/// Runs the server side of the handshake on `tcp`, with the configuration
/// `select` gives for the name the client asks for by SNI, or for no name.
/// Returns `None` when the client closes the connection first. A client
/// that fails the handshake gets OpenSSL's alert, if any, and the error is
/// raised; the caller then closes the connection either way.
async fn TlsStream::accept(
  tcp : @socket.Tcp,
  select : (String?) -> @openssl.ServerConfig,
) -> TlsStream? {
  let input = FixedArray::make(16 * 1024, b'\x00')
  // The ClientHello comes first: read it whole to learn the name, before
  // the connection starts with a configuration.
  let hello = Buffer()
  let server_name = for ;; {
    match read_client_hello(hello.to_bytes()[:]) {
      ServerName(name) => break name
      Incomplete => {
        let n = tcp.read(input)
        if n == 0 {
          return None
        }
        hello.write_bytes(input.unsafe_reinterpret_as_bytes()[:n])
      }
    }
  }
  let (buffer, _) = @io.pipe()
  let self = {
    tcp,
    tls: select(server_name).accept(),
    buffer,
    input,
    holds_read_output: false,
    read_output_left: false,
  }
  self.tls.receive(hello.to_bytes()[:])
  // A failed handshake still sends its alert, even if a cancellation comes
  // while it does. When a cancellation ends the handshake, during a read,
  // there is nothing to send: each step's output goes out before the read.
  errdefer @async.protect_from_cancel(() => self.try_flush())
  for ;; {
    let done = self.tls.handshake()
    self.flush()
    if done {
      return Some(self)
    }
    if !self.fill() {
      return None
    }
  }
}

///|
/// Whether ALPN selected HTTP/2: the connection is then served as HTTP/2,
/// and otherwise as HTTP/1.1, which never looks for the HTTP/2 preface
/// (RFC 9113, section 3.3).
fn TlsStream::is_http2(self : TlsStream) -> Bool {
  self.tls.alpn_protocol() is Some("h2")
}

///|
/// Sends what OpenSSL has written for the client.
async fn TlsStream::flush(self : TlsStream) -> Unit {
  let output = self.tls.take_output()
  self.read_output_left = false
  if output.length() > 0 {
    self.tcp.write(output)
  }
}

///|
/// After a read: sends what OpenSSL wrote for the client while it read, or
/// leaves it for the connection's writer.
async fn TlsStream::after_read(self : TlsStream) -> Unit {
  if self.holds_read_output {
    self.read_output_left = true
  } else {
    self.flush()
  }
}

///|
/// Sends what OpenSSL has written for the client, if the client is still
/// there to receive it.
async fn TlsStream::try_flush(self : TlsStream) -> Unit {
  self.flush() catch {
    _ => ()
  }
}

///|
/// Reads the next bytes from the client into OpenSSL. Returns `false` when
/// the client has closed the TCP connection.
async fn TlsStream::fill(self : TlsStream) -> Bool {
  let n = self.tcp.read(self.input)
  if n == 0 {
    return false
  }
  self.tls.receive(self.input.unsafe_reinterpret_as_bytes()[:n])
  true
}

///|
/// Ends the TLS connection with a close_notify alert, if the client is
/// still there to receive it.
async fn TlsStream::shutdown(self : TlsStream) -> Unit {
  self.tls.shutdown()
  self.try_flush()
}

///|
impl @io.Reader for TlsStream with fn _get_internal_buffer(self) {
  @io.Reader::_get_internal_buffer(self.buffer)
}

///|
/// Reads plaintext. It returns 0 at the end of the stream: when the client
/// sends close_notify, or closes the TCP connection without it.
impl @io.Reader for TlsStream with fn _direct_read(self, buf, offset~, max_len~) {
  for ;; {
    match self.tls.read(buf, offset~, max_len~) {
      Data(n) => {
        // A read can make OpenSSL write for the client, such as an alert.
        self.after_read()
        return n
      }
      Closed => return 0
      NeedInput => {
        self.after_read()
        if !self.fill() {
          return 0
        }
      }
    }
  }
}

///|
/// Each write sends what OpenSSL holds for the client, in the order it
/// wrote it: what reads left first, then the record of `data`.
impl @io.Writer for TlsStream with fn write_once(self, data, offset~, len~) {
  let len = if len > MAX_WRITE { MAX_WRITE } else { len }
  self.tls.write(data[offset:offset + len])
  self.flush()
  len
}

///|
/// From now on, a read leaves the records OpenSSL writes for the client to
/// the connection's writer (`after_read`).
impl ReadOutput for TlsStream with fn hold_read_output(self) {
  self.holds_read_output = true
}

///|
/// Whether a read has left records that nothing has sent since.
impl ReadOutput for TlsStream with fn has_read_output(self) {
  self.read_output_left
}

///|
/// Sends what OpenSSL holds for the client, the records reads left among
/// it, with the write timeout of `watchdog`.
impl ReadOutput for TlsStream with fn write_read_output(self, watchdog) {
  watchdog.writing(@async.now())
  self.flush()
  watchdog.stop_writing()
}
