// Seam 1 tests of the Admin API operations on Scenarios: listing the
// calling Session's Scenarios of a Mock, with their current and known
// states, and setting one Scenario's state for the Session.

///|
/// The calling Session's Scenarios of `mock` as the engine lists them, as
/// JSON, one per line, or the error.
fn Harness::scenarios(
  self : Harness,
  mock : String,
  session : String?,
) -> String {
  let scenarios = self.engine.list_scenarios(mock~, session~) catch {
    err => return @debug.to_string(err)
  }
  scenarios.map(scenario => scenario.to_json().stringify()).join("\n")
}

///|
test "list gives each Scenario of the Mock with the calling Session's state and its known states" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("test-a lists", h.scenarios("payments", Some("test-a")))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-a lists", h.scenarios("payments", Some("test-a")))
  step("test-b lists", h.scenarios("payments", Some("test-b")))
  step("no Session lists", h.scenarios("payments", None))
  inspect(
    out.join("\n"),
    content=(
      #|test-a lists: {"name":"checkout","state":"Started","states":["Started","Paid"]}
      #|test-a pays: 200  (pay; checkout: Started -> Paid)
      #|test-a lists: {"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|test-b lists: {"name":"checkout","state":"Started","states":["Started","Paid"]}
      #|no Session lists: {"name":"checkout","state":"Started","states":["Started","Paid"]}
    ),
  )
}

///|
/// Two Mocks whose file Stubs, in two Definition files, name Scenarios
/// whose names and states sort differently by bytes than by letters:
/// capitals before small letters, non-ASCII last.
let shop_scenarios : Array[(String, String)] = [
  (
    "10-payments.json",
    (
      #|{ "mocks": [
      #|    { "name": "payments", "hosts": ["payments.svc"] },
      #|    { "name": "users", "hosts": ["users.svc"] } ],
      #|  "stubs": [
      #|    { "id": "pay", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/pay" },
      #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
      #|      "response": { "status": 200 } },
      #|    { "id": "cancel", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/cancel" },
      #|      "scenario": { "name": "checkout", "requires": "Paid", "moveTo": "Cancelled" },
      #|      "response": { "status": 200 } },
      #|    { "id": "bake", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/bake" },
      #|      "scenario": { "name": "éclair", "moveTo": "Baked" },
      #|      "response": { "status": 200 } },
      #|    { "id": "u-ship", "mock": "users",
      #|      "request": { "method": "POST", "path": "/ship" },
      #|      "scenario": { "name": "checkout", "moveTo": "Shipped" },
      #|      "response": { "status": 200 } } ] }
    ),
  ),
  (
    "20-more.json",
    (
      #|{ "stubs": [
      #|    { "id": "refund", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/refund" },
      #|      "scenario": { "name": "checkout", "requires": "Ångström" },
      #|      "response": { "status": 200 } },
      #|    { "id": "zeta", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/zeta" },
      #|      "scenario": { "name": "Zeta", "requires": "on" },
      #|      "response": { "status": 200 } },
      #|    { "id": "apple", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/apple" },
      #|      "scenario": { "name": "apple", "moveTo": "Started" },
      #|      "response": { "status": 200 } } ] }
    ),
  ),
]

