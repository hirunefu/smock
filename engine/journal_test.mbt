// Seam 1 tests of the Journal: what an entry records, the bound by entry
// count and by bytes with the eviction counts per Session, Session
// isolation, the query filter, the Journal turned off, reset scopes and
// reloads. Entries come from requests the engine handles, and are committed
// as the server commits them.

///|
/// A Mock `users` for `users.example.com`, the Default Mock, with two Stubs.
let journal_users : String =
  #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"], "default": true }],
  #|  "stubs": [
  #|    { "id": "get-user", "mock": "users",
  #|      "request": { "method": "GET", "path": "/users/1" },
  #|      "response": { "status": 200, "body": "Alice" } },
  #|    { "id": "create-user", "mock": "users",
  #|      "request": { "method": "POST", "path": "/users",
  #|                   "headers": { "X-Api-Key": "secret" } },
  #|      "response": { "status": 201 } } ] }

///|
/// Sends a request, as `Harness::send` does, and commits its Journal entry,
/// if the engine returned one, then finishes it `duration_ms` later.
/// Returns whether there was an entry.
fn Harness::record(
  self : Harness,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
  session? : String,
  duration_ms? : Int64 = 1,
) -> Bool {
  let outcome = self.send(meth, target, headers~, body~, session?)
  guard outcome.journal is Some(entry) else { return false }
  self.engine.commit(entry)
  entry.finish(at=self.now + duration_ms)
  true
}

///|
/// Queries the Journal for `session` with the query given as JSON text, and
/// returns the page as JSON, or the error.
fn Harness::query(
  self : Harness,
  session : String?,
  query? : String = "{}",
) -> Json raise {
  let query = @engine.JournalQuery::from_json(@json.parse(query))
  ToJson::to_json(self.engine.query_journal(query, session~))
}

///|
test "a committed entry records the request, its Session, Host and Mock, the Stub that answered, the status, the timing and the definition set digest" {
  let h = harness([("users.json", journal_users)])
  let recorded = h.record(
    "GET",
    "/users/1?x=y",
    headers=[("Host", "Users.Example.com:8080"), ("Accept", "text/plain")],
    session="test-a",
    duration_ms=7,
  )
  inspect(recorded, content="true")
  let digest = h.engine.status().digest
  json_inspect(h.query(Some("test-a")), content={
    "entries": [
      {
        "seq": 1,
        "receivedAt": "2026-10-12T14:30:05.123Z",
        "durationMs": 7,
        "session": "test-a",
        "host": "users.example.com",
        "mock": "users",
        "viaDefault": false,
        "digest": Json::string(digest),
        "request": {
          "method": "GET",
          "target": "/users/1?x=y",
          "version": "HTTP/1.1",
          "headers": [
            { "name": "Host", "value": "Users.Example.com:8080" },
            { "name": "Accept", "value": "text/plain" },
          ],
          "body": {
            "encoding": "utf-8",
            "data": "",
            "size": 0,
            "truncated": false,
          },
        },
        "stub": "get-user",
        "stubSource": "file",
        "nearMiss": Json::null(),
        "status": 200,
        "fault": Json::null(),
        "templateError": Json::null(),
      },
    ],
    "more": false,
    "evicted": 0,
  })
}

///|
/// The entries a query for `session` returns, one per line, as the method,
/// the target and the Session, oldest first, then `more` and `evicted`.
fn Harness::listed(
  self : Harness,
  session : String?,
  query? : String = "{}",
) -> String raise {
  let page = self.engine.query_journal(
    @engine.JournalQuery::from_json(@json.parse(query)),
    session~,
  )
  let lines = page.entries.map(entry => {
    let session = entry.session.unwrap_or("no Session")
    "\{entry.request.meth} \{entry.request.target} (\{session})"
  })
  lines.push("more: \{page.more}, evicted: \{page.evicted}")
  lines.join("\n")
}

///|
test "a query returns only the calling Session's entries, oldest first; requests without a Session form their own space" {
  let h = harness([("users.json", journal_users)])
  let _ = h.record("GET", "/a/1", session="test-a")
  let _ = h.record("GET", "/b/1", session="test-b")
  let _ = h.record("GET", "/none/1")
  let _ = h.record("GET", "/a/2", session="test-a")
  let _ = h.record("GET", "/none/2")
  inspect(
    [
      h.listed(Some("test-a")),
      h.listed(Some("test-b")),
      h.listed(None),
      h.listed(Some("test-c")),
    ].join("\n--\n"),
    content=(
      #|GET /a/1 (test-a)
      #|GET /a/2 (test-a)
      #|more: false, evicted: 0
      #|--
      #|GET /b/1 (test-b)
      #|more: false, evicted: 0
      #|--
      #|GET /none/1 (no Session)
      #|GET /none/2 (no Session)
      #|more: false, evicted: 0
      #|--
      #|more: false, evicted: 0
    ),
  )
}

