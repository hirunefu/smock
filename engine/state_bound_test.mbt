// Seam 1 tests of the bound on per-Session state: one count, for the whole
// process, of the bytes Variables and the copies of Data buckets take, by
// one rule, against the bound the engine was created with; and the 507 of
// a request or an Admin API set whose writes would take the count above
// it.

///|
/// The Mock `shop`, where `POST /count` writes `count: 1`, the example of
/// the docs, and `POST /cart/items` stores the request's body in `last`, the
/// example of ticket #89.
let shop_state : (String, String) = (
  "shop.yaml",
  (
    #|mocks:
    #|  - name: shop
    #|stubs:
    #|  - id: count
    #|    mock: shop
    #|    request: { method: POST, path: /count }
    #|    variables:
    #|      count: 1
    #|    response: { status: 204 }
    #|  - id: add-cart-item
    #|    mock: shop
    #|    request: { method: POST, path: /cart/items }
    #|    variables:
    #|      last: ${body}
    #|    response: { status: 201 }
  ),
)

///|
/// The bytes the count of per-Session state holds now.
fn Harness::state_bytes(self : Harness) -> Int {
  self.engine.state_stats().bytes
}

///|
test "the count: a space counts its Mock name, its Session key and 64 while it holds a Variable; each Variable its name, 64, and its value's compact JSON with 16 per JSON value" {
  let h = harness([shop_state])
  let out = ["nothing written: \{h.state_bytes()}"]
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push("\{label}: \{outcome.plan.status}, \{h.state_bytes()} bytes")
  }
  // The space of shop and run-42: 4 + 6 + 64. The Variable count: 5 + 64,
  // and 1 + 16 for its value.
  step("count: 1 in run-42", h.send("POST", "/count", session="run-42"))
  step("the same value again", h.send("POST", "/count", session="run-42"))
  // last: 4 + 64, and {"a":[1,"x"],"b":null}, 22 bytes and five JSON
  // values: the object, the array, 1, "x" and null.
  step(
    "last in run-42",
    h.send(
      "POST",
      "/cart/items",
      body="{ \"a\": [1, \"x\"], \"b\": null }",
      session="run-42",
    ),
  )
  // The no-Session space has no key: 4 + 64, then 86 for count.
  step("count: 1 without a Session", h.send("POST", "/count"))
  // テスト takes 9 bytes of UTF-8: 4 + 9 + 64, then 86.
  step("count: 1 in テスト", h.send("POST", "/count", session="テスト"))
  // "é\n" takes 6 bytes as compact JSON (é is 2 bytes, \n is written as
  // 2), one JSON value: 22 in place of last's 102.
  step(
    "last replaced in run-42",
    h.send("POST", "/cart/items", body="\"é\\n\"", session="run-42"),
  )
  inspect(
    out.join("\n"),
    content=(
      #|nothing written: 0
      #|count: 1 in run-42: 204, 160 bytes
      #|the same value again: 204, 160 bytes
      #|last in run-42: 201, 330 bytes
      #|count: 1 without a Session: 204, 484 bytes
      #|count: 1 in テスト: 204, 647 bytes
      #|last replaced in run-42: 201, 567 bytes
    ),
  )
}

///|
/// The Mock `shop`, the Default Mock, with Stubs that store the request's
/// body in `last`: `add-cart-item` (ticket #89's example, with a Scenario
/// move and a delay), `pick`, with two responses, and `cut`, with a
/// connection Fault; `small` writes `small: 1`. `GET /vars` shows the
/// Variables and `GET /flow` the Scenario state.
let bounded_shop : (String, String) = (
  "shop.yaml",
  (
    #|mocks:
    #|  - { name: shop, default: true }
    #|stubs:
    #|  - id: add-cart-item
    #|    mock: shop
    #|    request: { method: POST, path: /cart/items }
    #|    scenario: { name: flow, moveTo: Added }
    #|    variables:
    #|      last: ${body}
    #|    response: { status: 201 }
    #|    fault: { delay: { fixed: 250 } }
    #|  - id: pick
    #|    mock: shop
    #|    request: { method: POST, path: /pick }
    #|    variables:
    #|      count: ${add(vars.count ?? 0, 1)}
    #|      last: ${body}
    #|    responses:
    #|      - { status: 200 }
    #|      - { status: 201 }
    #|  - id: cut
    #|    mock: shop
    #|    request: { method: POST, path: /cut }
    #|    variables: { last: "${body}" }
    #|    response: { status: 200 }
    #|    fault: { connection: { kind: reset } }
    #|  - id: small
    #|    mock: shop
    #|    request: { method: POST, path: /small }
    #|    variables: { small: 1 }
    #|    response: { status: 204 }
    #|  - id: vars
    #|    mock: shop
    #|    request: { method: GET, path: /vars }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: { count: "${vars.count ?? null}", last: "${vars.last ?? null}", small: "${vars.small ?? null}" }
    #|  - id: flow
    #|    mock: shop
    #|    request: { method: GET, path: /flow }
    #|    scenario: { name: flow, requires: Added }
    #|    response: { status: 200, body: Added }
  ),
)

