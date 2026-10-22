// Seam 1 tests of Session copies of Data buckets, and of the Admin API
// operations on them: listing the Mock's buckets, and reading, setting and
// dropping the calling Session's copy of one. A Session reads a bucket's
// initial value until it first writes to the bucket, which makes its own
// copy; requests without a Session share one copy.

///|
/// The Mock `shop`, the Default Mock, with the buckets `orders`, keyed by
/// `id`, from `orders.json`, `visits`, without `key`, and `tokens`, keyed by
/// `token` with `uuid` keys; `GET /api/v1/orders` answers `orders` and
/// `GET /api/v1/visits` answers `visits`. The ticket's example.
let shop_data : (String, String) = (
  "shop.yaml",
  (
    #|mocks:
    #|  - { name: shop, default: true }
    #|data:
    #|  - { mock: shop, name: visits, json: 0 }
    #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
    #|  - { mock: shop, name: tokens, key: token, newKey: uuid, json: [] }
    #|stubs:
    #|  - id: list-orders
    #|    mock: shop
    #|    request: { method: GET, path: /api/v1/orders }
    #|    response: { status: 200, template: true, json: "${data.orders}" }
    #|  - id: visits
    #|    mock: shop
    #|    request: { method: GET, path: /api/v1/visits }
    #|    response: { status: 200, template: true, body: "visits: ${data.visits}" }
  ),
)

///|
/// The body file of `shop_data`: three orders.
let orders_file : (String, Bytes) = (
  "orders.json",
  @utf8.encode(
    (
      #|[{ "id": 1, "status": "paid" }, { "id": 2, "status": "pending" },
      #| { "id": 3, "status": "paid" }]
    ),
  ),
)

///|
/// A harness that serves `shop_data`.
fn data_harness(state_max_bytes? : Int) -> Harness {
  harness([shop_data], body_files=[orders_file], state_max_bytes?)
}

///|
/// A bucket as the Admin API reads it, as compact JSON, or the error.
fn bucket_text(bucket : @engine.SessionBucket) -> String {
  let new_key = match bucket.new_key {
    Some(new_key) => Json::string(new_key.name())
    None => Json::null()
  }
  let json : Json = {
    "name": Json::string(bucket.name),
    "key": bucket.key.map_or(Json::null(), Json::string),
    "newKey": new_key,
    "written": Json::boolean(bucket.written),
    "value": bucket.value,
  }
  json.stringify()
}

///|
/// An error of the Admin API operations on Data buckets, with each problem
/// of a value that breaks a keyed bucket's rules on a line of its own.
fn data_error(err : Error) -> String {
  match err {
    @engine.InvalidData(bucket~, key~, problems~) => {
      let lines = problems.map(p => "\n    \{p.pointer.escape()}: \{p.message}")
      "InvalidData(bucket=\{bucket.escape()}, key=\{key.escape()})\{lines.join("")}"
    }
    err => @debug.to_string(err)
  }
}

///|
/// Sets the calling Session's copy of `bucket` of `shop` to `value`, given
/// as JSON text: the bucket as the reply shows it, or the error.
fn Harness::set_data(
  self : Harness,
  session : String?,
  bucket : String,
  value : String,
  mock? : String = "shop",
) -> String {
  let bucket = self.engine.set_data(
    mock~,
    session~,
    bucket~,
    @json.parse(value),
  ) catch {
    err => return data_error(err)
  }
  bucket_text(bucket)
}

///|
/// Drops the calling Session's copy of `bucket` of `shop`: the bucket as
/// the reply shows it, then `(a copy dropped)` when there was one, or the
/// error.
fn Harness::drop_data(
  self : Harness,
  session : String?,
  bucket : String,
  mock? : String = "shop",
) -> String {
  let result = self.engine.drop_data(mock~, session~, bucket~) catch {
    err => return data_error(err)
  }
  let dropped = if result.dropped { " (a copy dropped)" } else { "" }
  "\{bucket_text(result.bucket)}\{dropped}"
}

///|
test "set gives the calling Session its own copy, which its requests read; another Session reads the initial value; drop brings it back" {
  let h = data_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let orders = (session : String?) => {
    reply(h.send("GET", "/api/v1/orders", session?))
  }
  step(
    "checkout-42 sets orders",
    h.set_data(
      Some("checkout-42"),
      "orders",
      "[{\"id\":1,\"status\":\"paid\"}]",
    ),
  )
  step("checkout-42 lists orders", orders(Some("checkout-42")))
  step("checkout-43 lists orders", orders(Some("checkout-43")))
  step("no Session lists orders", orders(None))
  step("checkout-42 drops orders", h.drop_data(Some("checkout-42"), "orders"))
  step("checkout-42 lists orders", orders(Some("checkout-42")))
  inspect(
    out.join("\n"),
    content=(
      #|checkout-42 sets orders: {"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":1,"status":"paid"}]}
      #|checkout-42 lists orders: 200 [{"id":1,"status":"paid"}]
      #|checkout-43 lists orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
      #|no Session lists orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
      #|checkout-42 drops orders: {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]} (a copy dropped)
      #|checkout-42 lists orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]
    ),
  )
}

