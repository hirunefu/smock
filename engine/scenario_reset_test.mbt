// Seam 1 tests of resets and Scenario state: each reset scope also clears
// the Scenario state in it, and the reset says how many states it cleared.

///|
/// Two Mocks, as in the state-model prototype, each with a Scenario:
/// `users`, the Default Mock, where `POST /login` moves `login` to `In`
/// from any state, and `GET /me` answers Alice while `login` is in `In`
/// and 401 otherwise; and `payments`, where `GET /orders/42` answers
/// pending until `POST /orders/42/pay` moves `checkout` to `Paid`, and
/// paid after.
let reset_shop : Array[(String, String)] = [
  (
    "00-mocks.json",
    (
      #|{ "mocks": [
      #|    { "name": "users", "hosts": ["users.svc"], "default": true },
      #|    { "name": "payments", "hosts": ["payments.svc"] } ] }
    ),
  ),
  (
    "10-users.json",
    (
      #|{ "stubs": [
      #|    { "id": "u-login", "mock": "users",
      #|      "request": { "method": "POST", "path": "/login" },
      #|      "scenario": { "name": "login", "moveTo": "In" },
      #|      "response": { "status": 200, "body": "welcome" } },
      #|    { "id": "u-me", "mock": "users",
      #|      "request": { "method": "GET", "path": "/me" },
      #|      "scenario": { "name": "login", "requires": "In" },
      #|      "response": { "status": 200, "body": "Alice" } },
      #|    { "id": "u-anonymous", "mock": "users",
      #|      "request": { "method": "GET", "path": "/me" },
      #|      "response": { "status": 401, "body": "who?" } } ] }
    ),
  ),
  (
    "20-payments.json",
    (
      #|{ "stubs": [
      #|    { "id": "p-order-pending", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/orders/42" },
      #|      "scenario": { "name": "checkout", "requires": "Started" },
      #|      "response": { "status": 200, "body": "pending" } },
      #|    { "id": "p-pay", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/orders/42/pay" },
      #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
      #|      "response": { "status": 200, "body": "paid" } },
      #|    { "id": "p-order-paid", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/orders/42" },
      #|      "scenario": { "name": "checkout", "requires": "Paid" },
      #|      "response": { "status": 200, "body": "paid" } } ] }
    ),
  ),
]

///|
/// Resets `scope`: how many Ephemeral Stubs, Journal entries and Scenario
/// states it removed, or the error.
fn Harness::reset_scenarios(
  self : Harness,
  scope : @engine.ResetScope,
) -> String {
  let removed = self.engine.reset(scope) catch {
    err => return @debug.to_string(err)
  }
  "removed \{removed.ephemeral_stubs} Ephemeral Stubs, \{removed.journal_entries} entries, \{removed.scenario_states} Scenario states"
}

///|
test "the prototype's reset scopes: a Session reset clears the Session's state of every Mock and leaves another Session's alone, and a Mock reset clears every Session's state of that Mock" {
  let h = harness(reset_shop)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let pay = "http://payments.svc/orders/42/pay"
  // test-a pays and logs in, test-b pays, each recorded in the Journal.
  ignore(h.record("POST", pay, session="test-a"))
  ignore(h.record("POST", "http://users.svc/login", session="test-a"))
  ignore(h.record("POST", pay, session="test-b"))
  step(
    "test-a adds an Ephemeral Stub to users",
    h.add("users", Some("test-a"), get_stub("/health", 503, "down")),
  )
  step("test-a GET /orders/42", h.step("GET", "/orders/42", session="test-a"))
  step(
    "test-a GET /me",
    h.step("GET", "/me", host="users.svc", session="test-a"),
  )
  step("test-b GET /orders/42", h.step("GET", "/orders/42", session="test-b"))
  step("reset Session test-a", h.reset_scenarios(Session(Some("test-a"))))
  step("test-a GET /orders/42", h.step("GET", "/orders/42", session="test-a"))
  step(
    "test-a GET /me",
    h.step("GET", "/me", host="users.svc", session="test-a"),
  )
  step("test-b GET /orders/42", h.step("GET", "/orders/42", session="test-b"))
  step("reset Mock payments", h.reset_scenarios(Mock("payments")))
  step("test-b GET /orders/42", h.step("GET", "/orders/42", session="test-b"))
  step("test-b pays again", h.step("POST", "/orders/42/pay", session="test-b"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a adds an Ephemeral Stub to users: eph-1
      #|test-a GET /orders/42: 200 paid (p-order-paid; checkout: Paid -> Paid)
      #|test-a GET /me: 200 Alice (u-me; login: In -> In)
      #|test-b GET /orders/42: 200 paid (p-order-paid; checkout: Paid -> Paid)
      #|reset Session test-a: removed 1 Ephemeral Stubs, 2 entries, 2 Scenario states
      #|test-a GET /orders/42: 200 pending (p-order-pending; checkout: Started -> Started)
      #|test-a GET /me: 401 who? (u-anonymous; no clause)
      #|test-b GET /orders/42: 200 paid (p-order-paid; checkout: Paid -> Paid)
      #|reset Mock payments: removed 0 Ephemeral Stubs, 1 entries, 1 Scenario states
      #|test-b GET /orders/42: 200 pending (p-order-pending; checkout: Started -> Started)
      #|test-b pays again: 200 paid (p-pay; checkout: Started -> Paid)
    ),
  )
}

