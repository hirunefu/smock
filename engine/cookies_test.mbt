// Seam 1 tests of cookie conditions: `request.cookies` matches the cookies
// of every `Cookie` field by name, with the values exactly as sent.

///|
test "a cookie condition holds when a cookie with that name has the value, wherever it sits in the Cookie field" {
  let h = stubs([
    (
      #|{ "id": "signed-in", "mock": "m",
      #|  "request": { "cookies": { "session": "abc" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Cookie", "session=abc")], ""),
      ("GET", "/", [("Cookie", "theme=dark; session=abc; lang=en")], ""),
      ("GET", "/", [("cookie", "session=abd")], ""),
      ("GET", "/", [("Cookie", "theme=dark")], ""),
      ("GET", "/", [("X-Cookie", "session=abc")], ""),
      ("GET", "/", [], ""),
    ]),
    content=(
      #|GET / [Cookie: session=abc] -> signed-in
      #|GET / [Cookie: theme=dark; session=abc; lang=en] -> signed-in
      #|GET / [cookie: session=abd] -> none
      #|GET / [Cookie: theme=dark] -> none
      #|GET / [X-Cookie: session=abc] -> none
      #|GET / -> none
    ),
  )
}

///|
test "cookies are read from every Cookie field, and names are compared exactly, case and all" {
  let h = stubs([
    (
      #|{ "id": "both", "mock": "m",
      #|  "request": { "cookies": { "session": "abc", "Theme": "dark" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Cookie", "session=abc"), ("Cookie", "Theme=dark")], ""),
      (
        "GET",
        "/",
        [("cookie", "Theme=dark"), ("COOKIE", "a=1; session=abc")],
        "",
      ),
      ("GET", "/", [("Cookie", "session=abc; Theme=dark")], ""),
      ("GET", "/", [("Cookie", "session=abc; theme=dark")], ""),
      ("GET", "/", [("Cookie", "Session=abc; Theme=dark")], ""),
      ("GET", "/", [("Cookie", "session=abc, Theme=dark")], ""),
    ]),
    content=(
      #|GET / [Cookie: session=abc] [Cookie: Theme=dark] -> both
      #|GET / [cookie: Theme=dark] [COOKIE: a=1; session=abc] -> both
      #|GET / [Cookie: session=abc; Theme=dark] -> both
      #|GET / [Cookie: session=abc; theme=dark] -> none
      #|GET / [Cookie: Session=abc; Theme=dark] -> none
      #|GET / [Cookie: session=abc, Theme=dark] -> none
    ),
  )
}

///|
test "a cookie value is compared exactly as sent: quotes are part of it, and nothing is percent-decoded" {
  let h = stubs([
    (
      #|{ "id": "quoted", "mock": "m", "request": { "path": "/q",
      #|    "cookies": { "token": "\"abc\"" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "encoded", "mock": "m", "request": { "path": "/e",
      #|    "cookies": { "name": "a%20b", "plus": "a+b" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "pattern", "mock": "m", "request": { "path": "/p",
      #|    "cookies": { "session": { "pattern": "sess_[0-9a-f]+" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/q", [("Cookie", "token=\"abc\"")], ""),
      ("GET", "/q", [("Cookie", "token=abc")], ""),
      ("GET", "/e", [("Cookie", "name=a%20b; plus=a+b")], ""),
      ("GET", "/e", [("Cookie", "name=a b; plus=a b")], ""),
      ("GET", "/p", [("Cookie", "session=sess_09af")], ""),
      ("GET", "/p", [("Cookie", "session=\"sess_09af\"")], ""),
      ("GET", "/p", [("Cookie", "session=xsess_09af")], ""),
    ]),
    content=(
      #|GET /q [Cookie: token="abc"] -> quoted
      #|GET /q [Cookie: token=abc] -> none
      #|GET /e [Cookie: name=a%20b; plus=a+b] -> encoded
      #|GET /e [Cookie: name=a b; plus=a b] -> none
      #|GET /p [Cookie: session=sess_09af] -> pattern
      #|GET /p [Cookie: session="sess_09af"] -> none
      #|GET /p [Cookie: session=xsess_09af] -> none
    ),
  )
}

