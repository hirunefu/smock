// Seam 1 tests of Sessions and Ephemeral Stubs: Ephemeral Stubs added
// through the engine's Admin API operations, the order they are tried in,
// Session isolation, reset scopes and reloads.

///|
/// Two Mocks, as in the state-model prototype: `users`, the Default Mock,
/// and `payments`, each with Stubs from Definition files.
let shop : Array[(String, String)] = [
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
      #|    { "id": "u-any", "mock": "users",
      #|      "request": { "method": "GET", "path": { "pattern": "/users/[0-9]+" } },
      #|      "response": { "status": 200, "body": "Generic" } },
      #|    { "id": "u-alice", "mock": "users", "priority": 1,
      #|      "request": { "method": "GET", "path": "/users/1" },
      #|      "response": { "status": 200, "body": "Alice" } } ] }
    ),
  ),
  (
    "20-payments.json",
    (
      #|{ "stubs": [
      #|    { "id": "p-health", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/health" },
      #|      "response": { "status": 200, "body": "ok" } },
      #|    { "id": "p-order", "mock": "payments",
      #|      "request": { "method": "GET", "path": "/orders/42" },
      #|      "response": { "status": 200, "body": "pending" } } ] }
    ),
  ),
]

///|
/// Adds an Ephemeral Stub, given as JSON text, to `mock` for `session`, and
/// returns its ID.
fn Harness::add(
  self : Harness,
  mock : String,
  session : String?,
  stub : String,
) -> String raise {
  self.engine.add_ephemeral_stub(mock~, session~, @json.parse(stub)).id
}

///|
/// An Ephemeral Stub that answers `GET path` with `status` and `body`.
fn get_stub(
  path : String,
  status : Int,
  body : String,
  priority? : Int,
) -> String {
  let priority = match priority {
    Some(p) => ", \"priority\": \{p}"
    None => ""
  }
  "{ \"request\": { \"method\": \"GET\", \"path\": \"\{path}\" }, \"response\": { \"status\": \{status}, \"body\": \"\{body}\" }\{priority} }"
}

///|
/// `GET http://<host><path>` with `session`, as the status, the body and
/// the Stub that answered.
fn Harness::brief(
  self : Harness,
  host : String,
  path : String,
  session? : String,
) -> String {
  let outcome = self.send("GET", "http://\{host}\{path}", session?)
  let body = match outcome.plan.body {
    Bytes(body) => @utf8.decode_lossy(body)
    Events(_) => "(events)"
  }
  "\{outcome.plan.status} \{body} (\{matched_id(outcome).unwrap_or("no Stub")})"
}

///|
test "an Ephemeral Stub applies only to requests with the Session it was added for; one added without a Session only to requests without one" {
  let h = harness(shop)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let id = h.add(
    "payments",
    Some("test-a"),
    get_stub("/orders/42", 503, "down"),
  )
  step("test-a adds GET /orders/42 -> 503", id)
  step("test-a", h.brief("payments.svc", "/orders/42", session="test-a"))
  step("test-b", h.brief("payments.svc", "/orders/42", session="test-b"))
  step("no Session", h.brief("payments.svc", "/orders/42"))
  let id = h.add("payments", None, get_stub("/orders/42", 500, "boom"))
  step("no Session adds GET /orders/42 -> 500", id)
  step("no Session", h.brief("payments.svc", "/orders/42"))
  step("test-b", h.brief("payments.svc", "/orders/42", session="test-b"))
  step("test-a", h.brief("payments.svc", "/orders/42", session="test-a"))
  step(
    "test-a, another Mock",
    h.brief("users.svc", "/users/1", session="test-a"),
  )
  inspect(
    out.join("\n"),
    content=(
      #|test-a adds GET /orders/42 -> 503: eph-1
      #|test-a: 503 down (eph-1)
      #|test-b: 200 pending (p-order)
      #|no Session: 200 pending (p-order)
      #|no Session adds GET /orders/42 -> 500: eph-2
      #|no Session: 500 boom (eph-2)
      #|test-b: 200 pending (p-order)
      #|test-a: 503 down (eph-1)
      #|test-a, another Mock: 200 Alice (u-alice)
    ),
  )
}

