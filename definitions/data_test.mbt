// Reading Data buckets: the top-level `data` of Definition files, each
// entry a named JSON value of a Mock, with its initial value inline or in a
// JSON file of the body-file subdirectory, and the rules of keyed buckets.

///|
/// Loads the Definition files `files`, as (name, YAML or JSON text) pairs,
/// with the body files `body_files`, as (name, text) pairs.
fn load_data(
  files : Array[(String, String)],
  body_files? : Array[(String, String)] = [],
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: body_files.map(file => (file.0, @utf8.encode(file.1))),
  }
  @definitions.load(set)
}

///|
/// Every diagnostic of loading `files`, one per line, or `valid`.
fn data_problems(
  files : Array[(String, String)],
  body_files? : Array[(String, String)] = [],
) -> String {
  match load_data(files, body_files~) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
/// The Data buckets of each Mock of the snapshot of `files`, one per line:
/// the Mock, the bucket's name, its key and new keys, and its initial value
/// as compact JSON.
fn buckets_of(
  files : Array[(String, String)],
  body_files? : Array[(String, String)] = [],
) -> String raise {
  let snapshot = match load_data(files, body_files~) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
  let lines = []
  for mock in snapshot.mocks {
    for bucket in mock.buckets {
      let key = match bucket.key {
        Some(key) => "key \{key.escape()}, new keys \{bucket.new_key.name()}"
        None => "not keyed"
      }
      lines.push(
        "\{mock.name}: \{bucket.name}: \{key}: \{bucket.initial.stringify()}",
      )
    }
  }
  lines.join("\n")
}

///|
test "a bucket takes its initial value inline or from a JSON file, may sit in any file, and two Mocks may use one name" {
  inspect(
    buckets_of(
      [
        (
          "a.yaml",
          (
            $|data:
            $|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
            $|  - { mock: shop, name: visits, json: 0 }
            $|  - { mock: users, name: visits, json: null }
          ),
        ),
        (
          "b.yaml",
          (
            $|mocks:
            $|  - name: shop
            $|  - name: users
            $|data:
            $|  - { mock: users, name: tokens, key: token, newKey: uuid, json: [{ token: a-1 }] }
            $|  - { mock: shop, name: cart, json: { items: [], total: 12.50 } }
            $|  - { mock: shop, name: users, key: id, newKey: integer, json: [{ id: "b" }, { id: -3 }] }
          ),
        ),
      ],
      body_files=[
        (
          "orders.json",
          (
            $|[{"id": 1001, "status": "paid"},
            $| {"id": 1002.0, "status": "pending"},
            $| {"id": "a-3", "status": "paid"}]
          ),
        ),
      ],
    ),
    content=(
      #|shop: orders: key "id", new keys integer: [{"id":1001,"status":"paid"},{"id":1002,"status":"pending"},{"id":"a-3","status":"paid"}]
      #|shop: visits: not keyed: 0
      #|shop: cart: not keyed: {"items":[],"total":12.5}
      #|shop: users: key "id", new keys integer: [{"id":"b"},{"id":-3}]
      #|users: visits: not keyed: null
      #|users: tokens: key "token", new keys uuid: [{"token":"a-1"}]
    ),
  )
}

///|
test "an entry needs a declared Mock, a name unique within it, and exactly one of json and jsonFile; its members are closed" {
  inspect(
    data_problems(
      [
        (
          "a.yaml",
          (
            $|mocks:
            $|  - name: shop
            $|  - name: users
            $|data:
            $|  - { mock: shop, name: orders, json: [] }
            $|  - { mock: shop, name: orders, json: {} }
            $|  - { mock: users, name: orders, json: {} }
            $|  - { mock: nowhere, name: orders, json: 1 }
            $|  - { name: no-mock, json: 1 }
            $|  - { mock: shop, json: 1 }
            $|  - { mock: shop, name: both, json: 1, jsonFile: one.json }
            $|  - { mock: shop, name: neither }
            $|  - { mock: shop, name: "a.b", json: 1 }
            $|  - { mock: shop, name: "", json: 1 }
            $|  - { mock: shop, name: 7, json: 1 }
            $|  - { mock: "", name: empty-mock, json: 1 }
            $|  - { mock: shop, name: extra, json: 1, value: 2 }
            $|  - [mock, shop]
          ),
        ),
        (
          "b.yaml",
          (
            $|data:
            $|  - { mock: shop, name: \{"x".repeat(128)}, json: 1 }
            $|  - { mock: shop, name: \{"x".repeat(129)}, json: 1 }
          ),
        ),
        ("c.yaml", "data: { mock: shop }"),
      ],
      body_files=[("one.json", "1")],
    ),
    content=(
      #|a.yaml: /data/1/name: the Data bucket name "orders" is already declared for the Mock "shop" at a.yaml: /data/0/name
      #|a.yaml: /data/3/mock: no file declares the Mock "nowhere"
      #|a.yaml: /data/4: needs "mock"
      #|a.yaml: /data/5: needs "name"
      #|a.yaml: /data/6: has "json" and "jsonFile"; give exactly one of them
      #|a.yaml: /data/7: needs "json" or "jsonFile"
      #|a.yaml: /data/8/name: is not a Data bucket name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /data/9/name: is not a Data bucket name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /data/10/name: is not a Data bucket name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /data/11/mock: must be a non-empty string
      #|a.yaml: /data/12/value: is not a known field
      #|a.yaml: /data/13: must be an object
      #|b.yaml: /data/1/name: is not a Data bucket name: 1 to 128 ASCII letters, digits, _ and -
      #|c.yaml: /data: must be an array
    ),
  )
}

///|
test "a jsonFile follows bodyFile's path rules and must hold JSON in UTF-8 that repeats no key" {
  inspect(
    data_problems(
      [
        (
          "a.yaml",
          (
            $|mocks:
            $|  - name: shop
            $|data:
            $|  - { mock: shop, name: ok, jsonFile: data/ok.json }
            $|  - { mock: shop, name: missing, jsonFile: missing.json }
            $|  - { mock: shop, name: outside, jsonFile: ../ok.json }
            $|  - { mock: shop, name: hidden, jsonFile: .hidden.json }
            $|  - { mock: shop, name: not-a-string, jsonFile: 1 }
            $|  - { mock: shop, name: not-json, jsonFile: text.txt }
            $|  - { mock: shop, name: not-utf-8, jsonFile: latin1.json }
            $|  - { mock: shop, name: repeated, jsonFile: repeated.json }
            $|  - { mock: shop, name: empty, jsonFile: empty.json }
          ),
        ),
      ],
      body_files=[
        ("data/ok.json", "{\"a\": [1, 2]}"),
        (".hidden.json", "1"),
        ("text.txt", "hello"),
        ("repeated.json", "[{\"id\": 1, \"id\": 2}]"),
        ("empty.json", ""),
      ],
    ),
    content=(
      #|a.yaml: /data/1/jsonFile: no body file "missing.json" in the body-file subdirectory
      #|a.yaml: /data/2/jsonFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.yaml: /data/3/jsonFile: must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .
      #|a.yaml: /data/4/jsonFile: must be a string
      #|a.yaml: /data/5/jsonFile: "text.txt": not valid JSON: Invalid character 'h' at line 1, column 0
      #|a.yaml: /data/6/jsonFile: no body file "latin1.json" in the body-file subdirectory
      #|a.yaml: /data/7/jsonFile: "repeated.json" at /0/id: duplicate key
      #|a.yaml: /data/8/jsonFile: "empty.json": not valid JSON: Unexpected end of file
    ),
  )
  let set : @definitions.DefinitionSet = {
    files: [
      (
        "a.yaml",
        @utf8.encode(
          "mocks: [{ name: shop }]\ndata: [{ mock: shop, name: x, jsonFile: latin1.json }]",
        ),
      ),
    ],
    body_files: [("latin1.json", b"\"caf\xe9\"")],
  }
  inspect(
    match @definitions.load(set) {
      Ok(_) => "valid"
      Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
    },
    content=(
      #|a.yaml: /data/0/jsonFile: "latin1.json": not valid UTF-8
    ),
  )
}

///|
test "a keyed bucket holds an array of objects, each with a key that no other item's text repeats" {
  inspect(
    data_problems(
      [
        (
          "a.yaml",
          (
            $|mocks:
            $|  - name: shop
            $|data:
            $|  - mock: shop
            $|    name: keys
            $|    key: id
            $|    json:
            $|      - { id: 1 }
            $|      - { id: "1" }
            $|      - { id: 1.0 }
            $|      - { id: 1e0 }
            $|      - { id: 9007199254740991 }
            $|      - { id: -9007199254740991 }
            $|      - { id: 9007199254740992 }
            $|      - { id: 1.5 }
            $|      - { id: "" }
            $|      - { id: "a/b" }
            $|      - { id: null }
            $|      - { id: true }
            $|      - { id: [1] }
            $|      - { other: 1 }
            $|      - 7
            $|      - { id: "a.b" }
            $|      - { id: "-0" }
            $|      - { id: -0 }
            $|      - { id: 0 }
            $|  - { mock: shop, name: object, key: id, json: { id: 1 } }
            $|  - { mock: shop, name: "null", key: id, json: null }
            $|  - { mock: shop, name: literal, key: a.b, json: [{ a: { b: 1 } }, { a.b: 2 }] }
            $|  - { mock: shop, name: empty-key, key: "", json: [] }
            $|  - { mock: shop, name: no-key, newKey: integer, json: [] }
            $|  - { mock: shop, name: bad-new-key, key: id, newKey: random, json: [] }
            $|  - { mock: shop, name: from-file, key: id, jsonFile: orders.json }
            $|  - { mock: shop, name: file-not-array, key: id, jsonFile: object.json }
          ),
        ),
      ],
      body_files=[
        ("orders.json", "[{\"id\": 42}, {\"id\": \"42\"}, {\"name\": \"x\"}]"),
        ("object.json", "{\"id\": 1}"),
      ],
    ),
    content=(
      #|a.yaml: /data/0/json/1/id: has the key text "1", as item 0 does
      #|a.yaml: /data/0/json/2/id: has the key text "1", as item 0 does
      #|a.yaml: /data/0/json/3/id: has the key text "1", as item 0 does
      #|a.yaml: /data/0/json/6/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/7/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/8/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/9/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/10/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/11/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/12/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /data/0/json/13: needs the key member "id"
      #|a.yaml: /data/0/json/14: must be an object with the key member "id"
      #|a.yaml: /data/0/json/18/id: has the key text "0", as item 17 does
      #|a.yaml: /data/1/json: must be an array of objects, since the bucket has "key"
      #|a.yaml: /data/2/json: must be an array of objects, since the bucket has "key"
      #|a.yaml: /data/3/json/0: needs the key member "a.b"
      #|a.yaml: /data/4/key: must be a non-empty string
      #|a.yaml: /data/5/newKey: is allowed only with "key": only a keyed bucket makes new keys
      #|a.yaml: /data/6/newKey: must be "integer" or "uuid"
      #|a.yaml: /data/7/jsonFile: "orders.json" at /1/id: has the key text "42", as item 0 does
      #|a.yaml: /data/7/jsonFile: "orders.json" at /2: needs the key member "id"
      #|a.yaml: /data/8/jsonFile: "object.json": must be an array of objects, since the bucket has "key"
    ),
  )
}

///|
test "templates read data.NAME over their Mock's buckets, declared in any file, earlier or later" {
  inspect(
    data_problems([
      (
        "a.yaml",
        (
          $|stubs:
          $|  - id: reads
          $|    mock: shop
          $|    variables: { seen: "${len(data.orders)}" }
          $|    response:
          $|      status: 200
          $|      template: true
          $|      headers: { X-Visits: "${data.visits}" }
          $|      json: { $each: data.orders, as: o, do: "${o.id}" }
          $|  - id: events
          $|    response:
          $|      status: 200
          $|      template: true
          $|      events: [{ data: "${data['visits']}" }, { json: "${data.orders[0]}" }]
          $|    mock: shop
          $|  - id: weighted
          $|    mock: shop
          $|    responses: [{ status: 200, template: true, body: "${data.visits}" }]
        ),
      ),
      (
        "b.yaml",
        (
          $|mocks:
          $|  - name: shop
          $|  - name: users
          $|data:
          $|  - { mock: shop, name: orders, json: [] }
          $|  - { mock: shop, name: visits, json: 0 }
          $|  - { mock: users, name: profiles, json: [] }
        ),
      ),
    ]),
    content="valid",
  )
}

///|
test "a template that reads no bucket of its Mock, or a loop variable named data, is a load error at its JSON Pointer" {
  inspect(
    data_problems([
      (
        "a.yaml",
        (
          $|mocks:
          $|  - name: shop
          $|  - name: users
          $|data:
          $|  - { mock: shop, name: orders, json: [] }
          $|  - { mock: users, name: profiles, json: [] }
          $|stubs:
          $|  - id: other-mock
          $|    mock: shop
          $|    response: { status: 200, template: true, body: "${data.profiles}" }
          $|  - id: typo
          $|    mock: users
          $|    variables: { a: "${data.profile ?? 0}" }
          $|    response:
          $|      status: 200
          $|      template: true
          $|      headers: { X-A: "${data}" }
          $|      json: { a: "${data[0]}", b: { $each: "range(1, 2)", as: data, do: 1 } }
          $|  - id: undeclared-mock
          $|    mock: nowhere
          $|    response: { status: 200, template: true, body: "${data.orders}" }
        ),
      ),
    ]),
    content=(
      #|a.yaml: /stubs/0/response/body: template: column 3: data.profiles: the Mock has no Data bucket "profiles"
      #|a.yaml: /stubs/1/variables/a: template: column 3: data.profile: the Mock has no Data bucket "profile"
      #|a.yaml: /stubs/1/response/headers/X-A: template: column 3: data: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|a.yaml: /stubs/1/response/json/a: template: column 3: data[0]: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|a.yaml: /stubs/1/response/json/b/as: template: "data" cannot be a loop variable: it is a request field, env, vars, data, loop or a reserved word
      #|a.yaml: /stubs/2/response/body: template: column 3: data.orders: the Mock has no Data bucket "orders"
      #|a.yaml: /stubs/2/mock: no file declares the Mock "nowhere"
    ),
  )
}
