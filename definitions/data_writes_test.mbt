// Reading a Stub's `dataWrites`: a list of writes to the Data buckets of
// its Mock, each with `op`, `bucket` and the members its op takes.

///|
/// Loads the Definition file `a.yaml`, holding Mock `m` with the buckets
/// `visits` (a number), `cart` (an array), `profile` (an object) and
/// `orders` (keyed by `id`), and the Stubs `stubs`, given as YAML list
/// items, and renders every diagnostic, one per line, or `valid`.
fn write_problems(stubs : String) -> String {
  let file =
    $|mocks:
    $|  - name: m
    $|data:
    $|  - { mock: m, name: visits, json: 0 }
    $|  - { mock: m, name: cart, json: [] }
    $|  - { mock: m, name: profile, json: {} }
    $|  - { mock: m, name: orders, key: id, json: [] }
    $|stubs:
    $|\{stubs}
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "set, merge and append write to buckets without key, with literal and templated values, beside response or responses" {
  inspect(
    write_problems(
      (
        #|  - id: a
        #|    mock: m
        #|    dataWrites:
        #|      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
        #|      - { op: set, bucket: profile, value: null }
        #|      - { op: merge, bucket: profile, value: { name: "${body.name}", $$id: 1 } }
        #|      - { op: merge, bucket: profile, value: "${body}" }
        #|      - { op: append, bucket: cart, value: [1, "$${not a template}"] }
        #|      - { op: append, bucket: cart, value: { $if: "body.sku", then: "${body.sku}", else: none } }
        #|    response: { status: 200 }
        #|  - id: b
        #|    mock: m
        #|    variables: { last: "${body}" }
        #|    dataWrites: [{ op: set, bucket: cart, value: [] }]
        #|    responses: [{ status: 200 }, { status: 503 }]
      ),
    ),
    content="valid",
  )
}

///|
test "dataWrites holds 1 to 100 writes, each an object with a known op, a bucket and the members its op takes" {
  let many = "      - { op: set, bucket: visits, value: 1 }\n".repeat(101)
  inspect(
    write_problems(
      (
        $|  - id: empty
        $|    mock: m
        $|    dataWrites: []
        $|    response: { status: 200 }
        $|  - id: too-many
        $|    mock: m
        $|    dataWrites:
        $|\{many}    response: { status: 200 }
        $|  - id: not-a-list
        $|    mock: m
        $|    dataWrites: { op: set, bucket: visits, value: 1 }
        $|    response: { status: 200 }
        $|  - id: shapes
        $|    mock: m
        $|    dataWrites:
        $|      - set
        $|      - { op: inc, bucket: visits, value: 1 }
        $|      - { bucket: visits, value: 1 }
        $|      - { op: set, value: 1 }
        $|      - { op: set, bucket: visits }
        $|      - { op: set, bucket: 7, value: 1 }
        $|      - { op: set, bucket: visits, value: 1, path: /a }
        $|      - { op: remove, bucket: cart }
        $|      - { op: remove, bucket: cart, key: "1", value: 1 }
        $|      - { op: append, bucket: cart, key: "1", value: 1 }
        $|      - { op: merge, bucket: profile, key: 1, value: {} }
        $|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites: must hold 1 to 100 writes
      #|a.yaml: /stubs/1/dataWrites: must hold 1 to 100 writes
      #|a.yaml: /stubs/2/dataWrites: must be an array
      #|a.yaml: /stubs/3/dataWrites/0: must be an object
      #|a.yaml: /stubs/3/dataWrites/1/op: must be "set", "merge", "append" or "remove"
      #|a.yaml: /stubs/3/dataWrites/2: needs "op"
      #|a.yaml: /stubs/3/dataWrites/3: needs "bucket"
      #|a.yaml: /stubs/3/dataWrites/4: needs "value"
      #|a.yaml: /stubs/3/dataWrites/5/bucket: must be a non-empty string
      #|a.yaml: /stubs/3/dataWrites/6/path: is not a known field
      #|a.yaml: /stubs/3/dataWrites/7: needs "key"
      #|a.yaml: /stubs/3/dataWrites/8/value: "remove" takes no value
      #|a.yaml: /stubs/3/dataWrites/8/key: is allowed only on a keyed bucket, and the Data bucket "cart" has no "key"
      #|a.yaml: /stubs/3/dataWrites/9/key: "append" takes no key
      #|a.yaml: /stubs/3/dataWrites/10/key: must be a string
      #|a.yaml: /stubs/3/dataWrites/10/key: is allowed only on a keyed bucket, and the Data bucket "profile" has no "key"
    ),
  )
}

///|
test "a write names a bucket of the Stub's Mock, and takes key only on a keyed bucket" {
  inspect(
    write_problems(
      (
        #|  - id: buckets
        #|    mock: m
        #|    dataWrites:
        #|      - { op: set, bucket: visit, value: 1 }
        #|      - { op: set, bucket: visits, key: "${path[1]}", value: 1 }
        #|      - { op: remove, bucket: visits, key: "${path[1]}" }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites/0/bucket: the Mock has no Data bucket "visit"
      #|a.yaml: /stubs/0/dataWrites/1/key: is allowed only on a keyed bucket, and the Data bucket "visits" has no "key"
      #|a.yaml: /stubs/0/dataWrites/2/key: is allowed only on a keyed bucket, and the Data bucket "visits" has no "key"
    ),
  )
}

///|
test "keyed buckets take set, merge and remove with key, append, and set without key, with literal and templated values" {
  inspect(
    write_problems(
      (
        #|  - id: keyed
        #|    mock: m
        #|    dataWrites:
        #|      - { op: merge, bucket: orders, key: "${path[3]}", value: { status: paid, paidAt: "${now()}" } }
        #|      - { op: merge, bucket: orders, key: "1002", value: "${body}" }
        #|      - { op: set, bucket: orders, key: "${path[3]}", value: { id: 1002, status: pending } }
        #|      - { op: set, bucket: orders, key: "a-$${x}", value: "${body}" }
        #|      - { op: remove, bucket: orders, key: "${data.orders[0].id}" }
        #|      - { op: append, bucket: orders, value: { status: new } }
        #|      - { op: append, bucket: orders, value: { id: "a-1", status: new } }
        #|      - { op: append, bucket: orders, value: "${body}" }
        #|      - { op: set, bucket: orders, value: [] }
        #|      - { op: set, bucket: orders, value: [{ id: 1 }, { id: "2", note: null }] }
        #|      - { op: set, bucket: orders, value: "${data.orders}" }
        #|    response: { status: 200 }
      ),
    ),
    content="valid",
  )
}

///|
test "on a keyed bucket, merge needs key, and a literal value that already breaks its op does not load" {
  inspect(
    write_problems(
      (
        #|  - id: keyed
        #|    mock: m
        #|    dataWrites:
        #|      - { op: merge, bucket: orders, value: { status: paid } }
        #|      - { op: set, bucket: orders, key: "1", value: [1] }
        #|      - { op: set, bucket: orders, key: "1", value: null }
        #|      - { op: merge, bucket: orders, key: "1", value: paid }
        #|      - { op: append, bucket: orders, value: 1 }
        #|      - { op: append, bucket: orders, value: [{ id: 1 }] }
        #|      - { op: append, bucket: orders, value: { id: null } }
        #|      - { op: append, bucket: orders, value: { id: "a/b" } }
        #|      - { op: append, bucket: orders, value: { id: 1.5 } }
        #|      - { op: set, bucket: orders, value: {} }
        #|      - { op: set, bucket: orders, value: [1, {}, { id: 1 }, { id: 1.0 }, { id: "" }] }
        #|      - { op: set, bucket: orders, value: [{ id: "${body.id}" }, 1] }
        #|      - { op: append, bucket: orders, value: { id: "${body.id}" } }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites/0: "merge" into the keyed Data bucket "orders" needs "key": the bucket holds an array, and "merge" with "key" merges into one of its items
      #|a.yaml: /stubs/0/dataWrites/1/value: must be an object: "set" with "key" makes one item of the keyed bucket this value
      #|a.yaml: /stubs/0/dataWrites/2/value: must be an object: "set" with "key" makes one item of the keyed bucket this value
      #|a.yaml: /stubs/0/dataWrites/3/value: must be an object: "merge" with "key" merges the members of an object into one item
      #|a.yaml: /stubs/0/dataWrites/4/value: must be an object: "append" adds an item to the keyed bucket
      #|a.yaml: /stubs/0/dataWrites/5/value: must be an object: "append" adds an item to the keyed bucket
      #|a.yaml: /stubs/0/dataWrites/6/value/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /stubs/0/dataWrites/7/value/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /stubs/0/dataWrites/8/value/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|a.yaml: /stubs/0/dataWrites/9/value: must be an array of objects, since the bucket has "key"
      #|a.yaml: /stubs/0/dataWrites/10/value/0: must be an object with the key member "id"
      #|a.yaml: /stubs/0/dataWrites/10/value/1: needs the key member "id"
      #|a.yaml: /stubs/0/dataWrites/10/value/3/id: has the key text "1", as item 2 does
      #|a.yaml: /stubs/0/dataWrites/10/value/4/id: must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
    ),
  )
}

///|
test "key is a text template, always parsed: its problems are reported at its pointer" {
  inspect(
    write_problems(
      (
        #|  - id: keys
        #|    mock: m
        #|    dataWrites:
        #|      - { op: remove, bucket: orders, key: "${path[3]" }
        #|      - { op: set, bucket: orders, key: "${data.order[0].id}", value: {} }
        #|      - { op: merge, bucket: orders, key: 1002, value: {} }
        #|      - { op: remove, bucket: orders, key: "${x}" }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites/0/key: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/0/dataWrites/1/key: template: column 3: data.order[0].id: the Mock has no Data bucket "order"
      #|a.yaml: /stubs/0/dataWrites/2/key: must be a string
      #|a.yaml: /stubs/0/dataWrites/3/key: template: column 3: unknown name "x": not a request field, a loop variable or a helper
    ),
  )
}

///|
test "a literal value that already breaks its op, a merge value that is not an object, does not load; a template is checked when it renders" {
  inspect(
    write_problems(
      (
        #|  - id: values
        #|    mock: m
        #|    dataWrites:
        #|      - { op: merge, bucket: profile, value: [1] }
        #|      - { op: merge, bucket: profile, value: "$${x}" }
        #|      - { op: merge, bucket: profile, value: 1 }
        #|      - { op: merge, bucket: profile, value: null }
        #|      - { op: merge, bucket: profile, value: "${body}" }
        #|      - { op: merge, bucket: profile, value: ["${body}"] }
        #|      - { op: merge, bucket: profile, value: { $if: body, then: 1, else: 2 } }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites/0/value: must be an object: "merge" merges the members of an object into the bucket
      #|a.yaml: /stubs/0/dataWrites/1/value: must be an object: "merge" merges the members of an object into the bucket
      #|a.yaml: /stubs/0/dataWrites/2/value: must be an object: "merge" merges the members of an object into the bucket
      #|a.yaml: /stubs/0/dataWrites/3/value: must be an object: "merge" merges the members of an object into the bucket
    ),
  )
}

///|
test "a value is a structured template, always parsed: its problems are reported at its pointer, and a $if at its root needs else" {
  inspect(
    write_problems(
      (
        #|  - id: templates
        #|    mock: m
        #|    dataWrites:
        #|      - { op: set, bucket: visits, value: "${query.a" }
        #|      - { op: set, bucket: visits, value: { $if: query.a, then: 1 } }
        #|      - { op: set, bucket: visits, value: "${data.visit}" }
        #|      - { op: set, bucket: visits, value: { $each: "range(1, 1000)", as: i, do: { $each: "range(1, 11)", as: j, do: 1 } } }
        #|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/dataWrites/0/value: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/0/dataWrites/1/value: template: a $if at the root of a data write's value needs "else", so that it always gives a value
      #|a.yaml: /stubs/0/dataWrites/2/value: template: column 3: data.visit: the Mock has no Data bucket "visit"
      #|a.yaml: /stubs/0/dataWrites/3/value: template: its loops run at least 12000 times; one value runs at most 10000 loop iterations
    ),
  )
}

///|
test "a write may name a bucket that another file declares for the Stub's Mock, but not another Mock's" {
  let files = [
    (
      "a.yaml",
      (
        #|mocks: [{ name: m }, { name: other-mock }]
        #|stubs:
        #|  - id: a
        #|    mock: m
        #|    dataWrites:
        #|      - { op: set, bucket: later, value: 1 }
        #|      - { op: set, bucket: other, value: 1 }
        #|    response: { status: 200 }
      ),
    ),
    (
      "b.yaml",
      (
        #|data:
        #|  - { mock: m, name: later, json: 0 }
        #|  - { mock: other-mock, name: other, json: 0 }
      ),
    ),
  ]
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  let problems = match @definitions.load(set) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
  inspect(
    problems,
    content=(
      #|a.yaml: /stubs/0/dataWrites/1/bucket: the Mock has no Data bucket "other"
    ),
  )
}

///|
test "a Stub keeps its writes in the order written, each with its op, bucket, key and value" {
  let file =
    #|mocks:
    #|  - name: m
    #|data:
    #|  - { mock: m, name: visits, json: 0 }
    #|  - { mock: m, name: cart, json: [] }
    #|  - { mock: m, name: orders, key: id, json: [] }
    #|stubs:
    #|  - id: a
    #|    mock: m
    #|    dataWrites:
    #|      - { op: append, bucket: cart, value: { sku: "${body.sku}" } }
    #|      - { op: set, bucket: visits, value: 1 }
    #|      - { op: merge, bucket: cart, value: "${body}" }
    #|      - { op: merge, bucket: orders, key: "${path[1]}", value: { paid: true } }
    #|      - { op: remove, bucket: orders, key: "1001" }
    #|    response: { status: 200 }
    #|  - id: b
    #|    mock: m
    #|    response: { status: 200 }
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  let snapshot = match @definitions.load(set) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
  let out = []
  for stub in snapshot.mocks[0].stubs {
    let Ordinary(ordinary) = stub.serves
    out.push("\{stub.id}: writes data \{ordinary.writes_data()}")
    for write in ordinary.data_writes {
      let key = match write.key {
        Some(key) =>
          " key at \{key.pointer}: \{key.source.escape()}, literal \{key.is_literal()};"
        None => ""
      }
      let value = match write.value {
        Some(value) => {
          let literal = match value.literal() {
            Some(literal) => literal.stringify()
            None => "none"
          }
          " value at \{value.pointer}: \{value.source.stringify()}, literal \{literal}"
        }
        None => " no value"
      }
      out.push("  \{write.op.name()} \{write.bucket}:\{key}\{value}")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|a: writes data true
      #|  append cart: value at /dataWrites/0/value: {"sku":"${body.sku}"}, literal none
      #|  set visits: value at /dataWrites/1/value: 1, literal 1
      #|  merge cart: value at /dataWrites/2/value: "${body}", literal none
      #|  merge orders: key at /dataWrites/3/key: "${path[1]}", literal false; value at /dataWrites/3/value: {"paid":true}, literal {"paid":true}
      #|  remove orders: key at /dataWrites/4/key: "1001", literal true; no value
      #|b: writes data false
    ),
  )
}
