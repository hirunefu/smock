// Seam 1 tests of reloading: the definition set digest, and how the engine
// swaps in a new definition set, keeps the current one when the new one is
// invalid, and keeps responses already planned as they were.

///|
/// A Mock `users` for `users.example.com`, whose Stub answers `GET
/// /users/1` with the body file `users/1.json`.
let users_with_body_file : String =
  #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] }],
  #|  "stubs": [{ "id": "get-user", "mock": "users",
  #|    "request": { "method": "GET", "path": "/users/1" },
  #|    "response": { "status": 200, "bodyFile": "users/1.json" } }] }

///|
let alice : Bytes = b"{\"id\":1,\"name\":\"Alice\"}"

///|
test "the startup snapshot has a digest: the first 12 hex digits of SHA-256 over the framed names and bytes of every file" {
  // The expected values were computed outside smock, with Python's hashlib,
  // over the framing docs/definition-files.md describes.
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  inspect(h.engine.status().digest, content="aaa0fc44b496")
  // Without files, it is the digest of no bytes at all.
  inspect(harness([]).engine.status().digest, content="e3b0c44298fc")
}

///|
/// The digest of an engine built from Definition files given as (name,
/// text) pairs and body files as (name, bytes) pairs.
fn digest_of(
  files : Array[(String, String)],
  body_files? : Array[(String, Bytes)] = [],
) -> String {
  harness(files, body_files~).engine.status().digest
}

///|
/// A Definition file declaring the Mock `name`.
fn named_mock(name : String) -> String {
  "{ \"mocks\": [{ \"name\": \"\{name}\" }] }"
}

///|
test "the same files give the same digest, whatever order they are read in" {
  let files = [
    ("a.json", named_mock("a")),
    ("b.yaml", "mocks: [{ name: b }]\n"),
  ]
  let bodies = [("x.txt", b"x"), ("sub/y.txt", b"y"), ("z.txt", b"z")]
  let digests = [
    digest_of(files, body_files=bodies),
    digest_of(files.rev(), body_files=bodies.rev()),
    digest_of([files[1], files[0]], body_files=[bodies[2], bodies[0], bodies[1]]),
  ]
  inspect(digests[0] == digests[1] && digests[1] == digests[2], content="true")
}

///|
test "changing one byte of a Definition file or a body file, renaming a file or adding one changes the digest" {
  let bodies = [("users/1.json", alice), ("notes.txt", b"notes")]
  let base = digest_of(
    [("users.json", users_with_body_file)],
    body_files=bodies,
  )
  let changes = [
    (
      "one byte of the Definition file",
      digest_of(
        [("users.json", users_with_body_file.replace(old="200", new="201"))],
        body_files=bodies,
      ),
    ),
    (
      "one byte of a body file",
      digest_of([("users.json", users_with_body_file)], body_files=[
        ("users/1.json", alice),
        ("notes.txt", b"notez"),
      ]),
    ),
    (
      "the Definition file renamed",
      digest_of([("users2.json", users_with_body_file)], body_files=bodies),
    ),
    (
      "a body file renamed",
      digest_of([("users.json", users_with_body_file)], body_files=[
        ("users/1.json", alice),
        ("notes2.txt", b"notes"),
      ]),
    ),
    (
      "a Definition file added",
      digest_of(
        [("users.json", users_with_body_file), ("z.json", named_mock("z"))],
        body_files=bodies,
      ),
    ),
    (
      "a body file added",
      digest_of(
        [("users.json", users_with_body_file)],
        body_files=[..bodies, ("empty.txt", b"")],
      ),
    ),
  ]
  inspect(
    changes.map(change => "\{change.0}: \{change.1 != base}").join("\n"),
    content=(
      #|one byte of the Definition file: true
      #|one byte of a body file: true
      #|the Definition file renamed: true
      #|a body file renamed: true
      #|a Definition file added: true
      #|a body file added: true
    ),
  )
}

