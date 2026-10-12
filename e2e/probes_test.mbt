// Seam 2 tests of the probes on the admin port: /startupz, /readyz and
// /livez. Every probe response is checked against the OpenAPI document
// (contract_test.mbt).

///|
/// The probes, in the order the tests show them.
let probes : Array[String] = ["/startupz", "/readyz", "/livez"]

///|
/// Each probe's answer, without a token, as `<path>: <status> <body>`, one
/// per line, each checked against the document.
async fn Smock::probes(self : Smock) -> String {
  let out = []
  for path in probes {
    let response = self.admin("GET", path, token=None)
    conforms("GET", path, response)
    out.push("\{path}: \{response.status} \{response.body}")
  }
  out.join("\n")
}

///|
async test "the probes need no token while authentication is on, and pass once smock serves" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      inspect(
        smock.probes(),
        content=(
          #|/startupz: 200 {"status":"ok","warnings":[]}
          #|/readyz: 200 {"status":"ok","warnings":[]}
          #|/livez: 200 {"status":"ok","warnings":[]}
        ),
      )
    })
  })
}

///|
/// Starts `smock serve <args>` and runs `f` as soon as smock listens on its
/// admin port, which it opens before it loads its definitions; then stops
/// smock with SIGTERM and waits for it to exit. `f` gets smock without its
/// plain port, which is not known yet (0).
async fn while_starting(
  args : Array[String],
  f : async (Smock) -> Unit,
) -> Unit {
  build.wait()
  @async.with_task_group(group => {
    let (stderr, stderr_end) = @process.read_from_process()
    defer stderr.close()
    let process = @process.spawn(
      group,
      binary,
      ["serve", ..args],
      extra_env=smock_env(Map([])),
      inherit_env=false,
      stderr=stderr_end,
      no_wait=true,
    )
    let admin_port = @async.with_timeout_opt(patience_ms, () => {
      for ;; {
        guard stderr.read_until("\n") is Some(line) else {
          fail("smock exited before it listened on its admin port")
        }
        if listening(line) is Some(("admin", port)) {
          break port
        }
      }
    })
    guard admin_port is Some(admin_port) else {
      fail("smock did not listen on its admin port in time")
    }
    f({ port: 0, admin_port, tls_port: None, pid: process.pid, process, })
    let _ = @process.run("kill", ["-TERM", process.pid.to_string()])
    let status = @async.with_timeout_opt(patience_ms, () => process.wait())
    guard status is Some(_) else { fail("smock did not stop in time") }
  })
}

///|
/// What the probes and status answer, without a token for the probes, as
/// `<path> <status>`, with the error code of a failure.
async fn Smock::startup_state(self : Smock) -> String {
  let out = []
  for path in [..probes, "/v1/status"] {
    let token = if path == "/v1/status" { Some(test_token) } else { None }
    let response = self.admin("GET", path, token~)
    conforms("GET", path, response)
    let code = match response.json() {
      Object(body) =>
        match body.get("error") {
          Some(String(code)) => " \{code}"
          _ => ""
        }
      _ => ""
    }
    out.push("\{path} \{response.status}\{code}")
  }
  out.join(", ")
}

///|
async test "until the first definition set has loaded, /startupz and /readyz fail with not_started while /livez passes" {
  // Enough Definition files that smock takes a while to load them, so that
  // the first answers come before it has.
  let files = [("mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }")]
  for i in 0..<3000 {
    files.push(
      (
        "stub-\{i}.json",
        "{ \"stubs\": [{ \"id\": \"s\{i}\", \"mock\": \"m\", \"request\": { \"path\": \"/\{i}\" }, \"response\": { \"status\": 200 } }] }",
      ),
    )
  }
  with_definitions(files, dir => {
    while_starting(["--dir", dir, "--port", "0"], smock => {
      let first = smock.startup_state()
      let mut last = first
      let mut startup_passed = false
      let mut startup_kept = true
      let started = @async.with_timeout_opt(patience_ms, () => {
        while !last.has_prefix("/startupz 200, /readyz 200") {
          last = smock.startup_state()
          let startup = last.has_prefix("/startupz 200")
          if startup_passed && !startup {
            startup_kept = false
          }
          startup_passed = startup_passed || startup
        }
      })
      guard started is Some(_) else { fail("smock did not start in time") }
      inspect(
        (
          $|first: \{first}
          $|then: \{last}
          $|/startupz never failed again once it passed: \{startup_kept}
        ),
        content=(
          #|first: /startupz 503 not_started, /readyz 503 not_started, /livez 200, /v1/status 503 not_started
          #|then: /startupz 200, /readyz 200, /livez 200, /v1/status 200
          #|/startupz never failed again once it passed: true
        ),
      )
    })
  })
}

///|
async test "after a failed reload, /readyz still passes and the previous definition set keeps serving" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      write(dir, "users.json", "{ \"stubs\": [{ \"id\": 7 }] }")
      let after = smock.reloaded(before)
      inspect(
        (
          $|reload: \{last_reload(after).split("\n").next().unwrap_or("")}
          $|\{smock.probes()}
          $|/users/1: \{smock.brief("/users/1")}
        ),
        content=(
          #|reload: "failed"
          #|/startupz: 200 {"status":"ok","warnings":[]}
          #|/readyz: 200 {"status":"ok","warnings":[]}
          #|/livez: 200 {"status":"ok","warnings":[]}
          #|/users/1: 200 {"id":1,"name":"Alice"}
        ),
      )
    })
  })
}
