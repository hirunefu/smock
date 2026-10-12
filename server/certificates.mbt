// The certificates the TLS port presents: the default certificate, and the
// certificates of single Mocks, which SNI chooses. Each certificate and key
// file pair is read again when its directory changes, as the Definition
// files are, and a new pair that can be used replaces the one presented:
// new handshakes get it, while open connections keep the one they started
// with. A new pair that cannot be used is not swapped in.

///|
/// One certificate and key file pair that the TLS port presents.
priv struct Pair {
  /// The Mock it is for, or "" for the default certificate, as the expiry
  /// metric and the log entries name it.
  mock : String
  files : @settings.TlsFiles
  /// What new handshakes get: the pair as loaded last.
  mut config : @openssl.ServerConfig
  /// The files as read last, or why they could not be read, so that a pair
  /// is loaded again only when its files change.
  mut last_read : Result[(Bytes, Bytes), String]
  /// Its series of the expiry metric.
  expiry : @metrics.GaugeSeries
}

///|
/// The certificates of the TLS port.
priv struct Certificates {
  default : Pair
  /// The pairs of single Mocks, by Mock name.
  by_mock : Map[String, Pair]
  /// Which Mock an SNI name belongs to comes from the definition set it
  /// serves.
  engine : @engine.Engine
  logger : @log.Logger
  /// Serialises the checks of the files, which several watches start.
  checking : @async.Mutex
  /// The Mocks of `by_mock` that the definition set served does not
  /// declare, as last warned about.
  mut undeclared : Array[String]
}

///|
/// Loads the default pair, `default`, and the pair of each Mock in
/// `by_mock`, and registers the expiry metric in `metrics`. When a pair
/// cannot be loaded, it logs why and returns `None`: smock then does not
/// start. Warns about each Mock in `by_mock` that `engine` does not serve.
async fn Certificates::load(
  default : @settings.TlsFiles,
  by_mock : Map[String, @settings.TlsFiles],
  engine~ : @engine.Engine,
  logger~ : @log.Logger,
  metrics~ : @metrics.Registry,
) -> Certificates? {
  let expiry = metrics.gauge(
    "smock_tls_certificate_expiry_timestamp_seconds",
    help="When each certificate the TLS port presents expires (its notAfter), in seconds since the Unix epoch, by the Mock it is for: mock=\"\" for the default certificate.",
    labels=["mock"],
  )
  guard Pair::load("", default, expiry, logger) is Some(default) else {
    return None
  }
  let pairs = Map([])
  for mock, files in by_mock {
    guard Pair::load(mock, files, expiry, logger) is Some(pair) else {
      return None
    }
    pairs[mock] = pair
  }
  let self = {
    default,
    by_mock: pairs,
    engine,
    logger,
    checking: @async.Mutex(),
    undeclared: [],
  }
  self.warn_undeclared()
  Some(self)
}

///|
/// Reads and loads the pair of `mock` ("" for the default certificate) from
/// `files`, and sets its series of the expiry metric. Logs why it cannot be
/// loaded, and returns `None`, when it cannot.
async fn Pair::load(
  mock : String,
  files : @settings.TlsFiles,
  expiry : @metrics.Gauge,
  logger : @log.Logger,
) -> Pair? {
  let read = read_pair(files)
  let loaded = match read {
    Ok((cert, key)) => load_pair(cert, key)
    Err(reason) => Err(reason)
  }
  match loaded {
    Ok(config) => {
      let pair = {
        mock,
        files,
        config,
        last_read: read,
        expiry: expiry.labels([mock]),
      }
      pair.set_expiry()
      Some(pair)
    }
    Err(reason) => {
      let fields : Map[String, Json] = Map([])
      if mock != "" {
        fields["mock"] = Json::string(mock)
      }
      fields["cert_file"] = Json::string(files.cert_file)
      fields["key_file"] = Json::string(files.key_file)
      fields["error"] = Json::string(reason)
      logger.error("cannot load the TLS certificate", fields~)
      None
    }
  }
}

///|
/// Sets the expiry metric to the expiry of the certificate as read last.
fn Pair::set_expiry(self : Pair) -> Unit {
  if self.last_read is Ok((cert, _)) && certificate_expiry(cert) is Some(expiry) {
    self.expiry.set(expiry.to_double() / 1000.0)
  }
}

