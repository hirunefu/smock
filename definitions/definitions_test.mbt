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
test "a YAML file outside the safe subset gets a diagnostic with its file and the JSON Pointer of the offending value" {
  inspect(
    problems([
      (
        "10-users.yaml",
        (
          #|mocks: [{ name: users }]
          #|stubs:
          #|  - { id: a, mock: users, response: { status: 200 } }
          #|  - { id: b, mock: users, response: { status: 200 } }
          #|  - { id: c, mock: users, response: { status: 200 } }
          #|  - id: d
          #|    mock: users
          #|    request:
          #|      path: ~
          #|    response:
          #|      status: 200
        ),
      ),
      ("20-anchors.yml", "mocks:\n  - &users\n    name: users\n"),
      ("30-aliases.yaml", "stubs:\n  - *users\n"),
      ("40-tags.yaml", "mocks: !!seq []\n"),
      ("50-merge.yaml", "mocks:\n  - <<: { name: users }\n"),
      ("60-duplicate.yaml", "mocks:\n  - name: users\n    name: orders\n"),
      ("70-documents.yaml", "mocks: []\n---\nstubs: []\n"),
      ("80-on.yaml", "stubs:\n  - id: x\n    request: { method: on }\n"),
      ("90-syntax.yml", "mocks:\n  - name: \"users\n"),
      ("91-flow.yaml", "mocks: [{ name: users }\n"),
      ("92-tab.yaml", "mocks:\n\t- name: users\n"),
      ("93-empty.yml", ""),
    ]),
    content=(
      #|10-users.yaml: /stubs/3/request/path: "~" may be read as null; quote this value
      #|20-anchors.yml: /mocks/0: anchors (&) are not supported; quote the value if it is text
      #|30-aliases.yaml: /stubs/0: aliases (*) are not supported; quote the value if it is text
      #|40-tags.yaml: /mocks: tags (!) are not supported; quote the value if it is text
      #|50-merge.yaml: /mocks/0/<<: merge keys (<<) are not supported
      #|60-duplicate.yaml: /mocks/0/name: duplicate key
      #|70-documents.yaml: multiple documents are not supported
      #|80-on.yaml: /stubs/0/request/method: "on" may be read as a boolean; quote this value
      #|90-syntax.yml: /mocks/0/name: unterminated double-quoted value
      #|91-flow.yaml: /mocks/0/name: unterminated flow sequence
      #|92-tab.yaml: /mocks: tabs are not allowed in indentation
      #|93-empty.yml: the document is empty
    ),
  )
}

///|
test "a YAML file is validated like the equivalent JSON file" {
  let yaml =
    #|mocks:
    #|  - name: ""
    #|  - 3
    #|stubs:
    #|  - id: 1
    #|    mock: users
    #|    request: { method: 5 }
    #|    response:
    #|      status: 99
    #|      headers: { a/b: "1", Connection: close }
  let json =
    #|{ "mocks": [{ "name": "" }, 3],
    #|  "stubs": [{ "id": 1, "mock": "users", "request": { "method": 5 },
    #|    "response": { "status": 99, "headers": { "a/b": "1", "Connection": "close" } } }] }
  let expected =
    #|users.EXT: /mocks/0/name: must be a non-empty string
    #|users.EXT: /mocks/1: must be an object
    #|users.EXT: /stubs/0/id: must be a non-empty string
    #|users.EXT: /stubs/0/request/method: must be a string
    #|users.EXT: /stubs/0/response/status: must be an integer from 200 to 599
    #|users.EXT: /stubs/0/response/headers/a~1b: is not a valid header name
    #|users.EXT: /stubs/0/response/headers/Connection: is set by smock and cannot be given
  inspect(
    problems([("users.yaml", yaml)]),
    content=expected.replace_all(old=".EXT", new=".yaml"),
  )
  inspect(
    problems([("users.json", json)]),
    content=expected.replace_all(old=".EXT", new=".json"),
  )
}

///|
test "YAML and JSON files are read together, in byte-wise name order" {
  inspect(
    problems([
      ("b.yml", "mocks: [{ name: b }]\nstubs: 7\n"),
      ("a.json", "{ \"stubs\": 7 }"),
      ("B.yaml", "mocks: yes\n"),
    ]),
    content=(
      #|B.yaml: /mocks: "yes" may be read as a boolean; quote this value
      #|a.json: /stubs: must be an array
      #|b.yml: /stubs: must be an array
    ),
  )
}

///|
test "a file that is not UTF-8 gets a diagnostic" {
  let set : @definitions.DefinitionSet = {
    files: [
      ("a.json", b"{\"mocks\": [{\"name\": \"\xff\"}]}"),
      ("b.yaml", b"mocks: [{ name: \xff }]\n"),
    ],
    body_files: [],
  }
  guard @definitions.load(set) is Err(diagnostics) else { fail("valid") }
  inspect(
    diagnostics.map(d => d.to_string()).join("\n"),
    content=(
      #|a.json: not valid UTF-8
      #|b.yaml: not valid UTF-8
    ),
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
