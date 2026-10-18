// Seam 1 tests of the Near miss: when no Stub matches, the engine names the
// candidate Stub that failed the fewest conditions, in a short response
// header and in a full explanation.

///|
test "an unmatched request gets the Smock-Near-Miss header, naming the closest Stub and the conditions it failed" {
  let h = stubs([
    (
      #|{ "id": "get-user", "mock": "m",
      #|  "request": { "method": "GET", "path": "/users/1" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    response(h.send("POST", "/users/1")),
    content=(
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: get-user; failed=method
      #|Smock-Mock: m; via=default
      #|{"error":"no Stub matched"}
    ),
  )
}

///|
/// The `Smock-Near-Miss` header of each request's response, or `none`, one
/// per line, after the request. Fails the test when the header and the
/// engine's Near miss disagree on whether there is one.
fn near_misses(
  h : Harness,
  requests : Array[(String, String, Array[(String, String)], String)],
) -> String raise {
  let lines = []
  for r in requests {
    let (meth, target, headers, body) = r
    let outcome = h.send(meth, target, headers~, body~)
    let header = outcome.plan.headers
      .iter()
      .filter(h => h.0 == "Smock-Near-Miss")
      .map(h => h.1)
      .collect()
    let shown = match (header, outcome.near_miss) {
      ([], None) => "none"
      ([value], Some(_)) => value
      _ => fail("the header and the Near miss disagree: \{header.join(", ")}")
    }
    let shown_headers = headers.map(h => " [\{h.0}: \{h.1}]").join("")
    let shown_body = if body == "" { "" } else { " \{body.escape()}" }
    lines.push("\{meth} \{target}\{shown_headers}\{shown_body} -> \{shown}")
  }
  lines.join("\n")
}

///|
test "a request that matches gets no Near miss and no Smock-Near-Miss header" {
  let h = stubs([
    (
      #|{ "id": "get-user", "mock": "m",
      #|  "request": { "method": "GET", "path": "/users/1" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "any", "mock": "m", "response": { "status": 200 } }
    ),
  ])
  let outcome = h.send("POST", "/users/1")
  debug_inspect(matched_id(outcome), content="Some(\"any\")")
  inspect(
    near_misses(h, [("GET", "/users/1", [], ""), ("POST", "/users/1", [], "")]),
    content=(
      #|GET /users/1 -> none
      #|POST /users/1 -> none
    ),
  )
}

///|
test "method, path, each listed query parameter, each listed header and body each count as one condition" {
  let h = stubs([
    (
      #|{ "id": "all", "mock": "m",
      #|  "request": { "method": "POST", "path": "/orders",
      #|    "query": { "dry": "yes", "page": { "pattern": "[0-9]+" } },
      #|    "headers": { "X-Tenant": "acme", "Content-Type": "application/json" },
      #|    "body": { "json": { "item": "tea" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    near_misses(h, [
      ("GET", "/", [], ""),
      ("GET", "/orders?dry=yes&page=1", [], ""),
      (
        "POST",
        "/orders?dry=no&page=x&page=y",
        [("X-Tenant", "acme"), ("x-tenant", "other")],
        "{\"item\": \"tea\"}",
      ),
      (
        "POST",
        "/orders?dry=yes&page=2",
        [("X-Tenant", "acme"), ("Content-Type", "application/json")],
        "{\"item\": \"coffee\"}",
      ),
    ]),
    content=(
      #|GET / -> all; failed=method,path,query:dry,query:page,header:x-tenant,header:content-type,body
      #|GET /orders?dry=yes&page=1 -> all; failed=method,header:x-tenant,header:content-type,body
      #|POST /orders?dry=no&page=x&page=y [X-Tenant: acme] [x-tenant: other] "{\"item\": \"tea\"}" -> all; failed=query:dry,query:page,header:content-type
      #|POST /orders?dry=yes&page=2 [X-Tenant: acme] [Content-Type: application/json] "{\"item\": \"coffee\"}" -> all; failed=body
    ),
  )
}

///|
test "the Near miss is the candidate with the fewest failed conditions, and the earlier one in matching order on a tie" {
  let h = stubs([
    (
      #|{ "id": "a-get-users", "mock": "m",
      #|  "request": { "method": "GET", "path": "/users", "headers": { "X-A": "1" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "b-post-orders", "mock": "m",
      #|  "request": { "method": "POST", "path": "/orders" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "c-put-orders", "mock": "m", "priority": 5,
      #|  "request": { "method": "PUT", "path": "/orders" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    near_misses(h, [
      // c-put-orders comes first in matching order, by its priority.
      ("GET", "/orders", [], ""),
      ("GET", "/users", [], ""),
      ("POST", "/users", [], ""),
      ("POST", "/users", [("X-A", "1")], ""),
      ("DELETE", "/users", [], ""),
      ("DELETE", "/x", [], ""),
    ]),
    content=(
      #|GET /orders -> c-put-orders; failed=method
      #|GET /users -> a-get-users; failed=header:x-a
      #|POST /users -> b-post-orders; failed=path
      #|POST /users [X-A: 1] -> a-get-users; failed=method
      #|DELETE /users -> c-put-orders; failed=method,path
      #|DELETE /x -> c-put-orders; failed=method,path
    ),
  )
}

///|
test "there is no Near miss and no Smock-Near-Miss header when there is no candidate Stub" {
  let empty = harness([
    ("empty.json", "{ \"mocks\": [{ \"name\": \"empty\" }] }"),
  ])
  let no_files = harness([])
  let by_host = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  let unknown = by_host.send("GET", "/y", headers=[
    ("Host", "unknown.example.com"),
  ])
  debug_inspect(unknown.resolution, content="NoMock")
  inspect(
    [
      near_misses(empty, [("GET", "/x", [], "")]),
      near_misses(no_files, [("GET", "/x", [], "")]),
      near_misses(by_host, [
        ("GET", "/y", [("Host", "users.example.com")], ""),
        ("GET", "/y", [("Host", "unknown.example.com")], ""),
      ]),
    ].join("\n"),
    content=(
      #|GET /x -> none
      #|GET /x -> none
      #|GET /y [Host: users.example.com] -> users-x; failed=path
      #|GET /y [Host: unknown.example.com] -> none
    ),
  )
}

///|
test "the Smock-Near-Miss header is ASCII only and carries no expected or actual value, whatever the names and values" {
  let h = stubs([
    (
      #|{ "id": "café; failed=x,y\r\nSet-Cookie: a=b", "mock": "m",
      #|  "request": { "method": "PUT", "path": "/menü",
      #|    "query": { "naïve; q=1,2": "Zoë", "%41": "x" },
      #|    "headers": { "X-%": "ü" },
      #|    "body": "thé" },
      #|  "response": { "status": 200 } }
    ),
  ])
  let outcome = h.send(
    "POST",
    "/men%C3%BC?na%C3%AFve%3B+q%3D1%2C2=Zo%C3%AB%21&A=x",
    headers=[("X-%", "ü!")],
    body="thé!",
  )
  let header = outcome.plan.headers
    .iter()
    .filter(h => h.0 == "Smock-Near-Miss")
    .map(h => h.1)
    .collect()
  inspect(
    header.join("\n"),
    content="caf%C3%A9%3B%20failed%3Dx%2Cy%0D%0ASet-Cookie%3A%20a%3Db; failed=method,query:na%C3%AFve%3B%20q%3D1%2C2,query:%2541,header:x-%25,body",
  )
  debug_inspect(
    header.iter().all(value => value.iter().all(c => c >= ' ' && c <= '~')),
    content="true",
  )
}

///|
/// The engine's Near miss for a request, in its JSON form. Fails the test
/// when there is none.
fn explanation(
  h : Harness,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> Json raise {
  guard h.send(meth, target, headers~, body~).near_miss is Some(near_miss) else {
    fail("no Near miss")
  }
  near_miss.to_json()
}

///|
test "the Near miss explains each failed method, path, query and header condition: exact or pattern, with the actual values or none" {
  let exact = stubs([
    (
      #|{ "id": "exact", "mock": "m",
      #|  "request": { "method": "PUT", "path": "/users/1",
      #|    "query": { "page": "2", "sort": "name", "dry run": "yes" },
      #|    "headers": { "X-Tenant": "acme", "Accept": "text/plain" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let patterns = stubs([
    (
      #|{ "id": "patterns", "mock": "m",
      #|  "request": { "path": { "pattern": "/orders/[0-9]+" },
      #|    "query": { "page": { "pattern": "[0-9]+" }, "q": { "pattern": "a.*" } },
      #|    "headers": { "X-Tenant": { "pattern": "[a-z]+" }, "Accept": { "pattern": "text/.*" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  // The path, a repeated parameter and a repeated header carry their
  // decoded values; an absent parameter or header carries none.
  json_inspect(
    explanation(exact, "GET", "/users/%31%30?page=1&page=3&dry+run=no", headers=[
      ("x-tenant", "beta"),
      ("X-TENANT", "gamma"),
    ]),
    content={
      "stub": "exact",
      "stubSource": "file",
      "failed": [
        { "condition": "method", "expected": "PUT", "actual": ["GET"] },
        { "condition": "path", "expected": "/users/1", "actual": ["/users/10"] },
        { "condition": "query:page", "expected": "2", "actual": ["1", "3"] },
        { "condition": "query:sort", "expected": "name", "actual": [] },
        { "condition": "query:dry run", "expected": "yes", "actual": ["no"] },
        {
          "condition": "header:x-tenant",
          "expected": "acme",
          "actual": ["beta", "gamma"],
        },
        { "condition": "header:accept", "expected": "text/plain", "actual": [] },
      ],
    },
  )
  json_inspect(
    explanation(patterns, "PUT", "/orders/x%2F1?page=one&q=b&q=c", headers=[
      ("Accept", "image/png"),
      ("X-Tenant", "ACME"),
    ]),
    content={
      "stub": "patterns",
      "stubSource": "file",
      "failed": [
        {
          "condition": "path",
          "expected": { "pattern": "/orders/[0-9]+" },
          "actual": ["/orders/x/1"],
        },
        {
          "condition": "query:page",
          "expected": { "pattern": "[0-9]+" },
          "actual": ["one"],
        },
        {
          "condition": "query:q",
          "expected": { "pattern": "a.*" },
          "actual": ["b", "c"],
        },
        {
          "condition": "header:x-tenant",
          "expected": { "pattern": "[a-z]+" },
          "actual": ["ACME"],
        },
        {
          "condition": "header:accept",
          "expected": { "pattern": "text/.*" },
          "actual": ["image/png"],
        },
      ],
    },
  )
}

///|
test "the Near miss explains a failed body condition: exact, pattern or json, with the body as sent" {
  let body_stub = (id : String, body : String) => {
    harness([
      (
        "m.json",
        (
          $|{ "mocks": [{ "name": "m" }],
          $|  "stubs": [{ "id": "\{id}", "mock": "m", "request": { "body": \{body} },
          $|    "response": { "status": 200 } }] }
        ),
      ),
    ])
  }
  let exact = body_stub("exact", "\"name=Zoë\"")
  let pattern = body_stub("pattern", "{ \"pattern\": \"name=[A-Z][a-z]+\" }")
  let json = body_stub(
    "json", "{ \"json\": { \"name\": \"Zoë\", \"tags\": [1, true, null] } }",
  )
  json_inspect(
    [
      explanation(exact, "POST", "/", body="name=Zoe"),
      explanation(exact, "POST", "/"),
      explanation(pattern, "POST", "/", body="name=zoë"),
      explanation(json, "POST", "/", body="{\"name\": \"Zoë\", \"tags\": [1]}"),
      explanation(json, "POST", "/", body="not JSON"),
    ],
    content=[
      {
        "stub": "exact",
        "stubSource": "file",
        "failed": [
          {
            "condition": "body",
            "expected": "name=Zoë",
            "actual": ["name=Zoe"],
          },
        ],
      },
      {
        "stub": "exact",
        "stubSource": "file",
        "failed": [
          { "condition": "body", "expected": "name=Zoë", "actual": [""] },
        ],
      },
      {
        "stub": "pattern",
        "stubSource": "file",
        "failed": [
          {
            "condition": "body",
            "expected": { "pattern": "name=[A-Z][a-z]+" },
            "actual": ["name=zoë"],
          },
        ],
      },
      {
        "stub": "json",
        "stubSource": "file",
        "failed": [
          {
            "condition": "body",
            "expected": { "json": { "name": "Zoë", "tags": [1, true, null] } },
            "actual": ["{\"name\": \"Zoë\", \"tags\": [1]}"],
          },
        ],
      },
      {
        "stub": "json",
        "stubSource": "file",
        "failed": [
          {
            "condition": "body",
            "expected": { "json": { "name": "Zoë", "tags": [1, true, null] } },
            "actual": ["not JSON"],
          },
        ],
      },
    ],
  )
}

///|
test "a json condition with a pattern fails as body: the Near miss shows the condition with its pattern object, and the body as sent" {
  let h = stubs([
    (
      #|{ "id": "create-user", "mock": "m",
      #|  "request": { "method": "POST", "path": "/users",
      #|    "body": { "json": { "email": { "pattern": ".*@example\\.com" } } } },
      #|  "response": { "status": 201 } }
    ),
  ])
  let missed = h.send(
    "POST",
    "/users",
    body="{\"email\":{\"pattern\":\".*@example\\\\.com\"}}",
  )
  inspect(
    missed.plan.headers
    .filter(header => header.0 == "Smock-Near-Miss")
    .map(header => header.1)
    .join(""),
    content="create-user; failed=body",
  )
  guard missed.near_miss is Some(near_miss) else { fail("no Near miss") }
  json_inspect(near_miss.to_json(), content={
    "stub": "create-user",
    "stubSource": "file",
    "failed": [
      {
        "condition": "body",
        "expected": { "json": { "email": { "pattern": ".*@example\\.com" } } },
        "actual": ["{\"email\":{\"pattern\":\".*@example\\\\.com\"}}"],
      },
    ],
  })
}

///|
test "the Near miss shows a body that is not UTF-8 with U+FFFD in place of what is not UTF-8" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "exact", "mock": "m", "request": { "body": "name=Zoë" },
        #|    "response": { "status": 200 } }] }
      ),
    ),
  ])
  let outcome = h.engine.handle(
    {
      meth: "POST",
      target: "/",
      version: "HTTP/1.1",
      headers: [],
      body: b"name=Zo\xeb",
    },
    session=None,
    now=h.now,
    rand=h.rand,
  )
  guard outcome.near_miss is Some(near_miss) else { fail("no Near miss") }
  json_inspect(near_miss.to_json(), content={
    "stub": "exact",
    "stubSource": "file",
    "failed": [
      {
        "condition": "body",
        "expected": "name=Zoë",
        "actual": ["name=Zo\u{FFFD}"],
      },
    ],
  })
}

///|
test "changing the expected JSON of a Near miss changes no later match: the snapshot stays as loaded" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "tea", "mock": "m",
        #|    "request": { "body": { "json": { "item": "tea" } } },
        #|    "response": { "status": 201 } }] }
      ),
    ),
  ])
  let missed = h.send("POST", "/", body="{\"item\": \"coffee\"}")
  guard missed.near_miss
    is Some({ failed: [{ expected: Json(Object(expected)), .. }], .. }) else {
    fail("no Near miss with a json condition")
  }
  expected["item"] = Json::string("coffee")
  debug_inspect(
    [
      matched_id(h.send("POST", "/", body="{\"item\": \"coffee\"}")),
      matched_id(h.send("POST", "/", body="{\"item\": \"tea\"}")),
    ],
    content="[None, Some(\"tea\")]",
  )
}

