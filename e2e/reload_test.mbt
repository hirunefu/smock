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
/// How long a test waits for the next poll to find a change: the 10 s poll
/// interval, and some.
let poll_patience_ms : Int = 15_000

///|
/// Waits until status shows another last reload than `before` does, at
/// most `within` milliseconds, and returns that status.
async fn Smock::reloaded(
  self : Smock,
  before : Map[String, Json],
  within? : Int = reload_patience_ms,
) -> Map[String, Json] {
  let previous = before.get("lastReload")
  let status = @async.with_timeout_opt(within, () => {
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
          #|{"level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"<served at startup>","newDigest":"<served after the fix>","scenarioStatesReset":0}
        ),
      )
    },
  )
}

///|
/// Mock `payments` with two Scenarios: `POST /orders/42/pay` moves
/// `checkout` to `Paid`, and `GET /orders/42` answers paid from then on;
/// `POST /orders/42/ship` moves `shipping` to `Shipped`, and `GET
/// /orders/42/shipment` answers shipped from then on.
let pay_and_ship : String =
  #|{ "mocks": [{ "name": "payments" }],
  #|  "stubs": [
  #|    { "id": "pay", "mock": "payments",
  #|      "request": { "method": "POST", "path": "/orders/42/pay" },
  #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
  #|      "response": { "status": 200 } },
  #|    { "id": "order-paid", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "scenario": { "name": "checkout", "requires": "Paid" },
  #|      "response": { "status": 200, "json": { "status": "paid" } } },
  #|    { "id": "order", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42" },
  #|      "response": { "status": 200, "json": { "status": "pending" } } },
  #|    { "id": "ship", "mock": "payments",
  #|      "request": { "method": "POST", "path": "/orders/42/ship" },
  #|      "scenario": { "name": "shipping", "moveTo": "Shipped" },
  #|      "response": { "status": 200 } },
  #|    { "id": "shipped", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42/shipment" },
  #|      "scenario": { "name": "shipping", "requires": "Shipped" },
  #|      "response": { "status": 200, "json": { "shipped": true } } },
  #|    { "id": "shipment", "mock": "payments",
  #|      "request": { "method": "GET", "path": "/orders/42/shipment" },
  #|      "response": { "status": 200, "json": { "shipped": false } } } ] }

///|
async test "a reload by editing a file keeps a state whose name still exists, sends a renamed one back to Started, and logs how many went back" {
  with_definitions([("payments.json", pay_and_ship)], dir => {
    let mut digests = []
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      step("pay", smock.order("POST", "/orders/42/pay", session="test-a"))
      step("ship", smock.order("POST", "/orders/42/ship", session="test-a"))
      step("order", smock.order("GET", "/orders/42", session="test-a"))
      step(
        "shipment",
        smock.order("GET", "/orders/42/shipment", session="test-a"),
      )
      let before = smock.status()
      // The paid body gains a receipt, and Shipped is renamed Sent.
      write(
        dir,
        "payments.json",
        pay_and_ship
        .replace(
          old="{ \"status\": \"paid\" }",
          new="{ \"status\": \"paid\", \"receipt\": \"r-1\" }",
        )
        .replace_all(old="\"Shipped\"", new="\"Sent\""),
      )
      let after = smock.reloaded(before)
      step("reload", last_reload(after))
      step("order", smock.order("GET", "/orders/42", session="test-a"))
      step(
        "shipment",
        smock.order("GET", "/orders/42/shipment", session="test-a"),
      )
      digests = [
        ("<before>", before.get("digest")),
        ("<after>", after.get("digest")),
      ]
      inspect(
        out.join("\n"),
        content=(
          #|pay: 200, no body
          #|ship: 200, no body
          #|order: 200 {"status":"paid"}
          #|shipment: 200 {"shipped":true}
          #|reload: "swapped"
          #|order: 200 {"status":"paid","receipt":"r-1"}
          #|shipment: 200 {"shipped":false}
        ),
      )
    })
    inspect(
      reload_entries(stopped.logs, digests),
      content=(
        #|{"level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"<before>","newDigest":"<after>","scenarioStatesReset":1}
      ),
    )
  })
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

