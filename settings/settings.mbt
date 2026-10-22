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
  /// The environment variables templates may read, as `--template-env`
  /// lists them: each name once, in the order given.
  template_env : Array[String]
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
  /// The most bytes the Journal's entries take, as they count them, when
  /// `--journal-max-bytes` or `SMOCK_JOURNAL_MAX_BYTES` sets it. `None`
  /// leaves it to the memory limit, which `smock serve` reads at startup
  /// (`ByteBound::journal`).
  journal_max_bytes : ByteBound?
  /// The most bytes of a request body a Journal entry keeps.
  journal_body_limit : Int
  /// The most bytes the per-Session state of the whole process takes, as
  /// it counts them, when `--state-max-bytes` or `SMOCK_STATE_MAX_BYTES`
  /// sets it. `None` leaves it to the memory limit, which `smock serve`
  /// reads at startup (`ByteBound::state`).
  state_max_bytes : ByteBound?
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
/// argument. The body-file subdirectory and the environment variables
/// templates may read are the `smock serve` settings of the same names,
/// flags and variables, so that both load a directory the same way.
pub(all) struct CheckSettings {
  /// The definitions directory.
  dir : String
  /// The body-file subdirectory of the definitions directory.
  body_file_dir : String
  /// The environment variables templates may read, as `--template-env`
  /// lists them: each name once, in the order given.
  template_env : Array[String]
} derive(Debug)

///|
/// The settings of `smock render`. The definitions directory, the
/// body-file subdirectory and the environment variables templates may read
/// are the `smock serve` settings of the same names, flags and variables,
/// so that both load a directory the same way. The Stub ID is its argument,
/// and the sample request, the time, the seed and the response are flags of
/// its own, without variables: they belong to one rendering, not to a
/// process.
pub(all) struct RenderSettings {
  /// The definitions directory.
  dir : String
  /// The body-file subdirectory of the definitions directory.
  body_file_dir : String
  /// The environment variables templates may read, as `--template-env`
  /// lists them: each name once, in the order given.
  template_env : Array[String]
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
  /// The index of the response to render among the Stub's `responses`,
  /// or `None` for the one the seed picks.
  response_index : Int?
} derive(Debug)

