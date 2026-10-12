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
      #|a.json: /stubs/1/request/query/q: must be a string
      #|a.json: /stubs/1/request/query/r: must be a string
      #|a.json: /stubs/1/request/query/s: must be a string
      #|a.json: /stubs/1/request/headers/X A: is not a valid header name
      #|a.json: /stubs/1/request/headers/X-B: must be a string
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
test "pattern conditions on the query, headers and body are rejected as not supported yet" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "query": { "q": { "pattern": "[0-9]+" } },
          #|  "headers": { "X-A": { "pattern": ".*" } },
          #|  "body": { "pattern": ".*" } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/query/q: pattern conditions are not supported yet
      #|a.json: /stubs/0/request/headers/X-A: pattern conditions are not supported yet
      #|a.json: /stubs/0/request/body: pattern conditions are not supported yet
    ),
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
      #|a.json: /stubs/1/response/events: is not supported yet
      #|a.json: /stubs/1/response: has "bodyFile" and "events"; give at most one of "body", "bodyFile" and "events"
      #|a.json: /stubs/2/response/events: is not supported yet
      #|a.json: /stubs/2/response: has "body" and "events"; give at most one of "body", "bodyFile" and "events"
    ),
  )
}
