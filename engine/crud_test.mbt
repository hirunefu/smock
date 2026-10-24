// Seam 1 tests of CRUD Stubs: a Stub with `crud` serves a keyed Data
// bucket as a REST resource. It lists the bucket at its path, and reads one
// item at the path plus the item's key.

///|
/// The ticket's example: the Mock `shop`, at the Host `shop.example.com`,
/// with the bucket `orders`, keyed by `id`, from `orders.json`
/// (`data_body_files`), and the CRUD Stub `orders` with a CORS header; then
/// `stubs`, given as YAML list items, after it in the same file.
fn crud_shop(stubs~ : String = "") -> Array[(String, String)] {
  [
    (
      "shop.yaml",
      (
        $|mocks:
        $|  - { name: shop, hosts: [shop.example.com] }
        $|data:
        $|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
        $|  - { mock: shop, name: visits, json: 0 }
        $|stubs:
        $|  - id: orders
        $|    mock: shop
        $|    crud:
        $|      bucket: orders
        $|      path: /api/v1/orders
        $|      headers: { Access-Control-Allow-Origin: "*" }
        $|\{stubs}
      ),
    ),
  ]
}

///|
/// Sends `meth target` to `shop.example.com`, by default without a body
/// or a Session, and returns the outcome.
fn Harness::shop(
  self : Harness,
  meth : String,
  target : String,
  headers~ : Array[(String, String)] = [],
  body~ : String = "",
  session? : String,
) -> @engine.Outcome {
  self.send(
    meth,
    target,
    headers=[("Host", "shop.example.com"), ..headers],
    body~,
    session?,
  )
}

///|
test "a CRUD Stub lists its bucket at its path and reads an item at the path plus its key, whatever the request body, and a missing item is its own 404" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    [
      response(h.shop("GET", "/api/v1/orders", body="[]")),
      response(h.shop("GET", "/api/v1/orders/1002", body="{not JSON")),
      response(h.shop("GET", "/api/v1/orders/9999")),
    ].join("\n---\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|X-Total-Count: 3
      #|X-Filtered-Count: 3
      #|Access-Control-Allow-Origin: *
      #|[{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|---
      #|200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"id":1002,"customerId":7,"status":"pending","total":9.9}
      #|---
      #|404
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"no item with this key","stub":"orders","key":"9999"}
    ),
  )
}

