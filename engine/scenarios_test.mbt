// Seam 1 tests of Scenarios: Stubs whose scenario clause requires a state
// or moves a Scenario to one, the state each Mock keeps per Session, and
// the move the engine's outcome carries.

///|
/// The example of spec #48: Mock `payments`, where `GET /orders/42`
/// answers pending until `POST /orders/42/pay` moves the Scenario
/// `checkout` to `Paid`, and paid after.
let checkout : Array[(String, String)] = [
  (
    "payments.json",
    (
      #|{ "mocks": [{ "name": "payments", "hosts": ["payments.svc"] }],
      #|  "stubs": [
      #|    { "id": "order-pending", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/orders/42" },
      #|      "scenario": { "name": "checkout", "requires": "Started" },
      #|      "response": { "status": 200, "json": { "status": "pending" } } },
      #|    { "id": "pay", "mock": "payments",
      #|      "request": { "method": "POST", "path": "/orders/42/pay" },
      #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
      #|      "response": { "status": 200 } },
      #|    { "id": "order-paid", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/orders/42" },
      #|      "scenario": { "name": "checkout", "requires": "Paid" },
      #|      "response": { "status": 200, "json": { "status": "paid" } } } ] }
    ),
  ),
]

///|
/// The move in `outcome`: `<name>: <from> -> <to>`, or `no clause` when the
/// Stub that answered has none, or no Stub did.
fn moved(outcome : @engine.Outcome) -> String {
  match outcome.scenario {
    Some(moved) => "\{moved.name}: \{moved.from} -> \{moved.to}"
    None => "no clause"
  }
}

///|
/// `<meth> http://<host><path>` with `session`, if given: the status, the
/// body, the Stub that answered and the move.
fn Harness::step(
  self : Harness,
  meth : String,
  path : String,
  host? : String = "payments.svc",
  session? : String,
) -> String {
  let outcome = self.send(meth, "http://\{host}\{path}", session?)
  let body = match outcome.plan.body {
    Bytes(body) => @utf8.decode_lossy(body)
    Events(_) => "(events)"
  }
  let stub = matched_id(outcome).unwrap_or("no Stub")
  "\{outcome.plan.status} \{body} (\{stub}; \{moved(outcome)})"
}

///|
test "Scenario state is kept per Session: test-a pays and then sees paid, test-b still sees pending, and test-b's second payment matches nothing" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("test-b GET", h.step("GET", "/orders/42", session="test-b"))
  step("test-b pays", h.step("POST", "/orders/42/pay", session="test-b"))
  step("test-b pays again", h.step("POST", "/orders/42/pay", session="test-b"))
  step("test-b GET", h.step("GET", "/orders/42", session="test-b"))
  step("no Session GET", h.step("GET", "/orders/42"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-a pays: 200  (pay; checkout: Started -> Paid)
      #|test-a GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|test-b GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-b pays: 200  (pay; checkout: Started -> Paid)
      #|test-b pays again: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|test-b GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|no Session GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
    ),
  )
}

///|
/// Mock `auth`, where `GET /token` answers 200 while the Scenario `login`
/// is in `In`, and 401 from a Stub without a clause otherwise. `POST
/// /login` moves `login` to `In` and `POST /logout` back to `Started`, each
/// from any state.
let login : Array[(String, String)] = [
  (
    "auth.json",
    (
      #|{ "mocks": [{ "name": "auth", "hosts": ["auth.svc"] }],
      #|  "stubs": [
      #|    { "id": "token-valid", "mock": "auth", "priority": 1,
      #|      "request": { "method": "GET", "path": "/token" },
      #|      "scenario": { "name": "login", "requires": "In" },
      #|      "response": { "status": 200, "body": "valid" } },
      #|    { "id": "token-invalid", "mock": "auth",
      #|      "request": { "method": "GET", "path": "/token" },
      #|      "response": { "status": 401, "body": "invalid" } },
      #|    { "id": "login", "mock": "auth",
      #|      "request": { "method": "POST", "path": "/login" },
      #|      "scenario": { "name": "login", "moveTo": "In" },
      #|      "response": { "status": 200, "body": "welcome" } },
      #|    { "id": "logout", "mock": "auth",
      #|      "request": { "method": "POST", "path": "/logout" },
      #|      "scenario": { "name": "login", "moveTo": "Started" },
      #|      "response": { "status": 204 } } ] }
    ),
  ),
]

