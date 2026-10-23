// Validation of the Stub and Mock fields that decide matching and static
// responses: request conditions, priority, the Scenario clause, noMatch and
// body files.

///|
/// Loads the Definition file `a.json`, holding Mock `m` and `stubs`, with
/// `body_files`, and renders every diagnostic, one per line, or `valid`.
fn stub_problems(
  stubs : Array[String],
  body_files? : Array[(String, Bytes)] = [],
) -> String {
  let file = "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [\{stubs.join(", ")}] }"
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files,
  }
  match @definitions.load(set) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
/// A Stub of Mock `m` with `fields`, given as JSON members, and a 200
/// response.
fn stub_with(id : String, fields : String) -> String {
  "{ \"id\": \"\{id}\", \"mock\": \"m\", \{fields}, \"response\": { \"status\": 200 } }"
}

///|
test "query, header and body conditions are read as the Schema defines them" {
  inspect(
    stub_problems([
      stub_with(
        "valid",
        (
          #|"request": { "method": "POST", "path": "/a",
          #|  "query": { "q": "1", "": "", "a b": "é" },
          #|  "headers": { "X-A": "1", "x-a": "2", "Accept": "" },
          #|  "body": { "json": { "a": [1, null, { "b": true }] } } }
        ),
      ),
      stub_with("exact-body", "\"request\": { \"body\": \"\" }"),
      stub_with("json-null", "\"request\": { \"body\": { \"json\": null } }"),
    ]),
    content="valid",
  )
}

///|
test "a malformed query, header or body condition is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with(
        "a", "\"request\": { \"query\": [\"q\"], \"headers\": \"X-A: 1\" }",
      ),
      stub_with(
        "b",
        (
          #|"request": { "query": { "q": 1, "r": null, "s": ["1"] },
          #|  "headers": { "X A": "1", "X-B": 2, "a/b": "x" } }
        ),
      ),
      stub_with("c", "\"request\": { \"body\": 1 }"),
      stub_with("d", "\"request\": { \"body\": {} }"),
      stub_with(
        "e", "\"request\": { \"body\": { \"json\": {}, \"pattern\": \".*\" } }",
      ),
      stub_with(
        "f", "\"request\": { \"body\": { \"json\": {}, \"exact\": \"x\" } }",
      ),
      stub_with("g", "\"request\": { \"body\": [\"x\"] }"),
    ]),
    content=(
      #|a.json: /stubs/0/request/query: must be an object
      #|a.json: /stubs/0/request/headers: must be an object
      #|a.json: /stubs/1/request/query/q: must be a string or an object
      #|a.json: /stubs/1/request/query/r: must be a string or an object
      #|a.json: /stubs/1/request/query/s: must be a string or an object
      #|a.json: /stubs/1/request/headers/X A: is not a valid header name
      #|a.json: /stubs/1/request/headers/X-B: must be a string or an object
      #|a.json: /stubs/1/request/headers/a~1b: is not a valid header name
      #|a.json: /stubs/2/request/body: must be a string or an object
      #|a.json: /stubs/3/request/body: needs "json", "pattern", "form" or "xml"
      #|a.json: /stubs/4/request/body: has "json" and "pattern"; give only one of "json", "pattern", "form" or "xml"
      #|a.json: /stubs/5/request/body/exact: is not a known field
      #|a.json: /stubs/6/request/body: must be a string or an object
    ),
  )
}

///|
test "pattern conditions on the path, query, headers and body are read as the Schema defines them" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "path": { "pattern": "/users/[0-9]+" },
          #|  "query": { "q": { "pattern": "[0-9]+" }, "r": "exact" },
          #|  "headers": { "X-A": { "pattern": ".*" }, "X-B": "exact" },
          #|  "body": { "pattern": "(?s).*" } }
        ),
      ),
      stub_with(
        "empty",
        (
          #|"request": { "path": { "pattern": "" }, "query": { "q": { "pattern": "" } },
          #|  "headers": { "X-A": { "pattern": "" } }, "body": { "pattern": "" } }
        ),
      ),
      stub_with(
        "not-a-path", "\"request\": { \"path\": { \"pattern\": \"users|[a-z]*\" } }",
      ),
    ]),
    content="valid",
  )
}