///|
/// Serves the definitions directory `defs`, whose files are reached through
/// symlinks that lead out of it, so that no event reports their changes:
/// `users.json` leads into the ConfigMap-style volume `cm`, and the
/// body-file subdirectory `files` into `body`, whose subdirectory `users`
/// the file watcher does not look into. Runs `change` with the directory
/// that holds them all, then tells whether a reload came within 1 s, as an
/// event would bring one, and what the next poll reloaded.
///
/// The files are older than the 2 s after which a poll trusts its stamp
/// when smock starts, so that the first poll finds the change by comparing
/// its stamp with the one taken at startup.
async fn found_by_poll(change : async (String) -> Unit) -> String {
  let out = []
  with_definitions(
    [
      ("defs/mocks.json", reload_mock),
      ("body/users/1.json", "Alice"),
      ("body/users/old.txt", "old"),
    ],
    root => {
      @fs.mkdir("\{root}/cm")
      configmap_update("\{root}/cm", "v1", [("users.json", user_stub)])
      @fs.symlink(target="..data/users.json", "\{root}/cm/users.json")
      @fs.symlink(target="\{root}/cm/users.json", "\{root}/defs/users.json")
      @fs.symlink(target="\{root}/body", "\{root}/defs/files")
      @async.sleep(2500)
      let _ = with_smock(["--dir", "\{root}/defs", "--port", "0"], smock => {
        let before = smock.status()
        change(root)
        @async.sleep(1000)
        out.push("within 1 s: \{last_reload(smock.status())}")
        let after = smock.reloaded(before, within=poll_patience_ms)
        out.push(
          "by the next poll: \{last_reload(after)}; /users/1: \{smock.brief("/users/1")}",
        )
      })
    },
  )
  out.join("\n")
}

///|
async test "a body file edited where no event reports it, through a symlink that leads out of the definitions directory, is found by the next poll" {
  inspect(
    found_by_poll(root => write(root, "body/users/1.json", "Bob")),
    content=(
      #|within 1 s: null
      #|by the next poll: "swapped"; /users/1: 200 Bob
    ),
  )
}

///|
async test "a body file added where no event reports it is found by the next poll" {
  inspect(
    found_by_poll(root => write(root, "body/users/2.json", "Carol")),
    content=(
      #|within 1 s: null
      #|by the next poll: "swapped"; /users/1: 200 Alice
    ),
  )
}

///|
async test "a body file removed where no event reports it is found by the next poll" {
  inspect(
    found_by_poll(root => @fs.remove("\{root}/body/users/old.txt")),
    content=(
      #|within 1 s: null
      #|by the next poll: "swapped"; /users/1: 200 Alice
    ),
  )
}

///|
async test "a ConfigMap-style ..data swap where no event reports it, behind a symlink that leads out of the definitions directory, is found by the next poll" {
  inspect(
    found_by_poll(root => {
      configmap_update(
        "\{root}/cm",
        "v2",
        [("users.json", stub_file("get-user", "/users/1", "Dave"))],
        replaces="v1",
      )
    }),
    content=(
      #|within 1 s: null
      #|by the next poll: "swapped"; /users/1: 200 Dave
    ),
  )
}

///|
async test "a git-sync update that keeps the old worktree, so that no event reports it, is found by the next poll" {
  with_definitions([], root => {
    git_sync_update(root, "c1", [
      ("mocks/mocks.json", reload_mock),
      ("mocks/users.json", user_stub),
      ("mocks/files/users/1.json", "Alice"),
    ])
    // Older than the 2 s after which a poll trusts its stamp.
    @async.sleep(2500)
    let _ = with_smock(["--dir", "\{root}/current/mocks", "--port", "0"], smock => {
      let before = smock.status()
      // As with git-sync's --stale-worktree-timeout: c1 stays.
      git_sync_update(root, "c2", [
        ("mocks/mocks.json", reload_mock),
        ("mocks/users.json", user_stub),
        ("mocks/files/users/1.json", "Alice"),
        ("mocks/orders.json", stub_file("orders", "/orders", "orders")),
      ])
      @async.sleep(1000)
      let within = last_reload(smock.status())
      let after = smock.reloaded(before, within=poll_patience_ms)
      inspect(
        (
          $|within 1 s: \{within}
          $|by the next poll: \{last_reload(after)}; /orders: \{smock.brief("/orders")}
        ),
        content=(
          #|within 1 s: null
          #|by the next poll: "swapped"; /orders: 200 orders
        ),
      )
    })
  })
}

