// The settings of smock serve that are not numbers: each one's values are
// taken, and a value it cannot take is refused with the message a user
// sees, by the flag and, apart, by its variable, which docs/running.md's
// Settings table pairs with it (#320). The e2e settings test refuses some
// of these values through the binary; these run in-process. The message
// names the flag and its variable, in the form `InvalidSetting::message`
// documents. The documents say which values a setting takes, but not the
// words of a refusal's reason: those are the code's, and the maintainer,
// who decided on 2026-11-18 that they stay as they are (#320), is their
// source.
// The frame of a refused value, `invalid value "<value>" for <setting>:
// <reason>`, is no document's: the maintainer confirmed on 2026-11-21
// (#329) that it stays as the code has it, with a flag that has no
// variable, or an argument such as <document>, named alone, and a " in
// the value written \".

///|
/// What `smock serve <argv>`, with the variables `env`, makes of its
/// settings: `show` of the settings when they are valid, or the message a
/// user sees when they are not.
fn serve_shows(
  argv : Array[String],
  env~ : Map[String, String] = {},
  show : (@settings.ServeSettings) -> String,
) -> String {
  let matches = @settings.serve_command().parse(argv~, env~) catch {
    err => return "parse: \{err}"
  }
  try @settings.ServeSettings::from_matches(matches) catch {
    err => err.message()
  } noraise {
    settings => show(settings)
  }
}

///|
test "values: --tls-http2, --admin-auth and --journal, by their flags or variables, take on and off, and refuse any other value" {
  // docs/running.md, Settings: each of the three is `on` or `off`, `on` by
  // default, as each one's help says ("on or off").
  inspect(
    [
      serve_shows([], settings => {
        "default: \{settings.tls_http2} \{settings.admin_auth} \{settings.journal}"
      }),
      each_by_flag_and_variable(
        "--tls-http2",
        "SMOCK_TLS_HTTP2",
        ["on", "off", "OFF", "false", ""],
        settings => settings.tls_http2.to_string(),
      ),
      each_by_flag_and_variable(
        "--admin-auth",
        "SMOCK_ADMIN_AUTH",
        ["on", "off", "Off", "no", ""],
        settings => settings.admin_auth.to_string(),
      ),
      each_by_flag_and_variable(
        "--journal",
        "SMOCK_JOURNAL",
        ["on", "off", "ON", "1", ""],
        settings => settings.journal.to_string(),
      ),
    ].join("\n"),
    content=(
      #|default: true true true
      #|on: true
      #|off: false
      #|OFF: invalid value "OFF" for --tls-http2 (SMOCK_TLS_HTTP2): must be on or off
      #|false: invalid value "false" for --tls-http2 (SMOCK_TLS_HTTP2): must be on or off
      #|: invalid value "" for --tls-http2 (SMOCK_TLS_HTTP2): must be on or off
      #|on: true
      #|off: false
      #|Off: invalid value "Off" for --admin-auth (SMOCK_ADMIN_AUTH): must be on or off
      #|no: invalid value "no" for --admin-auth (SMOCK_ADMIN_AUTH): must be on or off
      #|: invalid value "" for --admin-auth (SMOCK_ADMIN_AUTH): must be on or off
      #|on: true
      #|off: false
      #|ON: invalid value "ON" for --journal (SMOCK_JOURNAL): must be on or off
      #|1: invalid value "1" for --journal (SMOCK_JOURNAL): must be on or off
      #|: invalid value "" for --journal (SMOCK_JOURNAL): must be on or off
    ),
  )
}

