// Seam 1 tests of `dataWrites` on keyed Data buckets: writes to one item by
// its key, appends with new keys, and whole sets that keep the rules of
// keyed buckets.

///|
/// The orders of `orders.json`: 1001 to 1003, keyed by `id`.
let orders_json : String =
  #|[
  #|  { "id": 1001, "customerId": 42, "status": "paid" },
  #|  { "id": 1002, "customerId": 7, "status": "pending" },
  #|  { "id": 1003, "customerId": 42, "status": "pending" }
  #|]

///|
/// A harness with Mock `shop`, the keyed bucket `orders` from
/// `orders.json`, the buckets `buckets`, the Stubs `stubs`, given as YAML
/// list items, and `GET /orders`, which answers the orders.
fn orders_harness(
  stubs : String,
  buckets? : String = "",
  state_max_bytes? : Int = @engine.default_state_max_bytes,
) -> Harness {
  harness(
    [
      shop_file(
        "  - { mock: shop, name: orders, key: id, jsonFile: orders.json }\n\{buckets}",
        (
          $|  - id: list
          $|    mock: shop
          $|    request: { method: GET, path: /orders }
          $|    response: { status: 200, template: true, json: "${data.orders}" }
          $|\{stubs}
        ),
      ),
    ],
    body_files=[("orders.json", @utf8.encode(orders_json))],
    state_max_bytes~,
  )
}

