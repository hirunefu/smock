// Seam 2 tests of smock's own lines in the mockoon log format: every line
// smock writes goes to stdout, in Mockoon's envelope (`app`, `level`,
// `message` and `timestamp`, with the line's own fields beside them and the
// keys sorted at every depth), and stderr stays empty. Lines are compared
// whole, byte for byte, with the value of `timestamp` masked once its form
// is checked, and ports and paths the test did not choose replaced.

///|
/// The lines among `lines` whose `message` is one of `messages`, in their
/// order.
fn with_messages(
  lines : Array[String],
  messages : Array[String],
) -> Array[String] {
  lines.filter(line => {
    let entry = @json.parse(line) catch { _ => return false }
    entry is Object({ "message": String(message), .. }) &&
    messages.contains(message)
  })
}

///|
/// `line` with the value of its `timestamp`, wherever the key stands, shown
/// as `<timestamp>` when it has the form `YYYY-MM-DDTHH:mm:ss.sssZ`, and each
/// text of `replace` written as the placeholder it comes with. A value of
/// any other form stays, so that it shows.
fn masked_line(
  line : String,
  replace~ : Array[(String, String)] = [],
) -> String {
  let key = ",\"timestamp\":\""
  let mut line = line
  if line.find(key) is Some(i) {
    let start = i + key.length()
    let end = start + "0000-00-00T00:00:00.000Z".length()
    if end <= line.length() && time_has_form(line[start:end].to_owned()) {
      line = "\{line[:start]}<timestamp>\{line[end:]}"
    }
  }
  for pair in replace {
    let (text, placeholder) = pair
    line = line.replace_all(old=text, new=placeholder)
  }
  line
}

///|
async test "with SMOCK_LOG_FORMAT=mockoon, smock's own lines go to stdout in Mockoon's envelope, keeping their messages and fields, and stderr stays empty" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", "--seed", "42", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let out = []
      let stopped = with_smock(args, env~, smock => {
        // Read while smock runs: a line held in a buffer would not come.
        let replace = [
          ("0.0.0.0:\{smock.admin_port}\"", "0.0.0.0:<admin port>\""),
          ("0.0.0.0:\{smock.port}\"", "0.0.0.0:<plain port>\""),
          ("0.0.0.0:\{smock.tls_port}\"", "0.0.0.0:<TLS port>\""),
          (certs.dir, "<certs>"),
        ]
        for line in with_messages(smock.stdout, ["random seed", "listening"]) {
          out.push(masked_line(line, replace~))
        }
      })
      out.push("stderr: \{stopped.logs.length()} lines")
      inspect(
        out.join("\n"),
        content=(
          #|{"app":"smock","level":"info","message":"random seed","seed":42,"timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<admin port>","app":"smock","level":"info","listener":"admin","message":"listening","timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<plain port>","app":"smock","level":"info","listener":"plain","message":"listening","timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<TLS port>","app":"smock","certFile":"<certs>/rsa-chain.pem","keyFile":"<certs>/rsa-key.pem","level":"info","listener":"tls","message":"listening","timestamp":"<timestamp>"}
          #|stderr: 0 lines
        ),
      )
    })
  })
}

///|
/// What is wrong with the envelope of `line`, or `None`: it must be one JSON
/// object with `app` (`"smock"`), `level` (`info`, `warn` or `error`),
/// `message` and `timestamp` (`YYYY-MM-DDTHH:mm:ss.sssZ`), and its keys
/// sorted at every depth in UTF-16 code-unit order.
fn envelope_problem(line : String) -> String? {
  let entry = @json.parse(line) catch { _ => return Some("not JSON") }
  guard entry
    is Object(
      {
        "app": String("smock"),
        "level": String("info" | "warn" | "error"),
        "message": String(_),
        "timestamp": String(timestamp),
        ..
      }
    ) else {
    return Some("no envelope")
  }
  if !time_has_form(timestamp) {
    return Some("timestamp not of the form YYYY-MM-DDTHH:mm:ss.sssZ")
  }
  if unsorted(entry) is Some(keys) {
    return Some("keys not sorted: \{keys}")
  }
  None
}