///|
test "values: --log-format, by its flag or SMOCK_LOG_FORMAT, takes json and mockoon, and refuses any other value" {
  // docs/running.md, Settings: --log-format is `json` by default, or
  // `mockoon`, as its help says ("json or mockoon").
  let format = (settings : @settings.ServeSettings) => {
    @debug.to_string(settings.log_format)
  }
  inspect(
    [
      serve_shows([], settings => "default: \{format(settings)}"),
      each_by_flag_and_variable(
        "--log-format",
        "SMOCK_LOG_FORMAT",
        ["json", "mockoon", "Mockoon", "text", ""],
        format,
      ),
    ].join("\n"),
    content=(
      #|default: Json
      #|json: Json
      #|mockoon: Mockoon
      #|Mockoon: invalid value "Mockoon" for --log-format (SMOCK_LOG_FORMAT): must be json or mockoon
      #|text: invalid value "text" for --log-format (SMOCK_LOG_FORMAT): must be json or mockoon
      #|: invalid value "" for --log-format (SMOCK_LOG_FORMAT): must be json or mockoon
    ),
  )
}

///|
/// A path setting's value, or `none` when it is not given.
fn path(value : String?) -> String {
  match value {
    Some(value) => value
    None => "none"
  }
}

///|
test "values: --dir and --admin-token-file, by their flags or variables, take a path, and refuse the empty value" {
  // docs/running.md, Settings: without --dir, smock serves "one empty
  // Default Mock"; without --admin-token-file, the token comes from
  // SMOCK_ADMIN_TOKEN. A path names a file or a directory, and no file has
  // the empty name.
  inspect(
    [
      serve_shows([], settings => {
        "default: \{path(settings.dir)} \{path(settings.admin_token_file)}"
      }),
      each_by_flag_and_variable(
        "--dir",
        "SMOCK_DIR",
        ["defs", "/etc/smock/defs", ""],
        settings => path(settings.dir),
      ),
      each_by_flag_and_variable(
        "--admin-token-file",
        "SMOCK_ADMIN_TOKEN_FILE",
        ["/run/secrets/smock-token", ""],
        settings => path(settings.admin_token_file),
      ),
    ].join("\n"),
    content=(
      #|default: none none
      #|defs: defs
      #|/etc/smock/defs: /etc/smock/defs
      #|: invalid value "" for --dir (SMOCK_DIR): must not be empty
      #|/run/secrets/smock-token: /run/secrets/smock-token
      #|: invalid value "" for --admin-token-file (SMOCK_ADMIN_TOKEN_FILE): must not be empty
    ),
  )
}

///|
test "values: --body-file-dir, by its flag or SMOCK_BODY_FILE_DIR, takes a subdirectory of the definitions directory, and refuses a path that leaves it or names it" {
  // docs/running.md, Settings: --body-file-dir is `files` by default; its
  // help: "The body-file subdirectory of the definitions directory".
  // docs/definition-files.md: "Body files live in the body-file
  // subdirectory". A subdirectory's path is relative to the directory and
  // stays below it.
  inspect(
    [
      serve_shows([], settings => "default: \{settings.body_file_dir}"),
      each_by_flag_and_variable(
        "--body-file-dir",
        "SMOCK_BODY_FILE_DIR",
        [
          "bodies", "bodies/v1", "../files", "/srv/files", "bodies/../../files",
          ".", "",
        ],
        settings => settings.body_file_dir,
      ),
    ].join("\n"),
    content=(
      #|default: files
      #|bodies: bodies
      #|bodies/v1: bodies/v1
      #|../files: invalid value "../files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|/srv/files: invalid value "/srv/files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|bodies/../../files: invalid value "bodies/../../files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|.: invalid value "." for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|: invalid value "" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
    ),
  )
}

