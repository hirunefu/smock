// Seam 2 tests of the Admin API foundation: authentication, the replica
// header and warning, the error shape and status. Every response is checked
// against the OpenAPI document (contract_test.mbt).

///|
/// Two Mocks with Hosts; `users` is the Default Mock.
let status_mocks : String =
  #|mocks:
  #|  - name: users
  #|    hosts: [users.example.com, "Users.Example.com:8080"]
  #|    default: true
  #|  - name: orders
  #|    hosts: [orders.example.com]

///|
async test "status shows the build smock --version prints, and the Mocks with their Hosts and the Default Mock" {
  let (_, version_line) = smock_stdout(["--version"])
  with_definitions([("mocks.yaml", status_mocks)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let response = smock.admin("GET", "/v1/status")
      guard response.json() is Object(status) &&
        status.get("version") is Some(String(version)) &&
        status.get("commit") is Some(String(commit)) &&
        status.get("toolchain") is Some(String(toolchain)) else {
        fail("no build in \{response.body}")
      }
      inspect(
        "smock \{version} (commit \{commit}, \{toolchain})" ==
        version_line.trim().to_owned(),
        content="true",
      )
      json_inspect(status.get("mocks").unwrap_or(Json::null()), content=[
        {
          "name": "users",
          "hosts": ["users.example.com", "Users.Example.com:8080"],
          "default": true,
        },
        { "name": "orders", "hosts": ["orders.example.com"], "default": false },
      ])
      json_inspect(status.get("warnings").unwrap_or(Json::null()), content=[])
    })
  })
}

///|
async test "without Definition files, status shows the one empty Default Mock" {
  let _ = with_smock(["--port", "0"], smock => {
    let response = smock.admin("GET", "/v1/status")
    guard response.json() is Object(status) else { fail(response.body) }
    json_inspect(status.get("mocks").unwrap_or(Json::null()), content=[
      { "name": "default", "hosts": [], "default": true },
    ])
  })
}

///|
/// A response as its status, the headers a test cares about and its body,
/// one per line.
fn summary(response : AdminResponse) -> String {
  let out = StringBuilder()
  out.write_string("\{response.status}")
  for name in ["WWW-Authenticate", "Allow"] {
    if response.header(name) is Some(value) {
      out.write_string("\n\{name}: \{value}")
    }
  }
  out.write_string("\n\{response.body}")
  out.to_string()
}

///|
async test "a missing or wrong bearer token gets 401 with WWW-Authenticate: Bearer; the right one gets through" {
  let _ = with_smock(["--port", "0"], smock => {
    let calls = [
      ("no token", smock.admin("GET", "/v1/status", token=None)),
      ("a wrong token", smock.admin("GET", "/v1/status", token=Some("wrong"))),
      (
        "a prefix of the token",
        smock.admin("GET", "/v1/status", token=Some(test_token[:4].to_owned())),
      ),
      (
        "the token with a character more",
        smock.admin("GET", "/v1/status", token=Some(test_token + "x")),
      ),
      (
        "the token in Basic credentials",
        smock.admin("GET", "/v1/status", token=None, headers=[
          ("Authorization", "Basic \{test_token}"),
        ]),
      ),
    ]
    let out = []
    for call in calls {
      let (name, response) = call
      out.push("\{name}: \{summary(response)}")
    }
    let right = smock.admin("GET", "/v1/status")
    out.push("the right token: \{right.status}")
    inspect(
      out.join("\n"),
      content=(
        #|no token: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
        #|a wrong token: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the bearer token is wrong","warnings":[]}
        #|a prefix of the token: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the bearer token is wrong","warnings":[]}
        #|the token with a character more: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the bearer token is wrong","warnings":[]}
        #|the token in Basic credentials: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
        #|the right token: 200
      ),
    )
  })
}