///|
/// The calling Session's buckets of `mock` as the engine lists them, one
/// per line, or the error.
fn Harness::list_data(
  self : Harness,
  session : String?,
  mock? : String = "shop",
) -> String {
  let buckets = self.engine.list_data(mock~, session~) catch {
    err => return data_error(err)
  }
  buckets.map(bucket => "  \{bucket_text(bucket)}").join("\n")
}

///|
/// The calling Session's bucket `bucket` of `mock` as the engine reads it,
/// or the error.
fn Harness::read_data(
  self : Harness,
  session : String?,
  bucket : String,
  mock? : String = "shop",
) -> String {
  let bucket = self.engine.read_data(mock~, session~, bucket~) catch {
    err => return data_error(err)
  }
  bucket_text(bucket)
}

///|
test "list gives the Mock's buckets by name, each with whether the calling Session holds a copy and what it reads; reads never copy" {
  let h = data_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}:\n\{result}")
  }
  ignore(h.send("GET", "/api/v1/orders", session="checkout-42"))
  ignore(h.send("GET", "/api/v1/visits", session="checkout-42"))
  step("checkout-42 lists after two reads", h.list_data(Some("checkout-42")))
  step("bytes counted", h.engine.state_stats().bytes.to_string())
  ignore(h.set_data(Some("checkout-42"), "visits", "7"))
  step("checkout-42 lists", h.list_data(Some("checkout-42")))
  step("checkout-43 lists", h.list_data(Some("checkout-43")))
  step("checkout-42 reads visits", h.read_data(Some("checkout-42"), "visits"))
  step(
    "checkout-42 GET /api/v1/visits",
    reply(h.send("GET", "/api/v1/visits", session="checkout-42")),
  )
  step("checkout-43 reads visits", h.read_data(Some("checkout-43"), "visits"))
  inspect(
    out.join("\n"),
    content=(
      #|checkout-42 lists after two reads:
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":false,"value":0}
      #|bytes counted:
      #|0
      #|checkout-42 lists:
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":true,"value":7}
      #|checkout-43 lists:
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":false,"value":0}
      #|checkout-42 reads visits:
      #|{"name":"visits","key":null,"newKey":null,"written":true,"value":7}
      #|checkout-42 GET /api/v1/visits:
      #|200 visits: 7
      #|checkout-43 reads visits:
      #|{"name":"visits","key":null,"newKey":null,"written":false,"value":0}
    ),
  )
}

///|
test "requests without a Session share one copy, apart from every Session's" {
  let h = data_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let visits = (session : String?) => {
    reply(h.send("GET", "/api/v1/visits", session?))
  }
  step("no Session sets visits", h.set_data(None, "visits", "5"))
  step("no Session GET", visits(None))
  step("no Session GET again", visits(None))
  step("checkout-42 GET", visits(Some("checkout-42")))
  step(
    "checkout-42 sets visits",
    h.set_data(Some("checkout-42"), "visits", "1"),
  )
  step("no Session reads", h.read_data(None, "visits"))
  step("no Session drops visits", h.drop_data(None, "visits"))
  step("no Session GET", visits(None))
  step("checkout-42 GET", visits(Some("checkout-42")))
  inspect(
    out.join("\n"),
    content=(
      #|no Session sets visits: {"name":"visits","key":null,"newKey":null,"written":true,"value":5}
      #|no Session GET: 200 visits: 5
      #|no Session GET again: 200 visits: 5
      #|checkout-42 GET: 200 visits: 0
      #|checkout-42 sets visits: {"name":"visits","key":null,"newKey":null,"written":true,"value":1}
      #|no Session reads: {"name":"visits","key":null,"newKey":null,"written":true,"value":5}
      #|no Session drops visits: {"name":"visits","key":null,"newKey":null,"written":false,"value":0} (a copy dropped)
      #|no Session GET: 200 visits: 0
      #|checkout-42 GET: 200 visits: 1
    ),
  )
}

