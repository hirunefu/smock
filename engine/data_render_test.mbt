// Seam 1 tests of rendering with Data buckets: the sample's data, the
// writes of a Stub's `dataWrites` that a rendering shows, and the response
// rendered after them, as `smock render` and the Admin render operation
// show them. A rendering never reads or writes a Session's data.

///|
/// A harness with Mock `shop`, the keyed bucket `orders` from
/// `orders.json`, the buckets `visits` (0), `cart` (an object), `log` (an
/// array) and `tokens` (keyed by `token`, with `uuid` keys), and the Stubs
/// `stubs`, given as YAML list items.
fn render_harness(stubs : String) -> Harness {
  harness(
    [
      shop_file(
        (
          #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
          #|  - { mock: shop, name: visits, json: 0 }
          #|  - { mock: shop, name: cart, json: { items: [] } }
          #|  - { mock: shop, name: log, json: [] }
          #|  - { mock: shop, name: tokens, key: token, newKey: uuid, json: [] }
        ),
        stubs,
      ),
    ],
    body_files=[("orders.json", @utf8.encode(orders_json))],
  )
}

///|
/// Renders the Stub `id` for the sample request `sample`, given as its
/// JSON, at the harness's time and with the seed 7, and shows the
/// rendering as `smock render` prints it, or why it cannot be rendered.
fn Harness::render_json(self : Harness, id : String, sample : Json) -> String {
  let sample = @engine.SampleRequest::from_json(sample) catch {
    error => return "invalid sample: \{error.message()}"
  }
  try self.engine.render(id, sample, now=self.now, fresh_seed=() => 7) catch {
    error => "cannot render: \{error.message()}"
  } noraise {
    rendering => rendering.to_json().stringify(indent=2)
  }
}

///|
/// What the rendering of the Stub `id` for the sample `sample` shows of
/// data, as `render_json` renders it: the response's status and body, the
/// writes the Stub would make, one line each, the Variables it would write
/// and the template error; or why it cannot be rendered.
fn Harness::render_brief(self : Harness, id : String, sample : Json) -> String {
  let text = self.render_json(id, sample)
  let rendering = @json.parse(text) catch { _ => return text }
  guard rendering is Object(rendering) else { return text }
  let response = rendering.get("response").unwrap_or(Json::null())
  let (status, body) = match response {
    Object(response) =>
      (
        response.get("status").unwrap_or(Json::null()).stringify(),
        match response.get("body") {
          Some(Object(body)) =>
            match body.get("data") {
              Some(String(data)) => data
              _ => "?"
            }
          _ => "?"
        },
      )
    _ => ("?", "?")
  }
  let line = (name : String) => {
    "  \{name} \{rendering.get(name).unwrap_or(Json::string("absent")).stringify()}"
  }
  let out = ["\{status} \{body}"]
  // One line for each write.
  match rendering.get("dataWrites") {
    Some(Array(writes)) if !writes.is_empty() => {
      out.push("  dataWrites")
      for write in writes {
        out.push("    \{write.stringify()}")
      }
    }
    _ => out.push(line("dataWrites"))
  }
  out.push(line("variables"))
  out.push(line("templateError"))
  out.join("\n")
}

