// Reading CRUD Stubs: a Stub with `crud` in place of `request`, `response`
// (or `responses`) and `scenario` serves a keyed Data bucket of its Mock at
// a path, with optional static headers.

///|
/// Loads the Definition file `a.yaml`, holding Mock `m` with the buckets
/// `orders` (keyed by `id`) and `visits` (without `key`), and the Stubs
/// `stubs`, given as YAML list items, and renders every diagnostic, one per
/// line, or `valid` and each Stub's ID with what it serves, in matching
/// order.
fn crud_problems(stubs : String) -> String {
  let file =
    $|mocks:
    $|  - name: m
    $|data:
    $|  - { mock: m, name: orders, key: id, json: [] }
    $|  - { mock: m, name: visits, json: 0 }
    $|stubs:
    $|\{stubs}
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(snapshot) => {
      let out = ["valid"]
      for stub in snapshot.mocks[0].stubs {
        let serves = match stub.serves {
          Crud({ bucket, path, headers, }) => {
            let fields = headers.iter().map(h => "\{h.0}: \{h.1}").collect()
            "crud \{bucket} at \{path}, headers [\{fields.join(", ")}]"
          }
          Ordinary(_) => "ordinary"
        }
        out.push("\{stub.id}: \{serves}")
      }
      out.join("\n")
    }
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "a CRUD Stub has crud, with a keyed bucket of its Mock, a path and optional headers, beside id, mock, priority and fault; two with the same path load" {
  inspect(
    crud_problems(
      (
        #|  - id: orders
        #|    mock: m
        #|    priority: 3
        #|    fault: { delay: { fixed: 10 } }
        #|    crud:
        #|      bucket: orders
        #|      path: /api/v1/orders
        #|      headers:
        #|        Access-Control-Allow-Origin: "*"
        #|        Access-Control-Expose-Headers: [X-Total-Count, X-Filtered-Count]
        #|  - id: again
        #|    mock: m
        #|    crud: { bucket: orders, path: /api/v1/orders }
        #|  - id: one-segment
        #|    mock: m
        #|    crud: { bucket: orders, path: "/a b" }
      ),
    ),
    content=(
      #|valid
      #|orders: crud orders at /api/v1/orders, headers [Access-Control-Allow-Origin: *, Access-Control-Expose-Headers: X-Total-Count, Access-Control-Expose-Headers: X-Filtered-Count]
      #|again: crud orders at /api/v1/orders, headers []
      #|one-segment: crud orders at /a b, headers []
    ),
  )
}

///|
test "crud is an object with bucket and path, and no other member than headers" {
  inspect(
    crud_problems(
      (
        #|  - id: not-an-object
        #|    mock: m
        #|    crud: orders
        #|  - id: empty
        #|    mock: m
        #|    crud: {}
        #|  - id: extra
        #|    mock: m
        #|    crud: { bucket: orders, path: /orders, methods: [GET] }
        #|  - id: wrong-types
        #|    mock: m
        #|    crud: { bucket: 1, path: 2, headers: 3 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/crud: must be an object
      #|a.yaml: /stubs/1/crud: needs "bucket"
      #|a.yaml: /stubs/1/crud: needs "path"
      #|a.yaml: /stubs/2/crud/methods: is not a known field
      #|a.yaml: /stubs/3/crud/bucket: must be a non-empty string
      #|a.yaml: /stubs/3/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|a.yaml: /stubs/3/crud/headers: must be an object
    ),
  )
}

///|
test "the bucket must be a keyed bucket of the Stub's Mock" {
  inspect(
    crud_problems(
      (
        #|  - id: unknown
        #|    mock: m
        #|    crud: { bucket: order, path: /orders }
        #|  - id: not-keyed
        #|    mock: m
        #|    crud: { bucket: visits, path: /visits }
        #|  - id: empty-name
        #|    mock: m
        #|    crud: { bucket: "", path: /orders }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/crud/bucket: the Mock has no Data bucket "order"
      #|a.yaml: /stubs/1/crud/bucket: the Data bucket "visits" has no "key": a CRUD Stub serves only a keyed bucket
      #|a.yaml: /stubs/2/crud/bucket: must be a non-empty string
    ),
  )
}

///|
test "the path starts with /, does not end with /, and has no empty segment, so / alone is refused" {
  let out = []
  for
    path in [
      "/", "orders", "/orders/", "/api//orders", "//orders", "", "/api/v1/orders",
    ] {
    let problems = crud_problems(
      (
        $|  - id: p
        $|    mock: m
        $|    crud: { bucket: orders, path: \{path.escape()} }
      ),
    )
    let shown = if problems.has_prefix("valid") { "valid" } else { problems }
    out.push("\{path.escape()}: \{shown}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|"/": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"orders": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"/orders/": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"/api//orders": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"//orders": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"": a.yaml: /stubs/0/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|"/api/v1/orders": valid
    ),
  )
}

///|
test "request, response, responses, scenario, variables and dataWrites are not allowed beside crud, and a Stub needs one of response, responses and crud" {
  inspect(
    crud_problems(
      (
        #|  - id: all
        #|    mock: m
        #|    crud: { bucket: orders, path: /orders }
        #|    request: { method: GET }
        #|    response: { status: 200 }
        #|    responses: [{ status: 200 }]
        #|    scenario: { name: s, requires: Down }
        #|    variables: { a: 1 }
        #|    dataWrites: [{ op: set, bucket: visits, value: 1 }]
        #|  - id: none
        #|    mock: m
        #|    request: { method: GET }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/0/response: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/0/responses: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/0/scenario: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/0/variables: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/0/dataWrites: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|a.yaml: /stubs/1: needs "response", "responses" or "crud"
    ),
  )
}

///|
test "crud.headers has the rules of noMatch.headers, and cannot give a header that smock sets on a CRUD answer" {
  inspect(
    crud_problems(
      (
        #|  - id: headers
        #|    mock: m
        #|    crud:
        #|      bucket: orders
        #|      path: /orders
        #|      headers:
        #|        content-type: text/plain
        #|        Location: /x
        #|        X-Total-Count: "1"
        #|        x-filtered-count: "1"
        #|        Content-Length: "1"
        #|        Transfer-Encoding: chunked
        #|        Connection: close
        #|        Smock-Mock: x
        #|        X-A: a
        #|        x-a: b
        #|        X-Empty: []
        #|        X-Line: "a\nb"
        #|        "bad name": x
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/crud/headers/content-type: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/Location: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/X-Total-Count: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/x-filtered-count: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/Content-Length: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/Transfer-Encoding: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/Connection: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/Smock-Mock: is set by smock and cannot be given
      #|a.yaml: /stubs/0/crud/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
      #|a.yaml: /stubs/0/crud/headers/X-Empty: must not be an empty array
      #|a.yaml: /stubs/0/crud/headers/X-Line: must not contain control characters other than tab
      #|a.yaml: /stubs/0/crud/headers/bad name: is not a valid header name
    ),
  )
}

///|
test "a crud with a problem still declares its Stub, so that the problems of its ID and Mock are reported too" {
  inspect(
    crud_problems(
      (
        #|  - id: dup
        #|    mock: m
        #|    crud: { bucket: orders, path: /orders }
        #|  - id: dup
        #|    mock: nowhere
        #|    crud: { bucket: orders, path: / }
      ),
    ),
    content=(
      #|a.yaml: /stubs/1/crud/bucket: the Mock has no Data bucket "orders"
      #|a.yaml: /stubs/1/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|a.yaml: /stubs/1/id: the Stub ID "dup" is already used at a.yaml: /stubs/0/id
      #|a.yaml: /stubs/1/mock: no file declares the Mock "nowhere"
    ),
  )
}

///|
/// The `crud` of a CRUD Stub on the path `/api/v1/orders`.
fn orders_crud() -> @definitions.Crud {
  let file =
    #|mocks:
    #|  - name: m
    #|data:
    #|  - { mock: m, name: orders, key: id, json: [] }
    #|stubs:
    #|  - { id: orders, mock: m, crud: { bucket: orders, path: /api/v1/orders } }
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) &&
    snapshot.mocks[0].stubs[0].serves is Crud(crud) else {
    abort("the CRUD Stub loads")
  }
  crud
}

///|
test "operation serves a method at a shape of path exactly when crud_methods lists it for that shape, and crud_methods(None) is their union in operation order" {
  let crud = orders_crud()
  let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
  let shapes : Array[(@definitions.CrudShape, String)] = [
    (ListPath, "/api/v1/orders"),
    (ItemPath, "/api/v1/orders/1"),
  ]
  let union = []
  for meth in methods {
    let mut served = false
    for shape in shapes {
      let (shape, path) = shape
      assert_eq(crud.shape(path), Some(shape))
      let listed = @definitions.crud_methods(Some(shape)).iter().contains(meth)
      assert_eq(crud.operation(meth, path) is Some(_), listed)
      served = served || listed
    }
    if served {
      union.push(meth)
    }
  }
  assert_eq(@definitions.crud_methods(None).iter().collect(), union)
  debug_inspect(
    shapes.map(shape => {
      @definitions.crud_methods(Some(shape.0)).iter().collect()
    }),
    content=(
      #|[["GET", "POST"], ["GET", "PUT", "PATCH", "DELETE"]]
    ),
  )
}
