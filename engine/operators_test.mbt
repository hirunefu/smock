// Seam 1 tests of the operators in query and header values: `$not`, which
// negates a condition, and `$exists`, which requires a name to be present
// or absent. Each is checked with present, absent and repeated values.

///|
test "$not on a header holds exactly when the inner condition does not, so it holds when the header is absent" {
  let h = stubs([
    (
      #|{ "id": "no-bearer", "mock": "m",
      #|  "request": { "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } } } },
      #|  "response": { "status": 401 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Authorization", "Bearer abc")], ""),
      ("GET", "/", [("Authorization", "Basic YTpi")], ""),
      ("GET", "/", [("authorization", "bearer abc")], ""),
      ("GET", "/", [], ""),
    ]),
    content=(
      #|GET / [Authorization: Bearer abc] -> none
      #|GET / [Authorization: Basic YTpi] -> no-bearer
      #|GET / [authorization: bearer abc] -> no-bearer
      #|GET / -> no-bearer
    ),
  )
}

///|
test "$not on a query parameter negates an exact value: it holds for every other value, and when the parameter is absent" {
  let h = stubs([
    (
      #|{ "id": "not-draft", "mock": "m",
      #|  "request": { "query": { "status": { "$not": "draft" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?status=draft", [], ""),
      ("GET", "/?status=published", [], ""),
      ("GET", "/?status=", [], ""),
      ("GET", "/?status", [], ""),
      ("GET", "/?state=draft", [], ""),
      ("GET", "/", [], ""),
    ]),
    content=(
      #|GET /?status=draft -> none
      #|GET /?status=published -> not-draft
      #|GET /?status= -> not-draft
      #|GET /?status -> not-draft
      #|GET /?state=draft -> not-draft
      #|GET / -> not-draft
    ),
  )
}

///|
test "$not on a repeated query parameter or header holds only when none of its values meets the inner condition" {
  let h = stubs([
    (
      #|{ "id": "no-admin", "mock": "m", "request": { "path": "/q",
      #|    "query": { "role": { "$not": "admin" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "no-debug", "mock": "m", "request": { "path": "/h",
      #|    "headers": { "X-Tag": { "$not": { "pattern": "debug.*" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/q?role=user&role=admin", [], ""),
      ("GET", "/q?role=admin&role=user", [], ""),
      ("GET", "/q?role=user&role=guest", [], ""),
      ("GET", "/h", [("X-Tag", "a"), ("x-tag", "debug-1")], ""),
      ("GET", "/h", [("X-Tag", "a"), ("x-tag", "b")], ""),
      ("GET", "/h", [("X-Tag", "a, debug-1")], ""),
    ]),
    content=(
      #|GET /q?role=user&role=admin -> none
      #|GET /q?role=admin&role=user -> none
      #|GET /q?role=user&role=guest -> no-admin
      #|GET /h [X-Tag: a] [x-tag: debug-1] -> none
      #|GET /h [X-Tag: a] [x-tag: b] -> no-debug
      #|GET /h [X-Tag: a, debug-1] -> no-debug
    ),
  )
}

///|
test "$exists true holds when the name is present with any value, even empty; false when it is absent" {
  let h = stubs([
    (
      #|{ "id": "with-debug", "mock": "m", "request": { "path": "/q",
      #|    "query": { "debug": { "$exists": true } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "without-debug", "mock": "m", "request": { "path": "/q",
      #|    "query": { "debug": { "$exists": false } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "with-trace", "mock": "m", "request": { "path": "/h",
      #|    "headers": { "X-Trace": { "$exists": true } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "without-trace", "mock": "m", "request": { "path": "/h",
      #|    "headers": { "X-Trace": { "$exists": false } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/q?debug=1", [], ""),
      ("GET", "/q?debug=", [], ""),
      ("GET", "/q?debug", [], ""),
      ("GET", "/q?debug=0&debug=1", [], ""),
      ("GET", "/q?debugging=1", [], ""),
      ("GET", "/q", [], ""),
      ("GET", "/h", [("x-trace", "abc")], ""),
      ("GET", "/h", [("X-TRACE", "")], ""),
      ("GET", "/h", [("X-Traces", "abc")], ""),
      ("GET", "/h", [], ""),
    ]),
    content=(
      #|GET /q?debug=1 -> with-debug
      #|GET /q?debug= -> with-debug
      #|GET /q?debug -> with-debug
      #|GET /q?debug=0&debug=1 -> with-debug
      #|GET /q?debugging=1 -> without-debug
      #|GET /q -> without-debug
      #|GET /h [x-trace: abc] -> with-trace
      #|GET /h [X-TRACE: ] -> with-trace
      #|GET /h [X-Traces: abc] -> without-trace
      #|GET /h -> without-trace
    ),
  )
}

