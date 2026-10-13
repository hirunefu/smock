// The Seam 2 harness: it runs the smock binary as a black box. Each test
// gets its own temporary definitions directory and its own ports (smock
// binds port 0 and logs the port it got), so tests run in parallel.

///|
/// The binary under test: the native debug build of `cmd/smock`. Tests run
/// with the module root as their working directory.
let binary : String = "_build/native/debug/build/smock/smock/cmd/smock/smock.exe"

///|
/// Builds the binary once per test process, so the tests always run the
/// code they are built from.
let build : @async.Lazy[Unit] = @async.Lazy(() => {
  let (status, output) = @process.collect_output_merged("moon", [
    "build", "--target", "native", "cmd/smock",
  ])
  if status != 0 {
    fail("moon build failed:\n\{output.text()}")
  }
})

///|
/// How long a test waits for smock to start listening or to exit.
let patience_ms : Int = 20_000

///|
/// Creates a temporary definitions directory holding `files`, given as
/// (relative path, text) pairs, runs `f` with its path and removes it.
async fn with_definitions(
  files : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-")
  defer @fs.rmdir(dir, recursive=true)
  for file in files {
    let (path, text) = file
    write(dir, path, text)
  }
  f(dir)
}

///|
/// Writes `text` to `dir/path`, creating the directories on the way.
async fn write(dir : String, path : String, text : String) -> Unit {
  let parts = path.split("/").collect()
  let mut parent = dir
  for part in parts[:parts.length() - 1] {
    parent = "\{parent}/\{part}"
    @fs.mkdir(parent, allow_exist=true)
  }
  @fs.write_file("\{dir}/\{path}", text)
}

///|
/// The Admin API token the harness gives smock, through `SMOCK_ADMIN_TOKEN`,
/// unless a test sets that variable itself.
let test_token : String = "e2e-admin-token"

///|
/// The environment of a smock process: `env`, plus a TLS port and an admin
/// port of 0 (free ports, so tests run in parallel) and the test token,
/// unless `env` sets them.
fn smock_env(env : Map[String, String]) -> Map[String, String] {
  let out = {
    "SMOCK_TLS_PORT": "0",
    "SMOCK_ADMIN_PORT": "0",
    "SMOCK_ADMIN_TOKEN": test_token,
  }
  for name, value in env {
    out[name] = value
  }
  out
}

///|
/// A running smock process.
struct Smock {
  /// The plain port it listens on.
  port : Int
  /// The admin port it listens on.
  admin_port : Int
  /// The TLS port it listens on.
  tls_port : Int
  /// Its process ID.
  pid : Int
  /// The log lines it has written so far: they keep coming while it runs.
  logs : Array[String]
  /// The process, to wait for its exit.
  process : @process.Process
}

///|
/// Sends smock SIGTERM, which makes it drain and exit.
async fn Smock::terminate(self : Smock) -> Unit {
  let _ = @process.run("kill", ["-TERM", self.pid.to_string()])
}

///|
/// Waits for smock to exit, and returns its exit status (minus the signal
/// number when a signal ended it).
async fn Smock::exited(self : Smock) -> Int {
  let status = @async.with_timeout_opt(patience_ms, () => self.process.wait())
  guard status is Some(status) else { fail("smock did not exit in time") }
  status
}

///|
/// The test PKI from `@testcerts`, written to files: the paths of the root
/// CA certificate, of two certificate chains for `localhost` and
/// `127.0.0.1` (the leaf, then the intermediate CA) with their keys, and of
/// a key that belongs to no certificate.
struct Certificates {
  dir : String
  ca : String
  rsa_chain : String
  rsa_key : String
  ecdsa_chain : String
  ecdsa_key : String
  other_key : String
}

///|
/// Writes the test PKI to a temporary directory, runs `f` with its paths
/// and removes it.
async fn with_certificates(f : async (Certificates) -> Unit) -> Unit {
  let dir = @fs.tmpdir(prefix="smock-e2e-certs-")
  defer @fs.rmdir(dir, recursive=true)
  let files = [
    ("ca.pem", @testcerts.root_ca),
    ("rsa-chain.pem", @testcerts.rsa_chain),
    ("rsa-key.pem", @testcerts.rsa_key),
    ("ecdsa-chain.pem", @testcerts.ecdsa_chain),
    ("ecdsa-key.pem", @testcerts.ecdsa_key),
    ("other-key.pem", @testcerts.other_rsa_key),
  ]
  for file in files {
    let (name, pem) = file
    write(dir, name, pem + "\n")
  }
  f({
    dir,
    ca: "\{dir}/ca.pem",
    rsa_chain: "\{dir}/rsa-chain.pem",
    rsa_key: "\{dir}/rsa-key.pem",
    ecdsa_chain: "\{dir}/ecdsa-chain.pem",
    ecdsa_key: "\{dir}/ecdsa-key.pem",
    other_key: "\{dir}/other-key.pem",
  })
}