///|
test "a malformed pattern condition is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "path": {}, "query": { "q": { "pattern": 1 } },
          #|  "headers": { "X-A": { "regex": ".*" } }, "body": { "pattern": null } }
        ),
      ),
      stub_with(
        "b",
        (
          #|"request": { "path": { "pattern": "/a", "flags": "i" },
          #|  "query": { "q": { "pattern": ["1"] } }, "headers": { "X-A": { } },
          #|  "body": { "pattern": ".*", "exact": "x" } }
        ),
      ),
      stub_with("c", "\"request\": { \"path\": 1, \"query\": { \"q\": [] } }"),
    ]),
    content=(
      #|a.json: /stubs/0/request/path: needs "pattern"
      #|a.json: /stubs/0/request/query/q/pattern: must be a string
      #|a.json: /stubs/0/request/headers/X-A/regex: is not a known field
      #|a.json: /stubs/0/request/headers/X-A: needs "pattern"
      #|a.json: /stubs/0/request/body/pattern: must be a string
      #|a.json: /stubs/1/request/path/flags: is not a known field
      #|a.json: /stubs/1/request/query/q/pattern: must be a string
      #|a.json: /stubs/1/request/headers/X-A: needs "pattern"
      #|a.json: /stubs/1/request/body/exact: is not a known field
      #|a.json: /stubs/2/request/path: must be a string or an object
      #|a.json: /stubs/2/request/query/q: must be a string or an object
    ),
  )
}

///|
test "a pattern that does not compile is a diagnostic at the JSON Pointer of its pattern field, with the error and its position in the pattern" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "path": { "pattern": "/users/([0-9]+" },
          #|  "query": { "q": { "pattern": "a**" } },
          #|  "headers": { "X-A/B": { "pattern": "[z-a]" } },
          #|  "body": { "pattern": "x{1001}" } }
        ),
      ),
      stub_with(
        "b", "\"request\": { \"path\": { \"pattern\": \"/café/(?P<é>x)\" } }",
      ),
      stub_with(
        "c", "\"request\": { \"query\": { \"~q\": { \"pattern\": \")\" } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/path/pattern: is not a valid pattern: position 7: missing closing )
      #|a.json: /stubs/0/request/query/q/pattern: is not a valid pattern: position 1: bad repetition operator **
      #|a.json: /stubs/0/request/headers/X-A~1B: is not a valid header name
      #|a.json: /stubs/0/request/body/pattern: is not a valid pattern: position 1: invalid repetition size {1001}
      #|a.json: /stubs/1/request/path/pattern: is not a valid pattern: position 6: non-ASCII capture group name (?P<é> is not supported in smock's RE2 subset
      #|a.json: /stubs/2/request/query/~0q/pattern: is not a valid pattern: position 0: unexpected )
    ),
  )
}

///|
test "a pattern with syntax outside smock's RE2 subset, or that is not RE2 syntax, is rejected the same way" {
  let stub = (i : Int, pattern : String) => {
    stub_with(
      "s\{i}",
      "\"request\": { \"path\": { \"pattern\": \{pattern.escape()} } }",
    )
  }
  inspect(
    stub_problems(
      [
        "/\\p{Greek}+", "/\\pL", "/[[:alpha:]]", "/(?U)a*", "/\\x41", "/(?=a)", "/(a)\\1",
      ].mapi(stub),
    ),
    content=(
      #|a.json: /stubs/0/request/path/pattern: is not a valid pattern: position 1: Unicode class \p{Greek} is not supported in smock's RE2 subset
      #|a.json: /stubs/1/request/path/pattern: is not a valid pattern: position 1: Unicode class \pL is not supported in smock's RE2 subset
      #|a.json: /stubs/2/request/path/pattern: is not a valid pattern: position 2: POSIX class [:alpha:] is not supported in smock's RE2 subset
      #|a.json: /stubs/3/request/path/pattern: is not a valid pattern: position 3: flag U is not supported in smock's RE2 subset
      #|a.json: /stubs/4/request/path/pattern: is not a valid pattern: position 1: hexadecimal escape \x is not supported in smock's RE2 subset
      #|a.json: /stubs/5/request/path/pattern: is not a valid pattern: position 1: lookahead (?= is not RE2 syntax
      #|a.json: /stubs/6/request/path/pattern: is not a valid pattern: position 4: backreference \1 is not RE2 syntax
    ),
  )
}

