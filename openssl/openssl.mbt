// smock's own bindings to OpenSSL, the one C library ADR 0001 allows.
//
// A Connection does no I/O. It takes the bytes that arrive from the peer
// (`receive`) and hands out the bytes to send to the peer (`take_output`);
// the caller moves them over the network.

///|
/// Why a TLS configuration or connection failed.
pub suberror TlsError {
  /// The certificate chain holds no PEM certificate, or one that cannot be
  /// used. The message says which.
  InvalidCertificate(String)
  /// The key holds no PEM private key, or one that cannot be used.
  InvalidPrivateKey(String)
  /// The private key does not belong to the leaf certificate.
  KeyMismatch
  /// The handshake or the connection failed, with OpenSSL's reason, such
  /// as `certificate verify failed`.
  Failed(String)
} derive(Debug, Eq)

///|
/// What reading plaintext from a Connection gave.
pub(all) enum ReadResult {
  /// This many bytes were read into the buffer.
  Data(Int)
  /// Nothing can be read until more bytes from the peer are received.
  NeedInput
  /// The peer closed the TLS connection with a close_notify alert.
  Closed
} derive(Debug, Eq)

///|
/// An OpenSSL `SSL_CTX`.
type Ctx

///|
/// An OpenSSL `SSL` with its two memory BIOs.
type Ssl

///|
extern "C" fn take_error_ffi() -> Bytes = "smock_openssl_take_error"

///|
extern "C" fn ctx_new_ffi(server : Bool) -> Ctx = "smock_openssl_ctx_new"

///|
#borrow(ctx)
extern "C" fn ctx_is_null_ffi(ctx : Ctx) -> Bool = "smock_openssl_ctx_is_null"

///|
#borrow(ctx, pem)
extern "C" fn ctx_use_chain_ffi(ctx : Ctx, pem : Bytes) -> Int = "smock_openssl_ctx_use_chain"

///|
#borrow(ctx, pem)
extern "C" fn ctx_use_key_ffi(ctx : Ctx, pem : Bytes) -> Int = "smock_openssl_ctx_use_key"

///|
#borrow(ctx)
extern "C" fn ctx_check_key_ffi(ctx : Ctx) -> Bool = "smock_openssl_ctx_check_key"

///|
#borrow(ctx, pem)
extern "C" fn ctx_trust_ffi(ctx : Ctx, pem : Bytes) -> Int = "smock_openssl_ctx_trust"

///|
#borrow(ctx, wire)
extern "C" fn ctx_set_alpn_ffi(ctx : Ctx, server : Bool, wire : Bytes) -> Bool = "smock_openssl_ctx_set_alpn"

///|
#borrow(ctx)
extern "C" fn ssl_new_ffi(ctx : Ctx, server : Bool) -> Ssl = "smock_openssl_ssl_new"

///|
#borrow(ssl)
extern "C" fn ssl_is_null_ffi(ssl : Ssl) -> Bool = "smock_openssl_ssl_is_null"

///|
#borrow(ssl, name)
extern "C" fn ssl_set_server_name_ffi(ssl : Ssl, name : Bytes) -> Bool = "smock_openssl_ssl_set_server_name"

///|
#borrow(ssl, data)
extern "C" fn ssl_receive_ffi(
  ssl : Ssl,
  data : Bytes,
  offset : Int,
  length : Int,
) -> Int = "smock_openssl_ssl_receive"

///|
#borrow(ssl)
extern "C" fn ssl_take_output_ffi(ssl : Ssl) -> Bytes = "smock_openssl_ssl_take_output"

///|
#borrow(ssl)
extern "C" fn ssl_handshake_ffi(ssl : Ssl) -> Int = "smock_openssl_ssl_handshake"

///|
#borrow(ssl, buf)
extern "C" fn ssl_read_ffi(
  ssl : Ssl,
  buf : FixedArray[Byte],
  offset : Int,
  length : Int,
) -> Int = "smock_openssl_ssl_read"

///|
#borrow(ssl, data)
extern "C" fn ssl_write_ffi(
  ssl : Ssl,
  data : Bytes,
  offset : Int,
  length : Int,
) -> Int = "smock_openssl_ssl_write"

///|
#borrow(ssl)
extern "C" fn ssl_shutdown_ffi(ssl : Ssl) = "smock_openssl_ssl_shutdown"

///|
#borrow(ssl)
extern "C" fn ssl_alpn_ffi(ssl : Ssl) -> Bytes = "smock_openssl_ssl_alpn"