///|
test "errors: an unknown Mock, a bucket the Mock does not declare, and a value that breaks a keyed bucket's rules, which writes nothing" {
  let bank = (
    "bank.yaml",
    (
      #|mocks:
      #|  - { name: bank, hosts: [bank.svc] }
      #|data:
      #|  - { mock: bank, name: accounts, key: iban, json: [] }
    ),
  )
  let h = harness([shop_data, bank], body_files=[orders_file])
  let session = Some("checkout-42")
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("list of an unknown Mock", h.list_data(session, mock="orders"))
  step("read of an unknown Mock", h.read_data(session, "orders", mock="orders"))
  step("set of an unknown Mock", h.set_data(session, "orders", "[]", mock="x"))
  step("drop of an unknown Mock", h.drop_data(session, "orders", mock="x"))
  step("read of another Mock's bucket", h.read_data(session, "accounts"))
  step("set of a name that is no bucket's", h.set_data(session, "a.b", "1"))
  step("drop of an unknown bucket", h.drop_data(session, "order"))
  step("set of orders to an object", h.set_data(session, "orders", "{}"))
  step(
    "set of orders with a bad item, a missing key, an invalid key and a key taken",
    h.set_data(
      session,
      "orders",
      (
        #|[1, {"status": "paid"}, {"id": "a/b"}, {"id": 1.5}, {"id": 42},
        #| {"id": "42"}, {"id": ""}]
      ),
    ),
  )
  step(
    "set of accounts with a key taken",
    h.set_data(
      session,
      "accounts",
      "[{\"iban\": \"x\"}, {\"iban\": \"x\"}]",
      mock="bank",
    ),
  )
  out.push("checkout-42 lists:\n" + h.list_data(session))
  step("bytes counted", h.engine.state_stats().bytes.to_string())
  inspect(
    out.join("\n"),
    content=(
      #|list of an unknown Mock: UnknownMock("orders")
      #|read of an unknown Mock: UnknownMock("orders")
      #|set of an unknown Mock: UnknownMock("x")
      #|drop of an unknown Mock: UnknownMock("x")
      #|read of another Mock's bucket: UnknownBucket(mock="shop", bucket="accounts")
      #|set of a name that is no bucket's: UnknownBucket(mock="shop", bucket="a.b")
      #|drop of an unknown bucket: UnknownBucket(mock="shop", bucket="order")
      #|set of orders to an object: InvalidData(bucket="orders", key="id")
      #|    "": must be an array of objects, since the bucket has "key"
      #|set of orders with a bad item, a missing key, an invalid key and a key taken: InvalidData(bucket="orders", key="id")
      #|    "/0": must be an object with the key member "id"
      #|    "/1": needs the key member "id"
      #|    "/2/id": must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|    "/3/id": must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|    "/5/id": has the key text "42", as item 4 does
      #|    "/6/id": must be a key: a non-empty string without /, or an integer from -9007199254740991 to 9007199254740991
      #|set of accounts with a key taken: InvalidData(bucket="accounts", key="iban")
      #|    "/1/iban": has the key text "x", as item 0 does
      #|checkout-42 lists:
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":false,"value":0}
      #|bytes counted: 0
    ),
  )
}

///|
test "set makes a copy even with the initial value, takes any JSON value in a bucket without key, and keeps a keyed bucket's integer keys as written" {
  let h = data_harness()
  let session = Some("checkout-42")
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("set visits to its initial value", h.set_data(session, "visits", "0"))
  step("set visits to null", h.set_data(session, "visits", "null"))
  step(
    "set orders, keys written as 42.0 and 4.3e1",
    h.set_data(
      session, "orders", "[{\"id\": 42.0}, {\"id\": 4.3e1}, {\"id\": \"x\"}]",
    ),
  )
  step("set tokens to []", h.set_data(session, "tokens", "[]"))
  out.push("checkout-42 lists:\n" + h.list_data(session))
  step(
    "checkout-42 lists orders",
    reply(h.send("GET", "/api/v1/orders", session="checkout-42")),
  )
  step("drop tokens", h.drop_data(session, "tokens"))
  step("drop tokens again", h.drop_data(session, "tokens"))
  inspect(
    out.join("\n"),
    content=(
      #|set visits to its initial value: {"name":"visits","key":null,"newKey":null,"written":true,"value":0}
      #|set visits to null: {"name":"visits","key":null,"newKey":null,"written":true,"value":null}
      #|set orders, keys written as 42.0 and 4.3e1: {"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":42},{"id":43},{"id":"x"}]}
      #|set tokens to []: {"name":"tokens","key":"token","newKey":"uuid","written":true,"value":[]}
      #|checkout-42 lists:
      #|  {"name":"orders","key":"id","newKey":"integer","written":true,"value":[{"id":42},{"id":43},{"id":"x"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":true,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":true,"value":null}
      #|checkout-42 lists orders: 200 [{"id":42},{"id":43},{"id":"x"}]
      #|drop tokens: {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]} (a copy dropped)
      #|drop tokens again: {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
    ),
  )
}

