// Seam 1 tests of the Near miss of a CRUD Stub: it counts two conditions,
// `method` and `path`, and expects its path or the methods it serves.

///|
test "the ticket's example: with only the CRUD Stub, HEAD on its list path gets the no-match answer with Smock-Near-Miss: orders; failed=method, and the Near miss expects the list's methods" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let outcome = h.shop("HEAD", "/api/v1/orders")
  inspect(
    response(outcome),
    content=(
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: orders; failed=method
      #|{"error":"no Stub matched"}
    ),
  )
  guard outcome.near_miss is Some(near_miss) else { fail("no Near miss") }
  json_inspect(near_miss, content={
    "stub": "orders",
    "stubSource": "file",
    "failed": [
      {
        "condition": "method",
        "expected": { "crud": ["GET", "POST"] },
        "actual": ["HEAD"],
      },
    ],
  })
}

///|
/// The Near miss of each request to `shop.example.com`, as its
/// `Smock-Near-Miss` header and its JSON form, or `none`.
fn shop_near_misses(h : Harness, requests : Array[(String, String)]) -> Json {
  Json::array(
    requests.map(request => {
      let (meth, target) = request
      let outcome = h.shop(meth, target)
      let header = outcome.plan.headers
        .iter()
        .filter(h => h.0 == "Smock-Near-Miss")
        .map(h => Json::string(h.1))
        .collect()
      {
        "request": Json::string("\{meth} \{target}"),
        "header": Json::array(header),
        "nearMiss": match outcome.near_miss {
          Some(near_miss) => near_miss.to_json()
          None => Json::string("none")
        },
      }
    }),
  )
}

///|
test "a CRUD Stub fails method when it does not serve the method at the path's shape, and path when the path is neither its list path nor an item path; the method is then judged at either shape" {
  let h = harness(crud_shop(), body_files=data_body_files)
  json_inspect(
    shop_near_misses(h, [
      ("POST", "/api/v1/orders/1001"),
      ("PUT", "/api/v1/orders"),
      ("GET", "/api/v1/customers"),
      ("GET", "/api/v1/orders/1001/items"),
      ("HEAD", "/api/v1/orders/1001/items"),
      ("DELETE", "/api/v1/orders/"),
      ("GET", "/api/v1/orders/a%2Fb"),
      ("get", "/API/v1/orders"),
    ]),
    content=[
      {
        "request": "POST /api/v1/orders/1001",
        "header": ["orders; failed=method"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "method",
              "expected": { "crud": ["GET", "PUT", "PATCH", "DELETE"] },
              "actual": ["POST"],
            },
          ],
        },
      },
      {
        "request": "PUT /api/v1/orders",
        "header": ["orders; failed=method"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "method",
              "expected": { "crud": ["GET", "POST"] },
              "actual": ["PUT"],
            },
          ],
        },
      },
      {
        "request": "GET /api/v1/customers",
        "header": ["orders; failed=path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/api/v1/customers"],
            },
          ],
        },
      },
      {
        "request": "GET /api/v1/orders/1001/items",
        "header": ["orders; failed=path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/api/v1/orders/1001/items"],
            },
          ],
        },
      },
      {
        "request": "HEAD /api/v1/orders/1001/items",
        "header": ["orders; failed=method,path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "method",
              "expected": { "crud": ["GET", "POST", "PUT", "PATCH", "DELETE"] },
              "actual": ["HEAD"],
            },
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/api/v1/orders/1001/items"],
            },
          ],
        },
      },
      {
        "request": "DELETE /api/v1/orders/",
        "header": ["orders; failed=path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/api/v1/orders/"],
            },
          ],
        },
      },
      {
        "request": "GET /api/v1/orders/a%2Fb",
        "header": ["orders; failed=path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/api/v1/orders/a/b"],
            },
          ],
        },
      },
      {
        "request": "get /API/v1/orders",
        "header": ["orders; failed=method,path"],
        "nearMiss": {
          "stub": "orders",
          "stubSource": "file",
          "failed": [
            {
              "condition": "method",
              "expected": { "crud": ["GET", "POST", "PUT", "PATCH", "DELETE"] },
              "actual": ["get"],
            },
            {
              "condition": "path",
              "expected": { "crud": "/api/v1/orders" },
              "actual": ["/API/v1/orders"],
            },
          ],
        },
      },
    ],
  )
}