///|
/// Whether `time` has the form `YYYY-MM-DDTHH:mm:ss.sssZ`.
fn time_has_form(time : String) -> Bool {
  let form = "0000-00-00T00:00:00.000Z"
  guard time.length() == form.length() else { return false }
  for j, c in form {
    let ok = if c == '0' {
      time[j] >= '0' && time[j] <= '9'
    } else {
      time[j] == c.to_int().to_uint16()
    }
    if !ok {
      return false
    }
  }
  true
}

///|
/// The keys of the first object in `value`, at any depth, whose keys are
/// not in UTF-16 code-unit order, as parsing keeps them in the order the
/// line wrote them, or `None` when every object's keys are.
fn unsorted(value : Json) -> String? {
  match value {
    Object(fields) => {
      let keys = fields.keys().collect()
      for i in 1..<keys.length() {
        if !code_units_before(keys[i - 1], keys[i]) {
          return Some(keys.join(","))
        }
      }
      for _, field in fields {
        if unsorted(field) is Some(keys) {
          return Some(keys)
        }
      }
      None
    }
    Array(items) => {
      for item in items {
        if unsorted(item) is Some(keys) {
          return Some(keys)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Whether `a` comes before `b` in UTF-16 code-unit order.
fn code_units_before(a : String, b : String) -> Bool {
  for i in 0..<a.length() {
    if i >= b.length() {
      return false
    }
    if a[i] != b[i] {
      return a[i] < b[i]
    }
  }
  a.length() < b.length()
}

///|
async test "every line of a run with a reload, a failed reload, an Admin API change, a request and a drain is in Mockoon's envelope, on stdout, with stderr empty" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let mut digests = []
    let mut port = 0
    let stopped = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      port = smock.port
      let before = smock.status()
      let _ = smock.exchange(
        Plain,
        "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
      )
      let _ = smock.call(
        "PUT",
        "/v1/mocks/users/variables/count",
        session="run-42",
        body="1",
      )
      let users = mockoon_mocks()[0].1
      write(
        dir,
        "users.json",
        users.replace(old="\"response\":", new="\"respons\": {}, \"response\":"),
      )
      let failed = smock.reloaded(before)
      write(dir, "users.json", users.replace(old="Alice", new="Bob"))
      let fixed = smock.reloaded(failed)
      digests = [
        ("<served at startup>", before.get("digest")),
        ("<served after the fix>", fixed.get("digest")),
      ]
    })
    let replace = []
    for digest in digests {
      if digest.1 is Some(String(value)) {
        replace.push((value, digest.0))
      }
    }
    let out = []
    for line in stopped.stdout {
      let entry = @json.parse(line) catch { _ => Json::null() }
      let message = match entry {
        Object({ "message": String(message), .. }) =>
          message.replace(old="on port \{port}", new="on port <plain port>")
        _ => "?"
      }
      let problem = match envelope_problem(line) {
        Some(problem) => ": \{problem}: \{line}"
        None => ""
      }
      out.push("\{message}\{problem}")
    }
    out.push("")
    for
      line in with_messages(stopped.stdout, [
        "Variable set", "definitions reload failed", "definitions reloaded",
      ]) {
      out.push(masked_line(line, replace~))
    }
    out.push("stderr: \{stopped.logs.length()} lines")
    inspect(
      out.join("\n"),
      content=(
        #|smock starting
        #|random seed
        #|journal byte bound
        #|state byte bound
        #|listening
        #|self-signed certificate in use
        #|listening
        #|listening
        #|Server started on port <plain port>
        #|Server started on port <plain port>
        #|Transaction recorded
        #|Variable set
        #|definitions reload failed
        #|definitions reloaded
        #|drain started
        #|drain ended
        #|Server stopped
        #|Server stopped
        #|
        #|{"app":"smock","level":"info","message":"Variable set","mock":"users","session":"run-42","timestamp":"<timestamp>","variable":"count"}
        #|{"app":"smock","digest":"<served at startup>","errors":[{"file":"users.json","message":"is not a known field","pointer":"/stubs/0/respons"}],"level":"error","message":"definitions reload failed","result":"failed","timestamp":"<timestamp>"}
        #|{"app":"smock","dataBucketsReset":0,"level":"info","message":"definitions reloaded","newDigest":"<served after the fix>","oldDigest":"<served at startup>","result":"swapped","scenarioStatesReset":0,"timestamp":"<timestamp>"}
        #|stderr: 0 lines
      ),
    )
  })
}

