///|
/// The protocols the TLS port accepts by ALPN. HTTP/2 comes in R2.
let alpn : Array[String] = ["http/1.1"]

///|
/// Reads the certificate and key files and loads them for the TLS port.
/// Returns what is wrong with them otherwise, as one sentence that names
/// the file at fault.
async fn load_tls(
  files : @settings.TlsFiles,
) -> Result[@openssl.ServerConfig, String] {
  let cert = match read_file(files.cert_file) {
    Ok(cert) => cert
    Err(reason) => return Err("cannot read the certificate file: \{reason}")
  }
  let key = match read_file(files.key_file) {
    Ok(key) => key
    Err(reason) => return Err("cannot read the key file: \{reason}")
  }
  try
    @openssl.ServerConfig(certificate_chain=cert, private_key=key, alpn~)
  catch {
    InvalidCertificate(reason) => Err("certificate file: \{reason}")
    InvalidPrivateKey(reason) => Err("key file: \{reason}")
    KeyMismatch => Err("the private key does not match the leaf certificate")
    Failed(reason) => Err(reason)
  } noraise {
    config => Ok(config)
  }
}

///|
/// The contents of a file, or why it cannot be read, such as
/// `no such file`.
async fn read_file(path : String) -> Result[Bytes, String] {
  // Such as a Secret volume's directory given instead of a file in it.
  let is_dir = try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Directory
  }
  if is_dir {
    return Err("is a directory")
  }
  try @fs.read_file(path).binary() catch {
    @os_error.OSError(_, ..) as err if err.is_ENOENT() => Err("no such file")
    @os_error.OSError(_, ..) as err if err.is_EACCES() =>
      Err("permission denied")
    err => Err(err.to_string())
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
/// One TLS connection on top of a TCP connection: the byte stream that
/// `serve_connection` reads requests from and writes responses to. OpenSSL
/// works on memory buffers only, so this moves the bytes between it and the
/// socket.
priv struct TlsStream {
  tcp : @socket.Tcp
  tls : @openssl.Connection
  // Every @io.Reader keeps a read buffer that only moonbitlang/async can
  // create, so this one uses the buffer of a pipe that is never read.
  buffer : @io.PipeRead
  input : FixedArray[Byte]
}

///|
/// The most plaintext one `write_once` encrypts and sends: one TLS record.
const MAX_WRITE = 16384

///|
/// Runs the server side of the handshake on `tcp`. Returns `None` when the
/// client closes the connection first. A client that fails the handshake
/// gets OpenSSL's alert, if any, and the error is raised; the caller then
/// closes the connection either way.
async fn TlsStream::accept(
  tcp : @socket.Tcp,
  config : @openssl.ServerConfig,
) -> TlsStream? {
  let (buffer, _) = @io.pipe()
  let self = {
    tcp,
    tls: config.accept(),
    buffer,
    input: FixedArray::make(16 * 1024, b'\x00'),
  }
  // A failed handshake still sends its alert.
  errdefer self.try_flush()
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
/// Sends what OpenSSL has written for the client.
async fn TlsStream::flush(self : TlsStream) -> Unit {
  let output = self.tls.take_output()
  if output.length() > 0 {
    self.tcp.write(output)
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
        // A read can make OpenSSL answer, such as to a key update.
        self.flush()
        return n
      }
      Closed => return 0
      NeedInput => {
        self.flush()
        if !self.fill() {
          return 0
        }
      }
    }
  }
}

///|
impl @io.Writer for TlsStream with fn write_once(self, data, offset~, len~) {
  let len = if len > MAX_WRITE { MAX_WRITE } else { len }
  self.tls.write(data[offset:offset + len])
  self.flush()
  len
}
