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
  /// The TLS port. 0 asks the system for a free port. smock listens on it
  /// only when `tls` is set.
  tls_port : Int
  /// The certificate and key files for the TLS port, or `None` when none
  /// are configured.
  tls : TlsFiles?
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
/// A setting or an argument was given a value it cannot take.
pub suberror InvalidSetting {
  InvalidSetting(
    flag~ : String,
    env~ : String,
    value~ : String,
    reason~ : String
  )
  InvalidArgument(name~ : String, value~ : String, reason~ : String)
} derive(Debug)

///|
/// What to tell the user, naming the setting by its flag and its variable,
/// such as `invalid value "x" for --port (SMOCK_PORT): must be ...`, or the
/// argument by its name, such as `invalid value "" for <dir>: ...`.
pub fn InvalidSetting::message(self : InvalidSetting) -> String {
  match self {
    InvalidSetting(flag~, env~, value~, reason~) =>
      "invalid value \{value.escape()} for --\{flag} (\{env}): \{reason}"
    InvalidArgument(name~, value~, reason~) =>
      "invalid value \{value.escape()} for <\{name}>: \{reason}"
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
    about: "The HTTPS port, served when --tls-cert-file and --tls-key-file are set. 0 picks a free port.",
    default: Some("8443"),
  },
  {
    name: "tls-cert-file",
    about: "The PEM certificate chain for the HTTPS port: the leaf certificate, then its intermediates.",
    default: None,
  },
  {
    name: "tls-key-file",
    about: "The PEM private key of the leaf certificate in --tls-cert-file.",
    default: None,
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
]

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
    about="Check a definitions directory as smock serve would load it. Prints every problem, one per line, and exits with status 1 if there is any.",
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
  let log_format = match value(matches, "log-format") {
    Some("json") => Json
    other => raise invalid("log-format", other.unwrap_or(""), "must be json")
  }
  let body_file_dir = body_file_dir(matches)
  {
    dir,
    port,
    tls_port,
    tls,
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
  }
}

///|
/// The largest size limit: 1 GiB. A request is held in memory whole.
let max_size : Int = 1024 * 1024 * 1024

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
  let reason = "must be an integer from \{min} to \{max}"
  // Decimal digits only: no sign, prefix or separator. Ten digits hold
  // every Int, and an Int64 holds every ten-digit number.
  if text == "" ||
    text.length() > 10 ||
    !text.iter().all(c => c >= '0' && c <= '9') {
    raise invalid(name, text, reason)
  }
  let n = text.fold(init=0L, (n, c) => {
    n * 10L + (c.to_int() - '0'.to_int()).to_int64()
  })
  if n < min.to_int64() || n > max.to_int64() {
    raise invalid(name, text, reason)
  }
  n.to_int()
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