///|
test "at the bound: a write that would take the count above it writes nothing and answers 507, with no response picked, after the Scenario move and with the Stub's delay" {
  let h = harness([bounded_shop], state_max_bytes=250)
  let out = []
  // shop's space counts 4 + 64 = 68, and small: 1 counts 5 + 64 + 1 + 16
  // = 86.
  let small = h.send("POST", "/small")
  out.push("small: \{journaled(small)}; \{h.state_bytes()} bytes")
  // last: "aaaaaaaaaaa" would count 4 + 64 + 13 + 16 = 97: 251 in all.
  let refused = h.send("POST", "/cart/items", body="\"aaaaaaaaaaa\"")
  inspect(
    describe(refused),
    content=(
      #|plan:
      #|  status: 507
      #|  header: Content-Type: application/json
      #|  header: Smock-Mock: shop; via=default
      #|  body: "{\"error\":\"state limit reached\",\"stub\":\"add-cart-item\",\"message\":\"the writes would take per-Session state from 154 to 251 bytes, above its bound of 250 (--state-max-bytes)\"}"
      #|  delay_ms: 250
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("shop")
      #|  via_default: true
      #|  request: POST /cart/items HTTP/1.1
      #|  body: "\"aaaaaaaaaaa\""
      #|  stub: Some("add-cart-item")
      #|  status: Some(507)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
  out.push("refused: \{journaled(refused)}; \{h.state_bytes()} bytes")
  out.push(
    "the Scenario move stands: \{@debug.to_string(refused.scenario)}, then \{reply(h.send("GET", "/flow"))}",
  )
  out.push("nothing written: \{reply(h.send("GET", "/vars"))}")
  // A Stub with responses picks none: count and last would need 86 + 97.
  let picked = h.send("POST", "/pick", body="\"aaaaaaaaaaa\"")
  out.push("with responses: \{reply(picked)}; \{journaled(picked)}")
  // A connection Fault still replaces the response.
  let cut = h.send("POST", "/cut", body="\"aaaaaaaaaaa\"")
  out.push("with a connection Fault: \{decision(cut)}; \{journaled(cut)}")
  out.push("still nothing written: \{reply(h.send("GET", "/vars"))}")
  // One character less takes the count to the bound exactly, which fits.
  let fits = h.send("POST", "/cart/items", body="\"aaaaaaaaaa\"")
  out.push("to the bound: \{journaled(fits)}; \{h.state_bytes()} bytes")
  let more = h.send("POST", "/cart/items", body="\"aaaaaaaaaaa\"")
  out.push("past it: \{reply(more)}")
  // A write that replaces a value with a smaller one fits.
  let smaller = h.send("POST", "/cart/items", body="\"a\"")
  out.push("smaller: \{journaled(smaller)}; \{h.state_bytes()} bytes")
  out.push("refused requests: \{h.engine.state_stats().writes_refused}")
  inspect(
    out.join("\n"),
    content=(
      #|small: status 204, responseIndex null, variablesWritten [small], templateError none; 154 bytes
      #|refused: status 507, responseIndex null, variablesWritten [], templateError none; 154 bytes
      #|the Scenario move stands: Some({ name: "flow", from: "Started", to: "Added" }), then 200 Added
      #|nothing written: 200 {"count":null,"last":null,"small":1}
      #|with responses: 507 {"error":"state limit reached","stub":"pick","message":"the writes would take per-Session state from 154 to 337 bytes, above its bound of 250 (--state-max-bytes)"}; status 507, responseIndex null, variablesWritten [], templateError none
      #|with a connection Fault: delay 0, Reset; status no status, responseIndex null, variablesWritten [], templateError none
      #|still nothing written: 200 {"count":null,"last":null,"small":1}
      #|to the bound: status 201, responseIndex null, variablesWritten [last], templateError none; 250 bytes
      #|past it: 507 {"error":"state limit reached","stub":"add-cart-item","message":"the writes would take per-Session state from 250 to 251 bytes, above its bound of 250 (--state-max-bytes)"}
      #|smaller: status 201, responseIndex null, variablesWritten [last], templateError none; 241 bytes
      #|refused requests: 4
    ),
  )
}

///|
test "the bytes go back when Variables are reset or dropped by a reload, and a write the bound refused then fits" {
  // counting_mocks: shop, the Default Mock, counts `count` and `last`;
  // bank, for bank.svc, adds 10 to `balance`. The bound is exactly what
  // the six writes below take.
  let h = harness(counting_mocks, state_max_bytes=1062)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}; \{h.state_bytes()} bytes")
  }
  let count = (by : String, session : String?) => {
    reply(h.send("POST", "/count?by=\{by}", session?))
  }
  let deposit = (session : String?) => {
    reply(h.send("POST", "http://bank.svc/deposit", session?))
  }
  // shop and test-a: 4 + 6 + 64; count: 1, 5 + 64 + 1 + 16; last: "ann",
  // 4 + 64 + 5 + 16.
  step("count, test-a", count("ann", Some("test-a")))
  // count: 2 replaces count: 1, which counted the same.
  step("count again, test-a", count("ann", Some("test-a")))
  // bank and test-a: 4 + 6 + 64; balance: 10, 7 + 64 + 2 + 16.
  step("deposit, test-a", deposit(Some("test-a")))
  step("count, test-b", count("bob", Some("test-b")))
  // shop without a Session: 4 + 64; count 86; last: "anon", 4 + 64 + 6 + 16.
  step("count, no Session", count("anon", None))
  step("deposit, no Session", deposit(None))
  // One byte more than "anon" does not fit.
  step("count as anon2, no Session", count("anon2", None))
  step("reset Session test-a", h.reset_all_kinds(Session(Some("test-a"))))
  step("count as anon2, no Session", count("anon2", None))
  step("reset Mock bank", h.reset_all_kinds(Mock("bank")))
  step("deposit, test-b", deposit(Some("test-b")))
  step(
    "reload without bank",
    @debug.to_string(h.reload([counting_mocks[0]]).result),
  )
  step("reset all", h.reset_all_kinds(All))
  inspect(
    out.join("\n"),
    content=(
      #|count, test-a: 204 ; 249 bytes
      #|count again, test-a: 204 ; 249 bytes
      #|deposit, test-a: 204 ; 412 bytes
      #|count, test-b: 204 ; 661 bytes
      #|count, no Session: 204 ; 905 bytes
      #|deposit, no Session: 204 ; 1062 bytes
      #|count as anon2, no Session: 507 {"error":"state limit reached","stub":"count","message":"the writes would take per-Session state from 1062 to 1063 bytes, above its bound of 1062 (--state-max-bytes)"}; 1062 bytes
      #|reset Session test-a: removed 3 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 650 bytes
      #|count as anon2, no Session: 204 ; 651 bytes
      #|reset Mock bank: removed 1 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 494 bytes
      #|deposit, test-b: 204 ; 657 bytes
      #|reload without bank: Swapped; 494 bytes
      #|reset all: removed 4 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states; 0 bytes
    ),
  )
}