///|
test "a Stub in another state than it requires is skipped and the next one in the usual order answers; a Stub without a clause, or with moveTo and no requires, matches in every state" {
  let walk = (h : Harness) => {
    let out = []
    let step = (label : String, result : String) => {
      out.push("\{label}: \{result}")
    }
    step("GET /token", h.step("GET", "/token", host="auth.svc"))
    step("log in", h.step("POST", "/login", host="auth.svc"))
    step("GET /token", h.step("GET", "/token", host="auth.svc"))
    step("log in again", h.step("POST", "/login", host="auth.svc"))
    step("log out", h.step("POST", "/logout", host="auth.svc"))
    step("GET /token", h.step("GET", "/token", host="auth.svc"))
    step("log out again", h.step("POST", "/logout", host="auth.svc"))
    out.join("\n")
  }
  let indexed = walk(harness(login))
  // The engine that tries every Stub in matching order, the match index's
  // oracle, checks the state the same way.
  let linear = walk(harness(login, match_index=false))
  assert_eq(linear, indexed)
  inspect(
    indexed,
    content=(
      #|GET /token: 401 invalid (token-invalid; no clause)
      #|log in: 200 welcome (login; login: Started -> In)
      #|GET /token: 200 valid (token-valid; login: In -> In)
      #|log in again: 200 welcome (login; login: In -> In)
      #|log out: 204  (logout; login: In -> Started)
      #|GET /token: 401 invalid (token-invalid; no clause)
      #|log out again: 204  (logout; login: Started -> Started)
    ),
  )
}

///|
test "states are compared byte for byte, so case and Unicode normalisation count: every Scenario starts in Started, not started" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "lower-case", "mock": "m", "request": { "path": "/a" },
        #|      "scenario": { "name": "s", "requires": "started" },
        #|      "response": { "status": 200 } },
        #|    { "id": "start", "mock": "m", "request": { "path": "/a" },
        #|      "scenario": { "name": "s", "requires": "Started", "moveTo": "Ü" },
        #|      "response": { "status": 200 } },
        #|    { "id": "decomposed", "mock": "m", "request": { "path": "/a" },
        #|      "scenario": { "name": "s", "requires": "Ü" },
        #|      "response": { "status": 200 } },
        #|    { "id": "composed", "mock": "m", "request": { "path": "/a" },
        #|      "scenario": { "name": "s", "requires": "Ü" },
        #|      "response": { "status": 200 } } ] }
      ),
    ),
  ])
  inspect(
    [h.step("GET", "/a", host="x"), h.step("GET", "/a", host="x")].join("\n"),
    content=(
      #|200  (start; s: Started -> Ü)
      #|200  (composed; s: Ü -> Ü)
    ),
  )
}

