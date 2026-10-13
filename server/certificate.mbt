// The self-signed certificate the TLS port presents by default when no
// default certificate files are configured: smock generates it in memory,
// for local use, for the Hosts it serves.

///|
/// How many days a generated certificate is valid. smock generates a new
/// one at every start, and clients limit how long a server certificate may
/// be valid (398 days for some).
const SELF_SIGNED_DAYS = 365

///|
/// A self-signed certificate smock generated, loaded for the TLS port.
priv struct SelfSignedCertificate {
  /// What new handshakes get.
  mut config : @openssl.ServerConfig
  /// The names it covers.
  mut names : Array[String]
  /// Its series of the expiry metric, the default certificate's.
  expiry : @metrics.GaugeSeries
}

///|
/// A self-signed certificate for the Hosts `engine` serves, whose expiry
/// `expiry`, the default certificate's series of the expiry metric,
/// reports. Returns `None` when it cannot be generated, which is logged.
fn SelfSignedCertificate::generate(
  engine : @engine.Engine,
  logger : @log.Logger,
  expiry : @metrics.GaugeSeries,
) -> SelfSignedCertificate? {
  let names = self_signed_names(engine.status())
  generate_self_signed(names, logger).map(generated => {
    let (config, certificate) = generated
    set_self_signed_expiry(expiry, certificate)
    { config, names, expiry, }
  })
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
  if generate_self_signed(names, logger) is Some((config, certificate)) {
    self.config = config
    self.names = names
    set_self_signed_expiry(self.expiry, certificate)
  }
}

///|
/// Sets `expiry` to when `certificate`, a generated certificate in PEM,
/// expires.
fn set_self_signed_expiry(
  expiry : @metrics.GaugeSeries,
  certificate : Bytes,
) -> Unit {
  if certificate_expiry(certificate) is Some(ms) {
    expiry.set(ms.to_double() / 1000.0)
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
/// names. Returns the configuration that presents it and the certificate,
/// in PEM, or `None` when it cannot, which is logged instead.
fn generate_self_signed(
  names : Array[String],
  logger : @log.Logger,
) -> (@openssl.ServerConfig, Bytes)? {
  try {
    let generated = @openssl.SelfSigned::generate(names, days=SELF_SIGNED_DAYS)
    let config = @openssl.ServerConfig(
      certificate_chain=generated.certificate,
      private_key=generated.private_key,
      alpn~,
    )
    (config, generated.certificate, generated.sha256_fingerprint)
  } catch {
    err => {
      logger.error("cannot generate a self-signed certificate", fields={
        "error": Json::string(err.message()),
      })
      None
    }
  } noraise {
    (config, certificate, fingerprint) => {
      logger.info("self-signed certificate in use", fields={
        "sha256Fingerprint": Json::string(fingerprint),
        "names": Json::array(names.map(name => Json::string(name))),
      })
      Some((config, certificate))
    }
  }
}