///|
test "an entry the server has not committed is not in the Journal" {
  let h = harness([("users.json", journal_users)])
  let outcome = h.send("GET", "/users/1", session="test-a")
  inspect(outcome.journal is Some(_), content="true")
  inspect(
    h.listed(Some("test-a")),
    content=(
      #|more: false, evicted: 0
    ),
  )
}

///|
test "a query returns at most limit entries, the oldest, and says when more passed" {
  let h = harness([("users.json", journal_users)])
  for i in 1..<=3 {
    let _ = h.record("GET", "/users/\{i}", session="test-a")
  }
  inspect(
    [
      h.listed(Some("test-a"), query="{ \"limit\": 2 }"),
      h.listed(Some("test-a"), query="{ \"limit\": 3 }"),
    ].join("\n--\n"),
    content=(
      #|GET /users/1 (test-a)
      #|GET /users/2 (test-a)
      #|more: true, evicted: 0
      #|--
      #|GET /users/1 (test-a)
      #|GET /users/2 (test-a)
      #|GET /users/3 (test-a)
      #|more: false, evicted: 0
    ),
  )
}

///|
/// What the Journal holds: its entries and bytes, and how many entries the
/// bound has evicted since the process started.
fn Harness::stats(self : Harness) -> String {
  let stats = self.engine.journal_stats()
  "\{stats.entries} entries, \{stats.bytes} bytes, \{stats.evictions} evicted"
}

///|
test "when the entry bound is reached, the oldest entries are evicted and each Session counts its own; the no-Session space has its own count" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=3),
  )
  let _ = h.record("GET", "/a/1", session="test-a")
  let _ = h.record("GET", "/b/1", session="test-b")
  let _ = h.record("GET", "/none/1")
  let _ = h.record("GET", "/a/2", session="test-a")
  let _ = h.record("GET", "/b/2", session="test-b")
  let _ = h.record("GET", "/none/2")
  let out = [
    h.listed(Some("test-a")),
    h.listed(Some("test-b")),
    h.listed(None),
    h.listed(Some("test-c")),
    h.stats(),
  ]
  for i in 3..<=5 {
    let _ = h.record("GET", "/a/\{i}", session="test-a")
  }
  out.push(h.listed(Some("test-a")))
  out.push(h.listed(Some("test-b")))
  out.push(h.listed(None))
  out.push(h.stats())
  inspect(
    out.join("\n--\n"),
    content=(
      #|GET /a/2 (test-a)
      #|more: false, evicted: 1
      #|--
      #|GET /b/2 (test-b)
      #|more: false, evicted: 1
      #|--
      #|GET /none/2 (no Session)
      #|more: false, evicted: 1
      #|--
      #|more: false, evicted: 0
      #|--
      #|3 entries, 996 bytes, 3 evicted
      #|--
      #|GET /a/3 (test-a)
      #|GET /a/4 (test-a)
      #|GET /a/5 (test-a)
      #|more: false, evicted: 2
      #|--
      #|more: false, evicted: 2
      #|--
      #|more: false, evicted: 2
      #|--
      #|3 entries, 996 bytes, 6 evicted
    ),
  )
}

///|
test "an entry counts 256 bytes, two for each UTF-16 code unit of its text and the bytes of its truncated body" {
  let h = harness([("users.json", journal_users)])
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[("Host", "users.example.com")],
    body="abc",
    session="s",
  )
  // GET, /users/1, HTTP/1.1, Host, users.example.com, the Session s, the
  // Host users.example.com, the Mock users and the Stub get-user hold 71
  // code units.
  inspect(h.stats(), content="1 entries, 401 bytes, 0 evicted")
}

///|
test "when the byte bound is reached, the oldest entries are evicted; an entry over the whole bound is evicted at once" {
  let body = "x".repeat(3000)
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_bytes=8000),
  )
  for i in 1..<=4 {
    let _ = h.record("POST", "/users/\{i}", body~, session="test-a")
  }
  let out = [h.listed(Some("test-a"))]
  let small = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_bytes=1000),
  )
  let _ = small.record("POST", "/users/1", body~, session="test-a")
  out.push(small.listed(Some("test-a")))
  out.push(small.stats())
  inspect(
    out.join("\n--\n"),
    content=(
      #|POST /users/3 (test-a)
      #|POST /users/4 (test-a)
      #|more: false, evicted: 2
      #|--
      #|more: false, evicted: 1
      #|--
      #|0 entries, 0 bytes, 1 evicted
    ),
  )
}

