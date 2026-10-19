///|
async test "every serve setting is a flag with a matching SMOCK_ environment variable and a default" {
  let (status, help) = smock_stdout(["serve", "--help"])
  inspect(
    "status \{status}\n\{help}",
    content=(
      #|status 0
      #|Usage: smock serve [options]
      #|
      #|Serve the Mocks and Stubs of a definitions directory.
      #|
      #|Options:
      #|  -h, --help                                   Show help information.
      #|  --dir <dir>                                  The definitions directory. Without it, smock serves one empty Default Mock. [env: SMOCK_DIR]
      #|  --port <port>                                The plain HTTP port. 0 picks a free port. [env: SMOCK_PORT] [default: 8080]
      #|  --tls-port <tls-port>                        The HTTPS port, separate from the plain port. 0 picks a free port. [env: SMOCK_TLS_PORT] [default: 8443]
      #|  --tls-cert-file <tls-cert-file>              The PEM certificate chain for the HTTPS port: the leaf certificate, then its intermediates. Without it and --tls-key-file, smock generates a self-signed certificate in memory for localhost, 127.0.0.1, ::1 and every Mock Host. [env: SMOCK_TLS_CERT_FILE]
      #|  --tls-key-file <tls-key-file>                The PEM private key of the leaf certificate in --tls-cert-file. [env: SMOCK_TLS_KEY_FILE]
      #|  --tls-mock-certs <tls-mock-certs>            Certificates of single Mocks, chosen by SNI: a JSON object that maps each Mock name to its PEM files, such as {"users":{"certFile":"/certs/users/tls.crt","keyFile":"/certs/users/tls.key"}}. A handshake whose SNI is a Host of a listed Mock gets that Mock's certificate; any other gets the default certificate: --tls-cert-file, or without it the self-signed one. Empty by default. [env: SMOCK_TLS_MOCK_CERTS]
      #|  --admin-port <admin-port>                    The Admin API port, separate from the plain and TLS ports. 0 picks a free port. [env: SMOCK_ADMIN_PORT] [default: 9090]
      #|  --admin-auth <admin-auth>                    Whether the Admin API needs a bearer token: on or off. Turn it off only for local use. [env: SMOCK_ADMIN_AUTH] [default: on]
      #|  --admin-token-file <admin-token-file>        A file that holds the Admin API token. Without it, the token comes from the environment variable SMOCK_ADMIN_TOKEN. [env: SMOCK_ADMIN_TOKEN_FILE]
      #|  --replicas <replicas>                        How many replicas the deployment runs. Above 1, every Admin API response warns that state is per replica. [env: SMOCK_REPLICAS] [default: 1]
      #|  --session-header <session-header>            The request header that carries the Session, as W3C Baggage, on requests and Admin API calls. [env: SMOCK_SESSION_HEADER] [default: baggage]
      #|  --session-member <session-member>            The member of the Session header whose value is the Session key. [env: SMOCK_SESSION_MEMBER] [default: smock-session]
      #|  --log-format <log-format>                    The log format: json. [env: SMOCK_LOG_FORMAT] [default: json]
      #|  --body-file-dir <body-file-dir>              The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
      #|  --header-size-limit <header-size-limit>      The most bytes a request head (request line and header fields) may take. Larger heads get 431. [env: SMOCK_HEADER_SIZE_LIMIT] [default: 16384]
      #|  --header-count-limit <header-count-limit>    The most header fields a request may have. More get 431. [env: SMOCK_HEADER_COUNT_LIMIT] [default: 100]
      #|  --body-limit <body-limit>                    The longest request body, in bytes. Longer bodies get 413. [env: SMOCK_BODY_LIMIT] [default: 10485760]
      #|  --read-timeout-ms <read-timeout-ms>          How long a request may take to arrive, in milliseconds, from its first byte to its last. Then the connection closes. [env: SMOCK_READ_TIMEOUT_MS] [default: 30000]
      #|  --idle-timeout-ms <idle-timeout-ms>          How long a connection may wait for a request, in milliseconds. Then it closes. [env: SMOCK_IDLE_TIMEOUT_MS] [default: 60000]
      #|  --drain-timeout-ms <drain-timeout-ms>        How long smock may drain after SIGTERM, in milliseconds: responses in progress, Server-Sent Event streams and delays still running then are cut, and smock exits. [env: SMOCK_DRAIN_TIMEOUT_MS] [default: 20000]
      #|  --seed <seed>                                The seed of the process random generator, from 0 to 9007199254740991. Faults of Stubs without their own seed draw from it. Without it, smock picks a seed at startup and logs it. [env: SMOCK_SEED]
      #|  --journal <journal>                          Whether smock records the requests it receives in the Journal: on or off. Off, it records none, and Journal queries are refused. [env: SMOCK_JOURNAL] [default: on]
      #|  --journal-max-entries <journal-max-entries>  The most entries the Journal holds. Beyond it, the oldest entries are evicted. [env: SMOCK_JOURNAL_MAX_ENTRIES] [default: 10000]
      #|  --journal-max-bytes <journal-max-bytes>      The most bytes the Journal's entries take: each counts 256, two per character of its request line, header fields, names and Near miss values, 32 per value its Near miss keeps from a form or an XML body, and the body bytes it keeps. Beyond it, the oldest entries are evicted. Default: a quarter of the memory limit of smock's cgroup (cgroup v2 memory.max), at least 1048576 (1 MiB) and at most 67108864 (64 MiB); 67108864 when there is no limit or it cannot be read. [env: SMOCK_JOURNAL_MAX_BYTES]
      #|  --journal-body-limit <journal-body-limit>    The most bytes of a request body a Journal entry keeps; the rest is cut. Its Near miss keeps the values of form fields and XML paths up to the same total, each counting 32 bytes more. [env: SMOCK_JOURNAL_BODY_LIMIT] [default: 4096]
      #|
    ),
  )
}