///|
/// An Ephemeral Stub that answers `GET` on paths matching `pattern` with
/// 200 and `body`.
fn pattern_stub(pattern : String, body : String, priority? : Int) -> String {
  let priority = match priority {
    Some(p) => ", \"priority\": \{p}"
    None => ""
  }
  "{ \"request\": { \"method\": \"GET\", \"path\": { \"pattern\": \"\{pattern}\" } }, \"response\": { \"status\": 200, \"body\": \"\{body}\" }\{priority} }"
}

///|
test "Ephemeral Stubs are tried before every Stub from Definition files, by their own priority, the newest first among equal priorities" {
  let h = harness(shop)
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step(
    "add GET /users/1 -> Carol",
    h.add("users", None, get_stub("/users/1", 200, "Carol")),
  )
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step(
    "add GET /users/[0-9]+ -> Erin",
    h.add("users", None, pattern_stub("/users/[0-9]+", "Erin")),
  )
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step(
    "add GET /users/1 -> Frank, priority 5",
    h.add("users", None, get_stub("/users/1", 200, "Frank", priority=5)),
  )
  step(
    "add GET /users/[0-9]+ -> Grace, priority 7",
    h.add("users", None, pattern_stub("/users/[0-9]+", "Grace", priority=7)),
  )
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step("GET /users/2", h.brief("users.svc", "/users/2"))
  step(
    "add GET /users/[0-9]+ -> Heidi, priority 5",
    h.add("users", None, pattern_stub("/users/[0-9]+", "Heidi", priority=5)),
  )
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step(
    "add GET /users/1 -> Ivan, priority -2147483648",
    h.add(
      "users",
      None,
      get_stub("/users/1", 200, "Ivan", priority=-2147483648),
    ),
  )
  step("GET /users/1", h.brief("users.svc", "/users/1"))
  step("GET /users/3", h.brief("users.svc", "/users/3"))
  step("GET /users/x", h.brief("users.svc", "/users/x"))
  inspect(
    out.join("\n"),
    content=(
      #|GET /users/1: 200 Alice (u-alice)
      #|add GET /users/1 -> Carol: eph-1
      #|GET /users/1: 200 Carol (eph-1)
      #|add GET /users/[0-9]+ -> Erin: eph-2
      #|GET /users/1: 200 Erin (eph-2)
      #|add GET /users/1 -> Frank, priority 5: eph-3
      #|add GET /users/[0-9]+ -> Grace, priority 7: eph-4
      #|GET /users/1: 200 Frank (eph-3)
      #|GET /users/2: 200 Grace (eph-4)
      #|add GET /users/[0-9]+ -> Heidi, priority 5: eph-5
      #|GET /users/1: 200 Heidi (eph-5)
      #|add GET /users/1 -> Ivan, priority -2147483648: eph-6
      #|GET /users/1: 200 Ivan (eph-6)
      #|GET /users/3: 200 Heidi (eph-5)
      #|GET /users/x: 404 {"error":"no Stub matched"} (no Stub)
    ),
  )
}

///|
/// The `Smock-Near-Miss` header of the response to `meth target`, with
/// `session`, and the Near miss in full, as JSON.
fn Harness::near_miss(
  self : Harness,
  meth : String,
  target : String,
  session? : String,
) -> String {
  let outcome = self.send(meth, target, session?)
  let header = outcome.plan.headers
    .iter()
    .filter(h => h.0 == "Smock-Near-Miss")
    .map(h => h.1)
    .collect()
    .join(", ")
  let full = match outcome.near_miss {
    Some(near_miss) => ToJson::to_json(near_miss).stringify()
    None => "none"
  }
  "\{header}\n  \{full}"
}

