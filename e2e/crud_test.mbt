// Seam 2 tests of CRUD Stubs over real sockets: a Stub with `crud` serves a
// keyed Data bucket, and its `crud.headers` go out on every answer.
// `smock render` and the Admin render operation render its answers.

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
async test "smock render and the Admin render operation agree on a CRUD Stub's answer and write, and a sample that fits no operation makes smock render fail and the Admin render answer 400 invalid_request" {
  let defs =
    #|mocks:
    #|  - name: shop
    #|data:
    #|  - { mock: shop, name: orders, key: id, json: [{ id: 1, status: pending }, { id: 2, status: paid }] }
    #|stubs:
    #|  - id: orders
    #|    mock: shop
    #|    crud: { bucket: orders, path: /api/v1/orders, headers: { Access-Control-Allow-Origin: "*" } }
  let list =
    #|{ "path": "/api/v1/orders", "query": { "status": "pending" } }
  let create =
    #|{ "method": "POST", "path": "/api/v1/orders", "body": "{\"status\":\"new\"}",
    #|  "data": { "orders": [{ "id": 7, "status": "paid" }] } }
  let none =
    #|{ "method": "DELETE", "path": "/api/v1/orders" }
  with_definitions(
    [
      ("shop.yaml", defs),
      ("samples/list.json", list),
      ("samples/create.json", create),
      ("samples/none.json", none),
    ],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let out = []
        for sample in ["list", "create"] {
          let file = "\{dir}/samples/\{sample}.json"
          let (status, stdout, stderr) = render_output([
            "--dir", dir, "orders", "--request", file,
          ])
          let response = smock.render("orders", sample=file)
          let from_cli = with_data_writes(@json.parse(stdout))
          let from_admin = with_data_writes(response.json())
          out.push(
            "\{sample}: render \{status}, admin \{response.status}, same: \{from_cli == from_admin}\{stderr}",
          )
          out.push("  \{from_cli}")
        }
        let file = "\{dir}/samples/none.json"
        out.push(
          render(["--dir", dir, "orders", "--request", file])
          .trim_end(chars="\n")
          .to_owned(),
        )
        let response = smock.render("orders", sample=file)
        out.push("admin: \{response.status} \{response.body}")
        inspect(
          out.join("\n"),
          content=(
            #|list: render 0, admin 200, same: true
            #|  {"dataWrites":[],"response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"X-Total-Count","value":"2"},{"name":"X-Filtered-Count","value":"1"},{"name":"Access-Control-Allow-Origin","value":"*"}],"body":{"encoding":"utf-8","data":"[{\"id\":1,\"status\":\"pending\"}]","size":29,"truncated":false},"events":null},"templateError":null}
            #|create: render 0, admin 200, same: true
            #|  {"dataWrites":[{"op":"append","bucket":"orders","key":null,"value":{"status":"new","id":8}}],"response":{"status":201,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Location","value":"/api/v1/orders/8"},{"name":"Access-Control-Allow-Origin","value":"*"}],"body":{"encoding":"utf-8","data":"{\"status\":\"new\",\"id\":8}","size":23,"truncated":false},"events":null},"templateError":null}
            #|status 1
            #|stderr:
            #|smock render: the CRUD Stub "orders" serves no operation for "DELETE" at "/api/v1/orders": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
            #|admin: 400 {"error":"invalid_request","message":"the CRUD Stub \"orders\" serves no operation for \"DELETE\" at \"/api/v1/orders\": it serves GET and POST at \"/api/v1/orders\", and GET, PUT, PATCH and DELETE at \"/api/v1/orders/<key>\"","warnings":[]}
          ),
        )
      })
    },
  )
}

///|
async test "smock check warns about an override placed after a CRUD Stub and still exits 0; over HTTP, a request the CRUD Stub does not serve gets its Near miss, which the Journal shows" {
  let defs =
    #|mocks:
    #|  - name: shop
    #|data:
    #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
    #|stubs:
    #|  - id: orders
    #|    mock: shop
    #|    crud: { bucket: orders, path: /api/v1/orders }
    #|  - id: order-1001
    #|    mock: shop
    #|    request: { method: GET, path: /api/v1/orders/1001 }
    #|    response: { status: 200, json: { id: 1001, overridden: true } }
  let orders =
    #|[{ "id": 1001, "status": "paid" }]
  with_definitions([("shop.yaml", defs), ("files/orders.json", orders)], dir => {
    inspect(
      check([dir]),
      content=(
        #|status 0
        #|shop.yaml: /stubs/1: warning: the Stub "order-1001" can never match: the Stub "orders" at shop.yaml: /stubs/0 is tried first and matches every request this one would
        #|
      ),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("crud-near-miss")
      inspect(
        smock.send("PATCH", "/api/v1/orders", headers=[session]),
        content=(
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Smock-Near-Miss: orders; failed=method
          #|Smock-Mock: shop; via=default
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let unmatched = smock.admin("GET", "/v1/journal/unmatched", headers=[
        session,
      ])
      inspect(unmatched.status, content="200")
      guard unmatched.json()
        is Object({ "entries": [Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not one entry with a Near miss: \{unmatched.body}")
      }
      json_inspect(near_miss, content={
        "stub": "orders",
        "stubSource": "file",
        "failed": [
          {
            "condition": "method",
            "expected": { "crud": ["GET", "POST"] },
            "actual": ["PATCH"],
          },
        ],
      })
    })
  })
}
