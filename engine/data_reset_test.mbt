// Seam 1 tests of how resets and reloads treat copies of Data buckets: each
// reset scope drops the copies in it and counts them, and a reload that
// swaps drops only the copies the new files make invalid: those of a Mock
// that is gone, of a bucket no longer declared, or of a bucket whose
// initial value or key changed. Dropped copies give their bytes back to the
// bound on per-Session state.

///|
/// The Mock `shop`, the Default Mock, with `orders`, keyed by `id`, from
/// `orders.json`, and `visits`, a number; and the Mock `bank`, for
/// `bank.svc`, with `accounts`, an array. In each, `GET /data` shows the
/// Mock's buckets as the request's Session reads them.
let shop_and_bank : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - { name: shop, default: true }
      #|data:
      #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
      #|  - { mock: shop, name: visits, json: 0 }
      #|stubs:
      #|  - id: shop-data
      #|    mock: shop
      #|    request: { method: GET, path: /data }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { orders: "${data.orders}", visits: "${data.visits}" }
    ),
  ),
  (
    "bank.yaml",
    (
      #|mocks:
      #|  - { name: bank, hosts: [bank.svc] }
      #|data:
      #|  - { mock: bank, name: accounts, json: [] }
      #|stubs:
      #|  - id: bank-data
      #|    mock: bank
      #|    request: { method: GET, path: /data }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { accounts: "${data.accounts}" }
    ),
  ),
]

///|
/// The body file of `shop_and_bank`: two orders.
let two_orders : (String, Bytes) = (
  "orders.json",
  @utf8.encode(
    (
      #|[{ "id": 1, "status": "paid" },
      #| { "id": 2, "status": "pending" }]
    ),
  ),
)

///|
/// A harness that serves `shop_and_bank`.
fn shop_and_bank_harness() -> Harness {
  harness(shop_and_bank, body_files=[two_orders])
}

///|
/// Resets `scope`: how many copies of Data buckets the reset dropped, the
/// rest of what it removed, and the bytes the bound on per-Session state
/// counts after it; or the error.
fn Harness::reset_data(self : Harness, scope : @engine.ResetScope) -> String {
  let removed = self.engine.reset(scope) catch {
    err => return @debug.to_string(err)
  }
  "removed \{removed.data_buckets} copies; \{removed.variables} Variables, \{removed.ephemeral_stubs} Ephemeral Stubs, \{removed.journal_entries} entries, \{removed.scenario_states} Scenario states; \{self.engine.state_stats().bytes} bytes"
}

///|
/// The buckets of `shop` and of `bank` as `session` reads them, or as
/// requests without a Session read them for `None`.
fn Harness::shop_and_bank(self : Harness, session : String?) -> String {
  let shop = reply(self.send("GET", "/data", session?))
  let bank = reply(self.send("GET", "http://bank.svc/data", session?))
  "shop \{shop}, bank \{bank}"
}

///|
/// Gives `test-a`, `test-b` and the no-Session space copies: `test-a` of
/// `orders` and `visits` of `shop` and of `accounts` of `bank`, the others
/// of `visits` and `accounts`. Fails the test if a set fails.
fn Harness::set_everywhere(self : Harness) -> Unit {
  let set = (session : String?, bucket : String, value : String, mock : String) => {
    let set = self.set_data(session, bucket, value, mock~)
    if !set.has_prefix("{") {
      abort(set)
    }
  }
  set(Some("test-a"), "orders", "[{\"id\": 9, \"status\": \"new\"}]", "shop")
  for session in [Some("test-a"), Some("test-b"), None] {
    let n = match session {
      Some("test-a") => "1"
      Some(_) => "2"
      None => "3"
    }
    set(session, "visits", n, "shop")
    set(session, "accounts", "[\{n}]", "bank")
  }
}

