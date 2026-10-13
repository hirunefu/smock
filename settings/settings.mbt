///|
/// How smock writes its log entries.
pub(all) enum LogFormat {
  /// One JSON object per line.
  Json
} derive(Debug, Eq)

///|
/// The settings of `smock serve`. Every setting is a flag, such as
/// `--port`, with a matching environment variable, such as `SMOCK_PORT`. The
/// flag wins over the variable, and the variable over the default. Settings
/// never live in Definition files.
pub(all) struct ServeSettings {
  /// The definitions directory, or `None` for no Definition files.
  dir : String?
  /// The plain port. 0 asks the system for a free port.
  port : Int
  /// The TLS port. 0 asks the system for a free port.
  tls_port : Int
  /// The certificate and key files for the TLS port, or `None` when none
  /// are configured: smock then generates a self-signed certificate. It is
  /// the default certificate: a handshake gets it unless its SNI chooses one
  /// of `tls_mock_certs`.
  tls : TlsFiles?
  /// The certificate and key files of single Mocks, by Mock name: a
  /// handshake whose SNI is a Host of one of these Mocks gets its pair.
  tls_mock_certs : Map[String, TlsFiles]
  /// The admin port, where the Admin API, the probes and the metrics are
  /// served. 0 asks the system for a free port.
  admin_port : Int
  /// Whether the Admin API needs a bearer token.
  admin_auth : Bool
  /// The file that holds the Admin API token, if one is set. Without it, the
  /// token comes from the environment variable `SMOCK_ADMIN_TOKEN`.
  admin_token_file : String?
  /// How many replicas the deployment runs, as the Admin API's replica
  /// warning tells it.
  replicas : Int
  /// The request header that carries the Session, as W3C Baggage. Header
  /// names are compared case-insensitively.
  session_header : String
  /// The member of the Session header whose value is the Session key.
  session_member : String
  log_format : LogFormat
  /// The body-file subdirectory of the definitions directory.
  body_file_dir : String
  /// The most bytes a request head may take: its request line and header
  /// fields.
  header_size_limit : Int
  /// The most header fields a request may have.
  header_count_limit : Int
  /// The longest request body, in bytes.
  body_limit : Int
  /// How long, in milliseconds, a request may take to arrive, from its first
  /// byte to its last.
  read_timeout_ms : Int
  /// How long, in milliseconds, a connection may wait for its next request.
  idle_timeout_ms : Int
  /// How long, in milliseconds, smock may drain after SIGTERM before it
  /// cuts the responses, Server-Sent Event streams and delays still in
  /// progress and exits.
  drain_timeout_ms : Int
  /// The seed of the process generator, from 0 to 2^53 - 1, or `None` for
  /// one that smock picks at startup.
  seed : UInt64?
  /// Whether smock records requests in the Journal.
  journal : Bool
  /// The most entries the Journal holds.
  journal_max_entries : Int
  /// The most bytes the Journal's entries take, as they count them.
  journal_max_bytes : Int
  /// The most bytes of a request body a Journal entry keeps.
  journal_body_limit : Int
} derive(Debug)

///|
/// The PEM files the TLS port presents.
pub(all) struct TlsFiles {
  /// The certificate chain: the leaf certificate, then the certificates
  /// that issued it.
  cert_file : String
  /// The private key of the leaf certificate.
  key_file : String
} derive(Debug)

///|
/// The settings of `smock check`. The definitions directory is its
/// argument. The body-file subdirectory is the `smock serve` setting of the
/// same name, flag and variable, so that both read a directory the same
/// way.
pub(all) struct CheckSettings {
  /// The definitions directory.
  dir : String
  /// The body-file subdirectory of the definitions directory.
  body_file_dir : String
} derive(Debug)

///|
/// The settings of `smock render`. The definitions directory and the
/// body-file subdirectory are the `smock serve` settings of the same names,
/// flags and variables, so that both read a directory the same way. The
/// Stub ID is its argument, and the sample request, the time and the seed
/// are flags of its own, without variables: they belong to one rendering,
/// not to a process.
pub(all) struct RenderSettings {
  /// The definitions directory.
  dir : String
  /// The body-file subdirectory of the definitions directory.
  body_file_dir : String
  /// The ID of the Stub to render.
  stub : String
  /// The file that holds the sample request, as JSON.
  request_file : String
  /// The time the sample request is received at, in milliseconds since the
  /// Unix epoch, or `None` for now.
  time : Int64?
  /// The seed of the random source the rendering draws from, from 0 to
  /// 2^53 - 1, or `None` for a fresh one.
  seed : UInt64?
} derive(Debug)

