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
      #|  -h, --help                       Show help information.
      #|  --dir <dir>                      The definitions directory. Without it, smock serves one empty Default Mock. [env: SMOCK_DIR]
      #|  --port <port>                    The plain HTTP port. 0 picks a free port. [env: SMOCK_PORT] [default: 8080]
      #|  --tls-port <tls-port>            The HTTPS port, served when --tls-cert-file and --tls-key-file are set. 0 picks a free port. [env: SMOCK_TLS_PORT] [default: 8443]
      #|  --tls-cert-file <tls-cert-file>  The PEM certificate chain for the HTTPS port: the leaf certificate, then its intermediates. [env: SMOCK_TLS_CERT_FILE]
      #|  --tls-key-file <tls-key-file>    The PEM private key of the leaf certificate in --tls-cert-file. [env: SMOCK_TLS_KEY_FILE]
      #|  --log-format <log-format>        The log format: json. [env: SMOCK_LOG_FORMAT] [default: json]
      #|  --body-file-dir <body-file-dir>  The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
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
    (["--log-format", "text"], Map([])),
    ([], { "SMOCK_LOG_FORMAT": "" }),
    (["--dir", ""], Map([])),
    (["--body-file-dir", "../files"], Map([])),
    ([], { "SMOCK_BODY_FILE_DIR": "/srv/files" }),
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
      #|status 2: smock serve: invalid value "text" for --log-format (SMOCK_LOG_FORMAT): must be json
      #|status 2: smock serve: invalid value "" for --log-format (SMOCK_LOG_FORMAT): must be json
      #|status 2: smock serve: invalid value "" for --dir (SMOCK_DIR): must not be empty
      #|status 2: smock serve: invalid value "../files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
      #|status 2: smock serve: invalid value "/srv/files" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
    ),
  )
}
