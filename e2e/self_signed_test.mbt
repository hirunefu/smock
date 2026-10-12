// Seam 2 tests of the self-signed certificate smock generates when no
// certificate files are configured. The tests read the certificate the TLS
// port presents with `openssl s_client`, and then trust only that
// certificate.

///|
/// Creates a temporary directory, runs `f` with its path and removes it.
async fn with_scratch(f : async (String) -> Unit) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-scratch-")
  defer @fs.rmdir(dir, recursive=true)
  f(dir)
}

///|
/// The certificate the TLS port presents to a new connection, as a client
/// that does not verify it sees it.
struct Presented {
  /// A file that holds it in PEM.
  file : String
  /// Its SHA-256 fingerprint, as `openssl x509 -fingerprint -sha256`
  /// prints it.
  fingerprint : String
  /// Its subject alternative names, as `openssl x509` prints them.
  names : String
  subject : String
  issuer : String
}

///|
/// Runs `openssl <args>` and returns its exit status and its standard
/// output.
async fn run_openssl(args : Array[String], stdin? : String) -> (Int, String) {
  let result = @async.with_timeout_opt(patience_ms, () => {
    match stdin {
      Some(path) =>
        @process.collect_output(
          "openssl",
          args,
          stdin=@process.redirect_from_file(path),
        )
      None => @process.collect_output("openssl", args)
    }
  })
  guard result is Some((status, stdout, _)) else {
    fail("openssl \{args.join(" ")} did not exit in time")
  }
  (status, stdout.text())
}

///|
/// The first line of `text` that starts with `prefix`, without the prefix.
fn line_after(text : String, prefix : String) -> String {
  for line in text.split("\n") {
    let line = line.trim(chars=" \r")
    if line.has_prefix(prefix) {
      return line[prefix.length():].to_owned()
    }
  }
  "(none)"
}

///|
/// The line of `text` that follows the first line that contains `title`.
fn line_following(text : String, title : String) -> String {
  let lines = text.split("\n").collect()
  for i, line in lines {
    if line.contains(title) && i + 1 < lines.length() {
      return lines[i + 1].trim(chars=" \r").to_owned()
    }
  }
  "(no \{title})"
}

///|
/// Reads the certificate the TLS port presents to a new connection, as a
/// client that does not verify it, and writes it to a new file in `dir`.
async fn Smock::presented(self : Smock, dir : String) -> Presented {
  write(dir, "empty.txt", "")
  let (_, output) = run_openssl(
    ["s_client", "-connect", "127.0.0.1:\{self.tls_port}"],
    stdin="\{dir}/empty.txt",
  )
  let end = "-----END CERTIFICATE-----"
  guard output.find("-----BEGIN CERTIFICATE-----") is Some(start) &&
    output.find(end) is Some(stop) else {
    fail("openssl s_client printed no certificate:\n\{output}")
  }
  let name = "presented-\{@fs.readdir(dir).length()}.pem"
  write(dir, name, output[start:stop + end.length()].to_owned() + "\n")
  let file = "\{dir}/\{name}"
  let (_, text) = run_openssl([
    "x509", "-in", file, "-noout", "-fingerprint", "-sha256", "-subject", "-issuer",
    "-ext", "subjectAltName",
  ])
  {
    file,
    fingerprint: line_after(text, "sha256 Fingerprint="),
    names: line_following(text, "X509v3 Subject Alternative Name"),
    subject: line_after(text, "subject="),
    issuer: line_after(text, "issuer="),
  }
}