///|
/// A setting or an argument was given a value it cannot take.
pub suberror InvalidSetting {
  InvalidSetting(
    flag~ : String,
    env~ : String,
    value~ : String,
    reason~ : String
  )
  InvalidArgument(name~ : String, value~ : String, reason~ : String)
  /// A flag without a variable.
  InvalidOption(flag~ : String, value~ : String, reason~ : String)
} derive(Debug)

///|
/// What to tell the user, naming the setting by its flag and its variable,
/// such as `invalid value "x" for --port (SMOCK_PORT): must be ...`, the
/// argument by its name, such as `invalid value "" for <dir>: ...`, or a
/// flag without a variable by the flag alone.
pub fn InvalidSetting::message(self : InvalidSetting) -> String {
  match self {
    InvalidSetting(flag~, env~, value~, reason~) =>
      "invalid value \{value.escape()} for --\{flag} (\{env}): \{reason}"
    InvalidArgument(name~, value~, reason~) =>
      "invalid value \{value.escape()} for <\{name}>: \{reason}"
    InvalidOption(flag~, value~, reason~) =>
      "invalid value \{value.escape()} for --\{flag}: \{reason}"
  }
}

///|
/// A setting: its name (the flag without `--`), what it does and its
/// default. Later settings are added to `serve_settings`.
priv struct Setting {
  name : String
  about : String
  default : String?
}

///|
let body_file_dir_setting : Setting = {
  name: "body-file-dir",
  about: "The body-file subdirectory of the definitions directory.",
  default: Some("files"),
}

///|
let serve_settings : Array[Setting] = [
  {
    name: "dir",
    about: "The definitions directory. Without it, smock serves one empty Default Mock.",
    default: None,
  },
  {
    name: "port",
    about: "The plain HTTP port. 0 picks a free port.",
    default: Some("8080"),
  },
  {
    name: "tls-port",
    about: "The HTTPS port, separate from the plain port. 0 picks a free port.",
    default: Some("8443"),
  },
  {
    name: "tls-cert-file",
    about: "The PEM certificate chain for the HTTPS port: the leaf certificate, then its intermediates. Without it and --tls-key-file, smock generates a self-signed certificate in memory for localhost, 127.0.0.1, ::1 and every Mock Host.",
    default: None,
  },
  {
    name: "tls-key-file",
    about: "The PEM private key of the leaf certificate in --tls-cert-file.",
    default: None,
  },
  {
    name: "tls-mock-certs",
    about: "Certificates of single Mocks, chosen by SNI: a JSON object that maps each Mock name to its PEM files, such as {\"users\":{\"certFile\":\"/certs/users/tls.crt\",\"keyFile\":\"/certs/users/tls.key\"}}. A handshake whose SNI is a Host of a listed Mock gets that Mock's certificate; any other gets the default certificate: --tls-cert-file, or without it the self-signed one. Empty by default.",
    default: None,
  },
  {
    name: "admin-port",
    about: "The Admin API port, separate from the plain and TLS ports. 0 picks a free port.",
    default: Some("9090"),
  },
  {
    name: "admin-auth",
    about: "Whether the Admin API needs a bearer token: on or off. Turn it off only for local use.",
    default: Some("on"),
  },
  {
    name: "admin-token-file",
    about: "A file that holds the Admin API token. Without it, the token comes from the environment variable SMOCK_ADMIN_TOKEN.",
    default: None,
  },
  {
    name: "replicas",
    about: "How many replicas the deployment runs. Above 1, every Admin API response warns that state is per replica.",
    default: Some("1"),
  },
  {
    name: "session-header",
    about: "The request header that carries the Session, as W3C Baggage, on requests and Admin API calls.",
    default: Some("baggage"),
  },
  {
    name: "session-member",
    about: "The member of the Session header whose value is the Session key.",
    default: Some("smock-session"),
  },
  { name: "log-format", about: "The log format: json.", default: Some("json"), },
  body_file_dir_setting,
  {
    name: "header-size-limit",
    about: "The most bytes a request head (request line and header fields) may take. Larger heads get 431.",
    default: Some("16384"),
  },
  {
    name: "header-count-limit",
    about: "The most header fields a request may have. More get 431.",
    default: Some("100"),
  },
  {
    name: "body-limit",
    about: "The longest request body, in bytes. Longer bodies get 413.",
    default: Some("10485760"),
  },
  {
    name: "read-timeout-ms",
    about: "How long a request may take to arrive, in milliseconds, from its first byte to its last. Then the connection closes.",
    default: Some("30000"),
  },
  {
    name: "idle-timeout-ms",
    about: "How long a connection may wait for a request, in milliseconds. Then it closes.",
    default: Some("60000"),
  },
  {
    name: "drain-timeout-ms",
    about: "How long smock may drain after SIGTERM, in milliseconds: responses in progress, Server-Sent Event streams and delays still running then are cut, and smock exits.",
    default: Some("20000"),
  },
  {
    name: "seed",
    about: "The seed of the process random generator, from 0 to \{max_seed}. Faults of Stubs without their own seed draw from it. Without it, smock picks a seed at startup and logs it.",
    default: None,
  },
  {
    name: "journal",
    about: "Whether smock records the requests it receives in the Journal: on or off. Off, it records none, and Journal queries are refused.",
    default: Some(if journal_defaults.enabled { "on" } else { "off" }),
  },
  {
    name: "journal-max-entries",
    about: "The most entries the Journal holds. Beyond it, the oldest entries are evicted.",
    default: Some(journal_defaults.max_entries.to_string()),
  },
  {
    name: "journal-max-bytes",
    about: "The most bytes the Journal's entries take: each counts 256, two per character of its request line, header fields, names and Near miss values, and the body bytes it keeps. Beyond it, the oldest entries are evicted.",
    default: Some(journal_defaults.max_bytes.to_string()),
  },
  {
    name: "journal-body-limit",
    about: "The most bytes of a request body a Journal entry keeps; the rest is cut.",
    default: Some(journal_defaults.body_limit.to_string()),
  },
]