///|
test "sets whose names and bytes run together the same way still have different digests" {
  let sets = [
    ("ab + c", [("ab", b"c")]),
    ("a + bc", [("a", b"bc")]),
    ("a + b, c + d", [("a", b"b"), ("c", b"d")]),
    ("a + bcd", [("a", b"bcd")]),
    ("a + b, c + d, empty", [("a", b"b"), ("c", b"d"), ("e", b"")]),
  ]
  let digests = sets.map(set => digest_of([], body_files=set.1))
  let collisions = []
  for i in 0..<digests.length() {
    for j in (i + 1)..<digests.length() {
      if digests[i] == digests[j] {
        collisions.push("\{sets[i].0} = \{sets[j].0}")
      }
    }
  }
  debug_inspect(collisions, content="[]")
  // A Definition file and a body file with the same name and bytes differ
  // too.
  inspect(
    digest_of([("m.json", named_mock("m"))]) ==
    digest_of([("m.json", named_mock("m"))], body_files=[
      ("m.json", @utf8.encode(named_mock("m"))),
    ]),
    content="false",
  )
}

///|
/// 2026-10-12T14:31:00.000Z, when the reloads in these tests finish.
let reload_time : Int64 = 1_791_815_460_000L

///|
/// Reloads the engine of `h` with Definition files given as (name, text)
/// pairs and body files as (name, bytes) pairs.
fn Harness::reload(
  self : Harness,
  files : Array[(String, String)],
  body_files? : Array[(String, Bytes)] = [],
  read_problems? : Array[@definitions.Diagnostic] = [],
) -> @engine.ReloadResult {
  self.engine.reload(
    { files: files.map(file => (file.0, @utf8.encode(file.1))), body_files, },
    read_problems~,
    at=reload_time,
  )
}

///|
/// A reload result: what happened, when, the digests served before and
/// after it, and its errors, one per line.
fn reload_summary(result : @engine.ReloadResult) -> String {
  let out = StringBuilder()
  out.write_string(
    "\{@debug.to_string(result.result)} at \{result.at}: \{result.old_digest} -> \{result.new_digest}",
  )
  for error in result.errors {
    out.write_string("\n\{error.to_string()}")
  }
  out.to_string()
}

///|
test "a reload swaps in a valid new set: later requests get its responses, and status shows its digest and the reload" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  let before = h.engine.status().digest
  let result = h.reload([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", b"{\"id\":1,\"name\":\"Bob\"}"),
  ])
  let after = h.engine.status()
  inspect(after.digest != before, content="true")
  inspect(
    reload_summary(result)
    .replace(old=before, new="<before>")
    .replace(old=after.digest, new="<after>"),
    content="Swapped at 1791815460000: <before> -> <after>",
  )
  debug_inspect(after.last_reload.map(r => r.result), content="Some(Swapped)")
  inspect(
    response(h.send("GET", "/users/1", headers=[("Host", "users.example.com")])),
    content=(
      #|200
      #|{"id":1,"name":"Bob"}
    ),
  )
}

///|
test "before the first reload, status shows no last reload" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  debug_inspect(h.engine.status().last_reload, content="None")
}

///|
test "a reload of the files served swaps nothing, and the last reload says unchanged" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  let digest = h.engine.status().digest
  // The same files, read in another order.
  let result = h.reload([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  inspect(
    reload_summary(result).replace_all(old=digest, new="<digest>"),
    content="Unchanged at 1791815460000: <digest> -> <digest>",
  )
  inspect(h.engine.status().digest == digest, content="true")
  debug_inspect(
    h.engine.status().last_reload.map(r => r.result),
    content="Some(Unchanged)",
  )
}

///|
test "an invalid set leaves the current snapshot serving with its digest, and the last reload lists every error" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  let digest = h.engine.status().digest
  let result = h.reload(
    [
      ("users.json", users_with_body_file.replace(old="200", new="99")),
      ("broken.json", "{ \"mocks\": "),
    ],
    body_files=[("users/1.json", b"{\"id\":1,\"name\":\"Bob\"}")],
    read_problems=[
      { file: "locked.json", pointer: "", message: "cannot be read: EACCES", },
    ],
  )
  inspect(
    reload_summary(result).replace_all(old=digest, new="<digest>"),
    content=(
      #|Failed at 1791815460000: <digest> -> <digest>
      #|locked.json: cannot be read: EACCES
      #|broken.json: not valid JSON: Unexpected end of file
      #|users.json: /stubs/0/response/status: must be an integer from 200 to 599
    ),
  )
  let status = h.engine.status()
  inspect(status.digest == digest, content="true")
  inspect(
    status.last_reload.map_or("none", r => reload_summary(r)) ==
    reload_summary(result),
    content="true",
  )
  inspect(
    response(h.send("GET", "/users/1", headers=[("Host", "users.example.com")])),
    content=(
      #|200
      #|{"id":1,"name":"Alice"}
    ),
  )
}