///|
/// The flags that serve HTTPS on a free TLS port with `cert` and `key`, by
/// default the RSA chain and its key.
fn Certificates::args(
  self : Certificates,
  cert? : String = self.rsa_chain,
  key? : String = self.rsa_key,
) -> Array[String] {
  ["--tls-port", "0", "--tls-cert-file", cert, "--tls-key-file", key]
}

///|
/// Starts smock with a definitions directory holding `files` (by default
/// `users`), a certificate and `args`, runs `f` once over the plain port and
/// once over the TLS port, and returns how smock ended. The HTTP/1.1 tests
/// run this way: the codec and the connection loop are the same on both
/// ports.
async fn on_both_ports(
  files? : Array[(String, String)] = [("users.json", users)],
  args? : Array[String] = [],
  f : async (Smock, Over) -> Unit,
) -> Stopped {
  let mut stopped = None
  with_definitions(files, dir => {
    with_certificates(certs => {
      stopped = Some(
        with_smock(["--dir", dir, "--port", "0", ..certs.args(), ..args], smock => {
          for over in [Plain, Tls(certs)] {
            f(smock, over)
          }
        }),
      )
    })
  })
  stopped.unwrap()
}

///|
/// How a test reaches smock: over plain TCP on the plain port, or over TLS
/// on the TLS port with a client that trusts only the test root CA and
/// checks the certificate for `localhost`.
enum Over {
  Plain
  Tls(Certificates)
}

///|
/// A connection to smock, over plain TCP or over TLS.
enum Conn {
  PlainConn(@socket.Tcp)
  TlsConn(@tls.Tls, @socket.Tcp)
}

///|
async fn Conn::write(self : Conn, data : &@io.Data) -> Unit {
  match self {
    PlainConn(tcp) => tcp.write(data)
    TlsConn(tls, _) => tls.write(data)
  }
}

///|
async fn Conn::read_until(self : Conn, separator : String) -> String? {
  match self {
    PlainConn(tcp) => tcp.read_until(separator)
    TlsConn(tls, _) => tls.read_until(separator)
  }
}

///|
async fn Conn::read_exactly(self : Conn, length : Int) -> Bytes {
  match self {
    PlainConn(tcp) => tcp.read_exactly(length)
    TlsConn(tls, _) => tls.read_exactly(length)
  }
}

///|
async fn Conn::read_some(self : Conn) -> Bytes? {
  match self {
    PlainConn(tcp) => tcp.read_some()
    TlsConn(tls, _) => tls.read_some()
  }
}

///|
fn Conn::close(self : Conn) -> Unit {
  match self {
    PlainConn(tcp) => tcp.close()
    TlsConn(tls, tcp) => {
      tls.close()
      tcp.close()
    }
  }
}

///|
/// How a smock process ended: its exit status (minus the signal number when
/// a signal ended it) and every log line it wrote.
struct Stopped {
  status : Int
  logs : Array[String]
}

///|
/// Starts `smock serve <args>` with only `smock_env(env)` as its
/// environment, in the working directory `cwd` (by default the test's own),
/// waits until it listens on the plain, the TLS and the admin port, runs
/// `f`, then stops it with SIGTERM, unless `f` has, and waits for it to
/// exit.
async fn with_smock(
  args : Array[String],
  env? : Map[String, String] = Map([]),
  cwd? : String = ".",
  f : async (Smock) -> Unit,
) -> Stopped {
  build.wait()
  @async.with_task_group(group => {
    let (stderr, stderr_end) = @process.read_from_process()
    let process = @process.spawn(
      group,
      @fs.realpath(binary),
      ["serve", ..args],
      extra_env=smock_env(env),
      inherit_env=false,
      stderr=stderr_end,
      cwd~,
      no_wait=true,
    )
    let logs = []
    let lines : @async.Queue[String?] = @async.Queue(kind=Unbounded)
    let reader = group.spawn(() => {
      defer stderr.close()
      for ;; {
        let line = stderr.read_until("\n")
        if line is Some(line) {
          logs.push(line)
        }
        lines.put(line)
        if line is None {
          break
        }
      }
    })
    let ports : Map[String, Int] = Map([])
    let expected = ["plain", "tls", "admin"]
    let listening = @async.with_timeout_opt(patience_ms, () => {
      while !expected.iter().all(listener => ports.contains(listener)) {
        guard lines.get() is Some(line) else {
          fail("smock exited before listening:\n\{logs.join("\n")}")
        }
        if listening(line) is Some((listener, port)) {
          ports[listener] = port
        }
      }
    })
    guard listening is Some(_) else {
      fail("smock did not listen in time:\n\{logs.join("\n")}")
    }
    f({
      port: ports.get("plain").unwrap(),
      tls_port: ports.get("tls").unwrap(),
      admin_port: ports.get("admin").unwrap(),
      pid: process.pid,
      logs,
      process,
    })
    if process.try_wait() is None {
      let _ = @process.run("kill", ["-TERM", process.pid.to_string()])
    }
    let status = @async.with_timeout_opt(patience_ms, () => process.wait())
    guard status is Some(status) else { fail("smock did not stop in time") }
    reader.wait()
    { status, logs, }
  })
}