///|
test "an entry over the whole byte bound is evicted alone: the older entries, of any Session, stay" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_bytes=2000),
  )
  let _ = h.record("GET", "/users/1", session="test-a")
  let _ = h.record("GET", "/users/2", session="test-a")
  // The two entries take 332 and 348 bytes; the third, over 3000.
  let _ = h.record("POST", "/users/3", body="x".repeat(3000), session="test-b")
  inspect(
    [h.listed(Some("test-a")), h.listed(Some("test-b")), h.stats()].join(
      "\n--\n",
    ),
    content=(
      #|GET /users/1 (test-a)
      #|GET /users/2 (test-a)
      #|more: false, evicted: 0
      #|--
      #|more: false, evicted: 1
      #|--
      #|2 entries, 680 bytes, 1 evicted
    ),
  )
}

///|
test "a body over the body limit is truncated, at the start of a UTF-8 sequence it would split; a body that is not UTF-8 is shown in base64" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(body_limit=4),
  )
  let _ = h.record("POST", "/users", body="Hello, world", session="s")
  let _ = h.record("POST", "/users", body="abcé", session="s")
  let _ = h.record("POST", "/users", body="abc", session="s")
  let outcome = h.engine.handle(
    {
      meth: "POST",
      target: "/users",
      version: "HTTP/1.0",
      headers: [],
      body: b"\xff\xfe\x00\x01\x02",
    },
    session=Some("s"),
    now=h.now,
    rand=h.rand,
  )
  h.engine.commit(outcome.journal.unwrap())
  let lines = []
  guard h.query(Some("s")) is Object({ "entries": Array(entries), .. }) else {
    fail("no entries")
  }
  for entry in entries {
    guard entry
      is Object(
        { "request": Object({ "version": version, "body": body, .. }), .. }
      ) else {
      fail("no request")
    }
    lines.push("\{version.stringify()} \{body.stringify()}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|"HTTP/1.1" {"encoding":"utf-8","data":"Hell","size":12,"truncated":true}
      #|"HTTP/1.1" {"encoding":"utf-8","data":"abc","size":5,"truncated":true}
      #|"HTTP/1.1" {"encoding":"utf-8","data":"abc","size":3,"truncated":false}
      #|"HTTP/1.0" {"encoding":"base64","data":"//4AAQ==","size":5,"truncated":true}
    ),
  )
}

///|
/// The newest entry of `session` as JSON, with only the members that say
/// who answered and how: `host`, `mock`, `viaDefault`, `stub`, `nearMiss`,
/// `status` and `fault`.
fn Harness::answered(self : Harness, session : String?) -> Json raise {
  guard self.query(session, query="{ \"limit\": 10000 }")
    is Object({ "entries": Array(entries), .. }) &&
    entries.last() is Some(Object(entry)) else {
    fail("no entry")
  }
  let out = Map([])
  for
    name in [
      "host", "mock", "viaDefault", "stub", "nearMiss", "status", "fault",
    ] {
    out[name] = entry[name]
  }
  Json::object(out)
}

///|
/// Two Mocks for their own Hosts, without a Default Mock: `orders`, whose
/// Stub wants an API key and a JSON body, and `users`.
let journal_orders : String =
  #|{ "mocks": [
  #|    { "name": "orders", "hosts": ["orders.example.com"] },
  #|    { "name": "users", "hosts": ["users.example.com"] } ],
  #|  "stubs": [
  #|    { "id": "create-order", "mock": "orders",
  #|      "request": { "method": "POST", "path": "/orders",
  #|                   "headers": { "X-Api-Key": { "pattern": "k-[0-9]+" } },
  #|                   "body": { "json": { "item": "book" } } },
  #|      "response": { "status": 201 } } ] }

///|
test "an unmatched request's entry holds the Near miss with expected and actual values; the body's actual value is truncated like the body" {
  let h = harness(
    [("orders.json", journal_orders)],
    journal=@engine.JournalSettings(body_limit=8),
  )
  let _ = h.record(
    "POST",
    "/orders",
    headers=[("Host", "orders.example.com"), ("X-Api-Key", "nope")],
    body="{\"item\":\"pen\",\"n\":1}",
    session="s",
  )
  json_inspect(h.answered(Some("s")), content={
    "host": "orders.example.com",
    "mock": "orders",
    "viaDefault": false,
    "stub": Json::null(),
    "nearMiss": {
      "stub": "create-order",
      "stubSource": "file",
      "failed": [
        {
          "condition": "header:x-api-key",
          "expected": { "pattern": "k-[0-9]+" },
          "actual": ["nope"],
        },
        {
          "condition": "body",
          "expected": { "json": { "item": "book" } },
          "actual": ["{\"item\":"],
        },
      ],
    },
    "status": 404,
    "fault": Json::null(),
  })
}

///|
test "an entry says when the Default Mock answered because no Mock lists the Host" {
  let h = harness([("users.json", journal_users)])
  let _ = h.record("GET", "/users/1", headers=[("Host", "Usres.example.com")])
  json_inspect(h.answered(None), content={
    "host": "usres.example.com",
    "mock": "users",
    "viaDefault": true,
    "stub": "get-user",
    "nearMiss": Json::null(),
    "status": 200,
    "fault": Json::null(),
  })
}