///|
test "Ephemeral Stubs are Near miss candidates in the order they are tried, and the header names their eph-<n> ID" {
  let h = harness(shop)
  let _ = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/orders/42" },
      #|  "response": { "status": 503 } }
    ),
  )
  let _ = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "request": { "method": "PUT", "path": "/orders/42",
      #|               "headers": { "X-Api-Key": "k" } },
      #|  "response": { "status": 503 } }
    ),
  )
  let out = [
    "test-a: \{h.near_miss("DELETE", "http://payments.svc/orders/42", session="test-a")}",
    "test-a: \{h.near_miss("PUT", "http://payments.svc/orders/42", session="test-a")}",
    "test-b: \{h.near_miss("DELETE", "http://payments.svc/orders/42", session="test-b")}",
  ]
  inspect(
    out.join("\n"),
    content=(
      #|test-a: eph-1; failed=method
      #|  {"stub":"eph-1","stubSource":"ephemeral","failed":[{"condition":"method","expected":"POST","actual":["DELETE"]}]}
      #|test-a: eph-2; failed=header:x-api-key
      #|  {"stub":"eph-2","stubSource":"ephemeral","failed":[{"condition":"header:x-api-key","expected":"k","actual":[]}]}
      #|test-b: p-order; failed=method
      #|  {"stub":"p-order","stubSource":"file","failed":[{"condition":"method","expected":"GET","actual":["DELETE"]}]}
    ),
  )
}

///|
/// The Ephemeral Stubs of `mock` for `session` as the engine lists them,
/// as JSON, one per line, or the error.
fn Harness::list(self : Harness, mock : String, session : String?) -> String {
  let stubs = self.engine.ephemeral_stubs(mock~, session~) catch {
    err => return @debug.to_string(err)
  }
  stubs.map(stub => ToJson::to_json(stub).stringify()).join("\n")
}

///|
/// Deletes the Ephemeral Stub `id` of `mock` for `session`: `deleted`, or
/// the error.
fn Harness::delete(
  self : Harness,
  mock : String,
  session : String?,
  id : String,
) -> String {
  self.engine.delete_ephemeral_stub(mock~, session~, id~) catch {
    err => return @debug.to_string(err)
  }
  "deleted"
}

///|
test "list gives only the calling Session's Ephemeral Stubs of the Mock, as they were added, in the order they are tried" {
  let h = harness(shop)
  let _ = h.add("payments", Some("test-a"), get_stub("/orders/42", 503, "a"))
  let _ = h.add("payments", Some("test-b"), get_stub("/orders/42", 503, "b"))
  let _ = h.add("payments", None, get_stub("/orders/42", 503, "none"))
  let _ = h.add("users", Some("test-a"), get_stub("/users/1", 200, "a"))
  let _ = h.add(
    "payments",
    Some("test-a"),
    (
      #|{ "priority": 3, "response": { "status": 204 },
      #|  "fault": { "delay": { "fixed": 10 } } }
    ),
  )
  let out = [
    "payments, test-a:\n\{h.list("payments", Some("test-a"))}",
    "payments, test-b:\n\{h.list("payments", Some("test-b"))}",
    "payments, no Session:\n\{h.list("payments", None)}",
    "payments, test-c:\n\{h.list("payments", Some("test-c"))}",
    "users, test-a:\n\{h.list("users", Some("test-a"))}",
    "orders, test-a:\n\{h.list("orders", Some("test-a"))}",
  ]
  inspect(
    out.join("\n"),
    content=(
      #|payments, test-a:
      #|{"id":"eph-5","mock":"payments","session":"test-a","priority":3,"response":{"status":204},"fault":{"delay":{"fixed":10}}}
      #|{"id":"eph-1","mock":"payments","session":"test-a","request":{"method":"GET","path":"/orders/42"},"response":{"status":503,"body":"a"}}
      #|payments, test-b:
      #|{"id":"eph-2","mock":"payments","session":"test-b","request":{"method":"GET","path":"/orders/42"},"response":{"status":503,"body":"b"}}
      #|payments, no Session:
      #|{"id":"eph-3","mock":"payments","session":null,"request":{"method":"GET","path":"/orders/42"},"response":{"status":503,"body":"none"}}
      #|payments, test-c:
      #|
      #|users, test-a:
      #|{"id":"eph-4","mock":"users","session":"test-a","request":{"method":"GET","path":"/users/1"},"response":{"status":200,"body":"a"}}
      #|orders, test-a:
      #|UnknownMock("orders")
    ),
  )
}

