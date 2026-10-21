// Seam 1 tests of how resets and reloads treat Variables: each reset scope
// clears the Variables in it and counts them, and a reload keeps them,
// except those of Mocks that are gone.

///|
/// Two Mocks that write Variables: `shop`, the Default Mock, where
/// `POST /count` counts its requests in `count` and stores who sent the
/// last one in `last`; and `bank`, for `bank.svc`, where `POST /deposit`
/// adds 10 to `balance`. In each, `GET /vars` shows the Variables of the
/// Mock as the request's Session sees them.
let counting_mocks : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - { name: shop, default: true }
      #|stubs:
      #|  - id: count
      #|    mock: shop
      #|    request: { method: POST, path: /count }
      #|    variables:
      #|      count: ${add(vars.count ?? 0, 1)}
      #|      last: ${query.by ?? 'nobody'}
      #|    response: { status: 204 }
      #|  - id: shop-vars
      #|    mock: shop
      #|    request: { method: GET, path: /vars }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { count: "${vars.count ?? null}", last: "${vars.last ?? null}" }
    ),
  ),
  (
    "bank.yaml",
    (
      #|mocks:
      #|  - { name: bank, hosts: [bank.svc] }
      #|stubs:
      #|  - id: deposit
      #|    mock: bank
      #|    request: { method: POST, path: /deposit }
      #|    variables:
      #|      balance: ${add(vars.balance ?? 0, 10)}
      #|    response: { status: 204 }
      #|  - id: bank-vars
      #|    mock: bank
      #|    request: { method: GET, path: /vars }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { balance: "${vars.balance ?? null}" }
    ),
  ),
]

///|
/// Resets `scope`: how many Variables the reset removed, then the rest of
/// what it removed, or the error.
fn Harness::reset_all_kinds(
  self : Harness,
  scope : @engine.ResetScope,
) -> String {
  let removed = self.engine.reset(scope) catch {
    err => return @debug.to_string(err)
  }
  "removed \{removed.variables} Variables; \{removed.ephemeral_stubs} Ephemeral Stubs, \{removed.journal_entries} entries, \{removed.scenario_states} Scenario states"
}

///|
/// The Variables of `shop` and of `bank` as `session` sees them, or as
/// requests without a Session see them for `None`.
fn Harness::both_mocks(self : Harness, session : String?) -> String {
  let shop = reply(self.send("GET", "/vars", session?))
  let bank = reply(self.send("GET", "http://bank.svc/vars", session?))
  "shop \{shop}, bank \{bank}"
}

///|
test "each reset scope clears the Variables in it and counts them: a Session's in every Mock, a Mock's of every Session and of the no-Session space, or every Variable" {
  let h = harness(counting_mocks)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let count = (by : String, session : String?) => {
    ignore(h.send("POST", "/count?by=\{by}", session?))
  }
  let deposit = (session : String?) => {
    ignore(h.send("POST", "http://bank.svc/deposit", session?))
  }
  count("ann", Some("test-a"))
  count("ann", Some("test-a"))
  deposit(Some("test-a"))
  count("bob", Some("test-b"))
  deposit(Some("test-b"))
  count("anon", None)
  deposit(None)
  step("test-a", h.both_mocks(Some("test-a")))
  step("reset Session test-a", h.reset_all_kinds(Session(Some("test-a"))))
  step("test-a", h.both_mocks(Some("test-a")))
  step("test-b", h.both_mocks(Some("test-b")))
  step("no Session", h.both_mocks(None))
  step("reset the no-Session space", h.reset_all_kinds(Session(None)))
  step("no Session", h.both_mocks(None))
  step("test-b", h.both_mocks(Some("test-b")))
  count("ann", Some("test-a"))
  count("anon", None)
  step("reset Mock shop", h.reset_all_kinds(Mock("shop")))
  step("test-a", h.both_mocks(Some("test-a")))
  step("test-b", h.both_mocks(Some("test-b")))
  step("no Session", h.both_mocks(None))
  step("reset all", h.reset_all_kinds(All))
  step("test-b", h.both_mocks(Some("test-b")))
  step("reset all again", h.reset_all_kinds(All))
  inspect(
    out.join("\n"),
    content=(
      #|test-a: shop 200 {"count":2,"last":"ann"}, bank 200 {"balance":10}
      #|reset Session test-a: removed 3 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states
      #|test-a: shop 200 {"count":null,"last":null}, bank 200 {"balance":null}
      #|test-b: shop 200 {"count":1,"last":"bob"}, bank 200 {"balance":10}
      #|no Session: shop 200 {"count":1,"last":"anon"}, bank 200 {"balance":10}
      #|reset the no-Session space: removed 3 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states
      #|no Session: shop 200 {"count":null,"last":null}, bank 200 {"balance":null}
      #|test-b: shop 200 {"count":1,"last":"bob"}, bank 200 {"balance":10}
      #|reset Mock shop: removed 6 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states
      #|test-a: shop 200 {"count":null,"last":null}, bank 200 {"balance":null}
      #|test-b: shop 200 {"count":null,"last":null}, bank 200 {"balance":10}
      #|no Session: shop 200 {"count":null,"last":null}, bank 200 {"balance":null}
      #|reset all: removed 1 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states
      #|test-b: shop 200 {"count":null,"last":null}, bank 200 {"balance":null}
      #|reset all again: removed 0 Variables; 0 Ephemeral Stubs, 0 entries, 0 Scenario states
    ),
  )
}

