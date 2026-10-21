// Seam 1 tests of Data buckets read in templates: `data.NAME` gives the
// value of a bucket of the Mock that answers. Every Session reads the
// bucket's initial value.

///|
/// A Mock `shop` with two buckets, one of them from a JSON file, and Stubs
/// that read them; a Mock `users`, the Default Mock, with a bucket of the
/// same name as one of `shop`'s.
let data_files : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - { name: shop, hosts: [shop.example.com] }
      #|data:
      #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      #|  - { mock: shop, name: visits, json: 0 }
      #|stubs:
      #|  - id: list-orders
      #|    mock: shop
      #|    request: { method: GET, path: /api/v1/orders }
      #|    response: { status: 200, template: true, json: "${data.orders}" }
      #|  - id: summary
      #|    mock: shop
      #|    request: { method: GET, path: /api/v1/summary }
      #|    variables: { seen: "${len(data.orders)}" }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      headers: { X-Visits: "${data.visits}" }
      #|      json:
      #|        count: ${len(data.orders)}
      #|        seen: ${vars.seen}
      #|        first: ${data.orders[0].id}
      #|        status: ${data['orders'][2].status}
      #|        paid:
      #|          $each: data.orders
      #|          as: o
      #|          do: { $if: "o.status == 'paid'", then: "${o.id}", else: null }
      #|        missing: ${data.orders[9] ?? 'none'}
      #|  - id: visits
      #|    mock: shop
      #|    request: { method: GET, path: /api/v1/visits }
      #|    response: { status: 200, template: true, body: "visits: ${data.visits}" }
      #|  - id: get-order
      #|    mock: shop
      #|    request: { method: GET, path: { pattern: "/api/v1/orders/[^/]+" } }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: "${find(data.orders, 'id', path[3]) ?? 'no such order'}"
    ),
  ),
  (
    "users.yaml",
    (
      #|mocks:
      #|  - { name: users, hosts: [users.example.com], default: true }
      #|data:
      #|  - { mock: users, name: visits, json: { total: 42 } }
      #|stubs:
      #|  - id: user-visits
      #|    mock: users
      #|    request: { method: GET, path: /api/v1/visits }
      #|    response: { status: 200, template: true, json: "${data.visits}" }
    ),
  ),
]

///|
/// The body files of `data_files`: orders 1001 to 1003.
let data_body_files : Array[(String, Bytes)] = [
  (
    "orders.json",
    @utf8.encode(
      (
        #|[
        #|  { "id": 1001, "customerId": 42, "status": "paid", "total": 12.50 },
        #|  { "id": 1002, "customerId": 7, "status": "pending", "total": 9.90 },
        #|  { "id": 1003, "customerId": 42, "status": "paid", "total": 3 }
        #|]
      ),
    ),
  ),
]

///|
/// Sends `GET target` to `host`, by default without a Session, and gives
/// the response's status, headers and body.
fn Harness::get_from(
  self : Harness,
  host : String,
  target : String,
  session? : String,
) -> String {
  response(self.send("GET", target, headers=[("Host", host)], session?))
}

///|
test "a template reads a whole bucket from its JSON file, as written but in compact JSON" {
  let h = harness(data_files, body_files=data_body_files)
  inspect(
    h.get_from("shop.example.com", "/api/v1/orders"),
    content=(
      #|200
      #|Content-Type: application/json
      #|[{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
    ),
  )
}

///|
test "steps, $each and len read into a bucket, in every template of a Stub and in its Variables" {
  let h = harness(data_files, body_files=data_body_files)
  inspect(
    h.get_from("shop.example.com", "/api/v1/summary", session="test-a") +
    "\n" +
    h.get_from("shop.example.com", "/api/v1/visits"),
    content=(
      #|200
      #|X-Visits: 0
      #|Content-Type: application/json
      #|{"count":3,"seen":3,"first":1001,"status":"paid","paid":[1001,null,1003],"missing":"none"}
      #|200
      #|visits: 0
    ),
  )
}

///|
test "find picks an item of a bucket by its key, compared as text" {
  let h = harness(data_files, body_files=data_body_files)
  inspect(
    h.get_from("shop.example.com", "/api/v1/orders/1002") +
    "\n" +
    h.get_from("shop.example.com", "/api/v1/orders/1004"),
    content=(
      #|200
      #|Content-Type: application/json
      #|{"id":1002,"customerId":7,"status":"pending","total":9.9}
      #|200
      #|Content-Type: application/json
      #|"no such order"
    ),
  )
}

///|
test "each Mock reads its own buckets, and a request that the Default Mock answers reads the Default Mock's" {
  let h = harness(data_files, body_files=data_body_files)
  inspect(
    [
      h.get_from("shop.example.com", "/api/v1/visits"),
      h.get_from("users.example.com", "/api/v1/visits"),
      h.get_from("unknown.example.com", "/api/v1/visits"),
    ].join("\n"),
    content=(
      #|200
      #|visits: 0
      #|200
      #|Content-Type: application/json
      #|{"total":42}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: users; via=default
      #|{"total":42}
    ),
  )
}