///|
/// The directories that hold the certificate and key files of `pairs`:
/// each one is watched.
fn tls_dirs(pairs : Array[@settings.TlsFiles]) -> Array[String] {
  let dirs = []
  for files in pairs {
    for path in [files.cert_file, files.key_file] {
      let dir = match path.rev_find("/") {
        None => "."
        Some(0) => "/"
        Some(i) => path[:i].to_owned()
      }
      if !dirs.contains(dir) {
        dirs.push(dir)
      }
    }
  }
  dirs
}

///|
/// The configuration a new handshake gets when the client asks for
/// `server_name` by SNI: the pair of the Mock whose Hosts include the name,
/// compared as Host resolution compares Hosts, if that Mock has one, and
/// the default certificate otherwise.
fn Certificates::select(
  self : Certificates,
  server_name : String?,
) -> @openssl.ServerConfig {
  if !self.by_mock.is_empty() &&
    server_name is Some(name) &&
    self.engine.mock_for_host(name) is Some(mock) &&
    self.by_mock.get(mock) is Some(pair) {
    pair.config
  } else {
    self.default.config
  }
}

///|
/// Warns about each Mock with a pair of its own that the definition set
/// served does not declare: its pair is chosen for nothing until a reload
/// declares it. A Mock is warned about once each time it goes missing.
fn Certificates::warn_undeclared(self : Certificates) -> Unit {
  let declared = self.engine.status().mocks.map(mock => mock.name)
  let undeclared = []
  for mock, pair in self.by_mock {
    if declared.contains(mock) {
      continue
    }
    undeclared.push(mock)
    if !self.undeclared.contains(mock) {
      self.logger.warn("TLS certificate for a Mock that is not declared", fields={
        "mock": Json::string(mock),
        "cert_file": Json::string(pair.files.cert_file),
        "key_file": Json::string(pair.files.key_file),
      })
    }
  }
  self.undeclared = undeclared
}

///|
/// Checks every pair on each check of `watch`, the watch of `dir`, a
/// directory that holds certificate or key files, until the task is
/// cancelled. Logs a warning when the directory cannot be watched, and is
/// only polled.
async fn Certificates::run(
  self : Certificates,
  dir : String,
  watch : @watch.Watch,
) -> Unit {
  watch.run(async fn(_) { self.check() }, on_error=err => {
    self.logger.warn(
      "cannot watch the TLS certificate directory, only polling it",
      fields={
        "dir": Json::string(dir),
        "error": Json::string(err.to_string()),
      },
    )
  })
}

///|
/// Reads every pair again, and loads each one whose files changed. A check
/// that fails in an unforeseen way is logged, and the next one tries again.
async fn Certificates::check(self : Certificates) -> Unit {
  self.checking.acquire()
  defer self.checking.release()
  for pair in [self.default, ..self.by_mock.values()] {
    self.check_pair(pair) catch {
      err =>
        self.logger.error("TLS certificate reload failed", fields={
          "mock": Json::string(pair.mock),
          "cert_file": Json::string(pair.files.cert_file),
          "key_file": Json::string(pair.files.key_file),
          "error": Json::string(err.to_string()),
        })
    }
  }
}

///|
/// Reads `pair` again, and when its files changed, loads them and swaps
/// them in, or keeps presenting the pair loaded before when they cannot be
/// used. Either way, one log entry names the pair and the new expiry.
async fn Certificates::check_pair(self : Certificates, pair : Pair) -> Unit {
  let read = read_pair(pair.files)
  if read == pair.last_read {
    return
  }
  pair.last_read = read
  let (loaded, expiry) = match read {
    Ok((cert, key)) => (load_pair(cert, key), certificate_expiry(cert))
    Err(reason) => (Err(reason), None)
  }
  let fields : Map[String, Json] = {
    "mock": Json::string(pair.mock),
    "cert_file": Json::string(pair.files.cert_file),
    "key_file": Json::string(pair.files.key_file),
    "expiry": match expiry {
      Some(ms) => Json::string(@log.format_time(ms))
      None => Json::null()
    },
  }
  match loaded {
    Ok(config) => {
      pair.config = config
      pair.set_expiry()
      self.logger.info("TLS certificate reloaded", fields~)
    }
    Err(reason) => {
      fields["error"] = Json::string(reason)
      self.logger.error("TLS certificate reload failed", fields~)
    }
  }
}
