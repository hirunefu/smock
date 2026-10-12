///|
/// Loads Definition files given as (name, text) pairs and renders every
/// diagnostic, one per line, or `valid`.
fn problems(files : Array[(String, String)]) -> String {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "a valid set has no problems" {
  inspect(
    problems([
      (
        "users.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [{ "id": "a", "mock": "users",
          #|    "request": { "method": "GET", "path": "/a" },
          #|    "response": { "status": 200, "headers": { "X-A": "1" }, "body": "a" } }] }
        ),
      ),
    ]),
    content="valid",
  )
}

///|
test "every problem is reported, each with its file and JSON Pointer" {
  inspect(
    problems([
      ("b.json", "{ \"mocks\": [ "),
      ("a.json", "[]"),
      (
        "c.json",
        (
          #|{ "mocks": [{ "name": "" }, 3, {}],
          #|  "stubs": { "id": "x" } }
        ),
      ),
      (
        "d.json",
        (
          #|{ "mocks": "users",
          #|  "stubs": [
          #|    { "id": 1, "mock": "users", "response": { "status": 200 } },
          #|    { "mock": "users", "request": { "method": 5, "path": ["/a"] },
          #|      "response": { "status": 99, "body": 1 } },
          #|    { "id": "c", "mock": "users", "request": "GET /a" },
          #|    { "id": "d", "mock": "users",
          #|      "response": { "status": 200.5, "headers": [] } },
          #|    { "id": "e", "mock": "users", "response": {
          #|      "headers": { "a/b": "1", "~x y": "2", "X-Ok": 3, "X-Bad": "a\r\nSet-Cookie: x",
          #|        "Content-Length": "1", "transfer-encoding": "chunked", "Connection": "close" } } },
          #|    "stub"
          #|  ] }
        ),
      ),
    ]),
    content=(
      #|a.json: must be an object
      #|b.json: not valid JSON: Unexpected end of file
      #|c.json: /mocks/0/name: must be a non-empty string
      #|c.json: /mocks/1: must be an object
      #|c.json: /mocks/2: needs "name"
      #|c.json: /stubs: must be an array
      #|d.json: /mocks: must be an array
      #|d.json: /stubs/0/id: must be a non-empty string
      #|d.json: /stubs/1: needs "id"
      #|d.json: /stubs/1/request/method: must be a string
      #|d.json: /stubs/1/request/path: must be a string
      #|d.json: /stubs/1/response/status: must be an integer from 200 to 599
      #|d.json: /stubs/1/response/body: must be a string
      #|d.json: /stubs/2/request: must be an object
      #|d.json: /stubs/2: needs a response
      #|d.json: /stubs/3/response/status: must be an integer from 200 to 599
      #|d.json: /stubs/3/response/headers: must be an object
      #|d.json: /stubs/4/response: needs a status
      #|d.json: /stubs/4/response/headers/a~1b: is not a valid header name
      #|d.json: /stubs/4/response/headers/~0x y: is not a valid header name
      #|d.json: /stubs/4/response/headers/X-Ok: must be a string
      #|d.json: /stubs/4/response/headers/X-Bad: must not contain control characters other than tab
      #|d.json: /stubs/4/response/headers/Content-Length: is set by smock and cannot be given
      #|d.json: /stubs/4/response/headers/transfer-encoding: is set by smock and cannot be given
      #|d.json: /stubs/4/response/headers/Connection: is set by smock and cannot be given
      #|d.json: /stubs/5: must be an object
    ),
  )
}

///|
test "a YAML Definition file gets a diagnostic saying YAML is not supported yet" {
  inspect(
    problems([("a.yaml", "mocks: []\n"), ("b.yml", "")]),
    content=(
      #|a.yaml: YAML Definition files are not supported yet; write this file as JSON
      #|b.yml: YAML Definition files are not supported yet; write this file as JSON
    ),
  )
}

///|
test "a file that is not UTF-8 gets a diagnostic" {
  let set : @definitions.DefinitionSet = {
    files: [("a.json", b"{\"mocks\": [{\"name\": \"\xff\"}]}")],
    body_files: [],
  }
  guard @definitions.load(set) is Err(diagnostics) else { fail("valid") }
  inspect(
    diagnostics.map(d => d.to_string()).join("\n"),
    content="a.json: not valid UTF-8",
  )
}

///|
test "a diagnostic carries the file, the JSON Pointer and the message" {
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode("{ \"mocks\": [{}] }"))],
    body_files: [],
  }
  guard @definitions.load(set) is Err(diagnostics) else { fail("valid") }
  debug_inspect(
    diagnostics,
    content=(
      #|[{ file: "a.json", pointer: "/mocks/0", message: "needs \"name\"" }]
    ),
  )
}
