// Validation of the Stub and Mock fields that decide matching and static
// responses: request conditions, priority, noMatch and body files.

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
      #|a.json: /stubs/3/request/body: needs "json" or "pattern"
      #|a.json: /stubs/4/request/body: needs "json" or "pattern", not both
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
      #|a.json: /stubs/1/request/path/pattern: is not a valid pattern: position 6: non-ASCII capture group name (?P<é> is not supported in R1
      #|a.json: /stubs/2/request/query/~0q/pattern: is not a valid pattern: position 0: unexpected )
    ),
  )
}

///|
test "a pattern with syntax outside the R1 subset, or that is not RE2 syntax, is rejected the same way" {
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
      #|a.json: /stubs/0/request/path/pattern: is not a valid pattern: position 1: Unicode class \p{Greek} is not supported in R1
      #|a.json: /stubs/1/request/path/pattern: is not a valid pattern: position 1: Unicode class \pL is not supported in R1
      #|a.json: /stubs/2/request/path/pattern: is not a valid pattern: position 2: POSIX class [:alpha:] is not supported in R1
      #|a.json: /stubs/3/request/path/pattern: is not a valid pattern: position 3: flag U is not supported in R1
      #|a.json: /stubs/4/request/path/pattern: is not a valid pattern: position 1: hexadecimal escape \x is not supported in R1
      #|a.json: /stubs/5/request/path/pattern: is not a valid pattern: position 1: lookahead (?= is not RE2 syntax
      #|a.json: /stubs/6/request/path/pattern: is not a valid pattern: position 4: backreference \1 is not RE2 syntax
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
  let request = snapshot.mocks[0].stubs[0].request
  debug_inspect(
    request,
    content=(
      #|{
      #|  meth: None,
      #|  path: Some(Pattern(Pattern("/users/[0-9]+"))),
      #|  query: <ReadOnlyArray: [("q", Pattern(Pattern("a|b")))]>,
      #|  headers: <ReadOnlyArray: [("x-a", Pattern(Pattern("1+")))]>,
      #|  body: Some(Pattern(Pattern("(?s).*"))),
      #|}
    ),
  )
  guard request.path is Some(Pattern(path)) else { fail("no path pattern") }
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
test "a response gives at most one of body, bodyFile and events" {
  let response = (i : Int, fields : String) => {
    "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"response\": { \"status\": 200, \{fields} } }"
  }
  inspect(
    stub_problems(
      [
        "\"body\": \"x\", \"bodyFile\": \"x.json\"", "\"bodyFile\": \"x.json\", \"events\": [{ \"data\": \"x\" }]",
        "\"body\": \"x\", \"events\": [{ \"data\": \"x\" }]",
      ].mapi(response),
      body_files=[("x.json", b"x")],
    ),
    content=(
      #|a.json: /stubs/0/response: has "body" and "bodyFile"; give at most one of "body", "bodyFile" and "events"
      #|a.json: /stubs/1/response: has "bodyFile" and "events"; give at most one of "body", "bodyFile" and "events"
      #|a.json: /stubs/2/response: has "body" and "events"; give at most one of "body", "bodyFile" and "events"
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
      ].mapi(events_stub),
    ),
    content=(
      #|a.json: /stubs/0/response/events: must be an array
      #|a.json: /stubs/1/response/events/0: must be an object
      #|a.json: /stubs/1/response/events/1: must be an object
      #|a.json: /stubs/2/response/events/0: needs "data"
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
    ),
  )
}