///|
/// Mock `m`, the Default Mock, whose Scenario Stubs move on although their
/// responses never arrive whole: `GET /flaky` resets the connection twice,
/// then answers; `GET /slow` is delayed once; `GET /broken` fails to render
/// once. Mock `quiet` does not record its requests in the Journal.
let mishaps : Array[(String, String)] = [
  (
    "m.json",
    (
      #|{ "mocks": [{ "name": "m", "default": true },
      #|    { "name": "quiet", "hosts": ["quiet.svc"], "journal": false }],
      #|  "stubs": [
      #|    { "id": "reset-1", "mock": "m", "request": { "path": "/flaky" },
      #|      "scenario": { "name": "retry", "requires": "Started", "moveTo": "Reset once" },
      #|      "response": { "status": 200, "body": "never sent" },
      #|      "fault": { "connection": { "kind": "reset" } } },
      #|    { "id": "reset-2", "mock": "m", "request": { "path": "/flaky" },
      #|      "scenario": { "name": "retry", "requires": "Reset once", "moveTo": "Reset twice" },
      #|      "response": { "status": 200, "body": "never sent" },
      #|      "fault": { "connection": { "kind": "reset" } } },
      #|    { "id": "flaky-ok", "mock": "m", "request": { "path": "/flaky" },
      #|      "scenario": { "name": "retry", "requires": "Reset twice" },
      #|      "response": { "status": 200, "body": "ok" } },
      #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
      #|      "scenario": { "name": "slow", "requires": "Started", "moveTo": "Done" },
      #|      "response": { "status": 200, "body": "slow" },
      #|      "fault": { "delay": { "fixed": 1500 } } },
      #|    { "id": "slow-done", "mock": "m", "request": { "path": "/slow" },
      #|      "scenario": { "name": "slow", "requires": "Done" },
      #|      "response": { "status": 200, "body": "done" } },
      #|    { "id": "broken", "mock": "m", "request": { "path": "/broken" },
      #|      "scenario": { "name": "render", "requires": "Started", "moveTo": "Failed" },
      #|      "response": { "status": 200, "template": true, "body": "${query.x}" } },
      #|    { "id": "fixed", "mock": "m", "request": { "path": "/broken" },
      #|      "scenario": { "name": "render", "requires": "Failed" },
      #|      "response": { "status": 200, "body": "fixed" } },
      #|    { "id": "quiet-1", "mock": "quiet", "request": { "path": "/q" },
      #|      "scenario": { "name": "q", "requires": "Started", "moveTo": "Done" },
      #|      "response": { "status": 200, "body": "first" } },
      #|    { "id": "quiet-2", "mock": "quiet", "request": { "path": "/q" },
      #|      "scenario": { "name": "q", "requires": "Done" },
      #|      "response": { "status": 200, "body": "second" } } ] }
    ),
  ),
]

///|
/// What became of the response to `GET http://<host><path>`: the Stub, the
/// status, the delay, the connection Fault, whether it failed to render and
/// whether the Journal records it, then the move.
fn Harness::mishap(
  self : Harness,
  path : String,
  host? : String = "m.svc",
) -> String {
  let outcome = self.send("GET", "http://\{host}\{path}")
  let plan = outcome.plan
  let stub = matched_id(outcome).unwrap_or("no Stub")
  let template_error = match outcome.journal {
    Some({ template_error: Some(_), .. }) => ", template error"
    _ => ""
  }
  let journal = if outcome.journal is Some(_) {
    "recorded"
  } else {
    "not recorded"
  }
  "\{stub}: \{plan.status}, delay \{plan.delay_ms}, fault \{@debug.to_string(plan.fault)}\{template_error}, \{journal}; \{moved(outcome)}"
}