///|
test "a pattern object in a json condition that does not compile is a diagnostic at the JSON Pointer of its pattern field, each one reported" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "body": { "json": {
          #|  "email": { "pattern": "([a-z]+@example\\.com" },
          #|  "tags": ["ok", { "pattern": "x{1001}" }, { "pattern": "[a-z]+" }],
          #|  "a/b": { "c~d": { "pattern": "\\p{Greek}" } } } } }
        ),
      ),
      stub_with(
        "b", "\"request\": { \"body\": { \"json\": { \"pattern\": \"(?=a)\" } } }",
      ),
      stub_with(
        "c",
        (
          #|"request": { "body": { "json": {
          #|  "a": { "pattern": ")", "flags": "i" }, "b": { "pattern": 1 } } } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/json/email/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/0/request/body/json/tags/1/pattern: is not a valid pattern: position 1: invalid repetition size {1001}
      #|a.json: /stubs/0/request/body/json/a~1b/c~0d/pattern: is not a valid pattern: position 0: Unicode class \p{Greek} is not supported in smock's RE2 subset
      #|a.json: /stubs/1/request/body/json/pattern: is not a valid pattern: position 0: lookahead (?= is not RE2 syntax
    ),
  )
}

///|
test "the snapshot holds each pattern compiled when the set is loaded, ready to match" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [{ "id": "a", "mock": "m",
    #|    "request": { "path": { "pattern": "/users/[0-9]+" },
    #|      "query": { "q": { "pattern": "a|b" } }, "headers": { "X-A": { "pattern": "1+" } },
    #|      "body": { "pattern": "(?s).*" } },
    #|    "response": { "status": 200 } }] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  guard snapshot.mocks[0].stubs[0].serves is Ordinary({ request, .. }) else {
    fail("not an ordinary Stub")
  }
  debug_inspect(
    request,
    content=(
      #|{
      #|  meth: None,
      #|  path: Some(Has(Pattern(Pattern("/users/[0-9]+")))),
      #|  query: <ReadOnlyArray: [("q", Has(Pattern(Pattern("a|b"))))]>,
      #|  headers: <ReadOnlyArray: [("x-a", Has(Pattern(Pattern("1+"))))]>,
      #|  cookies: <ReadOnlyArray: []>,
      #|  body: Some(Pattern(Pattern("(?s).*"))),
      #|}
    ),
  )
  guard request.path is Some(Has(Pattern(path))) else {
    fail("no path pattern")
  }
  debug_inspect(
    [
      path.matches(b"/users/42"),
      path.matches(b"/users/42/orders"),
      path.matches(b"/users/x"),
    ],
    content="[true, false, false]",
  )
}

///|
test "a priority is an integer from -2147483648 to 2147483647" {
  inspect(
    stub_problems([
      stub_with("a", "\"priority\": -2147483648"),
      stub_with("b", "\"priority\": 2147483647"),
      stub_with("c", "\"priority\": 0"),
      stub_with("d", "\"priority\": 7.0"),
      stub_with("e", "\"priority\": 1.5"),
      stub_with("f", "\"priority\": \"1\""),
      stub_with("g", "\"priority\": 2147483648"),
      stub_with("h", "\"priority\": -2147483649"),
      stub_with("i", "\"priority\": null"),
    ]),
    content=(
      #|a.json: /stubs/4/priority: must be an integer from -2147483648 to 2147483647
      #|a.json: /stubs/5/priority: must be an integer from -2147483648 to 2147483647
      #|a.json: /stubs/6/priority: must be an integer from -2147483648 to 2147483647
      #|a.json: /stubs/7/priority: must be an integer from -2147483648 to 2147483647
      #|a.json: /stubs/8/priority: must be an integer from -2147483648 to 2147483647
    ),
  )
}

///|
test "a Scenario clause names its Scenario and gives requires, moveTo or both, each any non-empty text" {
  inspect(
    stub_problems([
      stub_with(
        "requires", "\"scenario\": { \"name\": \"checkout\", \"requires\": \"Paid\" }",
      ),
      stub_with(
        "move-to", "\"scenario\": { \"name\": \"checkout\", \"moveTo\": \"Paid\" }",
      ),
      stub_with(
        "both", "\"scenario\": { \"name\": \"checkout\", \"requires\": \"Started\", \"moveTo\": \"Paid\" }",
      ),
      stub_with(
        "back", "\"scenario\": { \"name\": \"checkout\", \"requires\": \"Paid\", \"moveTo\": \"Started\" }",
      ),
      stub_with(
        "any-text", "\"scenario\": { \"name\": \"支払い ✓\", \"requires\": \" \", \"moveTo\": \"済み/π\" }",
      ),
    ]),
    content="valid",
  )
}