///|
/// The Journal settings the engine has by default, which the Journal
/// settings default to.
let journal_defaults : @engine.JournalSettings = @engine.JournalSettings()

///|
/// The settings of `smock check`: those of `smock serve` that decide how
/// the definitions directory is read.
let check_settings : Array[Setting] = [body_file_dir_setting]

///|
/// The environment variable of a setting: `SMOCK_` and its name in upper
/// case, with `_` for `-`.
fn env_name(name : String) -> String {
  "SMOCK_" + name.to_upper().replace_all(old="-", new="_")
}

///|
/// The `serve` subcommand, with a flag and a variable for every setting.
pub fn serve_command() -> @argparse.Command {
  @argparse.Command(
    "serve",
    about="Serve the Mocks and Stubs of a definitions directory.",
    options=serve_settings.map(option),
  )
}

///|
/// The `check` subcommand: the definitions directory as its argument, and
/// a flag and a variable for every setting.
pub fn check_command() -> @argparse.Command {
  @argparse.Command(
    "check",
    about="Check a definitions directory as smock serve would load it. Prints every problem, one per line, and exits with status 1 if there is any. Also warns about Stubs that can never match; warnings do not change the exit status.",
    positionals=[
      @argparse.PositionArg(
        "dir",
        about="The definitions directory.",
        num_args=@argparse.ValueRange::single(),
      ),
    ],
    options=check_settings.map(option),
  )
}

///|
/// The `render` subcommand: the Stub ID as its argument, the definitions
/// directory and the body-file subdirectory as `smock serve` takes them,
/// and the sample request, the time and the seed.
pub fn render_command() -> @argparse.Command {
  @argparse.Command(
    "render",
    about="Render a Stub's response for a sample request, as the Admin API render operation does, and print it as JSON: the time and the seed it used, the status, the headers and the body or events, rendered from the Stub's templates when it has them, and the Stub's conditions the sample fails, with expected and actual values. Exits with status 1 if the definitions directory is invalid, no Stub has the ID, or the sample request is not valid.",
    positionals=[
      @argparse.PositionArg(
        "stub-id",
        about="The ID of a Stub from the Definition files.",
        num_args=@argparse.ValueRange::single(),
      ),
    ],
    options=[
      @argparse.OptionArg(
        "dir",
        long="dir",
        env=env_name("dir"),
        about="The definitions directory, read as smock serve reads it.",
        required=true,
      ),
      option(body_file_dir_setting),
      @argparse.OptionArg(
        "request",
        long="request",
        about="A file that holds the sample request as JSON: {method, path, query, headers, body, session}, each optional.",
        required=true,
      ),
      @argparse.OptionArg(
        "time",
        long="time",
        about="The time the sample request is received at, as an RFC 3339 date-time such as 2026-10-12T14:30:05Z. Default: now.",
      ),
      @argparse.OptionArg(
        "seed",
        long="seed",
        about="The seed of the random source the rendering draws from, from 0 to \{max_seed}. Default: the Stub's fault.seed, or a fresh seed when it has none.",
      ),
    ],
  )
}