///|
test "list gives the Scenarios that the Mock's file Stubs and the calling Session's own Ephemeral Stubs name, by name byte-wise, each with Started first, then its other states byte-wise" {
  let h = harness(shop_scenarios)
  let _ = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/refund" },
      #|  "scenario": { "name": "checkout", "requires": "Cancelled", "moveTo": "Refunded" },
      #|  "response": { "status": 200 } }
    ),
  )
  let _ = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "requires": "Down" },
      #|  "response": { "status": 503 } }
    ),
  )
  let _ = h.add(
    "payments",
    Some("test-b"),
    (
      #|{ "request": { "method": "GET", "path": "/beta" },
      #|  "scenario": { "name": "beta", "moveTo": "On" },
      #|  "response": { "status": 200 } }
    ),
  )
  let _ = h.add(
    "users",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/me" },
      #|  "scenario": { "name": "session", "moveTo": "In" },
      #|  "response": { "status": 200 } }
    ),
  )
  inspect(
    [
      "test-a, payments:",
      h.scenarios("payments", Some("test-a")),
      "test-b, payments:",
      h.scenarios("payments", Some("test-b")),
      "no Session, payments:",
      h.scenarios("payments", None),
      "test-a, users:",
      h.scenarios("users", Some("test-a")),
    ].join("\n"),
    content=(
      #|test-a, payments:
      #|{"name":"Zeta","state":"Started","states":["Started","on"]}
      #|{"name":"apple","state":"Started","states":["Started"]}
      #|{"name":"checkout","state":"Started","states":["Started","Cancelled","Paid","Refunded","Ångström"]}
      #|{"name":"outage","state":"Started","states":["Started","Down"]}
      #|{"name":"éclair","state":"Started","states":["Started","Baked"]}
      #|test-b, payments:
      #|{"name":"Zeta","state":"Started","states":["Started","on"]}
      #|{"name":"apple","state":"Started","states":["Started"]}
      #|{"name":"beta","state":"Started","states":["Started","On"]}
      #|{"name":"checkout","state":"Started","states":["Started","Cancelled","Paid","Ångström"]}
      #|{"name":"éclair","state":"Started","states":["Started","Baked"]}
      #|no Session, payments:
      #|{"name":"Zeta","state":"Started","states":["Started","on"]}
      #|{"name":"apple","state":"Started","states":["Started"]}
      #|{"name":"checkout","state":"Started","states":["Started","Cancelled","Paid","Ångström"]}
      #|{"name":"éclair","state":"Started","states":["Started","Baked"]}
      #|test-a, users:
      #|{"name":"checkout","state":"Started","states":["Started","Shipped"]}
      #|{"name":"session","state":"Started","states":["Started","In"]}
    ),
  )
}

///|
test "a Scenario that the Session holds a state for, though no Stub names it any more, is listed with only Started as its known state; a state that only a deleted Ephemeral Stub named is listed outside the known states" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let down = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "moveTo": "Down" },
      #|  "response": { "status": 503 } }
    ),
  )
  let refund = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/orders/42/refund" },
      #|  "scenario": { "name": "checkout", "requires": "Paid", "moveTo": "Refunded" },
      #|  "response": { "status": 200 } }
    ),
  )
  step("test-a GET /health", h.step("GET", "/health", session="test-a"))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-a refunds", h.step("POST", "/orders/42/refund", session="test-a"))
  step(
    "test-a deletes both",
    "\{h.delete("payments", Some("test-a"), down)}, \{h.delete("payments", Some("test-a"), refund)}",
  )
  out.push("test-a lists:")
  out.push(h.scenarios("payments", Some("test-a")))
  out.push("test-b lists:")
  out.push(h.scenarios("payments", Some("test-b")))
  inspect(
    out.join("\n"),
    content=(
      #|test-a GET /health: 503  (eph-1; outage: Started -> Down)
      #|test-a pays: 200  (pay; checkout: Started -> Paid)
      #|test-a refunds: 200  (eph-2; checkout: Paid -> Refunded)
      #|test-a deletes both: deleted, deleted
      #|test-a lists:
      #|{"name":"checkout","state":"Refunded","states":["Started","Paid"]}
      #|{"name":"outage","state":"Down","states":["Started"]}
      #|test-b lists:
      #|{"name":"checkout","state":"Started","states":["Started","Paid"]}
    ),
  )
}