///|
async test "in the mockoon format, invalid definitions, a port taken, no Admin API token and a certificate that cannot be loaded reach stdout before exit status 1, with stderr empty" {
  let env = { "SMOCK_LOG_FORMAT": "mockoon" }
  let fatal = [
    "invalid definitions", "cannot listen", "no Admin API token", "cannot load the TLS certificate",
  ]
  let out = []
  let report = (
    name : String,
    stopped : Stopped,
    replace : Array[(String, String)],
  ) => {
    out.push(
      "\{name}: status \{stopped.status}, \{stopped.stdout.length()} lines on stdout, \{stopped.logs.length()} on stderr",
    )
    for line in with_messages(stopped.stdout, fatal) {
      out.push(masked_line(line, replace~))
    }
  }
  let broken =
    #|{ "stubs": [{ "id": "", "mock": "default",
    #|  "request": { "method": "GET", "path": "/" },
    #|  "response": { "status": 200 } }] }
  with_definitions([("broken.json", broken)], dir => {
    report(
      "invalid definitions",
      run_smock(["serve", "--dir", dir, "--port", "0"], env~),
      [],
    )
  })
  let _ = with_smock(["--port", "0"], first => {
    let port = first.port.to_string()
    report("a port taken", run_smock(["serve", "--port", port], env~), [
      (":\{port}\"", ":<taken port>\""),
    ])
  })
  report(
    "no Admin API token",
    run_smock(["serve", "--port", "0"], env={
      "SMOCK_LOG_FORMAT": "mockoon",
      "SMOCK_ADMIN_TOKEN": "",
    }),
    [],
  )
  with_certificates(certs => {
    let missing = "\{certs.dir}/missing.pem"
    report(
      "a certificate that cannot be loaded",
      run_smock(["serve", "--port", "0", ..certs.args(cert=missing)], env~),
      [(certs.dir, "<certs>")],
    )
  })
  inspect(
    out.join("\n"),
    content=(
      #|invalid definitions: status 1, 7 lines on stdout, 0 on stderr
      #|{"app":"smock","error":"must be a non-empty string","file":"broken.json","level":"error","message":"invalid definitions","pointer":"/stubs/0/id","timestamp":"<timestamp>"}
      #|{"app":"smock","error":"no file declares the Mock \"default\"","file":"broken.json","level":"error","message":"invalid definitions","pointer":"/stubs/0/mock","timestamp":"<timestamp>"}
      #|a port taken: status 1, 7 lines on stdout, 0 on stderr
      #|{"address":"0.0.0.0:<taken port>","app":"smock","error":"OSError(\"@socket.TcpServer::new(): Address already in use\")","level":"error","listener":"plain","message":"cannot listen","timestamp":"<timestamp>"}
      #|no Admin API token: status 1, 2 lines on stdout, 0 on stderr
      #|{"app":"smock","error":"Admin API authentication is on, but no token is set: set --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) or SMOCK_ADMIN_TOKEN, or turn authentication off with --admin-auth off","level":"error","message":"no Admin API token","timestamp":"<timestamp>"}
      #|a certificate that cannot be loaded: status 1, 6 lines on stdout, 0 on stderr
      #|{"app":"smock","certFile":"<certs>/missing.pem","error":"cannot read the certificate file: no such file","keyFile":"<certs>/rsa-key.pem","level":"error","message":"cannot load the TLS certificate","mock":"","timestamp":"<timestamp>"}
    ),
  )
}

///|
async test "in the mockoon format, a usage error is still plain text on stderr, with status 2 and nothing on stdout" {
  let out = []
  for
    run in [
      (["serve", "--port", "x"], { "SMOCK_LOG_FORMAT": "mockoon" }),
      (["serve", "--log-format", "mockoon", "--journal", "x"], Map([])),
    ] {
    let (args, env) = run
    let stopped = run_smock(args, env~)
    out.push(
      "status \{stopped.status}, \{stopped.stdout.length()} lines on stdout\n\{stopped.logs.join("\n")}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|status 2, 0 lines on stdout
      #|smock serve: invalid value "x" for --port (SMOCK_PORT): must be an integer from 0 to 65535
      #|status 2, 0 lines on stdout
      #|smock serve: invalid value "x" for --journal (SMOCK_JOURNAL): must be on or off
    ),
  )
}
