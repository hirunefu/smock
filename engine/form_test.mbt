// Seam 1 tests of form conditions, `body: { form: … }`: the fields of an
// application/x-www-form-urlencoded body, decoded as query parameters are,
// matched by name with the value conditions and operators of a query
// parameter, only when the request says the body is a form.

///|
/// The media type of a form body.
let form_type : String = "application/x-www-form-urlencoded"

///|
/// The ID of the Stub that answered each `POST /`, or `none`, one per line,
/// after the request's Content-Type, if any, and body. A request is given
/// as (Content-Type, body).
fn posted(h : Harness, requests : Array[(String?, String)]) -> String {
  requests
  .map(r => {
    let (content_type, body) = r
    let headers = match content_type {
      Some(value) => [("Content-Type", value)]
      None => []
    }
    let winner = match matched_id(h.send("POST", "/", headers~, body~)) {
      Some(id) => id
      None => "none"
    }
    let shown = match content_type {
      Some(value) => "[\{value}] "
      None => ""
    }
    "\{shown}\{body.escape()} -> \{winner}"
  })
  .join("\n")
}

///|
test "a form condition holds for the fields of a form body, decoded as query parameters are, whatever their order" {
  let h = stubs([
    (
      #|{ "id": "login", "mock": "m",
      #|  "request": { "body": { "form": { "username": "alice smith", "note": "a+b=c&d" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let form = Some(form_type)
  inspect(
    posted(h, [
      (form, "username=alice+smith&note=a%2Bb%3Dc%26d"),
      (form, "note=a%2bb%3dc%26d&username=alice%20smith"),
      (form, "user%6Eame=alice+smith&&note=a%2Bb%3Dc%26d&"),
      (form, "username=alice+smith&note=a+b=c&d"),
      (form, "username=alice+smith"),
      (form, "username=alice&note=a%2Bb%3Dc%26d"),
    ]),
    content=(
      #|[application/x-www-form-urlencoded] "username=alice+smith&note=a%2Bb%3Dc%26d" -> login
      #|[application/x-www-form-urlencoded] "note=a%2bb%3dc%26d&username=alice%20smith" -> login
      #|[application/x-www-form-urlencoded] "user%6Eame=alice+smith&&note=a%2Bb%3Dc%26d&" -> login
      #|[application/x-www-form-urlencoded] "username=alice+smith&note=a+b=c&d" -> none
      #|[application/x-www-form-urlencoded] "username=alice+smith" -> none
      #|[application/x-www-form-urlencoded] "username=alice&note=a%2Bb%3Dc%26d" -> none
    ),
  )
}

///|
test "a form condition holds only when the media type of the Content-Type is a form's, in any case and with any parameters; otherwise every form condition fails, $not included" {
  let h = stubs([
    (
      #|{ "id": "alice", "mock": "m",
      #|  "request": { "body": { "form": { "username": "alice" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "not-remembered", "mock": "m",
      #|  "request": { "body": { "form": { "remember": { "$not": "1" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let form = Some(form_type)
  inspect(
    posted(h, [
      (form, "username=alice"),
      (
        Some("Application/X-WWW-Form-URLEncoded;charset=UTF-8"),
        "username=alice",
      ),
      (
        Some("application/x-www-form-urlencoded ; charset=utf-8"),
        "username=alice",
      ),
      (form, "username=bob"),
      (form, ""),
      (Some("application/json"), "username=alice"),
      (Some("text/plain"), "username=bob"),
      (Some("multipart/form-data; boundary=x"), "username=bob"),
      (Some("application/x-www-form-urlencoded-x"), "username=bob"),
      (Some(""), "username=bob"),
      (None, "username=alice"),
    ]),
    content=(
      #|[application/x-www-form-urlencoded] "username=alice" -> alice
      #|[Application/X-WWW-Form-URLEncoded;charset=UTF-8] "username=alice" -> alice
      #|[application/x-www-form-urlencoded ; charset=utf-8] "username=alice" -> alice
      #|[application/x-www-form-urlencoded] "username=bob" -> not-remembered
      #|[application/x-www-form-urlencoded] "" -> not-remembered
      #|[application/json] "username=alice" -> none
      #|[text/plain] "username=bob" -> none
      #|[multipart/form-data; boundary=x] "username=bob" -> none
      #|[application/x-www-form-urlencoded-x] "username=bob" -> none
      #|[] "username=bob" -> none
      #|"username=alice" -> none
    ),
  )
}

///|
test "an empty form condition holds only when the Content-Type says the body is a form, as an empty json condition needs JSON; its failure counts once, as body" {
  let h = stubs([
    (
      #|{ "id": "any-form", "mock": "m", "request": { "body": { "form": {} } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    posted(h, [
      (Some(form_type), "a=1"),
      (Some(form_type), ""),
      (Some("Application/X-WWW-Form-URLEncoded; charset=UTF-8"), "a=1"),
      (Some("application/json"), "{}"),
      (None, "a=1"),
    ]),
    content=(
      #|[application/x-www-form-urlencoded] "a=1" -> any-form
      #|[application/x-www-form-urlencoded] "" -> any-form
      #|[Application/X-WWW-Form-URLEncoded; charset=UTF-8] "a=1" -> any-form
      #|[application/json] "{}" -> none
      #|"a=1" -> none
    ),
  )
  json_inspect(
    explanation(
      h,
      "POST",
      "/",
      headers=[("Content-Type", "application/json")],
      body="{}",
    ),
    content={
      "stub": "any-form",
      "stubSource": "file",
      "failed": [
        { "condition": "body", "expected": { "form": {} }, "actual": ["{}"] },
      ],
    },
  )
}

///|
test "a form field takes patterns, $not and $exists as a query parameter does: a repeated field matches when any value does, and $not when none does" {
  let one = (stub : String) => {
    stubs([
      "{ \"id\": \"s\", \"mock\": \"m\", \"request\": { \"body\": { \"form\": \{stub} } }, \"response\": { \"status\": 200 } }",
    ])
  }
  let form = Some(form_type)
  let out = []
  for
    case in [
      (
        "{ \"tag\": { \"pattern\": \"urgent|high\" } }",
        [
          "tag=low&tag=high", "tag=high&tag=low", "tag=low&tag=normal", "tag", "",
        ],
      ),
      (
        "{ \"role\": { \"$not\": \"admin\" } }",
        [
          "role=user&role=admin", "role=user&role=guest", "role=", "", "roles=admin",
        ],
      ),
      (
        "{ \"coupon\": { \"$exists\": true } }",
        ["coupon=SAVE10", "coupon=", "coupon", "coupons=SAVE10", ""],
      ),
      (
        "{ \"coupon\": { \"$exists\": false } }",
        ["coupon", "coupons=SAVE10", ""],
      ),
      (
        "{ \"$filter\": { \"$not\": { \"$not\": \"a\" } } }",
        ["$filter=a", "%24filter=b&%24filter=a", "filter=a"],
      ),
    ] {
    let (condition, bodies) = case
    out.push(condition)
    out.push(posted(one(condition), bodies.map(body => (form, body))))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{ "tag": { "pattern": "urgent|high" } }
      #|[application/x-www-form-urlencoded] "tag=low&tag=high" -> s
      #|[application/x-www-form-urlencoded] "tag=high&tag=low" -> s
      #|[application/x-www-form-urlencoded] "tag=low&tag=normal" -> none
      #|[application/x-www-form-urlencoded] "tag" -> none
      #|[application/x-www-form-urlencoded] "" -> none
      #|{ "role": { "$not": "admin" } }
      #|[application/x-www-form-urlencoded] "role=user&role=admin" -> none
      #|[application/x-www-form-urlencoded] "role=user&role=guest" -> s
      #|[application/x-www-form-urlencoded] "role=" -> s
      #|[application/x-www-form-urlencoded] "" -> s
      #|[application/x-www-form-urlencoded] "roles=admin" -> s
      #|{ "coupon": { "$exists": true } }
      #|[application/x-www-form-urlencoded] "coupon=SAVE10" -> s
      #|[application/x-www-form-urlencoded] "coupon=" -> s
      #|[application/x-www-form-urlencoded] "coupon" -> s
      #|[application/x-www-form-urlencoded] "coupons=SAVE10" -> none
      #|[application/x-www-form-urlencoded] "" -> none
      #|{ "coupon": { "$exists": false } }
      #|[application/x-www-form-urlencoded] "coupon" -> none
      #|[application/x-www-form-urlencoded] "coupons=SAVE10" -> s
      #|[application/x-www-form-urlencoded] "" -> s
      #|{ "$filter": { "$not": { "$not": "a" } } }
      #|[application/x-www-form-urlencoded] "$filter=a" -> s
      #|[application/x-www-form-urlencoded] "%24filter=b&%24filter=a" -> s
      #|[application/x-www-form-urlencoded] "filter=a" -> none
    ),
  )
}

///|
/// A Mock `m` with one Stub, `login`, with query, header and form
/// conditions.
let form_login : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [{ "id": "login", "mock": "m",
  #|    "request": { "method": "POST", "path": "/login",
  #|      "query": { "next": "/" }, "headers": { "X-Csrf": "t" },
  #|      "body": { "form": { "username": "alice", "pass word": { "pattern": ".{8,}" },
  #|        "remember": { "$not": "1" }, "é": { "$exists": true } } } },
  #|    "response": { "status": 200 } }] }

///|
test "the Near miss names each failed form field once, after the headers, as form:<name>, with the name escaped in the header as a query name is" {
  let h = harness([("m.json", form_login)])
  let form = ("Content-Type", form_type)
  inspect(
    near_misses(h, [
      (
        "POST",
        "/login?next=/",
        [form, ("X-Csrf", "t")],
        "username=alice&pass+word=12345678&%C3%A9",
      ),
      ("POST", "/login", [form], "username=bob&remember=1&pass%20word=1234"),
      (
        "POST",
        "/login?next=/",
        [("Content-Type", "application/json"), ("X-Csrf", "t")],
        "username=alice&pass+word=12345678&%C3%A9",
      ),
    ]),
    content=(
      #|POST /login?next=/ [Content-Type: application/x-www-form-urlencoded] [X-Csrf: t] "username=alice&pass+word=12345678&%C3%A9" -> none
      #|POST /login [Content-Type: application/x-www-form-urlencoded] "username=bob&remember=1&pass%20word=1234" -> login; failed=query:next,header:x-csrf,form:username,form:pass%20word,form:remember,form:%C3%A9
      #|POST /login?next=/ [Content-Type: application/json] [X-Csrf: t] "username=alice&pass+word=12345678&%C3%A9" -> login; failed=form:username,form:pass%20word,form:remember,form:%C3%A9
    ),
  )
}

///|
test "the Near miss shows a failed form field as the Stub writes it, with every value the body carries for the field, none when it is absent or the body is not a form" {
  let h = harness([("m.json", form_login)])
  let csrf = ("X-Csrf", "t")
  json_inspect(
    explanation(
      h,
      "POST",
      "/login?next=/",
      headers=[("Content-Type", form_type), csrf],
      body="username=bob&remember=0&username=carol&remember=1&pass+word=a+b",
    ),
    content={
      "stub": "login",
      "stubSource": "file",
      "failed": [
        {
          "condition": "form:username",
          "expected": "alice",
          "actual": ["bob", "carol"],
        },
        {
          "condition": "form:pass word",
          "expected": { "pattern": ".{8,}" },
          "actual": ["a b"],
        },
        {
          "condition": "form:remember",
          "expected": { "$not": "1" },
          "actual": ["0", "1"],
        },
        {
          "condition": "form:é",
          "expected": { "$exists": true },
          "actual": [],
        },
      ],
    },
  )
  json_inspect(
    explanation(
      h,
      "POST",
      "/login?next=/",
      headers=[("Content-Type", "text/plain"), csrf],
      body="username=alice&pass+word=12345678&%C3%A9",
    ),
    content={
      "stub": "login",
      "stubSource": "file",
      "failed": [
        { "condition": "form:username", "expected": "alice", "actual": [] },
        {
          "condition": "form:pass word",
          "expected": { "pattern": ".{8,}" },
          "actual": [],
        },
        {
          "condition": "form:remember",
          "expected": { "$not": "1" },
          "actual": [],
        },
        {
          "condition": "form:é",
          "expected": { "$exists": true },
          "actual": [],
        },
      ],
    },
  )
}

///|
test "the Journal keeps the values of failed form fields up to its body limit in total, as it cuts the body, cutting the last one kept, and counts them as kept" {
  let h = harness(
    [("m.json", form_login)],
    journal=@engine.JournalSettings(body_limit=60),
  )
  let headers = [("Content-Type", form_type), ("X-Csrf", "t")]
  let body = (e : Int) => {
    "username=" +
    "b".repeat(20) +
    "&remember=" +
    "%C3%A9".repeat(e) +
    "&remember=1"
  }
  let _ = h.record(
    "POST",
    "/login?next=/",
    headers~,
    body=body(50),
    session="s",
  )
  // The username takes 20 bytes and 32 more, which leaves 8 bytes, four é,
  // of the first remember value, and none for the second.
  json_inspect(h.answered(Some("s")), content={
    "host": null,
    "mock": "m",
    "viaDefault": true,
    "stub": null,
    "nearMiss": {
      "stub": "login",
      "stubSource": "file",
      "failed": [
        {
          "condition": "form:username",
          "expected": "alice",
          "actual": ["bbbbbbbbbbbbbbbbbbbb"],
        },
        {
          "condition": "form:pass word",
          "expected": { "pattern": ".{8,}" },
          "actual": [],
        },
        {
          "condition": "form:remember",
          "expected": { "$not": "1" },
          "actual": ["éééé"],
        },
        {
          "condition": "form:é",
          "expected": { "$exists": true },
          "actual": [],
        },
      ],
    },
    "status": 404,
    "fault": null,
  })
  let one = h.stats()
  let _ = h.record(
    "POST",
    "/login?next=/",
    headers~,
    body=body(500),
    session="s",
  )
  inspect(
    "\{one}\n\{h.stats()}",
    content=(
      #|1 entries, 596 bytes, 0 evicted
      #|2 entries, 1192 bytes, 0 evicted
    ),
  )
}

///|
test "render lists the failed form fields of a sample request as the Near miss does" {
  let h = harness([("m.json", form_login)])
  inspect(
    [
      h.failed("login", {
        "method": "POST",
        "path": "/login",
        "query": { "next": "/" },
        "headers": { "X-Csrf": "t", "Content-Type": form_type },
        "body": "username=alice&username=bob&pass+word=x&remember=1",
      }),
      h.failed("login", {
        "method": "POST",
        "path": "/login",
        "query": { "next": "/" },
        "headers": { "X-Csrf": "t" },
        "body": "username=alice&pass+word=12345678&%C3%A9",
      }),
    ].join("\n--\n"),
    content=(
      #|form:pass word: expected {"pattern":".{8,}"}, actual ["x"]
      #|form:remember: expected {"$not":"1"}, actual ["1"]
      #|form:é: expected {"$exists":true}, actual []
      #|--
      #|form:username: expected "alice", actual []
      #|form:pass word: expected {"pattern":".{8,}"}, actual []
      #|form:remember: expected {"$not":"1"}, actual []
      #|form:é: expected {"$exists":true}, actual []
    ),
  )
}

///|
test "an Ephemeral Stub may have a form condition, and a malformed one is rejected with the messages a Definition file gets" {
  let h = harness(shop)
  let added = h.add(
    "users",
    Some("s"),
    (
      #|{ "request": { "method": "POST", "path": "/login",
      #|    "body": { "form": { "username": "alice", "remember": { "$exists": false } } } },
      #|  "response": { "status": 204 } }
    ),
  )
  let headers = [("Host", "users.svc"), ("Content-Type", form_type)]
  let out = [added]
  for body in ["username=alice", "username=alice&remember=1", "username=bob"] {
    let outcome = h.send("POST", "/login", headers~, body~, session="s")
    out.push("\{body} -> \{matched_id(outcome).unwrap_or("none")}")
  }
  out.push(
    h.problems(
      (
        #|{ "request": { "body": { "form": { "a": { "$nto": "1" } }, "pattern": "a=1" } },
        #|  "response": { "status": 200 } }
      ),
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|eph-1
      #|username=alice -> eph-1
      #|username=alice&remember=1 -> none
      #|username=bob -> none
      #|/request/body/form/a/$nto: is not an operator: the operators here are "$not" and "$exists"
      #|/request/body: has "pattern" and "form"; give only one of "json", "pattern", "form" or "xml"
    ),
  )
}