///|
/// Whether `smock serve <args>` loads its definitions: `"serves"` once it
/// listens on its plain port, which it opens once they have loaded (it is
/// then stopped), or `"exits with status <n>"` when it stops by itself
/// first.
async fn serve_verdict(args : Array[String]) -> String {
  build.wait()
  @async.with_task_group(group => {
    let (stderr, stderr_end) = @process.read_from_process()
    defer stderr.close()
    let process = @process.spawn(
      group,
      binary,
      ["serve", "--port", "0", ..args],
      extra_env=smock_env(Map([])),
      inherit_env=false,
      stderr=stderr_end,
      no_wait=true,
    )
    let verdict = @async.with_timeout_opt(patience_ms, () => {
      for ;; {
        guard stderr.read_until("\n") is Some(line) else {
          break "exits with status \{process.wait()}"
        }
        if listening(line) is Some(("plain", _)) {
          let _ = @process.run("kill", ["-TERM", process.pid.to_string()])
          let _ = process.wait()
          break "serves"
        }
      }
    })
    guard verdict is Some(verdict) else {
      fail("smock serve neither listened nor stopped in time")
    }
    verdict
  })
}

///|
/// The listener and the port of a `listening` log entry.
fn listening(line : String) -> (String, Int)? {
  let entry = @json.parse(line) catch { _ => return None }
  guard entry is Object(entry) &&
    entry.get("msg") is Some(String("listening")) &&
    entry.get("listener") is Some(String(listener)) &&
    entry.get("address") is Some(String(address)) else {
    return None
  }
  let colon = address.rev_find(":").unwrap_or(-1)
  try @string.parse_int(address[colon + 1:]) catch {
    _ => None
  } noraise {
    port => Some((listener, port))
  }
}

///|
/// Runs `smock <args>` with only `smock_env(env)` as its environment until
/// it exits by itself, and returns its exit status and the lines it wrote to
/// stderr.
async fn run_smock(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> Stopped {
  build.wait()
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_stderr(
      binary,
      args,
      extra_env=smock_env(env),
      inherit_env=false,
    )
  })
  guard result is Some((status, stderr)) else {
    fail("smock did not exit in time")
  }
  let logs = stderr
    .text()
    .split("\n")
    .filter(line => line != "")
    .map(line => line.to_owned())
    .collect()
  { status, logs, }
}

///|
/// Runs `smock <args>` until it exits, and returns its exit status and what
/// it wrote to stdout, such as help text.
async fn smock_stdout(args : Array[String]) -> (Int, String) {
  build.wait()
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_stdout(binary, args, inherit_env=false)
  })
  guard result is Some((status, stdout)) else {
    fail("smock did not exit in time")
  }
  (status, stdout.text())
}

///|
/// Sends `GET path` with a real HTTP client and renders the response: the
/// status, the headers and the body.
async fn Smock::get(self : Smock, path : String) -> String {
  let client = @http.Client("http://127.0.0.1:\{self.port}")
  defer client.close()
  let response = client.get(path)
  let body = client.read_all().text()
  render_response(response, body)
}

///|
/// Sends one request to the Admin API and reads the whole response.
///
/// - `token` goes in `Authorization: Bearer <token>`; `None` sends no
///   Authorization field. The default is the token the harness gives smock.
/// - `headers` are sent after Host and Authorization.
/// - `body`, when given, is sent with its Content-Length.
async fn Smock::admin(
  self : Smock,
  meth : String,
  path : String,
  token? : String? = Some(test_token),
  headers? : Array[(String, String)] = [],
  body? : String,
) -> AdminResponse {
  let conn = @socket.Tcp::connect(
    @socket.Addr::parse("127.0.0.1:\{self.admin_port}"),
  )
  defer conn.close()
  let request = StringBuilder()
  request.write_string("\{meth} \{path} HTTP/1.1\r\nHost: localhost\r\n")
  if token is Some(token) {
    request.write_string("Authorization: Bearer \{token}\r\n")
  }
  for header in headers {
    request.write_string("\{header.0}: \{header.1}\r\n")
  }
  match body {
    Some(body) => {
      let length = @utf8.encode(body).length()
      request.write_string("Content-Length: \{length}\r\n\r\n\{body}")
    }
    None => request.write_string("\r\n")
  }
  conn.write(request.to_string())
  read_admin_response(conn)
}