///|
test "values: --session-header and --session-member, by their flags or variables, take a token, and refuse a value with a character a token has not" {
  // docs/running.md, Settings: --session-header names "the W3C Baggage
  // header that carries the Session", `baggage` by default, and
  // --session-member "the member of that header whose value is the Session
  // key", `smock-session` by default. A header name is a token (RFC 9110,
  // section 5.1), and so is a W3C Baggage key (W3C Baggage, the grammar's
  // `key`): one or more of the ASCII letters, the digits and
  // !#$%&'*+-.^_`|~ (RFC 9110, section 5.6.2).
  inspect(
    [
      serve_shows([], settings => {
        "default: \{settings.session_header} \{settings.session_member}"
      }),
      each_by_flag_and_variable(
        "--session-header",
        "SMOCK_SESSION_HEADER",
        ["X-Session", "!#$%&'*+-.^_`|~09AZaz", "", "x baggage", "baggage:"],
        settings => settings.session_header,
      ),
      each_by_flag_and_variable(
        "--session-member",
        "SMOCK_SESSION_MEMBER",
        ["session", "", "smock session", "a=b", "sésame"],
        settings => settings.session_member,
      ),
    ].join("\n"),
    content=(
      #|default: baggage smock-session
      #|X-Session: X-Session
      #|!#$%&'*+-.^_`|~09AZaz: !#$%&'*+-.^_`|~09AZaz
      #|: invalid value "" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|x baggage: invalid value "x baggage" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|baggage:: invalid value "baggage:" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|session: session
      #|: invalid value "" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
      #|smock session: invalid value "smock session" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
      #|a=b: invalid value "a=b" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
      #|sésame: invalid value "sésame" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
    ),
  )
}

///|
/// The certificate and key files of the TLS port that settings hold, or
/// `none` for the self-signed certificate.
fn tls_files(settings : @settings.ServeSettings) -> String {
  match settings.tls {
    Some({ cert_file, key_file, }) => "\{cert_file} \{key_file}"
    None => "none"
  }
}

///|
test "values: --tls-cert-file and --tls-key-file, by their flags or variables, go together, and neither takes the empty value" {
  // docs/running.md, Settings: without either, smock serves "a generated
  // self-signed certificate". HTTPS: "Setting only one of the two files
  // ... stops smock serve ... (2 for a missing partner setting)". A path
  // names a file, and no file has the empty name.
  inspect(
    [
      serve_shows([], tls_files),
      serve_shows(
        ["--tls-cert-file", "tls.crt", "--tls-key-file", "tls.key"],
        tls_files,
      ),
      serve_shows([], tls_files, env={
        "SMOCK_TLS_CERT_FILE": "tls.crt",
        "SMOCK_TLS_KEY_FILE": "tls.key",
      }),
      serve_shows(["--tls-cert-file", "tls.crt"], tls_files, env={
        "SMOCK_TLS_KEY_FILE": "tls.key",
      }),
      serve_shows(["--tls-cert-file", "tls.crt"], tls_files),
      serve_shows([], tls_files, env={ "SMOCK_TLS_CERT_FILE": "tls.crt" }),
      serve_shows(["--tls-key-file", "tls.key"], tls_files),
      serve_shows([], tls_files, env={ "SMOCK_TLS_KEY_FILE": "tls.key" }),
      serve_shows(["--tls-cert-file=", "--tls-key-file", "tls.key"], tls_files),
      serve_shows([], tls_files, env={
        "SMOCK_TLS_CERT_FILE": "tls.crt",
        "SMOCK_TLS_KEY_FILE": "",
      }),
    ].join("\n"),
    content=(
      #|none
      #|tls.crt tls.key
      #|tls.crt tls.key
      #|tls.crt tls.key
      #|invalid value "tls.crt" for --tls-cert-file (SMOCK_TLS_CERT_FILE): needs --tls-key-file (SMOCK_TLS_KEY_FILE) as well
      #|invalid value "tls.crt" for --tls-cert-file (SMOCK_TLS_CERT_FILE): needs --tls-key-file (SMOCK_TLS_KEY_FILE) as well
      #|invalid value "tls.key" for --tls-key-file (SMOCK_TLS_KEY_FILE): needs --tls-cert-file (SMOCK_TLS_CERT_FILE) as well
      #|invalid value "tls.key" for --tls-key-file (SMOCK_TLS_KEY_FILE): needs --tls-cert-file (SMOCK_TLS_CERT_FILE) as well
      #|invalid value "" for --tls-cert-file (SMOCK_TLS_CERT_FILE): must not be empty
      #|invalid value "" for --tls-key-file (SMOCK_TLS_KEY_FILE): must not be empty
    ),
  )
}