///|
/// The `Smock-Near-Miss` header of `outcome`, or `none`.
fn near_miss_header(outcome : @engine.Outcome) -> String {
  for header in outcome.plan.headers {
    if header.0 == "Smock-Near-Miss" {
      return header.1
    }
  }
  "none"
}

///|
test "a Stub that fails only the state it requires is the Near miss, with the condition scenario:<name>: the required state, and the current one" {
  let h = harness(checkout)
  let _ = h.send("POST", "http://payments.svc/orders/42/pay", session="test-a")
  let again = h.send(
    "POST",
    "http://payments.svc/orders/42/pay",
    session="test-a",
  )
  inspect(near_miss_header(again), content="pay; failed=scenario:checkout")
  guard again.near_miss is Some(near_miss) else { fail("no Near miss") }
  json_inspect(near_miss.to_json(), content={
    "stub": "pay",
    "stubSource": "file",
    "failed": [
      {
        "condition": "scenario:checkout",
        "expected": "Started",
        "actual": ["Paid"],
      },
    ],
  })
}

///|
test "the state a Stub requires counts after method, path, query, headers and body, and a Scenario with no state stored is in Started" {
  let h = stubs([
    (
      #|{ "id": "paid-only", "mock": "m",
      #|  "request": { "method": "GET", "path": "/orders/42",
      #|    "query": { "v": "2" }, "headers": { "X-Tenant": "acme" }, "body": "x" },
      #|  "scenario": { "name": "checkout", "requires": "Paid" },
      #|  "response": { "status": 200 } }
    ),
  ])
  let wrong = h.send("PUT", "/orders/41?v=1", body="y", session="test-a")
  let only_query = h.send(
    "GET",
    "/orders/42?v=1",
    headers=[("X-Tenant", "acme")],
    body="x",
    session="test-a",
  )
  inspect(
    [near_miss_header(wrong), near_miss_header(only_query)].join("\n"),
    content=(
      #|paid-only; failed=method,path,query:v,header:x-tenant,body,scenario:checkout
      #|paid-only; failed=query:v,scenario:checkout
    ),
  )
  guard only_query.near_miss is Some(near_miss) else { fail("no Near miss") }
  json_inspect(near_miss.to_json(), content={
    "stub": "paid-only",
    "stubSource": "file",
    "failed": [
      { "condition": "query:v", "expected": "2", "actual": ["1"] },
      {
        "condition": "scenario:checkout",
        "expected": "Paid",
        "actual": ["Started"],
      },
    ],
  })
  // An Ephemeral Stub is a candidate as before, and its Scenario is in the
  // state of the request's Session.
  let _ = h.add(
    "m",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/health" },
      #|  "scenario": { "name": "outage", "requires": "Down" },
      #|  "response": { "status": 200 } }
    ),
  )
  guard h.send("GET", "/health", session="test-a").near_miss is Some(near_miss) else {
    fail("no Near miss")
  }
  json_inspect(near_miss.to_json(), content={
    "stub": "eph-1",
    "stubSource": "ephemeral",
    "failed": [
      {
        "condition": "scenario:outage",
        "expected": "Down",
        "actual": ["Started"],
      },
    ],
  })
}