///|
async test "with --admin-auth off, no operation needs a token, and the startup entry says authentication is off" {
  let out = []
  let stopped = with_smock(
    ["--port", "0", "--admin-auth", "off"],
    env={ "SMOCK_ADMIN_TOKEN": "" },
    smock => {
      for call in [("no token", None), ("any token", Some("anything"))] {
        let (name, token) = call
        let response = smock.admin("GET", "/v1/status", token~)
        out.push("\{name}: \{response.status}")
      }
    },
  )
  out.push(log_entries([stopped.logs[0]]))
  inspect(
    out.join("\n"),
    content=(
      #|no token: 200
      #|any token: 200
      #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"off"}
    ),
  )
}

///|
async test "authentication is on by default, and the startup entry says so" {
  let stopped = with_smock(["--port", "0"], smock => {
    inspect(smock.admin("GET", "/v1/status", token=None).status, content="401")
  })
  inspect(
    log_entries([stopped.logs[0]]),
    content=(
      #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
    ),
  )
}

///|
async test "with authentication on, smock refuses to start without exactly one token, logs why and exits with status 1" {
  with_definitions([("empty-token", " \n"), ("token", "from-file\n")], dir => {
    let runs = [
      ("no token", [], { "SMOCK_ADMIN_TOKEN": "" }),
      ("a blank SMOCK_ADMIN_TOKEN", [], { "SMOCK_ADMIN_TOKEN": " \t" }),
      (
        "an empty token file",
        ["--admin-token-file", "\{dir}/empty-token"],
        { "SMOCK_ADMIN_TOKEN": "" },
      ),
      (
        "a missing token file",
        ["--admin-token-file", "\{dir}/missing"],
        { "SMOCK_ADMIN_TOKEN": "" },
      ),
      (
        "a token file and SMOCK_ADMIN_TOKEN",
        ["--admin-token-file", "\{dir}/token"],
        { "SMOCK_ADMIN_TOKEN": "from-variable" },
      ),
    ]
    let out = []
    for run in runs {
      let (name, args, env) = run
      let stopped = run_smock(["serve", "--port", "0", ..args], env~)
      out.push(
        "\{name}: status \{stopped.status}\n" +
        log_entries(stopped.logs[1:].to_owned()).replace_all(
          old=dir,
          new="<dir>",
        ),
      )
    }
    inspect(
      out.join("\n"),
      content=(
        #|no token: status 1
        #|{"level":"error","msg":"no Admin API token","error":"Admin API authentication is on, but no token is set: set --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) or SMOCK_ADMIN_TOKEN, or turn authentication off with --admin-auth off"}
        #|a blank SMOCK_ADMIN_TOKEN: status 1
        #|{"level":"error","msg":"no Admin API token","error":"Admin API authentication is on, but no token is set: set --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) or SMOCK_ADMIN_TOKEN, or turn authentication off with --admin-auth off"}
        #|an empty token file: status 1
        #|{"level":"error","msg":"no Admin API token","error":"the token file \"<dir>/empty-token\" is empty"}
        #|a missing token file: status 1
        #|{"level":"error","msg":"no Admin API token","error":"cannot read the token file \"<dir>/missing\": no such file"}
        #|a token file and SMOCK_ADMIN_TOKEN: status 1
        #|{"level":"error","msg":"no Admin API token","error":"both --admin-token-file (SMOCK_ADMIN_TOKEN_FILE) and SMOCK_ADMIN_TOKEN are set; set only one"}
      ),
    )
  })
}

///|
async test "the token can come from a file, without the whitespace around it" {
  with_definitions([("token", "  from-file\n")], dir => {
    let _ = with_smock(
      ["--port", "0", "--admin-token-file", "\{dir}/token"],
      env={ "SMOCK_ADMIN_TOKEN": "" },
      smock => {
        let out = []
        for token in ["from-file", test_token] {
          let response = smock.admin("GET", "/v1/status", token=Some(token))
          out.push("\{token}: \{response.status}")
        }
        inspect(
          out.join("\n"),
          content=(
            #|from-file: 200
            #|e2e-admin-token: 401
          ),
        )
      },
    )
  })
}