///|
test "the state moves at the match decision, whatever then happens to the response: a delay, a connection Fault, a template error, or the Journal off for the Mock or for all" {
  let walk = (h : Harness) => {
    [
      h.mishap("/flaky"),
      h.mishap("/flaky"),
      h.mishap("/flaky"),
      h.mishap("/slow"),
      h.mishap("/slow"),
      h.mishap("/broken"),
      h.mishap("/broken"),
      h.mishap("/q", host="quiet.svc"),
      h.mishap("/q", host="quiet.svc"),
    ].join("\n")
  }
  inspect(
    walk(harness(mishaps)),
    content=(
      #|reset-1: 200, delay 0, fault Some(Reset), recorded; retry: Started -> Reset once
      #|reset-2: 200, delay 0, fault Some(Reset), recorded; retry: Reset once -> Reset twice
      #|flaky-ok: 200, delay 0, fault None, recorded; retry: Reset twice -> Reset twice
      #|slow: 200, delay 1500, fault None, recorded; slow: Started -> Done
      #|slow-done: 200, delay 0, fault None, recorded; slow: Done -> Done
      #|broken: 500, delay 0, fault None, template error, recorded; render: Started -> Failed
      #|fixed: 200, delay 0, fault None, recorded; render: Failed -> Failed
      #|quiet-1: 200, delay 0, fault None, not recorded; q: Started -> Done
      #|quiet-2: 200, delay 0, fault None, not recorded; q: Done -> Done
    ),
  )
  inspect(
    walk(harness(mishaps, journal=@engine.JournalSettings(enabled=false))),
    content=(
      #|reset-1: 200, delay 0, fault Some(Reset), not recorded; retry: Started -> Reset once
      #|reset-2: 200, delay 0, fault Some(Reset), not recorded; retry: Reset once -> Reset twice
      #|flaky-ok: 200, delay 0, fault None, not recorded; retry: Reset twice -> Reset twice
      #|slow: 200, delay 1500, fault None, not recorded; slow: Started -> Done
      #|slow-done: 200, delay 0, fault None, not recorded; slow: Done -> Done
      #|broken: 500, delay 0, fault None, not recorded; render: Started -> Failed
      #|fixed: 200, delay 0, fault None, not recorded; render: Failed -> Failed
      #|quiet-1: 200, delay 0, fault None, not recorded; q: Started -> Done
      #|quiet-2: 200, delay 0, fault None, not recorded; q: Done -> Done
    ),
  )
}

///|
test "requests without a Session share the no-Session space, which no Session sees" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("no Session pays", h.step("POST", "/orders/42/pay"))
  step("no Session GET", h.step("GET", "/orders/42"))
  step("no Session GET again", h.step("GET", "/orders/42"))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  inspect(
    out.join("\n"),
    content=(
      #|no Session pays: 200  (pay; checkout: Started -> Paid)
      #|no Session GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|no Session GET again: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|test-a GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
    ),
  )
}

///|
/// Two Mocks with a Scenario of the same name, `checkout`: `users`, the
/// Default Mock, and `payments`. `GET /step` moves it to `Done`, and then
/// answers from the Stub that requires `Done`.
let two_checkouts : Array[(String, String)] = [
  (
    "mocks.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.svc"], "default": true },
      #|    { "name": "payments", "hosts": ["payments.svc"] }],
      #|  "stubs": [
      #|    { "id": "u-step", "mock": "users",
      #|      "request": { "method": "GET", "path": "/step" },
      #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Done" },
      #|      "response": { "status": 200, "body": "users, first" } },
      #|    { "id": "u-done", "mock": "users",
      #|      "request": { "method": "GET", "path": "/step" },
      #|      "scenario": { "name": "checkout", "requires": "Done" },
      #|      "response": { "status": 200, "body": "users, done" } },
      #|    { "id": "p-step", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/step" },
      #|      "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Done" },
      #|      "response": { "status": 200, "body": "payments, first" } },
      #|    { "id": "p-done", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/step" },
      #|      "scenario": { "name": "checkout", "requires": "Done" },
      #|      "response": { "status": 200, "body": "payments, done" } } ] }
    ),
  ),
]

///|
test "the state that moves is the Mock's that answered: the Default Mock's for an unknown Host, and two Mocks' Scenarios of the same name stay apart" {
  let h = harness(two_checkouts)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("POST, which matches nothing", h.step("POST", "/step", host="other.svc"))
  step("unknown Host", h.step("GET", "/step", host="other.svc"))
  step("users", h.step("GET", "/step", host="users.svc"))
  step("payments", h.step("GET", "/step", host="payments.svc"))
  step("payments", h.step("GET", "/step", host="payments.svc"))
  inspect(
    out.join("\n"),
    content=(
      #|POST, which matches nothing: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|unknown Host: 200 users, first (u-step; checkout: Started -> Done)
      #|users: 200 users, done (u-done; checkout: Done -> Done)
      #|payments: 200 payments, first (p-step; checkout: Started -> Done)
      #|payments: 200 payments, done (p-done; checkout: Done -> Done)
    ),
  )
}

