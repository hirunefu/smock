// Seam 2 tests of CRUD Stubs over real sockets: a Stub with `crud` serves a
// keyed Data bucket, and its `crud.headers` go out on every answer.

///|
async test "a browser's cross-origin list and read of a CRUD Stub get the CORS headers of crud.headers, its 404 too, and the counts it exposes" {
  let defs =
    #|mocks:
    #|  - name: shop
    #|data:
    #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
    #|stubs:
    #|  - id: orders
    #|    mock: shop
    #|    crud:
    #|      bucket: orders
    #|      path: /api/v1/orders
    #|      headers:
    #|        Access-Control-Allow-Origin: "*"
    #|        Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
  let orders =
    #|[{ "id": 1001, "status": "paid", "total": 12.50 },
    #| { "id": 1002, "status": "pending", "total": 9.90 }]
  with_definitions([("shop.yaml", defs), ("files/orders.json", orders)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let origin = [("Origin", "http://localhost:5173")]
      inspect(
        [
          smock.send("GET", "/api/v1/orders", headers=origin),
          smock.send("GET", "/api/v1/orders/1002", headers=origin),
          smock.send("GET", "/api/v1/orders/9999", headers=origin),
        ].join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Total-Count: 2
          #|X-Filtered-Count: 2
          #|Access-Control-Allow-Origin: *
          #|Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
          #|Smock-Mock: shop; via=default
          #|Content-Length: 85
          #|
          #|[{"id":1001,"status":"paid","total":12.5},{"id":1002,"status":"pending","total":9.9}]
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Access-Control-Allow-Origin: *
          #|Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
          #|Smock-Mock: shop; via=default
          #|Content-Length: 42
          #|
          #|{"id":1002,"status":"pending","total":9.9}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Access-Control-Allow-Origin: *
          #|Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
          #|Smock-Mock: shop; via=default
          #|Content-Length: 62
          #|
          #|{"error":"no item with this key","stub":"orders","key":"9999"}
        ),
      )
    })
  })
}

///|
async test "smock render and the Admin render operation refuse a CRUD Stub for now" {
  let defs =
    #|mocks:
    #|  - name: shop
    #|data:
    #|  - { mock: shop, name: orders, key: id, json: [{ id: 1 }] }
    #|stubs:
    #|  - id: orders
    #|    mock: shop
    #|    crud: { bucket: orders, path: /api/v1/orders }
  let sample =
    #|{ "path": "/api/v1/orders" }
  with_definitions([("shop.yaml", defs), ("samples/orders.json", sample)], dir => {
    let cli = render([
      "--dir",
      dir,
      "orders",
      "--request",
      "\{dir}/samples/orders.json",
    ])
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let admin = smock.render("orders", body=sample)
      inspect(
        "\{cli}---\n\{admin.status} \{admin.body}",
        content=(
          #|status 1
          #|stderr:
          #|smock render: the Stub "orders" is a CRUD Stub, and smock cannot render CRUD Stubs yet
          #|---
          #|400 {"error":"invalid_request","message":"the Stub \"orders\" is a CRUD Stub, and smock cannot render CRUD Stubs yet","warnings":[]}
        ),
      )
    })
  })
}

///|
/// The spec's example: the Mock `shop`, whose bucket `orders`, keyed by
/// `id`, starts with orders 1001 to 1003 from `files/orders.json`; the CRUD
/// Stub `orders` serves it under `/api/v1/orders`, and `pay-order` marks an
/// order paid with `dataWrites` and answers it with `find`.
let shop_example : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - name: shop
      #|data:
      #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      #|stubs:
      #|  - id: orders
      #|    mock: shop
      #|    crud:
      #|      bucket: orders
      #|      path: /api/v1/orders
      #|      headers: { Access-Control-Allow-Origin: "*" }
      #|  - id: pay-order
      #|    mock: shop
      #|    request: { method: POST, path: { pattern: "/api/v1/orders/[^/]+/pay" } }
      #|    dataWrites:
      #|      - { op: merge, bucket: orders, key: "${path[3]}", value: { status: paid, paidAt: "${now()}" } }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: "${find(data.orders, 'id', path[3])}"
    ),
  ),
  (
    "files/orders.json",
    (
      #|[{ "id": 1001, "customerId": 7, "status": "paid", "total": 12.50 },
      #| { "id": 1002, "customerId": 42, "status": "pending", "total": 9.90 },
      #| { "id": 1003, "customerId": 42, "status": "pending", "total": 30 }]
    ),
  ),
]