///|
test "a malformed Scenario clause is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with("a", "\"scenario\": \"checkout\""),
      stub_with("b", "\"scenario\": { \"requires\": \"Paid\" }"),
      stub_with("c", "\"scenario\": { \"name\": \"\", \"moveTo\": \"Paid\" }"),
      stub_with("d", "\"scenario\": { \"name\": \"checkout\" }"),
      stub_with(
        "e", "\"scenario\": { \"name\": \"checkout\", \"moveTo\": \"Paid\", \"state\": \"Paid\" }",
      ),
      stub_with(
        "f", "\"scenario\": { \"name\": \"checkout\", \"requires\": 1, \"moveTo\": null }",
      ),
      stub_with(
        "g", "\"scenario\": { \"name\": \"checkout\", \"requires\": \"\" }",
      ),
      stub_with(
        "h", "\"scenario\": [{ \"name\": \"checkout\", \"moveTo\": \"Paid\" }]",
      ),
      stub_with("i", "\"scenario\": {}"),
    ]),
    content=(
      #|a.json: /stubs/0/scenario: must be an object
      #|a.json: /stubs/1/scenario: needs "name"
      #|a.json: /stubs/2/scenario/name: must be a non-empty string
      #|a.json: /stubs/3/scenario: must give requires, moveTo or both
      #|a.json: /stubs/4/scenario/state: is not a known field
      #|a.json: /stubs/5/scenario/requires: must be a non-empty string
      #|a.json: /stubs/5/scenario/moveTo: must be a non-empty string
      #|a.json: /stubs/6/scenario/requires: must be a non-empty string
      #|a.json: /stubs/7/scenario: must be an object
      #|a.json: /stubs/8/scenario: needs "name"
      #|a.json: /stubs/8/scenario: must give requires, moveTo or both
    ),
  )
}

///|
test "the snapshot holds each Stub's Scenario clause, and each Mock's Scenarios with the states its Stubs name" {
  let file =
    #|{ "mocks": [{ "name": "payments" }, { "name": "users" }, { "name": "plain" }],
    #|  "stubs": [
    #|    { "id": "pending", "mock": "payments", "request": { "path": "/orders/42" },
    #|      "scenario": { "name": "checkout", "requires": "Started" },
    #|      "response": { "status": 200 } },
    #|    { "id": "pay", "mock": "payments", "request": { "path": "/orders/42/pay" },
    #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
    #|      "response": { "status": 200 } },
    #|    { "id": "refund", "mock": "payments",
    #|      "scenario": { "name": "checkout", "moveTo": "Refunded" },
    #|      "response": { "status": 200 } },
    #|    { "id": "audit", "mock": "payments",
    #|      "scenario": { "name": "audit", "requires": "Open" },
    #|      "response": { "status": 200 } },
    #|    { "id": "health", "mock": "payments", "response": { "status": 200 } },
    #|    { "id": "login", "mock": "users",
    #|      "scenario": { "name": "checkout", "moveTo": "In" },
    #|      "response": { "status": 200 } },
    #|    { "id": "plain", "mock": "plain", "response": { "status": 200 } } ] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let out = []
  let state = (state : String?) => state.unwrap_or("-")
  for mock in snapshot.mocks {
    out.push("\{mock.name}: has Scenario Stubs: \{mock.has_scenarios()}")
    for scenario in mock.scenarios {
      out.push(
        "  Scenario \{scenario.name}: \{scenario.states.iter().collect().join(", ")}",
      )
    }
    for stub in mock.stubs {
      guard stub.serves is Ordinary(ordinary) else {
        fail("\{stub.id} is not an ordinary Stub")
      }
      let clause = match ordinary.scenario {
        Some(c) =>
          "\{c.name}, requires \{state(c.requires)}, moveTo \{state(c.move_to)}"
        None => "no clause"
      }
      out.push("  Stub \{stub.id}: \{clause}")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|payments: has Scenario Stubs: true
      #|  Scenario audit: Started, Open
      #|  Scenario checkout: Started, Paid, Refunded
      #|  Stub pending: checkout, requires Started, moveTo -
      #|  Stub pay: checkout, requires Started, moveTo Paid
      #|  Stub refund: checkout, requires -, moveTo Refunded
      #|  Stub audit: audit, requires Open, moveTo -
      #|  Stub health: no clause
      #|users: has Scenario Stubs: true
      #|  Scenario checkout: Started, In
      #|  Stub login: checkout, requires -, moveTo In
      #|plain: has Scenario Stubs: false
      #|  Stub plain: no clause
    ),
  )
}

