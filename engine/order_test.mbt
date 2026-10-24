// Seam 1 tests of the order Stubs are tried in: priority first, then
// file-name order, then position in the file. The first matching Stub wins.

///|
/// A Stub of Mock `m` with `id`, an optional priority and conditions given
/// as JSON members, such as `"method": "GET"`. It answers 200 with its ID.
fn stub(id : String, priority? : Int32, request~ : String = "") -> String {
  let priority = match priority {
    Some(p) => "\"priority\": \{p}, "
    None => ""
  }
  "{ \"id\": \"\{id}\", \"mock\": \"m\", \{priority}\"request\": { \{request} }, \"response\": { \"status\": 200, \"body\": \"\{id}\" } }"
}

///|
/// A Definition file declaring `stubs`.
fn stub_file(stubs : Array[String]) -> String {
  "{ \"stubs\": [\{stubs.join(", ")}] }"
}

///|
let mock_m : (String, String) = (
  "mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }",
)

///|
/// The ID of the Stub that answers `GET target`, or `none`.
fn winner(h : Harness, target : String) -> String {
  matched_id(h.send("GET", target)).unwrap_or("none")
}

///|
test "a Stub with a lower priority number is tried first, wherever it is declared" {
  let h = harness([
    mock_m,
    (
      "a.json",
      stub_file([
        stub("catch-all", priority=10),
        stub("user", priority=1, request="\"path\": \"/users/1\""),
        stub("first", priority=-5, request="\"path\": \"/first\""),
      ]),
    ),
    (
      "b.json",
      stub_file([
        stub("late", priority=-2147483648, request="\"path\": \"/late\""),
      ]),
    ),
  ])
  inspect(
    ["/users/1", "/users/2", "/first", "/late"]
    .map(target => "\{target} -> \{winner(h, target)}")
    .join("\n"),
    content=(
      #|/users/1 -> user
      #|/users/2 -> catch-all
      #|/first -> first
      #|/late -> late
    ),
  )
}

///|
test "a Stub without a priority comes after every Stub with one, however large its number" {
  let h = harness([
    mock_m,
    (
      "a.json",
      stub_file([
        stub("no-priority"),
        stub("highest-number", priority=2147483647, request="\"path\": \"/x\""),
      ]),
    ),
  ])
  inspect(
    "/x -> \{winner(h, "/x")}\n/y -> \{winner(h, "/y")}",
    content=(
      #|/x -> highest-number
      #|/y -> no-priority
    ),
  )
}

///|
/// The Definition file `<name>.json`: a Stub `<name>-1` that matches only
/// `/other`, then a Stub `<name>-2` that matches every request, both with
/// `priority`.
fn file(name : String, priority? : Int32) -> (String, String) {
  let first = stub("\{name}-1", priority?, request="\"path\": \"/other\"")
  let second = stub("\{name}-2", priority?)
  ("\{name}.json", stub_file([first, second]))
}

///|
test "Stubs of equal priority are tried in byte-wise file-name order, then by position in the file" {
  // Byte-wise, "B" < "a" < "aa" < "b": upper case first, and not by length.
  let h = harness([mock_m, file("b"), file("aa"), file("a"), file("B")])
  inspect(winner(h, "/x"), content="B-2")
  let h = harness([mock_m, file("b", priority=3), file("aa", priority=3)])
  inspect(winner(h, "/x"), content="aa-2")
  let h = harness([mock_m, file("aa", priority=3), file("b", priority=2)])
  inspect(winner(h, "/x"), content="b-2")
  let h = harness([
    mock_m,
    ("a.json", stub_file([stub("a-1", priority=0), stub("a-2", priority=0)])),
  ])
  inspect(winner(h, "/x"), content="a-1")
}

///|
test "the snapshot holds each Mock's Stubs in the order they are tried" {
  let set : @definitions.DefinitionSet = {
    files: [
      (
        "mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }, { \"name\": \"o\" }] }",
      ),
      (
        "b.json",
        stub_file([
          stub("b-unset"),
          stub("b-p5", priority=5),
          stub("b-p-1", priority=-1),
          stub("b-p5-again", priority=5),
        ]),
      ),
      (
        "a.json",
        stub_file([
          stub("a-p5", priority=5),
          stub("a-unset"),
          "{ \"id\": \"a-o\", \"mock\": \"o\", \"priority\": 1, \"response\": { \"status\": 200 } }",
          stub("a-p0", priority=0),
          stub("a-unset-again"),
        ]),
      ),
      (
        "c.yaml",
        (
          #|stubs:
          #|  - { id: c-p5, mock: m, priority: 5, response: { status: 200 } }
          #|  - { id: c-o, mock: o, response: { status: 200 } }
          #|  - { id: c-p-1, mock: m, priority: -1, response: { status: 200 } }
        ),
      ),
    ].map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  let snapshot = match @definitions.load(set) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
  inspect(
    snapshot.mocks
    .iter()
    .map(mock => {
      "\{mock.name}: " + mock.stubs.iter().map(stub => stub.id).join(", ")
    })
    .join("\n"),
    content=(
      #|m: b-p-1, c-p-1, a-p0, a-p5, b-p5, b-p5-again, c-p5, a-unset, a-unset-again, b-unset
      #|o: a-o, c-o
    ),
  )
}