///|
test "a CRUD Stub matches GET and POST at its path, and GET, PUT, PATCH and DELETE at an item path; other methods and path shapes fall through to later Stubs, then to the Mock's no-match answer" {
  let h = harness(
    crud_shop(
      stubs=(
        #|  - id: anything-under-orders
        #|    mock: shop
        #|    request: { path: { pattern: "/api/v1/orders.*" } }
        #|    response: { status: 299, body: later }
      ),
    ),
    body_files=data_body_files,
  )
  let without_later = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    request in [
      ("GET", "/api/v1/orders"),
      ("GET", "/api/v1/orders?status=paid"),
      ("GET", "/api/v1/orders/1001"),
      ("GET", "/api/v1/orders/1001?x=1"),
      ("GET", "/api/v1/orders/%31%30%30%31"),
      ("HEAD", "/api/v1/orders"),
      ("OPTIONS", "/api/v1/orders/1001"),
      ("get", "/api/v1/orders"),
      ("POST", "/api/v1/orders"),
      ("PUT", "/api/v1/orders"),
      ("PATCH", "/api/v1/orders"),
      ("DELETE", "/api/v1/orders"),
      ("POST", "/api/v1/orders/1001"),
      ("PUT", "/api/v1/orders/1001"),
      ("PATCH", "/api/v1/orders/1001"),
      ("DELETE", "/api/v1/orders/1001"),
      ("GET", "/api/v1/orders/"),
      ("GET", "/api/v1/orders//"),
      ("GET", "/api/v1/orders/1001/"),
      ("GET", "/api/v1/orders/1001/items"),
      ("GET", "/api/v1/orders/a%2Fb"),
      ("GET", "/API/v1/orders"),
      ("GET", "/api/v1/ordersx"),
    ] {
    let (meth, target) = request
    let first = h.shop(meth, target)
    let alone = without_later.shop(meth, target)
    out.push(
      "\{meth} \{target}: \{first.plan.status} \{@debug.to_string(matched_id(first))}; alone: \{alone.plan.status} \{@debug.to_string(matched_id(alone))}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|GET /api/v1/orders: 200 Some("orders"); alone: 200 Some("orders")
      #|GET /api/v1/orders?status=paid: 200 Some("orders"); alone: 200 Some("orders")
      #|GET /api/v1/orders/1001: 200 Some("orders"); alone: 200 Some("orders")
      #|GET /api/v1/orders/1001?x=1: 200 Some("orders"); alone: 200 Some("orders")
      #|GET /api/v1/orders/%31%30%30%31: 200 Some("orders"); alone: 200 Some("orders")
      #|HEAD /api/v1/orders: 299 Some("anything-under-orders"); alone: 404 None
      #|OPTIONS /api/v1/orders/1001: 299 Some("anything-under-orders"); alone: 404 None
      #|get /api/v1/orders: 299 Some("anything-under-orders"); alone: 404 None
      #|POST /api/v1/orders: 400 Some("orders"); alone: 400 Some("orders")
      #|PUT /api/v1/orders: 299 Some("anything-under-orders"); alone: 404 None
      #|PATCH /api/v1/orders: 299 Some("anything-under-orders"); alone: 404 None
      #|DELETE /api/v1/orders: 299 Some("anything-under-orders"); alone: 404 None
      #|POST /api/v1/orders/1001: 299 Some("anything-under-orders"); alone: 404 None
      #|PUT /api/v1/orders/1001: 400 Some("orders"); alone: 400 Some("orders")
      #|PATCH /api/v1/orders/1001: 400 Some("orders"); alone: 400 Some("orders")
      #|DELETE /api/v1/orders/1001: 200 Some("orders"); alone: 200 Some("orders")
      #|GET /api/v1/orders/: 299 Some("anything-under-orders"); alone: 404 None
      #|GET /api/v1/orders//: 299 Some("anything-under-orders"); alone: 404 None
      #|GET /api/v1/orders/1001/: 299 Some("anything-under-orders"); alone: 404 None
      #|GET /api/v1/orders/1001/items: 299 Some("anything-under-orders"); alone: 404 None
      #|GET /api/v1/orders/a%2Fb: 299 Some("anything-under-orders"); alone: 404 None
      #|GET /API/v1/orders: 404 None; alone: 404 None
      #|GET /api/v1/ordersx: 299 Some("anything-under-orders"); alone: 404 None
    ),
  )
}

///|
test "an earlier Stub takes over a CRUD Stub's requests: by its place or its priority, with conditions, or in a Scenario state" {
  let h = harness(
    [
      (
        "a.yaml",
        (
          #|stubs:
          #|  - id: no-token
          #|    mock: shop
          #|    request: { headers: { authorization: { $exists: false } } }
          #|    response: { status: 401, json: { error: unauthorized } }
          #|  - id: down
          #|    mock: shop
          #|    scenario: { name: orders, requires: Down }
          #|    request: { path: { pattern: "/api/v1/orders.*" } }
          #|    response: { status: 503 }
          #|  - id: go-down
          #|    mock: shop
          #|    scenario: { name: orders, moveTo: Down }
          #|    request: { method: POST, path: /down }
          #|    response: { status: 204 }
        ),
      ),
      ..crud_shop(
        stubs=(
          #|  - id: special-order
          #|    mock: shop
          #|    priority: 1
          #|    request: { method: GET, path: /api/v1/orders/1003 }
          #|    response: { status: 200, json: { special: true } }
        ),
      ),
    ],
    body_files=data_body_files,
  )
  let token = [("Authorization", "Bearer t")]
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push(
      "\{label}: \{@debug.to_string(matched_id(outcome))} \{reply(outcome)}",
    )
  }
  step("without a token", h.shop("GET", "/api/v1/orders/1001"))
  step(
    "with a token",
    h.shop("GET", "/api/v1/orders/1001", headers=token, session="s"),
  )
  step(
    "priority 1",
    h.shop("GET", "/api/v1/orders/1003", headers=token, session="s"),
  )
  step("move to Down", h.shop("POST", "/down", headers=token, session="s"))
  step(
    "while Down",
    h.shop("GET", "/api/v1/orders/1001", headers=token, session="s"),
  )
  step(
    "another Session",
    h.shop("GET", "/api/v1/orders/1001", headers=token, session="t"),
  )
  inspect(
    out.join("\n"),
    content=(
      #|without a token: Some("no-token") 401 {"error":"unauthorized"}
      #|with a token: Some("orders") 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|priority 1: Some("special-order") 200 {"special":true}
      #|move to Down: Some("go-down") 204 
      #|while Down: Some("down") 503 
      #|another Session: Some("orders") 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}
    ),
  )
}

