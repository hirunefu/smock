// The Seam 2 harness: it runs the smock binary as a black box. Each test
// gets its own temporary definitions directory and its own ports (smock
// binds port 0 and logs the port it got), so tests run in parallel. They
// share one event loop, so a test computes for no more than about 20 ms
// between awaits: see "Build and test" in README.md.

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
let patience_ms : Int32 = 20_000

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
/// The most UTF-16 code units of a text that `write` encodes at once.
let write_piece : Int32 = 1024 * 1024

///|
/// Writes `text` to `dir/path`, creating the directories on the way, as
/// `@fs.write_file` does. A text longer than `write_piece` is encoded and
/// written a piece at a time: encoding a 16 MiB body file in one go took
/// 50 to 150 ms, in which no other test of the package ran.
async fn write(dir : String, path : String, text : String) -> Unit {
  let parts = path.split("/").collect()
  let mut parent = dir
  for part in parts[:parts.length() - 1] {
    parent = "\{parent}/\{part}"
    @fs.mkdir(parent, allow_exist=true)
  }
  let file = @fs.open(
    "\{dir}/\{path}",
    mode=WriteOnly,
    sync=Data,
    create_mode=CreateOrTruncate,
  )
  defer file.close()
  let mut rest = text[:]
  while rest.length() > 0 {
    // A view never ends between the two halves of a surrogate pair.
    let piece = rest[:write_piece]
    file.write(@utf8.encode(piece))
    rest = rest[piece.length():]
  }
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
  port : Int32
  /// The admin port it listens on.
  admin_port : Int32
  /// The TLS port it listens on.
  tls_port : Int32
  /// Its process ID.
  pid : Int32
  /// The lines it has written to stderr so far, its log lines in the json
  /// log format: they keep coming while it runs.
  logs : Array[String]
  /// The lines it has written to stdout so far, every log line in the
  /// mockoon log format: they keep coming while it runs.
  stdout : Array[String]
  /// The process, to wait for its exit.
  process : @process.Process
}

///|
/// Sends smock SIGTERM, which makes it drain and exit.
async fn Smock::terminate(self : Smock) -> Unit {
  terminate(self.pid)
}

///|
/// Sends the process `pid` SIGTERM.
async fn terminate(pid : Int32) -> Unit {
  let _ = @process.run("kill", ["-TERM", pid.to_string()])
}

///|
/// Waits for smock to exit, and returns its exit status (minus the signal
/// number when a signal ended it).
async fn Smock::exited(self : Smock) -> Int32 {
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
  cert~ : String = self.rsa_chain,
  key~ : String = self.rsa_key,
) -> Array[String] {
  ["--tls-port", "0", "--tls-cert-file", cert, "--tls-key-file", key]
}