///|
test "a request for an unknown Host, without a Default Mock, is recorded under its Session with no Mock" {
  let h = harness([("orders.json", journal_orders)])
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[("Host", "usres.example.com")],
    session="s",
  )
  let _ = h.record("GET", "/users/1", session="s")
  inspect(
    h.listed(Some("s")),
    content=(
      #|GET /users/1 (s)
      #|GET /users/1 (s)
      #|more: false, evicted: 0
    ),
  )
  json_inspect(h.answered(Some("s")), content={
    "host": Json::null(),
    "mock": Json::null(),
    "viaDefault": false,
    "stub": Json::null(),
    "nearMiss": Json::null(),
    "status": 404,
    "fault": Json::null(),
  })
}

///|
/// `users`, the Default Mock, and `orders`, each for its own Host.
let journal_shop : Array[(String, String)] = [
  ("users.json", journal_users),
  (
    "orders.json",
    (
      #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"] }] }
    ),
  ),
]

///|
test "the filter takes a Mock, a method, a path and headers with the semantics of Stub conditions, and a time range [since, until) on the receive time" {
  let h = harness(journal_shop)
  let users = ("Host", "users.example.com")
  // Received at 14:30:05.123, .133, .143 and .153.
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[users, ("X-Trace", "a")],
    session="s",
  )
  h.now += 10
  let _ = h.record(
    "POST",
    "/users",
    headers=[users, ("X-Api-Key", "secret")],
    session="s",
  )
  h.now += 10
  let _ = h.record(
    "GET",
    "http://orders.example.com/orders/7?x=1",
    headers=[("X-Trace", "b"), ("x-trace", "c")],
    session="s",
  )
  h.now += 10
  let _ = h.record("GET", "/users/a%20b", headers=[users], session="s")
  // Another Session's entry never passes.
  let _ = h.record("GET", "/users/1", headers=[users], session="other")
  let filters = [
    "{}", "{ \"mock\": \"orders\" }", "{ \"mock\": \"gone\" }", "{ \"method\": \"POST\" }",
    "{ \"path\": \"/users/1\" }", "{ \"path\": \"/users/a b\" }", "{ \"path\": \"/orders/7\" }",
    "{ \"path\": { \"pattern\": \"/users/.*\" } }", "{ \"headers\": { \"x-trace\": \"c\" } }",
    "{ \"headers\": { \"X-TRACE\": { \"pattern\": \"[ab]\" } } }", "{ \"headers\": { \"X-Trace\": \"a\", \"Host\": \"orders.example.com\" } }",
    "{ \"method\": \"GET\", \"mock\": \"users\" }", "{ \"since\": \"2026-10-12T14:30:05.133Z\" }",
    "{ \"until\": \"2026-10-12T14:30:05.143Z\" }", "{ \"since\": \"2026-10-12T16:30:05.133+02:00\", \"until\": \"2026-10-12T14:30:05.143Z\" }",
  ]
  let out = []
  for filter in filters {
    let page = h.engine.query_journal(
      @engine.JournalQuery::from_json(@json.parse("{ \"filter\": \{filter} }")),
      session=Some("s"),
    )
    let targets = page.entries.map(entry => {
      "\{entry.request.meth} \{entry.request.target}"
    })
    let listed = if targets.is_empty() { "none" } else { targets.join(", ") }
    out.push("\{filter} -> \{listed}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|{} -> GET /users/1, POST /users, GET http://orders.example.com/orders/7?x=1, GET /users/a%20b
      #|{ "mock": "orders" } -> GET http://orders.example.com/orders/7?x=1
      #|{ "mock": "gone" } -> none
      #|{ "method": "POST" } -> POST /users
      #|{ "path": "/users/1" } -> GET /users/1
      #|{ "path": "/users/a b" } -> GET /users/a%20b
      #|{ "path": "/orders/7" } -> GET http://orders.example.com/orders/7?x=1
      #|{ "path": { "pattern": "/users/.*" } } -> GET /users/1, GET /users/a%20b
      #|{ "headers": { "x-trace": "c" } } -> GET http://orders.example.com/orders/7?x=1
      #|{ "headers": { "X-TRACE": { "pattern": "[ab]" } } } -> GET /users/1, GET http://orders.example.com/orders/7?x=1
      #|{ "headers": { "X-Trace": "a", "Host": "orders.example.com" } } -> none
      #|{ "method": "GET", "mock": "users" } -> GET /users/1, GET /users/a%20b
      #|{ "since": "2026-10-12T14:30:05.133Z" } -> POST /users, GET http://orders.example.com/orders/7?x=1, GET /users/a%20b
      #|{ "until": "2026-10-12T14:30:05.143Z" } -> GET /users/1, POST /users
      #|{ "since": "2026-10-12T16:30:05.133+02:00", "until": "2026-10-12T14:30:05.143Z" } -> POST /users
    ),
  )
}