///|
test "merge with key merges into the item with that key: the pay-order Stub answers the order it paid, and a key that no item has writes nothing" {
  let h = orders_harness(
    (
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
  )
  let out = []
  out.push(reply(h.send("POST", "/api/v1/orders/1002/pay", session="s")))
  let missing = h.send("POST", "/api/v1/orders/9999/pay", session="s")
  out.push(reply(missing))
  out.push(data_journaled(missing))
  out.push("s: \{reply(h.send("GET", "/orders", session="s"))}")
  out.push("t: \{reply(h.send("GET", "/orders", session="t"))}")
  inspect(
    out.join("\n"),
    content=(
      #|200 {"id":1002,"customerId":7,"status":"paid","paidAt":"2026-10-12T14:30:05.123Z"}
      #|500 {"error":"data write failed","stub":"pay-order","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no item with the key \"9999\""}
      #|status 500, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/0: the Data bucket "orders" has no item with the key "9999", templateError none
      #|s: 200 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"paid","paidAt":"2026-10-12T14:30:05.123Z"},{"id":1003,"customerId":42,"status":"pending"}]
      #|t: 200 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"pending"},{"id":1003,"customerId":42,"status":"pending"}]
    ),
  )
}

///|
/// The Stubs `PUT /orders/<key>`, `PATCH /orders/<key>` and `DELETE
/// /orders/<key>`, which write the item of the path's key with `set`,
/// `merge` and `remove`, the first two from the body, and answer the item,
/// or `none` after a remove.
let by_key : String =
  #|  - id: replace
  #|    mock: shop
  #|    request: { method: PUT, path: { pattern: "/orders/[^/]+" } }
  #|    dataWrites:
  #|      - { op: set, bucket: orders, key: "${path[1]}", value: "${body}" }
  #|    response: { status: 200, template: true, json: "${find(data.orders, 'id', path[1]) ?? 'none'}" }
  #|  - id: update
  #|    mock: shop
  #|    request: { method: PATCH, path: { pattern: "/orders/[^/]+" } }
  #|    dataWrites:
  #|      - { op: merge, bucket: orders, key: "${path[1]}", value: "${body}" }
  #|    response: { status: 200, template: true, json: "${find(data.orders, 'id', path[1]) ?? 'none'}" }
  #|  - id: delete
  #|    mock: shop
  #|    request: { method: DELETE, path: { pattern: "/orders/[^/]+" } }
  #|    dataWrites:
  #|      - { op: remove, bucket: orders, key: "${path[1]}" }
  #|    response: { status: 200, template: true, json: "${find(data.orders, 'id', path[1]) ?? 'none'}" }

///|
test "set with key makes the item the value, in its place: an absent key member is added last, and the item keeps its stored key value" {
  let h = orders_harness(by_key)
  let out = []
  let put = (target : String, body : String) => {
    out.push("PUT \{target} \{body}: \{reply(h.send("PUT", target, body~))}")
  }
  put("/orders/1002", "{\"status\":\"shipped\",\"note\":\"x\"}")
  put("/orders/1002", "{\"status\":\"lost\",\"id\":\"1002\"}")
  put("/orders/1001", "{\"id\":1001.0}")
  put("/orders/1002", "{\"id\":1003,\"status\":\"x\"}")
  put("/orders/1002", "{\"id\":null}")
  put("/orders/1002", "[1]")
  put("/orders/1004", "{}")
  out.push("orders: \{reply(h.send("GET", "/orders"))}")
  inspect(
    out.join("\n"),
    content=(
      #|PUT /orders/1002 {"status":"shipped","note":"x"}: 200 {"status":"shipped","note":"x","id":1002}
      #|PUT /orders/1002 {"status":"lost","id":"1002"}: 200 {"status":"lost","id":1002}
      #|PUT /orders/1001 {"id":1001.0}: 200 {"id":1001}
      #|PUT /orders/1002 {"id":1003,"status":"x"}: 500 {"error":"data write failed","stub":"replace","at":"/dataWrites/0","message":"the value's \"id\" must be absent or hold the item's key \"1002\", and it holds the key \"1003\""}
      #|PUT /orders/1002 {"id":null}: 500 {"error":"data write failed","stub":"replace","at":"/dataWrites/0","message":"the value's \"id\" must be absent or hold the item's key \"1002\", and it holds null"}
      #|PUT /orders/1002 [1]: 500 {"error":"data write failed","stub":"replace","at":"/dataWrites/0","message":"the value of \"set\" with \"key\" must be an object, and it is an array"}
      #|PUT /orders/1004 {}: 500 {"error":"data write failed","stub":"replace","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no item with the key \"1004\""}
      #|orders: 200 [{"id":1001},{"status":"lost","id":1002},{"id":1003,"customerId":42,"status":"pending"}]
    ),
  )
}

///|
test "merge with key merges shallowly into the item: members replace in place, new ones go last, null is stored, and the item keeps its key" {
  let h = orders_harness(by_key)
  let out = []
  let patch = (target : String, body : String) => {
    out.push(
      "PATCH \{target} \{body}: \{reply(h.send("PATCH", target, body~))}",
    )
  }
  patch(
    "/orders/1002", "{\"note\":{\"a\":1},\"status\":\"paid\",\"id\":\"1002\",\"customerId\":null}",
  )
  patch("/orders/1002", "{\"note\":\"b\"}")
  patch("/orders/1002", "{}")
  patch("/orders/1002", "{\"id\":5}")
  patch("/orders/1002", "[1]")
  patch("/orders/x", "{}")
  out.push("orders: \{reply(h.send("GET", "/orders"))}")
  inspect(
    out.join("\n"),
    content=(
      #|PATCH /orders/1002 {"note":{"a":1},"status":"paid","id":"1002","customerId":null}: 200 {"id":1002,"customerId":null,"status":"paid","note":{"a":1}}
      #|PATCH /orders/1002 {"note":"b"}: 200 {"id":1002,"customerId":null,"status":"paid","note":"b"}
      #|PATCH /orders/1002 {}: 200 {"id":1002,"customerId":null,"status":"paid","note":"b"}
      #|PATCH /orders/1002 {"id":5}: 500 {"error":"data write failed","stub":"update","at":"/dataWrites/0","message":"the value's \"id\" must be absent or hold the item's key \"1002\", and it holds the key \"5\""}
      #|PATCH /orders/1002 [1]: 500 {"error":"data write failed","stub":"update","at":"/dataWrites/0","message":"the value of \"merge\" must be an object, and it is an array"}
      #|PATCH /orders/x {}: 500 {"error":"data write failed","stub":"update","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no item with the key \"x\""}
      #|orders: 200 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":null,"status":"paid","note":"b"},{"id":1003,"customerId":42,"status":"pending"}]
    ),
  )
}

///|
test "remove removes the item with the key, and a key that no item has, a removed one included, writes nothing" {
  let h = orders_harness(by_key)
  let out = []
  let delete = (target : String) => {
    out.push("DELETE \{target}: \{reply(h.send("DELETE", target))}")
  }
  delete("/orders/1002")
  delete("/orders/1002")
  delete("/orders/1003")
  delete("/orders/1001")
  out.push("orders: \{reply(h.send("GET", "/orders"))}")
  delete("/orders/1001")
  inspect(
    out.join("\n"),
    content=(
      #|DELETE /orders/1002: 200 "none"
      #|DELETE /orders/1002: 500 {"error":"data write failed","stub":"delete","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no item with the key \"1002\""}
      #|DELETE /orders/1003: 200 "none"
      #|DELETE /orders/1001: 200 "none"
      #|orders: 200 []
      #|DELETE /orders/1001: 500 {"error":"data write failed","stub":"delete","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no item with the key \"1001\""}
    ),
  )
}

///|
/// The Stubs `POST /<bucket>`, which appends the body to the bucket and
/// answers it, and `DELETE /orders/<key>`, for each bucket of `buckets`.
fn appends(buckets : Array[String]) -> String {
  let out = StringBuilder()
  for bucket in buckets {
    out.write_string(
      (
        $|  - id: add-\{bucket}
        $|    mock: shop
        $|    request: { method: POST, path: /\{bucket} }
        $|    dataWrites:
        $|      - { op: append, bucket: \{bucket}, value: "${body}" }
        $|    response: { status: 201, template: true, json: "${data.\{bucket}}" }
        $|
      ),
    )
  }
  out.to_string()
}

///|
test "append adds an item at the end: a valid key that no item has is kept, and an item without the key member gets the next integer key, added last" {
  let h = orders_harness(appends(["orders"]) + by_key)
  let out = []
  let post = (body : String) => {
    out.push("POST \{body}: \{reply(h.send("POST", "/orders", body~))}")
  }
  post("{\"customerId\":42,\"status\":\"pending\"}")
  post("{\"status\":\"x\",\"id\":\"a-1\"}")
  post("{\"id\":1001}")
  post("{\"id\":\"1001\"}")
  post("{\"id\":null}")
  post("{\"id\":\"\"}")
  post("{\"id\":\"a/b\"}")
  post("{\"id\":1.5}")
  post("[1]")
  // The highest integer key, deleted, is given again.
  out.push("DELETE 1004: \{reply(h.send("DELETE", "/orders/1004"))}")
  post("{}")
  inspect(
    out.join("\n"),
    content=(
      #|POST {"customerId":42,"status":"pending"}: 201 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"pending"},{"id":1003,"customerId":42,"status":"pending"},{"customerId":42,"status":"pending","id":1004}]
      #|POST {"status":"x","id":"a-1"}: 201 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"pending"},{"id":1003,"customerId":42,"status":"pending"},{"customerId":42,"status":"pending","id":1004},{"status":"x","id":"a-1"}]
      #|POST {"id":1001}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the Data bucket \"orders\" already has an item with the key \"1001\""}
      #|POST {"id":"1001"}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the Data bucket \"orders\" already has an item with the key \"1001\""}
      #|POST {"id":null}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the value's \"id\" must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991, and it holds null"}
      #|POST {"id":""}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the value's \"id\" must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991, and it holds a string"}
      #|POST {"id":"a/b"}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the value's \"id\" must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991, and it holds a string"}
      #|POST {"id":1.5}: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the value's \"id\" must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991, and it holds a number"}
      #|POST [1]: 500 {"error":"data write failed","stub":"add-orders","at":"/dataWrites/0","message":"the value of \"append\" to a keyed bucket must be an object, and it is an array"}
      #|DELETE 1004: 200 "none"
      #|POST {}: 201 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"pending"},{"id":1003,"customerId":42,"status":"pending"},{"status":"x","id":"a-1"},{"id":1004}]
    ),
  )
}

///|
test "a new integer key counts no string key, starts from 1, and skips the integers whose text a string key has" {
  let h = orders_harness(
    appends(["tags", "codes", "empty", "below"]),
    buckets=(
      #|  - { mock: shop, name: tags, key: name, json: [{ name: "1" }, { name: "2" }, { name: x }] }
      #|  - { mock: shop, name: codes, key: code, json: [{ code: 7 }, { code: "8" }, { code: "09" }, { code: "-1" }] }
      #|  - { mock: shop, name: empty, key: id, newKey: integer, json: [] }
      #|  - { mock: shop, name: below, key: id, json: [{ id: -5 }, { id: "-4" }] }
    ),
  )
  let out = []
  for bucket in ["tags", "codes", "empty", "below"] {
    for _ in 0..<2 {
      out.push("\{bucket}: \{reply(h.send("POST", "/\{bucket}", body="{}"))}")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|tags: 201 [{"name":"1"},{"name":"2"},{"name":"x"},{"name":3}]
      #|tags: 201 [{"name":"1"},{"name":"2"},{"name":"x"},{"name":3},{"name":4}]
      #|codes: 201 [{"code":7},{"code":"8"},{"code":"09"},{"code":"-1"},{"code":9}]
      #|codes: 201 [{"code":7},{"code":"8"},{"code":"09"},{"code":"-1"},{"code":9},{"code":10}]
      #|empty: 201 [{"id":1}]
      #|empty: 201 [{"id":1},{"id":2}]
      #|below: 201 [{"id":-5},{"id":"-4"},{"id":-3}]
      #|below: 201 [{"id":-5},{"id":"-4"},{"id":-3},{"id":-2}]
    ),
  )
}

///|
test "when the new integer key would pass 2^53 - 1, the append fails with no new key, and nothing is written" {
  let h = orders_harness(
    appends(["last", "taken"]),
    buckets=(
      #|  - { mock: shop, name: last, key: id, json: [{ id: 9007199254740990 }] }
      #|  - { mock: shop, name: taken, key: id, json: [{ id: 9007199254740990 }, { id: "9007199254740991" }] }
    ),
  )
  let out = []
  for bucket in ["last", "last", "taken"] {
    out.push("\{bucket}: \{reply(h.send("POST", "/\{bucket}", body="{}"))}")
  }
  let other = h.send("POST", "/last", body="{\"id\":\"other\"}")
  out.push("a key of its own: \{reply(other)}")
  inspect(
    out.join("\n"),
    content=(
      #|last: 201 [{"id":9007199254740990},{"id":9007199254740991}]
      #|last: 500 {"error":"data write failed","stub":"add-last","at":"/dataWrites/0","message":"no new key: the next integer key of the Data bucket \"last\" would pass 9007199254740991"}
      #|taken: 500 {"error":"data write failed","stub":"add-taken","at":"/dataWrites/0","message":"no new key: the next integer key of the Data bucket \"taken\" would pass 9007199254740991"}
      #|a key of its own: 201 [{"id":9007199254740990},{"id":9007199254740991},{"id":"other"}]
    ),
  )
}

///|
test "keys are compared by their text: a key written as 42.0 is the key 42, and 42 and \"42\" collide" {
  let h = orders_harness(
    appends(["items"]) +
    (
      #|  - id: set-42
      #|    mock: shop
      #|    request: { method: PUT, path: /items/42 }
      #|    dataWrites:
      #|      - { op: set, bucket: items, key: "42", value: { id: "42", name: forty-two } }
      #|    response: { status: 200, template: true, json: "${data.items}" }
      #|  - id: remove-42
      #|    mock: shop
      #|    request: { method: DELETE, path: /items/42 }
      #|    dataWrites:
      #|      - { op: remove, bucket: items, key: "${path[1]}" }
      #|    response: { status: 200, template: true, json: "${data.items}" }
      #|  - id: add-written
      #|    mock: shop
      #|    request: { method: POST, path: /written }
      #|    dataWrites:
      #|      - { op: append, bucket: items, value: { id: 4.2e1 } }
      #|    response: { status: 201, template: true, json: "${data.items}" }
    ),
    buckets=(
      #|  - { mock: shop, name: items, key: id, json: [{ id: 42.0 }, { id: "a" }] }
    ),
  )
  let out = []
  out.push("POST id 42: \{reply(h.send("POST", "/items", body="{\"id\":42}"))}")
  out.push(
    "POST id \"42\": \{reply(h.send("POST", "/items", body="{\"id\":\"42\"}"))}",
  )
  out.push("POST id 4.2e1 in the Stub: \{reply(h.send("POST", "/written"))}")
  out.push("POST no id: \{reply(h.send("POST", "/items", body="{}"))}")
  out.push("PUT 42: \{reply(h.send("PUT", "/items/42"))}")
  out.push("DELETE 42: \{reply(h.send("DELETE", "/items/42"))}")
  out.push("POST id 42: \{reply(h.send("POST", "/items", body="{\"id\":42}"))}")
  inspect(
    out.join("\n"),
    content=(
      #|POST id 42: 500 {"error":"data write failed","stub":"add-items","at":"/dataWrites/0","message":"the Data bucket \"items\" already has an item with the key \"42\""}
      #|POST id "42": 500 {"error":"data write failed","stub":"add-items","at":"/dataWrites/0","message":"the Data bucket \"items\" already has an item with the key \"42\""}
      #|POST id 4.2e1 in the Stub: 500 {"error":"data write failed","stub":"add-written","at":"/dataWrites/0","message":"the Data bucket \"items\" already has an item with the key \"42\""}
      #|POST no id: 201 [{"id":42},{"id":"a"},{"id":43}]
      #|PUT 42: 200 [{"id":42,"name":"forty-two"},{"id":"a"},{"id":43}]
      #|DELETE 42: 200 [{"id":"a"},{"id":43}]
      #|POST id 42: 201 [{"id":"a"},{"id":43},{"id":42}]
    ),
  )
}

