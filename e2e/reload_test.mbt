// Seam 2 tests of reloading the Definition files: smock watches the
// definitions directory and its body-file subdirectory, and swaps in a new
// definition set when its files change. Every status response is checked
// against the OpenAPI document (contract_test.mbt).

///|
/// The status, checked against the document.
async fn Smock::status(self : Smock) -> Map[String, Json] {
  let response = self.admin("GET", "/v1/status")
  guard response.json() is Object(status) else { fail(response.body) }
  status
}

///|
/// How long a test waits for a reload after changing a file: well below
/// the 10 s poll interval, so that a reload in time comes from watching
/// the files, not from polling them.
let reload_patience_ms : Int = 5000

///|
/// Waits until status shows another last reload than `before` does, and
/// returns that status.
async fn Smock::reloaded(
  self : Smock,
  before : Map[String, Json],
) -> Map[String, Json] {
  let previous = before.get("lastReload")
  let status = @async.with_timeout_opt(reload_patience_ms, () => {
    for ;; {
      let status = self.status()
      if status.get("lastReload") != previous {
        break status
      }
      @async.sleep(20)
    }
  })
  guard status is Some(status) else {
    fail("no reload in time; status: \{Json::object(before).stringify()}")
  }
  status
}

///|
/// The status and the body of the response to `GET path`, on one line.
async fn Smock::brief(self : Smock, path : String) -> String {
  let client = @http.Client("http://127.0.0.1:\{self.port}")
  defer client.close()
  let response = client.get(path)
  "\{response.code} \{client.read_all().text()}"
}

///|
/// The last reload of `status`: its result, then its errors, if any.
fn last_reload(status : Map[String, Json]) -> String {
  match status.get("lastReload") {
    Some(Object(reload)) => {
      let out = StringBuilder()
      out.write_string(reload.get("result").map_or("?", r => r.stringify()))
      if reload.get("errors") is Some(Array(errors)) {
        for error in errors {
          out.write_string("\n  \{error.stringify()}")
        }
      }
      out.to_string()
    }
    other => other.map_or("missing", r => r.stringify())
  }
}

///|
/// One Mock, `m`, in its own Definition file, so that the files that add
/// and remove Stubs never change which Mock answers.
let reload_mock : String = "{ \"mocks\": [{ \"name\": \"m\" }] }"

///|
/// A Stub of `m` that answers `GET /users/1` with the body file
/// `users/1.json`.
let user_stub : String =
  #|{ "stubs": [{ "id": "get-user", "mock": "m",
  #|  "request": { "method": "GET", "path": "/users/1" },
  #|  "response": { "status": 200, "bodyFile": "users/1.json" } }] }

///|
async test "adding, editing, renaming or removing a Definition file or a body file reloads the definitions" {
  with_definitions(
    [
      ("mocks.json", reload_mock),
      ("users.json", user_stub),
      ("files/users/1.json", "Alice"),
    ],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let orders = stub_file("orders", "/orders", "orders")
        let steps : Array[(String, async () -> Unit)] = [
          ("edit the body file", () => write(dir, "files/users/1.json", "Bob")),
          ("add a Definition file", () => write(dir, "orders.json", orders)),
          (
            "rename the Definition file",
            () => @fs.rename("\{dir}/orders.json", "\{dir}/orders-v2.json"),
          ),
          (
            "remove the Definition file",
            () => @fs.remove("\{dir}/orders-v2.json"),
          ),
          ("add a body file", () => write(dir, "files/extra.txt", "extra")),
          (
            "rename the body file",
            () => @fs.rename("\{dir}/files/extra.txt", "\{dir}/files/more.txt"),
          ),
          ("remove the body file", () => @fs.remove("\{dir}/files/more.txt")),
          (
            "write a Definition file again with the same bytes",
            () => write(dir, "users.json", user_stub),
          ),
        ]
        let out = []
        let mut status = smock.status()
        for step in steps {
          let (name, change) = step
          change()
          let next = smock.reloaded(status)
          let changed = next.get("digest") != status.get("digest")
          out.push(
            "\{name}: \{last_reload(next)}, digest changed: \{changed}; /users/1: \{smock.brief("/users/1")}; /orders: \{smock.brief("/orders")}",
          )
          status = next
        }
        inspect(
          out.join("\n"),
          content=(
            #|edit the body file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
            #|add a Definition file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 200 orders
            #|rename the Definition file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 200 orders
            #|remove the Definition file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
            #|add a body file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
            #|rename the body file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
            #|remove the body file: "swapped", digest changed: true; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
            #|write a Definition file again with the same bytes: "unchanged", digest changed: false; /users/1: 200 Bob; /orders: 404 {"error":"no Stub matched"}
          ),
        )
      })
    },
  )
}