///|
/// The settings of `smock import-openapi`. The OpenAPI document is its
/// argument, and the Mock, its Hosts, whether the file declares it, the
/// directory references are followed in, the output, the base path and
/// whether the output may be replaced are flags of its own, without
/// variables: they belong to one import, not to a process.
pub(all) struct ImportOpenapiSettings {
  /// The OpenAPI document, a JSON or YAML file, as given.
  document : String
  /// The directory that references to other files are followed in, as
  /// given, or `None` for the document's own directory. The document lies
  /// under it, which the CLI checks, since it takes the file system.
  ref_dir : String?
  /// The name of the Mock the Definition file declares.
  mock : String
  /// The Hosts the Mock is declared with, as given, in that order: each
  /// one a Definition file can declare, and none the same as another once
  /// normalised. Empty when none is given.
  hosts : Array[String]
  /// Whether the Definition file declares the Mock. When it does not, it
  /// holds only Stubs, for a Mock declared by hand in another file, and
  /// `hosts` is empty.
  declare_mock : Bool
  /// The Definition file to write, a JSON or YAML file, as given. Its name
  /// picks the format.
  output : String
  /// The path put in front of every path in place of the paths of the
  /// document's servers, as given: it starts with `/` and holds no `?` or
  /// `#`. `None` when it is not given, so that the servers' paths are used.
  base_path : String?
  /// Whether an existing regular file at `output` is replaced.
  overwrite : Bool
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
/// The body-file subdirectory: a setting of smock serve that smock check
/// and smock render share, as they share `template_env_setting`.
let body_file_dir_setting : Setting = {
  name: "body-file-dir",
  about: "The body-file subdirectory of the definitions directory.",
  default: Some("files"),
}

///|
/// The environment variables templates may read: a setting of smock serve
/// that smock check and smock render share, so that all three load a
/// directory the same way.
let template_env_setting : Setting = {
  name: "template-env",
  about: "The environment variables templates may read as env.NAME, separated by commas, such as REGION,API_BASE. Their values are read once, at startup. A listed value can show in responses, renderings and template error messages, so list only values that may be shown. A name is letters, digits and _, starting with a letter or _, and cannot start with SMOCK_. None by default.",
  default: None,
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
  template_env_setting,
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
    about: "The most bytes the Journal's entries take: each counts 256, two per character of its request line, header fields, names and Near miss values, 32 per value its Near miss keeps from a form or an XML body, and the body bytes it keeps. Beyond it, the oldest entries are evicted. Default: a quarter of the memory limit of smock's cgroup (cgroup v2 memory.max), at least \{min_byte_bound} (1 MiB) and at most \{journal_defaults.max_bytes} (64 MiB); \{journal_defaults.max_bytes} when there is no limit or it cannot be read.",
    default: None,
  },
  {
    name: "journal-body-limit",
    about: "The most bytes of a request body a Journal entry keeps; the rest is cut. Its Near miss keeps the values of form fields and XML paths up to the same total, each counting 32 bytes more.",
    default: Some(journal_defaults.body_limit.to_string()),
  },
  {
    name: "state-max-bytes",
    about: "The most bytes the per-Session state of the whole process takes, across every Mock and Session: each Mock and Session that holds Variables counts its Mock name, its Session key and 64; each Variable counts its name, 64, and its value as compact JSON with 16 more per JSON value in it. A request or an Admin API set whose writes would pass it writes nothing and gets 507. Scenario state does not count. Default: an eighth of the memory limit of smock's cgroup (cgroup v2 memory.max), at least \{min_byte_bound} (1 MiB) and at most \{@engine.default_state_max_bytes} (64 MiB); \{@engine.default_state_max_bytes} when there is no limit or it cannot be read.",
    default: None,
  },
]

///|
/// The Journal settings the engine has by default, which the Journal
/// settings default to.
let journal_defaults : @engine.JournalSettings = @engine.JournalSettings()

///|
/// The settings of `smock check`: those of `smock serve` that decide how
/// the definitions directory is loaded.
let check_settings : Array[Setting] = [
  body_file_dir_setting, template_env_setting,
]

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
    about="Check a definitions directory as smock serve would load it. Prints every problem, one per line, and exits with status 1 if there is any. Also warns about Stubs that can never match, and about states that a Stub requires but no Stub moves its Scenario to; warnings do not change the exit status.",
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
/// directory, the body-file subdirectory and the environment variables
/// templates may read as `smock serve` takes them, and the sample request,
/// the time, the seed and the response.
pub fn render_command() -> @argparse.Command {
  @argparse.Command(
    "render",
    about="Render a Stub's response for a sample request, as the Admin API render operation does, and print it as JSON: the time and the seed it used, the status, the headers and the body or events, rendered from the Stub's templates when it has them, and the Stub's conditions the sample fails, with expected and actual values. A Stub with responses renders the response the seed picks, or the one --response names, and the output shows its index. The sample may give data, values of the Data buckets of the Stub's Mock, which are read in place of their initial values. The output shows the values the Stub's variables would write, rendered against the sample's vars, and, as dataWrites, the writes the Stub would make; nothing is written. A CRUD Stub renders the answer its operation would give to the sample. Exits with status 1 if the definitions directory is invalid, no Stub has the ID, the Stub has no response at the index given, the sample request is not valid, the sample's data names a Data bucket the Mock does not declare or breaks a keyed bucket's rules, or the sample fits no operation of a CRUD Stub.",
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
      option(template_env_setting),
      @argparse.OptionArg(
        "request",
        long="request",
        about="A file that holds the sample request as JSON: {method, path, query, headers, body, session, vars, data}, each optional.",
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
      @argparse.OptionArg(
        "response",
        long="response",
        about="The index of the response to render among the Stub's responses, from 0. A Stub with response takes 0 only. Default: the response the seed picks.",
      ),
    ],
  )
}

