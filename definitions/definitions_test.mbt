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
      ("users.json", "{ \"mocks\": [{ \"name\": \"users\" }] }"),
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
      #|d.json: /stubs/1/request/method: must be an HTTP token, such as GET
      #|d.json: /stubs/1/request/path: must be a string
      #|d.json: /stubs/1/response/status: must be an integer from 200 to 599
      #|d.json: /stubs/1/response/body: must be a string
      #|d.json: /stubs/1: needs "id"
      #|d.json: /stubs/2/request: must be an object
      #|d.json: /stubs/2: needs "response"
      #|d.json: /stubs/3/response/status: must be an integer from 200 to 599
      #|d.json: /stubs/3/response/headers: must be an object
      #|d.json: /stubs/4/response/headers/a~1b: is not a valid header name
      #|d.json: /stubs/4/response/headers/~0x y: is not a valid header name
      #|d.json: /stubs/4/response/headers/X-Ok: must be a string
      #|d.json: /stubs/4/response/headers/X-Bad: must not contain control characters other than tab
      #|d.json: /stubs/4/response/headers/Content-Length: is set by smock and cannot be given
      #|d.json: /stubs/4/response/headers/transfer-encoding: is set by smock and cannot be given
      #|d.json: /stubs/4/response/headers/Connection: is set by smock and cannot be given
      #|d.json: /stubs/4/response: needs "status"
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

///|
test "a file without version is read as version 1, and version 1 is accepted" {
  inspect(
    problems([
      ("a.json", "{ \"mocks\": [{ \"name\": \"m\" }] }"),
      ("b.json", "{ \"version\": 1 }"),
      ("c.json", "{ \"version\": 1.0 }"),
    ]),
    content="valid",
  )
}

///|
test "any version other than 1 is rejected, including a higher number and latest" {
  inspect(
    problems([
      ("a.json", "{ \"version\": 2 }"),
      ("b.json", "{ \"version\": \"latest\" }"),
      ("c.json", "{ \"version\": \"1\" }"),
      ("d.json", "{ \"version\": 0 }"),
      ("e.json", "{ \"version\": 1.5 }"),
      ("f.json", "{ \"version\": null }"),
    ]),
    content=(
      #|a.json: /version: must be 1, the only format version
      #|b.json: /version: must be 1, the only format version
      #|c.json: /version: must be 1, the only format version
      #|d.json: /version: must be 1, the only format version
      #|e.json: /version: must be 1, the only format version
      #|f.json: /version: must be 1, the only format version
    ),
  )
}

///|
test "a field the Schema does not define is rejected wherever it appears" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mock": [], "mocks": [{ "name": "m", "nmae": "n" }],
          #|  "stubs": [{ "id": "a", "mock": "m", "requst": {},
          #|    "request": { "methd": "GET", "path": "/a" },
          #|    "response": { "status": 200, "boddy": "x", "a/b~c": 1 } }] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mock: is not a known field
      #|a.json: /mocks/0/nmae: is not a known field
      #|a.json: /stubs/0/requst: is not a known field
      #|a.json: /stubs/0/request/methd: is not a known field
      #|a.json: /stubs/0/response/boddy: is not a known field
      #|a.json: /stubs/0/response/a~1b~0c: is not a known field
    ),
  )
}

///|
test "a field the Schema defines but smock does not implement yet is rejected as not supported yet" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m", "hosts": ["m.example"], "default": true,
          #|    "noMatch": { "status": 418 }, "journal": false }],
          #|  "stubs": [{ "id": "a", "mock": "m", "priority": 1,
          #|    "request": { "method": "GET", "path": { "pattern": "/a.*" },
          #|      "query": { "q": "1" }, "headers": { "X-A": "1" },
          #|      "body": { "json": {} } },
          #|    "response": { "status": 200, "bodyFile": "a.json",
          #|      "template": true, "events": [{ "data": "x" }] },
          #|    "fault": { "seed": 1 } }] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/0/hosts: is not supported yet
      #|a.json: /mocks/0/default: is not supported yet
      #|a.json: /mocks/0/noMatch: is not supported yet
      #|a.json: /mocks/0/journal: is not supported yet
      #|a.json: /stubs/0/priority: is not supported yet
      #|a.json: /stubs/0/request/path: pattern conditions are not supported yet
      #|a.json: /stubs/0/request/query: is not supported yet
      #|a.json: /stubs/0/request/headers: is not supported yet
      #|a.json: /stubs/0/request/body: is not supported yet
      #|a.json: /stubs/0/response/bodyFile: is not supported yet
      #|a.json: /stubs/0/response/template: is not supported yet
      #|a.json: /stubs/0/response/events: is not supported yet
      #|a.json: /stubs/0/fault: is not supported yet
    ),
  )
}

