// How the engine stores Scenario state: only states other than Started,
// with no map left empty. Nothing outside the engine can see this, since a
// Scenario without an entry is in Started either way, so these tests look
// at the store itself after requests through `Engine::handle`, and after
// reloads through `Engine::reload`.

///|
/// Mock `payments`, where, from any state, `POST /orders/42/pay` moves
/// `checkout` to `Paid` and `POST /orders/42/refund` back to `Started`, and
/// `POST /orders/42/ship` moves `shipping` to `Shipped` and `POST
/// /orders/42/return` back to `Started`.
let store_files : String =
  #|{ "mocks": [{ "name": "payments" }],
  #|  "stubs": [
  #|    { "id": "pay", "mock": "payments", "request": { "path": "/orders/42/pay" },
  #|      "scenario": { "name": "checkout", "moveTo": "Paid" },
  #|      "response": { "status": 200 } },
  #|    { "id": "refund", "mock": "payments", "request": { "path": "/orders/42/refund" },
  #|      "scenario": { "name": "checkout", "moveTo": "Started" },
  #|      "response": { "status": 200 } },
  #|    { "id": "ship", "mock": "payments", "request": { "path": "/orders/42/ship" },
  #|      "scenario": { "name": "shipping", "moveTo": "Shipped" },
  #|      "response": { "status": 200 } },
  #|    { "id": "return", "mock": "payments", "request": { "path": "/orders/42/return" },
  #|      "scenario": { "name": "shipping", "moveTo": "Started" },
  #|      "response": { "status": 200 } } ] }

///|
test "only states other than Started are stored, and a move back to Started leaves no empty map behind" {
  let set : @definitions.DefinitionSet = {
    files: [("payments.json", @utf8.encode(store_files))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let engine = Engine(snapshot)
  let rand = @prng.Generator(1)
  let out = []
  let step = (label : String, path : String, session : String?) => {
    let request : Request = {
      meth: "POST",
      target: path,
      version: "HTTP/1.1",
      headers: [],
      body: b"",
    }
    ignore(engine.handle(request, session~, now=0, rand~))
    out.push("\{label}: \{@debug.to_string(engine.scenarios.by_mock)}")
  }
  step("test-a refunds in Started", "/orders/42/refund", Some("test-a"))
  step("test-a pays", "/orders/42/pay", Some("test-a"))
  step("test-a pays again", "/orders/42/pay", Some("test-a"))
  step("test-a ships", "/orders/42/ship", Some("test-a"))
  step("test-b pays", "/orders/42/pay", Some("test-b"))
  step("no Session pays", "/orders/42/pay", None)
  step("test-a refunds", "/orders/42/refund", Some("test-a"))
  step("test-b refunds", "/orders/42/refund", Some("test-b"))
  step("no Session refunds", "/orders/42/refund", None)
  step("test-a ships again", "/orders/42/ship", Some("test-a"))
  step("test-a returns", "/orders/42/return", Some("test-a"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a refunds in Started: {}
      #|test-a pays: { "payments": { Some("test-a"): { "checkout": "Paid" } } }
      #|test-a pays again: { "payments": { Some("test-a"): { "checkout": "Paid" } } }
      #|test-a ships: { "payments": { Some("test-a"): { "checkout": "Paid", "shipping": "Shipped" } } }
      #|test-b pays: {
      #|  "payments": {
      #|    Some("test-a"): { "checkout": "Paid", "shipping": "Shipped" },
      #|    Some("test-b"): { "checkout": "Paid" },
      #|  },
      #|}
      #|no Session pays: {
      #|  "payments": {
      #|    Some("test-a"): { "checkout": "Paid", "shipping": "Shipped" },
      #|    Some("test-b"): { "checkout": "Paid" },
      #|    None: { "checkout": "Paid" },
      #|  },
      #|}
      #|test-a refunds: {
      #|  "payments": {
      #|    Some("test-a"): { "shipping": "Shipped" },
      #|    Some("test-b"): { "checkout": "Paid" },
      #|    None: { "checkout": "Paid" },
      #|  },
      #|}
      #|test-b refunds: {
      #|  "payments": {
      #|    Some("test-a"): { "shipping": "Shipped" },
      #|    None: { "checkout": "Paid" },
      #|  },
      #|}
      #|no Session refunds: { "payments": { Some("test-a"): { "shipping": "Shipped" } } }
      #|test-a ships again: { "payments": { Some("test-a"): { "shipping": "Shipped" } } }
      #|test-a returns: {}
    ),
  )
}

///|
test "a reload that sends states back to Started, or drops a Mock's, leaves no empty map behind" {
  let set = (files : String) => {
    let set : @definitions.DefinitionSet = {
      files: [("payments.json", @utf8.encode(files))],
      body_files: [],
    }
    set
  }
  guard @definitions.load(set(store_files)) is Ok(snapshot) else {
    fail("not loaded")
  }
  let engine = Engine(snapshot)
  let rand = @prng.Generator(1)
  let send = (path : String, session : String?) => {
    let request : Request = {
      meth: "POST",
      target: path,
      version: "HTTP/1.1",
      headers: [],
      body: b"",
    }
    ignore(engine.handle(request, session~, now=0, rand~))
  }
  let out = []
  let reload = (label : String, files : String) => {
    let result = engine.reload(set(files), at=0)
    out.push(
      "\{label}: \{result.scenario_states_reset} back to Started; \{@debug.to_string(engine.scenarios.by_mock)}",
    )
  }
  send("/orders/42/pay", Some("test-a"))
  send("/orders/42/ship", Some("test-a"))
  send("/orders/42/pay", Some("test-b"))
  let sent = store_files.replace(old="\"Shipped\"", new="\"Sent\"")
  reload("Shipped renamed Sent", sent)
  reload(
    "Paid renamed Settled too",
    sent.replace(old="\"Paid\"", new="\"Settled\""),
  )
  send("/orders/42/pay", Some("test-a"))
  reload("payments removed", "{ \"mocks\": [{ \"name\": \"users\" }] }")
  inspect(
    out.join("\n"),
    content=(
      #|Shipped renamed Sent: 1 back to Started; {
      #|  "payments": {
      #|    Some("test-a"): { "checkout": "Paid" },
      #|    Some("test-b"): { "checkout": "Paid" },
      #|  },
      #|}
      #|Paid renamed Settled too: 2 back to Started; {}
      #|payments removed: 0 back to Started; {}
    ),
  )
}