///|
/// Requests that get a response of each kind: a success, the errors of
/// authentication, routing and the request body, and an error from the
/// HTTP/1.1 codec, which closes the connection.
async fn each_kind(smock : Smock) -> Array[(String, String, AdminResponse)] {
  [
    ("GET", "/v1/status", smock.admin("GET", "/v1/status")),
    ("GET", "/v1/status", smock.admin("GET", "/v1/status", token=None)),
    ("GET", "/v1/nowhere", smock.admin("GET", "/v1/nowhere")),
    ("DELETE", "/v1/status", smock.admin("DELETE", "/v1/status")),
    ("POST", "/v1/reset", smock.admin("POST", "/v1/reset", body="{\"scope\":")),
    (
      "GET",
      "/v1/status",
      smock.admin("GET", "/v1/status", headers=[("X-Big", "x".repeat(17000))]),
    ),
  ]
}

///|
async test "every Admin API response, errors included, names the replica that handled it: the host name" {
  let (_, uname) = collect_stdout("uname", ["-n"])
  let host = uname.text().trim().to_owned()
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for call in each_kind(smock) {
      let (meth, path, response) = call
      let replica = response.header("Smock-Replica")
      out.push("\{meth} \{path} \{response.status}: \{replica == Some(host)}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|GET /v1/status 200: true
        #|GET /v1/status 401: true
        #|GET /v1/nowhere 404: true
        #|DELETE /v1/status 405: true
        #|POST /v1/reset 400: true
        #|GET /v1/status 431: true
      ),
    )
  })
}

///|
async test "errors take the form {error, message, warnings}: a missing token, an unknown operation or method, malformed JSON, a request over a limit" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for call in each_kind(smock)[1:] {
      let (meth, path, response) = call
      out.push("\{meth} \{path}: \{summary(response)}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|GET /v1/status: 401
        #|WWW-Authenticate: Bearer
        #|{"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
        #|GET /v1/nowhere: 404
        #|{"error":"not_found","message":"no Admin API operation at /v1/nowhere","warnings":[]}
        #|DELETE /v1/status: 405
        #|Allow: GET, HEAD
        #|{"error":"method_not_allowed","message":"/v1/status takes GET, HEAD, not DELETE","warnings":[]}
        #|POST /v1/reset: 400
        #|{"error":"malformed_json","message":"the body is not valid JSON: Unexpected end of file","warnings":[]}
        #|GET /v1/status: 431
        #|{"error":"header_fields_too_large","message":"the request head is over the header limits (--header-size-limit, --header-count-limit)","warnings":[]}
      ),
    )
  })
}

///|
async test "with more than one replica, every JSON response, errors included, warns that state is per replica" {
  let (_, uname) = collect_stdout("uname", ["-n"])
  let host = uname.text().trim().to_owned()
  let warnings = []
  let _ = with_smock(["--port", "0"], env={ "SMOCK_REPLICAS": "3" }, smock => {
    for call in each_kind(smock) {
      let (_, _, response) = call
      guard response.json() is Object(body) && body.get("warnings") is Some(w) else {
        fail("no warnings in \{response.body}")
      }
      warnings.push(w.stringify().replace_all(old=host, new="<host>"))
    }
  })
  let distinct = Set::from_array(warnings)
  inspect(
    "\{warnings.length()} responses, \{distinct.length()} kind of warnings:\n\{distinct.iter().collect().join("\n")}",
    content=(
      #|6 responses, 1 kind of warnings:
      #|[{"code":"per_replica_state","message":"This deployment runs 3 replicas (--replicas), and each one keeps its own Ephemeral Stubs, Scenario state, Variables, copies of Data buckets and Journal. This response comes from <host> alone."}]
    ),
  )
}

///|
async test "with one replica, the default, warnings are empty" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for call in each_kind(smock) {
      let (_, _, response) = call
      guard response.json() is Object(body) && body.get("warnings") is Some(w) else {
        fail("no warnings in \{response.body}")
      }
      out.push(w.stringify())
    }
    inspect(out.join(" "), content="[] [] [] [] [] []")
  })
}