///|
/// Runs `openssl s_client` against the TLS port, trusting only the
/// certificate in the file `ca` and checking it for `name`, a DNS name or an
/// IP address, sends `GET path` with `name` as its Host once the handshake
/// is done, and returns its exit status, the certificate verification
/// result, the response's status line and, if given, the value of its
/// header field `header`.
async fn Smock::verify_for(
  self : Smock,
  dir : String,
  ca : String,
  name : String,
  path? : String = "/",
  header? : String,
) -> String {
  let is_ipv6 = name.contains(":")
  let is_ip = is_ipv6 ||
    name.iter().all(c => c == '.' || (c >= '0' && c <= '9'))
  let host = if is_ipv6 { "[\{name}]" } else { name }
  write(
    dir,
    "request.txt",
    "GET \{path} HTTP/1.1\r\nHost: \{host}\r\nConnection: close\r\n\r\n",
  )
  let check = if is_ip {
    ["-verify_ip", name]
  } else {
    ["-verify_hostname", name, "-servername", name]
  }
  let (status, output) = run_openssl(
    [
      "s_client",
      "-connect",
      "127.0.0.1:\{self.tls_port}",
      "-CAfile",
      ca,
      "-verify_return_error",
      "-ign_eof",
      ..check,
    ],
    stdin="\{dir}/request.txt",
  )
  let verify = line_after(output, "Verify return code: ")
  let response = line_after(output, "HTTP/1.1 ")
  let line = "\{name}: status \{status}, verify \{verify}, response \{response}"
  match header {
    Some(header) => "\{line}, \{header} \{line_after(output, header + ": ")}"
    None => line
  }
}

///|
async test "with neither certificate setting, smock serves HTTPS on the TLS port with a self-signed certificate it generated" {
  with_scratch(dir => {
    let _ = with_smock(["--port", "0"], smock => {
      let presented = smock.presented(dir)
      inspect(
        [
          "self-signed: \{presented.subject == presented.issuer}",
          smock.verify_for(dir, presented.file, "localhost"),
        ].join("\n"),
        content=(
          #|self-signed: true
          #|localhost: status 0, verify 0 (ok), response 404 Not Found
        ),
      )
    })
  })
}

///|
async test "with only the empty Default Mock, the certificate covers localhost, 127.0.0.1 and ::1, and a client that trusts it verifies it for each" {
  with_scratch(dir => {
    let _ = with_smock(["--port", "0"], smock => {
      let presented = smock.presented(dir)
      let out = [presented.names]
      for name in ["localhost", "127.0.0.1", "::1", "example.com", "127.0.0.2"] {
        out.push(smock.verify_for(dir, presented.file, name))
      }
      inspect(
        out.join("\n"),
        content=(
          #|DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1
          #|localhost: status 0, verify 0 (ok), response 404 Not Found
          #|127.0.0.1: status 0, verify 0 (ok), response 404 Not Found
          #|::1: status 0, verify 0 (ok), response 404 Not Found
          #|example.com: status 1, verify 62 (hostname mismatch), response (none)
          #|127.0.0.2: status 1, verify 64 (IP address mismatch), response (none)
        ),
      )
    })
  })
}

///|
/// Three Mocks whose Hosts are names, IP addresses, a Host with a port and
/// trailing dot, and `localhost`, which the certificate covers anyway. Each
/// has a Stub `GET /x` that names its Mock in the header field `X-Mock`.
let hosts_of_every_kind : Array[(String, String)] = [
  (
    "mocks.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] },
      #|            { "name": "orders", "hosts": ["Orders.Example.com.", "10.1.2.3:8443"] },
      #|            { "name": "payments", "hosts": ["[fd00::1]", "localhost"] }],
      #|  "stubs": [{ "id": "users-x", "mock": "users",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "headers": { "X-Mock": "users" } } },
      #|            { "id": "orders-x", "mock": "orders",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "headers": { "X-Mock": "orders" } } },
      #|            { "id": "payments-x", "mock": "payments",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "headers": { "X-Mock": "payments" } } }] }
    ),
  ),
]

///|
async test "the certificate also covers every Mock Host, IP addresses as IP addresses and the rest as DNS names, so a client that trusts it can call each Mock by its Host" {
  with_definitions(hosts_of_every_kind, defs => {
    with_scratch(dir => {
      let _ = with_smock(["--dir", defs, "--port", "0"], smock => {
        let presented = smock.presented(dir)
        let out = [presented.names]
        let names = [
          "users.example.com", "orders.example.com", "10.1.2.3", "fd00::1", "localhost",
          "127.0.0.1", "::1",
        ]
        for name in names {
          out.push(
            smock.verify_for(
              dir,
              presented.file,
              name,
              path="/x",
              header="X-Mock",
            ),
          )
        }
        inspect(
          out.join("\n"),
          content=(
            #|DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1, IP Address:10.1.2.3, IP Address:FD00:0:0:0:0:0:0:1, DNS:orders.example.com, DNS:users.example.com
            #|users.example.com: status 0, verify 0 (ok), response 200 OK, X-Mock users
            #|orders.example.com: status 0, verify 0 (ok), response 200 OK, X-Mock orders
            #|10.1.2.3: status 0, verify 0 (ok), response 200 OK, X-Mock orders
            #|fd00::1: status 0, verify 0 (ok), response 200 OK, X-Mock payments
            #|localhost: status 0, verify 0 (ok), response 200 OK, X-Mock payments
            #|127.0.0.1: status 0, verify 0 (ok), response 404 Not Found, X-Mock (none)
            #|::1: status 0, verify 0 (ok), response 404 Not Found, X-Mock (none)
          ),
        )
      })
    })
  })
}