///|
test "each part of a Cookie field is trimmed of spaces and tabs, its first = ends the name, and a part without = is skipped" {
  let h = stubs([
    (
      #|{ "id": "trimmed", "mock": "m", "request": { "path": "/t",
      #|    "cookies": { "a": "1", "b": "x=y", "c": "" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "flag", "mock": "m", "request": { "path": "/f",
      #|    "cookies": { "flag": { "$exists": true } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "spaced", "mock": "m", "request": { "path": "/s",
      #|    "cookies": { "a ": " 1" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/t", [("Cookie", "a=1;b=x=y;c=")], ""),
      ("GET", "/t", [("Cookie", " \ta=1 ;  b=x=y\t;c= ; ;")], ""),
      ("GET", "/t", [("Cookie", "a=1; b=x; c=")], ""),
      ("GET", "/f", [("Cookie", "flag")], ""),
      ("GET", "/f", [("Cookie", "a=1; flag; b=2")], ""),
      ("GET", "/f", [("Cookie", "flag=")], ""),
      ("GET", "/s", [("Cookie", "a = 1")], ""),
      ("GET", "/s", [("Cookie", "a=1")], ""),
    ]),
    content=(
      #|GET /t [Cookie: a=1;b=x=y;c=] -> trimmed
      #|GET /t [Cookie:  	a=1 ;  b=x=y	;c= ; ;] -> trimmed
      #|GET /t [Cookie: a=1; b=x; c=] -> none
      #|GET /f [Cookie: flag] -> none
      #|GET /f [Cookie: a=1; flag; b=2] -> none
      #|GET /f [Cookie: flag=] -> flag
      #|GET /s [Cookie: a = 1] -> spaced
      #|GET /s [Cookie: a=1] -> none
    ),
  )
}

///|
test "a repeated cookie name matches when any of its values meets the condition, and $not and $exists are about the name as a whole" {
  let h = stubs([
    (
      #|{ "id": "ticket", "mock": "m",
      #|  "request": { "cookies": { "session": { "pattern": "sess_.*" }, "debug": { "$not": "1" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "anonymous", "mock": "m",
      #|  "request": { "cookies": { "session": { "$exists": false } } },
      #|  "response": { "status": 401 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("Cookie", "session=old; session=sess_1")], ""),
      (
        "GET",
        "/",
        [("Cookie", "session=sess_1"), ("Cookie", "debug=0; debug=2")],
        "",
      ),
      (
        "GET",
        "/",
        [("Cookie", "session=sess_1; debug=0"), ("Cookie", "debug=1")],
        "",
      ),
      ("GET", "/", [("Cookie", "session=old")], ""),
      ("GET", "/", [("Cookie", "debug=1")], ""),
      ("GET", "/", [("Cookie", "sessions=sess_1; session")], ""),
      ("GET", "/", [], ""),
    ]),
    content=(
      #|GET / [Cookie: session=old; session=sess_1] -> ticket
      #|GET / [Cookie: session=sess_1] [Cookie: debug=0; debug=2] -> ticket
      #|GET / [Cookie: session=sess_1; debug=0] [Cookie: debug=1] -> none
      #|GET / [Cookie: session=old] -> none
      #|GET / [Cookie: debug=1] -> anonymous
      #|GET / [Cookie: sessions=sess_1; session] -> anonymous
      #|GET / -> anonymous
    ),
  )
}

