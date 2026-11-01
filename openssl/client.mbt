// The client side of the bindings, and the protocol ALPN selected. smock's
// server asks the protocol ALPN selected on each connection of its TLS port,
// to serve HTTP/2 when it is h2. The e2e tests drive HTTP/2 over the TLS
// port with the client side, since it offers ALPN and moonbitlang/async's
// own TLS client offers none. The bindings' tests use it to run a client
// and a server Connection against each other in memory, with no I/O, so
// that scripts/test-openssl-asan.sh can check both sides under
// AddressSanitizer and LeakSanitizer.

///|
#borrow(ctx, pem)
extern "C" fn ctx_trust_ffi(ctx : Ctx, pem : Bytes) -> Int32 = "smock_openssl_ctx_trust"

///|
#borrow(ctx, ciphers)
extern "C" fn ctx_tls12_ciphers_ffi(ctx : Ctx, ciphers : Bytes) -> Bool = "smock_openssl_ctx_tls12_ciphers"

///|
#borrow(ssl, name)
extern "C" fn ssl_set_server_name_ffi(ssl : Ssl, name : Bytes) -> Bool = "smock_openssl_ssl_set_server_name"

///|
#borrow(ssl)
extern "C" fn ssl_alpn_ffi(ssl : Ssl) -> Bytes = "smock_openssl_ssl_alpn"

///|
#borrow(ssl)
extern "C" fn ssl_update_keys_ffi(ssl : Ssl) -> Bool = "smock_openssl_ssl_update_keys"

///|
#borrow(ssl)
extern "C" fn ssl_alert_ffi(ssl : Ssl) -> Int32 = "smock_openssl_ssl_alert"

///|
/// What a TLS client trusts and offers.
pub struct ClientConfig {
  priv ctx : Ctx
}

///|
/// A client configuration that trusts only the PEM certificates in
/// `trusted` and offers the protocols in `alpn` by ALPN, if any. With
/// `tls12_ciphers`, an OpenSSL cipher list such as
/// `ECDHE-RSA-AES128-GCM-SHA256`, it offers TLS 1.2 alone, with only those
/// suites, so that a test can choose the suite a TLS 1.2 connection uses.
pub fn ClientConfig::ClientConfig(
  trusted~ : Bytes,
  alpn~ : Array[String] = [],
  tls12_ciphers? : String,
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
  if tls12_ciphers is Some(ciphers) &&
    !ctx_tls12_ciphers_ffi(ctx, @utf8.encode(ciphers)) {
    raise Failed("cannot set the TLS 1.2 cipher suites: \{take_error()}")
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
/// The protocol ALPN selected, if any, on either side. smock's server asks
/// it of each connection of its TLS port, and the e2e tests of their
/// client's.
pub fn Connection::alpn_protocol(self : Connection) -> String? {
  let protocol = ssl_alpn_ffi(self.ssl)
  if protocol.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(protocol))
  }
}

///|
/// The description of the last alert the server sent this client side,
/// such as 120 for no_application_protocol (RFC 8446, section 6), if it
/// sent one. A test whose handshake failed asks it to learn which alert
/// failed it by the protocol's own code: OpenSSL's text for an alert
/// differs between versions, and some have none.
pub fn Connection::alert_received(self : Connection) -> Int32? {
  match ssl_alert_ffi(self.ssl) {
    -1 => None
    alert => Some(alert)
  }
}

///|
/// Updates the keys this side sends with, and asks the peer to update the
/// keys it sends with too, by a TLS 1.3 KeyUpdate message; send
/// `take_output` afterwards. The peer's KeyUpdate comes back as output of
/// one of its reads, which this side's next read takes in.
pub fn Connection::update_keys(self : Connection) -> Unit raise TlsError {
  if !ssl_update_keys_ffi(self.ssl) {
    raise Failed("cannot update the keys: \{take_error()}")
  }
}