///|
test "operators nest: $not of $not is the inner condition, and $not of $exists is $exists of the opposite" {
  let h = stubs([
    (
      #|{ "id": "not-not", "mock": "m", "request": { "path": "/a",
      #|    "query": { "v": { "$not": { "$not": { "pattern": "[0-9]+" } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "not-exists", "mock": "m", "request": { "path": "/b",
      #|    "headers": { "X-Id": { "$not": { "$exists": true } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "not-not-exists", "mock": "m", "request": { "path": "/c",
      #|    "headers": { "X-Id": { "$not": { "$not": { "$exists": false } } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/a?v=12", [], ""),
      ("GET", "/a?v=x&v=3", [], ""),
      ("GET", "/a?v=x", [], ""),
      ("GET", "/a", [], ""),
      ("GET", "/b", [("X-Id", "1")], ""),
      ("GET", "/b", [], ""),
      ("GET", "/c", [("X-Id", "1")], ""),
      ("GET", "/c", [], ""),
    ]),
    content=(
      #|GET /a?v=12 -> not-not
      #|GET /a?v=x&v=3 -> not-not
      #|GET /a?v=x -> none
      #|GET /a -> none
      #|GET /b [X-Id: 1] -> none
      #|GET /b -> not-exists
      #|GET /c [X-Id: 1] -> none
      #|GET /c -> not-not-exists
    ),
  )
}

///|
test "query and header names are literal even when they start with $, as OData's $filter and $top do" {
  let h = stubs([
    (
      #|{ "id": "odata", "mock": "m",
      #|  "request": { "query": { "$filter": "name eq 'a'", "$top": { "$exists": true } },
      #|    "headers": { "$X": { "$not": "1" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?$filter=name+eq+'a'&$top=5", [], ""),
      ("GET", "/?%24filter=name%20eq%20'a'&%24top", [("$x", "2")], ""),
      ("GET", "/?$filter=name+eq+'a'&$top=5", [("$X", "1")], ""),
      ("GET", "/?$filter=name+eq+'a'", [], ""),
      ("GET", "/?filter=name+eq+'a'&top=5", [], ""),
    ]),
    content=(
      #|GET /?$filter=name+eq+'a'&$top=5 -> odata
      #|GET /?%24filter=name%20eq%20'a'&%24top [$x: 2] -> odata
      #|GET /?$filter=name+eq+'a'&$top=5 [$X: 1] -> none
      #|GET /?$filter=name+eq+'a' -> none
      #|GET /?filter=name+eq+'a'&top=5 -> none
    ),
  )
}

///|
test "an Ephemeral Stub may use operators, and a malformed one is rejected with the messages a Definition file gets" {
  let h = harness(shop)
  let added = h.add(
    "users",
    Some("s"),
    (
      #|{ "request": { "path": "/users/1",
      #|    "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } } },
      #|    "query": { "debug": { "$exists": false } } },
      #|  "response": { "status": 401, "body": "no token" } }
    ),
  )
  inspect(
    [
      h.brief("users.svc", "/users/1", session="s"),
      h.brief("users.svc", "/users/1?debug", session="s"),
      h.brief("users.svc", "/users/1", session="t"),
    ].join("\n"),
    content=(
      #|401 no token (eph-1)
      #|200 Alice (u-alice)
      #|200 Alice (u-alice)
    ),
  )
  debug_inspect(added, content="\"eph-1\"")
  inspect(
    h.problems(
      (
        #|{ "request": { "query": { "q": { "$nto": "1" }, "r": { "$exists": "yes" } },
        #|    "headers": { "X-A": { "$not": "a", "pattern": "b" }, "X-B": { "$includes": "c" } } },
        #|  "response": { "status": 200 } }
      ),
    ),
    content=(
      #|/request/query/q/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
      #|/request/query/r/$exists: must be true or false
      #|/request/headers/X-A/pattern: is not allowed beside "$not": an operator is the only key of its object
      #|/request/headers/X-B/$includes: is allowed only in a json condition
    ),
  )
}