///|
test "delete removes only one of the calling Session's Ephemeral Stubs of the Mock" {
  let h = harness(shop)
  let a = h.add("payments", Some("test-a"), get_stub("/orders/42", 503, "a"))
  let b = h.add("payments", Some("test-b"), get_stub("/orders/42", 503, "b"))
  let out = [
    "test-b deletes test-a's \{a}: \{h.delete("payments", Some("test-b"), a)}",
    "no Session deletes test-a's \{a}: \{h.delete("payments", None, a)}",
    "test-a deletes \{a} from users: \{h.delete("users", Some("test-a"), a)}",
    "test-a deletes \{a} from orders: \{h.delete("orders", Some("test-a"), a)}",
    "test-a: \{h.brief("payments.svc", "/orders/42", session="test-a")}",
    "test-a deletes \{a}: \{h.delete("payments", Some("test-a"), a)}",
    "test-a: \{h.brief("payments.svc", "/orders/42", session="test-a")}",
    "test-a deletes \{a} again: \{h.delete("payments", Some("test-a"), a)}",
    "test-b: \{h.brief("payments.svc", "/orders/42", session="test-b")}",
    "test-b deletes \{b}: \{h.delete("payments", Some("test-b"), b)}",
    "test-b: \{h.brief("payments.svc", "/orders/42", session="test-b")}",
  ]
  inspect(
    out.join("\n"),
    content=(
      #|test-b deletes test-a's eph-1: UnknownEphemeralStub(mock="payments", id="eph-1")
      #|no Session deletes test-a's eph-1: UnknownEphemeralStub(mock="payments", id="eph-1")
      #|test-a deletes eph-1 from users: UnknownEphemeralStub(mock="users", id="eph-1")
      #|test-a deletes eph-1 from orders: UnknownMock("orders")
      #|test-a: 503 a (eph-1)
      #|test-a deletes eph-1: deleted
      #|test-a: 200 pending (p-order)
      #|test-a deletes eph-1 again: UnknownEphemeralStub(mock="payments", id="eph-1")
      #|test-b: 503 b (eph-2)
      #|test-b deletes eph-2: deleted
      #|test-b: 200 pending (p-order)
    ),
  )
}

///|
/// Every Ephemeral Stub left, as `<mock>/<session>: <ids>` for each Mock
/// and Session that has some. A Mock that is gone has none.
fn Harness::remaining(self : Harness) -> String {
  let out = []
  for mock in ["users", "payments"] {
    for session in [Some("test-a"), Some("test-b"), None] {
      let ids = self.engine.ephemeral_stubs(mock~, session~) catch {
        UnknownMock(_) => []
        err => abort(@debug.to_string(err))
      }
      if ids.length() > 0 {
        let session = session.unwrap_or("no Session")
        out.push("\{mock}/\{session}: \{ids.map(s => s.id).join(" ")}")
      }
    }
  }
  if out.is_empty() {
    "none left"
  } else {
    out.join(", ")
  }
}

///|
/// Resets `scope`: how many Ephemeral Stubs it removed and those left, or
/// the error.
fn Harness::reset(self : Harness, scope : @engine.ResetScope) -> String {
  let removed = self.engine.reset(scope) catch {
    err => return @debug.to_string(err)
  }
  "removed \{removed.ephemeral_stubs}; \{self.remaining()}"
}