///|
/// Starts smock with a definitions directory holding `files` (by default
/// `users`), a certificate, `args` and the environment `env`, runs `f` once
/// over the plain port and once over the TLS port, and returns how smock
/// ended. The HTTP/1.1 tests run this way: the codec and the connection
/// loop are the same on both ports.
async fn on_both_ports(
  files~ : Array[(String, String)] = [("users.json", users)],
  args~ : Array[String] = [],
  env~ : Map[String, String] = Map([]),
  f : async (Smock, Over) -> Unit,
) -> Stopped {
  let mut stopped = None
  with_definitions(files, dir => {
    with_certificates(certs => {
      stopped = Some(
        with_smock(
          ["--dir", dir, "--port", "0", ..certs.args(), ..args],
          env~,
          smock => {
            for over in [Plain, Tls(certs)] {
              f(smock, over)
            }
          },
        ),
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
async fn Conn::read_exactly(self : Conn, length : Int32) -> Bytes {
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
/// a signal ended it), every line it wrote to stderr and every line it
/// wrote to stdout.
struct Stopped {
  status : Int32
  logs : Array[String]
  stdout : Array[String]
}

///|
/// Starts `smock serve <args>` with only `smock_env(env)` as its
/// environment, in the working directory `cwd` (by default the test's own),
/// waits until it listens on the plain, the TLS and the admin port, runs
/// `f`, then stops it with SIGTERM, unless `f` has, and waits for it to
/// exit. `under`, when given, is a command that runs smock as its last
/// arguments and becomes smock by exec, such as `systemd-run --scope ...
/// --`, so that the signal still reaches smock. With `close_stdout`, the
/// reading end of smock's stdout is closed once smock listens, so that every
/// write smock makes there after that fails.
async fn with_smock(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
  under~ : Array[String] = [],
  close_stdout~ : Bool = false,
  f : async (Smock) -> Unit,
) -> Stopped {
  @async.with_task_group(group => {
    let serving = Serving::start(group, args, env~, cwd~, under~)
    guard serving.listening_on(["plain", "tls", "admin"]) is Some(ports) else {
      fail("smock exited before listening:\n\{serving.log().join("\n")}")
    }
    if close_stdout {
      serving.close_stdout()
    }
    f(serving.smock(ports))
    let status = serving.stop()
    { status, logs: serving.logs, stdout: serving.stdout, }
  })
}

///|
/// A `smock serve` process the harness started, while it runs.
struct Serving {
  process : @process.Process
  /// The lines it has written to stderr so far: they keep coming while it
  /// runs.
  logs : Array[String]
  /// Each log line as it comes, from stderr, or from stdout in the mockoon
  /// log format, then `None` once smock has closed that stream, which it
  /// does when it exits.
  lines : @async.Queue[String?]
  /// Reads the lines of stderr, until smock closes it.
  reader : @async.Task[Unit]
  /// The lines it has written to stdout so far.
  stdout : Array[String]
  /// Reads the lines of stdout, until smock closes it, unless its reading
  /// end was closed (`close_stdout`) or reading it stopped
  /// (`stall_stdout`).
  mut stdout_reader : @async.Task[Unit]?
  /// The reading end of stdout.
  stdout_pipe : @process.ReadFromProcess
  /// Whether reading stdout has stopped and left its reading end open
  /// (`stall_stdout`), until `close_stdout` closes it.
  stdout_stalled : Ref[Bool]
  /// Whether smock writes its log to stdout: in the mockoon log format.
  logs_to_stdout : Bool
}

///|
/// Whether `smock serve <args>`, with `env` as its environment, writes its
/// log to stdout: when `--log-format`, or else `SMOCK_LOG_FORMAT`, sets the
/// mockoon log format.
fn logs_to_stdout(args : Array[String], env : Map[String, String]) -> Bool {
  let mut format = env.get("SMOCK_LOG_FORMAT")
  for i, arg in args {
    if arg == "--log-format" && i + 1 < args.length() {
      format = Some(args[i + 1])
    } else if arg.has_prefix("--log-format=") {
      format = Some(arg["--log-format=".length():].to_owned())
    }
  }
  format is Some("mockoon")
}

///|
/// Starts `smock serve <args>` in `group`, with only `smock_env(env)` as
/// its environment, in the working directory `cwd`, under the command
/// `under` when given (see `with_smock`), and reads the lines of its stderr
/// and of its stdout as they come. Its log lines come from stderr, or from
/// stdout when a test sets the mockoon log format.
async fn[X] Serving::start(
  group : @async.TaskGroup[X],
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
  under~ : Array[String] = [],
) -> Serving {
  build.wait()
  let (stderr, stderr_end) = @process.read_from_process()
  let (stdout, stdout_end) = @process.read_from_process()
  let smock = [@fs.realpath(binary), "serve", ..args]
  let command = [..under, ..smock]
  let process = @process.spawn(
    group,
    command[0],
    command[1:],
    extra_env=smock_env(env),
    inherit_env=false,
    stdout=stdout_end,
    stderr=stderr_end,
    cwd~,
    no_wait=true,
  )
  let logs_to_stdout = logs_to_stdout(args, env)
  let lines : @async.Queue[String?] = @async.Queue(kind=Unbounded)
  // Reads the lines of `output` into `into` until smock closes it, and, if
  // it carries the log, passes each on to `lines`.
  let read_lines = (
    output : @process.ReadFromProcess,
    into : Array[String],
    log : Bool,
  ) => {
    for ;; {
      let line = output.read_until("\n")
      if line is Some(line) {
        into.push(line)
      }
      if log {
        lines.put(line)
      }
      if line is None {
        break
      }
    }
  }
  let stdout_lines = []
  let stdout_stalled = Ref(false)
  let stdout_reader = group.spawn(() => {
    // Reading may stop with the reading end left open (`stall_stdout`).
    defer (if !stdout_stalled.val { stdout.close() })
    read_lines(stdout, stdout_lines, logs_to_stdout)
  })
  let logs = []
  let reader = group.spawn(() => {
    defer stderr.close()
    read_lines(stderr, logs, !logs_to_stdout)
  })
  {
    process,
    logs,
    lines,
    reader,
    stdout: stdout_lines,
    stdout_reader: Some(stdout_reader),
    stdout_pipe: stdout,
    stdout_stalled,
    logs_to_stdout,
  }
}

///|
/// The log lines smock has written so far: those of stderr, or of stdout
/// in the mockoon log format.
fn Serving::log(self : Serving) -> Array[String] {
  if self.logs_to_stdout {
    self.stdout
  } else {
    self.logs
  }
}

///|
/// Closes the reading end of smock's stdout, so that every write smock
/// makes there from now on fails, a write that waits on a stalled reader
/// (`stall_stdout`) included. The lines read so far stay.
async fn Serving::close_stdout(self : Serving) -> Unit {
  if self.stdout_stalled.val {
    self.stdout_stalled.val = false
    self.stdout_pipe.close()
  }
  guard self.stdout_reader is Some(reader) else { return }
  self.stdout_reader = None
  // Cancelling the reader closes the reading end, as it ends.
  reader.cancel()
  reader.wait() catch {
    _ => ()
  }
}

///|
/// Stops reading smock's stdout, and leaves its reading end open, as a
/// reader that has stalled does: once the pipe is full, every write smock
/// makes there waits, until `close_stdout`. The lines read so far stay.
async fn Serving::stall_stdout(self : Serving) -> Unit {
  guard self.stdout_reader is Some(reader) else { return }
  self.stdout_reader = None
  self.stdout_stalled.val = true
  reader.cancel()
  reader.wait() catch {
    _ => ()
  }
}

///|
/// Waits until smock listens on each of `listeners` (`"plain"`, `"tls"`,
/// `"admin"`) and returns their ports, or `None` when smock exits first.
async fn Serving::listening_on(
  self : Serving,
  listeners : Array[String],
) -> Map[String, Int32]? {
  let ports : Map[String, Int32] = Map([])
  let listened = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      if listeners.iter().all(listener => ports.contains(listener)) {
        break true
      }
      guard self.lines.get() is Some(line) else { break false }
      if listening(line) is Some((listener, port)) {
        ports[listener] = port
      }
    }
  })
  guard listened is Some(listened) else {
    fail("smock did not listen in time:\n\{self.log().join("\n")}")
  }
  if listened {
    Some(ports)
  } else {
    None
  }
}

///|
/// The running smock, with the ports it listens on from `ports`; a port it
/// has not opened yet is 0.
fn Serving::smock(self : Serving, ports : Map[String, Int32]) -> Smock {
  {
    port: ports.get("plain").unwrap_or(0),
    tls_port: ports.get("tls").unwrap_or(0),
    admin_port: ports.get("admin").unwrap_or(0),
    pid: self.process.pid,
    logs: self.logs,
    stdout: self.stdout,
    process: self.process,
  }
}

///|
/// Waits for smock to exit and for its last log line and its last line on
/// stdout, and returns its exit status (minus the signal number when a
/// signal ended it).
async fn Serving::wait(self : Serving) -> Int32 {
  let status = @async.with_timeout_opt(patience_ms, () => self.process.wait())
  guard status is Some(status) else { fail("smock did not stop in time") }
  self.reader.wait()
  if self.stdout_reader is Some(reader) {
    reader.wait()
  }
  status
}

///|
/// Stops smock with SIGTERM, unless it has exited, and waits for it as
/// `wait` does.
async fn Serving::stop(self : Serving) -> Int32 {
  if self.process.try_wait() is None {
    terminate(self.process.pid)
  }
  self.wait()
}

///|
/// Whether `smock serve <args>` loads its definitions: `"serves"` once it
/// listens on its plain port, which it opens once they have loaded (it is
/// then stopped), or `"exits with status <n>"` when it stops by itself
/// first.
async fn serve_verdict(args : Array[String]) -> String {
  @async.with_task_group(group => {
    let serving = Serving::start(group, ["--port", "0", ..args])
    if serving.listening_on(["plain"]) is Some(_) {
      let _ = serving.stop()
      "serves"
    } else {
      "exits with status \{serving.wait()}"
    }
  })
}

///|
/// The listener and the port of a `listening` log entry, in either log
/// format: with `msg` in the json format, `message` in the mockoon format.
fn listening(line : String) -> (String, Int32)? {
  let entry = @json.parse(line) catch { _ => return None }
  guard entry is Object(entry) &&
    (
      entry.get("msg") is Some(String("listening")) ||
      entry.get("message") is Some(String("listening"))
    ) &&
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
/// stderr and to stdout.
async fn run_smock(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
) -> Stopped {
  let (status, stdout, stderr) = smock_output(args, env=smock_env(env))
  let lines = (text : String) => {
    text
    .split("\n")
    .filter(line => line != "")
    .map(line => line.to_owned())
    .collect()
  }
  { status, logs: lines(stderr), stdout: lines(stdout), }
}

///|
/// Runs `smock <args>` until it exits, and returns its exit status and what
/// it wrote to stdout, such as help text.
async fn smock_stdout(args : Array[String]) -> (Int32, String) {
  let (status, stdout, _) = smock_output(args)
  (status, stdout)
}

///|
/// Runs `smock <args>` with only `env` as its environment, in the working
/// directory `cwd` (by default the test's own), until it exits by itself,
/// and returns its exit status and what it wrote to stdout and to stderr.
async fn smock_output(
  args : Array[String],
  env~ : Map[String, String] = Map([]),
  cwd~ : String = ".",
) -> (Int32, String, String) {
  build.wait()
  let smock = @fs.realpath(binary)
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(smock, args, extra_env=env, inherit_env=false, cwd~)
  })
  guard result is Some((status, stdout, stderr)) else {
    fail("smock \{args.join(" ")} did not exit in time")
  }
  (status, stdout.text(), stderr.text())
}

///|
/// Renders how a run of smock ended, as `smock_output` returns it: the exit
/// status, then what smock wrote to stdout and, if anything, to stderr.
fn exit_report(output : (Int32, String, String)) -> String {
  let (status, stdout, stderr) = output
  let out = "status \{status}\n\{stdout}"
  match stderr {
    "" => out
    err => "\{out}stderr:\n\{err}"
  }
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
/// Sends one request to the Admin API and reads the whole response. It fails
/// the test unless the response conforms to the OpenAPI document
/// (`conforms`), so every Admin API response a test gets is checked.
///
/// - `token` goes in `Authorization: Bearer <token>`; `None` sends no
///   Authorization field. The default is the token the harness gives smock.
/// - `headers` are sent after Host and Authorization.
/// - `body`, when given, is sent with its Content-Length.
async fn Smock::admin(
  self : Smock,
  meth : String,
  path : String,
  token~ : String? = Some(test_token),
  headers~ : Array[(String, String)] = [],
  body? : String,
) -> AdminResponse {
  let conn = PlainConn(
    @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.admin_port}")),
  )
  defer conn.close()
  let authorization = match token {
    Some(token) => [("Authorization", "Bearer \{token}")]
    None => []
  }
  conn.write(
    raw_request(
      meth,
      path,
      host="localhost",
      headers=[..authorization, ..headers],
      body?,
    ),
  )
  let response = read_admin_response(conn)
  conforms(meth, path, response)
  response
}

///|
/// An Admin API response as a test sees it.
struct AdminResponse {
  status : Int32
  /// The header fields, in the order they came.
  headers : Array[(String, String)]
  body : String
}

///|
/// The value of the header field `name`, compared case-insensitively.
fn AdminResponse::header(self : AdminResponse, name : String) -> String? {
  let name = name.to_lower()
  for header in self.headers {
    if header.0.to_lower() == name {
      return Some(header.1)
    }
  }
  None
}

///|
/// The body, parsed as JSON.
fn AdminResponse::json(self : AdminResponse) -> Json raise {
  @json.parse(self.body)
}

///|
/// Reads one response and parses its status and header fields.
async fn read_admin_response(conn : Conn) -> AdminResponse {
  guard read_framed(conn) is Some((head, body)) else {
    fail("the connection closed without a response")
  }
  let lines = head.split("\r\n").collect()
  let status = @string.parse_int(lines[0].split(" ").nth(1).unwrap())
  let headers = []
  for line in lines[1:] {
    guard line.find(":") is Some(colon) else { continue }
    headers.push((line[:colon].to_owned(), line[colon + 1:].trim().to_owned()))
  }
  AdminResponse::{ status, headers, body: @utf8.decode(body), }
}

///|
/// A request as raw HTTP/1.1 bytes: the request line, `Host: <host>` when
/// `host` is given, `headers` in order, then, when `body` is given, its
/// Content-Length and the body.
fn raw_request(
  meth : String,
  target : String,
  host? : String,
  headers~ : Array[(String, String)] = [],
  body? : String,
) -> String {
  let out = StringBuilder()
  out.write_string("\{meth} \{target} HTTP/1.1\r\n")
  if host is Some(host) {
    out.write_string("Host: \{host}\r\n")
  }
  for header in headers {
    out.write_string("\{header.0}: \{header.1}\r\n")
  }
  match body {
    Some(body) =>
      out.write_string(
        "Content-Length: \{@utf8.encode(body).length()}\r\n\r\n\{body}",
      )
    None => out.write_string("\r\n")
  }
  out.to_string()
}

///|
/// Reads one response, framed by its Content-Length: its head, without the
/// empty line that ends it, and its body. `None` when the connection ends
/// first.
async fn read_framed(conn : Conn) -> (String, Bytes)? {
  let result = @async.with_timeout_opt(patience_ms, () => {
    guard conn.read_until("\r\n\r\n") is Some(head) else { return None }
    let mut length = 0
    for line in head.split("\r\n") {
      if line.to_lower().has_prefix("content-length:") {
        length = @string.parse_int(line["content-length:".length():].trim())
      }
    }
    Some((head, conn.read_exactly(length)))
  })
  guard result is Some(response) else { fail("no response in time") }
  response
}

///|
/// Opens a connection to smock for tests that send exact bytes: over plain
/// TCP by default, or over TLS.
async fn Smock::connect(self : Smock, over~ : Over = Plain) -> Conn {
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
/// `\r\n` shown as `\n` and the current Date masked (`mask_date`). Returns
/// `"closed"` when the connection ends first.
async fn read_response(conn : Conn) -> String {
  match read_framed(conn) {
    Some((head, body)) =>
      mask_date(head.replace_all(old="\r\n", new="\n")) +
      "\n\n" +
      @utf8.decode_lossy(body)
    None => "closed"
  }
}

///|
/// `text`, one or more responses or parts of them, with the value of each
/// `Date` field that is the current time shown as `<now>`: the time, by the
/// test's clock, of a second within the last minute, in IMF-fixdate form.
/// Any other value stays as it is, such as an older one a Stub gives, so a
/// Date that is missing, repeated, late or malformed shows.
fn mask_date(text : String) -> String {
  guard text.contains("Date: ") else { return text }
  let dates = @http1.DateCache()
  let now = @async.now() / 1000L
  let recent = []
  for second in (now - 60L)..<=(now + 1L) {
    recent.push(dates.at(second * 1000L))
  }
  text
  .split("\n")
  .map(line => {
    guard line.strip_prefix("Date: ") is Some(value) else {
      return line.to_owned()
    }
    let (value, cr) = match value.strip_suffix("\r") {
      Some(value) => (value, "\r")
      None => (value, "")
    }
    if recent.contains(value.to_owned()) {
      "Date: <now>\{cr}"
    } else {
      line.to_owned()
    }
  })
  .collect()
  .join("\n")
}

///|
/// Whether smock closes the connection without sending anything more.
async fn closed(conn : Conn) -> Bool {
  let result = @async.with_timeout_opt(patience_ms, () => conn.read_some())
  guard result is Some(rest) else { fail("the connection stayed open") }
  rest is None
}

///|
/// Reads `conn` until smock ends it, by a FIN or a reset alike, and returns
/// when the last bytes came (-1 if none did) and when the end came, in
/// milliseconds after `since`, and every byte received.
async fn received_until_end(
  conn : Conn,
  since : Int64,
) -> (Int64, Int64, Bytes) {
  let received = @buffer.Buffer()
  let mut last = -1L
  let result = @async.with_timeout_opt(patience_ms, () => {
    for ;; {
      let more = conn.read_some() catch { _ => None }
      guard more is Some(bytes) else { break }
      last = @async.now() - since
      received.write_bytes(bytes)
    }
  })
  guard result is Some(_) else { fail("the connection stayed open") }
  (last, @async.now() - since, received.to_bytes())
}

///|
fn render_response(response : @http.Response, body : String) -> String {
  let out = StringBuilder()
  out.write_string("\{response.code} \{response.reason}\n")
  for name, value in response.headers {
    out.write_string("\{name.0}: \{value}\n")
  }
  out.write_string("\n")
  mask_date(out.to_string()) + body
}

///|
/// The log lines as JSON objects without their time, with the values that
/// differ from build to build and run to run replaced by `*`. The Journal's
/// byte bound and the per-Session state's differ from machine to machine
/// unless a flag or a variable sets them: they follow the memory limit of
/// smock's cgroup. Then a bound, its source and the memory limit, or why it
/// could not be read, are all `*`, as `memoryLimit`.
fn log_entries(logs : Array[String]) -> String {
  logs
  .map(line => {
    let entry = @json.parse(line) catch { _ => return "not JSON: \{line}" }
    guard entry is Object(fields) else { return "not an object: \{line}" }
    let from_memory_limit = fields.get("msg")
      is Some(String("journal byte bound" | "state byte bound")) &&
      !(fields.get("source") is Some(String("flag" | "variable")))
    let out : Map[String, Json] = Map([])
    for key, value in fields {
      match key {
        "time" => ()
        "maxBytes" | "source" if from_memory_limit => out[key] = "*"
        "memoryLimit" | "memoryLimitError" if from_memory_limit =>
          out["memoryLimit"] = "*"
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

///|
/// The log entry with the message `msg`, without its time.
fn startup_entry(logs : Array[String], msg : String) -> String {
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(m)) &&
      m == msg else {
      continue
    }
    fields.remove("time")
    return Json::object(fields).stringify()
  }
  "no \{msg} entry in:\n\{logs.join("\n")}"
}