///|
test "nothing moves for a request that no Mock takes" {
  let files = [
    (
      "mocks.json",
      (
        #|{ "mocks": [{ "name": "users", "hosts": ["users.svc"] },
        #|    { "name": "payments", "hosts": ["payments.svc"] }],
        #|  "stubs": [
        #|    { "id": "u-step", "mock": "users",
        #|      "scenario": { "name": "checkout", "moveTo": "Done" },
        #|      "response": { "status": 200, "body": "users" } } ] }
      ),
    ),
  ]
  let h = harness(files)
  inspect(
    [
      h.step("GET", "/step", host="other.svc"),
      h.step("GET", "/step", host="users.svc"),
    ].join("\n"),
    content=(
      #|404 {"error":"no Mock for this Host","host":"other.svc","acceptedHosts":["users.svc","payments.svc"]} (no Stub; no clause)
      #|200 users (u-step; checkout: Started -> Done)
    ),
  )
}

///|
test "an Ephemeral Stub that names a Scenario of the files shares its Session's state with the file Stubs, and other Sessions do not see it" {
  let h = harness(checkout)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let id = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/orders/42/pay" },
      #|  "scenario": { "name": "checkout", "requires": "Started", "moveTo": "Paid" },
      #|  "response": { "status": 202, "body": "accepted" } }
    ),
  )
  step("test-a adds a payment that answers 202", id)
  step("test-a pays", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-a GET", h.step("GET", "/orders/42", session="test-a"))
  step("test-a pays again", h.step("POST", "/orders/42/pay", session="test-a"))
  step("test-b GET", h.step("GET", "/orders/42", session="test-b"))
  step("test-b pays", h.step("POST", "/orders/42/pay", session="test-b"))
  step("test-a lists", h.list("payments", Some("test-a")))
  inspect(
    out.join("\n"),
    content=(
      #|test-a adds a payment that answers 202: eph-1
      #|test-a pays: 202 accepted (eph-1; checkout: Started -> Paid)
      #|test-a GET: 200 {"status":"paid"} (order-paid; checkout: Paid -> Paid)
      #|test-a pays again: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|test-b GET: 200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|test-b pays: 200  (pay; checkout: Started -> Paid)
      #|test-a lists: {"id":"eph-1","mock":"payments","session":"test-a","request":{"method":"POST","path":"/orders/42/pay"},"scenario":{"name":"checkout","requires":"Started","moveTo":"Paid"},"response":{"status":202,"body":"accepted"}}
    ),
  )
}

///|
test "Ephemeral Stubs may name Scenarios and states that no file names, and deleting one leaves the state as it is" {
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
      #|  "scenario": { "name": "outage", "requires": "Started", "moveTo": "Down once" },
      #|  "response": { "status": 503, "body": "down" } }
    ),
  )
  let up =
    #|{ "request": { "method": "GET", "path": "/health" },
    #|  "scenario": { "name": "outage", "requires": "Down once" },
    #|  "response": { "status": 200, "body": "up" } }
  let first_up = h.add("payments", Some("test-a"), up)
  step("test-a adds", "\{down}, \{first_up}")
  step("test-a GET /health", h.step("GET", "/health", session="test-a"))
  step("test-a GET /health", h.step("GET", "/health", session="test-a"))
  step("test-b GET /health", h.step("GET", "/health", session="test-b"))
  step(
    "test-a deletes both",
    "\{h.delete("payments", Some("test-a"), down)}, \{h.delete("payments", Some("test-a"), first_up)}",
  )
  step("test-a GET /health", h.step("GET", "/health", session="test-a"))
  step("test-a adds up again", h.add("payments", Some("test-a"), up))
  step("test-a GET /health", h.step("GET", "/health", session="test-a"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a adds: eph-1, eph-2
      #|test-a GET /health: 503 down (eph-1; outage: Started -> Down once)
      #|test-a GET /health: 200 up (eph-2; outage: Down once -> Down once)
      #|test-b GET /health: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|test-a deletes both: deleted, deleted
      #|test-a GET /health: 404 {"error":"no Stub matched"} (no Stub; no clause)
      #|test-a adds up again: eph-3
      #|test-a GET /health: 200 up (eph-3; outage: Down once -> Down once)
    ),
  )
}