///|
test "a rendering reads each bucket's initial value, also when the sample names a Session that holds a copy, and writes no copy" {
  let h = data_harness()
  ignore(h.set_data(Some("checkout-42"), "visits", "7"))
  let render = (sample : Json) => {
    let rendering = h.engine.render(
      "visits",
      @engine.SampleRequest::from_json(sample),
      now=h.now,
      fresh_seed=() => 7,
    ) catch {
      err => return @debug.to_string(err)
    }
    match rendering.body {
      Bytes(body) => "\{rendering.status} \{@utf8.decode_lossy(body)}"
      Events(_) => "(events)"
    }
  }
  inspect(
    [
      render({ "path": "/api/v1/visits", "session": "checkout-42" }),
      render({ "path": "/api/v1/visits", "session": "checkout-43" }),
      render({ "path": "/api/v1/visits" }),
      reply(h.send("GET", "/api/v1/visits", session="checkout-42")),
      h.list_data(Some("checkout-43")),
      "\{h.state_bytes()} bytes",
    ].join("\n"),
    content=(
      #|200 visits: 0
      #|200 visits: 0
      #|200 visits: 0
      #|200 visits: 7
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
      #|  {"name":"visits","key":null,"newKey":null,"written":false,"value":0}
      #|166 bytes
    ),
  )
}

///|
test "the values of a Stub's Variables, its templates and the calling Session's Ephemeral Stubs read the Session's copy" {
  let counter = (
    "counter.yaml",
    (
      #|stubs:
      #|  - id: remember
      #|    mock: shop
      #|    request: { method: POST, path: /remember }
      #|    variables: { seen: "${data.visits}" }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { seen: "${vars.seen}", now: "${data.visits}", paid: "${find(data.orders, 'status', 'paid').id ?? 'none'}" }
    ),
  )
  let h = harness([shop_data, counter], body_files=[orders_file])
  ignore(
    h.set_data(
      Some("checkout-42"),
      "orders",
      "[{\"id\": 9, \"status\": \"paid\"}]",
    ),
  )
  ignore(h.set_data(Some("checkout-42"), "visits", "5"))
  let added = h.engine.add_ephemeral_stub(
    mock="shop",
    session=Some("checkout-42"),
    @json.parse(
      (
        #|{ "request": { "path": "/count" },
        #|  "response": { "status": 200, "template": true,
        #|    "body": "${len(data.orders)} orders, ${data.visits} visits" } }
      ),
    ),
  )
  inspect(added.id, content="eph-1")
  inspect(
    [
      reply(h.send("POST", "/remember", session="checkout-42")),
      reply(h.send("POST", "/remember", session="checkout-43")),
      reply(h.send("GET", "/count", session="checkout-42")),
    ].join("\n"),
    content=(
      #|200 {"seen":5,"now":5,"paid":9}
      #|200 {"seen":0,"now":0,"paid":1}
      #|200 1 orders, 5 visits
    ),
  )
}

///|
test "a copy of a bucket that a reload removed is never read, and the bucket is unknown to the Admin API" {
  let h = data_harness()
  ignore(h.set_data(None, "visits", "5"))
  let added = h.engine.add_ephemeral_stub(
    mock="shop",
    session=None,
    @json.parse(
      (
        #|{ "request": { "path": "/count" },
        #|  "response": { "status": 200, "template": true,
        #|    "body": "${data.visits ?? 'no'} visits" } }
      ),
    ),
  )
  inspect(added.id, content="eph-1")
  let out = [reply(h.send("GET", "/count"))]
  let without_visits =
    #|mocks:
    #|  - { name: shop, default: true }
    #|data:
    #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
    #|  - { mock: shop, name: tokens, key: token, newKey: uuid, json: [] }
  out.push(
    @debug.to_string(
      h.reload([("shop.yaml", without_visits)], body_files=[orders_file]).result,
    ),
  )
  out.push(reply(h.send("GET", "/count")))
  out.push(h.read_data(None, "visits"))
  out.push(h.list_data(None))
  inspect(
    out.join("\n"),
    content=(
      #|200 5 visits
      #|Swapped
      #|200 no visits
      #|UnknownBucket(mock="shop", bucket="visits")
      #|  {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}
      #|  {"name":"tokens","key":"token","newKey":"uuid","written":false,"value":[]}
    ),
  )
}