///|
test "a Mock's noMatch is an object with a status from 200 to 599" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "noMatch": { "status": 200 } },
          #|  { "name": "b", "noMatch": { "status": 599.0 } },
          #|  { "name": "c", "noMatch": {} },
          #|  { "name": "d", "noMatch": 404 },
          #|  { "name": "e", "noMatch": { "status": 199 } },
          #|  { "name": "f", "noMatch": { "status": "418" } },
          #|  { "name": "g", "noMatch": { "status": 418, "body": "x" } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/3/noMatch: must be an object
      #|a.json: /mocks/4/noMatch/status: must be an integer from 200 to 599
      #|a.json: /mocks/5/noMatch/status: must be an integer from 200 to 599
      #|a.json: /mocks/6/noMatch/body: is not a known field
    ),
  )
}

///|
test "a Mock's noMatch.headers follow the rules of a Stub's response headers, and Content-Type and Smock-Near-Miss are set by smock too" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "noMatch": { "status": 404, "headers": {
          #|    "Access-Control-Allow-Origin": "*", "Vary": ["Origin", "Accept"],
          #|    "X-Path": "${request.path}", "Smock-Other": "1" } } },
          #|  { "name": "b", "noMatch": { "headers": ["X-A: 1"] } },
          #|  { "name": "c", "noMatch": { "headers": {
          #|    "Content-Type": "text/plain", "smock-near-miss": "x", "Smock-Mock": "y",
          #|    "Content-Length": "1", "Transfer-Encoding": "chunked", "Connection": "close" } } },
          #|  { "name": "d", "noMatch": { "headers": { "X-A": "1", "x-a": ["2"] } } },
          #|  { "name": "e", "noMatch": { "headers": {
          #|    "Vary": [], "X-B": 1, "X-C": ["a\r\nb", 2], "X D": "1" } } },
          #|  { "name": "f", "noMatch": { "headers": { "CONTENT-TYPE": ["application/json"] } } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/1/noMatch/headers: must be an object
      #|a.json: /mocks/2/noMatch/headers/Content-Type: is set by smock and cannot be given
      #|a.json: /mocks/2/noMatch/headers/smock-near-miss: is set by smock and cannot be given
      #|a.json: /mocks/2/noMatch/headers/Smock-Mock: is set by smock and cannot be given
      #|a.json: /mocks/2/noMatch/headers/Content-Length: is set by smock and cannot be given
      #|a.json: /mocks/2/noMatch/headers/Transfer-Encoding: is set by smock and cannot be given
      #|a.json: /mocks/2/noMatch/headers/Connection: is set by smock and cannot be given
      #|a.json: /mocks/3/noMatch/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
      #|a.json: /mocks/4/noMatch/headers/Vary: must not be an empty array
      #|a.json: /mocks/4/noMatch/headers/X-B: must be a string or an array of strings
      #|a.json: /mocks/4/noMatch/headers/X-C/0: must not contain control characters other than tab
      #|a.json: /mocks/4/noMatch/headers/X-C/1: must be a string
      #|a.json: /mocks/4/noMatch/headers/X D: is not a valid header name
      #|a.json: /mocks/5/noMatch/headers/CONTENT-TYPE: is set by smock and cannot be given
    ),
  )
}

///|
test "a body file is named by a path relative to the body-file subdirectory, and must exist there" {
  let response = (i : Int, body_file : String) => {
    "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"response\": { \"status\": 200, \"bodyFile\": \{body_file.escape()} } }"
  }
  inspect(
    stub_problems(
      ["users/1.json", "logo.png", "users/2.json", "users", "Users/1.json"].mapi(
        response,
      ),
      body_files=[("users/1.json", b"{}"), ("logo.png", b"\x89PNG")],
    ),
    content=(
      #|a.json: /stubs/2/response/bodyFile: no body file "users/2.json" in the body-file subdirectory
      #|a.json: /stubs/3/response/bodyFile: no body file "users" in the body-file subdirectory
      #|a.json: /stubs/4/response/bodyFile: no body file "Users/1.json" in the body-file subdirectory
    ),
  )
}

///|
test "a body-file path that would leave the body-file subdirectory is a diagnostic, even when such a file is given" {
  let response = (i : Int, body_file : Json) => {
    "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"response\": { \"status\": 200, \"bodyFile\": \{body_file.stringify()} } }"
  }
  let paths : Array[Json] = [
    "../x.json", "/etc/passwd", "users/../../x.json", "./x.json", "users//1.json",
    "users/", "", ".hidden", "users/.x.json", 7,
  ]
  inspect(
    stub_problems(paths.mapi(response), body_files=[
      ("../x.json", b"outside"),
      ("/etc/passwd", b"outside"),
      (".hidden", b"hidden"),
    ]),
    content=(
      #|a.json: /stubs/0/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/1/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/2/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/3/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/4/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/5/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/6/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/7/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/8/response/bodyFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.json: /stubs/9/response/bodyFile: must be a string
    ),
  )
}