///|
test "uuid keys draw from the helper generator after every write's key and value, before the response, in write order, and repeat under fault.seed" {
  let h = orders_harness(
    (
      #|  - id: stored
      #|    mock: shop
      #|    request: { path: /stored }
      #|    variables: { first: "${fake.uuid()}" }
      #|    dataWrites:
      #|      - { op: merge, bucket: tokens, key: "${len(fake.uuid())}", value: { seen: "${fake.uuid()}" } }
      #|      - { op: append, bucket: tokens, value: { owner: "${fake.uuid()}" } }
      #|      - { op: append, bucket: tokens, value: {} }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { first: "${vars.first}", tokens: "${data.tokens}", last: "${fake.uuid()}" }
      #|    fault: { seed: 42 }
      #|  - id: drawn
      #|    mock: shop
      #|    request: { path: /drawn }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { $each: "range(1, 7)", as: i, do: "${fake.uuid()}" }
      #|    fault: { seed: 42 }
    ),
    buckets=(
      #|  - { mock: shop, name: tokens, key: token, newKey: uuid, json: [{ token: "36" }] }
    ),
  )
  // Each request's uuids, named by their place among those `/drawn` gives
  // for the same request of its seed: u1 is drawn first.
  let out = []
  for session in ["s", "t"] {
    let mut stored = reply(h.send("GET", "/stored", session~))
    let drawn = h.send("GET", "/drawn").plan.body
    guard drawn is Bytes(body) &&
      @json.parse(@utf8.decode_lossy(body)) is Array(uuids) else {
      fail("no uuids")
    }
    for i, uuid in uuids {
      guard uuid is String(uuid) else { fail("not a uuid") }
      stored = stored.replace_all(old=uuid, new="u\{i + 1}")
    }
    out.push("\{session}: \{stored}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|s: 200 {"first":"u1","tokens":[{"token":"36","seen":"u3"},{"owner":"u4","token":"u5"},{"token":"u6"}],"last":"u7"}
      #|t: 200 {"first":"u1","tokens":[{"token":"36","seen":"u3"},{"owner":"u4","token":"u5"},{"token":"u6"}],"last":"u7"}
    ),
  )
}