///|
/// `text` with each `"paidAt"` that holds a time as `now()` writes it, RFC
/// 3339 in UTC with milliseconds, shown as `<now()>`.
fn masked_now(text : String) -> String raise {
  let time = @re2.compile(
    "\"paidAt\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\"",
  )
  let out = StringBuilder()
  let mut rest = text
  while time.search(@utf8.encode(rest)) is Some({ start, end, }) {
    // The text is ASCII, so byte offsets are character offsets.
    out.write_string(rest[:start].to_owned())
    out.write_string("\"paidAt\":\"<now()>\"")
    rest = rest[end:].to_owned()
  }
  out.write_string(rest)
  out.to_string()
}

///|
async test "the spec's example over real sockets: a Session creates an order, lists it first among the pending ones, pays it, and another Session still lists the three orders of orders.json, with each operation in the Journal" {
  with_definitions(shop_example, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let json = ("Content-Type", "application/json")
      let created = smock.send(
        "POST",
        "/api/v1/orders",
        headers=[json, baggage("test-a")],
        body="{\"customerId\":42,\"status\":\"pending\"}",
      )
      let listed = smock.send(
        "GET",
        "/api/v1/orders?status=pending&$sort=-id&$limit=10",
        headers=[baggage("test-a")],
      )
      let paid = smock.send("POST", "/api/v1/orders/1004/pay", headers=[
        baggage("test-a"),
      ])
      let other = smock.send("GET", "/api/v1/orders", headers=[
        baggage("test-b"),
      ])
      inspect(
        masked_now([created, listed, paid, other].join("\n---\n")),
        content=(
          #|HTTP/1.1 201 Created
          #|Content-Type: application/json
          #|Location: /api/v1/orders/1004
          #|Access-Control-Allow-Origin: *
          #|Smock-Mock: shop; via=default
          #|Content-Length: 46
          #|
          #|{"customerId":42,"status":"pending","id":1004}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Total-Count: 4
          #|X-Filtered-Count: 3
          #|Access-Control-Allow-Origin: *
          #|Smock-Mock: shop; via=default
          #|Content-Length: 165
          #|
          #|[{"customerId":42,"status":"pending","id":1004},{"id":1003,"customerId":42,"status":"pending","total":30},{"id":1002,"customerId":42,"status":"pending","total":9.9}]
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Content-Length: 79
          #|
          #|{"customerId":42,"status":"paid","id":1004,"paidAt":"<now()>"}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Total-Count: 3
          #|X-Filtered-Count: 3
          #|Access-Control-Allow-Origin: *
          #|Smock-Mock: shop; via=default
          #|Content-Length: 174
          #|
          #|[{"id":1001,"customerId":7,"status":"paid","total":12.5},{"id":1002,"customerId":42,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"pending","total":30}]
        ),
      )
      // Each request's Journal entry: what it asked, the Stub that
      // answered, its CRUD operation and key, and the buckets it wrote.
      let entries = []
      for session in ["test-a", "test-b"] {
        guard smock.journal(session~)
          is (200, Object({ "entries": Array(found), .. })) else {
          fail("the Journal query as \{session} failed")
        }
        for entry in found {
          guard entry
            is Object(
              {
                "request": Object({ "method": meth, "target": target, .. }),
                "stub": stub,
                "status": status,
                "crud": crud,
                "dataWritten": written,
                "dataError": error,
                ..
              }
            ) else {
            fail("an entry lacks a member: \{entry.stringify()}")
          }
          let shown : Json = {
            "session": session.to_json(),
            "method": meth,
            "target": target,
            "stub": stub,
            "status": status,
            "crud": crud,
            "dataWritten": written,
            "dataError": error,
          }
          entries.push(shown.stringify())
        }
      }
      inspect(
        entries.join("\n"),
        content=(
          #|{"session":"test-a","method":"POST","target":"/api/v1/orders","stub":"orders","status":201,"crud":{"op":"create","key":"1004"},"dataWritten":["orders"],"dataError":null}
          #|{"session":"test-a","method":"GET","target":"/api/v1/orders?status=pending&$sort=-id&$limit=10","stub":"orders","status":200,"crud":{"op":"list","key":null},"dataWritten":[],"dataError":null}
          #|{"session":"test-a","method":"POST","target":"/api/v1/orders/1004/pay","stub":"pay-order","status":200,"crud":null,"dataWritten":["orders"],"dataError":null}
          #|{"session":"test-b","method":"GET","target":"/api/v1/orders","stub":"orders","status":200,"crud":{"op":"list","key":null},"dataWritten":[],"dataError":null}
        ),
      )
    })
  })
}
