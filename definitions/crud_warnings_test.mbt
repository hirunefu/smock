// Seam 1 tests of the `check` warnings about CRUD Stubs: only the shadowing
// that can be proven is reported, never a partial overlap.

///|
/// The warnings of a definition set with the Mock `shop`, a second Mock
/// `other`, and the keyed bucket `orders` in each, then `stubs`, given as
/// YAML list items, one per line, or `none`.
fn crud_warnings(stubs : String) -> String raise {
  warnings([
    (
      "shop.yaml",
      (
        $|mocks:
        $|  - { name: shop }
        $|  - { name: other }
        $|data:
        $|  - { mock: shop, name: orders, key: id, json: [] }
        $|  - { mock: other, name: orders, key: id, json: [] }
        $|stubs:
        $|\{stubs}
      ),
    ),
  ])
}

///|
test "an earlier CRUD Stub shadows a later ordinary Stub of its Mock whose exact method and exact path it serves, whatever that Stub's other conditions or requires" {
  inspect(
    crud_warnings(
      (
        #|  - id: orders
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/orders }
        #|  - id: order-1001
        #|    mock: shop
        #|    request: { method: GET, path: /api/v1/orders/1001 }
        #|    response: { status: 200 }
        #|  - id: create-with-key
        #|    mock: shop
        #|    request: { method: POST, path: /api/v1/orders, headers: { X-Api-Key: { $exists: true } } }
        #|    response: { status: 201 }
        #|  - id: delete-while-down
        #|    mock: shop
        #|    scenario: { name: orders, requires: Down }
        #|    request: { method: DELETE, path: /api/v1/orders/7, body: { json: { reason: x } } }
        #|    response: { status: 503 }
        #|  - id: paid-list
        #|    mock: shop
        #|    request: { method: GET, path: /api/v1/orders, query: { status: paid } }
        #|    responses: [{ status: 200 }, { status: 500 }]
        #|  - id: go-down
        #|    mock: shop
        #|    scenario: { name: orders, moveTo: Down }
        #|    request: { method: POST, path: /admin/down }
        #|    response: { status: 204 }
      ),
    ),
    content=(
      #|shop.yaml: /stubs/1: warning: the Stub "order-1001" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|shop.yaml: /stubs/2: warning: the Stub "create-with-key" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|shop.yaml: /stubs/3: warning: the Stub "delete-while-down" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|shop.yaml: /stubs/4: warning: the Stub "paid-list" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
test "an earlier CRUD Stub shadows a later CRUD Stub of its Mock with the same path, whatever its bucket, and no other" {
  inspect(
    crud_warnings(
      (
        #|  - id: orders
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/orders }
        #|  - id: orders-again
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/orders, headers: { X-A: "1" } }
        #|  - id: under-an-item
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/orders/1001 }
        #|  - id: longer
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/ordersx }
        #|  - id: other-case
        #|    mock: shop
        #|    crud: { bucket: orders, path: /API/v1/orders }
        #|  - id: in-other
        #|    mock: other
        #|    crud: { bucket: orders, path: /api/v1/orders }
      ),
    ),
    content=(
      #|shop.yaml: /stubs/1: warning: the Stub "orders-again" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
test "an ordinary Stub shadows a later CRUD Stub only when it has no request conditions and no requires" {
  let verdict = (earlier : String) => {
    let warned = crud_warnings(
      (
        $|  - id: earlier
        $|    mock: shop
        $|\{earlier}
        $|    response: { status: 200 }
        $|  - id: orders
        $|    mock: shop
        $|    crud: { bucket: orders, path: /api/v1/orders }
      ),
    )
    let shown = earlier.trim().to_owned()
    if warned == "none" {
      "\{shown} -> not reported"
    } else {
      "\{shown} -> \{warned}"
    }
  }
  inspect(
    [
      verdict("    priority: 1"),
      verdict("    request: {}"),
      verdict("    scenario: { name: s, moveTo: Down }"),
      verdict("    scenario: { name: s, requires: Started }"),
      verdict("    request: { method: GET }"),
      verdict("    request: { path: { pattern: \".*\" } }"),
      verdict("    request: { headers: { authorization: { $exists: false } } }"),
    ].join("\n"),
    content=(
      #|priority: 1 -> shop.yaml: /stubs/1: warning: the Stub "orders" can never match: the Stub "earlier" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|request: {} -> shop.yaml: /stubs/1: warning: the Stub "orders" can never match: the Stub "earlier" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|scenario: { name: s, moveTo: Down } -> shop.yaml: /stubs/1: warning: the Stub "orders" can never match: the Stub "earlier" at shop.yaml: /stubs/0 is tried first and matches every request this one would
      #|scenario: { name: s, requires: Started } -> not reported
      #|request: { method: GET } -> not reported
      #|request: { path: { pattern: ".*" } } -> not reported
      #|request: { headers: { authorization: { $exists: false } } } -> not reported
    ),
  )
}

///|
test "partial overlaps give no warning: a later Stub that a CRUD Stub does not answer for every request it matches, or an override tried before it" {
  inspect(
    crud_warnings(
      (
        #|  - id: orders
        #|    mock: shop
        #|    crud: { bucket: orders, path: /api/v1/orders }
        #|  - id: override-by-priority
        #|    mock: shop
        #|    priority: 1
        #|    request: { method: GET, path: /api/v1/orders/1001 }
        #|    response: { status: 200 }
        #|  - id: any-method
        #|    mock: shop
        #|    request: { path: /api/v1/orders/1001 }
        #|    response: { status: 200 }
        #|  - id: head-on-list
        #|    mock: shop
        #|    request: { method: HEAD, path: /api/v1/orders }
        #|    response: { status: 200 }
        #|  - id: delete-list
        #|    mock: shop
        #|    request: { method: DELETE, path: /api/v1/orders }
        #|    response: { status: 200 }
        #|  - id: post-on-item
        #|    mock: shop
        #|    request: { method: POST, path: /api/v1/orders/1002 }
        #|    response: { status: 200 }
        #|  - id: deeper
        #|    mock: shop
        #|    request: { method: GET, path: /api/v1/orders/1001/items }
        #|    response: { status: 200 }
        #|  - id: trailing-slash
        #|    mock: shop
        #|    request: { method: GET, path: /api/v1/orders/ }
        #|    response: { status: 200 }
        #|  - id: other-case
        #|    mock: shop
        #|    request: { method: GET, path: /API/v1/orders }
        #|    response: { status: 200 }
        #|  - id: lower-case-method
        #|    mock: shop
        #|    request: { method: get, path: /api/v1/orders }
        #|    response: { status: 200 }
        #|  - id: in-other-mock
        #|    mock: other
        #|    request: { method: GET, path: /api/v1/orders/1001 }
        #|    response: { status: 200 }
        #|  - id: by-pattern
        #|    mock: shop
        #|    request: { method: GET, path: { pattern: "/api/v1/orders/[0-9]+" } }
        #|    response: { status: 200 }
      ),
    ),
    content="none",
  )
}