///|
/// The log entries about reloads, without their time, with each digest in
/// `digests` shown as its name.
fn reload_entries(
  logs : Array[String],
  digests : Array[(String, Json?)],
) -> String {
  let out = []
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(msg)) &&
      msg.contains("reload") else {
      continue
    }
    fields.remove("time")
    let mut text = Json::object(fields).stringify()
    for digest in digests {
      if digest.1 is Some(String(value)) {
        text = text.replace_all(old=value, new=digest.0)
      }
    }
    out.push(text)
  }
  out.join("\n")
}

///|
async test "an invalid set keeps the current one serving and is reported in status, a log entry and the reload metric; fixing it swaps" {
  with_definitions(
    [
      ("mocks.json", reload_mock),
      ("users.json", user_stub),
      ("files/users/1.json", "Alice"),
    ],
    dir => {
      let mut digests = []
      let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
        let before = smock.status()
        let broken =
          #|{ "stubs": [{ "id": "get-user", "mock": "nobody",
          #|  "request": { "method": "GET", "path": "/users/1" },
          #|  "response": { "status": 99, "bodyFile": "users/1.json" } }] }
        write(dir, "users.json", broken)
        let failed = smock.reloaded(before)
        let kept = failed.get("digest") == before.get("digest")
        let served = smock.brief("/users/1")
        write(dir, "users.json", user_stub.replace(old="200", new="201"))
        let fixed = smock.reloaded(failed)
        let changed = fixed.get("digest") != before.get("digest")
        digests = [
          ("<served at startup>", before.get("digest")),
          ("<served after the fix>", fixed.get("digest")),
        ]
        inspect(
          (
            $|broken: \{last_reload(failed)}
            $|digest kept: \{kept}; /users/1: \{served}
            $|fixed: \{last_reload(fixed)}
            $|digest changed: \{changed}; /users/1: \{smock.brief("/users/1")}
            $|\{smock.metric("smock_definition_reloads_total", help=true)}
          ),
          content=(
            #|broken: "failed"
            #|  {"file":"users.json","pointer":"/stubs/0/response/status","message":"must be an integer from 200 to 599"}
            #|  {"file":"users.json","pointer":"/stubs/0/mock","message":"no file declares the Mock \"nobody\""}
            #|digest kept: true; /users/1: 200 Alice
            #|fixed: "swapped"
            #|digest changed: true; /users/1: 201 Alice
            #|# HELP smock_definition_reloads_total Reloads of the Definition files, by result: swapped (the new definition set is served), unchanged (it had the digest served) or failed (it was invalid, and the previous one is still served).
            #|# TYPE smock_definition_reloads_total counter
            #|smock_definition_reloads_total{result="swapped"} 1
            #|smock_definition_reloads_total{result="unchanged"} 0
            #|smock_definition_reloads_total{result="failed"} 1
          ),
        )
        // When the reload finished, as an RFC 3339 time in UTC.
        guard fixed.get("lastReload") is Some(Object(reload)) &&
          reload.get("at") is Some(String(at)) else {
          fail("no time in \{Json::object(fixed).stringify()}")
        }
        let time = @re2.compile(
          "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z",
        )
        inspect(time.full_match(@utf8.encode(at)), content="true")
      })
      inspect(
        reload_entries(stopped.logs, digests),
        content=(
          #|{"level":"error","msg":"definitions reload failed","result":"failed","digest":"<served at startup>","errors":[{"file":"users.json","pointer":"/stubs/0/response/status","message":"must be an integer from 200 to 599"},{"file":"users.json","pointer":"/stubs/0/mock","message":"no file declares the Mock \"nobody\""}]}
          #|{"level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"<served at startup>","newDigest":"<served after the fix>"}
        ),
      )
    },
  )
}

///|
/// How many bytes of `bytes` are not `byte`.
fn count_other(bytes : BytesView, byte : Byte) -> Int {
  let mut n = 0
  for b in bytes {
    if b != byte {
      n += 1
    }
  }
  n
}