///|
async test "settings can come from SMOCK_ environment variables" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(
      [],
      env={
        "SMOCK_DIR": dir,
        "SMOCK_PORT": "0",
        "SMOCK_LOG_FORMAT": "json",
        "SMOCK_BODY_FILE_DIR": "bodies",
      },
      smock => {
        inspect(smock.get("/users/1").has_prefix("200 OK"), content="true")
      },
    )
  })
}

///|
async test "limits and timeouts can come from SMOCK_ environment variables" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0"],
      env={
        "SMOCK_HEADER_SIZE_LIMIT": "100",
        "SMOCK_HEADER_COUNT_LIMIT": "2",
        "SMOCK_BODY_LIMIT": "4",
        // Long enough that connecting and writing each request below fits
        // well within them on a busy machine.
        "SMOCK_READ_TIMEOUT_MS": "1000",
        "SMOCK_IDLE_TIMEOUT_MS": "1000",
      },
      smock => {
        let out = []
        for
          request in [
            "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nX: \{"x".repeat(60)}\r\n\r\n",
            "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nX-1: 1\r\nX-2: 2\r\n\r\n",
            "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n",
          ] {
          let conn = smock.connect()
          defer conn.close()
          conn.write(request)
          out.push(status_line(read_response(conn)))
        }
        let since = @async.now()
        let idle = smock.connect()
        defer idle.close()
        let (elapsed, _) = ended(idle, since)
        out.push(
          "idle connection ended after at least 1000 ms: \{elapsed >= 1000}",
        )
        inspect(
          out.join("\n"),
          content=(
            #|HTTP/1.1 431 Request Header Fields Too Large
            #|HTTP/1.1 431 Request Header Fields Too Large
            #|HTTP/1.1 413 Content Too Large
            #|idle connection ended after at least 1000 ms: true
          ),
        )
      },
    )
  })
}

///|
async test "a flag wins over its environment variable" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_DIR": "/nonexistent", "SMOCK_PORT": "not a port" },
      smock => {
        inspect(smock.get("/users/1").has_prefix("200 OK"), content="true")
      },
    )
  })
}