///|
/// The members of `outcome`'s Journal entry that say how its Stub answered,
/// as compact JSON.
fn answered(outcome : @engine.Outcome) -> String raise {
  guard outcome.journal is Some(entry) else { fail("no Journal entry") }
  guard entry.to_json() is Object(members) else { fail("not an object") }
  let shown : Map[String, Json] = Map([])
  for
    name in [
      "stub", "stubSource", "status", "responseIndex", "crud", "variablesWritten",
      "dataWritten", "dataError", "nearMiss",
    ] {
    shown[name] = members[name]
  }
  Json::object(shown).stringify()
}

///|
test "the Journal records the CRUD operation and its key: a list with a null key, a read with the item path's key, whatever the outcome" {
  let h = harness(
    crud_shop(
      stubs=(
        #|  - id: other
        #|    mock: shop
        #|    request: { method: GET, path: /other }
        #|    response: { status: 200 }
      ),
    ),
    body_files=data_body_files,
  )
  inspect(
    [
      answered(h.shop("GET", "/api/v1/orders?status=paid")),
      answered(h.shop("GET", "/api/v1/orders/1002")),
      answered(h.shop("GET", "/api/v1/orders/a%20b")),
      answered(h.shop("GET", "/other")),
      answered(h.shop("HEAD", "/api/v1/orders")),
    ].join("\n"),
    content=(
      #|{"stub":"orders","stubSource":"file","status":200,"responseIndex":null,"crud":{"op":"list","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":200,"responseIndex":null,"crud":{"op":"read","key":"1002"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":404,"responseIndex":null,"crud":{"op":"read","key":"a b"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"other","stubSource":"file","status":200,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":null,"stubSource":null,"status":404,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"orders","stubSource":"file","failed":[{"condition":"method","expected":{"crud":["GET","POST"]},"actual":["HEAD"]}]}}
    ),
  )
}

///|
test "an entry's crud counts toward its bytes, two for each UTF-16 code unit of the operation and the key" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let headers = [("Host", "shop.example.com")]
  // GET, /api/v1/orders, HTTP/1.1, Host, shop.example.com, the Host
  // shop.example.com, the Mock shop and the Stub orders hold 71 code
  // units, and list 4 more: 256 + 2 * 75 bytes.
  let _ = h.record("GET", "/api/v1/orders", headers~)
  let list = h.stats()
  // The target has 5 code units more, and read 1002 holds 8: 256 + 2 * 84
  // bytes.
  let _ = h.record("GET", "/api/v1/orders/1002", headers~)
  inspect(
    "\{list}\n\{h.stats()}",
    content=(
      #|1 entries, 406 bytes, 0 evicted
      #|2 entries, 830 bytes, 0 evicted
    ),
  )
}

///|
test "reads see the copy of the request's Session when it holds one, else the initial value, and never copy" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let _ = h.engine.set_data(
    mock="shop",
    session=Some("test-a"),
    bucket="orders",
    @json.parse("[{\"id\":\"a b\",\"total\":9.90},{\"id\":-7}]"),
  )
  let out = []
  let bytes = h.engine.state_stats().bytes
  for session in [Some("test-a"), Some("test-b"), None] {
    for
      target in [
        "/api/v1/orders", "/api/v1/orders/a%20b", "/api/v1/orders/-7", "/api/v1/orders/1001",
      ] {
      out.push(
        "\{@debug.to_string(session)} GET \{target}: \{reply(h.shop("GET", target, session?))}",
      )
    }
  }
  out.push("bytes unchanged: \{h.engine.state_stats().bytes == bytes}")
  inspect(
    out.join("\n"),
    content=(
      #|Some("test-a") GET /api/v1/orders: 200 [{"id":"a b","total":9.9},{"id":-7}]
      #|Some("test-a") GET /api/v1/orders/a%20b: 200 {"id":"a b","total":9.9}
      #|Some("test-a") GET /api/v1/orders/-7: 200 {"id":-7}
      #|Some("test-a") GET /api/v1/orders/1001: 404 {"error":"no item with this key","stub":"orders","key":"1001"}
      #|Some("test-b") GET /api/v1/orders: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|Some("test-b") GET /api/v1/orders/a%20b: 404 {"error":"no item with this key","stub":"orders","key":"a b"}
      #|Some("test-b") GET /api/v1/orders/-7: 404 {"error":"no item with this key","stub":"orders","key":"-7"}
      #|Some("test-b") GET /api/v1/orders/1001: 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|None GET /api/v1/orders: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|None GET /api/v1/orders/a%20b: 404 {"error":"no item with this key","stub":"orders","key":"a b"}
      #|None GET /api/v1/orders/-7: 404 {"error":"no item with this key","stub":"orders","key":"-7"}
      #|None GET /api/v1/orders/1001: 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|bytes unchanged: true
    ),
  )
}