///|
test "a uuid key that an item has already is drawn again" {
  let h = orders_harness(
    (
      #|  - id: add-token
      #|    mock: shop
      #|    request: { path: /token }
      #|    dataWrites:
      #|      - { op: append, bucket: tokens, value: {} }
      #|    response: { status: 201, template: true, json: { tokens: "${data.tokens}", next: "${fake.uuid()}" } }
      #|    fault: { seed: 42 }
    ),
    buckets=(
      #|  - { mock: shop, name: tokens, key: token, newKey: uuid, json: [{ token: 967d85fe-343d-4cc0-9b49-c024af3b3103 }] }
    ),
  )
  inspect(
    reply(h.send("GET", "/token")),
    content=(
      #|201 {"tokens":[{"token":"967d85fe-343d-4cc0-9b49-c024af3b3103"},{"token":"a168a304-0584-4bdd-99da-8adbdc970b94"}],"next":"60f50a30-f8ef-47b0-bcd9-40ec46d73ae7"}
    ),
  )
}

///|
test "set without key makes the whole bucket the value, which must keep the rules of keyed buckets" {
  let h = orders_harness(
    (
      #|  - id: replace-all
      #|    mock: shop
      #|    request: { method: PUT, path: /orders }
      #|    dataWrites:
      #|      - { op: set, bucket: orders, value: "${body}" }
      #|      - { op: append, bucket: orders, value: { status: added } }
      #|    response: { status: 200, template: true, json: "${data.orders}" }
    ),
  )
  let out = []
  let put = (body : String) => {
    out.push("PUT \{body}: \{reply(h.send("PUT", "/orders", body~))}")
  }
  put("[]")
  put("[{\"id\":\"b\"},{\"id\":7,\"n\":null}]")
  put("{\"id\":1}")
  put("[{\"id\":1},{\"id\":\"1\"}]")
  put("[1,{},{\"id\":true}]")
  out.push("orders: \{reply(h.send("GET", "/orders"))}")
  inspect(
    out.join("\n"),
    content=(
      #|PUT []: 200 [{"status":"added","id":1}]
      #|PUT [{"id":"b"},{"id":7,"n":null}]: 200 [{"id":"b"},{"id":7,"n":null},{"status":"added","id":8}]
      #|PUT {"id":1}: 500 {"error":"data write failed","stub":"replace-all","at":"/dataWrites/0","message":"the value breaks the rules of the Data bucket \"orders\", keyed by \"id\": must be an array of objects, since the bucket has \"key\""}
      #|PUT [{"id":1},{"id":"1"}]: 500 {"error":"data write failed","stub":"replace-all","at":"/dataWrites/0","message":"the value breaks the rules of the Data bucket \"orders\", keyed by \"id\": /1/id has the key text \"1\", as item 0 does"}
      #|PUT [1,{},{"id":true}]: 500 {"error":"data write failed","stub":"replace-all","at":"/dataWrites/0","message":"the value breaks the rules of the Data bucket \"orders\", keyed by \"id\": /0 must be an object with the key member \"id\" (and 2 more)"}
      #|orders: 200 [{"id":"b"},{"id":7,"n":null},{"status":"added","id":8}]
    ),
  )
}

