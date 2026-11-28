///|
async test "smock serve answers a request that matches a Stub with that Stub's response" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/1"),
        content=(
          #|200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
    })
  })
}

///|
/// `users` written in YAML.
let users_yaml : String =
  #|mocks:
  #|  - name: users
  #|stubs:
  #|  - id: get-user
  #|    mock: users
  #|    request: { method: GET, path: /users/1 }
  #|    response:
  #|      status: 200
  #|      headers:
  #|        Content-Type: application/json
  #|        X-Source: smock
  #|      body: '{"id":1,"name":"Alice"}'

///|
async test "smock serve answers a request that matches a Stub declared in a YAML file" {
  with_definitions([("users.yaml", users_yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/1"),
        content=(
          #|200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
    })
  })
}

///|
async test "any other request gets the no-match response" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.get("/users/2"),
        content=(
          #|404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: get-user; failed=path
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "with an invalid definition set, smock logs every error with its file and JSON Pointer and exits with status 1" {
  // No document states the words of smock/yaml's "unterminated double-quoted
  // value"; the maintainer confirmed them as the code has them on 2026-11-26
  // (the twenty-seventh round of #275's answers, #323).
  with_definitions(
    [
      ("users.json", users),
      ("broken.json", "{ \"stubs\": [{ \"id\": 7, \"mock\": \"users\" }] }"),
      (
        "orders.yaml", "stubs:\n  - id: get-order\n    mock: users\n    request: { method: on }\n",
      ),
      ("payments.yml", "mocks:\n  - name: \"payments\n"),
      ("refunds.yaml", "mocks: [{ name: refunds }]\n---\nstubs: []\n"),
    ],
    dir => {
      let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
      inspect(
        "status \{stopped.status}\n" + log_entries(stopped.logs),
        content=(
          #|status 1
          #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
          #|{"level":"info","msg":"random seed","seed":"*"}
          #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
          #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
          #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
          #|{"level":"error","msg":"invalid definitions","file":"broken.json","pointer":"/stubs/0/id","error":"must be a non-empty string"}
          #|{"level":"error","msg":"invalid definitions","file":"broken.json","pointer":"/stubs/0","error":"needs \"response\", \"responses\" or \"crud\""}
          #|{"level":"error","msg":"invalid definitions","file":"orders.yaml","pointer":"/stubs/0/request/method","error":"\"on\" may be read as a boolean; quote this value"}
          #|{"level":"error","msg":"invalid definitions","file":"payments.yml","pointer":"/mocks/0/name","error":"unterminated double-quoted value"}
          #|{"level":"error","msg":"invalid definitions","file":"refunds.yaml","pointer":"","error":"multiple documents are not supported"}
        ),
      )
    },
  )
}

///|
async test "when the port is taken, smock logs that it cannot listen and exits with status 1" {
  let _ = with_smock(["--port", "0"], first => {
    let second = run_smock(["serve", "--port", first.port.to_string()])
    inspect(
      "status \{second.status}\n\{log_entries(second.logs)}",
      content=(
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
        #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
        #|{"level":"error","msg":"cannot listen","listener":"plain","address":"0.0.0.0:*","error":"OSError(\"@socket.TcpServer::new(): Address already in use\")"}
      ),
    )
  })
}

///|
async test "logs start with the startup entry, then the random seed, the Journal's byte bound, the listening addresses and the TLS certificate, end with the drain, and have no per-request lines" {
  with_definitions([("users.json", users)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let _ = smock.get("/users/1")
      let _ = smock.get("/users/2")
    })
    inspect(
      "status \{stopped.status}\n" + log_entries(stopped.logs),
      content=(
        #|status 0
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
        #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*","protocols":["http/1.1","h2c"]}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","protocols":["h2","http/1.1"]}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
/// The output of `command args`, without the whitespace around it, or
/// `None` when it fails.
async fn command_output(command : String, args : Array[String]) -> String? {
  let (status, out) = @process.collect_stdout(command, args) catch {
    _ => return None
  }
  guard status == 0 else { return None }
  Some(out.text().trim().to_owned())
}

///|
async test "smock --version names the commit checked out and the toolchain in use, however long ago the binary was first built" {
  // As buildinfo/gen_build_info.sh documents it: SMOCK_COMMIT, or else the
  // checked-out commit, or else `unknown`.
  let commit = match @env.get_env_var("SMOCK_COMMIT") {
    Some(commit) => commit
    None =>
      command_output("git", ["rev-parse", "--short=12", "HEAD"]).unwrap_or(
        "unknown",
      )
  }
  let moonc = command_output("moonc", ["-v"]).unwrap_or("")
  let toolchain = "moonc \{moonc[:moonc.find(" ").unwrap_or(moonc.length())]}"
  let (_, version_line) = smock_stdout(["--version"])
  let (_, built_commit, built_toolchain) = version_parts(version_line)
  assert_eq(built_commit, commit)
  assert_eq(built_toolchain, toolchain)
}

///|
/// The commands of the `smock` binary that the usage lists, in order: the
/// first word of each line under `Commands:`.
fn listed_commands(usage : String) -> Array[String] {
  let out = []
  let mut listing = false
  for line in usage.split("\n") {
    if line == "Commands:" {
      listing = true
    } else if listing && line.has_prefix("  ") {
      out.push(line.trim_start().split(" ").next().unwrap_or("").to_owned())
    } else {
      listing = false
    }
  }
  out
}

///|
async test "smock, smock help and smock --help print one usage, which lists the commands docs/commands.md names and says what smock serves as the README's opening line does" {
  let (_, usage, _) = smock_output(["--help"])
  let out = []
  // #370's criterion: the three print one usage, and nothing on stderr.
  // docs/commands.md: "`smock` alone, `smock help` and `smock --help` print
  // a usage that lists them, and exit with status 0."
  for args in [[], ["help"], ["--help"]] {
    let (status, stdout, stderr) = smock_output(args)
    out.push(
      "\{["smock", ..args].join(" ")}: status \{status}, the usage: \{stdout == usage}, stderr: \{stderr.length()} bytes",
    )
  }
  // docs/commands.md: "The `smock` binary has four commands beside `help`",
  // which it names.
  out.push("commands: \{listed_commands(usage).join(", ")}")
  // README.md opens with "smock is a mock server for ...": the usage's
  // description says the same, as "A mock server for ...".
  let readme = @fs.read_file("README.md").text().replace_all(old="\n", new=" ")
  guard readme.find("smock is a ") is Some(start) else {
    fail("README.md does not say what smock is")
  }
  let opening = readme[start:]
  let opening = opening[:opening.find(". ").unwrap_or(opening.length() - 1) + 1].to_owned()
  let description = usage.split("\n").nth(2).unwrap_or("").to_owned()
  inspect(
    out.join("\n"),
    content=(
      #|smock: status 0, the usage: true, stderr: 0 bytes
      #|smock help: status 0, the usage: true, stderr: 0 bytes
      #|smock --help: status 0, the usage: true, stderr: 0 bytes
      #|commands: serve, check, render, import-openapi, help
    ),
  )
  assert_eq("smock is a\{description[1:]}", opening)
}