///|
test "an item path's segment finds the item whose key has that text: an integer by its digits, however it is written, and a string as it is" {
  let h = harness([
    (
      "things.yaml",
      (
        #|mocks:
        #|  - name: things
        #|data:
        #|  - mock: things
        #|    name: things
        #|    key: code
        #|    json:
        #|      - { code: 42.0, item: 1 }
        #|      - { code: 0, item: 2 }
        #|      - { code: -9007199254740991, item: 3 }
        #|      - { code: 4.2e1x, item: 4 }
        #|      - { code: "007", item: 5 }
        #|stubs:
        #|  - id: things
        #|    mock: things
        #|    crud: { bucket: things, path: /things }
      ),
    ),
  ])
  let out = []
  for
    key in [
      "42", "042", "4.2e1", "%2B42", "0", "-0", "-9007199254740991", "-9007199254740992",
      "9007199254740991", "4.2e1x", "007", "7",
    ] {
    out.push("\{key}: \{reply(h.send("GET", "/things/\{key}"))}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|42: 200 {"code":42,"item":1}
      #|042: 404 {"error":"no item with this key","stub":"things","key":"042"}
      #|4.2e1: 404 {"error":"no item with this key","stub":"things","key":"4.2e1"}
      #|%2B42: 404 {"error":"no item with this key","stub":"things","key":"+42"}
      #|0: 200 {"code":0,"item":2}
      #|-0: 404 {"error":"no item with this key","stub":"things","key":"-0"}
      #|-9007199254740991: 200 {"code":-9007199254740991,"item":3}
      #|-9007199254740992: 404 {"error":"no item with this key","stub":"things","key":"-9007199254740992"}
      #|9007199254740991: 404 {"error":"no item with this key","stub":"things","key":"9007199254740991"}
      #|4.2e1x: 200 {"code":"4.2e1x","item":4}
      #|007: 200 {"code":"007","item":5}
      #|7: 404 {"error":"no item with this key","stub":"things","key":"7"}
    ),
  )
}