///|
async test "a Definition file whose modification time is ahead of the clock is warned about once" {
  with_definitions(
    [
      ("defs/mocks.json", reload_mock),
      ("defs/users.json", user_stub),
      ("defs/files/users/1.json", "Alice"),
    ],
    root => {
      let dir = "\{root}/defs"
      // A day ahead, as from an archive made on a host whose clock ran
      // ahead.
      let ahead = @async.now() / 1000 + 86_400
      let status = @process.run("touch", [
        "-m",
        "-d",
        "@\{ahead}",
        "\{dir}/users.json",
      ])
      guard status == 0 else { fail("touch exited with \{status}") }
      let (_, date) = collect_stdout("date", [
        "-u",
        "-d",
        "@\{ahead}",
        "+%Y-%m-%dT%H:%M:%S.000Z",
      ])
      let expected = Json::string(date.text().trim().to_owned()).stringify()
      let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
        // Another check, whose stamp notes the same time.
        let before = smock.status()
        write(dir, "README.md", "")
        let _ = smock.reloaded(before)
      })
      let warnings = stopped.logs.filter_map(line => {
        guard @json.parse(line) is Object(fields) &&
          fields.get("level") is Some(String("warn")) else {
          return None
        }
        let file = fields
          .get("file")
          .map_or("?", file => file.stringify().replace(old=root, new="<root>"))
        let time = fields.get("fileTime").map_or("?", time => time.stringify())
        Some(
          "\{fields.get("msg").map_or("?", msg => msg.stringify())} \{file} at the time set: \{time == expected}",
        )
      }) catch {
        _ => fail("a log line is not JSON")
      }
      inspect(
        warnings.join("\n"),
        content=(
          #|"a file in the definitions directory has a time ahead of the clock" "<root>/defs/users.json" at the time set: true
        ),
      )
    },
  )
}

///|
async test "a symlink outside the definitions directory pointed at a file with the very same times is found by the next poll" {
  with_definitions([("defs/mocks.json", reload_mock)], root => {
    // Two releases of users.json, written back to back, as a script that
    // writes both would: within one clock tick they get the very same
    // times. A new pair is written until they do.
    let times = async fn(path : String) { (@fs.mtime(path), @fs.ctime(path)) }
    let mut same = false
    let mut release = 0
    while !same && release < 20 {
      release += 1
      for name in ["a", "b"] {
        @fs.mkdir("\{root}/rel/\{release}\{name}", recursive=true)
      }
      for name in ["a", "b"] {
        @fs.write_file(
          "\{root}/rel/\{release}\{name}/users.json",
          stub_file("get-user", "/users/1", name),
        )
      }
      same = times("\{root}/rel/\{release}a/users.json") ==
        times("\{root}/rel/\{release}b/users.json")
    }
    @fs.symlink(target="\{release}a", "\{root}/rel/current")
    @fs.symlink(
      target="\{root}/rel/current/users.json",
      "\{root}/defs/users.json",
    )
    // Older than the 2 s after which a poll trusts its stamp.
    @async.sleep(2500)
    let _ = with_smock(["--dir", "\{root}/defs", "--port", "0"], smock => {
      let before = smock.status()
      let served_before = smock.brief("/users/1")
      @fs.symlink(target="\{release}b", "\{root}/rel/next")
      @fs.rename("\{root}/rel/next", "\{root}/rel/current")
      @async.sleep(1000)
      let within = last_reload(smock.status())
      let after = smock.reloaded(before, within=poll_patience_ms)
      inspect(
        (
          $|the very same times: \{same}
          $|before: \{served_before}
          $|within 1 s: \{within}
          $|by the next poll: \{last_reload(after)}; /users/1: \{smock.brief("/users/1")}
        ),
        content=(
          #|the very same times: true
          #|before: 200 a
          #|within 1 s: null
          #|by the next poll: "swapped"; /users/1: 200 b
        ),
      )
    })
  })
}