///|
/// OpenSSL's reason for the last failure, then a clean error queue.
fn take_error() -> String {
  let reason = @utf8.decode_lossy(take_error_ffi())
  if reason == "" {
    "unknown OpenSSL error"
  } else {
    reason
  }
}

///|
/// A list of ALPN protocol names in wire format: each name preceded by its
/// length in one byte.
fn alpn_wire(protocols : Array[String]) -> Bytes raise TlsError {
  let out = Buffer()
  for protocol in protocols {
    let name = @utf8.encode(protocol)
    if name.length() == 0 || name.length() > 255 {
      raise Failed("invalid ALPN protocol name \{protocol.escape()}")
    }
    out.write_byte(name.length().to_byte())
    out.write_bytes(name)
  }
  out.to_bytes()
}

///|
/// Whether `pem` has a line `-----BEGIN <label>-----` whose label ends with
/// `label`, such as `RSA PRIVATE KEY` for `PRIVATE KEY`.
fn has_pem_block(pem : Bytes, label : String) -> Bool {
  let text = @utf8.decode_lossy(pem)
  text
  .split("\n")
  .any(line => {
    let line = line.trim_end(chars="\r")
    line.has_prefix("-----BEGIN ") && line.has_suffix(label + "-----")
  })
}

///|
fn contains(data : Bytes, text : String) -> Bool {
  data[:].find(@utf8.encode(text)[:]) is Some(_)
}

///|
fn new_ctx(server~ : Bool) -> Ctx raise TlsError {
  let ctx = ctx_new_ffi(server)
  if ctx_is_null_ffi(ctx) {
    raise Failed("cannot create a TLS context: \{take_error()}")
  }
  ctx
}

///|
/// What a TLS server presents and accepts: one certificate chain and its
/// private key, and the protocols it accepts by ALPN. One ServerConfig
/// serves any number of connections.
pub struct ServerConfig {
  priv ctx : Ctx
}

///|
/// Loads a server configuration.
///
/// - `certificate_chain` is PEM: the leaf certificate first, then the
///   certificates that issued it, which are sent with it.
/// - `private_key` is the leaf's private key in PEM (PKCS#8, PKCS#1 or
///   SEC1), RSA or ECDSA. Encrypted keys are not supported.
/// - `alpn` lists the protocols accepted by ALPN, in order of preference.
///   A client that offers ALPN but none of them fails the handshake with
///   the no_application_protocol alert; a client that offers no ALPN is
///   served.
pub fn ServerConfig::ServerConfig(
  certificate_chain~ : Bytes,
  private_key~ : Bytes,
  alpn~ : Array[String],
) -> ServerConfig raise TlsError {
  let wire = alpn_wire(alpn)
  let ctx = new_ctx(server=true)
  // OpenSSL versions word a missing PEM block differently, so look for one
  // first.
  if !has_pem_block(certificate_chain, "CERTIFICATE") {
    raise InvalidCertificate("no PEM certificate found")
  }
  match ctx_use_chain_ffi(ctx, certificate_chain) {
    0 => raise InvalidCertificate("no PEM certificate found")
    n if n < 0 =>
      raise InvalidCertificate(
        "cannot parse a PEM certificate: \{take_error()}",
      )
    _ => ()
  }
  if !has_pem_block(private_key, "PRIVATE KEY") {
    raise InvalidPrivateKey("no PEM private key found")
  }
  if has_pem_block(private_key, "ENCRYPTED PRIVATE KEY") ||
    contains(private_key, "Proc-Type: 4,ENCRYPTED") {
    raise InvalidPrivateKey("encrypted private keys are not supported")
  }
  match ctx_use_key_ffi(ctx, private_key) {
    0 => raise InvalidPrivateKey("no PEM private key found")
    -2 => raise KeyMismatch
    // OpenSSL's reason differs between versions and says little here, such
    // as "unsupported".
    n if n < 0 => {
      ignore(take_error())
      raise InvalidPrivateKey("cannot parse the PEM private key")
    }
    _ => ()
  }
  if !ctx_check_key_ffi(ctx) {
    raise KeyMismatch
  }
  if !ctx_set_alpn_ffi(ctx, true, wire) {
    raise Failed("cannot set ALPN: \{take_error()}")
  }
  { ctx, }
}

///|
/// Starts the server side of a new TLS connection.
pub fn ServerConfig::accept(self : ServerConfig) -> Connection raise TlsError {
  Connection::new(self.ctx, server=true)
}

