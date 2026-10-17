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
      #|d.json: /stubs/1/request/path: must be a string or an object
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
    #|      headers: { a/b: "1", Connection: close, X-A: "1", x-a: "2" }
  let json =
    #|{ "mocks": [{ "name": "" }, 3],
    #|  "stubs": [{ "id": 1, "mock": "users", "request": { "method": 5 },
    #|    "response": { "status": 99,
    #|      "headers": { "a/b": "1", "Connection": "close", "X-A": "1", "x-a": "2" } } }] }
  let expected =
    #|users.EXT: /mocks/0/name: must be a non-empty string
    #|users.EXT: /mocks/1: must be an object
    #|users.EXT: /stubs/0/id: must be a non-empty string
    #|users.EXT: /stubs/0/request/method: must be an HTTP token, such as GET
    #|users.EXT: /stubs/0/response/status: must be an integer from 200 to 599
    #|users.EXT: /stubs/0/response/headers/a~1b: is not a valid header name
    #|users.EXT: /stubs/0/response/headers/Connection: is set by smock and cannot be given
    #|users.EXT: /stubs/0/response/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
    #|users.EXT: /stubs/0/mock: no file declares the Mock "users"
  assert_eq(@yaml.parse(yaml), @json.parse(json))
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
test "a JSON file with a duplicate key is rejected at the later key, as the equivalent YAML file is" {
  inspect(
    problems([
      (
        "10-users.json", "{ \"mocks\": [{ \"name\": \"users\", \"name\": \"orders\" }] }",
      ),
      (
        "20-stubs.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [{ "id": "a", "mock": "m", "response": { "status": 200 } }],
          #|  "stubs": [{ "id": "b", "mock": "m", "response": { "status": 200 } }] }
        ),
      ),
      (
        "30-escaped.json",
        (
          #|{ "mocks": [{ "name": "n" }],
          #|  "stubs": [{ "id": "c", "mock": "n", "response": { "status": 200 },
          #|    "request": { "body": { "json": { "a/b": [{}, { "x": 1, "\u0078": 2 }] } } } }] }
        ),
      ),
      (
        "40-distinct.json",
        (
          #|{ "mocks": [{ "name": "o" }],
          #|  "stubs": [{ "id": "d", "mock": "o", "response": { "status": 200 },
          #|    "request": { "body": { "json": [{ "x": 1 }, { "x": 2, "X": 3, "x ": 4 }] } } }] }
        ),
      ),
    ]),
    content=(
      #|10-users.json: /mocks/0/name: duplicate key
      #|20-stubs.json: /stubs: duplicate key
      #|30-escaped.json: /stubs/0/request/body/json/a~1b/1/x: duplicate key
    ),
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
test "a Stub may use the fields the Schema defines for Mocks, Stubs and responses, template included" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m", "hosts": ["m.example"], "default": true,
          #|    "noMatch": { "status": 418 }, "journal": false }],
          #|  "stubs": [{ "id": "a", "mock": "m", "priority": 1,
          #|    "request": { "method": "GET", "path": "/a" },
          #|    "response": { "status": 200, "template": true } }] }
        ),
      ),
    ]),
    content="valid",
  )
}

///|
test "a Mock's journal is true or false" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "journal": false },
          #|  { "name": "b", "journal": true },
          #|  { "name": "c", "journal": "off" },
          #|  { "name": "d", "journal": null } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/2/journal: must be true or false
      #|a.json: /mocks/3/journal: must be true or false
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
      #|c.json: /mocks/2/name: the Mock name "orders" is already declared at b.json: /mocks/1/name
    ),
  )
}

///|
test "hosts are host names or IP addresses, optionally with a port, and default is true or false" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "hosts": ["users.example.com", "users:8080", "10.0.0.7", "[::1]:8080",
          #|      "fe80::1", "under_score", "USERS.EXAMPLE.COM."], "default": false },
          #|  { "name": "b", "hosts": [], "default": true } ] }
        ),
      ),
    ]),
    content="valid",
  )
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "hosts": "users.example.com" },
          #|  { "name": "b", "hosts": [1, "", "*.example.com", "users.*", "a b", "http://users",
          #|      "users/x", "ユーザー.example", "users\n"] },
          #|  { "name": "c", "default": "true" },
          #|  { "name": "d", "default": 1 },
          #|  { "name": "e", "default": null } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/0/hosts: must be an array
      #|a.json: /mocks/1/hosts/0: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/1: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/2: must be an exact name: Hosts have no wildcards
      #|a.json: /mocks/1/hosts/3: must be an exact name: Hosts have no wildcards
      #|a.json: /mocks/1/hosts/4: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/5: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/6: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/7: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/1/hosts/8: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/2/default: must be true or false
      #|a.json: /mocks/3/default: must be true or false
      #|a.json: /mocks/4/default: must be true or false
    ),
  )
}