///|
/// A Mock `m` with one Stub, `cookie-guarded`, with a condition of each kind
/// up to the body, three of them on cookies, one of which is named `a b`.
let cookie_guarded : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [{ "id": "cookie-guarded", "mock": "m",
  #|    "request": { "method": "POST", "path": "/cart",
  #|      "body": "{}",
  #|      "cookies": { "session": { "pattern": "sess_.*" }, "debug": { "$not": "1" },
  #|        "a b": { "$exists": true } },
  #|      "headers": { "X-Tenant": "acme" },
  #|      "query": { "dry": "yes" } },
  #|    "response": { "status": 200 } }] }

///|
test "a failed cookie counts once in the Near miss as cookie:<name>, after the headers and before the body, escaped in the header as query names are" {
  let h = harness([("m.json", cookie_guarded)])
  inspect(
    near_misses(h, [
      (
        "POST",
        "/cart?dry=yes",
        [("X-Tenant", "acme"), ("Cookie", "session=sess_1; a b")],
        "{}",
      ),
      ("GET", "/cart", [("Cookie", "session=old; debug=1")], "x"),
    ]),
    content=(
      #|POST /cart?dry=yes [X-Tenant: acme] [Cookie: session=sess_1; a b] "{}" -> cookie-guarded; failed=cookie:a%20b
      #|GET /cart [Cookie: session=old; debug=1] "x" -> cookie-guarded; failed=method,query:dry,header:x-tenant,cookie:session,cookie:debug,cookie:a%20b,body
    ),
  )
}

///|
test "the Near miss shows a failed cookie's condition as the Stub writes it, with every value of the name from every Cookie field, none when absent" {
  let h = harness([("m.json", cookie_guarded)])
  json_inspect(
    explanation(h, "POST", "/cart?dry=yes", body="{}", headers=[
      ("X-Tenant", "acme"),
      ("Cookie", "session=old; debug=0"),
      ("cookie", "debug=\"1\"; session=\"sess_2\"; debug=1"),
    ]),
    content={
      "stub": "cookie-guarded",
      "stubSource": "file",
      "failed": [
        {
          "condition": "cookie:session",
          "expected": { "pattern": "sess_.*" },
          "actual": ["old", "\"sess_2\""],
        },
        {
          "condition": "cookie:debug",
          "expected": { "$not": "1" },
          "actual": ["0", "\"1\"", "1"],
        },
        {
          "condition": "cookie:a b",
          "expected": { "$exists": true },
          "actual": [],
        },
      ],
    },
  )
}

///|
test "the Journal and render show a failed cookie as the Near miss does" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["m.example.com"] }],
        #|  "stubs": [{ "id": "signed-in", "mock": "m",
        #|    "request": { "path": "/a",
        #|      "cookies": { "session": { "pattern": "sess_.*" }, "debug": { "$not": "1" } } },
        #|    "response": { "status": 200 } }] }
      ),
    ),
  ])
  let _ = h.record(
    "GET",
    "/a",
    headers=[("Host", "m.example.com"), ("Cookie", "session=old; debug=1")],
    session="s",
  )
  json_inspect(h.answered(Some("s")), content={
    "host": "m.example.com",
    "mock": "m",
    "viaDefault": false,
    "stub": null,
    "nearMiss": {
      "stub": "signed-in",
      "stubSource": "file",
      "failed": [
        {
          "condition": "cookie:session",
          "expected": { "pattern": "sess_.*" },
          "actual": ["old"],
        },
        {
          "condition": "cookie:debug",
          "expected": { "$not": "1" },
          "actual": ["1"],
        },
      ],
    },
    "status": 404,
    "fault": null,
  })
  inspect(
    h.failed("signed-in", {
      "path": "/a",
      "headers": { "Cookie": ["debug=0; session=x", "debug=1"] },
    }),
    content=(
      #|cookie:session: expected {"pattern":"sess_.*"}, actual ["x"]
      #|cookie:debug: expected {"$not":"1"}, actual ["0","1"]
    ),
  )
}

///|
test "an Ephemeral Stub may have cookie conditions, and a malformed one is rejected with the messages a Definition file gets" {
  let h = harness(shop)
  let added = h.add(
    "users",
    Some("s"),
    (
      #|{ "request": { "path": "/users/1",
      #|    "cookies": { "session": { "$exists": false } } },
      #|  "response": { "status": 401, "body": "sign in" } }
    ),
  )
  let answer = (cookie : String?) => {
    let headers = match cookie {
      Some(cookie) => [("Cookie", cookie)]
      None => []
    }
    let outcome = h.send(
      "GET",
      "http://users.svc/users/1",
      headers~,
      session="s",
    )
    matched_id(outcome).unwrap_or("none")
  }
  inspect(
    "\{added}: \{answer(None)} \{answer(Some("theme=dark"))} \{answer(Some("session=abc"))}",
    content=(
      #|eph-1: eph-1 eph-1 u-alice
    ),
  )
  inspect(
    h.problems(
      (
        #|{ "request": { "cookies": { "a": 1, "b": { "$nto": "1" }, "c": { "pattern": "(" } } },
        #|  "response": { "status": 200 } }
      ),
    ),
    content=(
      #|/request/cookies/a: must be a string or an object
      #|/request/cookies/b/$nto: is not an operator: the operators here are "$not" and "$exists"
      #|/request/cookies/c/pattern: is not a valid pattern: position 0: missing closing )
    ),
  )
}