///|
test "a query or a filter that does not have the shape of the Admin API document is rejected with every problem and where it is" {
  let queries = [
    "[]", "{ \"filter\": 1 }", "{ \"filter\": { \"query\": { \"a\": \"b\" }, \"body\": \"x\" } }",
    "{ \"filter\": { \"mock\": \"\" } }", "{ \"filter\": { \"method\": \"G T\" } }",
    "{ \"filter\": { \"path\": \"users\" } }", "{ \"filter\": { \"path\": { \"pattern\": \"(\" } } }",
    "{ \"filter\": { \"headers\": { \"X-Id\": 1 } } }", "{ \"filter\": { \"since\": \"yesterday\", \"until\": 1 } }",
    "{ \"limit\": 0 }", "{ \"limit\": 1.5 }", "{ \"limit\": 10001 }", "{ \"extra\": 1 }",
    "{ \"filter\": { \"mock\": 1 }, \"limit\": \"10\" }",
  ]
  let out = []
  for query in queries {
    let result = try
      @engine.JournalQuery::from_json(@json.parse(query)) |> ignore |> Ok
    catch {
      err => Err(err)
    }
    match result {
      Ok(_) => out.push("\{query}: valid")
      Err(err) => {
        let message = match err {
          @engine.InvalidQuery(_) as err => err.message()
          err => "unexpected: \{err}"
        }
        out.push("\{query}:\n  \{message.replace_all(old="\n", new="\n  ")}")
      }
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|[]:
      #|  must be an object
      #|{ "filter": 1 }:
      #|  /filter: must be an object
      #|{ "filter": { "query": { "a": "b" }, "body": "x" } }:
      #|  /filter/query: is not a known field
      #|  /filter/body: is not a known field
      #|{ "filter": { "mock": "" } }:
      #|  /filter/mock: must be a non-empty string
      #|{ "filter": { "method": "G T" } }:
      #|  /filter/method: must be an HTTP token, such as GET
      #|{ "filter": { "path": "users" } }:
      #|  /filter/path: must start with /
      #|{ "filter": { "path": { "pattern": "(" } } }:
      #|  /filter/path/pattern: is not a valid pattern: position 0: missing closing )
      #|{ "filter": { "headers": { "X-Id": 1 } } }:
      #|  /filter/headers/X-Id: must be a string or an object
      #|{ "filter": { "since": "yesterday", "until": 1 } }:
      #|  /filter/since: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
      #|  /filter/until: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
      #|{ "limit": 0 }:
      #|  /limit: must be an integer from 1 to 10000
      #|{ "limit": 1.5 }:
      #|  /limit: must be an integer from 1 to 10000
      #|{ "limit": 10001 }:
      #|  /limit: must be an integer from 1 to 10000
      #|{ "extra": 1 }:
      #|  /extra: is not a known field
      #|{ "filter": { "mock": 1 }, "limit": "10" }:
      #|  /filter/mock: must be a non-empty string
      #|  /limit: must be an integer from 1 to 10000
    ),
  )
}

///|
/// The outcome of a query for `session`: the listed entries, or the error.
fn Harness::outcome(
  self : Harness,
  session : String?,
  query? : String = "{}",
) -> String raise {
  let parsed = @engine.JournalQuery::from_json(@json.parse(query))
  let _ = self.engine.query_journal(parsed, session~) catch {
    err => return "refused: \{@debug.to_string(err)}"
  }
  self.listed(session, query~).replace_all(old="\n", new="; ")
}

///|
test "a Mock whose journal is false is not recorded, and a query whose filter names it is refused; queries without it are not" {
  let h = harness([
    ("users.json", journal_users),
    (
      "orders.json",
      (
        #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"], "journal": false }] }
      ),
    ),
  ])
  let order = h.send("GET", "http://orders.example.com/orders/1", session="s")
  inspect(order.journal is None, content="true")
  inspect(order.plan.status, content="404")
  let _ = h.record("GET", "/users/1", session="s")
  inspect(
    [
      h.outcome(Some("s")),
      h.outcome(Some("s"), query="{ \"filter\": { \"mock\": \"orders\" } }"),
      h.outcome(Some("s"), query="{ \"filter\": { \"mock\": \"users\" } }"),
    ].join("\n"),
    content=(
      #|GET /users/1 (s); more: false, evicted: 0
      #|refused: JournalOff(Some("orders"))
      #|GET /users/1 (s); more: false, evicted: 0
    ),
  )
}