///|
/// Sets the Scenario `scenario` of `mock` to `state` for `session`: the
/// Scenario as the engine gives it after, as JSON, or the error.
fn Harness::set(
  self : Harness,
  mock : String,
  session : String?,
  scenario : String,
  state : String,
) -> String {
  let scenario = self.engine.set_scenario_state(
    mock~,
    session~,
    scenario~,
    state~,
  ) catch {
    err => return @debug.to_string(err)
  }
  scenario.to_json().stringify()
}

///|
test "set moves the calling Session's Scenario to a known state, so a test can start in the middle of a flow, and setting Started resets it" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step(
    "test-a sets Paid",
    h.set("payments", Some("test-a"), "checkout", "Paid"),
  )
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-b GET", h.step("GET", "/orders/42", session="test-b"))
  step("no Session GET", h.step("GET", "/orders/42"))
  step("test-a lists", h.scenarios("payments", Some("test-a")))
  step(
    "test-a sets Paid again",
    h.set("payments", Some("test-a"), "checkout", "Paid"),
  )
  step(
    "test-a sets Started",
    h.set("payments", Some("test-a"), "checkout", "Started"),
  )
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("no Session sets Paid", h.set("payments", None, "checkout", "Paid"))
  step("no Session GET", h.step("GET", "/orders/42"))
  step("test-b GET", h.step("GET", "/orders/42", session="test-b"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a sets Paid: {"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|test-a GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|test-a pays: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|test-b GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|no Session GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-a lists: {"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|test-a sets Paid again: {"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|test-a sets Started: {"name":"checkout","state":"Started","states":["Started","Paid"]}
      #|test-a GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-a pays: 200  (pay; checkout: Started -> Paid)
      #|no Session sets Paid: {"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|no Session GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|test-b GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
    ),
  )
}

///|
test "setting Started on a Scenario that only the Session's state kept listed clears that state, so the Scenario is no longer listed" {
  let h = harness(checkout)
  let down = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "moveTo": "Down" },
      #|  "response": { "status": 503 } }
    ),
  )
  let _ = h.step("GET", "/health", session="test-a")
  let _ = h.delete("payments", Some("test-a"), down)
  let out = [
    "test-a lists:",
    h.scenarios("payments", Some("test-a")),
    "test-a sets outage to Started: \{h.set("payments", Some("test-a"), "outage", "Started")}",
    "test-a lists:",
    h.scenarios("payments", Some("test-a")),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|test-a lists:
      #|{"name":"checkout","state":"Started","states":["Started","Paid"]}
      #|{"name":"outage","state":"Down","states":["Started"]}
      #|test-a sets outage to Started: {"name":"outage","state":"Started","states":["Started"]}
      #|test-a lists:
      #|{"name":"checkout","state":"Started","states":["Started","Paid"]}
    ),
  )
}