///|
test "a method is an HTTP token and an exact path starts with /" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "a", "mock": "m", "request": { "method": "GET /", "path": "users/1" },
          #|      "response": { "status": 200 } },
          #|    { "id": "b", "mock": "m", "request": { "method": "", "path": "" },
          #|      "response": { "status": 200 } },
          #|    { "id": "c", "mock": "m", "request": { "method": "M-SEARCH", "path": "/" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/method: must be an HTTP token, such as GET
      #|a.json: /stubs/0/request/path: must start with /
      #|a.json: /stubs/1/request/method: must be an HTTP token, such as GET
      #|a.json: /stubs/1/request/path: must start with /
    ),
  )
}

///|
test "two Mocks with the same name are rejected at the later one in file-name order, naming the earlier one" {
  inspect(
    problems([
      (
        "b.json", "{ \"mocks\": [{ \"name\": \"users\" }, { \"name\": \"orders\" }] }",
      ),
      ("a.json", "{ \"mocks\": [{ \"name\": \"users\" }] }"),
      (
        "c.json",
        (
          #|{ "mocks": [{ "name": "orders" }, { "name": "users" },
          #|  { "name": "orders", "journal": false }, { "name": "Users" }] }
        ),
      ),
    ]),
    content=(
      #|b.json: /mocks/0/name: the Mock name "users" is already declared at a.json: /mocks/0/name
      #|c.json: /mocks/0/name: the Mock name "orders" is already declared at b.json: /mocks/1/name
      #|c.json: /mocks/1/name: the Mock name "users" is already declared at a.json: /mocks/0/name
      #|c.json: /mocks/2/journal: is not supported yet
      #|c.json: /mocks/2/name: the Mock name "orders" is already declared at b.json: /mocks/1/name
    ),
  )
}

///|
test "two Stubs with the same ID anywhere in the definition set are rejected at the later one, naming the earlier one" {
  let stub = (id : String, mock : String) => {
    "{ \"id\": \"\{id}\", \"mock\": \"\{mock}\", \"response\": { \"status\": 200 } }"
  }
  inspect(
    problems([
      (
        "b.json",
        "{ \"stubs\": [\{stub("get-user", "orders")}, \{stub("list", "users")}] }",
      ),
      (
        "a.json", "{ \"mocks\": [{ \"name\": \"users\" }, { \"name\": \"orders\" }] }",
      ),
      (
        "c.json",
        "{ \"stubs\": [\{stub("list", "orders")}, \{stub("get-user", "users")}] }",
      ),
      ("d.json", "{ \"stubs\": [\{stub("get-user", "users")}] }"),
    ]),
    content=(
      #|c.json: /stubs/0/id: the Stub ID "list" is already used at b.json: /stubs/1/id
      #|c.json: /stubs/1/id: the Stub ID "get-user" is already used at b.json: /stubs/0/id
      #|d.json: /stubs/0/id: the Stub ID "get-user" is already used at b.json: /stubs/0/id
    ),
  )
}

///|
test "a Stub that names a Mock no file declares is rejected; the Mock may be declared in any file" {
  let stub = (id : String, mock : String) => {
    "{ \"id\": \"\{id}\", \"mock\": \"\{mock}\", \"response\": { \"status\": 200 } }"
  }
  inspect(
    problems([
      (
        "a.json",
        "{ \"stubs\": [\{stub("a", "users")}, \{stub("b", "orders")}] }",
      ),
      ("b.json", "{ \"mocks\": [{ \"name\": \"users\" }] }"),
      ("c.json", "{ \"stubs\": [\{stub("c", "Users")}] }"),
    ]),
    content=(
      #|a.json: /stubs/1/mock: no file declares the Mock "orders"
      #|c.json: /stubs/0/mock: no file declares the Mock "Users"
    ),
  )
  // Without any Mock declared, smock serves one empty Mock named default,
  // but no file declares it, so no Stub can name it.
  inspect(
    problems([("a.json", "{ \"stubs\": [\{stub("a", "default")}] }")]),
    content=(
      #|a.json: /stubs/0/mock: no file declares the Mock "default"
    ),
  )
}

///|
test "a problem renders as one line, even when a file name or a field name has a line break" {
  let diagnostics = problems([
    (
      "a\nb.json", "{ \"x\\ny\": 1, \"mocks\": [{ \"name\": \"m\", \"\\u2028\\r\": 1 }] }",
    ),
  ])
  inspect(diagnostics.split("\n").count(), content="2")
  inspect(
    diagnostics,
    content=(
      #|a\nb.json: /x\ny: is not a known field
      #|a\nb.json: /mocks/0/\u{2028}\r: is not a known field
    ),
  )
}