///|
/// A Mock `m` with one Stub, `guarded`, whose query and header conditions
/// use every operator form.
let guarded : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [{ "id": "guarded", "mock": "m",
  #|    "request": { "method": "GET", "path": "/orders",
  #|      "query": { "debug": { "$exists": false }, "page": { "$exists": true },
  #|        "status": { "$not": "draft" } },
  #|      "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } },
  #|        "X-Tag": { "$not": { "$not": "a" } } } },
  #|    "response": { "status": 200 } }] }

///|
test "a failed operator counts once in the Near miss, named as any query or header condition, and the header carries no operator" {
  let h = harness([("m.json", guarded)])
  inspect(
    near_misses(h, [
      ("GET", "/orders?page=1", [("X-Tag", "a")], ""),
      (
        "GET",
        "/orders?debug&debug=1&status=draft",
        [("Authorization", "Bearer x"), ("X-Tag", "b")],
        "",
      ),
    ]),
    content=(
      #|GET /orders?page=1 [X-Tag: a] -> none
      #|GET /orders?debug&debug=1&status=draft [Authorization: Bearer x] [X-Tag: b] -> guarded; failed=query:debug,query:page,query:status,header:authorization,header:x-tag
    ),
  )
}

///|
test "the Near miss shows a failed operator as the Stub writes it, with every value the request carries for the name, none when absent" {
  let h = harness([("m.json", guarded)])
  json_inspect(
    explanation(h, "GET", "/orders?debug&status=draft&debug=1&status=x", headers=[
      ("Authorization", "Basic a"),
      ("authorization", "Bearer x"),
    ]),
    content={
      "stub": "guarded",
      "stubSource": "file",
      "failed": [
        {
          "condition": "query:debug",
          "expected": { "$exists": false },
          "actual": ["", "1"],
        },
        {
          "condition": "query:page",
          "expected": { "$exists": true },
          "actual": [],
        },
        {
          "condition": "query:status",
          "expected": { "$not": "draft" },
          "actual": ["draft", "x"],
        },
        {
          "condition": "header:authorization",
          "expected": { "$not": { "pattern": "Bearer .*" } },
          "actual": ["Basic a", "Bearer x"],
        },
        {
          "condition": "header:x-tag",
          "expected": { "$not": { "$not": "a" } },
          "actual": [],
        },
      ],
    },
  )
}

///|
test "the Journal and render show a failed operator as the Near miss does" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["m.example.com"] }],
        #|  "stubs": [{ "id": "no-bearer", "mock": "m",
        #|    "request": { "path": "/a",
        #|      "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } } },
        #|      "query": { "v": { "$exists": true } } },
        #|    "response": { "status": 401 } }] }
      ),
    ),
  ])
  let _ = h.record(
    "GET",
    "/a",
    headers=[("Host", "m.example.com"), ("Authorization", "Bearer x")],
    session="s",
  )
  json_inspect(h.answered(Some("s")), content={
    "host": "m.example.com",
    "mock": "m",
    "viaDefault": false,
    "stub": Json::null(),
    "nearMiss": {
      "stub": "no-bearer",
      "stubSource": "file",
      "failed": [
        {
          "condition": "query:v",
          "expected": { "$exists": true },
          "actual": [],
        },
        {
          "condition": "header:authorization",
          "expected": { "$not": { "pattern": "Bearer .*" } },
          "actual": ["Bearer x"],
        },
      ],
    },
    "status": 404,
    "fault": Json::null(),
  })
  inspect(
    h.failed("no-bearer", {
      "path": "/a",
      "headers": { "Authorization": "Bearer x" },
    }),
    content=(
      #|query:v: expected {"$exists":true}, actual []
      #|header:authorization: expected {"$not":{"pattern":"Bearer .*"}}, actual ["Bearer x"]
    ),
  )
}

///|
test "a Journal filter's header values take $not and $exists, as a Stub's do, and a malformed operator is rejected at its pointer" {
  let h = harness(journal_shop)
  let users = ("Host", "users.example.com")
  let _ = h.record("GET", "/users/1", headers=[users], session="s")
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[users, ("X-Trace", "a")],
    session="s",
  )
  let _ = h.record(
    "GET",
    "/users/1",
    headers=[users, ("X-Trace", "b"), ("x-trace", "a")],
    session="s",
  )
  let filters = [
    "{ \"X-Trace\": { \"$exists\": false } }", "{ \"X-Trace\": { \"$exists\": true } }",
    "{ \"x-trace\": { \"$not\": \"a\" } }", "{ \"X-Trace\": { \"$not\": { \"pattern\": \"[c-z]\" } } }",
  ]
  let out = []
  for filter in filters {
    let page = h.engine.query_journal(
      @engine.JournalQuery::from_json(
        @json.parse("{ \"filter\": { \"headers\": \{filter} } }"),
      ),
      session=Some("s"),
    )
    let traces = page.entries.map(entry => {
      let values = entry.request.headers
        .iter()
        .filter(header => header.0.to_lower() == "x-trace")
        .map(header => header.1)
        .collect()
      "[\{values.join(", ")}]"
    })
    out.push("\{filter} -> \{traces.join(" ")}")
  }
  let problems = try
    @engine.JournalQuery::from_json(
      @json.parse(
        "{ \"filter\": { \"headers\": { \"X-A\": { \"$exists\": 1 }, \"X-B\": { \"$nto\": \"b\" } } } }",
      ),
    )
  catch {
    @engine.InvalidQuery(_) as error => error.message()
    error => fail(@debug.to_string(error))
  } noraise {
    _ => "valid"
  }
  inspect(
    "\{out.join("\n")}\n\{problems}",
    content=(
      #|{ "X-Trace": { "$exists": false } } -> []
      #|{ "X-Trace": { "$exists": true } } -> [a] [b, a]
      #|{ "x-trace": { "$not": "a" } } -> []
      #|{ "X-Trace": { "$not": { "pattern": "[c-z]" } } } -> [] [a] [b, a]
      #|/filter/headers/X-A/$exists: must be true or false
      #|/filter/headers/X-B/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
    ),
  )
}