///|
test "a Host must be one a request can carry: a port is digits, a bracketed IP literal ends the name, and the name is not empty once normalised" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "hosts": ["users:", "[::1]:", "[fe80::1]", "fe80::1", "10.0.0.7:80"] } ] }
        ),
      ),
    ]),
    content="valid",
  )
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [
          #|  { "name": "a", "hosts": [":8080", ".", "[::1]junk", "users:http", "[]", "[::1",
          #|      "a]b", "users:8080:9090", "[zz]", "[::1]:x"] } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /mocks/0/hosts/0: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/1: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/2: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/3: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/4: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/5: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/6: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/7: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/8: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|a.json: /mocks/0/hosts/9: must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
    ),
  )
}

///|
test "two Mocks that claim the same Host after normalisation are rejected at the later claim, naming the earlier one" {
  inspect(
    problems([
      (
        "b.json",
        (
          #|{ "mocks": [{ "name": "orders",
          #|  "hosts": ["orders.example.com", "USERS.example.com.:8443", "shared"] }] }
        ),
      ),
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "users",
          #|  "hosts": ["users.example.com:8080", "users.internal", "[::1]:8080"] }] }
        ),
      ),
      (
        "c.json",
        (
          #|{ "mocks": [
          #|  { "name": "payments", "hosts": ["::1", "Users.Internal", "payments", "shared:1"] },
          #|  { "name": "refunds", "hosts": ["refunds", "Refunds.", "refunds:9"] } ] }
        ),
      ),
    ]),
    content=(
      #|b.json: /mocks/0/hosts/1: the Host "users.example.com" is already claimed by the Mock "users" at a.json: /mocks/0/hosts/0
      #|c.json: /mocks/0/hosts/0: the Host "[::1]" is already claimed by the Mock "users" at a.json: /mocks/0/hosts/2
      #|c.json: /mocks/0/hosts/1: the Host "users.internal" is already claimed by the Mock "users" at a.json: /mocks/0/hosts/1
      #|c.json: /mocks/0/hosts/3: the Host "shared" is already claimed by the Mock "orders" at b.json: /mocks/0/hosts/2
    ),
  )
}

///|
test "more than one Mock marked default is rejected at the later one, naming the earlier one" {
  inspect(
    problems([
      (
        "b.json",
        (
          #|{ "mocks": [{ "name": "orders", "default": true },
          #|  { "name": "payments", "default": false }] }
        ),
      ),
      ("a.json", "{ \"mocks\": [{ \"name\": \"users\", \"default\": true }] }"),
      (
        "c.json", "{ \"mocks\": [{ \"name\": \"refunds\", \"default\": true }] }",
      ),
    ]),
    content=(
      #|b.json: /mocks/0/default: the Default Mock is already "users", marked at a.json: /mocks/0/default
      #|c.json: /mocks/0/default: the Default Mock is already "users", marked at a.json: /mocks/0/default
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
test "two names in a response's headers that differ only in case are rejected at the later one, naming the earlier one" {
  inspect(
    problems([
      (
        "users.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [
          #|    { "id": "a", "mock": "users",
          #|      "response": { "status": 200, "headers": { "Set-Cookie": "a=1", "set-cookie": "b=2" } } },
          #|    { "id": "b", "mock": "users",
          #|      "response": { "status": 200, "headers": { "X-A": "1", "X-B": "2", "x-a": "3", "X-a": "4" } } },
          #|    { "id": "c", "mock": "users",
          #|      "response": { "status": 200, "headers": { "set-cookie": "c=3", "X-B": "5" } } } ] }
        ),
      ),
    ]),
    content=(
      #|users.json: /stubs/0/response/headers/set-cookie: the header name "Set-Cookie" is already given: header names are case-insensitive
      #|users.json: /stubs/1/response/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
      #|users.json: /stubs/1/response/headers/X-a: the header name "X-A" is already given: header names are case-insensitive
    ),
  )
}

///|
test "a header name that smock sets, or that is not valid, is not also reported as differing only in case" {
  inspect(
    problems([
      (
        "users.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [{ "id": "a", "mock": "users",
          #|    "response": { "status": 200,
          #|      "headers": { "Content-Length": "1", "content-length": "2", "X Y": "3", "x y": "4" } } }] }
        ),
      ),
    ]),
    content=(
      #|users.json: /stubs/0/response/headers/Content-Length: is set by smock and cannot be given
      #|users.json: /stubs/0/response/headers/content-length: is set by smock and cannot be given
      #|users.json: /stubs/0/response/headers/X Y: is not a valid header name
      #|users.json: /stubs/0/response/headers/x y: is not a valid header name
    ),
  )
}

///|
test "a header name repeated exactly is a duplicate key, in JSON and in YAML, and the rest of the file is not read" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [{ "id": "a", "mock": "users",
          #|    "response": { "status": 200, "headers": { "X-A": "1", "X-A": "2", "x-a": "3" } } }] }
        ),
      ),
      (
        "b.yaml",
        (
          #|stubs:
          #|  - id: b
          #|    mock: users
          #|    response: { status: 200, headers: { X-A: "1", X-A: "2", x-a: "3" } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/response/headers/X-A: duplicate key
      #|b.yaml: /stubs/0/response/headers/X-A: duplicate key
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
