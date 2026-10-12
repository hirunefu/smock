// The certificate the TLS port presents: the configured certificate files,
// or, without them, a self-signed certificate smock generates in memory for
// local use.

///|
/// How many days a generated certificate is valid. smock generates a new
/// one at every start, and clients limit how long a server certificate may
/// be valid (398 days for some).
const SELF_SIGNED_DAYS = 365

///|
/// What the TLS port presents to each new connection. A connection keeps
/// the certificate it started its handshake with.
priv enum TlsCertificate {
  /// The configured certificate files: the default pair and the pairs of
  /// single Mocks, which SNI chooses and which rotate.
  Files(Certificates)
  /// A self-signed certificate smock generated for the Hosts it serves.
  SelfSigned(SelfSignedCertificate)
}

///|
/// The configuration a new handshake gets when the client asks for
/// `server_name` by SNI, or for no name.
fn TlsCertificate::select(
  self : TlsCertificate,
  server_name : String?,
) -> @openssl.ServerConfig {
  match self {
    Files(certificates) => certificates.select(server_name)
    SelfSigned(certificate) => certificate.config
  }
}

///|
/// Follows a reload that swapped in a new definition set served by
/// `engine`: warns about the Mocks with certificate files of their own that
/// it does not declare, or replaces a self-signed certificate whose names no
/// longer match its Hosts.
fn TlsCertificate::after_swap(
  self : TlsCertificate,
  engine : @engine.Engine,
  logger : @log.Logger,
) -> Unit {
  match self {
    Files(certificates) => certificates.warn_undeclared()
    SelfSigned(certificate) => certificate.follow_hosts(engine, logger)
  }
}

///|
/// A self-signed certificate smock generated, loaded for the TLS port.
priv struct SelfSignedCertificate {
  /// What new handshakes get.
  mut config : @openssl.ServerConfig
  /// The names it covers.
  mut names : Array[String]
}

///|
/// A self-signed certificate for the Hosts `engine` serves. Returns `None`
/// when it cannot be generated, which is logged.
fn SelfSignedCertificate::generate(
  engine : @engine.Engine,
  logger : @log.Logger,
) -> SelfSignedCertificate? {
  let names = self_signed_names(engine.status())
  generate_self_signed(names, logger).map(config => { config, names, })
}

///|
/// Follows the Hosts `engine` serves after a reload: a certificate whose
/// names no longer match them is replaced by a new one, for new
/// connections. It is kept when a new one cannot be generated (which is
/// logged).
fn SelfSignedCertificate::follow_hosts(
  self : SelfSignedCertificate,
  engine : @engine.Engine,
  logger : @log.Logger,
) -> Unit {
  let names = self_signed_names(engine.status())
  if names == self.names {
    return
  }
  if generate_self_signed(names, logger) is Some(config) {
    self.config = config
    self.names = names
  }
}

///|
/// The names a self-signed certificate covers: `localhost`, `127.0.0.1`
/// and `::1`, then every Host of every Mock, normalised as Host resolution
/// compares it, in byte-wise order, each name once. An IPv6 Host is given
/// without its brackets.
fn self_signed_names(status : @engine.Status) -> Array[String] {
  let names = ["localhost", "127.0.0.1", "::1"]
  let hosts = []
  for mock in status.mocks {
    for host in mock.hosts {
      let host = @definitions.normalize_host(host)
      let host = if host.has_prefix("[") && host.has_suffix("]") {
        host[1:host.length() - 1].to_owned()
      } else {
        host
      }
      if !names.contains(host) && !hosts.contains(host) {
        hosts.push(host)
      }
    }
  }
  hosts.sort_by((a, b) => a.lexical_compare(b))
  names + hosts
}

///|
/// Generates a self-signed certificate for `names` and loads it for the TLS
/// port, and logs that it is in use, with its SHA-256 fingerprint and its
/// names. Returns `None` when it cannot, which is logged instead.
fn generate_self_signed(
  names : Array[String],
  logger : @log.Logger,
) -> @openssl.ServerConfig? {
  try {
    let generated = @openssl.SelfSigned::generate(names, days=SELF_SIGNED_DAYS)
    let config = @openssl.ServerConfig(
      certificate_chain=generated.certificate,
      private_key=generated.private_key,
      alpn~,
    )
    (config, generated.sha256_fingerprint)
  } catch {
    err => {
      let reason = match err {
        Failed(reason)
        | InvalidCertificate(reason)
        | InvalidPrivateKey(reason) => reason
        KeyMismatch => "the private key does not match the certificate"
      }
      logger.error("cannot generate a self-signed certificate", fields={
        "error": Json::string(reason),
      })
      None
    }
  } noraise {
    (config, fingerprint) => {
      logger.info("self-signed certificate in use", fields={
        "sha256Fingerprint": Json::string(fingerprint),
        "names": Json::array(names.map(name => Json::string(name))),
      })
      Some(config)
    }
  }
}