///|
test "with the Journal off globally, no request is recorded and every query is refused" {
  let h = harness(
    [("orders.json", journal_orders)],
    journal=@engine.JournalSettings(enabled=false),
  )
  let outcomes = [
    h.send("POST", "http://orders.example.com/orders", session="s"),
    h.send("GET", "http://unknown.example.com/", session="s"),
    h.send("GET", "/"),
  ]
  inspect(
    outcomes.map(outcome => (outcome.journal is None).to_string()).join(", "),
    content="true, true, true",
  )
  inspect(
    [
      h.outcome(Some("s")),
      h.outcome(None, query="{ \"filter\": { \"mock\": \"users\" } }"),
      h.stats(),
    ].join("\n"),
    content=(
      #|refused: JournalOff(None)
      #|refused: JournalOff(None)
      #|0 entries, 0 bytes, 0 evicted
    ),
  )
}

///|
/// Resets `scope`, as what it removed, or the error.
fn Harness::reset_journal(self : Harness, scope : @engine.ResetScope) -> String {
  let removed = self.engine.reset(scope) catch {
    err => return @debug.to_string(err)
  }
  "removed \{removed.ephemeral_stubs} Ephemeral Stubs, \{removed.journal_entries} entries"
}

///|
test "reset clears the calling Session's entries and eviction count across all Mocks, one Mock's entries for every Session, or the whole Journal and every eviction count" {
  let h = harness(journal_shop, journal=@engine.JournalSettings(max_entries=6))
  let users = "http://users.example.com/users/1"
  let orders = "http://orders.example.com/orders/1"
  // The bound evicts these first two.
  let _ = h.record("GET", users, session="test-a")
  let _ = h.record("GET", users, session="test-b")
  for session in [Some("test-a"), Some("test-b"), None] {
    let _ = h.record("GET", users, session?)
    let _ = h.record("GET", orders, session?)
  }
  let listed = (session : String?) => {
    h.listed(session).replace_all(old="\n", new="; ")
  }
  let out = [
    "test-a: \{listed(Some("test-a"))}",
    "test-b: \{listed(Some("test-b"))}",
    "reset Session test-a: \{h.reset_journal(Session(Some("test-a")))}",
    "test-a: \{listed(Some("test-a"))}",
    "test-b: \{listed(Some("test-b"))}",
    "reset Mock orders: \{h.reset_journal(Mock("orders"))}",
    "test-b: \{listed(Some("test-b"))}",
    "no Session: \{listed(None)}",
    "reset no Session: \{h.reset_journal(Session(None))}",
    "no Session: \{listed(None)}",
    "reset all: \{h.reset_journal(All)}",
    "test-b: \{listed(Some("test-b"))}",
    h.stats(),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|test-a: GET http://users.example.com/users/1 (test-a); GET http://orders.example.com/orders/1 (test-a); more: false, evicted: 1
      #|test-b: GET http://users.example.com/users/1 (test-b); GET http://orders.example.com/orders/1 (test-b); more: false, evicted: 1
      #|reset Session test-a: removed 0 Ephemeral Stubs, 2 entries
      #|test-a: more: false, evicted: 0
      #|test-b: GET http://users.example.com/users/1 (test-b); GET http://orders.example.com/orders/1 (test-b); more: false, evicted: 1
      #|reset Mock orders: removed 0 Ephemeral Stubs, 2 entries
      #|test-b: GET http://users.example.com/users/1 (test-b); more: false, evicted: 1
      #|no Session: GET http://users.example.com/users/1 (no Session); more: false, evicted: 0
      #|reset no Session: removed 0 Ephemeral Stubs, 1 entries
      #|no Session: more: false, evicted: 0
      #|reset all: removed 0 Ephemeral Stubs, 1 entries
      #|test-b: more: false, evicted: 0
      #|0 entries, 0 bytes, 2 evicted
    ),
  )
}

///|
test "the Journal survives a reload, each entry keeping the digest of the definition set that served it; a Mock's journal follows the definitions served" {
  let h = harness(journal_shop, journal=@engine.JournalSettings(max_entries=3))
  let users = "http://users.example.com/users/1"
  let orders = "http://orders.example.com/orders/1"
  let first = h.engine.status().digest
  // The bound evicts the first two, one before the reload and one after,
  // so that the eviction count shows that it survives too.
  let _ = h.record("GET", users, session="s")
  let _ = h.record("GET", users, session="s")
  let _ = h.record("GET", orders, session="s")
  let _ = h.record("GET", users, session="s")
  // The new set turns the Journal of orders off.
  let _ = h.reload([
    ("users.json", journal_users),
    (
      "orders.json",
      (
        #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"], "journal": false }] }
      ),
    ),
  ])
  let second = h.engine.status().digest
  let recorded_orders = h.record("GET", orders, session="s")
  let _ = h.record("GET", users, session="s")
  let digests = (query : String) => {
    let page = h.engine.query_journal(
      @engine.JournalQuery::from_json(@json.parse(query)),
      session=Some("s"),
    )
    page.entries
    .map(entry => {
      let digest = if entry.digest == first {
        "first"
      } else if entry.digest == second {
        "second"
      } else {
        entry.digest
      }
      "\{entry.mock.unwrap_or("-")} served by the \{digest} set"
    })
    .join(", ") +
    "; evicted: \{page.evicted}"
  }
  let out = [
    "a request for orders is recorded after the reload: \{recorded_orders}",
    digests("{}"),
    h.outcome(Some("s"), query="{ \"filter\": { \"mock\": \"orders\" } }"),
  ]
  // The next set declares no orders: its entries can still be queried.
  let _ = h.reload([("users.json", journal_users)])
  out.push(digests("{ \"filter\": { \"mock\": \"orders\" } }"))
  inspect(
    out.join("\n"),
    content=(
      #|a request for orders is recorded after the reload: false
      #|orders served by the first set, users served by the first set, users served by the second set; evicted: 2
      #|refused: JournalOff(Some("orders"))
      #|orders served by the first set; evicted: 2
    ),
  )
}

