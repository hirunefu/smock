// The certificate the TLS port presents: the configured certificate files,
// or, without them, a self-signed certificate smock generates in memory for
// local use.

///|
/// How many days a generated certificate is valid. smock generates a new
/// one at every start, and clients limit how long a server certificate may
/// be valid (398 days for some).
const SELF_SIGNED_DAYS = 365

///|
/// The certificate the TLS port presents to each new connection. A
/// connection keeps the one it was accepted with.
priv struct TlsCertificate {
  mut config : @openssl.ServerConfig
  /// The names of the self-signed certificate smock generated, or `None`
  /// when it presents the configured certificate files.
  mut self_signed_names : Array[String]?
}

///|
/// The configured certificate files, loaded.
fn TlsCertificate::from_files(config : @openssl.ServerConfig) -> TlsCertificate {
  { config, self_signed_names: None, }
}

///|
/// A self-signed certificate for the Hosts `engine` serves. Returns `None`
/// when it cannot be generated, which is logged.
fn TlsCertificate::self_signed(
  engine : @engine.Engine,
  logger : @log.Logger,
) -> TlsCertificate? {
  let names = self_signed_names(engine.status())
  generate_self_signed(names, logger).map(config => {
    config,
    self_signed_names: Some(names),
  })
}

///|
/// Follows the Hosts `engine` serves after a reload: a self-signed
/// certificate whose names no longer match them is replaced by a new one,
/// for new connections. The configured certificate files are kept, and so
/// is a self-signed certificate when a new one cannot be generated (which is
/// logged).
fn TlsCertificate::follow_hosts(
  self : TlsCertificate,
  engine : @engine.Engine,
  logger : @log.Logger,
) -> Unit {
  guard self.self_signed_names is Some(current) else { return }
  let names = self_signed_names(engine.status())
  if names == current {
    return
  }
  if generate_self_signed(names, logger) is Some(config) {
    self.config = config
    self.self_signed_names = Some(names)
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
