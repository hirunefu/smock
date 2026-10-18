// Seam 1 tests of how a reload treats Scenario state: a reload that swaps
// in a new set keeps each stored state whose name is still known, sends any
// other state back to Started, and drops the states of removed Mocks. A
// reload that swaps nothing touches no state.

///|
/// Reloads the engine of `h` with Definition files given as (name, text)
/// pairs: how the reload ended, and how many states it sent back to
/// `Started`.
fn Harness::reload_states(
  self : Harness,
  files : Array[(String, String)],
) -> String {
  let result = self.reload(files)
  "\{@debug.to_string(result.result)}, \{result.scenario_states_reset} back to Started"
}

///|
/// `checkout` with the body of `order-paid` changed: it adds a receipt.
let checkout_with_receipt : Array[(String, String)] = checkout.map(file => {
  (
    file.0,
    file.1.replace(
      old="{ \"status\": \"paid\" }",
      new="{ \"status\": \"paid\", \"receipt\": \"r-1\" }",
    ),
  )
})

///|
/// `checkout` with the state `Paid` renamed `Settled`, in `moveTo` and in
/// `requires`.
let checkout_settled : Array[(String, String)] = checkout.map(file => {
  (file.0, file.1.replace_all(old="\"Paid\"", new="\"Settled\""))
})

///|
test "the prototype's reload walkthrough: a body change keeps Paid, a rename sends it back to Started, an invalid set changes nothing, and a removed Mock drops its states and its Ephemeral Stubs" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step(
    "test-b adds",
    h.add("payments", Some("test-b"), get_stub("/health", 500, "down")),
  )
  step("reload, body changed", h.reload_states(checkout_with_receipt))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("no Session pays", h.step("POST", "/orders/42/pay"))
  step("reload, Paid renamed Settled", h.reload_states(checkout_settled))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("no Session GET", h.step("GET", "/orders/42"))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step(
    "reload, invalid",
    h.reload_states([..checkout_settled, ("broken.json", "{ \"mocks\": ")]),
  )
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step(
    "reload, payments removed",
    h.reload_states([("users.json", named_mock("users"))]),
  )
  step("test-b GET /health", h.step("GET", "/health", session="test-b"))
  step("reload, payments back", h.reload_states(checkout_settled))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step(
    "test-b lists",
    match h.list("payments", Some("test-b")) {
      "" => "none"
      listed => listed
    },
  )
  inspect(
    out.join("\n"),
    content=(
      #|test-a pays: 200  (pay; checkout: Started -> Paid)
      #|test-b adds: eph-1
      #|reload, body changed: Swapped, 0 back to Started
      #|test-a GET: 200 {"status":"paid","receipt":"r-1"} (order-paid; checkout: Paid -> Paid)
      #|no Session pays: 200  (pay; checkout: Started -> Paid)
      #|reload, Paid renamed Settled: Swapped, 2 back to Started
      #|test-a GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|no Session GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-a pays: 200  (pay; checkout: Started -> Settled)
      #|reload, invalid: Failed, 0 back to Started
      #|test-a GET: 200 {"status":"paid"} (order-paid; checkout: Settled -> Settled)
      #|reload, payments removed: Swapped, 0 back to Started
      #|test-b GET /health: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|reload, payments back: Swapped, 0 back to Started
      #|test-a GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-b lists: none
    ),
  )
}

///|
/// A Stub `id` of `mock` that answers `<meth> <path>` with 200, with the
/// Scenario clause whose members are `clause`, as JSON text.
fn clause_stub(
  id : String,
  mock : String,
  meth : String,
  path : String,
  clause : String,
) -> String {
  "{ \"id\": \"\{id}\", \"mock\": \"\{mock}\", \"request\": { \"method\": \"\{meth}\", \"path\": \"\{path}\" }, \"scenario\": { \{clause} }, \"response\": { \"status\": 200 } }"
}

///|
/// A Definition file that declares the Mocks `payments`, for
/// `payments.svc`, and `users`, for `users.svc`, with `stubs`, each given
/// as JSON text.
fn scenario_file(stubs : Array[String]) -> Array[(String, String)] {
  let mocks =
    #|"mocks": [{ "name": "payments", "hosts": ["payments.svc"] },
    #|  { "name": "users", "hosts": ["users.svc"] }]
  [("mocks.json", "{ \{mocks}, \"stubs\": [\{stubs.join(", ")}] }")]
}

///|
/// A Stub of `payments` that answers `GET /<name>` and moves the Scenario
/// `name` back to `Started` from any state. Its move shows the state the
/// Scenario was in, and it names no state but `Started`.
fn observer(name : String) -> String {
  clause_stub(
    "see-\{name}",
    "payments",
    "GET",
    "/\{name}",
    "\"name\": \"\{name}\", \"moveTo\": \"Started\"",
  )
}