///|
test "a key that fails to render writes nothing and gives the template failure at the write's key, which renders before its value, bounded as a rendered body is" {
  let h = orders_harness(
    (
      #|  - id: pay
      #|    mock: shop
      #|    request: { method: POST, path: /pay }
      #|    dataWrites:
      #|      - { op: append, bucket: orders, value: { status: new } }
      #|      - { op: merge, bucket: orders, key: "${body.id}", value: { paid: "${body.missing}" } }
      #|    response: { status: 200 }
    ),
  )
  let mib = 1024 * 1024
  let out = []
  let pay = (label : String, body : String) => {
    let outcome = h.send("POST", "/pay", body~)
    out.push("\{label}: \{reply(outcome)}")
    out.push("\{label}: \{data_journaled(outcome)}")
  }
  // The value would fail too: the key renders first.
  pay("no id", "{}")
  pay("an object", "{\"id\":{\"a\":1}}")
  pay("1 MiB", "{\"id\":\"\{"a".repeat(mib)}\"}")
  pay("past 1 MiB", "{\"id\":\"\{"a".repeat(mib + 1)}\"}")
  out.push("orders: \{reply(h.send("GET", "/orders"))}")
  inspect(
    out.join("\n"),
    content=(
      #|no id: 500 {"error":"template failed","stub":"pay","at":"/dataWrites/1/key","message":"body.id is missing"}
      #|no id: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError /dataWrites/1/key: body.id is missing
      #|an object: 500 {"error":"template failed","stub":"pay","at":"/dataWrites/1/key","message":"an object or an array cannot be written as text; write it with json(…)"}
      #|an object: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError /dataWrites/1/key: an object or an array cannot be written as text; write it with json(…)
      #|1 MiB: 500 {"error":"template failed","stub":"pay","at":"/dataWrites/1/value/paid","message":"body.missing is missing"}
      #|1 MiB: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError /dataWrites/1/value/paid: body.missing is missing
      #|past 1 MiB: 500 {"error":"template failed","stub":"pay","at":"/dataWrites/1/key","message":"the rendered value takes more than 1 MiB"}
      #|past 1 MiB: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError /dataWrites/1/key: the rendered value takes more than 1 MiB
      #|orders: 200 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"pending"},{"id":1003,"customerId":42,"status":"pending"}]
    ),
  )
}