///|
async test "a large body written to a slow reader during a reload completes with the old content" {
  // Far more than the socket buffers hold, so smock is still writing the
  // body when the reload swaps the definitions.
  let size = 16 * 1024 * 1024
  let big_stub =
    #|{ "stubs": [{ "id": "big", "mock": "m",
    #|  "request": { "method": "GET", "path": "/big" },
    #|  "response": { "status": 200, "bodyFile": "big.bin" } }] }
  with_definitions([("mocks.json", reload_mock), ("big.json", big_stub)], dir => {
    @fs.mkdir("\{dir}/files")
    @fs.write_file("\{dir}/files/big.bin", Bytes::make(size, b'a'))
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      let slow = smock.connect()
      defer slow.close()
      slow.write("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
      guard slow.read_until("\r\n\r\n") is Some(head) else {
        fail("no response head")
      }
      let first = slow.read_exactly(1024)
      // The reader pauses; meanwhile the body file changes.
      @fs.write_file("\{dir}/files/big.bin", Bytes::make(size, b'b'))
      let after = smock.reloaded(before)
      let rest = @async.with_timeout_opt(patience_ms, () => {
        slow.read_exactly(size - 1024)
      })
      guard rest is Some(rest) else { fail("the body did not arrive in time") }
      // A request after the reload gets the new content.
      let fresh = smock.connect()
      defer fresh.close()
      fresh.write("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let _ = fresh.read_until("\r\n\r\n")
      let fresh_start = fresh.read_exactly(1024)
      inspect(
        (
          $|\{head.split("\r\n").filter(line => !line.has_prefix("Smock-Mock")).collect().join("\n")}
          $|reload: \{last_reload(after)}
          $|bytes of the first response that are not "a": \{count_other(first, b'a') + count_other(rest, b'a')}
          $|bytes at the start of a later response that are not "b": \{count_other(fresh_start, b'b')}
        ),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Length: 16777216
          #|reload: "swapped"
          #|bytes of the first response that are not "a": 0
          #|bytes at the start of a later response that are not "b": 0
        ),
      )
    })
  })
}

///|
async test "without a definitions directory, nothing is watched and no reload happens" {
  let stopped = with_smock(["--port", "0"], smock => {
    // Four quiet periods: a reload would have happened by now.
    @async.sleep(1000)
    let status = smock.status()
    inspect(
      (
        $|digest: \{status.get("digest").map_or("missing", d => d.stringify())}
        $|lastReload: \{last_reload(status)}
        $|\{smock.metric("smock_definition_reloads_total", help=true)}
      ),
      content=(
        #|digest: "e3b0c44298fc"
        #|lastReload: null
        #|# HELP smock_definition_reloads_total Reloads of the Definition files, by result: swapped (the new definition set is served), unchanged (it had the digest served) or failed (it was invalid, and the previous one is still served).
        #|# TYPE smock_definition_reloads_total counter
        #|smock_definition_reloads_total{result="swapped"} 0
        #|smock_definition_reloads_total{result="unchanged"} 0
        #|smock_definition_reloads_total{result="failed"} 0
      ),
    )
  })
  inspect(reload_entries(stopped.logs, []), content="")
}

///|
async test "a definitions directory that does not exist yet is polled every 10 s, without a warning, so its files are loaded once it appears" {
  with_definitions([], parent => {
    let dir = "\{parent}/later"
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      @fs.mkdir(dir)
      write(dir, "mocks.json", reload_mock)
      write(dir, "users.json", user_stub)
      write(dir, "files/users/1.json", "Alice")
      let status = @async.with_timeout_opt(15_000, () => {
        for ;; {
          let status = smock.status()
          if status.get("lastReload") != before.get("lastReload") {
            break status
          }
          @async.sleep(200)
        }
      })
      guard status is Some(status) else { fail("no reload within 15 s") }
      inspect(
        "\{last_reload(status)}; /users/1: \{smock.brief("/users/1")}",
        content=(
          #|"swapped"; /users/1: 200 Alice
        ),
      )
    })
    // No warning about watching.
    inspect(
      warnings_and_reloads(stopped.logs),
      content=(
        #|info: definitions reloaded
      ),
    )
  })
}

///|
/// The level and message of each warning, error and reload in `logs`, one
/// per line, and any line that is not a log entry.
fn warnings_and_reloads(logs : Array[String]) -> String {
  logs
  .filter_map(line => {
    let entry = @json.parse(line) catch { _ => return Some(line) }
    guard entry is Object(fields) &&
      fields.get("level") is Some(String(level)) &&
      fields.get("msg") is Some(String(msg)) else {
      return Some(line)
    }
    if level != "info" || msg.contains("reload") {
      Some("\{level}: \{msg}")
    } else {
      None
    }
  })
  .join("\n")
}