///|
test "each reset scope drops the copies in it and counts them: a Session's in every Mock, a Mock's of every Session and of the no-Session space, or every copy; the bytes go back" {
  let h = shop_and_bank_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  h.set_everywhere()
  step("bytes", h.engine.state_stats().bytes.to_string())
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("reset Session test-a", h.reset_data(Session(Some("test-a"))))
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("test-b", h.shop_and_bank(Some("test-b")))
  step("no Session", h.shop_and_bank(None))
  step("reset the no-Session space", h.reset_data(Session(None)))
  step("no Session", h.shop_and_bank(None))
  step("test-b", h.shop_and_bank(Some("test-b")))
  ignore(h.set_data(Some("test-a"), "visits", "4"))
  ignore(h.set_data(None, "visits", "5"))
  step("reset Mock shop", h.reset_data(Mock("shop")))
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("test-b", h.shop_and_bank(Some("test-b")))
  step("no Session", h.shop_and_bank(None))
  step("reset all", h.reset_data(All))
  step("test-b", h.shop_and_bank(Some("test-b")))
  step("reset all again", h.reset_data(All))
  inspect(
    out.join("\n"),
    content=(
      #|bytes: 1173
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reset Session test-a: removed 3 copies; 0 Variables, 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 672 bytes
      #|test-a: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":2}, bank 200 {"accounts":[2]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":3}, bank 200 {"accounts":[3]}
      #|reset the no-Session space: removed 2 copies; 0 Variables, 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 342 bytes
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":2}, bank 200 {"accounts":[2]}
      #|reset Mock shop: removed 3 copies; 0 Variables, 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 181 bytes
      #|test-a: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[2]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|reset all: removed 1 copies; 0 Variables, 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 0 bytes
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|reset all again: removed 0 copies; 0 Variables, 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 0 bytes
    ),
  )
}

///|
/// Reloads the engine of `h` with Definition files given as (name, text)
/// pairs and body files as (name, bytes) pairs: how the reload ended, how
/// many copies of Data buckets it dropped, and the bytes the bound on
/// per-Session state counts after it.
fn Harness::reload_data(
  self : Harness,
  files : Array[(String, String)],
  body_files? : Array[(String, Bytes)] = [two_orders],
) -> String {
  let result = self.reload(files, body_files~)
  "\{@debug.to_string(result.result)}, \{result.data_buckets_reset} copies dropped; \{self.engine.state_stats().bytes} bytes"
}

///|
/// `shop_and_bank` with the `shop` file changed by `edit`.
fn shop_edited(edit : (String) -> String) -> Array[(String, String)] {
  [(shop_and_bank[0].0, edit(shop_and_bank[0].1)), shop_and_bank[1]]
}

