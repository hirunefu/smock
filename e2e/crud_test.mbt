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
