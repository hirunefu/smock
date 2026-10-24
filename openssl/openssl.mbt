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
/// Why it failed, without the file or the connection it is about, such as
/// `no PEM certificate found` or `the private key does not match the leaf
/// certificate`: the caller adds what it was loading.
pub fn TlsError::message(self : TlsError) -> String {
  match self {
    InvalidCertificate(reason) | InvalidPrivateKey(reason) | Failed(reason) =>
      reason
    KeyMismatch => "the private key does not match the leaf certificate"
  }
}

///|
/// What reading plaintext from a Connection gave.
pub(all) enum ReadResult {
  /// This many bytes were read into the buffer.
  Data(Int32)
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
extern "C" fn ctx_use_chain_ffi(ctx : Ctx, pem : Bytes) -> Int32 = "smock_openssl_ctx_use_chain"

///|
#borrow(ctx, pem)
extern "C" fn ctx_use_key_ffi(ctx : Ctx, pem : Bytes) -> Int32 = "smock_openssl_ctx_use_key"

///|
#borrow(ctx)
extern "C" fn ctx_check_key_ffi(ctx : Ctx) -> Bool = "smock_openssl_ctx_check_key"

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
#borrow(ssl, data)
extern "C" fn ssl_receive_ffi(
  ssl : Ssl,
  data : Bytes,
  offset : Int32,
  length : Int32,
) -> Int32 = "smock_openssl_ssl_receive"

///|
#borrow(ssl)
extern "C" fn ssl_take_output_ffi(ssl : Ssl) -> Bytes = "smock_openssl_ssl_take_output"

///|
#borrow(ssl)
extern "C" fn ssl_handshake_ffi(ssl : Ssl) -> Int32 = "smock_openssl_ssl_handshake"

///|
#borrow(ssl, buf)
extern "C" fn ssl_read_ffi(
  ssl : Ssl,
  buf : FixedArray[Byte],
  offset : Int32,
  length : Int32,
) -> Int32 = "smock_openssl_ssl_read"

///|
#borrow(ssl, data)
extern "C" fn ssl_write_ffi(
  ssl : Ssl,
  data : Bytes,
  offset : Int32,
  length : Int32,
) -> Int32 = "smock_openssl_ssl_write"

///|
#borrow(ssl)
extern "C" fn ssl_shutdown_ffi(ssl : Ssl) = "smock_openssl_ssl_shutdown"

///|
/// An OpenSSL `X509` and its `EVP_PKEY`, generated in memory.
priv type Generated

///|
#borrow(names)
extern "C" fn self_signed_new_ffi(names : Bytes, days : Int32) -> Generated = "smock_openssl_self_signed_new"

///|
#borrow(generated)
extern "C" fn self_signed_is_null_ffi(generated : Generated) -> Bool = "smock_openssl_self_signed_is_null"

///|
#borrow(generated)
extern "C" fn self_signed_certificate_ffi(generated : Generated) -> Bytes = "smock_openssl_self_signed_certificate"

///|
#borrow(generated)
extern "C" fn self_signed_private_key_ffi(generated : Generated) -> Bytes = "smock_openssl_self_signed_private_key"

///|
#borrow(generated)
extern "C" fn self_signed_sha256_ffi(generated : Generated) -> Bytes = "smock_openssl_self_signed_sha256"

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
  offset~ : Int32,
  max_len~ : Int32,
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
/// A certificate for a TLS server that signs itself, and its private key,
/// generated in memory. Nothing is written to disk.
pub struct SelfSigned {
  /// The certificate in PEM.
  certificate : Bytes
  /// Its private key, ECDSA P-256, in PEM (PKCS#8, not encrypted).
  private_key : Bytes
  /// The SHA-256 fingerprint of the certificate: the digest of its DER
  /// encoding as 32 upper-case hex pairs separated by colons, as
  /// `openssl x509 -fingerprint -sha256` and browsers show it.
  sha256_fingerprint : String
}

///|
/// Generates a new ECDSA P-256 key and a certificate for it, signed with
/// itself, for a TLS server. A client that trusts the certificate verifies
/// it for each of `names` and for no other name.
///
/// - `names` become its subject alternative names: a name that is an IPv4
///   or IPv6 address, without brackets, such as `127.0.0.1` or `::1`,
///   becomes an IP address, and every other name a DNS name.
/// - It is valid from an hour before now, for clocks a little behind, for
///   `days` days.
///
/// Each call makes a new key, and a new certificate with a random serial
/// number, so no two share a fingerprint.
pub fn SelfSigned::generate(
  names : Array[String],
  days~ : Int32,
) -> SelfSigned raise TlsError {
  if names.is_empty() {
    raise Failed("a self-signed certificate needs at least one name")
  }
  let list = Buffer()
  for name in names {
    if name == "" || name.contains_char('\u{0}') {
      raise Failed("invalid name \{name.escape()} for a certificate")
    }
    list.write_bytes(@utf8.encode(name))
    list.write_byte(b'\x00')
  }
  let generated = self_signed_new_ffi(list.to_bytes(), days)
  if self_signed_is_null_ffi(generated) {
    raise Failed("cannot generate a self-signed certificate: \{take_error()}")
  }
  let certificate = self_signed_certificate_ffi(generated)
  let private_key = self_signed_private_key_ffi(generated)
  let digest = self_signed_sha256_ffi(generated)
  if certificate.length() == 0 ||
    private_key.length() == 0 ||
    digest.length() == 0 {
    raise Failed("cannot encode the self-signed certificate: \{take_error()}")
  }
  { certificate, private_key, sha256_fingerprint: fingerprint(digest), }
}

///|
/// `digest` as upper-case hex pairs separated by colons, such as `0A:FF`.
fn fingerprint(digest : Bytes) -> String {
  let hex = "0123456789ABCDEF"
  let out = StringBuilder()
  for i, byte in digest {
    if i > 0 {
      out.write_char(':')
    }
    let n = byte.to_int()
    out.write_char(hex.get_char(n >> 4).unwrap())
    out.write_char(hex.get_char(n & 15).unwrap())
  }
  out.to_string()
}