///|
/// What a TLS client trusts and offers.
pub struct ClientConfig {
  priv ctx : Ctx
}

///|
/// A client configuration that trusts only the PEM certificates in
/// `trusted` and offers the protocols in `alpn` by ALPN, if any.
pub fn ClientConfig::ClientConfig(
  trusted~ : Bytes,
  alpn? : Array[String] = [],
) -> ClientConfig raise TlsError {
  let wire = alpn_wire(alpn)
  let ctx = new_ctx(server=false)
  if !has_pem_block(trusted, "CERTIFICATE") {
    raise InvalidCertificate("no PEM certificate found")
  }
  match ctx_trust_ffi(ctx, trusted) {
    0 => raise InvalidCertificate("no PEM certificate found")
    n if n < 0 =>
      raise InvalidCertificate(
        "cannot parse a PEM certificate: \{take_error()}",
      )
    _ => ()
  }
  if alpn.length() > 0 && !ctx_set_alpn_ffi(ctx, false, wire) {
    raise Failed("cannot set ALPN: \{take_error()}")
  }
  { ctx, }
}

///|
/// Starts the client side of a new TLS connection to `server_name`: the
/// name it sends by SNI and checks the server's certificate against.
pub fn ClientConfig::connect(
  self : ClientConfig,
  server_name~ : String,
) -> Connection raise TlsError {
  let conn = Connection::new(self.ctx, server=false)
  if !ssl_set_server_name_ffi(conn.ssl, @utf8.encode(server_name)) {
    raise Failed("cannot set the server name: \{take_error()}")
  }
  conn
}

///|
/// One TLS connection, client or server side, driven by bytes: hand it
/// what arrives from the peer with `receive`, and send what `take_output`
/// returns after every call.
pub struct Connection {
  priv ssl : Ssl
}

///|
fn Connection::new(ctx : Ctx, server~ : Bool) -> Connection raise TlsError {
  let ssl = ssl_new_ffi(ctx, server)
  if ssl_is_null_ffi(ssl) {
    raise Failed("cannot create a TLS connection")
  }
  { ssl, }
}

///|
/// Hands bytes that arrived from the peer to the connection.
pub fn Connection::receive(self : Connection, data : BytesView) -> Unit {
  if data.length() > 0 {
    let _ = ssl_receive_ffi(
      self.ssl,
      data.data(),
      data.start_offset(),
      data.length(),
    )
  }
}

///|
/// Takes the bytes the connection has written for the peer since the last
/// call; they are empty when there are none.
pub fn Connection::take_output(self : Connection) -> Bytes {
  ssl_take_output_ffi(self.ssl)
}

///|
/// Advances the handshake with the bytes received so far. Returns `true`
/// once it is done, and `false` while it needs more bytes from the peer.
/// Send `take_output` either way, also when it fails: it may hold an alert.
pub fn Connection::handshake(self : Connection) -> Bool raise TlsError {
  match ssl_handshake_ffi(self.ssl) {
    -1 => false
    -2 => raise Failed("the peer closed the connection during the handshake")
    -3 => raise Failed(take_error())
    _ => true
  }
}

///|
/// Reads up to `max_len` bytes of plaintext into `buf` from `offset`. It
/// finishes the handshake first if needed.
pub fn Connection::read(
  self : Connection,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> ReadResult raise TlsError {
  if max_len <= 0 {
    return Data(0)
  }
  match ssl_read_ffi(self.ssl, buf, offset, max_len) {
    -1 => NeedInput
    -2 => Closed
    -3 => raise Failed(take_error())
    n => Data(n)
  }
}

///|
/// Encrypts `data` for the peer; send `take_output` afterwards.
pub fn Connection::write(
  self : Connection,
  data : BytesView,
) -> Unit raise TlsError {
  if data.length() == 0 {
    return
  }
  match
    ssl_write_ffi(self.ssl, data.data(), data.start_offset(), data.length()) {
    n if n == data.length() => ()
    -3 => raise Failed(take_error())
    _ => raise Failed("the connection cannot be written to")
  }
}

///|
/// Writes a close_notify alert for the peer, once the handshake is done;
/// send `take_output` afterwards.
pub fn Connection::shutdown(self : Connection) -> Unit {
  ssl_shutdown_ffi(self.ssl)
}

///|
/// The protocol ALPN selected, if any.
pub fn Connection::alpn_protocol(self : Connection) -> String? {
  let protocol = ssl_alpn_ffi(self.ssl)
  if protocol.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(protocol))
  }
}