///|
test "an Ephemeral Stub's write with key fails after a reload takes key away, so does a merge without key after one gives key, and a set or append without key still applies" {
  let files = (buckets : String) => {
    [
      shop_file(
        buckets,
        (
          #|  - id: other
          #|    mock: shop
          #|    request: { path: /other }
          #|    response: { status: 200 }
        ),
      ),
    ]
  }
  let h = harness(
    files(
      (
        #|  - { mock: shop, name: orders, key: id, json: [{ id: 1 }] }
        #|  - { mock: shop, name: profile, json: {} }
        #|  - { mock: shop, name: log, json: [] }
      ),
    ),
  )
  let add = (path : String, writes : String) => {
    h.add_to_shop(
      "{ \"request\": { \"path\": \"\{path}\" }, \"dataWrites\": [\{writes}], \"response\": { \"status\": 200, \"template\": true, \"json\": { \"orders\": \"${data.orders}\", \"profile\": \"${data.profile}\", \"log\": \"${data.log}\" } } }",
    )
  }
  let out = [
    add(
      "/pay", "{ \"op\": \"merge\", \"bucket\": \"orders\", \"key\": \"1\", \"value\": { \"paid\": true } }",
    ),
    add(
      "/name", "{ \"op\": \"merge\", \"bucket\": \"profile\", \"value\": { \"name\": \"ann\" } }",
    ),
    add(
      "/log", "{ \"op\": \"set\", \"bucket\": \"log\", \"value\": \"${body}\" }, { \"op\": \"append\", \"bucket\": \"log\", \"value\": { \"at\": 1 } }",
    ),
  ]
  let send = (label : String, path : String, body : String) => {
    out.push(
      "\{label}: \{reply(h.send("POST", path, body~, session="test-a"))}",
    )
  }
  send("pay", "/pay", "")
  send("name", "/name", "")
  let reload = h.engine.reload(
    {
      files: files(
        (
          #|  - { mock: shop, name: orders, json: [{ id: 1 }] }
          #|  - { mock: shop, name: profile, key: id, json: [] }
          #|  - { mock: shop, name: log, key: id, json: [] }
        ),
      ).map(f => (f.0, @utf8.encode(f.1))),
      body_files: [],
    },
    at=fixed_now,
  )
  out.push("reload: \{@debug.to_string(reload.result)}")
  send("pay", "/pay", "")
  send("name", "/name", "")
  send("log a keyed array", "/log", "[{\"id\":\"a\"}]")
  send("log a number", "/log", "1")
  inspect(
    out.join("\n"),
    content=(
      #|eph-1
      #|eph-2
      #|eph-3
      #|pay: 200 {"orders":[{"id":1,"paid":true}],"profile":{},"log":[]}
      #|name: 200 {"orders":[{"id":1,"paid":true}],"profile":{"name":"ann"},"log":[]}
      #|reload: Swapped
      #|pay: 500 {"error":"data write failed","stub":"eph-1","at":"/dataWrites/0","message":"the Data bucket \"orders\" has no \"key\" since a reload, and a write with \"key\" needs a keyed bucket"}
      #|name: 500 {"error":"data write failed","stub":"eph-2","at":"/dataWrites/0","message":"the Data bucket \"profile\" has \"key\" since a reload, and \"merge\" without \"key\" cannot write to a keyed bucket"}
      #|log a keyed array: 200 {"orders":[{"id":1}],"profile":[],"log":[{"id":"a"},{"at":1,"id":1}]}
      #|log a number: 500 {"error":"data write failed","stub":"eph-3","at":"/dataWrites/0","message":"the value breaks the rules of the Data bucket \"log\", keyed by \"id\": must be an array of objects, since the bucket has \"key\""}
    ),
  )
}