///|
/// The option of `setting`: its flag and its variable.
fn option(setting : Setting) -> @argparse.OptionArg {
  @argparse.OptionArg(
    setting.name,
    long=setting.name,
    env=env_name(setting.name),
    about=setting.about,
    default_values=match setting.default {
      Some(value) => [value]
      None => []
    },
  )
}

///|
/// Reads and checks the settings from the parsed `serve` subcommand.
pub fn ServeSettings::from_matches(
  matches : @argparse.Matches,
) -> ServeSettings raise InvalidSetting {
  let dir = match value(matches, "dir") {
    Some(dir) => {
      if dir == "" {
        raise invalid("dir", dir, "must not be empty")
      }
      Some(dir)
    }
    None => None
  }
  let port = int_value(matches, "port", min=0, max=65535)
  let tls_port = int_value(matches, "tls-port", min=0, max=65535)
  if tls_port != 0 && tls_port == port {
    raise invalid(
      "tls-port",
      tls_port.to_string(),
      "must differ from --port (SMOCK_PORT)",
    )
  }
  let tls = match
    (file_value(matches, "tls-cert-file"), file_value(matches, "tls-key-file")) {
    (Some(cert_file), Some(key_file)) => Some({ cert_file, key_file, })
    (None, None) => None
    (Some(cert_file), None) =>
      raise invalid(
        "tls-cert-file",
        cert_file,
        "needs --tls-key-file (\{env_name("tls-key-file")}) as well",
      )
    (None, Some(key_file)) =>
      raise invalid(
        "tls-key-file",
        key_file,
        "needs --tls-cert-file (\{env_name("tls-cert-file")}) as well",
      )
  }
  let tls_mock_certs = mock_certs_value(matches, "tls-mock-certs")
  let admin_port = int_value(matches, "admin-port", min=0, max=65535)
  if admin_port != 0 && admin_port == port {
    raise invalid(
      "admin-port",
      admin_port.to_string(),
      "must differ from --port (SMOCK_PORT)",
    )
  }
  if admin_port != 0 && admin_port == tls_port {
    raise invalid(
      "admin-port",
      admin_port.to_string(),
      "must differ from --tls-port (SMOCK_TLS_PORT)",
    )
  }
  let admin_auth = on_off_value(matches, "admin-auth")
  let admin_token_file = file_value(matches, "admin-token-file")
  let log_format = match value(matches, "log-format") {
    Some("json") => Json
    other => raise invalid("log-format", other.unwrap_or(""), "must be json")
  }
  let body_file_dir = body_file_dir(matches)
  let session_header = token_value(
    matches, "session-header", "must be a header name, such as baggage",
  )
  let session_member = token_value(
    matches, "session-member", "must be a W3C Baggage key, such as smock-session",
  )
  {
    dir,
    port,
    tls_port,
    tls,
    tls_mock_certs,
    admin_port,
    admin_auth,
    admin_token_file,
    replicas: int_value(matches, "replicas", min=1, max=max_replicas),
    session_header,
    session_member,
    log_format,
    body_file_dir,
    header_size_limit: int_value(
      matches,
      "header-size-limit",
      min=1,
      max=max_size,
    ),
    header_count_limit: int_value(
      matches,
      "header-count-limit",
      min=1,
      max=max_size,
    ),
    body_limit: int_value(matches, "body-limit", min=0, max=max_size),
    read_timeout_ms: int_value(
      matches,
      "read-timeout-ms",
      min=1,
      max=max_duration_ms,
    ),
    idle_timeout_ms: int_value(
      matches,
      "idle-timeout-ms",
      min=1,
      max=max_duration_ms,
    ),
    drain_timeout_ms: int_value(
      matches,
      "drain-timeout-ms",
      min=0,
      max=max_duration_ms,
    ),
    seed: seed_value(matches, "seed"),
    journal: on_off_value(matches, "journal"),
    journal_max_entries: int_value(
      matches,
      "journal-max-entries",
      min=1,
      max=max_size,
    ),
    journal_max_bytes: int_value(
      matches,
      "journal-max-bytes",
      min=1,
      max=max_size,
    ),
    journal_body_limit: int_value(
      matches,
      "journal-body-limit",
      min=0,
      max=max_size,
    ),
  }
}