///|
test "a response gives at most one of body, bodyFile, json and events" {
  let response = (i : Int, fields : String) => {
    "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"response\": { \"status\": 200, \{fields} } }"
  }
  inspect(
    stub_problems(
      [
        "\"body\": \"x\", \"bodyFile\": \"x.json\"", "\"bodyFile\": \"x.json\", \"events\": [{ \"data\": \"x\" }]",
        "\"body\": \"x\", \"events\": [{ \"data\": \"x\" }]", "\"json\": {}, \"body\": \"x\"",
        "\"bodyFile\": \"x.json\", \"json\": null", "\"events\": [], \"json\": [1]",
      ].mapi(response),
      body_files=[("x.json", b"x")],
    ),
    content=(
      #|a.json: /stubs/0/response: has "body" and "bodyFile"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/1/response: has "bodyFile" and "events"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/2/response: has "body" and "events"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/3/response: has "body" and "json"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/4/response: has "bodyFile" and "json"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/5/response: has "json" and "events"; give at most one of "body", "bodyFile", "json", "events" and "llm"
    ),
  )
}

///|
test "the snapshot holds a Stub's response as its only response, of weight 1, whether static or templated" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "static", "mock": "m", "response": { "status": 204 } },
    #|    { "id": "templated", "mock": "m",
    #|      "response": { "status": 201, "template": true, "body": "${method}" } } ] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let out = []
  for stub in snapshot.mocks[0].stubs {
    guard stub.serves is Ordinary(ordinary) else {
      fail("\{stub.id} is not an ordinary Stub")
    }
    for i, weighted in ordinary.responses {
      let response = weighted.response
      out.push(
        "\{stub.id} \{i}: weight \{weighted.weight}, status \{response.status}, template \{response.body is Template(_)}",
      )
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|static 0: weight 1, status 204, template false
      #|templated 0: weight 1, status 201, template true
    ),
  )
}

///|
test "the snapshot holds a Stub's responses in the order written, each with its weight, 1 by default" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "weighted", "mock": "m",
    #|      "responses": [
    #|        { "weight": 9, "status": 200, "json": { "price": 101 } },
    #|        { "status": 503, "headers": { "Retry-After": "5" } },
    #|        { "weight": 1000000, "status": 201, "template": true,
    #|          "bodyFile": "t.txt" } ] },
    #|    { "id": "one", "mock": "m", "responses": [{ "status": 204 }] } ] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [("t.txt", b"${method}")],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let out = []
  for stub in snapshot.mocks[0].stubs {
    guard stub.serves is Ordinary(ordinary) else {
      fail("\{stub.id} is not an ordinary Stub")
    }
    for i, weighted in ordinary.responses {
      let response = weighted.response
      out.push(
        "\{stub.id} \{i}: weight \{weighted.weight}, status \{response.status}, headers \{response.headers.length()}, template \{response.body is Template(_)}",
      )
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|weighted 0: weight 9, status 200, headers 1, template false
      #|weighted 1: weight 1, status 503, headers 1, template false
      #|weighted 2: weight 1000000, status 201, headers 0, template true
      #|one 0: weight 1, status 204, headers 0, template false
    ),
  )
}