///|
test "writes by key copy the bucket only at a Session's first write, move the count by what each item changed, and are undone in place when a later write fails" {
  let h = orders_harness(
    (
      #|  - id: edit
      #|    mock: shop
      #|    request: { method: POST, path: /edit }
      #|    dataWrites:
      #|      - { op: set, bucket: orders, key: "${body.set}", value: { status: set } }
      #|      - { op: merge, bucket: orders, key: "${body.merge}", value: { note: "${body.note}", status: null } }
      #|      - { op: remove, bucket: orders, key: "${body.remove}" }
      #|      - { op: append, bucket: orders, value: { status: new } }
      #|      - { op: merge, bucket: orders, key: "${body.last}", value: {} }
      #|    response: { status: 204 }
    ),
  )
  let out = []
  // What the Session's copy counts, and what the same value counts when
  // the Admin API measures it whole, in another Session of the same
  // length.
  let counts = () => {
    let before = h.engine.state_stats().bytes
    let value = h.engine.read_data(
        mock="shop",
        session=Some("s"),
        bucket="orders",
      ).value
    h.engine.set_data(mock="shop", session=Some("t"), bucket="orders", value)
    |> ignore
    let whole = h.engine.state_stats().bytes - before
    h.engine.drop_data(mock="shop", session=Some("t"), bucket="orders")
    |> ignore
    "\{before} bytes, measured whole \{whole}"
  }
  let edit = (body : String) => {
    let outcome = h.send("POST", "/edit", body~, session="s")
    out.push("\{body}: \{reply(outcome)}, \{counts()}")
  }
  edit(
    "{\"set\":1002,\"merge\":1001,\"note\":\"a\",\"remove\":1003,\"last\":1001}",
  )
  let after_first = reply(h.send("GET", "/orders", session="s"))
  // Every write is applied to the stored copy in place, then undone when
  // the last finds no item.
  edit(
    "{\"set\":1003,\"merge\":1002,\"note\":\"bb\",\"remove\":1001,\"last\":\"none\"}",
  )
  let after_failure = reply(h.send("GET", "/orders", session="s"))
  out.push("undone: \{after_failure == after_first}")
  edit(
    "{\"set\":1001,\"merge\":1003,\"note\":\"a longer note\",\"remove\":1002,\"last\":1004}",
  )
  out.push(reply(h.send("GET", "/orders", session="s")))
  inspect(
    out.join("\n"),
    content=(
      #|{"set":1002,"merge":1001,"note":"a","remove":1003,"last":1001}: 204 , 439 bytes, measured whole 439
      #|{"set":1003,"merge":1002,"note":"bb","remove":1001,"last":"none"}: 500 {"error":"data write failed","stub":"edit","at":"/dataWrites/4","message":"the Data bucket \"orders\" has no item with the key \"none\""}, 439 bytes, measured whole 439
      #|undone: true
      #|{"set":1001,"merge":1003,"note":"a longer note","remove":1002,"last":1004}: 204 , 419 bytes, measured whole 419
      #|200 [{"status":"set","id":1001},{"status":null,"id":1003,"note":"a longer note"},{"status":"new","id":1004}]
    ),
  )
}