///|
/// Reads one response, framed by its Content-Length.
async fn read_admin_response(conn : @socket.Tcp) -> AdminResponse {
  let result = @async.with_timeout_opt(patience_ms, () => {
    guard conn.read_until("\r\n\r\n") is Some(head) else {
      fail("the connection closed without a response")
    }
    let lines = head.split("\r\n").collect()
    let status = @string.parse_int(lines[0].split(" ").nth(1).unwrap())
    let headers = []
    let mut length = 0
    for line in lines[1:] {
      guard line.find(":") is Some(colon) else { continue }
      let name = line[:colon].to_owned()
      let value = line[colon + 1:].trim().to_owned()
      if name.to_lower() == "content-length" {
        length = @string.parse_int(value)
      }
      headers.push((name, value))
    }
    let body = @utf8.decode(conn.read_exactly(length))
    AdminResponse::{ status, headers, body, }
  })
  guard result is Some(response) else { fail("no response in time") }
  response
}

///|
/// Opens a connection to smock for tests that send exact bytes: over plain
/// TCP by default, or over TLS.
async fn Smock::connect(self : Smock, over? : Over = Plain) -> Conn {
  match over {
    Plain =>
      PlainConn(
        @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}")),
      )
    Tls(certs) => {
      let tcp = @socket.Tcp::connect(
        @socket.Addr::parse("127.0.0.1:\{self.tls_port}"),
      )
      errdefer tcp.close()
      let tls = @tls.Tls::client(
        tcp,
        host="localhost",
        trust=CustomPemFile(certs.ca),
      )
      TlsConn(tls, tcp)
    }
  }
}

///|
/// Reads one response, framed by its Content-Length, and renders it with
/// `\r\n` shown as `\n`. Returns `"closed"` when the connection ends first.
async fn read_response(conn : Conn) -> String {
  let result = @async.with_timeout_opt(patience_ms, () => {
    guard conn.read_until("\r\n\r\n") is Some(head) else { return "closed" }
    let mut length = 0
    for line in head.split("\r\n") {
      if line.to_lower().has_prefix("content-length:") {
        length = @string.parse_int(line["content-length:".length():].trim())
      }
    }
    let body = conn.read_exactly(length)
    head.replace_all(old="\r\n", new="\n") + "\n\n" + @utf8.decode_lossy(body)
  })
  guard result is Some(response) else { fail("no response in time") }
  response
}

///|
/// Whether smock closes the connection without sending anything more.
async fn closed(conn : Conn) -> Bool {
  let result = @async.with_timeout_opt(patience_ms, () => conn.read_some())
  guard result is Some(rest) else { fail("the connection stayed open") }
  rest is None
}

///|
fn render_response(response : @http.Response, body : String) -> String {
  let out = StringBuilder()
  out.write_string("\{response.code} \{response.reason}\n")
  for name, value in response.headers {
    out.write_string("\{name.0}: \{value}\n")
  }
  out.write_string("\n")
  out.write_string(body)
  out.to_string()
}

///|
/// The log lines as JSON objects without their time, with the values that
/// differ from build to build and run to run replaced by `*`.
fn entries(logs : Array[String]) -> String {
  logs
  .map(line => {
    let entry = @json.parse(line) catch { _ => return "not JSON: \{line}" }
    guard entry is Object(fields) else { return "not an object: \{line}" }
    let out : Map[String, Json] = Map([])
    for key, value in fields {
      match key {
        "time" => ()
        "version" | "commit" | "toolchain" | "seed" | "sha256Fingerprint" =>
          out[key] = "*"
        "certFile" | "keyFile" =>
          out[key] = match value {
            String(path) =>
              Json::string(
                "*/" + path[path.rev_find("/").unwrap_or(-1) + 1:].to_owned(),
              )
            _ => value
          }
        "address" =>
          out[key] = match value {
            String(address) =>
              Json::string(
                address[:address.rev_find(":").unwrap_or(0)].to_owned() + ":*",
              )
            _ => value
          }
        _ => out[key] = value
      }
    }
    Json::object(out).stringify()
  })
  .join("\n")
}