///|
/// The log entries about the self-signed certificate, without their time,
/// with each fingerprint shown by its label in `labels`, a list of
/// (fingerprint, label) pairs, or as `unknown`.
fn certificate_entries(
  logs : Array[String],
  labels : Array[(String, String)],
) -> String {
  let out = []
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(entry) &&
      entry.get("msg") is Some(String(msg)) &&
      msg.contains("self-signed") else {
      continue
    }
    entry.remove("time")
    if entry.get("sha256Fingerprint") is Some(String(fingerprint)) {
      let label = labels
        .iter()
        .find_first(pair => pair.0 == fingerprint)
        .map(pair => pair.1)
        .unwrap_or("unknown")
      entry["sha256Fingerprint"] = Json::string(label)
    }
    out.push(Json::object(entry).stringify())
  }
  out.join("\n")
}

///|
async test "a log entry at startup says that a self-signed certificate is in use, with its SHA-256 fingerprint and its names" {
  with_definitions(hosts_of_every_kind, defs => {
    with_scratch(dir => {
      let mut presented = None
      let stopped = with_smock(["--dir", defs, "--port", "0"], smock => {
        presented = Some(smock.presented(dir))
      })
      let fingerprint = presented.unwrap().fingerprint
      inspect(
        certificate_entries(stopped.logs, [(fingerprint, "presented")]),
        content=(
          #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"presented","names":["localhost","127.0.0.1","::1","10.1.2.3","fd00::1","orders.example.com","users.example.com"]}
        ),
      )
    })
  })
}

///|
/// A Definition file that declares a Mock for each (name, Host) pair in
/// `mocks`, with a Stub `GET /x` that answers with `status`.
fn mocks_file(mocks : Array[(String, String)], status? : Int = 200) -> String {
  let declared = mocks.map(mock => {
    "{ \"name\": \"\{mock.0}\", \"hosts\": [\"\{mock.1}\"] }"
  })
  let stubs = mocks.map(mock => {
    (
      $|{ "id": "\{mock.0}-x", "mock": "\{mock.0}",
      $|  "request": { "method": "GET", "path": "/x" },
      $|  "response": { "status": \{status} } }
    )
  })
  "{ \"mocks\": [\{declared.join(", ")}], \"stubs\": [\{stubs.join(", ")}] }"
}