///|
test "the sample's data is what templates read as data.NAME, and the buckets it does not name read their initial value" {
  let h = render_harness(
    (
      #|  - id: summary
      #|    mock: shop
      #|    request: { method: GET, path: /summary }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { orders: "${data.orders}", visits: "${data.visits}", cart: "${data.cart}" }
    ),
  )
  inspect(
    h.render_json("summary", {
      "path": "/summary",
      "data": { "orders": [{ "id": 7, "status": "new" }], "visits": 41 },
    }),
    content=(
      #|{
      #|  "stub": "summary",
      #|  "mock": "shop",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"orders\":[{\"id\":7,\"status\":\"new\"}],\"visits\":41,\"cart\":{\"items\":[]}}",
      #|      "size": 68,
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

///|
test "sample data for a bucket the Mock does not declare, or that breaks a keyed bucket's rules, cannot be rendered" {
  let h = render_harness(
    (
      #|  - id: summary
      #|    mock: shop
      #|    request: { method: GET, path: /summary }
      #|    response: { status: 200, template: true, json: "${data.visits}" }
    ),
  )
  let out = []
  for
    data in [
      Json::object({ "nope": 1 }),
      { "visits": 1, "a b": [] },
      { "orders": { "id": 1 } },
      { "orders": [{ "id": 1 }, { "id": "1" }, { "number": 2 }, "x"] },
      { "tokens": [{ "token": "a/b" }] },
      { "visits": "any value", "cart": null, "orders": [] },
      Json::array([]),
    ] {
    out.push(
      h
      .render_brief("summary", { "path": "/summary", "data": data })
      .split("\n")
      .next()
      .unwrap()
      .to_owned(),
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|cannot render: the sample request's data names the Data bucket "nope", which the Mock "shop" does not declare
      #|cannot render: the sample request's data names the Data bucket "a b", which the Mock "shop" does not declare
      #|cannot render: the sample request's data breaks the rules of the Data bucket "orders", keyed by "id": /data/orders must be an array of objects, since the bucket has "key"
      #|cannot render: the sample request's data breaks the rules of the Data bucket "orders", keyed by "id": /data/orders/1/id has the key text "1", as item 0 does; /data/orders/2 needs the key member "id"; /data/orders/3 must be an object with the key member "id"
      #|cannot render: the sample request's data breaks the rules of the Data bucket "tokens", keyed by "token": /data/tokens/0/token must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|200 "any value"
      #|invalid sample: /data: must be an object
    ),
  )
}

///|
test "rendering the pay-order Stub for an order of the sample's data shows the merge it would make, and the order after it" {
  let h = render_harness(
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
  inspect(
    h.render_json("pay-order", {
      "method": "POST",
      "path": "/api/v1/orders/1002/pay",
      "data": { "orders": [{ "id": 1002, "status": "pending" }] },
    }),
    content=(
      #|{
      #|  "stub": "pay-order",
      #|  "mock": "shop",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [
      #|    {
      #|      "op": "merge",
      #|      "bucket": "orders",
      #|      "key": "1002",
      #|      "value": {
      #|        "status": "paid",
      #|        "paidAt": "2026-10-12T14:30:05.123Z"
      #|      }
      #|    }
      #|  ],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"id\":1002,\"status\":\"paid\",\"paidAt\":\"2026-10-12T14:30:05.123Z\"}",
      #|      "size": 63,
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

///|
test "a rendering shows each write in order, with its rendered key and value and the new keys filled in, and the response reads the data after them all" {
  let h = render_harness(
    (
      #|  - id: checkout
      #|    mock: shop
      #|    request: { method: POST, path: /checkout }
      #|    dataWrites:
      #|      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
      #|      - { op: merge, bucket: cart, value: { coupon: "${body.coupon}" } }
      #|      - { op: append, bucket: log, value: "checkout ${body.coupon}" }
      #|      - { op: append, bucket: orders, value: { customerId: 42, status: pending } }
      #|      - { op: append, bucket: orders, value: { id: "x-1", status: pending } }
      #|      - { op: append, bucket: tokens, value: { user: ann } }
      #|      - { op: set, bucket: orders, key: "1001", value: { status: refunded } }
      #|      - { op: remove, bucket: orders, key: "${body.cancel}" }
      #|      - { op: merge, bucket: orders, key: "1004", value: { status: paid } }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { visits: "${data.visits}", cart: "${data.cart}", log: "${data.log}", orders: "${data.orders}", tokens: "${len(data.tokens)}" }
    ),
  )
  inspect(
    h.render_brief("checkout", {
      "method": "POST",
      "path": "/checkout",
      "body": "{\"coupon\": \"SPRING\", \"cancel\": 1002}",
      "data": { "visits": 41, "log": ["opened"] },
    }),
    content=(
      #|200 {"visits":42,"cart":{"items":[],"coupon":"SPRING"},"log":["opened","checkout SPRING"],"orders":[{"status":"refunded","id":1001},{"id":1003,"customerId":42,"status":"pending"},{"customerId":42,"status":"paid","id":1004},{"id":"x-1","status":"pending"}],"tokens":1}
      #|  dataWrites
      #|    {"op":"set","bucket":"visits","key":null,"value":42}
      #|    {"op":"merge","bucket":"cart","key":null,"value":{"coupon":"SPRING"}}
      #|    {"op":"append","bucket":"log","key":null,"value":"checkout SPRING"}
      #|    {"op":"append","bucket":"orders","key":null,"value":{"customerId":42,"status":"pending","id":1004}}
      #|    {"op":"append","bucket":"orders","key":null,"value":{"id":"x-1","status":"pending"}}
      #|    {"op":"append","bucket":"tokens","key":null,"value":{"user":"ann","token":"491faadb-213a-4ae9-b52a-e618828349a6"}}
      #|    {"op":"set","bucket":"orders","key":"1001","value":{"status":"refunded"}}
      #|    {"op":"remove","bucket":"orders","key":"1002","value":null}
      #|    {"op":"merge","bucket":"orders","key":"1004","value":{"status":"paid"}}
      #|  variables {}
      #|  templateError null
    ),
  )
}

///|
test "a rendering with the Stub's fault.seed shows the writes, new uuid keys included, and the response the first matched request makes" {
  let h = render_harness(
    (
      #|  - id: issue-token
      #|    mock: shop
      #|    request: { method: POST, path: /tokens }
      #|    fault: { seed: 5 }
      #|    variables: { nonce: "${fake.uuid()}" }
      #|    dataWrites:
      #|      - { op: append, bucket: log, value: "${fake.uuid()}" }
      #|      - { op: append, bucket: tokens, value: { user: "${fake.pick('ann', 'bob', 'cy')}" } }
      #|      - { op: append, bucket: tokens, value: { user: dee } }
      #|    response:
      #|      status: 201
      #|      template: true
      #|      json: { tokens: "${data.tokens}", log: "${data.log}", nonce: "${vars.nonce}", request: "${fake.uuid()}" }
      #|  - id: data
      #|    mock: shop
      #|    request: { method: GET, path: /data }
      #|    response: { status: 200, template: true, json: { tokens: "${data.tokens}", log: "${data.log}" } }
    ),
  )
  let rendered = h.render_brief("issue-token", {
    "method": "POST",
    "path": "/tokens",
  })
  let sent = reply(h.send("POST", "/tokens"))
  let stored = reply(h.send("GET", "/data"))
  inspect(
    "\{rendered}\nsent: \{sent}\nstored: \{stored}",
    content=(
      #|201 {"tokens":[{"user":"cy","token":"7717a213-09d2-4ad4-80d8-2d9a4d9cf728"},{"user":"dee","token":"66635c92-44a1-438d-92a9-cde27f178dfb"}],"log":["a886ba0c-7707-4f55-99e8-a3f0bad79efe"],"nonce":"27bc579a-af50-4383-8748-7b860f321914","request":"6f7da846-a4b3-4d4b-89a3-32d8d27ae773"}
      #|  dataWrites
      #|    {"op":"append","bucket":"log","key":null,"value":"a886ba0c-7707-4f55-99e8-a3f0bad79efe"}
      #|    {"op":"append","bucket":"tokens","key":null,"value":{"user":"cy","token":"7717a213-09d2-4ad4-80d8-2d9a4d9cf728"}}
      #|    {"op":"append","bucket":"tokens","key":null,"value":{"user":"dee","token":"66635c92-44a1-438d-92a9-cde27f178dfb"}}
      #|  variables {"nonce":"27bc579a-af50-4383-8748-7b860f321914"}
      #|  templateError null
      #|sent: 201 {"tokens":[{"user":"cy","token":"7717a213-09d2-4ad4-80d8-2d9a4d9cf728"},{"user":"dee","token":"66635c92-44a1-438d-92a9-cde27f178dfb"}],"log":["a886ba0c-7707-4f55-99e8-a3f0bad79efe"],"nonce":"27bc579a-af50-4383-8748-7b860f321914","request":"6f7da846-a4b3-4d4b-89a3-32d8d27ae773"}
      #|stored: 200 {"tokens":[{"user":"cy","token":"7717a213-09d2-4ad4-80d8-2d9a4d9cf728"},{"user":"dee","token":"66635c92-44a1-438d-92a9-cde27f178dfb"}],"log":["a886ba0c-7707-4f55-99e8-a3f0bad79efe"]}
    ),
  )
}

///|
test "a write that fails to render or to apply on the sample's data shows the 500 a request would get, with no write and no Variable" {
  let h = render_harness(
    (
      #|  - id: pay
      #|    mock: shop
      #|    request: { method: POST, path: /pay }
      #|    variables: { paid: "${body.amount ?? 0}" }
      #|    dataWrites:
      #|      - { op: append, bucket: log, value: "paid ${body.amount ?? 0}" }
      #|      - { op: merge, bucket: orders, key: "${body.order}", value: { status: paid } }
      #|      - { op: merge, bucket: cart, value: { paid: "${body.amount}" } }
      #|    response: { status: 200, template: true, json: "${data.orders}" }
    ),
  )
  let out = []
  for
    case in [
      // Every write applies.
      ("{\"order\": 1002, \"amount\": 9.5}", Json::object({})),
      // The key of the second write fails to render.
      ("{\"amount\": 9.5}", {}),
      // The value of the third write fails to render.
      ("{\"order\": 1002}", {}),
      // The sample's data has no order 1002.
      ("{\"order\": 1002, \"amount\": 9.5}", { "orders": [{ "id": 1001 }] }),
      // The sample's cart holds no object.
      ("{\"order\": 1002, \"amount\": 9.5}", { "cart": [] }),
    ] {
    let (body, data) = case
    out.push(
      h.render_brief("pay", {
        "method": "POST",
        "path": "/pay",
        "body": body,
        "data": data,
      }),
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|200 [{"id":1001,"customerId":42,"status":"paid"},{"id":1002,"customerId":7,"status":"paid"},{"id":1003,"customerId":42,"status":"pending"}]
      #|  dataWrites
      #|    {"op":"append","bucket":"log","key":null,"value":"paid 9.5"}
      #|    {"op":"merge","bucket":"orders","key":"1002","value":{"status":"paid"}}
      #|    {"op":"merge","bucket":"cart","key":null,"value":{"paid":9.5}}
      #|  variables {"paid":9.5}
      #|  templateError null
      #|500 {"error":"template failed","stub":"pay","at":"/dataWrites/1/key","message":"body.order is missing"}
      #|  dataWrites []
      #|  variables {}
      #|  templateError {"at":"/dataWrites/1/key","message":"body.order is missing"}
      #|500 {"error":"template failed","stub":"pay","at":"/dataWrites/2/value/paid","message":"body.amount is missing"}
      #|  dataWrites []
      #|  variables {}
      #|  templateError {"at":"/dataWrites/2/value/paid","message":"body.amount is missing"}
      #|500 {"error":"data write failed","stub":"pay","at":"/dataWrites/1","message":"the Data bucket \"orders\" has no item with the key \"1002\""}
      #|  dataWrites []
      #|  variables {}
      #|  templateError null
      #|500 {"error":"data write failed","stub":"pay","at":"/dataWrites/2","message":"the Data bucket \"cart\" holds an array, and \"merge\" needs an object"}
      #|  dataWrites []
      #|  variables {}
      #|  templateError null
    ),
  )
}

///|
test "a rendering neither reads nor writes a Session's copies, leaves the sample's data as it was, and applies no bound" {
  let stubs =
    #|  - id: add
    #|    mock: shop
    #|    request: { method: POST, path: /add }
    #|    dataWrites:
    #|      - { op: append, bucket: log, value: "${body}" }
    #|      - { op: merge, bucket: orders, key: "1001", value: { note: "${body}" } }
    #|    response: { status: 200, template: true, json: { log: "${data.log}", first: "${data.orders[0]}" } }
  let h = render_harness(stubs)
  let out = []
  // A request of the Session s makes its copies.
  out.push(
    "s sends a: \{reply(h.send("POST", "/add", body="\"a\"", session="s"))}",
  )
  let sample = @engine.SampleRequest::from_json({
    "method": "POST",
    "path": "/add",
    "body": "\"b\"",
    "session": "s",
    "data": { "log": ["sample"], "orders": [{ "id": 1001 }] },
  })
  let render = () => {
    let rendering = h.engine.render("add", sample, now=h.now, fresh_seed=() => 7)
    guard rendering.body is Bytes(body) else { "events" }
    "\{rendering.status} \{@utf8.decode_lossy(body)}"
  }
  out.push("render b: \{render()}")
  out.push("render b again: \{render()}")
  out.push("the sample's data: \{Json::object(sample.data).stringify()}")
  out.push(
    "s sends c: \{reply(h.send("POST", "/add", body="\"c\"", session="s"))}",
  )
  // With a bound that the orders alone pass, a request gets 507, and a
  // rendering is as before.
  let bounded = harness(
    [
      shop_file(
        (
          #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
          #|  - { mock: shop, name: log, json: [] }
        ),
        stubs,
      ),
    ],
    body_files=[("orders.json", @utf8.encode(orders_json))],
    state_max_bytes=100,
  )
  out.push(
    "bounded, s sends a: \{reply(bounded.send("POST", "/add", body="\"a\"", session="s"))}",
  )
  out.push(
    "bounded, render b: \{bounded.render_brief("add", { "method": "POST", "path": "/add", "body": "\"b\"" })}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|s sends a: 200 {"log":["a"],"first":{"id":1001,"customerId":42,"status":"paid","note":"a"}}
      #|render b: 200 {"log":["sample","b"],"first":{"id":1001,"note":"b"}}
      #|render b again: 200 {"log":["sample","b"],"first":{"id":1001,"note":"b"}}
      #|the sample's data: {"log":["sample"],"orders":[{"id":1001}]}
      #|s sends c: 200 {"log":["a","c"],"first":{"id":1001,"customerId":42,"status":"paid","note":"c"}}
      #|bounded, s sends a: 507 {"error":"state limit reached","stub":"add","message":"the writes would take per-Session state from 0 to 616 bytes, above its bound of 100 (--state-max-bytes)"}
      #|bounded, render b: 200 {"log":["b"],"first":{"id":1001,"customerId":42,"status":"paid","note":"b"}}
      #|  dataWrites
      #|    {"op":"append","bucket":"log","key":null,"value":"b"}
      #|    {"op":"merge","bucket":"orders","key":"1001","value":{"note":"b"}}
      #|  variables {}
      #|  templateError null
    ),
  )
}