///|
/// `done` for the reply of an Admin API operation on a Data bucket that
/// succeeded, or else the error it gives.
fn done(reply : String) -> String {
  if reply.has_prefix("{") {
    "done"
  } else {
    reply
  }
}

///|
test "the count of copies: a space counts once, with Variables or copies; each copy counts its bucket's name, 64, and its value's compact JSON with 16 per JSON value" {
  let h = data_harness()
  let out = ["nothing written: \{h.state_bytes()}"]
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}, \{h.state_bytes()} bytes")
  }
  let long = "k".repeat(1000)
  // The space of shop and run-42: 4 + 6 + 64. The copy of visits: 6 + 64,
  // and 1 + 16 for 7.
  step("visits: 7 in run-42", done(h.set_data(Some("run-42"), "visits", "7")))
  step("the same value again", done(h.set_data(Some("run-42"), "visits", "7")))
  // [[],[],[]]: 10 bytes and four JSON values, in place of 7's 1 + 16.
  step(
    "visits: [[],[],[]] in run-42",
    done(h.set_data(Some("run-42"), "visits", "[[],[],[]]")),
  )
  // orders: 6 + 64, and [{"id":1}], 10 bytes and three JSON values.
  step(
    "orders in run-42",
    done(h.set_data(Some("run-42"), "orders", "[{\"id\": 1}]")),
  )
  // A Variable in the same space counts its name, 64 and its value, but no
  // space again: 1 + 64 + 1 + 16.
  h.engine.set_variable(mock="shop", session=Some("run-42"), name="a", 1)
  step("a Variable in run-42", "done")
  // A Session key of 1,000 bytes: 4 + 1000 + 64, then 87 for visits: 7.
  step(
    "visits: 7 for a long Session key",
    done(h.set_data(Some(long), "visits", "7")),
  )
  // テスト takes 9 bytes of UTF-8: 4 + 9 + 64, then 87.
  step(
    "visits: 7 in テスト",
    done(h.set_data(Some("テスト"), "visits", "7")),
  )
  // The no-Session space has no key: 4 + 64, then 87.
  step("visits: 7 without a Session", done(h.set_data(None, "visits", "7")))
  // The space stays while it holds the Variable.
  step("drop visits in run-42", done(h.drop_data(Some("run-42"), "visits")))
  step("drop orders in run-42", done(h.drop_data(Some("run-42"), "orders")))
  h.engine.delete_variable(mock="shop", session=Some("run-42"), name="a")
  step("delete the Variable in run-42", "done")
  step(
    "drop visits for the long Session key",
    done(h.drop_data(Some(long), "visits")),
  )
  step(
    "drop visits in テスト",
    done(h.drop_data(Some("テスト"), "visits")),
  )
  step("drop visits without a Session", done(h.drop_data(None, "visits")))
  inspect(
    out.join("\n"),
    content=(
      #|nothing written: 0
      #|visits: 7 in run-42: done, 161 bytes
      #|the same value again: done, 161 bytes
      #|visits: [[],[],[]] in run-42: done, 218 bytes
      #|orders in run-42: done, 346 bytes
      #|a Variable in run-42: done, 428 bytes
      #|visits: 7 for a long Session key: done, 1583 bytes
      #|visits: 7 in テスト: done, 1747 bytes
      #|visits: 7 without a Session: done, 1902 bytes
      #|drop visits in run-42: done, 1758 bytes
      #|drop orders in run-42: done, 1630 bytes
      #|delete the Variable in run-42: done, 1474 bytes
      #|drop visits for the long Session key: done, 319 bytes
      #|drop visits in テスト: done, 155 bytes
      #|drop visits without a Session: done, 0 bytes
    ),
  )
}