///|
test "a reset of the no-Session space clears only its states, a Mock reset clears that Mock's states of every Session and of the no-Session space, and a reset of everything clears every state" {
  let h = harness(reset_shop)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let pay = "/orders/42/pay"
  ignore(h.step("POST", pay, session="test-a"))
  ignore(h.step("POST", "/login", host="users.svc", session="test-a"))
  ignore(h.step("POST", "/login", host="users.svc", session="test-b"))
  ignore(h.step("POST", pay))
  ignore(h.step("POST", "/login", host="users.svc"))
  // A Scenario that only an Ephemeral Stub named, which is gone, keeps its
  // state until a reset.
  let outage = h.add(
    "payments",
    None,
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "moveTo": "Down" },
      #|  "response": { "status": 503, "body": "down" } }
    ),
  )
  step("no Session GET /health", h.step("GET", "/health"))
  step("no Session deletes \{outage}", h.delete("payments", None, outage))
  step("reset the no-Session space", h.reset_scenarios(Session(None)))
  step("no Session GET /orders/42", h.step("GET", "/orders/42"))
  step("no Session GET /me", h.step("GET", "/me", host="users.svc"))
  step("test-a GET /orders/42", h.step("GET", "/orders/42", session="test-a"))
  step("no Session logs in", h.step("POST", "/login", host="users.svc"))
  step("reset Mock orders", h.reset_scenarios(Mock("orders")))
  step(
    "test-a GET /me",
    h.step("GET", "/me", host="users.svc", session="test-a"),
  )
  step("reset Mock users", h.reset_scenarios(Mock("users")))
  step(
    "test-a GET /me",
    h.step("GET", "/me", host="users.svc", session="test-a"),
  )
  step(
    "test-b GET /me",
    h.step("GET", "/me", host="users.svc", session="test-b"),
  )
  step("no Session GET /me", h.step("GET", "/me", host="users.svc"))
  step("test-a GET /orders/42", h.step("GET", "/orders/42", session="test-a"))
  step("reset all", h.reset_scenarios(All))
  step("test-a GET /orders/42", h.step("GET", "/orders/42", session="test-a"))
  step("reset all again", h.reset_scenarios(All))
  inspect(
    out.join("\n"),
    content=(
      #|no Session GET /health: 503 down (eph-1; outage: Started -> Down)
      #|no Session deletes eph-1: deleted
      #|reset the no-Session space: removed 0 Ephemeral Stubs, 0 entries, 3 Scenario states
      #|no Session GET /orders/42: 200 pending (p-order-pending; checkout: Started -> Started)
      #|no Session GET /me: 401 who? (u-anonymous; no clause)
      #|test-a GET /orders/42: 200 paid (p-order-paid; checkout: Paid -> Paid)
      #|no Session logs in: 200 welcome (u-login; login: Started -> In)
      #|reset Mock orders: UnknownMock("orders")
      #|test-a GET /me: 200 Alice (u-me; login: In -> In)
      #|reset Mock users: removed 0 Ephemeral Stubs, 0 entries, 3 Scenario states
      #|test-a GET /me: 401 who? (u-anonymous; no clause)
      #|test-b GET /me: 401 who? (u-anonymous; no clause)
      #|no Session GET /me: 401 who? (u-anonymous; no clause)
      #|test-a GET /orders/42: 200 paid (p-order-paid; checkout: Paid -> Paid)
      #|reset all: removed 0 Ephemeral Stubs, 0 entries, 1 Scenario states
      #|test-a GET /orders/42: 200 pending (p-order-pending; checkout: Started -> Started)
      #|reset all again: removed 0 Ephemeral Stubs, 0 entries, 0 Scenario states
    ),
  )
}