///|
test "on a Mock whose file Stubs have no clause, an Ephemeral Stub that is the Near miss shows the state its Scenario is in for the Session, though no Stub with a clause met the request" {
  let h = stubs([
    (
      #|{ "id": "health", "mock": "m",
      #|  "request": { "method": "PUT", "path": "/health", "headers": { "X-Probe": "1" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let _ = h.add(
    "m",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/outage", "headers": { "X-Admin": "yes" } },
      #|  "scenario": { "name": "outage", "moveTo": "Down" },
      #|  "response": { "status": 200 } }
    ),
  )
  let _ = h.add(
    "m",
    Some("test-a"),
    (
      #|{ "request": { "method": "GET", "path": "/status", "query": { "v": "2" } },
      #|  "scenario": { "name": "outage", "requires": "Recovering" },
      #|  "response": { "status": 200 } }
    ),
  )
  let _ = h.send(
    "POST",
    "/outage",
    headers=[("X-Admin", "yes")],
    session="test-a",
  )
  guard h.send("GET", "/status?v=1", session="test-a").near_miss
    is Some(near_miss) else {
    fail("no Near miss")
  }
  json_inspect(near_miss.to_json(), content={
    "stub": "eph-2",
    "stubSource": "ephemeral",
    "failed": [
      { "condition": "query:v", "expected": "2", "actual": ["1"] },
      {
        "condition": "scenario:outage",
        "expected": "Recovering",
        "actual": ["Down"],
      },
    ],
  })
}

///|
test "the tie rule is unchanged: a Stub that fails only its state ties with one that fails only its method, and the earlier one is the Near miss" {
  let h = stubs([
    (
      #|{ "id": "a-put", "mock": "m", "request": { "method": "PUT", "path": "/a" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "b-paid", "mock": "m", "request": { "method": "GET", "path": "/a" },
      #|  "scenario": { "name": "checkout", "requires": "Paid" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "c-paid", "mock": "m", "request": { "method": "GET", "path": "/b" },
      #|  "scenario": { "name": "checkout", "requires": "Paid" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "d-put", "mock": "m", "request": { "method": "PUT", "path": "/b" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    [
      near_miss_header(h.send("GET", "/a")),
      near_miss_header(h.send("GET", "/b")),
    ].join("\n"),
    content=(
      #|a-put; failed=method
      #|c-paid; failed=scenario:checkout
    ),
  )
}

///|
test "only a Stub that requires a state can fail it: a Stub with moveTo and no requires fails only its request conditions, in any state" {
  let h = harness(login)
  let before = near_miss_header(h.send("PUT", "http://auth.svc/logout"))
  let _ = h.send("POST", "http://auth.svc/login")
  let after = near_miss_header(h.send("PUT", "http://auth.svc/logout"))
  inspect(
    "before login: \{before}\nafter login: \{after}",
    content=(
      #|before login: logout; failed=method
      #|after login: logout; failed=method
    ),
  )
}

///|
test "the Smock-Near-Miss header percent-encodes the Scenario name and carries no state" {
  let h = stubs([
    (
      #|{ "id": "pay", "mock": "m", "request": { "path": "/pay" },
      #|  "scenario": { "name": "check out; failed=x,y\r\nü", "requires": "Paid\r\nX: y" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    near_miss_header(h.send("GET", "/pay")),
    content="pay; failed=scenario:check%20out%3B%20failed%3Dx%2Cy%0D%0A%C3%BC",
  )
}

///|
test "Scenarios add no response header: a Stub that requires or moves a state answers with its own headers, and a miss gets only the Near miss" {
  let h = harness(checkout)
  inspect(
    [
      response(h.send("GET", "http://payments.svc/orders/42")),
      response(h.send("POST", "http://payments.svc/orders/42/pay")),
      response(h.send("GET", "http://payments.svc/orders/42")),
      response(h.send("POST", "http://payments.svc/orders/42/pay")),
    ].join("\n--\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|{"status":"pending"}
      #|--
      #|200
      #|
      #|--
      #|200
      #|Content-Type: application/json
      #|{"status":"paid"}
      #|--
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: pay; failed=scenario:checkout
      #|{"error":"no Stub matched"}
    ),
  )
}