///|
test "a Mock-scope reset clears the entries of a Mock a reload removed; a name that neither the definitions nor the Journal knows is an unknown Mock" {
  let h = harness(journal_shop)
  let _ = h.record("GET", "http://orders.example.com/orders/1", session="s")
  let _ = h.record("GET", "http://users.example.com/users/1", session="s")
  let _ = h.reload([("users.json", journal_users)])
  let orders = "{ \"filter\": { \"mock\": \"orders\" } }"
  let out = [
    "orders: \{h.outcome(Some("s"), query=orders)}",
    "reset Mock orders: \{h.reset_journal(Mock("orders"))}",
    "orders: \{h.outcome(Some("s"), query=orders)}",
    "reset Mock orders again: \{h.reset_journal(Mock("orders"))}",
    "reset Mock payments: \{h.reset_journal(Mock("payments"))}",
    h.stats(),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|orders: GET http://orders.example.com/orders/1 (s); more: false, evicted: 0
      #|reset Mock orders: removed 0 Ephemeral Stubs, 1 entries
      #|orders: more: false, evicted: 0
      #|reset Mock orders again: UnknownMock("orders")
      #|reset Mock payments: UnknownMock("payments")
      #|1 entries, 404 bytes, 0 evicted
    ),
  )
}

///|
test "an entry records the connection Fault injected; one that resets or closes the connection before a status has none" {
  let h = harness([
    (
      "faults.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "reset", "mock": "m", "request": { "path": "/reset" },
        #|      "fault": { "connection": { "kind": "reset" } },
        #|      "response": { "status": 200 } },
        #|    { "id": "close", "mock": "m", "request": { "path": "/close" },
        #|      "fault": { "connection": { "kind": "close" } },
        #|      "response": { "status": 200 } },
        #|    { "id": "partial", "mock": "m", "request": { "path": "/partial" },
        #|      "fault": { "connection": { "kind": "partial" } },
        #|      "response": { "status": 200, "body": "abcd" } } ] }
      ),
    ),
  ])
  let _ = h.record("GET", "/reset", session="s")
  let reset = h.answered(Some("s"))
  let _ = h.record("GET", "/close", session="s")
  let closed = h.answered(Some("s"))
  let _ = h.record("GET", "/partial", session="s")
  let partial = h.answered(Some("s"))
  json_inspect([reset, closed, partial], content=[
    {
      "host": Json::null(),
      "mock": "m",
      "viaDefault": true,
      "stub": "reset",
      "nearMiss": Json::null(),
      "status": Json::null(),
      "fault": "reset",
    },
    {
      "host": Json::null(),
      "mock": "m",
      "viaDefault": true,
      "stub": "close",
      "nearMiss": Json::null(),
      "status": Json::null(),
      "fault": "close",
    },
    {
      "host": Json::null(),
      "mock": "m",
      "viaDefault": true,
      "stub": "partial",
      "nearMiss": Json::null(),
      "status": 200,
      "fault": "partial",
    },
  ])
}