///|
test "the snapshot holds what a response sends as one kind, and its header values apart from it, as written or as templates" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "s", "mock": "m",
    #|      "responses": [
    #|        { "status": 204 },
    #|        { "status": 200, "headers": { "X-A": ["1", "2"] }, "body": "a" },
    #|        { "status": 200, "bodyFile": "t.txt" },
    #|        { "status": 200, "json": { "a": 1 } },
    #|        { "status": 200, "headers": { "X-A": "1" },
    #|          "events": [{ "data": "a" }, { "json": [1] }] },
    #|        { "status": 200, "template": true, "headers": { "X-A": "${method}" },
    #|          "body": "${path}" },
    #|        { "status": 200, "template": true, "bodyFile": "t.txt" },
    #|        { "status": 200, "template": true, "json": { "a": "${method}" } },
    #|        { "status": 200, "template": true,
    #|          "events": [{ "data": "${method}" }, { "json": ["${path}"] }] },
    #|        { "status": 200, "template": false, "body": "${path}" },
    #|        { "status": 200, "headers": { "X-A": "1" },
    #|          "llm": { "api": "openai-chat", "text": "${path}" } },
    #|        { "status": 200, "template": true, "headers": { "X-A": "${method}" },
    #|          "llm": { "api": "openai-chat" } } ] } ] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [("t.txt", b"${method}")],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  guard snapshot.mocks[0].stubs[0].serves is Ordinary(ordinary) else {
    fail("not an ordinary Stub")
  }
  let out = []
  for i, weighted in ordinary.responses {
    let response = weighted.response
    let headers = match response.headers {
      Written(fields) =>
        "headers as written: [\{fields.iter().map(f => "\{f.0}: \{f.1}").collect().join(", ")}]"
      Templated(fields) =>
        "headers as templates: [\{fields.iter().map(f => f.0).collect().join(", ")}]"
    }
    let body = match response.body {
      Bytes(bytes) => "bytes [\{@utf8.decode_lossy(bytes)}]"
      Events(events) => "\{events.length()} events"
      Template(Text(_)) => "a text template"
      Template(Json(_)) => "a JSON template"
      Template(Events(events)) => "\{events.length()} event templates"
      Llm(reply) =>
        "an LLM reply for \{reply.declaration.api.name()}, text [\{reply.strings.text}]"
    }
    out.push("\{i}: \{body}; \{headers}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|0: bytes []; headers as written: []
      #|1: bytes [a]; headers as written: [X-A: 1, X-A: 2]
      #|2: bytes [${method}]; headers as written: []
      #|3: bytes [{"a":1}]; headers as written: [Content-Type: application/json]
      #|4: 2 events; headers as written: [X-A: 1]
      #|5: a text template; headers as templates: [X-A]
      #|6: a text template; headers as templates: []
      #|7: a JSON template; headers as templates: [Content-Type]
      #|8: 2 event templates; headers as templates: []
      #|9: bytes [${path}]; headers as written: []
      #|10: an LLM reply for openai-chat, text [${path}]; headers as written: [X-A: 1]
      #|11: an LLM reply for openai-chat, text []; headers as templates: [X-A]
    ),
  )
}

///|
test "a Stub gives exactly one of response and responses, 1 to 100 responses, each weight an integer from 1 to 1,000,000" {
  let stub = (i : Int, fields : String) => {
    "{ \"id\": \"s\{i}\", \"mock\": \"m\", \{fields} }"
  }
  let many = (n : Int) => {
    "\"responses\": [\{Array::make(n, "{ \"status\": 200 }").join(", ")}]"
  }
  inspect(
    stub_problems(
      [
        "\"response\": { \"status\": 200 }, \"responses\": [{ \"status\": 200 }]",
        "\"request\": { \"path\": \"/a\" }",
        "\"responses\": []",
        many(101),
        many(100),
        (
          #|"responses": [{ "weight": 0, "status": 200 }, { "weight": 1000001, "status": 200 },
          #|  { "weight": 1.5, "status": 200 }, { "weight": "2", "status": 200 },
          #|  { "weight": null, "status": 200 }, { "weight": 1000000.0, "status": 200 }]
        ),
        "\"responses\": { \"status\": 200 }",
        (
          #|"responses": [200, { "weight": 2 }, { "status": 200, "wieght": 2 },
          #|  { "status": 200, "body": "x", "json": {} }]
        ),
      ].mapi(stub),
    ),
    content=(
      #|a.json: /stubs/0: has "response" and "responses"; give exactly one of them
      #|a.json: /stubs/1: needs "response", "responses" or "crud"
      #|a.json: /stubs/2/responses: must hold 1 to 100 responses
      #|a.json: /stubs/3/responses: must hold 1 to 100 responses
      #|a.json: /stubs/5/responses/0/weight: must be an integer from 1 to 1000000
      #|a.json: /stubs/5/responses/1/weight: must be an integer from 1 to 1000000
      #|a.json: /stubs/5/responses/2/weight: must be an integer from 1 to 1000000
      #|a.json: /stubs/5/responses/3/weight: must be an integer from 1 to 1000000
      #|a.json: /stubs/5/responses/4/weight: must be an integer from 1 to 1000000
      #|a.json: /stubs/6/responses: must be an array
      #|a.json: /stubs/7/responses/0: must be an object
      #|a.json: /stubs/7/responses/1: needs "status"
      #|a.json: /stubs/7/responses/2/wieght: is not a known field
      #|a.json: /stubs/7/responses/3: has "body" and "json"; give at most one of "body", "bodyFile", "json", "events" and "llm"
    ),
  )
}