///|
test "at the bound: a set that would take the count above it writes nothing and is refused, reads still answer, and a drop gives the bytes back for a later set" {
  let h = data_harness(state_max_bytes=250)
  let out = []
  let step = (label : String, result : String) => {
    out.push(
      "\{label}: \{result}; \{h.state_bytes()} bytes, \{h.engine.state_stats().writes_refused} refused",
    )
  }
  // 74 for the space of shop and run-42, and 87 for visits: 7.
  step("visits: 7", done(h.set_data(Some("run-42"), "visits", "7")))
  // orders: [{"id":1}] would count 128 more.
  step(
    "orders: [{\"id\":1}]",
    done(h.set_data(Some("run-42"), "orders", "[{\"id\": 1}]")),
  )
  step("read orders", h.read_data(Some("run-42"), "orders"))
  step(
    "GET /api/v1/orders",
    reply(h.send("GET", "/api/v1/orders", session="run-42")),
  )
  // A string of 100 x would count 102 + 16 in place of 7's 1 + 16.
  let xs = "\"\{"x".repeat(100)}\""
  step("visits: 100 x", done(h.set_data(Some("run-42"), "visits", xs)))
  step("read visits", h.read_data(Some("run-42"), "visits"))
  // A smaller value always fits.
  step("visits: 1", done(h.set_data(Some("run-42"), "visits", "1")))
  step("drop visits", done(h.drop_data(Some("run-42"), "visits")))
  step(
    "orders: [{\"id\":1}]",
    done(h.set_data(Some("run-42"), "orders", "[{\"id\": 1}]")),
  )
  inspect(
    out.join("\n"),
    content=(
      #|visits: 7: done; 161 bytes, 0 refused
      #|orders: [{"id":1}]: StateLimitReached("the writes would take per-Session state from 161 to 289 bytes, above its bound of 250 (--state-max-bytes)"); 161 bytes, 1 refused
      #|read orders: {"name":"orders","key":"id","newKey":"integer","written":false,"value":[{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]}; 161 bytes, 1 refused
      #|GET /api/v1/orders: 200 [{"id":1,"status":"paid"},{"id":2,"status":"pending"},{"id":3,"status":"paid"}]; 161 bytes, 1 refused
      #|visits: 100 x: StateLimitReached("the writes would take per-Session state from 161 to 262 bytes, above its bound of 250 (--state-max-bytes)"); 161 bytes, 2 refused
      #|read visits: {"name":"visits","key":null,"newKey":null,"written":true,"value":7}; 161 bytes, 2 refused
      #|visits: 1: done; 161 bytes, 2 refused
      #|drop visits: done; 0 bytes, 2 refused
      #|orders: [{"id":1}]: done; 202 bytes, 2 refused
    ),
  )
}