///|
/// Adds the Ephemeral Stub `stub`, given as JSON text, to `shop` for the
/// Session `test-a`: its ID, or each problem on a line of its own.
fn Harness::add_to_shop(self : Harness, stub : String) -> String raise {
  let stub = @json.parse(stub)
  let added = self.engine.add_ephemeral_stub(
    mock="shop",
    session=Some("test-a"),
    stub,
  ) catch {
    InvalidStub(problems) =>
      return problems.map(problem => problem.to_string()).join("\n")
    err => fail(@debug.to_string(err))
  }
  added.id
}

///|
test "an Ephemeral Stub reads its Mock's buckets, and names only those" {
  let h = harness(data_files, body_files=data_body_files)
  let add = (stub : String) => h.add_to_shop(stub)
  inspect(
    [
      add(
        (
          #|{ "request": { "path": "/api/v1/count" },
          #|  "response": { "status": 200, "template": true,
          #|    "body": "${len(data.orders)} orders, ${data.visits} visits" } }
        ),
      ),
      add(
        (
          #|{ "request": { "path": "/api/v1/count" },
          #|  "variables": { "a": "${data.order}" },
          #|  "response": { "status": 200, "template": true,
          #|    "json": { "a": "${data}", "b": { "$each": "data.orders", "as": "data", "do": 1 } } } }
        ),
      ),
      h.get_from("shop.example.com", "/api/v1/count", session="test-a"),
    ].join("\n"),
    content=(
      #|eph-1
      #|/variables/a: template: column 3: data.order: the Mock has no Data bucket "order"
      #|/response/json/a: template: column 3: data: data takes the name of a Data bucket first, such as data.orders or data.orders[0].id
      #|/response/json/b/as: template: "data" cannot be a loop variable: it is a request field, env, vars, data, loop or a reserved word
      #|200
      #|3 orders, 0 visits
    ),
  )
}

///|
test "a reload with a broken bucket keeps the set served; after a reload removes a bucket, an Ephemeral Stub's reads of it are missing, so ?? applies" {
  let h = harness(data_files, body_files=data_body_files)
  let _ = h.engine.add_ephemeral_stub(
    mock="shop",
    session=None,
    @json.parse(
      (
        #|{ "request": { "path": "/api/v1/count" },
        #|  "response": { "status": 200, "template": true,
        #|    "body": "${len(data.orders) ?? 0} orders, ${data.visits ?? 'no'} visits" } }
      ),
    ),
  )
  let reload = (files : Array[(String, String)], body_files) => {
    let result = h.engine.reload(
      { files: files.map(f => (f.0, @utf8.encode(f.1))), body_files, },
      at=fixed_now,
    )
    @debug.to_string(result.result)
  }
  let out = [h.get_from("shop.example.com", "/api/v1/count")]
  // A bucket that breaks its rules fails the reload, which keeps the set
  // it serves.
  out.push(
    reload(data_files, [("orders.json", b"[{\"id\": 1}, {\"id\": \"1\"}]")]),
  )
  out.push(
    h.engine.status().last_reload.map_or("", reload => {
      reload.errors.map(e => e.to_string()).join("\n")
    }),
  )
  out.push(h.get_from("shop.example.com", "/api/v1/count"))
  // `visits` gone, and `orders` changed in its file.
  let without_visits = [
    (
      "shop.yaml",
      (
        #|mocks:
        #|  - { name: shop, hosts: [shop.example.com] }
        #|data:
        #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      ),
    ),
  ]
  out.push(
    reload(without_visits, [("orders.json", b"[{\"id\": 1}, {\"id\": 2}]")]),
  )
  out.push(h.get_from("shop.example.com", "/api/v1/count"))
  out.push(
    reload(
      [("shop.yaml", "mocks: [{ name: shop, hosts: [shop.example.com] }]")],
      [],
    ),
  )
  out.push(h.get_from("shop.example.com", "/api/v1/count"))
  inspect(
    out.join("\n"),
    content=(
      #|200
      #|3 orders, 0 visits
      #|Failed
      #|shop.yaml: /data/0/jsonFile: "orders.json" at /1/id: has the key text "1", as item 0 does
      #|200
      #|3 orders, 0 visits
      #|Swapped
      #|200
      #|2 orders, no visits
      #|Swapped
      #|200
      #|0 orders, no visits
    ),
  )
}

///|
test "rendering a Stub reads each bucket's initial value" {
  let h = harness(data_files, body_files=data_body_files)
  let rendering = h.engine.render(
    "summary",
    @engine.SampleRequest::from_json({ "path": "/api/v1/summary" }),
    now=h.now,
    fresh_seed=() => 7,
  )
  inspect(
    rendering.to_json().stringify(indent=2),
    content=(
      #|{
      #|  "stub": "summary",
      #|  "mock": "shop",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {
      #|    "seen": 3
      #|  },
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "X-Visits",
      #|        "value": "0"
      #|      },
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"count\":3,\"seen\":3,\"first\":1001,\"status\":\"paid\",\"paid\":[1001,null,1003],\"missing\":\"none\"}",
      #|      "size": 90,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
}