///|
test "a set read with problems fails even when its files are valid" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  let result = h.reload(
    [("users.json", users_with_body_file)],
    body_files=[("users/1.json", alice)],
    read_problems=[
      { file: "new.json", pointer: "", message: "cannot be read: EACCES", },
    ],
  )
  inspect(
    reload_summary(result).replace_all(
      old=h.engine.status().digest,
      new="<digest>",
    ),
    content=(
      #|Failed at 1791815460000: <digest> -> <digest>
      #|new.json: cannot be read: EACCES
    ),
  )
}

///|
test "a response planned before a swap stays as it was after it, body-file bytes included" {
  let h = harness([("users.json", users_with_body_file)], body_files=[
    ("users/1.json", alice),
  ])
  let planned = h.send("GET", "/users/1", headers=[
    ("Host", "users.example.com"),
  ])
  let before = describe(planned)
  let _ = h.reload(
    [("users.json", users_with_body_file.replace(old="200", new="203"))],
    body_files=[("users/1.json", b"{\"id\":1,\"name\":\"Bob\"}")],
  )
  inspect(describe(planned) == before, content="true")
  inspect(
    response(planned) +
    "\n---\n" +
    response(h.send("GET", "/users/1", headers=[("Host", "users.example.com")])),
    content=(
      #|200
      #|{"id":1,"name":"Alice"}
      #|---
      #|203
      #|{"id":1,"name":"Bob"}
    ),
  )
}

///|
test "a swap creates the generators of seeded Stubs anew from their seeds; a reload that swaps nothing keeps them going" {
  let seeded = faults_file([coin_flips("/seeded", seed=42)])
  let h = harness([seeded])
  let first = decisions(h, "/seeded", 4)
  // The same files: nothing is swapped, so the generator goes on.
  let _ = h.reload([seeded])
  let went_on = decisions(h, "/seeded", 4)
  // Another Stub added: the new snapshot's generator starts from the seed.
  let _ = h.reload([
    faults_file([coin_flips("/seeded", seed=42), coin_flips("/other", seed=7)]),
  ])
  let restarted = decisions(h, "/seeded", 4)
  // The first 8 decisions of seed 42, as the Fault tests pin them.
  inspect(
    [..first, "---", ..went_on, "---", ..restarted].join("\n"),
    content=(
      #|delay 0, Close
      #|delay 0
      #|delay 395
      #|delay 572
      #|---
      #|delay 818
      #|delay 0, Close
      #|delay 594, Close
      #|delay 0
      #|---
      #|delay 0, Close
      #|delay 0
      #|delay 395
      #|delay 572
    ),
  )
}

///|
test "after a reload removes a Mock, its Hosts resolve like any unknown Host" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
    mock_file("other", "\"hosts\": [\"other.example.com\"]"),
  ])
  let orders = [("Host", "orders.example.com")]
  let before = answer(h, "/x", orders)
  let _ = h.reload([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("other", "\"hosts\": [\"other.example.com\"]"),
  ])
  let without_default = answer(h, "/x", orders)
  let _ = h.reload([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("other", "\"hosts\": [\"other.example.com\"], \"default\": true"),
  ])
  let with_default = answer(h, "/x", orders)
  inspect(
    [before, without_default, with_default].join("---\n"),
    content=(
      #|ByHost("orders")
      #|200
      #|from orders---
      #|NoMock
      #|404
      #|Content-Type: application/json
      #|{"error":"no Mock for this Host","host":"orders.example.com","acceptedHosts":["other.example.com","users.example.com"]}---
      #|ViaDefault("other")
      #|200
      #|Smock-Mock: other; via=default
      #|from other
    ),
  )
}

///|
test "the reload outcomes are named as the Admin API's lastReload.result names them" {
  inspect(
    @engine.ReloadOutcome::all().map(outcome => outcome.name()).join(", "),
    content="swapped, unchanged, failed",
  )
}
