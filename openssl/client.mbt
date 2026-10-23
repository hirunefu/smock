// The client side of the bindings. smock's server never uses it: e2e
// drives the TLS port with moonbitlang/async's own client. The bindings'
// tests use it to run a client and a server Connection against each other
// in memory, with no I/O, so that scripts/test-openssl-asan.sh can check
// both sides under AddressSanitizer and LeakSanitizer.

///|
#borrow(ctx, pem)
extern "C" fn ctx_trust_ffi(ctx : Ctx, pem : Bytes) -> Int32 = "smock_openssl_ctx_trust"

///|
#borrow(ssl, name)
extern "C" fn ssl_set_server_name_ffi(ssl : Ssl, name : Bytes) -> Bool = "smock_openssl_ssl_set_server_name"

///|
#borrow(ssl)
extern "C" fn ssl_alpn_ffi(ssl : Ssl) -> Bytes = "smock_openssl_ssl_alpn"

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
  alpn~ : Array[String] = [],
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
/// The protocol ALPN selected, if any.
pub fn Connection::alpn_protocol(self : Connection) -> String? {
  let protocol = ssl_alpn_ffi(self.ssl)
  if protocol.length() == 0 {
    None
  } else {
    Some(@utf8.decode_lossy(protocol))
  }
}