///|
test "reset clears the Ephemeral Stubs of the calling Session across all Mocks, of one Mock for every Session, or all of them" {
  let h = harness(shop)
  let add = (mock : String, session : String?) => {
    h.add(mock, session, get_stub("/orders/42", 503, "x")) |> ignore
  }
  add("users", Some("test-a"))
  add("payments", Some("test-a"))
  add("payments", Some("test-b"))
  add("users", Some("test-b"))
  add("payments", None)
  add("users", None)
  let out = [
    "before: \{h.remaining()}",
    "Session test-a: \{h.reset(Session(Some("test-a")))}",
    "Session test-a again: \{h.reset(Session(Some("test-a")))}",
    "Mock payments: \{h.reset(Mock("payments"))}",
    "Mock orders: \{h.reset(Mock("orders"))}",
    "no Session: \{h.reset(Session(None))}",
    "all: \{h.reset(All)}",
  ]
  add("payments", Some("test-b"))
  add("users", None)
  out.push("added since: \{h.remaining()}")
  out.push("all: \{h.reset(All)}")
  inspect(
    out.join("\n"),
    content=(
      #|before: users/test-a: eph-1, users/test-b: eph-4, users/no Session: eph-6, payments/test-a: eph-2, payments/test-b: eph-3, payments/no Session: eph-5
      #|Session test-a: removed 2; users/test-b: eph-4, users/no Session: eph-6, payments/test-b: eph-3, payments/no Session: eph-5
      #|Session test-a again: removed 0; users/test-b: eph-4, users/no Session: eph-6, payments/test-b: eph-3, payments/no Session: eph-5
      #|Mock payments: removed 2; users/test-b: eph-4, users/no Session: eph-6
      #|Mock orders: UnknownMock("orders")
      #|no Session: removed 1; users/test-b: eph-4
      #|all: removed 1; none left
      #|added since: users/no Session: eph-8, payments/test-b: eph-7
      #|all: removed 2; none left
    ),
  )
}

///|
/// `shop` with `payments` and its Stubs removed, and `u-alice` answering
/// "Alice 2".
let shop_without_payments : Array[(String, String)] = [
  (
    "00-mocks.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.svc"], "default": true }] }
    ),
  ),
  (
    "10-users.json",
    (
      #|{ "stubs": [
      #|    { "id": "u-alice", "mock": "users", "priority": 1,
      #|      "request": { "method": "GET", "path": "/users/1" },
      #|      "response": { "status": 200, "body": "Alice 2" } } ] }
    ),
  ),
]

///|
test "Ephemeral Stubs survive a reload, but a reload that removes a Mock drops its Ephemeral Stubs, and its Hosts resolve like any unknown Host" {
  let h = harness(shop)
  let _ = h.add("users", Some("test-a"), get_stub("/users/2", 200, "Bob"))
  let _ = h.add("payments", Some("test-b"), get_stub("/health", 500, "down"))
  let out = []
  let step = (label : String, result : String) => {
    out.push("\{label}: \{result}")
  }
  let reload = (files : Array[(String, String)]) => {
    let result = h.engine.reload(
      { files: files.map(f => (f.0, @utf8.encode(f.1))), body_files: [], },
      at=fixed_now,
    )
    @debug.to_string(result.result)
  }
  step("before", h.remaining())
  step("reload, unchanged", reload(shop))
  step("after", h.remaining())
  step(
    "reload, invalid",
    reload([..shop, ("30-bad.json", "{ \"stubs\": [{ \"id\": \"x\" }] }")]),
  )
  step("after", h.remaining())
  let shop_v2 = shop.map(file => {
    (file.0, file.1.replace(old="\"Alice\"", new="\"Alice 2\""))
  })
  step("reload, u-alice changed", reload(shop_v2))
  step("after", h.remaining())
  step("test-a", h.brief("users.svc", "/users/2", session="test-a"))
  step("test-a", h.brief("users.svc", "/users/1", session="test-a"))
  step("test-b", h.brief("payments.svc", "/health", session="test-b"))
  step("reload, payments removed", reload(shop_without_payments))
  step("after", h.remaining())
  step("test-b", h.brief("payments.svc", "/health", session="test-b"))
  step(
    "payments.svc resolves to",
    @debug.to_string(
      h.send("GET", "http://payments.svc/health", session="test-b").resolution,
    ),
  )
  step("test-a", h.brief("users.svc", "/users/2", session="test-a"))
  step("list payments", h.list("payments", Some("test-b")))
  step("add to payments", h.add_or_error("payments", Some("test-b")))
  step("reload, payments back", reload(shop))
  step("after", h.remaining())
  step("test-b", h.brief("payments.svc", "/health", session="test-b"))
  inspect(
    out.join("\n"),
    content=(
      #|before: users/test-a: eph-1, payments/test-b: eph-2
      #|reload, unchanged: Unchanged
      #|after: users/test-a: eph-1, payments/test-b: eph-2
      #|reload, invalid: Failed
      #|after: users/test-a: eph-1, payments/test-b: eph-2
      #|reload, u-alice changed: Swapped
      #|after: users/test-a: eph-1, payments/test-b: eph-2
      #|test-a: 200 Bob (eph-1)
      #|test-a: 200 Alice 2 (u-alice)
      #|test-b: 500 down (eph-2)
      #|reload, payments removed: Swapped
      #|after: users/test-a: eph-1
      #|test-b: 404 {"error":"no Stub matched"} (no Stub)
      #|payments.svc resolves to: ViaDefault("users")
      #|test-a: 200 Bob (eph-1)
      #|list payments: UnknownMock("payments")
      #|add to payments: UnknownMock("payments")
      #|reload, payments back: Swapped
      #|after: users/test-a: eph-1
      #|test-b: 200 ok (p-health)
    ),
  )
}