///|
test "a CRUD Stub and an ordinary Stub compete as any candidates do: the fewest failed conditions, the earlier one in matching order on a tie" {
  let h = harness(
    crud_shop(
      stubs=(
        #|  - id: pay
        #|    mock: shop
        #|    request: { method: POST, path: /api/v1/orders/1001/pay }
        #|    response: { status: 200 }
        #|  - id: first-get-customers
        #|    mock: shop
        #|    priority: 1
        #|    request: { method: GET, path: /api/v1/customers }
        #|    response: { status: 200 }
      ),
    ),
    body_files=data_body_files,
  )
  let lines = []
  for
    request in [
      ("HEAD", "/api/v1/orders/1001/pay"),
      ("POST", "/api/v1/orders/1001/cancel"),
      ("POST", "/api/v1/customers"),
      ("HEAD", "/api/v1/orders"),
    ] {
    let (meth, target) = request
    let outcome = h.shop(meth, target)
    let header = outcome.plan.headers
      .iter()
      .filter(h => h.0 == "Smock-Near-Miss")
      .map(h => h.1)
      .collect()
    lines.push("\{meth} \{target} -> \{header.join(", ")}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|HEAD /api/v1/orders/1001/pay -> pay; failed=method
      #|POST /api/v1/orders/1001/cancel -> orders; failed=path
      #|POST /api/v1/customers -> first-get-customers; failed=method
      #|HEAD /api/v1/orders -> orders; failed=method
    ),
  )
}

///|
test "the Journal's unmatched listing shows the same Near miss of a CRUD Stub, and an Ephemeral CRUD Stub of the Session is a candidate before the file Stubs" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let _ = h.add_to_shop(
    (
      #|{ "crud": { "bucket": "orders", "path": "/mine" } }
    ),
  )
  // PATCH on the list ties: the Ephemeral Stub fails only its path, the
  // file Stub only its method, and the Ephemeral Stub is tried first.
  let sent = [
    h.shop("HEAD", "/api/v1/orders", session="test-a"),
    h.shop("PATCH", "/api/v1/orders", session="test-a"),
    h.shop("POST", "/mine/1001", session="test-a"),
  ]
  let headers = []
  for outcome in sent {
    guard outcome.journal is Some(entry) else { fail("no Journal entry") }
    h.engine.commit(entry)
    entry.finish(at=h.now + 1)
    for header in outcome.plan.headers {
      if header.0 == "Smock-Near-Miss" {
        headers.push(header.1)
      }
    }
  }
  inspect(
    headers.join("\n"),
    content=(
      #|orders; failed=method
      #|eph-1; failed=path
      #|eph-1; failed=method
    ),
  )
  guard h.unmatched(Some("test-a")) is Object({ "entries": Array(entries), .. }) else {
    fail("no entries")
  }
  let listed = entries.map(entry => {
    guard entry is Object({ "nearMiss": near_miss, .. }) else {
      fail("no nearMiss")
    }
    near_miss
  })
  let engine = sent.map(outcome => {
    guard outcome.near_miss is Some(near_miss) else { fail("no Near miss") }
    near_miss.to_json()
  })
  inspect(listed == engine, content="true")
  json_inspect(listed, content=[
    {
      "stub": "orders",
      "stubSource": "file",
      "failed": [
        {
          "condition": "method",
          "expected": { "crud": ["GET", "POST"] },
          "actual": ["HEAD"],
        },
      ],
    },
    {
      "stub": "eph-1",
      "stubSource": "ephemeral",
      "failed": [
        {
          "condition": "path",
          "expected": { "crud": "/mine" },
          "actual": ["/api/v1/orders"],
        },
      ],
    },
    {
      "stub": "eph-1",
      "stubSource": "ephemeral",
      "failed": [
        {
          "condition": "method",
          "expected": { "crud": ["GET", "PUT", "PATCH", "DELETE"] },
          "actual": ["POST"],
        },
      ],
    },
  ])
}