///|
test "a template error inside one of responses points at it, counted from 0, and a body file in it is read as in response" {
  inspect(
    stub_problems(
      [
        (
          #|{ "id": "t", "mock": "m",
          #|  "responses": [
          #|    { "status": 200, "template": true, "body": "${method}" },
          #|    { "status": 200, "template": true, "body": "${nope}",
          #|      "headers": { "X-A": "${" } },
          #|    { "status": 200, "template": true, "bodyFile": "t.txt" },
          #|    { "status": 200, "bodyFile": "missing.txt" } ] }
        ),
      ],
      body_files=[("t.txt", b"${method")],
    ),
    content=(
      #|a.json: /stubs/0/responses/1/headers/X-A: template: column 1: the ${ is not closed
      #|a.json: /stubs/0/responses/1/body: template: column 3: unknown name "nope": not a request field, a loop variable or a helper
      #|a.json: /stubs/0/responses/2/bodyFile: template: column 1: the ${ is not closed
      #|a.json: /stubs/0/responses/3/bodyFile: no body file "missing.txt" in the body-file subdirectory
    ),
  )
}

///|
/// A Stub of Mock `m` whose response streams `events`, given as JSON.
fn events_stub(i : Int, events : String) -> String {
  "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"response\": { \"status\": 200, \"events\": \{events} } }"
}

///|
test "events are read as the Schema defines them: data, and optionally a delay in milliseconds, a type and an ID" {
  inspect(
    stub_problems(
      [
        "[]",
        "[{ \"data\": \"\" }]",
        (
          #|[{ "data": "first" },
          #|  { "delay": 250, "event": "update", "id": "2", "data": "line 1\nline 2" },
          #|  { "delay": 0, "event": "", "id": "", "data": "a\r\n\u0000b" },
          #|  { "delay": 2147483647, "event": " x\t", "id": "é", "data": "x" },
          #|  { "delay": 7.0, "data": "x" }]
        ),
      ].mapi(events_stub),
    ),
    content="valid",
  )
}

///|
test "a malformed event is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems(
      [
        "{ \"data\": \"x\" }",
        "[\"data: x\", null]",
        "[{ \"event\": \"ping\" }, { \"data\": 1 }, { \"data\": null }]",
        (
          #|[{ "delay": -1, "data": "x" }, { "delay": 1.5, "data": "x" },
          #|  { "delay": 2147483648, "data": "x" }, { "delay": "100", "data": "x" }]
        ),
        (
          #|[{ "event": "a\nb", "data": "x" }, { "event": "a\rb", "data": "x" },
          #|  { "event": 1, "data": "x" }]
        ),
        (
          #|[{ "id": "a\nb", "data": "x" }, { "id": "a\rb", "data": "x" },
          #|  { "id": "a\u0000b", "data": "x" }, { "id": 2, "data": "x" }]
        ),
        "[{ \"data\": \"x\", \"retry\": 1000 }]",
        "[{ \"data\": \"x\", \"json\": { \"x\": 1 } }, { \"json\": null }]",
      ].mapi(events_stub),
    ),
    content=(
      #|a.json: /stubs/0/response/events: must be an array
      #|a.json: /stubs/1/response/events/0: must be an object
      #|a.json: /stubs/1/response/events/1: must be an object
      #|a.json: /stubs/2/response/events/0: needs "data" or "json"
      #|a.json: /stubs/2/response/events/1/data: must be a string
      #|a.json: /stubs/2/response/events/2/data: must be a string
      #|a.json: /stubs/3/response/events/0/delay: must be an integer from 0 to 2147483647
      #|a.json: /stubs/3/response/events/1/delay: must be an integer from 0 to 2147483647
      #|a.json: /stubs/3/response/events/2/delay: must be an integer from 0 to 2147483647
      #|a.json: /stubs/3/response/events/3/delay: must be an integer from 0 to 2147483647
      #|a.json: /stubs/4/response/events/0/event: must be one line
      #|a.json: /stubs/4/response/events/1/event: must be one line
      #|a.json: /stubs/4/response/events/2/event: must be a string
      #|a.json: /stubs/5/response/events/0/id: must be one line without NUL characters
      #|a.json: /stubs/5/response/events/1/id: must be one line without NUL characters
      #|a.json: /stubs/5/response/events/2/id: must be one line without NUL characters
      #|a.json: /stubs/5/response/events/3/id: must be a string
      #|a.json: /stubs/6/response/events/0/retry: is not a known field
      #|a.json: /stubs/7/response/events/0: has "data" and "json"; give exactly one of them
    ),
  )
}