///|
/// Adds the Ephemeral Stub `stub`, given as JSON text, to `users` without a
/// Session: its ID, or each problem on a line of its own, as
/// `Diagnostic::to_string` writes it.
fn Harness::problems(self : Harness, stub : String) -> String raise {
  let stub = @json.parse(stub)
  let added = self.engine.add_ephemeral_stub(mock="users", session=None, stub) catch {
    InvalidStub(problems) =>
      return problems.map(problem => problem.to_string()).join("\n")
    err => fail(@debug.to_string(err))
  }
  added.id
}

///|
test "Ephemeral Stubs are validated and compiled like Stubs from Definition files, with the same messages" {
  let h = harness(shop)
  let file_problems = match
    @definitions.load({
      files: [
        (
          "users.json",
          @utf8.encode(
            (
              #|{ "mocks": [{ "name": "users" }],
              #|  "stubs": [{ "id": "s", "mock": "users",
              #|    "request": { "method": "GET /", "path": { "pattern": "(" } },
              #|    "response": { "status": 99, "headers": { "Content-Length": "1", "X-A": "1", "x-a": "2" } },
              #|    "colour": "red" }] }
            ),
          ),
        ),
      ],
      body_files: [],
    }) {
    Ok(_) => fail("the Definition file is valid")
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
  let ephemeral_problems = h.problems(
    (
      #|{ "request": { "method": "GET /", "path": { "pattern": "(" } },
      #|  "response": { "status": 99, "headers": { "Content-Length": "1", "X-A": "1", "x-a": "2" } },
      #|  "colour": "red" }
    ),
  )
  inspect(
    "Definition file:\n\{file_problems}\nEphemeral Stub:\n\{ephemeral_problems}",
    content=(
      #|Definition file:
      #|users.json: /stubs/0/request/method: must be an HTTP token, such as GET
      #|users.json: /stubs/0/request/path/pattern: is not a valid pattern: position 0: missing closing )
      #|users.json: /stubs/0/response/status: must be an integer from 200 to 599
      #|users.json: /stubs/0/response/headers/Content-Length: is set by smock and cannot be given
      #|users.json: /stubs/0/response/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
      #|users.json: /stubs/0/colour: is not a known field
      #|Ephemeral Stub:
      #|/request/method: must be an HTTP token, such as GET
      #|/request/path/pattern: is not a valid pattern: position 0: missing closing )
      #|/response/status: must be an integer from 200 to 599
      #|/response/headers/Content-Length: is set by smock and cannot be given
      #|/response/headers/x-a: the header name "X-A" is already given: header names are case-insensitive
      #|/colour: is not a known field
    ),
  )
}

///|
test "an Ephemeral Stub may give a header an array: it answers with one field per value, and is listed with the array as added" {
  let h = harness(shop)
  let _ = h.add(
    "users",
    None,
    (
      #|{ "request": { "path": "/login" },
      #|  "response": { "status": 200, "headers": { "X-A": "1", "Set-Cookie": ["a=1", "b=2"] } } }
    ),
  )
  inspect(
    response(h.send("GET", "http://users.svc/login")) +
    "---\n" +
    h.list("users", None) +
    "\n---\n" +
    h.problems(
      (
        #|{ "response": { "status": 200, "headers": { "Set-Cookie": [], "Content-Type": ["text/plain"] } } }
      ),
    ),
    content=(
      #|200
      #|X-A: 1
      #|Set-Cookie: a=1
      #|Set-Cookie: b=2
      #|---
      #|{"id":"eph-1","mock":"users","session":null,"request":{"path":"/login"},"response":{"status":200,"headers":{"X-A":"1","Set-Cookie":["a=1","b=2"]}}}
      #|---
      #|/response/headers/Set-Cookie: must not be an empty array
      #|/response/headers/Content-Type: must be a string
    ),
  )
}

///|
test "an Ephemeral Stub with an id or a mock, or a body from a body file, is rejected, and one that is not an object or has no response too" {
  let h = harness(shop)
  let cases = [
    (
      "id and mock",
      (
        #|{ "id": "mine", "mock": "users", "response": { "status": 200 } }
      ),
    ),
    (
      "a body file",
      (
        #|{ "response": { "status": 200, "bodyFile": "users/1.json" } }
      ),
    ),
    ("no response", "{ \"request\": { \"method\": \"GET\" } }"),
    ("an array", "[]"),
    (
      "a seed out of range", "{ \"response\": { \"status\": 200 }, \"fault\": { \"seed\": -1 } }",
    ),
    ("valid", "{ \"response\": { \"status\": 200 } }"),
  ]
  let out = cases.map(case => "\{case.0}:\n\{h.problems(case.1)}")
  inspect(
    out.join("\n"),
    content=(
      #|id and mock:
      #|/id: is not allowed in an Ephemeral Stub: smock assigns its ID
      #|/mock: is not allowed in an Ephemeral Stub: the Admin API path names its Mock
      #|a body file:
      #|/response/bodyFile: is not allowed in an Ephemeral Stub, whose body must be inline: give "body" instead
      #|no response:
      #|needs "response"
      #|an array:
      #|must be an object
      #|a seed out of range:
      #|/fault/seed: must be an integer from 0 to 9007199254740991
      #|valid:
      #|eph-1
    ),
  )
}

///|
test "adding an Ephemeral Stub to a Mock that does not exist fails, naming the Mock, before the Stub is read" {
  let h = harness(shop)
  let error = try
    h.engine.add_ephemeral_stub(
      mock="orders",
      session=Some("test-a"),
      @json.parse("{ \"colour\": \"red\" }"),
    )
  catch {
    err => @debug.to_string(err)
  } noraise {
    stub => stub.id
  }
  inspect(
    error,
    content=(
      #|UnknownMock("orders")
    ),
  )
}

///|
/// Adds a `GET /health` Ephemeral Stub to `mock` for `session`: its ID, or
/// the error.
fn Harness::add_or_error(
  self : Harness,
  mock : String,
  session : String?,
) -> String {
  self.add(mock, session, get_stub("/health", 500, "down")) catch {
    err => @debug.to_string(err)
  }
}

///|
/// A Stub, without `id` and `mock`, that answers `GET path` after a delay
/// drawn uniformly from 0 to 1000 ms, with its own generator from `seed`
/// when it has one.
fn delayed(path : String, seed? : Int) -> String {
  let seed = match seed {
    Some(seed) => ", \"seed\": \{seed}"
    None => ""
  }
  "\"request\": { \"method\": \"GET\", \"path\": \"\{path}\" }, \"response\": { \"status\": 200 }, \"fault\": { \"delay\": { \"uniform\": { \"min\": 0, \"max\": 1000 } }\{seed} }"
}

///|
/// The delays of `n` requests for `GET http://users.svc<path>` with
/// `session`.
fn Harness::delays(
  self : Harness,
  path : String,
  n : Int,
  session? : String,
) -> String {
  let delays = []
  for _ in 0..<n {
    delays.push(
      self.send("GET", "http://users.svc\{path}", session?).plan.delay_ms,
    )
  }
  delays.map(d => d.to_string()).join(" ")
}

///|
test "an Ephemeral Stub with a seed gets its own generator when it is added: its delays are those a Definition file Stub with the seed gets" {
  // The oracle: a Stub from a Definition file with the same seed.
  let from_file = harness(
    [
      shop[0],
      (
        "10-users.json",
        "{ \"stubs\": [{ \"id\": \"slow\", \"mock\": \"users\", \{delayed("/slow", seed=42)} }] }",
      ),
    ],
    process_seed=1,
  )
  let expected = from_file.delays("/slow", 4)
  let h = harness(shop, process_seed=2)
  let _ = h.add("users", Some("test-a"), "{ \{delayed("/noise")} }")
  let _ = h.add("users", Some("test-a"), "{ \{delayed("/slow", seed=42)} }")
  let out = []
  // Requests to an Ephemeral Stub without a seed draw from the process
  // generator, in between.
  out.push("first: \{h.delays("/slow", 2, session="test-a")}")
  out.push("noise: \{h.delays("/noise", 3, session="test-a")}")
  out.push("then: \{h.delays("/slow", 2, session="test-a")}")
  // A reload that keeps the Mock keeps the generator where it is.
  let _ = h.engine.reload(
    {
      files: [
        ..shop,
        ("30-extra.json", "{ \"mocks\": [{ \"name\": \"extra\" }] }"),
      ].map(f => (f.0, @utf8.encode(f.1))),
      body_files: [],
    },
    at=fixed_now,
  )
  // Another Ephemeral Stub with the seed starts its own generator afresh.
  let _ = h.add("users", Some("test-b"), "{ \{delayed("/slow", seed=42)} }")
  out.push("test-b: \{h.delays("/slow", 2, session="test-b")}")
  inspect(
    "Definition file: \{expected}\n\{out.join("\n")}",
    content=(
      #|Definition file: 365 239 280 910
      #|first: 365 239
      #|noise: 924 428 776
      #|then: 280 910
      #|test-b: 365 239
    ),
  )
}

///|
test "the outcome names the Stub that matched and whether it comes from a Definition file or is an Ephemeral Stub, whatever its ID looks like" {
  let h = harness(
    [
      ..shop,
      (
        "30-refunds.json",
        (
          #|{ "stubs": [{ "id": "eph-1", "mock": "payments",
          #|    "request": { "method": "GET", "path": "/refunds" },
          #|    "response": { "status": 200, "body": "none" } }] }
        ),
      ),
    ],
  )
  let _ = h.add("payments", Some("test-a"), get_stub("/orders/42", 503, "down"))
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push("\{label}: \{@debug.to_string(outcome.matched)}")
  }
  step(
    "a Stub from a Definition file",
    h.send("GET", "http://payments.svc/orders/42"),
  )
  step(
    "an Ephemeral Stub",
    h.send("GET", "http://payments.svc/orders/42", session="test-a"),
  )
  step(
    "a Stub from a Definition file with the ID eph-1",
    h.send("GET", "http://payments.svc/refunds", session="test-a"),
  )
  step("no Stub", h.send("GET", "http://payments.svc/orders/43"))
  inspect(
    out.join("\n"),
    content=(
      #|a Stub from a Definition file: Some(FromFile("p-order"))
      #|an Ephemeral Stub: Some(Ephemeral("eph-1"))
      #|a Stub from a Definition file with the ID eph-1: Some(FromFile("eph-1"))
      #|no Stub: None
    ),
  )
}

///|
test "changing the JSON an Ephemeral Stub was added from changes no later match" {
  let h = harness(shop)
  let stub = @json.parse(
    (
      #|{ "request": { "method": "POST", "path": "/orders",
      #|    "body": { "json": { "item": "tea" } } },
      #|  "response": { "status": 201 } }
    ),
  )
  let added = h.engine.add_ephemeral_stub(mock="users", session=None, stub)
  // Both the JSON given and the JSON the Ephemeral Stub shows.
  for json in [stub, Json::object(added.added)] {
    guard json
      is Object(
        {
          "request": Object(
            { "body": Object({ "json": Object(item), .. }), .. }
          ),
          ..
        }
      ) else {
      fail("the Stub has no json condition")
    }
    item["item"] = Json::string("coffee")
  }
  debug_inspect(
    [
      matched_id(h.send("POST", "/orders", body="{\"item\": \"coffee\"}")),
      matched_id(h.send("POST", "/orders", body="{\"item\": \"tea\"}")),
    ],
    content="[None, Some(\"eph-1\")]",
  )
}