///|
test "list and set refuse an unknown Mock; set refuses a Scenario that no Stub of the Mock names for the calling Session, and a state outside its known states" {
  let h = harness(shop_scenarios)
  let _ = h.add(
    "payments",
    Some("test-b"),
    (
      #|{ "request": { "method": "GET", "path": "/beta" },
      #|  "scenario": { "name": "beta", "moveTo": "On" },
      #|  "response": { "status": 200 } }
    ),
  )
  let _ = h.add(
    "payments",
    Some("test-b"),
    (
      #|{ "request": { "method": "POST", "path": "/refund" },
      #|  "scenario": { "name": "checkout", "requires": "Paid", "moveTo": "Refunded" },
      #|  "response": { "status": 200 } }
    ),
  )
  let calls = [
    ("list orders", h.scenarios("orders", Some("test-a"))),
    ("set in orders", h.set("orders", Some("test-a"), "checkout", "Paid")),
    ("set nowhere", h.set("payments", Some("test-a"), "nowhere", "Started")),
    (
      "set beta, which only test-b's Ephemeral Stub names",
      h.set("payments", Some("test-a"), "beta", "On"),
    ),
    (
      "set session, which only test-a's Ephemeral Stub in users names",
      h.set("payments", Some("test-a"), "session", "Started"),
    ),
    (
      "set checkout to paid, not Paid",
      h.set("payments", Some("test-a"), "checkout", "paid"),
    ),
    (
      "set checkout to Refunded, which only test-b's Ephemeral Stub names",
      h.set("payments", Some("test-a"), "checkout", "Refunded"),
    ),
    (
      "set checkout to Shipped, which only users names",
      h.set("payments", None, "checkout", "Shipped"),
    ),
    (
      "set checkout to Baked, which only éclair names",
      h.set("payments", None, "checkout", "Baked"),
    ),
    ("test-b sets beta to On", h.set("payments", Some("test-b"), "beta", "On")),
    (
      "test-b sets checkout to Refunded",
      h.set("payments", Some("test-b"), "checkout", "Refunded"),
    ),
  ]
  inspect(
    calls.map(call => "\{call.0}: \{call.1}").join("\n"),
    content=(
      #|list orders: UnknownMock("orders")
      #|set in orders: UnknownMock("orders")
      #|set nowhere: UnknownScenario(mock="payments", scenario="nowhere")
      #|set beta, which only test-b's Ephemeral Stub names: UnknownScenario(mock="payments", scenario="beta")
      #|set session, which only test-a's Ephemeral Stub in users names: UnknownScenario(mock="payments", scenario="session")
      #|set checkout to paid, not Paid: UnknownState(
      #|  mock="payments",
      #|  scenario="checkout",
      #|  state="paid",
      #|  known=["Started", "Cancelled", "Paid", "Ångström"],
      #|)
      #|set checkout to Refunded, which only test-b's Ephemeral Stub names: UnknownState(
      #|  mock="payments",
      #|  scenario="checkout",
      #|  state="Refunded",
      #|  known=["Started", "Cancelled", "Paid", "Ångström"],
      #|)
      #|set checkout to Shipped, which only users names: UnknownState(
      #|  mock="payments",
      #|  scenario="checkout",
      #|  state="Shipped",
      #|  known=["Started", "Cancelled", "Paid", "Ångström"],
      #|)
      #|set checkout to Baked, which only éclair names: UnknownState(
      #|  mock="payments",
      #|  scenario="checkout",
      #|  state="Baked",
      #|  known=["Started", "Cancelled", "Paid", "Ångström"],
      #|)
      #|test-b sets beta to On: {"name":"beta","state":"On","states":["Started","On"]}
      #|test-b sets checkout to Refunded: {"name":"checkout","state":"Refunded","states":["Started","Cancelled","Paid","Refunded","Ångström"]}
    ),
  )
}

///|
test "a state that the Session holds, though no Stub names it any more, cannot be set again, and a refused set leaves every state as it was" {
  let h = harness(checkout)
  let down = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "moveTo": "Down" },
      #|  "response": { "status": 503 } }
    ),
  )
  let _ = h.step("GET", "/health", session="test-a")
  let _ = h.delete("payments", Some("test-a"), down)
  let _ = h.set("payments", Some("test-a"), "checkout", "Paid")
  let out = [
    "test-a sets outage to Down: \{h.set("payments", Some("test-a"), "outage", "Down")}",
    "test-a sets checkout to Down: \{h.set("payments", Some("test-a"), "checkout", "Down")}",
    "test-a lists:",
    h.scenarios("payments", Some("test-a")),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|test-a sets outage to Down: UnknownState(
      #|  mock="payments",
      #|  scenario="outage",
      #|  state="Down",
      #|  known=["Started"],
      #|)
      #|test-a sets checkout to Down: UnknownState(
      #|  mock="payments",
      #|  scenario="checkout",
      #|  state="Down",
      #|  known=["Started", "Paid"],
      #|)
      #|test-a lists:
      #|{"name":"checkout","state":"Paid","states":["Started","Paid"]}
      #|{"name":"outage","state":"Down","states":["Started"]}
    ),
  )
}