///|
test "a state stays when a file Stub of its Mock and Scenario names it, in requires or in moveTo, and goes back to Started when only another Scenario or another Mock names it" {
  let to_x = (mock : String, name : String) => {
    clause_stub(
      "to-x-\{name}",
      mock,
      "POST",
      "/\{name}",
      "\"name\": \"\{name}\", \"moveTo\": \"X\"",
    )
  }
  let names = ["a", "b", "c", "d"]
  let observers = names.map(observer)
  let h = harness(
    scenario_file([..names.map(name => to_x("payments", name)), ..observers]),
  )
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  for name in names {
    step("test-a moves \{name}", h.step("POST", "/\{name}", session="test-a"))
  }
  step(
    "reload",
    h.reload_states(
      scenario_file(
        [
          clause_stub(
            "a-in-x", "payments", "PUT", "/a", "\"name\": \"a\", \"requires\": \"X\"",
          ),
          to_x("payments", "b"),
          clause_stub(
            "other-in-x", "payments", "PUT", "/c", "\"name\": \"other\", \"requires\": \"X\"",
          ),
          to_x("users", "d"),
          ..observers,
        ],
      ),
    ),
  )
  let named = [
    "a, which a Stub requires X of", "b, which a Stub moves to X", "c, whose X only another Scenario names",
    "d, whose X only another Mock names",
  ]
  for i, name in names {
    step(named[i], h.step("GET", "/\{name}", session="test-a"))
  }
  inspect(
    out.join("\n"),
    content=(
      #|test-a moves a: 200  (to-x-a; a: Started -> X)
      #|test-a moves b: 200  (to-x-b; b: Started -> X)
      #|test-a moves c: 200  (to-x-c; c: Started -> X)
      #|test-a moves d: 200  (to-x-d; d: Started -> X)
      #|reload: Swapped, 2 back to Started
      #|a, which a Stub requires X of: 200  (see-a; a: X -> Started)
      #|b, which a Stub moves to X: 200  (see-b; b: X -> Started)
      #|c, whose X only another Scenario names: 200  (see-c; c: Started -> Started)
      #|d, whose X only another Mock names: 200  (see-d; d: Started -> Started)
    ),
  )
}

///|
/// An Ephemeral Stub that answers `POST /outage` with 503 and moves the
/// Scenario `outage` to `Down` from any state.
let outage_down : String =
  #|{ "request": { "method": "POST", "path": "/outage" },
  #|  "scenario": { "name": "outage", "moveTo": "Down" },
  #|  "response": { "status": 503 } }

///|
test "a state known only through the Session's own Ephemeral Stubs in the Mock survives an unrelated file change; another Session's or another Mock's Ephemeral Stubs do not keep it" {
  let files = (body : String) => {
    scenario_file([
      observer("outage"),
      "{ \"id\": \"hello\", \"mock\": \"payments\", \"request\": { \"path\": \"/hello\" }, \"response\": { \"status\": 200, \"body\": \"\{body}\" } }",
    ])
  }
  let h = harness(files("v1"))
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("test-a adds", h.add("payments", Some("test-a"), outage_down))
  step("test-a goes down", h.step("POST", "/outage", session="test-a"))
  let b = h.add("payments", Some("test-b"), outage_down)
  step("test-b goes down", h.step("POST", "/outage", session="test-b"))
  step("test-b deletes \{b}", h.delete("payments", Some("test-b"), b))
  step("test-c adds to users", h.add("users", Some("test-c"), outage_down))
  let c = h.add("payments", Some("test-c"), outage_down)
  step("test-c goes down", h.step("POST", "/outage", session="test-c"))
  step("test-c deletes \{c}", h.delete("payments", Some("test-c"), c))
  step("reload, another Stub's body changed", h.reload_states(files("v2")))
  for session in ["test-a", "test-b", "test-c"] {
    step(session, h.step("GET", "/outage", session~))
  }
  inspect(
    out.join("\n"),
    content=(
      #|test-a adds: eph-1
      #|test-a goes down: 503  (eph-1; outage: Started -> Down)
      #|test-b goes down: 503  (eph-2; outage: Started -> Down)
      #|test-b deletes eph-2: deleted
      #|test-c adds to users: eph-3
      #|test-c goes down: 503  (eph-4; outage: Started -> Down)
      #|test-c deletes eph-4: deleted
      #|reload, another Stub's body changed: Swapped, 2 back to Started
      #|test-a: 200  (see-outage; outage: Down -> Started)
      #|test-b: 200  (see-outage; outage: Started -> Started)
      #|test-c: 200  (see-outage; outage: Started -> Started)
    ),
  )
}

///|
test "a reload that swaps nothing, unchanged or invalid, touches no state, not even one that no Stub names any more" {
  let files = scenario_file([observer("outage")])
  let h = harness(files)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  for session in ["test-a", "test-b"] {
    let id = h.add("payments", Some(session), outage_down)
    step("\{session} goes down", h.step("POST", "/outage", session~))
    step("\{session} deletes \{id}", h.delete("payments", Some(session), id))
  }
  step("reload, the same files", h.reload_states(files))
  step(
    "reload, invalid",
    h.reload_states([..files, ("broken.json", "{ \"mocks\": ")]),
  )
  step("test-a", h.step("GET", "/outage", session="test-a"))
  step(
    "reload, a Stub added",
    h.reload_states(scenario_file([observer("outage"), observer("other")])),
  )
  step("test-b", h.step("GET", "/outage", session="test-b"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a goes down: 503  (eph-1; outage: Started -> Down)
      #|test-a deletes eph-1: deleted
      #|test-b goes down: 503  (eph-2; outage: Started -> Down)
      #|test-b deletes eph-2: deleted
      #|reload, the same files: Unchanged, 0 back to Started
      #|reload, invalid: Failed, 0 back to Started
      #|test-a: 200  (see-outage; outage: Down -> Started)
      #|reload, a Stub added: Swapped, 1 back to Started
      #|test-b: 200  (see-outage; outage: Started -> Started)
    ),
  )
}