///|
test "an entry and its Near miss say whether the Stub comes from a Definition file or is an Ephemeral Stub, whatever its ID" {
  let h = harness([
    (
      "payments.json",
      (
        #|{ "mocks": [{ "name": "payments", "hosts": ["payments.svc"] }],
        #|  "stubs": [{ "id": "eph-1", "mock": "payments",
        #|    "request": { "method": "GET", "path": "/refunds" },
        #|    "response": { "status": 200, "body": "none" } }] }
      ),
    ),
  ])
  let added = h.add("payments", Some("s"), get_stub("/orders/42", 503, "down"))
  inspect(added, content="eph-1")
  for
    request in [
      ("GET", "/refunds"),
      ("GET", "/orders/42"),
      ("GET", "/orders/43"),
      ("POST", "/refunds"),
    ] {
    let _ = h.record(request.0, "http://payments.svc\{request.1}", session="s")
  }
  guard h.query(Some("s")) is Object({ "entries": Array(entries), .. }) else {
    fail("no entries")
  }
  // Each entry's target, Stub and Stub source, and its Near miss's.
  let pick = (json : Json, names : Array[String]) => {
    guard json is Object(members) else { return json }
    let out = Map([])
    for name in names {
      out[name] = members.get(name).unwrap_or("missing")
    }
    Json::object(out)
  }
  json_inspect(
    Json::array(
      entries.map(entry => {
        guard entry
          is Object(
            {
              "request": Object({ "target": target, .. }),
              "nearMiss": near_miss,
              ..
            } as members
          ) else {
          return entry
        }
        {
          "target": target,
          "stub": members["stub"],
          "stubSource": members.get("stubSource").unwrap_or("missing"),
          "nearMiss": pick(near_miss, ["stub", "stubSource"]),
        }
      }),
    ),
    content=[
      {
        "target": "http://payments.svc/refunds",
        "stub": "eph-1",
        "stubSource": "file",
        "nearMiss": Json::null(),
      },
      {
        "target": "http://payments.svc/orders/42",
        "stub": "eph-1",
        "stubSource": "ephemeral",
        "nearMiss": Json::null(),
      },
      {
        "target": "http://payments.svc/orders/43",
        "stub": Json::null(),
        "stubSource": Json::null(),
        "nearMiss": { "stub": "eph-1", "stubSource": "ephemeral" },
      },
      {
        "target": "http://payments.svc/refunds",
        "stub": Json::null(),
        "stubSource": Json::null(),
        "nearMiss": { "stub": "eph-1", "stubSource": "file" },
      },
    ],
  )
}

///|
/// Pages through `fetch` from the start, each page after the last entry of
/// the page before, until `more` is false, and renders each page as its
/// entries' sequence numbers and targets, then `more`.
fn paged(fetch : (Int64?) -> Json raise) -> String raise {
  let pages = []
  let mut after : Int64? = None
  for _ in 0..<10 {
    guard fetch(after)
      is Object({ "entries": Array(entries), "more": more, .. }) else {
      fail("not a Journal page")
    }
    let lines = []
    for entry in entries {
      guard entry
        is Object(
          {
            "seq": Number(seq, ..),
            "request": Object({ "target": String(target), .. }),
            ..
          }
        ) else {
        fail("an entry without a sequence number: \{entry.stringify()}")
      }
      lines.push("\{seq.to_int64()} \{target}")
      after = Some(seq.to_int64())
    }
    lines.push("more: \{more.stringify()}")
    pages.push(lines.join("\n"))
    if more is False {
      break
    }
  }
  pages.join("\n--\n")
}

///|
test "each entry has a sequence number, and a query or the unmatched list pages after the last one it returned, losing and repeating none, even within one millisecond" {
  let h = harness([("users.json", journal_users)])
  // Every request is received in the same millisecond; one of another
  // Session comes between them.
  let _ = h.record("GET", "/users/1", session="s")
  let _ = h.record("GET", "/users/1", session="other")
  let _ = h.record("GET", "/a", session="s")
  let _ = h.record("GET", "/users/1?x=2", session="s")
  let _ = h.record("GET", "/b", session="s")
  let _ = h.record("GET", "/users/1?x=3", session="s")
  let query = (after : Int64?) => {
    let after = after.map_or("", after => ", \"after\": \{after}")
    h.query(Some("s"), query="{ \"limit\": 2\{after} }")
  }
  let unmatched = fn(after : Int64?) -> Json raise {
    ToJson::to_json(h.engine.unmatched(session=Some("s"), limit=1, after?))
  }
  inspect(
    "query:\n\{paged(query)}\nunmatched:\n\{paged(unmatched)}",
    content=(
      #|query:
      #|1 /users/1
      #|3 /a
      #|more: true
      #|--
      #|4 /users/1?x=2
      #|5 /b
      #|more: true
      #|--
      #|6 /users/1?x=3
      #|more: false
      #|unmatched:
      #|3 /a
      #|more: true
      #|--
      #|5 /b
      #|more: false
    ),
  )
  let read = fn(query : String) -> Int64? raise @engine.InvalidQuery {
    let json = @json.parse(query) catch { _ => abort("not JSON") }
    @engine.JournalQuery::from_json(json).after
  }
  inspect(
    [
      "{ \"after\": 0 }", "{ \"after\": 9007199254740991 }", "{ \"after\": -1 }",
      "{ \"after\": 1.5 }", "{ \"after\": \"3\" }",
    ]
    .map(query => {
      let read = @debug.to_string(read(query)) catch { err => err.message() }
      "\{query}: \{read}"
    })
    .join("\n"),
    content=(
      #|{ "after": 0 }: Some(0)
      #|{ "after": 9007199254740991 }: Some(9007199254740991)
      #|{ "after": -1 }: /after: must be an integer from 0 to 9007199254740991
      #|{ "after": 1.5 }: /after: must be an integer from 0 to 9007199254740991
      #|{ "after": "3" }: /after: must be an integer from 0 to 9007199254740991
    ),
  )
}