///|
async test "an invalid value stops startup with a message that names the setting" {
  let runs = [
    (["--port", "65536"], Map([])),
    (["--port", "eighty"], Map([])),
    (["--port", "0x50"], Map([])),
    (["--port", "8_080"], Map([])),
    ([], { "SMOCK_PORT": "-1" }),
    (["--tls-port", "65536"], Map([])),
    ([], { "SMOCK_TLS_PORT": "https" }),
    (["--port", "8443", "--tls-port", "8443"], Map([])),
    ([], { "SMOCK_PORT": "9000", "SMOCK_TLS_PORT": "9000" }),
    (["--log-format", "text"], Map([])),
    ([], { "SMOCK_LOG_FORMAT": "" }),
    (["--dir", ""], Map([])),
    (["--body-file-dir", "../files"], Map([])),
    ([], { "SMOCK_BODY_FILE_DIR": "/srv/files" }),
    (["--header-size-limit", "0"], Map([])),
    ([], { "SMOCK_HEADER_SIZE_LIMIT": "16KiB" }),
    (["--header-count-limit", "0"], Map([])),
    (["--body-limit", "1073741825"], Map([])),
    ([], { "SMOCK_BODY_LIMIT": "-1" }),
    (["--read-timeout-ms", "30s"], Map([])),
    (["--read-timeout-ms", "2147483648"], Map([])),
    ([], { "SMOCK_IDLE_TIMEOUT_MS": "0" }),
    (["--drain-timeout-ms", "20s"], Map([])),
    ([], { "SMOCK_DRAIN_TIMEOUT_MS": "-1" }),
    (["--drain-timeout-ms", "2147483648"], Map([])),
    (["--admin-port", "65536"], Map([])),
    ([], { "SMOCK_ADMIN_PORT": "admin" }),
    (["--port", "8080", "--admin-port", "8080"], Map([])),
    // The TLS port is served with or without certificate files.
    (["--tls-port", "8443", "--admin-port", "8443"], Map([])),
    (
      [
        "--tls-port", "8443", "--admin-port", "8443", "--tls-cert-file", "c.pem",
        "--tls-key-file", "k.pem",
      ],
      Map([]),
    ),
    (["--admin-auth", "false"], Map([])),
    ([], { "SMOCK_ADMIN_AUTH": "OFF" }),
    (["--admin-token-file", ""], Map([])),
    (["--replicas", "0"], Map([])),
    ([], { "SMOCK_REPLICAS": "two" }),
    (["--seed", "9007199254740992"], Map([])),
    ([], { "SMOCK_SEED": "-1" }),
    (["--seed", ""], Map([])),
    ([], { "SMOCK_SEED": "0x2a" }),
    ([], { "SMOCK_SEED": "12345678901234567890" }),
    (["--session-header", ""], Map([])),
    (["--session-header", "x baggage"], Map([])),
    ([], { "SMOCK_SESSION_HEADER": "baggage:" }),
    (["--session-member", "smock session"], Map([])),
    ([], { "SMOCK_SESSION_MEMBER": "" }),
    (["--journal", "false"], Map([])),
    ([], { "SMOCK_JOURNAL": "OFF" }),
    (["--journal-max-entries", "0"], Map([])),
    ([], { "SMOCK_JOURNAL_MAX_BYTES": "64MiB" }),
    (["--journal-max-bytes", "1073741825"], Map([])),
    ([], { "SMOCK_JOURNAL_BODY_LIMIT": "-1" }),
  ]
  let out = []
  for run in runs {
    let (args, env) = run
    let stopped = run_smock(["serve", ..args], env~)
    out.push("status \{stopped.status}: \{stopped.logs.join(" | ")}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|status 2: smock serve: invalid value "65536" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "eighty" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "0x50" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "8_080" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "-1" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "65536" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "https" for --tls-port (SMOCK_TLS_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "8443" for --tls-port (SMOCK_TLS_PORT): must differ from --port (SMOCK_PORT)
      #|status 2: smock serve: invalid value "9000" for --tls-port (SMOCK_TLS_PORT): must differ from --port (SMOCK_PORT)
      #|status 2: smock serve: invalid value "text" for --log-format (SMOCK_LOG_FORMAT): must be json
      #|status 2: smock serve: invalid value "" for --log-format (SMOCK_LOG_FORMAT): must be json
      #|status 2: smock serve: invalid value "" for --dir (SMOCK_DIR): must not be empty
      #|status 2: smock serve: invalid value "../files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|status 2: smock serve: invalid value "/srv/files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|status 2: smock serve: invalid value "0" for --header-size-limit (SMOCK_HEADER_SIZE_LIMIT): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "16KiB" for --header-size-limit (SMOCK_HEADER_SIZE_LIMIT): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "0" for --header-count-limit (SMOCK_HEADER_COUNT_LIMIT): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "1073741825" for --body-limit (SMOCK_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|status 2: smock serve: invalid value "-1" for --body-limit (SMOCK_BODY_LIMIT): must be an integer from 0 to 1073741824
      #|status 2: smock serve: invalid value "30s" for --read-timeout-ms (SMOCK_READ_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|status 2: smock serve: invalid value "2147483648" for --read-timeout-ms (SMOCK_READ_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|status 2: smock serve: invalid value "0" for --idle-timeout-ms (SMOCK_IDLE_TIMEOUT_MS): must be an integer from 1 to 2147483647
      #|status 2: smock serve: invalid value "20s" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
      #|status 2: smock serve: invalid value "-1" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
      #|status 2: smock serve: invalid value "2147483648" for --drain-timeout-ms (SMOCK_DRAIN_TIMEOUT_MS): must be an integer from 0 to 2147483647
      #|status 2: smock serve: invalid value "65536" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "admin" for --admin-port (SMOCK_ADMIN_PORT): must be an integer from 0 to 65535
      #|status 2: smock serve: invalid value "8080" for --admin-port (SMOCK_ADMIN_PORT): must differ from --port (SMOCK_PORT)
      #|status 2: smock serve: invalid value "8443" for --admin-port (SMOCK_ADMIN_PORT): must differ from --tls-port (SMOCK_TLS_PORT)
      #|status 2: smock serve: invalid value "8443" for --admin-port (SMOCK_ADMIN_PORT): must differ from --tls-port (SMOCK_TLS_PORT)
      #|status 2: smock serve: invalid value "false" for --admin-auth (SMOCK_ADMIN_AUTH): must be on or off
      #|status 2: smock serve: invalid value "OFF" for --admin-auth (SMOCK_ADMIN_AUTH): must be on or off
      #|status 2: smock serve: invalid value "" for --admin-token-file (SMOCK_ADMIN_TOKEN_FILE): must not be empty
      #|status 2: smock serve: invalid value "0" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
      #|status 2: smock serve: invalid value "two" for --replicas (SMOCK_REPLICAS): must be an integer from 1 to 10000
      #|status 2: smock serve: invalid value "9007199254740992" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|status 2: smock serve: invalid value "-1" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|status 2: smock serve: invalid value "" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|status 2: smock serve: invalid value "0x2a" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|status 2: smock serve: invalid value "12345678901234567890" for --seed (SMOCK_SEED): must be an integer from 0 to 9007199254740991
      #|status 2: smock serve: invalid value "" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|status 2: smock serve: invalid value "x baggage" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|status 2: smock serve: invalid value "baggage:" for --session-header (SMOCK_SESSION_HEADER): must be a header name, such as baggage
      #|status 2: smock serve: invalid value "smock session" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
      #|status 2: smock serve: invalid value "" for --session-member (SMOCK_SESSION_MEMBER): must be a W3C Baggage key, such as smock-session
      #|status 2: smock serve: invalid value "false" for --journal (SMOCK_JOURNAL): must be on or off
      #|status 2: smock serve: invalid value "OFF" for --journal (SMOCK_JOURNAL): must be on or off
      #|status 2: smock serve: invalid value "0" for --journal-max-entries (SMOCK_JOURNAL_MAX_ENTRIES): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "64MiB" for --journal-max-bytes (SMOCK_JOURNAL_MAX_BYTES): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "1073741825" for --journal-max-bytes (SMOCK_JOURNAL_MAX_BYTES): must be an integer from 1 to 1073741824
      #|status 2: smock serve: invalid value "-1" for --journal-body-limit (SMOCK_JOURNAL_BODY_LIMIT): must be an integer from 0 to 1073741824
    ),
  )
}