///|
/// Writes `files` into `dir` the way a ConfigMap volume does: into a new
/// timestamped directory `..<version>`, then points `..data` at it with an
/// atomic rename of a symlink, then removes the version it replaced, if
/// any. The visible names are symlinks into `..data`, made once.
async fn configmap_update(
  dir : String,
  version : String,
  files : Array[(String, String)],
  replaces? : String,
) -> Unit {
  for file in files {
    write(dir, "..\{version}/\{file.0}", file.1)
  }
  @fs.symlink(target="..\{version}", "\{dir}/..data_tmp")
  @fs.rename("\{dir}/..data_tmp", "\{dir}/..data")
  if replaces is Some(old) {
    @fs.rmdir("\{dir}/..\{old}", recursive=true)
  }
}

///|
async test "a ConfigMap update, which swaps the ..data symlink and keeps the visible names, reloads the definitions" {
  with_definitions([], dir => {
    configmap_update(dir, "2026_10_13_01", [
      ("mocks.json", reload_mock),
      ("users.json", user_stub),
      ("files/users/1.json", "Alice"),
    ])
    for name in ["mocks.json", "users.json", "files"] {
      @fs.symlink(target="..data/\{name}", "\{dir}/\{name}")
    }
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let before = smock.status()
      let served_before = smock.brief("/users/1")
      configmap_update(
        dir,
        "2026_10_13_02",
        [
          ("mocks.json", reload_mock),
          ("users.json", user_stub),
          ("files/users/1.json", "Bob"),
        ],
        replaces="2026_10_13_01",
      )
      let after = smock.reloaded(before)
      let changed = after.get("digest") != before.get("digest")
      inspect(
        "before: \{served_before}\n\{last_reload(after)}, digest changed: \{changed}\nafter: \{smock.brief("/users/1")}",
        content=(
          #|before: 200 Alice
          #|"swapped", digest changed: true
          #|after: 200 Bob
        ),
      )
    })
  })
}

///|
/// Writes `files` into `root` the way git-sync publishes a commit: into a
/// new worktree `.worktrees/<commit>`, then points the symlink `current` at
/// it with an atomic rename, then removes the worktree it replaced, if any,
/// as git-sync does by default.
async fn git_sync_update(
  root : String,
  commit : String,
  files : Array[(String, String)],
  replaces? : String,
) -> Unit {
  for file in files {
    write(root, ".worktrees/\{commit}/\{file.0}", file.1)
  }
  @fs.symlink(target=".worktrees/\{commit}", "\{root}/current_tmp")
  @fs.rename("\{root}/current_tmp", "\{root}/current")
  if replaces is Some(old) {
    @fs.rmdir("\{root}/.worktrees/\{old}", recursive=true)
  }
}

///|
async test "a git-sync update, which points the symlink that --dir goes through at a new worktree and removes the old one, reloads the definitions" {
  with_definitions([], root => {
    git_sync_update(root, "c1", [
      ("mocks/mocks.json", reload_mock),
      ("mocks/users.json", user_stub),
      ("mocks/files/users/1.json", "Alice"),
    ])
    let stopped = with_smock(
      ["--dir", "\{root}/current/mocks", "--port", "0"],
      smock => {
        let before = smock.status()
        let served_before = smock.brief("/users/1")
        git_sync_update(
          root,
          "c2",
          [
            ("mocks/mocks.json", reload_mock),
            ("mocks/users.json", user_stub),
            ("mocks/files/users/1.json", "Bob"),
          ],
          replaces="c1",
        )
        let after = smock.reloaded(before)
        let served_after = smock.brief("/users/1")
        // The watch has moved on to the new worktree, so the next commit
        // is seen too.
        git_sync_update(
          root,
          "c3",
          [
            ("mocks/mocks.json", reload_mock),
            ("mocks/users.json", user_stub),
            ("mocks/files/users/1.json", "Carol"),
          ],
          replaces="c2",
        )
        let next = smock.reloaded(after)
        inspect(
          (
            $|before: \{served_before}
            $|\{last_reload(after)}: \{served_after}
            $|\{last_reload(next)}: \{smock.brief("/users/1")}
          ),
          content=(
            #|before: 200 Alice
            #|"swapped": 200 Bob
            #|"swapped": 200 Carol
          ),
        )
      },
    )
    // A reload for each commit, and no warning about watching.
    inspect(
      warnings_and_reloads(stopped.logs),
      content=(
        #|info: definitions reloaded
        #|info: definitions reloaded
      ),
    )
  })
}