///|
/// The value of the per-Mock certificates setting: a JSON object that maps
/// each Mock name to `{"certFile": <path>, "keyFile": <path>}`. Without it,
/// no Mock has a certificate of its own.
fn mock_certs_value(
  matches : @argparse.Matches,
  name : String,
) -> Map[String, TlsFiles] raise InvalidSetting {
  guard value(matches, name) is Some(text) else { return Map([]) }
  let entry_format = "{\"certFile\": <path>, \"keyFile\": <path>}"
  let not_a_map = "must be a JSON object that maps each Mock name to \{entry_format}"
  let json = @json.parse(text) catch {
    _ => raise invalid(name, text, not_a_map)
  }
  guard json is Object(entries) else { raise invalid(name, text, not_a_map) }
  let out : Map[String, TlsFiles] = Map([])
  for mock, entry in entries {
    if mock == "" {
      raise invalid(name, text, "a Mock name must not be empty")
    }
    guard entry is Object(fields) &&
      fields.length() == 2 &&
      fields.get("certFile") is Some(String(cert_file)) &&
      fields.get("keyFile") is Some(String(key_file)) &&
      cert_file != "" &&
      key_file != "" else {
      raise invalid(
        name,
        text,
        "the entry of the Mock \{mock.escape()} must be \{entry_format}, with paths that are not empty",
      )
    }
    out[mock] = { cert_file, key_file, }
  }
  out
}

///|
/// The largest seed, as in Definition files.
let max_seed : UInt64 = @definitions.max_seed

///|
/// The value of a seed setting, when given: a decimal integer from 0 to
/// `max_seed`.
fn seed_value(
  matches : @argparse.Matches,
  name : String,
) -> UInt64? raise InvalidSetting {
  guard value(matches, name) is Some(text) else { return None }
  match parse_seed(text) {
    Some(seed) => Some(seed)
    None => raise invalid(name, text, seed_reason())
  }
}

///|
/// Why a value is not a seed.
fn seed_reason() -> String {
  "must be an integer from 0 to \{max_seed}"
}

///|
/// The seed `text` gives: a decimal integer from 0 to 2^53 - 1, without a
/// sign, prefix or separator. `None` when it is not one.
pub fn parse_seed(text : String) -> UInt64? {
  // Sixteen digits hold every seed.
  match decimal(text, max_digits=16) {
    Some(n) if n <= max_seed => Some(n)
    _ => None
  }
}

///|
/// A fresh seed from the platform's entropy, from 0 to 2^53 - 1, like the
/// seeds `--seed` takes: what `smock serve`, `smock render` and the Admin
/// render operation use when no seed is given.
pub fn random_seed() -> UInt64 {
  // What Rand::new() does, written out: MoonBit 0.10.15 deprecates it for
  // Rand(), which 0.10.14 does not have. Without entropy (wasm-gc has
  // none), ChaCha8 falls back to its fixed default seed, as Rand::new() did.
  let rand = match @env.rand(32) {
    Some(seed) => @random.Rand::chacha8(seed~)
    None => @random.Rand::chacha8()
  }
  // max_seed is 2^53 - 1, all ones in binary.
  rand.uint64() & max_seed
}

///|
/// The number `text` writes in at most `max_digits` decimal digits, without
/// a sign, prefix or separator, or `None` when it is not one. A UInt64
/// holds every number of up to 19 digits.
fn decimal(text : String, max_digits~ : Int) -> UInt64? {
  if text == "" ||
    text.length() > max_digits ||
    !text.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  Some(
    text.fold(init=0UL, (n, c) => {
      n * 10UL + (c.to_int() - '0'.to_int()).to_uint64()
    }),
  )
}

