// Seam 1 tests of the unmatched requests: the calling Session's Journal
// entries that no Stub answered, each with its full Near miss.

///|
/// Two Mocks for their own Hosts, without a Default Mock: `orders`, with a
/// Stub that wants a query parameter, an API key and a JSON body, and one
/// for a pattern of paths; and `users`, without Stubs.
let unmatched_orders : String =
  #|{ "mocks": [
  #|    { "name": "orders", "hosts": ["orders.example.com"] },
  #|    { "name": "users", "hosts": ["users.example.com"] } ],
  #|  "stubs": [
  #|    { "id": "create-order", "mock": "orders",
  #|      "request": { "method": "POST", "path": "/orders",
  #|                   "query": { "dry": "no" },
  #|                   "headers": { "X-Api-Key": { "pattern": "k-[0-9]+" } },
  #|                   "body": { "json": { "item": "book" } } },
  #|      "response": { "status": 201 } },
  #|    { "id": "get-order", "mock": "orders",
  #|      "request": { "method": "GET", "path": { "pattern": "/orders/[0-9]+" } },
  #|      "response": { "status": 200 } } ] }

///|
/// The unmatched requests of `session` as JSON, each entry with only the
/// members that say what was sent and why nothing answered it: the request
/// line, `host`, `mock`, `stub`, `nearMiss` and `status`. Or the error.
fn Harness::unmatched(
  self : Harness,
  session : String?,
  limit? : Int,
) -> Json raise {
  let page = self.engine.unmatched(session~, limit?) catch {
    err => return Json::string("refused: \{@debug.to_string(err)}")
  }
  guard ToJson::to_json(page) is Object(members) &&
    members.get("entries") is Some(Array(entries)) else {
    fail("a Journal page is an object with entries")
  }
  let shown = entries.map(entry => {
    guard entry is Object(entry) else { fail("an entry is an object") }
    let request = entry["request"]
    guard request
      is Object({ "method": String(meth), "target": String(target), .. }) else {
      fail("an entry has a request")
    }
    let out : Map[String, Json] = {
      "request": Json::string("\{meth} \{target}"),
    }
    for name in ["host", "mock", "stub", "nearMiss", "status"] {
      out[name] = entry[name]
    }
    Json::object(out)
  })
  members["entries"] = Json::array(shown)
  Json::object(members)
}

///|
test "the unmatched requests are the calling Session's entries that no Stub answered, oldest first, each with its full Near miss; an unknown Host has no Mock and no Near miss" {
  let h = harness([("orders.json", unmatched_orders)])
  let orders = ("Host", "orders.example.com")
  let _ = h.record(
    "POST",
    "/orders?dry=yes",
    headers=[orders, ("X-Api-Key", "k-1")],
    body="{\"item\":\"pen\"}",
    session="s",
  )
  // Answered by a Stub from a Definition file: not listed.
  let _ = h.record("GET", "/orders/7", headers=[orders], session="s")
  let _ = h.record("GET", "/orders/abc", headers=[orders], session="s")
  // Answered by one of the Session's Ephemeral Stubs: not listed.
  let _ = h.engine.add_ephemeral_stub(
    mock="orders",
    session=Some("s"),
    @json.parse(
      "{ \"request\": { \"method\": \"DELETE\", \"path\": \"/orders/7\" }, \"response\": { \"status\": 204 } }",
    ),
  )
  let _ = h.record("DELETE", "/orders/7", headers=[orders], session="s")
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[("Host", "users.example.com")],
    session="s",
  )
  let _ = h.record(
    "GET",
    "/x",
    headers=[("Host", "nowhere.example.com")],
    session="s",
  )
  // Other Sessions' unmatched requests: not listed.
  let _ = h.record("GET", "/orders/abc", headers=[orders], session="other")
  let _ = h.record("GET", "/orders/none", headers=[orders])
  json_inspect(h.unmatched(Some("s")), content={
    "entries": [
      {
        "request": "POST /orders?dry=yes",
        "host": "orders.example.com",
        "mock": "orders",
        "stub": Json::null(),
        "nearMiss": {
          "stub": "create-order",
          "failed": [
            { "condition": "query:dry", "expected": "no", "actual": ["yes"] },
            {
              "condition": "body",
              "expected": { "json": { "item": "book" } },
              "actual": ["{\"item\":\"pen\"}"],
            },
          ],
        },
        "status": 404,
      },
      {
        "request": "GET /orders/abc",
        "host": "orders.example.com",
        "mock": "orders",
        "stub": Json::null(),
        "nearMiss": {
          "stub": "get-order",
          "failed": [
            {
              "condition": "path",
              "expected": { "pattern": "/orders/[0-9]+" },
              "actual": ["/orders/abc"],
            },
          ],
        },
        "status": 404,
      },
      {
        "request": "GET /users/1",
        "host": "users.example.com",
        "mock": "users",
        "stub": Json::null(),
        "nearMiss": Json::null(),
        "status": 404,
      },
      {
        "request": "GET /x",
        "host": "nowhere.example.com",
        "mock": Json::null(),
        "stub": Json::null(),
        "nearMiss": Json::null(),
        "status": 404,
      },
    ],
    "more": false,
    "evicted": 0,
  })
}

