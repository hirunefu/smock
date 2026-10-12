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
/// A running smock process.
struct Smock {
  /// The plain port it listens on.
  port : Int
}

///|
/// How a smock process ended: its exit status (minus the signal number when
/// a signal ended it) and every log line it wrote.
struct Stopped {
  status : Int
  logs : Array[String]
}

///|
/// Starts `smock serve <args>` with only `env` as its environment, waits
/// until it listens, runs `f`, then stops it with SIGTERM and waits for it
/// to exit.
async fn with_smock(
  args : Array[String],
  env? : Map[String, String] = Map([]),
  f : async (Smock) -> Unit,
) -> Stopped {
  build.wait()
  @async.with_task_group(group => {
    let (stderr, stderr_end) = @process.read_from_process()
    let process = @process.spawn(
      group,
      binary,
      ["serve", ..args],
      extra_env=env,
      inherit_env=false,
      stderr=stderr_end,
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
    let port = @async.with_timeout_opt(patience_ms, () => {
      for ;; {
        guard lines.get() is Some(line) else {
          fail("smock exited before listening:\n\{logs.join("\n")}")
        }
        if listening_port(line) is Some(port) {
          break port
        }
      }
    })
    guard port is Some(port) else {
      fail("smock did not listen in time:\n\{logs.join("\n")}")
    }
    f({ port, })
    let _ = @process.run("kill", ["-TERM", process.pid.to_string()])
    let status = @async.with_timeout_opt(patience_ms, () => process.wait())
    guard status is Some(status) else { fail("smock did not stop in time") }
    reader.wait()
    { status, logs, }
  })
}

///|
/// The port of a `listening` log entry.
fn listening_port(line : String) -> Int? {
  let entry = @json.parse(line) catch { _ => return None }
  guard entry is Object(entry) &&
    entry.get("msg") is Some(String("listening")) &&
    entry.get("address") is Some(String(address)) else {
    return None
  }
  let colon = address.rev_find(":").unwrap_or(-1)
  try @string.parse_int(address[colon + 1:]) catch {
    _ => None
  } noraise {
    port => Some(port)
  }
}

///|
/// Runs `smock <args>` with only `env` as its environment until it exits by
/// itself, and returns its exit status and the lines it wrote to stderr.
async fn run_smock(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> Stopped {
  build.wait()
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_stderr(binary, args, extra_env=env, inherit_env=false)
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
/// Opens a raw TCP connection to smock, for tests that send exact bytes.
async fn Smock::connect(self : Smock) -> @socket.Tcp {
  @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{self.port}"))
}

///|
/// Reads one response, framed by its Content-Length, and renders it with
/// `\r\n` shown as `\n`. Returns `"closed"` when the connection ends first.
async fn read_response(conn : @socket.Tcp) -> String {
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
async fn closed(conn : @socket.Tcp) -> Bool {
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
        "version" | "commit" | "toolchain" => out[key] = "*"
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