///|
/// The `import-openapi` subcommand: the OpenAPI document as its argument,
/// and the Mock, its Hosts, whether to declare it, the directory that
/// references are followed in, the output, the base path and whether to
/// replace the output as flags without variables.
pub fn import_openapi_command() -> @argparse.Command {
  @argparse.Command(
    "import-openapi",
    about="Convert an OpenAPI 3.0, 3.1 or 3.2 document into a Definition file, once: it declares one Mock, unless --declare-mock is off, with a Stub for each response of each operation, and for each further named example, which matches the operation's method and path. The main response answers by default, and each other one when the request sends Smock-Status with its key as the document writes it, such as Smock-Status: 404. A further named example answers when the request sends Smock-Example with its name too, such as Smock-Example: dog. smock never reads OpenAPI when it serves. Prints every problem, one per line, as smock check does, then a summary line, and exits with status 1 if nothing was written.",
    positionals=[
      @argparse.PositionArg(
        "document",
        about="The OpenAPI document: a JSON file, whose name ends in .json, or a YAML file, read as YAML 1.2, whose name ends in .yaml or .yml.",
        num_args=@argparse.ValueRange::single(),
      ),
    ],
    options=[
      @argparse.OptionArg(
        "mock",
        long="mock",
        about="The name of the Mock the Definition file declares. Every Stub ID starts with it.",
        required=true,
      ),
      @argparse.OptionArg(
        "hosts",
        long="hosts",
        about="The Mock's Hosts, separated by commas, such as petstore.test,pets.internal:8080. None by default: the only Mock of a definitions directory is the Default Mock and needs none; with several Mocks, give its Hosts. The document's servers never become Hosts.",
      ),
      @argparse.OptionArg(
        "declare-mock",
        long="declare-mock",
        about="Whether the file declares the Mock: on or off. Off, it holds only the Stubs, for a Mock declared by hand in another file, such as to set default, noMatch or journal; --hosts is then refused.",
        default_values=["on"],
      ),
      @argparse.OptionArg(
        "ref-dir",
        long="ref-dir",
        about="The directory that references to other files are followed in, by default the document's own. The document must lie under it. A reference that leads outside it, by its path or through a symlink, is an error: so a downloaded document cannot copy a file such as ../../.npmrc into the Definition file. smock never reads URLs.",
      ),
      @argparse.OptionArg(
        "output",
        long="output",
        about="The Definition file to write. Its name picks the format: .yaml or .yml writes YAML, with comments that map each Stub back to the document, and .json writes JSON. Its directory must exist. The file is written to a temporary file whose name starts with ., then renamed, so a smock that watches the directory never reads half a file.",
        required=true,
      ),
      @argparse.OptionArg(
        "base-path",
        long="base-path",
        about="A path to put in front of every path, such as /mock/petstore, to mount the API where the system under test calls it. It replaces the paths of the document's servers, which are then not read: / means no prefix. It must start with / and hold no ? or #. By default, the path of the first server of the operation, else of its Path Item, else of the document, is put in front.",
      ),
      @argparse.OptionArg(
        "overwrite",
        long="overwrite",
        about="Whether an existing --output is replaced: on or off. Off, an existing file is refused before the document is read, and nothing is written. Either way, a directory, a symlink, or the document or a file it refers to is refused.",
        default_values=["off"],
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
    template_env: template_env_value(matches),
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
    journal_max_bytes: byte_bound_value(matches, "journal-max-bytes"),
    journal_body_limit: int_value(
      matches,
      "journal-body-limit",
      min=0,
      max=max_size,
    ),
    state_max_bytes: byte_bound_value(matches, "state-max-bytes"),
  }
}

///|
/// A byte bound, the Journal's or the per-Session state's, when its flag
/// or its variable sets it, with which of them did.
fn byte_bound_value(
  matches : @argparse.Matches,
  name : String,
) -> ByteBound? raise InvalidSetting {
  guard value(matches, name) is Some(_) else { return None }
  let max_bytes = int_value(matches, name, min=1, max=max_size)
  let source : ByteBoundSource = match matches.sources.get(name) {
    Some(Env) => Variable
    _ => Flag
  }
  Some({ max_bytes, source, })
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
/// The index of a response that `text` gives, as `--response` and the
/// render operation's `response` query parameter take it: a decimal integer
/// from 0 to one less than the most responses a Stub has, without a sign,
/// prefix or separator. `None` when it is not one. Whether the Stub has a
/// response at that index is the rendering's to say.
pub fn parse_response_index(text : String) -> Int? {
  // Two digits hold every index below max_responses (100).
  match decimal(text, max_digits=2) {
    Some(n) if n < @definitions.max_responses.to_uint64() => Some(n.to_int())
    _ => None
  }
}

///|
/// Why a value is not the index of a response, as `--response` and the
/// render operation's `response` query parameter say it.
pub fn response_index_reason() -> String {
  "must be an integer from 0 to \{@definitions.max_responses - 1}"
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
  {
    dir,
    body_file_dir: body_file_dir(matches),
    template_env: template_env_value(matches),
  }
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
  let response_index = match value(matches, "response") {
    None => None
    Some(text) =>
      match parse_response_index(text) {
        Some(index) => Some(index)
        None =>
          raise InvalidOption(
            flag="response",
            value=text,
            reason=response_index_reason(),
          )
      }
  }
  {
    dir,
    body_file_dir: body_file_dir(matches),
    template_env: template_env_value(matches),
    stub: value(matches, "stub-id").unwrap_or(""),
    request_file,
    time,
    seed,
    response_index,
  }
}

///|
/// Reads and checks the settings from the parsed `import-openapi`
/// subcommand. The document and the output name a JSON or YAML file, in
/// lower case, as Definition files do, and the output's name does not
/// start with `.`, since smock skips such files. `--declare-mock` and
/// `--overwrite` are `on` or `off`. `--hosts` lists Hosts, separated by
/// commas, only when the file declares the Mock. `--base-path` starts with
/// `/` and holds no `?` or `#`. `--ref-dir` is not empty; that the
/// document lies under it is checked by the CLI, which reads the file
/// system.
pub fn ImportOpenapiSettings::from_matches(
  matches : @argparse.Matches,
) -> ImportOpenapiSettings raise InvalidSetting {
  let document = value(matches, "document").unwrap_or("")
  if !@definitions.is_json_or_yaml_name(document) {
    raise InvalidArgument(
      name="document",
      value=document,
      reason="must name a .json, .yaml or .yml file",
    )
  }
  let mock = value(matches, "mock").unwrap_or("")
  if mock == "" {
    raise InvalidOption(flag="mock", value=mock, reason="must not be empty")
  }
  let ref_dir = file_value(matches, "ref-dir", invalid_value=invalid_option)
  let output = value(matches, "output").unwrap_or("")
  if !@definitions.is_json_or_yaml_name(output) {
    raise InvalidOption(
      flag="output",
      value=output,
      reason="must name a .json, .yaml or .yml file",
    )
  }
  if base_name(output).has_prefix(".") {
    raise InvalidOption(
      flag="output",
      value=output,
      reason="must not name a file that starts with ., which smock skips",
    )
  }
  let declare_mock = on_off_value(
    matches,
    "declare-mock",
    invalid_value=invalid_option,
  )
  let hosts = hosts_value(matches, declare_mock~)
  let base_path = base_path_value(matches)
  let overwrite = on_off_value(
    matches,
    "overwrite",
    invalid_value=invalid_option,
  )
  {
    document,
    ref_dir,
    mock,
    hosts,
    declare_mock,
    output,
    base_path,
    overwrite,
  }
}

///|
/// The Hosts `--hosts` lists, separated by commas, in the order given, and
/// none when it is not given or empty. Each is a Host a Definition file can
/// declare, by the check `smock check` makes, and none is the same as an
/// earlier one once normalised. So a Host taken here always loads. The flag
/// is refused when the file does not declare the Mock (`declare_mock`
/// false), even empty: `--hosts ""` means no Hosts only for a declared
/// Mock.
fn hosts_value(
  matches : @argparse.Matches,
  declare_mock~ : Bool,
) -> Array[String] raise InvalidSetting {
  let hosts = []
  guard value(matches, "hosts") is Some(text) else { return hosts }
  if !declare_mock {
    raise InvalidOption(
      flag="hosts",
      value=text,
      reason="must not be given with --declare-mock off: give the Hosts where the Mock is declared",
    )
  }
  if text == "" {
    return hosts
  }
  let normalised : Map[String, String] = Map([])
  for part in text.split(",") {
    let host = part.to_owned()
    if @definitions.host_problem(host) is Some(problem) {
      raise InvalidOption(
        flag="hosts",
        value=text,
        reason="\{host.escape()} \{problem}",
      )
    }
    let name = @definitions.normalize_host(host)
    if normalised.get(name) is Some(earlier) {
      raise InvalidOption(
        flag="hosts",
        value=text,
        reason="\{host.escape()} is the same Host as \{earlier.escape()}: Hosts are compared in lower case, without the port and a trailing dot",
      )
    }
    normalised[name] = host
    hosts.push(host)
  }
  hosts
}

///|
/// The path `--base-path` gives, as given, or `None` when it is not given.
/// It starts with `/`, as a request's path does, and holds no `?` or `#`,
/// which would start a query or a fragment.
fn base_path_value(matches : @argparse.Matches) -> String? raise InvalidSetting {
  guard value(matches, "base-path") is Some(path) else { return None }
  if !path.has_prefix("/") {
    raise InvalidOption(
      flag="base-path",
      value=path,
      reason="must start with /",
    )
  }
  if path.contains_char('?') || path.contains_char('#') {
    raise InvalidOption(
      flag="base-path",
      value=path,
      reason="must not hold ? or #: a query or a fragment is not part of a path",
    )
  }
  Some(path)
}

///|
/// The OpenAPI document's name under the directory that references are
/// followed in, `/`-separated, from the real paths of the directories,
/// once symlinks, `.` and `..` are resolved: `ref_dir`, that of
/// `--ref-dir`, or `None` when it names no directory, and `document_dir`,
/// that of the document's directory, or `None` when it cannot be resolved.
///
/// Without `--ref-dir`, which defaults to the document's directory, or
/// when the document's directory cannot be resolved, so that the document
/// cannot be read either, it is the document's base name. A usage error
/// when `--ref-dir` names no directory, or when the document does not lie
/// under it, as when a symlink leads its directory outside.
pub fn ImportOpenapiSettings::document_name_under(
  self : ImportOpenapiSettings,
  ref_dir~ : String?,
  document_dir~ : String?,
) -> String raise InvalidSetting {
  // Its base name: its name under its own directory, where references are
  // followed by default.
  let name = base_name(self.document)
  guard self.ref_dir is Some(given) else { return name }
  guard ref_dir is Some(ref_dir) else {
    raise InvalidOption(
      flag="ref-dir",
      value=given,
      reason="must name a directory",
    )
  }
  guard document_dir is Some(document_dir) else { return name }
  if document_dir == ref_dir {
    return name
  }
  guard is_under(document_dir, ref_dir) else {
    raise InvalidArgument(
      name="document",
      value=self.document,
      reason="must lie under --ref-dir \{given.escape()}",
    )
  }
  "\{document_dir[under(ref_dir).length():]}/\{name}"
}

///|
/// Whether the real path `real` lies below the directory whose real path
/// is `directory`, once symlinks, `.` and `..` are resolved in both. The
/// directory itself does not. `import-openapi` reads the documents that
/// references name only under `--ref-dir`, which this decides.
pub fn is_under(real : String, directory : String) -> Bool {
  real.has_prefix(under(directory))
}

///|
/// What the paths below the directory `directory` start with: it, then
/// `/`.
fn under(directory : String) -> String {
  if directory.has_suffix("/") {
    directory
  } else {
    "\{directory}/"
  }
}

///|
/// The directory that references are followed in, as given, by which
/// problems name the documents under it: `--ref-dir`, or else the
/// directory part of the document's path (see `document_directory`).
pub fn ImportOpenapiSettings::ref_dir_path(
  self : ImportOpenapiSettings,
) -> String {
  self.ref_dir.unwrap_or(self.document_directory())
}

///|
/// The directory part of the OpenAPI document's path, as given, up to its
/// last `/`, such as `api/`, or `""` when the path has none.
pub fn ImportOpenapiSettings::document_directory(
  self : ImportOpenapiSettings,
) -> String {
  match self.document.rev_find("/") {
    Some(i) => self.document[:i + 1].to_owned()
    None => ""
  }
}

///|
/// The last name of `path`, after its last `/`.
fn base_name(path : String) -> String {
  match path.rev_find("/") {
    Some(i) => path[i + 1:].to_owned()
    None => path
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
/// The names `--template-env` lists, separated by commas: each once, in
/// the order given, and none when it is not given or empty. A name is
/// letters, digits and `_`, starting with a letter or `_`, and does not
/// start with `SMOCK_`, so that smock's own variables, such as the Admin
/// API token, never reach a template.
fn template_env_value(
  matches : @argparse.Matches,
) -> Array[String] raise InvalidSetting {
  let setting = template_env_setting.name
  let names = []
  guard value(matches, setting) is Some(text) && text != "" else {
    return names
  }
  for part in text.split(",") {
    let name = part.to_owned()
    if !is_environment_variable_name(name) {
      raise invalid(
        setting,
        text,
        "\{name.escape()} is not an environment variable name: letters, digits and _, starting with a letter or _",
      )
    }
    if name.has_prefix("SMOCK_") {
      raise invalid(
        setting,
        text,
        "\{name.escape()} starts with SMOCK_: smock's own variables cannot be listed",
      )
    }
    if !names.contains(name) {
      names.push(name)
    }
  }
  names
}

///|
/// Whether `name` is an environment variable name templates may read:
/// ASCII letters, digits and `_`, starting with a letter or `_`.
fn is_environment_variable_name(name : String) -> Bool {
  name != "" &&
  !name[0].unsafe_to_char().is_ascii_digit() &&
  name
  .iter()
  .all(c => c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_')
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
/// The value of a file setting, which must not be empty when given. The
/// problem is made with `invalid_value`, by default that of a setting with
/// an environment variable.
fn file_value(
  matches : @argparse.Matches,
  name : String,
  invalid_value? : (String, String, String) -> InvalidSetting = invalid,
) -> String? raise InvalidSetting {
  match value(matches, name) {
    Some("") => raise invalid_value(name, "", "must not be empty")
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
/// The value of a setting that is `on` or `off`, as true or false. The
/// problem is made with `invalid_value`, by default that of a setting with
/// an environment variable.
fn on_off_value(
  matches : @argparse.Matches,
  name : String,
  invalid_value? : (String, String, String) -> InvalidSetting = invalid,
) -> Bool raise InvalidSetting {
  match value(matches, name) {
    Some("on") => true
    Some("off") => false
    other => raise invalid_value(name, other.unwrap_or(""), "must be on or off")
  }
}

///|
/// The problem with the value `value` of the setting `name`, which has an
/// environment variable, and why: `reason`.
fn invalid(name : String, value : String, reason : String) -> InvalidSetting {
  InvalidSetting(flag=name, env=env_name(name), value~, reason~)
}

///|
/// The problem with the value `value` of the flag `name`, which has no
/// environment variable, and why: `reason`.
fn invalid_option(
  name : String,
  value : String,
  reason : String,
) -> InvalidSetting {
  InvalidOption(flag=name, value~, reason~)
}

///|
/// Whether `path` is a relative path that stays inside the directory it is
/// relative to: one or more `/`-separated names, none of them empty, `.` or
/// `..`.
fn is_inner_relative_path(path : String) -> Bool {
  path != "" &&
  path.split("/").all(part => part != "" && part != "." && part != "..")
}