///|
/// The unmatched requests of `session`, one per line, as the method and
/// the target, then `more` and `evicted`; or the error.
fn Harness::unmatched_listed(
  self : Harness,
  session : String?,
  limit? : Int,
) -> String raise {
  match self.unmatched(session, limit?) {
    Object({ "entries": Array(entries), "more": more, "evicted": evicted, .. }) => {
      let lines = entries.map(entry => {
        guard entry is Object({ "request": String(request), .. }) else {
          fail("an entry has a request")
        }
        request
      })
      lines.push("more: \{more.stringify()}, evicted: \{evicted.stringify()}")
      lines.join("\n")
    }
    other => other.stringify()
  }
}

///|
test "the unmatched requests come at most limit at a time, the oldest first, with the calling Session's eviction count" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=4),
  )
  // The bound evicts the first, which a Stub answered: it still counts.
  let _ = h.record("GET", "/users/1", session="s")
  for i in 1..<=4 {
    let _ = h.record("GET", "/nope/\{i}", session="s")
  }
  inspect(
    [
      h.unmatched_listed(Some("s"), limit=2),
      h.unmatched_listed(Some("s"), limit=4),
      h.unmatched_listed(Some("s")),
      h.unmatched_listed(None),
    ].join("\n--\n"),
    content=(
      #|GET /nope/1
      #|GET /nope/2
      #|more: true, evicted: 1
      #|--
      #|GET /nope/1
      #|GET /nope/2
      #|GET /nope/3
      #|GET /nope/4
      #|more: false, evicted: 1
      #|--
      #|GET /nope/1
      #|GET /nope/2
      #|GET /nope/3
      #|GET /nope/4
      #|more: false, evicted: 1
      #|--
      #|more: false, evicted: 0
    ),
  )
}

///|
test "while the Journal is off globally, the unmatched requests are refused; a Mock whose journal is false only goes unrecorded" {
  let shop = [
    ("orders.json", unmatched_orders),
    (
      "billing.json",
      (
        #|{ "mocks": [{ "name": "billing", "hosts": ["billing.example.com"], "journal": false }] }
      ),
    ),
  ]
  let h = harness(shop)
  let _ = h.record(
    "GET",
    "/invoices/1",
    headers=[("Host", "billing.example.com")],
    session="s",
  )
  let _ = h.record(
    "GET",
    "/orders/abc",
    headers=[("Host", "orders.example.com")],
    session="s",
  )
  let off = harness(shop, journal=@engine.JournalSettings(enabled=false))
  let _ = off.record(
    "GET",
    "/orders/abc",
    headers=[("Host", "orders.example.com")],
    session="s",
  )
  inspect(
    [h.unmatched_listed(Some("s")), off.unmatched_listed(Some("s"))].join(
      "\n--\n",
    ),
    content=(
      #|GET /orders/abc
      #|more: false, evicted: 0
      #|--
      #|"refused: JournalOff(None)"
    ),
  )
}
