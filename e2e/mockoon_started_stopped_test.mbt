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
