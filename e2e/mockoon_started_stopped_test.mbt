// Seam 2 tests of the `Server started on port …` and `Server stopped` lines
// of the mockoon log format: one of each per Mock, the started lines once
// the plain and TLS listeners are open, the stopped lines when the drain
// after SIGTERM ends, and none on a reload. Lines are compared whole, byte
// for byte, with the value of `timestamp` masked once its form is checked
// and the ports smock picked replaced.

///|
/// Whether `line` is a `Server started on port …` or a `Server stopped`
/// line.
fn is_server_line(line : String) -> Bool {
  line.contains("\"message\":\"Server started on port ") ||
  line.contains("\"message\":\"Server stopped\"")
}

///|
/// Waits until smock has written `count` `Server started on port …` lines
/// to stdout, while it runs, and returns every line of stdout so far.
async fn Smock::started_lines(self : Smock, count : Int32) -> Array[String] {
  let started = () => {
    self.stdout
    .iter()
    .filter(line => line.contains("\"message\":\"Server started on port "))
    .count()
  }
  let written = @async.with_timeout_opt(patience_ms, () => {
    while started() < count {
      @async.sleep(10)
    }
  })
  guard written is Some(_) else {
    fail(
      "smock wrote \{started()} of \{count} Server started lines in time:\n\{self.stdout.join("\n")}",
    )
  }
  self.stdout.copy()
}

///|
/// The ports of `smock` as placeholders, for `masked_line`.
fn port_placeholders(smock : Smock) -> Array[(String, String)] {
  [
    ("0.0.0.0:\{smock.port}\"", "0.0.0.0:<plain port>\""),
    ("0.0.0.0:\{smock.tls_port}\"", "0.0.0.0:<TLS port>\""),
    ("on port \{smock.port}\"", "on port <plain port>\""),
  ]
}

///|
async test "two Mocks get a Server started line each, right after the TLS port's listening line, with the plain port --port 0 picked, read while smock runs" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let out = []
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      // Read while smock runs, as a readiness script reads them.
      let lines = smock.started_lines(2)
      guard lines.search_by(line => listening(line) is Some(("tls", _)))
        is Some(tls) else {
        fail("no listening line of the TLS port:\n\{lines.join("\n")}")
      }
      for line in lines[tls:] {
        out.push(masked_line(line, replace=port_placeholders(smock)))
      }
    })
    inspect(
      out.join("\n"),
      content=(
        #|{"address":"0.0.0.0:<TLS port>","app":"smock","level":"info","listener":"tls","message":"listening","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"users","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"orders","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
      ),
    )
  })
}

///|
async test "with no definitions directory, the lines name the empty Default Mock, default, and SIGTERM writes its Server stopped line right after drain ended" {
  let env = { "SMOCK_LOG_FORMAT": "mockoon" }
  let mut replace = []
  let stopped = with_smock(["--port", "0"], env~, smock => {
    replace = port_placeholders(smock)
    let _ = smock.started_lines(1)
  })
  let out = []
  guard stopped.stdout.search_by(line => {
      line.contains("\"message\":\"drain ended\"")
    })
    is Some(ended) else {
    fail("no drain ended line:\n\{stopped.stdout.join("\n")}")
  }
  for line in stopped.stdout.filter(is_server_line) {
    out.push(masked_line(line, replace~))
  }
  out.push("after drain ended: \{stopped.stdout.length() - 1 - ended} lines")
  out.push("exit status \{stopped.status}")
  inspect(
    out.join("\n"),
    content=(
      #|{"app":"smock","environmentName":"default","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
      #|{"app":"smock","environmentName":"default","level":"info","message":"Server stopped","timestamp":"<timestamp>"}
      #|after drain ended: 1 lines
      #|exit status 0
    ),
  )
}

///|
async test "a reload that adds a Mock, one that changes nothing and one that fails write no started or stopped line, and SIGTERM writes three Server stopped lines right after drain ended" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let payments =
      #|{ "mocks": [{ "name": "payments", "hosts": ["payments.example.com"] }],
      #|  "stubs": [{ "id": "charge", "mock": "payments",
      #|    "request": { "method": "POST", "path": "/charges" },
      #|    "response": { "status": 201 } }] }
    let out = []
    let mut replace = []
    let stopped = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      replace = port_placeholders(smock)
      let _ = smock.started_lines(2)
      let mut status = smock.status()
      let steps = [
        ("add a Mock", "payments.json", payments),
        ("write a Definition file again", "users.json", mockoon_mocks()[0].1),
        ("break a Definition file", "payments.json", "{"),
      ]
      for step in steps {
        let (name, file, text) = step
        write(dir, file, text)
        status = smock.reloaded(status)
        out.push("\{name}: \{last_reload(status)}")
      }
      let mocks = match status.get("mocks") {
        Some(Array(mocks)) =>
          mocks.map(mock => {
            match mock {
              Object({ "name": String(name), .. }) => name
              _ => "?"
            }
          })
        _ => []
      }
      out.push("the Admin API's status lists: \{mocks.join(", ")}")
    })
    // Every line from the first started line on: smock's own lines by
    // their message, the started and stopped lines whole.
    guard stopped.stdout.search_by(is_server_line) is Some(first) else {
      fail("no Server started line:\n\{stopped.stdout.join("\n")}")
    }
    for line in stopped.stdout[first:] {
      if is_server_line(line) {
        out.push(masked_line(line, replace~))
      } else {
        match @json.parse(line) {
          Object({ "message": String(message), .. }) => out.push(message)
          _ => out.push(line)
        }
      }
    }
    out.push("exit status \{stopped.status}")
    inspect(
      out.join("\n"),
      content=(
        #|add a Mock: "swapped"
        #|write a Definition file again: "unchanged"
        #|break a Definition file: "failed"
        #|  {"file":"payments.json","pointer":"","message":"not valid JSON: Unexpected end of file"}
        #|the Admin API's status lists: payments, users, orders
        #|{"app":"smock","environmentName":"users","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"orders","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|definitions reloaded
        #|self-signed certificate in use
        #|definitions reloaded
        #|definitions reload failed
        #|drain started
        #|drain ended
        #|{"app":"smock","environmentName":"payments","level":"info","message":"Server stopped","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"users","level":"info","message":"Server stopped","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"orders","level":"info","message":"Server stopped","timestamp":"<timestamp>"}
        #|exit status 0
      ),
    )
  })
}

///|
async test "SIGINT and SIGHUP, which end smock at once, write no Server stopped line" {
  with_definitions(mockoon_mocks(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let out = []
    for signal in ["INT", "HUP"] {
      let mut replace = []
      let stopped = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
        replace = port_placeholders(smock)
        let _ = smock.started_lines(2)
        let _ = @process.run("kill", ["-\{signal}", smock.pid.to_string()])
        let _ = smock.exited()
      })
      out.push("SIG\{signal}: exit status \{stopped.status}")
      for line in stopped.stdout.filter(is_server_line) {
        out.push(masked_line(line, replace~))
      }
    }
    inspect(
      out.join("\n"),
      content=(
        #|SIGINT: exit status -2
        #|{"app":"smock","environmentName":"users","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"orders","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|SIGHUP: exit status -1
        #|{"app":"smock","environmentName":"users","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
        #|{"app":"smock","environmentName":"orders","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
      ),
    )
  })
}