///|
test "render ignores the Scenario clause and moves nothing, and a Journal filter's request conditions match whatever the state" {
  let h = harness(checkout)
  let render = (id : String, meth : String, path : String) => {
    let sample : Json = {
      "method": Json::string(meth),
      "path": Json::string(path),
      "session": "test-a",
    }
    let rendering = h.engine.render(
      id,
      @engine.SampleRequest::from_json(sample),
      now=h.now,
      fresh_seed=() => 7,
    ) catch {
      err => return @debug.to_string(err)
    }
    guard rendering.to_json()
      is { "response": { "status": status, .. }, "failed": failed, .. } else {
      return "no status"
    }
    "render \{id}: \{status.stringify()}, failed \{failed.stringify()}"
  }
  let out = [
    render("order-paid", "GET", "/orders/42"),
    render("pay", "POST", "/orders/42/pay"),
    h.step("GET", "/orders/42", session="test-a"),
  ]
  // The first GET is answered in Started and the second in Paid: the
  // filter's request conditions take both.
  for target in ["/orders/42", "/orders/42/pay", "/orders/42"] {
    let meth = if target.has_suffix("pay") { "POST" } else { "GET" }
    ignore(h.record(meth, "http://payments.svc\{target}", session="test-a"))
  }
  out.push(
    h.listed(
      Some("test-a"),
      query="{ \"filter\": { \"method\": \"GET\", \"path\": \"/orders/42\" } }",
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|render order-paid: 200, failed []
      #|render pay: 200, failed []
      #|200 {"status":"pending"} (order-pending; checkout: Started -> Started)
      #|GET http://payments.svc/orders/42 (test-a)
      #|GET http://payments.svc/orders/42 (test-a)
      #|more: false, evicted: 0
    ),
  )
}

///|
/// Adds the Ephemeral Stub `stub`, given as JSON text, to `payments` for
/// the Session test-a: its ID, or each problem on a line of its own.
fn Harness::payments_problems(self : Harness, stub : String) -> String raise {
  let stub = @json.parse(stub)
  let added = self.engine.add_ephemeral_stub(
    mock="payments",
    session=Some("test-a"),
    stub,
  ) catch {
    InvalidStub(problems) =>
      return problems.map(problem => problem.to_string()).join("\n")
    err => fail(@debug.to_string(err))
  }
  added.id
}

///|
test "an Ephemeral Stub's Scenario clause is validated like a file Stub's, with the same messages" {
  let h = harness(checkout)
  inspect(
    [
      h.payments_problems(
        "{ \"scenario\": { \"name\": \"checkout\" }, \"response\": { \"status\": 200 } }",
      ),
      h.payments_problems(
        "{ \"scenario\": { \"name\": \"\", \"requires\": 1, \"to\": \"x\" }, \"response\": { \"status\": 200 } }",
      ),
      h.payments_problems(
        "{ \"scenario\": null, \"response\": { \"status\": 200 } }",
      ),
    ].join("\n"),
    content=(
      #|/scenario: must give requires, moveTo or both
      #|/scenario/name: must be a non-empty string
      #|/scenario/requires: must be a non-empty string
      #|/scenario/to: is not a known field
      #|/scenario: must be an object
    ),
  )
}