///|
/// The largest size limit: 1 GiB. A request is held in memory whole.
let max_size : Int = 1024 * 1024 * 1024

///|
/// The most replicas a deployment can declare.
let max_replicas : Int = 10000

///|
/// The longest timeout, in milliseconds: the largest `Int`, about 24 days.
let max_duration_ms : Int = 0x7fffffff

///|
/// Reads and checks the settings from the parsed `check` subcommand.
pub fn CheckSettings::from_matches(
  matches : @argparse.Matches,
) -> CheckSettings raise InvalidSetting {
  let dir = value(matches, "dir").unwrap_or("")
  if dir == "" {
    raise InvalidArgument(name="dir", value=dir, reason="must not be empty")
  }
  { dir, body_file_dir: body_file_dir(matches), }
}

///|
/// Reads and checks the settings from the parsed `render` subcommand.
pub fn RenderSettings::from_matches(
  matches : @argparse.Matches,
) -> RenderSettings raise InvalidSetting {
  let dir = value(matches, "dir").unwrap_or("")
  if dir == "" {
    raise invalid("dir", dir, "must not be empty")
  }
  let request_file = value(matches, "request").unwrap_or("")
  if request_file == "" {
    raise InvalidOption(
      flag="request",
      value=request_file,
      reason="must not be empty",
    )
  }
  let time = match value(matches, "time") {
    None => None
    Some(text) =>
      match @log.parse_time(text) {
        Some(time) => Some(time)
        None =>
          raise InvalidOption(
            flag="time",
            value=text,
            reason="must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z",
          )
      }
  }
  let seed = match value(matches, "seed") {
    None => None
    Some(text) =>
      match parse_seed(text) {
        Some(seed) => Some(seed)
        None =>
          raise InvalidOption(flag="seed", value=text, reason=seed_reason())
      }
  }
  {
    dir,
    body_file_dir: body_file_dir(matches),
    stub: value(matches, "stub-id").unwrap_or(""),
    request_file,
    time,
    seed,
  }
}

///|
fn body_file_dir(matches : @argparse.Matches) -> String raise InvalidSetting {
  let dir = value(matches, "body-file-dir").unwrap_or("")
  if !is_inner_relative_path(dir) {
    raise invalid(
      "body-file-dir", dir, "must be a relative path inside the definitions directory",
    )
  }
  dir
}

///|
fn value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => values.last()
    None => None
  }
}

///|
/// The value of a setting that must be an HTTP token, as header names and
/// W3C Baggage keys are, or `reason` when it is not.
fn token_value(
  matches : @argparse.Matches,
  name : String,
  reason : String,
) -> String raise InvalidSetting {
  let text = value(matches, name).unwrap_or("")
  if !@http1.is_token(text) {
    raise invalid(name, text, reason)
  }
  text
}

///|
/// The value of a file setting, which must not be empty when given.
fn file_value(
  matches : @argparse.Matches,
  name : String,
) -> String? raise InvalidSetting {
  match value(matches, name) {
    Some("") => raise invalid(name, "", "must not be empty")
    other => other
  }
}

///|
fn int_value(
  matches : @argparse.Matches,
  name : String,
  min~ : Int,
  max~ : Int,
) -> Int raise InvalidSetting {
  let text = value(matches, name).unwrap_or("")
  // Ten digits hold every Int.
  match decimal(text, max_digits=10).map(n => n.reinterpret_as_int64()) {
    Some(n) if n >= min.to_int64() && n <= max.to_int64() => n.to_int()
    _ => raise invalid(name, text, "must be an integer from \{min} to \{max}")
  }
}

///|
/// The value of a setting that is `on` or `off`, as true or false.
fn on_off_value(
  matches : @argparse.Matches,
  name : String,
) -> Bool raise InvalidSetting {
  match value(matches, name) {
    Some("on") => true
    Some("off") => false
    other => raise invalid(name, other.unwrap_or(""), "must be on or off")
  }
}

///|
fn invalid(name : String, value : String, reason : String) -> InvalidSetting {
  InvalidSetting(flag=name, env=env_name(name), value~, reason~)
}

///|
/// Whether `path` is a relative path that stays inside the directory it is
/// relative to: one or more `/`-separated names, none of them empty, `.` or
/// `..`.
fn is_inner_relative_path(path : String) -> Bool {
  path != "" &&
  path.split("/").all(part => part != "" && part != "." && part != "..")
}