///|
async test "a reload that changes the set of Hosts generates a new certificate for new connections, open connections keep theirs, and other reloads keep the certificate" {
  let users = ("users", "users.example.com")
  let orders = ("orders", "orders.example.com")
  with_definitions([("mocks.json", mocks_file([users]))], defs => {
    with_scratch(dir => {
      let labels = []
      let stopped = with_smock(["--dir", defs, "--port", "0"], smock => {
        let first = smock.presented(dir)
        labels.push((first.fingerprint, "first"))
        // A connection opened before the reloads, kept alive across them.
        let tcp = @socket.Tcp::connect(
          @socket.Addr::parse("127.0.0.1:\{smock.tls_port}"),
        )
        let tls = @tls.Tls::client(
          tcp,
          host="users.example.com",
          trust=CustomPemFile(first.file),
        )
        let open = TlsConn(tls, tcp)
        defer open.close()
        let request = "GET /x HTTP/1.1\r\nHost: users.example.com\r\n\r\n"
        open.write(request)
        let out = [
          "open connection, before: \{status_line(read_response(open))}",
        ]
        let steps = [
          ("change a Stub, not the Hosts", mocks_file([users], status=201)),
          ("write an invalid file", "{ \"mocks\": "),
          ("add a Mock with a new Host", mocks_file([users, orders])),
          ("remove a Mock", mocks_file([orders])),
        ]
        let mut current = first
        for step in steps {
          let (name, text) = step
          let status = smock.status()
          write(defs, "mocks.json", text)
          let reloaded = smock.reloaded(status)
          let presented = smock.presented(dir)
          let certificate = if presented.fingerprint == current.fingerprint {
            "the same"
          } else {
            labels.push((presented.fingerprint, "new after \"\{name}\""))
            "new"
          }
          out.push(
            "\{name}: reload \{last_reload(reloaded).split("\n").next().unwrap()}, certificate \{certificate}, names \{presented.names}",
          )
          if name == "add a Mock with a new Host" {
            open.write(request)
            out.push(
              "open connection, after: \{status_line(read_response(open))}",
            )
          }
          current = presented
        }
        out.push(
          smock.verify_for(dir, current.file, "orders.example.com", path="/x"),
        )
        inspect(
          out.join("\n"),
          content=(
            #|open connection, before: HTTP/1.1 200 OK
            #|change a Stub, not the Hosts: reload "swapped", certificate the same, names DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1, DNS:users.example.com
            #|write an invalid file: reload "failed", certificate the same, names DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1, DNS:users.example.com
            #|add a Mock with a new Host: reload "swapped", certificate new, names DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1, DNS:orders.example.com, DNS:users.example.com
            #|open connection, after: HTTP/1.1 200 OK
            #|remove a Mock: reload "swapped", certificate new, names DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1, DNS:orders.example.com
            #|orders.example.com: status 0, verify 0 (ok), response 200 OK
          ),
        )
      })
      inspect(
        certificate_entries(stopped.logs, labels),
        content=(
          #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"first","names":["localhost","127.0.0.1","::1","users.example.com"]}
          #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"new after \"add a Mock with a new Host\"","names":["localhost","127.0.0.1","::1","orders.example.com","users.example.com"]}
          #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"new after \"remove a Mock\"","names":["localhost","127.0.0.1","::1","orders.example.com"]}
        ),
      )
    })
  })
}

///|
async test "with certificate files configured, no certificate is generated, at startup or when a reload changes the Hosts" {
  let users = ("users", "users.example.com")
  let orders = ("orders", "orders.example.com")
  with_definitions([("mocks.json", mocks_file([users]))], defs => {
    with_certificates(certs => {
      let stopped = with_smock(["--dir", defs, "--port", "0", ..certs.args()], smock => {
        let out = []
        let presented = smock.presented(certs.dir)
        out.push("at startup: \{presented.subject}")
        let status = smock.status()
        write(defs, "mocks.json", mocks_file([users, orders]))
        let reloaded = smock.reloaded(status)
        let presented = smock.presented(certs.dir)
        out.push(
          "after a reload \{last_reload(reloaded)}: \{presented.subject}",
        )
        // The test certificate is for localhost and 127.0.0.1 only.
        out.push(
          smock.s_client(
            certs,
            ["-verify_hostname", "localhost"],
            "GET /x HTTP/1.1\r\nHost: users.example.com\r\nConnection: close\r\n\r\n",
            show=[["Verify return code:"], ["HTTP/"]],
          ),
        )
        inspect(
          out.join("\n"),
          content=(
            #|at startup: CN=localhost
            #|after a reload "swapped": CN=localhost
            #|status 0
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
          ),
        )
      })
      // No log entry about a self-signed certificate.
      inspect(certificate_entries(stopped.logs, []), content="")
    })
  })
}

///|
async test "the generated certificate and its key stay in memory: smock serves HTTPS with them from an empty read-only directory as its working directory, HOME and TMPDIR, which stays empty" {
  with_scratch(dir => {
    let read_only = "\{dir}/read-only"
    @fs.mkdir(read_only, permission=0o555)
    let out = []
    let _ = with_smock(
      ["--port", "0"],
      env={ "HOME": read_only, "TMPDIR": read_only },
      cwd=read_only,
      smock => {
        let presented = smock.presented(dir)
        out.push(smock.verify_for(dir, presented.file, "localhost"))
      },
    )
    out.push("entries in the directory: \{@fs.readdir(read_only).length()}")
    inspect(
      out.join("\n"),
      content=(
        #|localhost: status 0, verify 0 (ok), response 404 Not Found
        #|entries in the directory: 0
      ),
    )
  })
}