///|
/// `counting_mocks` with `shop`'s `GET /vars` changed: it says it was
/// edited.
let counting_mocks_edited : Array[(String, String)] = [
  (
    counting_mocks[0].0,
    counting_mocks[0].1.replace(
      old="json: { count:",
      new="json: { edited: true, count:",
    ),
  ),
  counting_mocks[1],
]

///|
/// `counting_mocks` without the Stub that writes `shop`'s Variables: only
/// `GET /vars` is left in `shop`.
let counting_mocks_without_writes : Array[(String, String)] = [
  (
    "shop.yaml",
    (
      #|mocks:
      #|  - { name: shop, default: true }
      #|stubs:
      #|  - id: shop-vars
      #|    mock: shop
      #|    request: { method: GET, path: /vars }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      json: { count: "${vars.count ?? null}", last: "${vars.last ?? null}" }
    ),
  ),
  counting_mocks[1],
]

///|
/// Writes the Variables of both Mocks for `test-a`, `test-b` and the
/// no-Session space.
fn Harness::count_everywhere(self : Harness) -> Unit {
  for session in [Some("test-a"), Some("test-b"), None] {
    let by = session.unwrap_or("anon")
    ignore(self.send("POST", "/count?by=\{by}", session?))
    ignore(self.send("POST", "http://bank.svc/deposit", session?))
  }
}

///|
test "a reload that swaps keeps every Variable of the Mocks the new set still declares, even when no Stub writes them any more, and drops those of a Mock it does not declare" {
  let h = harness(counting_mocks)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let reloaded = (files : Array[(String, String)]) => {
    @debug.to_string(h.reload(files).result)
  }
  h.count_everywhere()
  step("reload, a response edited", reloaded(counting_mocks_edited))
  step("test-a", h.both_mocks(Some("test-a")))
  step("no Session", h.both_mocks(None))
  step(
    "reload, the Stub that writes shop's removed",
    reloaded(counting_mocks_without_writes),
  )
  step("test-b", h.both_mocks(Some("test-b")))
  step("reload, bank removed", reloaded([counting_mocks[0]]))
  step("test-a", reply(h.send("GET", "/vars", session="test-a")))
  step("reload, bank back", reloaded(counting_mocks))
  step("test-a", h.both_mocks(Some("test-a")))
  step("test-b", h.both_mocks(Some("test-b")))
  step("no Session", h.both_mocks(None))
  inspect(
    out.join("\n"),
    content=(
      #|reload, a response edited: Swapped
      #|test-a: shop 200 {"edited":true,"count":1,"last":"test-a"}, bank 200 {"balance":10}
      #|no Session: shop 200 {"edited":true,"count":1,"last":"anon"}, bank 200 {"balance":10}
      #|reload, the Stub that writes shop's removed: Swapped
      #|test-b: shop 200 {"count":1,"last":"test-b"}, bank 200 {"balance":10}
      #|reload, bank removed: Swapped
      #|test-a: 200 {"count":1,"last":"test-a"}
      #|reload, bank back: Swapped
      #|test-a: shop 200 {"count":1,"last":"test-a"}, bank 200 {"balance":null}
      #|test-b: shop 200 {"count":1,"last":"test-b"}, bank 200 {"balance":null}
      #|no Session: shop 200 {"count":1,"last":"anon"}, bank 200 {"balance":null}
    ),
  )
}

///|
test "a reload that fails or finds the set unchanged keeps every Variable" {
  let h = harness(counting_mocks)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let reloaded = (files : Array[(String, String)]) => {
    @debug.to_string(h.reload(files).result)
  }
  h.count_everywhere()
  step(
    "reload, bank removed and a file invalid",
    reloaded([counting_mocks[0], ("broken.json", "{ \"mocks\": ")]),
  )
  step("test-a", h.both_mocks(Some("test-a")))
  step("no Session", h.both_mocks(None))
  step("reload, the same files", reloaded(counting_mocks))
  step("test-b", h.both_mocks(Some("test-b")))
  step("no Session", h.both_mocks(None))
  inspect(
    out.join("\n"),
    content=(
      #|reload, bank removed and a file invalid: Failed
      #|test-a: shop 200 {"count":1,"last":"test-a"}, bank 200 {"balance":10}
      #|no Session: shop 200 {"count":1,"last":"anon"}, bank 200 {"balance":10}
      #|reload, the same files: Unchanged
      #|test-b: shop 200 {"count":1,"last":"test-b"}, bank 200 {"balance":10}
      #|no Session: shop 200 {"count":1,"last":"anon"}, bank 200 {"balance":10}
    ),
  )
}