///|
test "values: the plain, TLS and admin ports, by their flags or variables, must differ from each other, but each may be 0" {
  // docs/running.md, Settings: the defaults are 8080, 8443 and 9090, and
  // "0 picks a free port". The help: the TLS port is "separate from the
  // plain port", and the admin port "separate from the plain and TLS
  // ports".
  let ports = (settings : @settings.ServeSettings) => {
    "\{settings.port} \{settings.tls_port} \{settings.admin_port}"
  }
  inspect(
    [
      serve_shows([], ports),
      serve_shows(
        ["--port", "0", "--tls-port", "0", "--admin-port", "0"],
        ports,
      ),
      serve_shows(["--port", "8443"], ports),
      serve_shows([], ports, env={
        "SMOCK_PORT": "9000",
        "SMOCK_TLS_PORT": "9000",
      }),
      serve_shows(["--admin-port", "8080"], ports),
      serve_shows([], ports, env={ "SMOCK_ADMIN_PORT": "8443" }),
      serve_shows(
        ["--port", "1", "--tls-port", "2", "--admin-port", "3"],
        ports,
      ),
    ].join("\n"),
    content=(
      #|8080 8443 9090
      #|0 0 0
      #|invalid value "8443" for --tls-port (SMOCK_TLS_PORT): must differ from --port (SMOCK_PORT)
      #|invalid value "9000" for --tls-port (SMOCK_TLS_PORT): must differ from --port (SMOCK_PORT)
      #|invalid value "8080" for --admin-port (SMOCK_ADMIN_PORT): must differ from --port (SMOCK_PORT)
      #|invalid value "8443" for --admin-port (SMOCK_ADMIN_PORT): must differ from --tls-port (SMOCK_TLS_PORT)
      #|1 2 3
    ),
  )
}

///|
test "values: a plain or TLS port that is the admin port's default is refused, and the refusal names the admin port" {
  // The same rule as above: the admin port is "separate from the plain and
  // TLS ports", 9090 by default (docs/running.md, Settings). Which of the
  // two ports the refusal names, here the admin port that the user did not
  // set, comes from the maintainer, who decided on 2026-11-18 that today's
  // refusal stays (#320).
  let ports = (settings : @settings.ServeSettings) => {
    "\{settings.port} \{settings.tls_port} \{settings.admin_port}"
  }
  inspect(
    [
      serve_shows(["--port", "9090"], ports),
      serve_shows([], ports, env={ "SMOCK_TLS_PORT": "9090" }),
    ].join("\n"),
    content=(
      #|invalid value "9090" for --admin-port (SMOCK_ADMIN_PORT): must differ from --port (SMOCK_PORT)
      #|invalid value "9090" for --admin-port (SMOCK_ADMIN_PORT): must differ from --tls-port (SMOCK_TLS_PORT)
    ),
  )
}

///|
/// The certificates of single Mocks that settings hold, one Mock after
/// another, sorted, or `none`.
fn mock_certs(settings : @settings.ServeSettings) -> String {
  let mocks = []
  for mock, files in settings.tls_mock_certs {
    mocks.push("\{mock}: \{files.cert_file} \{files.key_file}")
  }
  mocks.sort()
  if mocks.is_empty() {
    "none"
  } else {
    mocks.join(", ")
  }
}