///|
test "a reload that swaps keeps the copies of buckets whose initial value and key did not change: an unrelated edit, a newKey change, and values moved between json and jsonFile" {
  let h = shop_and_bank_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  h.set_everywhere()
  step("bytes", h.engine.state_stats().bytes.to_string())
  step(
    "reload, the Stub's response edited",
    h.reload_data(
      shop_edited(text => {
        text.replace(old="json: { orders:", new="json: { edited: true, orders:")
      }),
    ),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step(
    "reload, orders makes uuid keys",
    h.reload_data(
      shop_edited(text => {
        text.replace(old="key: id,", new="key: id, newKey: uuid,")
      }),
    ),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step(
    "reload, orders inline and visits from visits.json",
    h.reload_data(
      shop_edited(text => {
        text
        .replace(
          old="jsonFile: orders.json",
          new="json: [{ id: 1, status: paid }, { id: 2.0, status: pending }]",
        )
        .replace(old="json: 0", new="jsonFile: visits.json")
      }),
      body_files=[("visits.json", b" 0\n")],
    ),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("no Session", h.shop_and_bank(None))
  h.now += 7L * 24 * 60 * 60 * 1000
  step("a week later, test-b", h.shop_and_bank(Some("test-b")))
  inspect(
    out.join("\n"),
    content=(
      #|bytes: 1173
      #|reload, the Stub's response edited: Swapped, 0 copies dropped; 1173 bytes
      #|test-a: shop 200 {"edited":true,"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reload, orders makes uuid keys: Swapped, 0 copies dropped; 1173 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reload, orders inline and visits from visits.json: Swapped, 0 copies dropped; 1173 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":3}, bank 200 {"accounts":[3]}
      #|a week later, test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":2}, bank 200 {"accounts":[2]}
    ),
  )
}

///|
/// `orders.json` with order 2 shipped.
let order_2_shipped : (String, Bytes) = (
  "orders.json",
  @utf8.encode(
    (
      #|[{ "id": 1, "status": "paid" },
      #| { "id": 2, "status": "shipped" }]
    ),
  ),
)

///|
test "a reload that swaps drops the copies of a bucket whose key or initial value changed, that is no longer declared, or whose Mock is gone, and counts them" {
  let h = shop_and_bank_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let by_status = (text : String) => {
    text.replace(old="key: id,", new="key: status,")
  }
  let visits_at_1 = (text : String) => {
    by_status(text).replace(old="json: 0", new="json: 1")
  }
  let without_visits = (text : String) => {
    by_status(text)
    .replace(old="  - { mock: shop, name: visits, json: 0 }\n", new="")
    .replace(old=", visits: \"${data.visits}\"", new="")
  }
  h.set_everywhere()
  step("bytes", h.engine.state_stats().bytes.to_string())
  step("reload, orders keyed by status", h.reload_data(shop_edited(by_status)))
  step("test-a", h.shop_and_bank(Some("test-a")))
  h.set_everywhere()
  step(
    "reload, orders.json edited",
    h.reload_data(shop_edited(by_status), body_files=[order_2_shipped]),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  h.set_everywhere()
  step(
    "reload, visits starts at 1",
    h.reload_data(shop_edited(visits_at_1), body_files=[order_2_shipped]),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("test-b", h.shop_and_bank(Some("test-b")))
  step("no Session", h.shop_and_bank(None))
  h.set_everywhere()
  step(
    "reload, visits removed",
    h.reload_data(shop_edited(without_visits), body_files=[order_2_shipped]),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step(
    "reload, bank removed",
    h.reload_data([shop_edited(without_visits)[0]], body_files=[order_2_shipped]),
  )
  step("reload, as at first", h.reload_data(shop_and_bank))
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("test-b", h.shop_and_bank(Some("test-b")))
  step("no Session", h.shop_and_bank(None))
  inspect(
    out.join("\n"),
    content=(
      #|bytes: 1173
      #|reload, orders keyed by status: Swapped, 1 copies dropped; 1014 bytes
      #|test-a: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reload, orders.json edited: Swapped, 1 copies dropped; 1014 bytes
      #|test-a: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"shipped"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reload, visits starts at 1: Swapped, 3 copies dropped; 770 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"shipped"}],"visits":1}, bank 200 {"accounts":[2]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"shipped"}],"visits":1}, bank 200 {"accounts":[3]}
      #|reload, visits removed: Swapped, 3 copies dropped; 770 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}]}, bank 200 {"accounts":[1]}
      #|reload, bank removed: Swapped, 3 copies dropped; 233 bytes
      #|reload, as at first: Swapped, 1 copies dropped; 0 bytes
      #|test-a: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|test-b: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":0}, bank 200 {"accounts":[]}
    ),
  )
}

///|
test "a reload that fails or finds the set unchanged keeps every copy" {
  let h = shop_and_bank_harness()
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  h.set_everywhere()
  step(
    "reload, orders.json edited, bank removed and a file invalid",
    h.reload_data([shop_and_bank[0], ("broken.json", "{ \"mocks\": ")], body_files=[
      order_2_shipped,
    ]),
  )
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("reload, the same files", h.reload_data(shop_and_bank))
  step("test-a", h.shop_and_bank(Some("test-a")))
  step("no Session", h.shop_and_bank(None))
  inspect(
    out.join("\n"),
    content=(
      #|reload, orders.json edited, bank removed and a file invalid: Failed, 0 copies dropped; 1173 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|reload, the same files: Unchanged, 0 copies dropped; 1173 bytes
      #|test-a: shop 200 {"orders":[{"id":9,"status":"new"}],"visits":1}, bank 200 {"accounts":[1]}
      #|no Session: shop 200 {"orders":[{"id":1,"status":"paid"},{"id":2,"status":"pending"}],"visits":3}, bank 200 {"accounts":[3]}
    ),
  )
}