///|
test "fault works on a CRUD Stub as on any Stub: every matched request takes its one draw, 404s included, so a seed replays the same decisions" {
  let fault =
    #|{ seed: 7, delay: { uniform: { min: 1, max: 1000 } }, connection: { kind: reset, probability: 0.5 } }
  let h = harness(
    [
      (
        "shop.yaml",
        (
          $|mocks:
          $|  - name: shop
          $|data:
          $|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
          $|stubs:
          $|  - id: orders
          $|    mock: shop
          $|    crud: { bucket: orders, path: /orders }
          $|    fault: \{fault}
          $|  - id: twin
          $|    mock: shop
          $|    request: { path: /twin }
          $|    response: { status: 200 }
          $|    fault: \{fault}
          $|  - id: partial
          $|    mock: shop
          $|    crud: { bucket: orders, path: /partial, headers: { X-A: [one, two] } }
          $|    fault: { delay: { fixed: 250 }, connection: { kind: partial } }
        ),
      ),
    ],
    body_files=data_body_files,
  )
  let crud = ["/orders", "/orders/1001", "/orders/404", "/orders/1003"].repeat(
    2,
  )
  let crud_decisions = crud.map(target => {
    let outcome = h.send("GET", target)
    "\{outcome.plan.status} \{decision(outcome)}"
  })
  let twin_decisions = decisions(h, "/twin", crud.length())
  inspect(
    [
      crud_decisions.join("\n"),
      "the same as an ordinary Stub's: \{crud_decisions.map(d => d[4:].to_owned()) == twin_decisions}",
      describe(h.send("GET", "/partial/1001")),
    ].join("\n"),
    content=(
      #|200 delay 189
      #|200 delay 599
      #|404 delay 809, Reset
      #|200 delay 853
      #|200 delay 749
      #|200 delay 20
      #|404 delay 689, Reset
      #|200 delay 396, Reset
      #|the same as an ordinary Stub's: true
      #|plan:
      #|  status: 200
      #|  header: Content-Type: application/json
      #|  header: X-A: one
      #|  header: X-A: two
      #|  header: Smock-Mock: shop; via=default
      #|  body: "{\"id\":1001,\"customerId\":42,\"status\":\"paid\",\"total\":12.5}"
      #|  delay_ms: 250
      #|  fault: Some(Partial)
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("shop")
      #|  via_default: true
      #|  request: GET /partial/1001 HTTP/1.1
      #|  body: ""
      #|  stub: Some("partial")
      #|  status: Some(200)
      #|  fault: Some(Partial)
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "an Ephemeral Stub can be a CRUD Stub of its Session, which looks its bucket up on each request: after a reload removes it or takes its key away, it answers 500" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  out.push(
    h.add_to_shop(
      (
        #|{ "crud": { "bucket": "orders", "path": "/mine",
        #|    "headers": { "Access-Control-Allow-Origin": "https://app.test" } } }
      ),
    ),
  )
  let step = (label : String, session : String?) => {
    let outcome = h.shop("GET", "/mine/1001", session?)
    out.push(
      "\{label}: \{@debug.to_string(outcome.matched)} \{response(outcome)}",
    )
  }
  step("test-a", Some("test-a"))
  step("test-b", Some("test-b"))
  let reload = (shop : String) => {
    let result = h.engine.reload(
      {
        files: [("shop.yaml", @utf8.encode(shop))],
        body_files: data_body_files,
      },
      at=fixed_now,
    )
    out.push("reload: \{@debug.to_string(result.result)}")
  }
  // `orders` keyed by another member: the Stub serves it by that member.
  reload(
    (
      #|mocks: [{ name: shop, hosts: [shop.example.com] }]
      #|data: [{ mock: shop, name: orders, key: customerId, json: [{ customerId: 1001, k: 1 }] }]
    ),
  )
  step("keyed by customerId", Some("test-a"))
  reload(
    (
      #|mocks: [{ name: shop, hosts: [shop.example.com] }]
      #|data: [{ mock: shop, name: orders, jsonFile: orders.json }]
    ),
  )
  step("without key", Some("test-a"))
  reload(
    (
      #|mocks: [{ name: shop, hosts: [shop.example.com] }]
    ),
  )
  step("without the bucket", Some("test-a"))
  inspect(
    out.join("\n"),
    content=(
      #|eph-1
      #|test-a: Some(Ephemeral("eph-1")) 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: https://app.test
      #|{"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|test-b: None 404
      #|Content-Type: application/json
      #|Smock-Near-Miss: orders; failed=path
      #|{"error":"no Stub matched"}
      #|reload: Swapped
      #|keyed by customerId: Some(Ephemeral("eph-1")) 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: https://app.test
      #|{"customerId":1001,"k":1}
      #|reload: Swapped
      #|without key: Some(Ephemeral("eph-1")) 500
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: https://app.test
      #|{"error":"data bucket changed","stub":"eph-1","bucket":"orders"}
      #|reload: Swapped
      #|without the bucket: Some(Ephemeral("eph-1")) 500
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: https://app.test
      #|{"error":"unknown data bucket","stub":"eph-1","bucket":"orders"}
    ),
  )
}

///|
test "an Ephemeral CRUD Stub that breaks the rules is 400 invalid_stub, with the problems a Definition file gets" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    [
      h.add_to_shop(
        (
          #|{ "crud": { "bucket": "visits", "path": "/visits/" },
          #|  "request": { "path": "/v" }, "responses": [{ "status": 200 }] }
        ),
      ),
      h.add_to_shop(
        (
          #|{ "crud": { "bucket": "nope", "path": "/nope", "extra": 1 } }
        ),
      ),
    ].join("\n"),
    content=(
      #|/crud/bucket: the Data bucket "visits" has no "key": a CRUD Stub serves only a keyed bucket
      #|/crud/path: must be a path such as /api/v1/orders: it starts with /, does not end with /, and has no empty segment
      #|/request: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|/responses: is not allowed beside "crud": a CRUD Stub serves its bucket with no conditions, responses, Scenario clause or writes of its own
      #|/crud/bucket: the Mock has no Data bucket "nope"
      #|/crud/extra: is not a known field
    ),
  )
}