///|
test "values: --tls-mock-certs, by its flag or SMOCK_TLS_MOCK_CERTS, takes a JSON object that maps each Mock name to its certificate and key files, and refuses any other value" {
  // docs/running.md, Settings: no Mock has a certificate of its own by
  // default. Certificates for single Mocks: the value is "a JSON object
  // that maps each Mock name to its certificate and key files", as
  // {"users":{"certFile":"/etc/smock/users/tls.crt","keyFile":"/etc/smock/users/tls.key"}},
  // and "a value that is not such a JSON object, or an entry without both
  // files, exits with status 2", the status of a usage error. A Mock's name
  // is "a non-empty name" (schema/v1/definitions.json, `$defs/name`), and a
  // path names a file, which no file's empty name does.
  inspect(
    [
      serve_shows([], mock_certs),
      each_by_flag_and_variable(
        "--tls-mock-certs",
        "SMOCK_TLS_MOCK_CERTS",
        [
          "{}", "{\"users\":{\"certFile\":\"/etc/smock/users/tls.crt\",\"keyFile\":\"/etc/smock/users/tls.key\"}}",
          "{\"users\":{\"keyFile\":\"u.key\",\"certFile\":\"u.crt\"},\"carts\":{\"certFile\":\"c.crt\",\"keyFile\":\"c.key\"}}",
          "users", "[]", "", "{\"\":{\"certFile\":\"u.crt\",\"keyFile\":\"u.key\"}}",
          "{\"users\":{\"certFile\":\"u.crt\"}}", "{\"users\":{\"certFile\":\"u.crt\",\"keyFile\":\"\"}}",
          "{\"users\":{\"certFile\":1,\"keyFile\":\"u.key\"}}", "{\"users\":\"u.crt\"}",
        ],
        mock_certs,
      ),
    ].join("\n"),
    content=(
      #|none
      #|{}: none
      #|{"users":{"certFile":"/etc/smock/users/tls.crt","keyFile":"/etc/smock/users/tls.key"}}: users: /etc/smock/users/tls.crt /etc/smock/users/tls.key
      #|{"users":{"keyFile":"u.key","certFile":"u.crt"},"carts":{"certFile":"c.crt","keyFile":"c.key"}}: carts: c.crt c.key, users: u.crt u.key
      #|users: invalid value "users" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): must be a JSON object that maps each Mock name to {"certFile": <path>, "keyFile": <path>}
      #|[]: invalid value "[]" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): must be a JSON object that maps each Mock name to {"certFile": <path>, "keyFile": <path>}
      #|: invalid value "" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): must be a JSON object that maps each Mock name to {"certFile": <path>, "keyFile": <path>}
      #|{"":{"certFile":"u.crt","keyFile":"u.key"}}: invalid value "{\"\":{\"certFile\":\"u.crt\",\"keyFile\":\"u.key\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): a Mock name must not be empty
      #|{"users":{"certFile":"u.crt"}}: invalid value "{\"users\":{\"certFile\":\"u.crt\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
      #|{"users":{"certFile":"u.crt","keyFile":""}}: invalid value "{\"users\":{\"certFile\":\"u.crt\",\"keyFile\":\"\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
      #|{"users":{"certFile":1,"keyFile":"u.key"}}: invalid value "{\"users\":{\"certFile\":1,\"keyFile\":\"u.key\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
      #|{"users":"u.crt"}: invalid value "{\"users\":\"u.crt\"}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
    ),
  )
}

///|
test "values: --tls-mock-certs refuses an entry with a member beside its two files" {
  // docs/running.md, Certificates for single Mocks, after "an entry without
  // both files, exits with status 2": "So does an entry with a member
  // beside `certFile` and `keyFile`, such as a `ca`: an entry holds the two
  // files and nothing else", as the maintainer decided on 2026-11-18
  // (#320).
  inspect(
    by_flag_and_variable(
      "--tls-mock-certs", "SMOCK_TLS_MOCK_CERTS", "{\"users\":{\"certFile\":\"u.crt\",\"keyFile\":\"u.key\",\"ca\":\"ca.crt\"}}",
      mock_certs,
    ),
    content=(
      #|{"users":{"certFile":"u.crt","keyFile":"u.key","ca":"ca.crt"}}: invalid value "{\"users\":{\"certFile\":\"u.crt\",\"keyFile\":\"u.key\",\"ca\":\"ca.crt\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
    ),
  )
}
