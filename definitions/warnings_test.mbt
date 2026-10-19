// Seam 1 tests of the `check` warnings: a Stub is shadowed when an earlier
// Stub of the same Mock, in matching order, has a subset of its
// conditions, so it always matches first.

///|
/// Loads Definition files given as (name, text) pairs and renders every
/// warning, one per line, or `none`. Fails the test if the set is invalid.
fn warnings(files : Array[(String, String)]) -> String raise {
  let set : @definitions.DefinitionSet = {
    files: files.map(file => (file.0, @utf8.encode(file.1))),
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(snapshot) =>
      match snapshot.warnings() {
        [] => "none"
        warnings => warnings.map(w => w.to_string()).join("\n")
      }
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
}

///|
test "a Stub that an earlier Stub of its Mock always matches first gets one warning line with its file and JSON Pointer, naming that Stub" {
  inspect(
    warnings([
      (
        "users.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [
          #|    { "id": "any-user", "mock": "users",
          #|      "request": { "path": { "pattern": "/users/[0-9]+" } },
          #|      "response": { "status": 200 } },
          #|    { "id": "user-1", "mock": "users",
          #|      "request": { "method": "GET", "path": "/users/1" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content=(
      #|users.json: /stubs/1: warning: the Stub "user-1" can never match: the Stub "any-user" at users.json: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
/// For each pair of `request` objects, whether a Stub `s` with the second
/// is reported as shadowed by a Stub `t` with the first, declared before it
/// in the same Mock: one line per pair, `t <request> / s <request> ->
/// shadowed` or `-> not reported`.
fn verdicts(pairs : Array[(String, String)]) -> String raise {
  let lines = []
  for pair in pairs {
    let (t, s) = pair
    let file =
      $|{ "mocks": [{ "name": "m" }],
      $|  "stubs": [
      $|    { "id": "t", "mock": "m", "request": \{t}, "response": { "status": 200 } },
      $|    { "id": "s", "mock": "m", "request": \{s}, "response": { "status": 200 } } ] }
    let verdict = match warnings([("m.json", file)]) {
      "none" => "not reported"
      _ => "shadowed"
    }
    lines.push("t \{t} / s \{s} -> \{verdict}")
  }
  lines.join("\n")
}

///|
test "shadowing needs t's method to be absent or equal to s's" {
  inspect(
    verdicts([
      ("{}", "{ \"method\": \"GET\" }"),
      ("{ \"method\": \"GET\" }", "{ \"method\": \"GET\" }"),
      ("{ \"method\": \"GET\" }", "{ \"method\": \"POST\" }"),
      ("{ \"method\": \"GET\" }", "{ \"method\": \"get\" }"),
      ("{ \"method\": \"GET\" }", "{}"),
    ]),
    content=(
      #|t {} / s { "method": "GET" } -> shadowed
      #|t { "method": "GET" } / s { "method": "GET" } -> shadowed
      #|t { "method": "GET" } / s { "method": "POST" } -> not reported
      #|t { "method": "GET" } / s { "method": "get" } -> not reported
      #|t { "method": "GET" } / s {} -> not reported
    ),
  )
}

///|
test "shadowing needs t's path to be absent, equal to s's exact path, or a pattern that matches s's exact path" {
  inspect(
    verdicts([
      ("{}", "{ \"path\": \"/a\" }"),
      ("{}", "{ \"path\": { \"pattern\": \"/a.*\" } }"),
      ("{ \"path\": \"/a\" }", "{ \"path\": \"/a\" }"),
      ("{ \"path\": \"/a\" }", "{ \"path\": \"/A\" }"),
      ("{ \"path\": \"/a\" }", "{ \"path\": \"/a/\" }"),
      (
        "{ \"path\": { \"pattern\": \"/a/[0-9]+\" } }", "{ \"path\": \"/a/42\" }",
      ),
      (
        "{ \"path\": { \"pattern\": \"/a/[0-9]+\" } }", "{ \"path\": \"/a/42/b\" }",
      ),
      ("{ \"path\": { \"pattern\": \"/caf.\" } }", "{ \"path\": \"/café\" }"),
      ("{ \"path\": \"/a\" }", "{}"),
      ("{ \"path\": { \"pattern\": \".*\" } }", "{}"),
    ]),
    content=(
      #|t {} / s { "path": "/a" } -> shadowed
      #|t {} / s { "path": { "pattern": "/a.*" } } -> shadowed
      #|t { "path": "/a" } / s { "path": "/a" } -> shadowed
      #|t { "path": "/a" } / s { "path": "/A" } -> not reported
      #|t { "path": "/a" } / s { "path": "/a/" } -> not reported
      #|t { "path": { "pattern": "/a/[0-9]+" } } / s { "path": "/a/42" } -> shadowed
      #|t { "path": { "pattern": "/a/[0-9]+" } } / s { "path": "/a/42/b" } -> not reported
      #|t { "path": { "pattern": "/caf." } } / s { "path": "/café" } -> shadowed
      #|t { "path": "/a" } / s {} -> not reported
      #|t { "path": { "pattern": ".*" } } / s {} -> not reported
    ),
  )
}

///|
test "shadowing needs each of t's query conditions to appear identically in s" {
  inspect(
    verdicts([
      ("{}", "{ \"query\": { \"a\": \"1\" } }"),
      ("{ \"query\": { \"a\": \"1\" } }", "{ \"query\": { \"a\": \"1\" } }"),
      (
        "{ \"query\": { \"a\": \"1\" } }", "{ \"query\": { \"b\": \"2\", \"a\": \"1\" } }",
      ),
      (
        "{ \"query\": { \"a\": \"1\", \"b\": \"2\" } }", "{ \"query\": { \"a\": \"1\" } }",
      ),
      ("{ \"query\": { \"a\": \"1\" } }", "{ \"query\": { \"a\": \"2\" } }"),
      ("{ \"query\": { \"a\": \"1\" } }", "{ \"query\": { \"A\": \"1\" } }"),
      (
        "{ \"query\": { \"a\": { \"pattern\": \"[0-9]+\" } } }", "{ \"query\": { \"a\": { \"pattern\": \"[0-9]+\" } } }",
      ),
      ("{ \"query\": { \"a\": \"1\" } }", "{}"),
    ]),
    content=(
      #|t {} / s { "query": { "a": "1" } } -> shadowed
      #|t { "query": { "a": "1" } } / s { "query": { "a": "1" } } -> shadowed
      #|t { "query": { "a": "1" } } / s { "query": { "b": "2", "a": "1" } } -> shadowed
      #|t { "query": { "a": "1", "b": "2" } } / s { "query": { "a": "1" } } -> not reported
      #|t { "query": { "a": "1" } } / s { "query": { "a": "2" } } -> not reported
      #|t { "query": { "a": "1" } } / s { "query": { "A": "1" } } -> not reported
      #|t { "query": { "a": { "pattern": "[0-9]+" } } } / s { "query": { "a": { "pattern": "[0-9]+" } } } -> shadowed
      #|t { "query": { "a": "1" } } / s {} -> not reported
    ),
  )
}

///|
test "shadowing needs each of t's header conditions to appear identically in s, with names compared case-insensitively" {
  inspect(
    verdicts([
      ("{}", "{ \"headers\": { \"X-A\": \"1\" } }"),
      (
        "{ \"headers\": { \"X-A\": \"1\" } }", "{ \"headers\": { \"x-a\": \"1\" } }",
      ),
      (
        "{ \"headers\": { \"x-a\": \"1\" } }", "{ \"headers\": { \"Accept\": \"*/*\", \"X-A\": \"1\" } }",
      ),
      (
        "{ \"headers\": { \"X-A\": \"1\" } }", "{ \"headers\": { \"X-A\": \"one\" } }",
      ),
      (
        "{ \"headers\": { \"X-A\": \"a\" } }", "{ \"headers\": { \"X-A\": \"A\" } }",
      ),
      (
        "{ \"headers\": { \"X-A\": \"1\" } }", "{ \"headers\": { \"X-B\": \"1\" } }",
      ),
      (
        "{ \"headers\": { \"X-A\": { \"pattern\": \"[a-z]+\" } } }", "{ \"headers\": { \"x-a\": { \"pattern\": \"[a-z]+\" } } }",
      ),
      (
        "{ \"headers\": { \"X-A\": \"1\" } }", "{ \"query\": { \"X-A\": \"1\" } }",
      ),
    ]),
    content=(
      #|t {} / s { "headers": { "X-A": "1" } } -> shadowed
      #|t { "headers": { "X-A": "1" } } / s { "headers": { "x-a": "1" } } -> shadowed
      #|t { "headers": { "x-a": "1" } } / s { "headers": { "Accept": "*/*", "X-A": "1" } } -> shadowed
      #|t { "headers": { "X-A": "1" } } / s { "headers": { "X-A": "one" } } -> not reported
      #|t { "headers": { "X-A": "a" } } / s { "headers": { "X-A": "A" } } -> not reported
      #|t { "headers": { "X-A": "1" } } / s { "headers": { "X-B": "1" } } -> not reported
      #|t { "headers": { "X-A": { "pattern": "[a-z]+" } } } / s { "headers": { "x-a": { "pattern": "[a-z]+" } } } -> shadowed
      #|t { "headers": { "X-A": "1" } } / s { "query": { "X-A": "1" } } -> not reported
    ),
  )
}

///|
test "shadowing needs t's body condition to be absent or to appear identically in s" {
  inspect(
    verdicts([
      ("{}", "{ \"body\": \"x\" }"),
      ("{ \"body\": \"x\" }", "{ \"body\": \"x\" }"),
      ("{ \"body\": \"x\" }", "{ \"body\": \"y\" }"),
      (
        "{ \"body\": { \"pattern\": \"[a-z]+\" } }", "{ \"body\": { \"pattern\": \"[a-z]+\" } }",
      ),
      (
        "{ \"body\": { \"json\": { \"a\": [1, true] } } }", "{ \"body\": { \"json\": { \"a\": [1, true] } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"a\": 1 } } }", "{ \"body\": { \"json\": { \"a\": 2 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"a\": 1 } } }", "{ \"body\": { \"json\": { \"a\": 1.0 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"id\": 9007199254740993 } } }", "{ \"body\": { \"json\": { \"id\": 9007199254740992 } } }",
      ),
      ("{ \"body\": { \"json\": \"x\" } }", "{ \"body\": \"x\" }"),
      ("{ \"body\": \"x\" }", "{}"),
    ]),
    content=(
      #|t {} / s { "body": "x" } -> shadowed
      #|t { "body": "x" } / s { "body": "x" } -> shadowed
      #|t { "body": "x" } / s { "body": "y" } -> not reported
      #|t { "body": { "pattern": "[a-z]+" } } / s { "body": { "pattern": "[a-z]+" } } -> shadowed
      #|t { "body": { "json": { "a": [1, true] } } } / s { "body": { "json": { "a": [1, true] } } } -> shadowed
      #|t { "body": { "json": { "a": 1 } } } / s { "body": { "json": { "a": 2 } } } -> not reported
      #|t { "body": { "json": { "a": 1 } } } / s { "body": { "json": { "a": 1.0 } } } -> shadowed
      #|t { "body": { "json": { "id": 9007199254740993 } } } / s { "body": { "json": { "id": 9007199254740992 } } } -> not reported
      #|t { "body": { "json": "x" } } / s { "body": "x" } -> not reported
      #|t { "body": "x" } / s {} -> not reported
    ),
  )
}

///|
/// Matching compares an integer above 2^53 in a body with one in a
/// condition by its digits, and with any other number by its Double. So
/// `12345678901234567890` and `1.2345678901234567890e19`, equal as
/// Doubles, match different bodies: `12345678901234567891` meets only the
/// second.
test "a json condition's integer above 2^53 shadows only the same integer, not a number written with a fraction or an exponent that has its Double" {
  inspect(
    verdicts([
      (
        "{ \"body\": { \"json\": { \"id\": 12345678901234567890 } } }", "{ \"body\": { \"json\": { \"id\": 1.2345678901234567890e19 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"id\": 1.2345678901234567890e19 } } }", "{ \"body\": { \"json\": { \"id\": 12345678901234567890 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"id\": 12345678901234567890 } } }", "{ \"body\": { \"json\": { \"id\": 12345678901234567890 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"id\": 1.2345678901234567890e19 } } }", "{ \"body\": { \"json\": { \"id\": 12345678901234567000.0 } } }",
      ),
      (
        "{ \"body\": { \"json\": [1e3, 0] } }", "{ \"body\": { \"json\": [1000, -0] } }",
      ),
    ]),
    content=(
      #|t { "body": { "json": { "id": 12345678901234567890 } } } / s { "body": { "json": { "id": 1.2345678901234567890e19 } } } -> not reported
      #|t { "body": { "json": { "id": 1.2345678901234567890e19 } } } / s { "body": { "json": { "id": 12345678901234567890 } } } -> not reported
      #|t { "body": { "json": { "id": 12345678901234567890 } } } / s { "body": { "json": { "id": 12345678901234567890 } } } -> shadowed
      #|t { "body": { "json": { "id": 1.2345678901234567890e19 } } } / s { "body": { "json": { "id": 12345678901234567000.0 } } } -> shadowed
      #|t { "body": { "json": [1e3, 0] } } / s { "body": { "json": [1000, -0] } } -> shadowed
    ),
  )
}

///|
test "every condition of t must be in s for a warning" {
  inspect(
    verdicts([
      (
        (
          #|{ "method": "POST", "path": { "pattern": "/orders/.*" },
          #|  "query": { "dry": "yes" }, "headers": { "X-Tenant": "acme" },
          #|  "body": { "json": { "item": "tea" } } }
        ),
        (
          #|{ "method": "POST", "path": "/orders/1",
          #|  "query": { "dry": "yes", "page": "2" }, "headers": { "x-tenant": "acme", "Accept": "*/*" },
          #|  "body": { "json": { "item": "tea" } } }
        ),
      ),
      (
        (
          #|{ "method": "POST", "path": { "pattern": "/orders/.*" },
          #|  "query": { "dry": "yes" }, "headers": { "X-Tenant": "acme" },
          #|  "body": { "json": { "item": "tea" } } }
        ),
        (
          #|{ "method": "POST", "path": "/orders/1",
          #|  "query": { "dry": "yes", "page": "2" }, "headers": { "x-tenant": "acme", "Accept": "*/*" },
          #|  "body": { "json": { "item": "coffee" } } }
        ),
      ),
    ]),
    content=(
      #|t { "method": "POST", "path": { "pattern": "/orders/.*" },
      #|  "query": { "dry": "yes" }, "headers": { "X-Tenant": "acme" },
      #|  "body": { "json": { "item": "tea" } } } / s { "method": "POST", "path": "/orders/1",
      #|  "query": { "dry": "yes", "page": "2" }, "headers": { "x-tenant": "acme", "Accept": "*/*" },
      #|  "body": { "json": { "item": "tea" } } } -> shadowed
      #|t { "method": "POST", "path": { "pattern": "/orders/.*" },
      #|  "query": { "dry": "yes" }, "headers": { "X-Tenant": "acme" },
      #|  "body": { "json": { "item": "tea" } } } / s { "method": "POST", "path": "/orders/1",
      #|  "query": { "dry": "yes", "page": "2" }, "headers": { "x-tenant": "acme", "Accept": "*/*" },
      #|  "body": { "json": { "item": "coffee" } } } -> not reported
    ),
  )
}

///|
test "what the subset test cannot prove is not reported: containment between two patterns, or between a pattern or json condition and another condition" {
  inspect(
    verdicts([
      // Every path s matches, t matches too, but that takes comparing two
      // patterns. Identical path patterns are not compared either: only an
      // exact path of s is.
      (
        "{ \"path\": { \"pattern\": \"/a/.*\" } }", "{ \"path\": { \"pattern\": \"/a/[0-9]+\" } }",
      ),
      (
        "{ \"path\": { \"pattern\": \"/a/[0-9]+\" } }", "{ \"path\": { \"pattern\": \"/a/[0-9]+\" } }",
      ),
      // An exact path of t never covers a pattern of s.
      ("{ \"path\": \"/a/1\" }", "{ \"path\": { \"pattern\": \"/a/1\" } }"),
      // Query, header and body conditions must be identical, even where t's
      // pattern matches s's exact value or t's json is contained in s's.
      (
        "{ \"query\": { \"a\": { \"pattern\": \"[0-9]+\" } } }", "{ \"query\": { \"a\": \"1\" } }",
      ),
      (
        "{ \"query\": { \"a\": { \"pattern\": \".*\" } } }", "{ \"query\": { \"a\": { \"pattern\": \"[0-9]+\" } } }",
      ),
      (
        "{ \"headers\": { \"X-A\": { \"pattern\": \".*\" } } }", "{ \"headers\": { \"X-A\": \"1\" } }",
      ),
      ("{ \"body\": { \"pattern\": \"(?s).*\" } }", "{ \"body\": \"x\" }"),
      (
        "{ \"body\": { \"json\": { \"a\": 1 } } }", "{ \"body\": { \"json\": { \"a\": 1, \"b\": 2 } } }",
      ),
    ]),
    content=(
      #|t { "path": { "pattern": "/a/.*" } } / s { "path": { "pattern": "/a/[0-9]+" } } -> not reported
      #|t { "path": { "pattern": "/a/[0-9]+" } } / s { "path": { "pattern": "/a/[0-9]+" } } -> not reported
      #|t { "path": "/a/1" } / s { "path": { "pattern": "/a/1" } } -> not reported
      #|t { "query": { "a": { "pattern": "[0-9]+" } } } / s { "query": { "a": "1" } } -> not reported
      #|t { "query": { "a": { "pattern": ".*" } } } / s { "query": { "a": { "pattern": "[0-9]+" } } } -> not reported
      #|t { "headers": { "X-A": { "pattern": ".*" } } } / s { "headers": { "X-A": "1" } } -> not reported
      #|t { "body": { "pattern": "(?s).*" } } / s { "body": "x" } -> not reported
      #|t { "body": { "json": { "a": 1 } } } / s { "body": { "json": { "a": 1, "b": 2 } } } -> not reported
    ),
  )
}

///|
test "an operator on a query or header value shadows only the same operator, written the same way; one the later Stub lacks gives no warning" {
  inspect(
    verdicts([
      (
        "{ \"headers\": { \"Authorization\": { \"$not\": { \"pattern\": \"Bearer .*\" } } } }",
        "{ \"path\": \"/a\", \"headers\": { \"authorization\": { \"$not\": { \"pattern\": \"Bearer .*\" } } } }",
      ),
      (
        "{ \"query\": { \"a\": { \"$exists\": false } } }", "{ \"path\": \"/a\" }",
      ),
      (
        "{ \"query\": { \"a\": { \"$not\": \"1\" } } }", "{ \"query\": { \"b\": { \"$not\": \"1\" } } }",
      ),
      (
        "{ \"query\": { \"a\": { \"$not\": \"1\" } } }", "{ \"query\": { \"a\": \"1\" } }",
      ),
      (
        "{ \"query\": { \"a\": \"1\" } }", "{ \"query\": { \"a\": { \"$not\": \"1\" } } }",
      ),
      (
        "{ \"query\": { \"a\": { \"$not\": \"1\" } } }", "{ \"query\": { \"a\": { \"$not\": { \"pattern\": \"1\" } } } }",
      ),
      (
        "{ \"query\": { \"a\": { \"$exists\": true } } }", "{ \"query\": { \"a\": { \"$exists\": false } } }",
      ),
      (
        "{ \"query\": { \"a\": { \"$exists\": true } } }", "{ \"query\": { \"a\": { \"$exists\": true }, \"b\": \"2\" } }",
      ),
      (
        "{ \"headers\": { \"X-A\": { \"$not\": { \"$not\": \"1\" } } } }", "{ \"headers\": { \"X-A\": \"1\" } }",
      ),
    ]),
    content=(
      #|t { "headers": { "Authorization": { "$not": { "pattern": "Bearer .*" } } } } / s { "path": "/a", "headers": { "authorization": { "$not": { "pattern": "Bearer .*" } } } } -> shadowed
      #|t { "query": { "a": { "$exists": false } } } / s { "path": "/a" } -> not reported
      #|t { "query": { "a": { "$not": "1" } } } / s { "query": { "b": { "$not": "1" } } } -> not reported
      #|t { "query": { "a": { "$not": "1" } } } / s { "query": { "a": "1" } } -> not reported
      #|t { "query": { "a": "1" } } / s { "query": { "a": { "$not": "1" } } } -> not reported
      #|t { "query": { "a": { "$not": "1" } } } / s { "query": { "a": { "$not": { "pattern": "1" } } } } -> not reported
      #|t { "query": { "a": { "$exists": true } } } / s { "query": { "a": { "$exists": false } } } -> not reported
      #|t { "query": { "a": { "$exists": true } } } / s { "query": { "a": { "$exists": true }, "b": "2" } } -> shadowed
      #|t { "headers": { "X-A": { "$not": { "$not": "1" } } } } / s { "headers": { "X-A": "1" } } -> not reported
    ),
  )
}

///|
test "a json condition with patterns shadows only one written the same way, patterns included" {
  inspect(
    verdicts([
      (
        (
          #|{ "body": { "json": { "email": { "pattern": ".*@example\\.com" }, "tags": [{ "pattern": "[a-z]+" }] } } }
        ),
        (
          #|{ "body": { "json": { "tags": [{ "pattern": "[a-z]+" }], "email": { "pattern": ".*@example\\.com" } } } }
        ),
      ),
      // t's pattern matches s's string, but a pattern is not compared with
      // another condition.
      (
        "{ \"body\": { \"json\": { \"email\": { \"pattern\": \".*\" } } } }", "{ \"body\": { \"json\": { \"email\": \"a@example.com\" } } }",
      ),
      // Two patterns that match the same values are not compared either.
      (
        "{ \"body\": { \"json\": { \"n\": { \"pattern\": \"[0-9]\" } } } }", "{ \"body\": { \"json\": { \"n\": { \"pattern\": \"\\\\d\" } } } }",
      ),
      // Read as literal JSON, t would be contained in s; but t's member is a
      // pattern, which never matches s's object.
      (
        "{ \"body\": { \"json\": { \"a\": { \"pattern\": \"x\" } } } }", "{ \"body\": { \"json\": { \"a\": { \"pattern\": \"x\", \"b\": 1 } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"a\": { \"pattern\": \"x\" } } } }", "{ \"body\": { \"json\": { \"a\": { \"pattern\": \"y\" } } } }",
      ),
    ]),
    content=(
      #|t { "body": { "json": { "email": { "pattern": ".*@example\\.com" }, "tags": [{ "pattern": "[a-z]+" }] } } } / s { "body": { "json": { "tags": [{ "pattern": "[a-z]+" }], "email": { "pattern": ".*@example\\.com" } } } } -> shadowed
      #|t { "body": { "json": { "email": { "pattern": ".*" } } } } / s { "body": { "json": { "email": "a@example.com" } } } -> not reported
      #|t { "body": { "json": { "n": { "pattern": "[0-9]" } } } } / s { "body": { "json": { "n": { "pattern": "\\d" } } } } -> not reported
      #|t { "body": { "json": { "a": { "pattern": "x" } } } } / s { "body": { "json": { "a": { "pattern": "x", "b": 1 } } } } -> not reported
      #|t { "body": { "json": { "a": { "pattern": "x" } } } } / s { "body": { "json": { "a": { "pattern": "y" } } } } -> not reported
    ),
  )
}

///|
/// A Stub of the Mock `mock` with `fields` added, such as `"priority": 1`,
/// that matches `GET /a`.
fn get_a(id : String, mock? : String = "m", fields? : String = "") -> String {
  let fields = if fields == "" { "" } else { ", \{fields}" }
  (
    $|{ "id": "\{id}", "mock": "\{mock}"\{fields},
    $|  "request": { "method": "GET", "path": "/a" }, "response": { "status": 200 } }
  )
}

///|
test "earlier means earlier in matching order: by priority, then file-name order, then position in the file" {
  let file = (name : String, stubs : Array[String]) => {
    (name, "{ \"stubs\": [\{stubs.join(", ")}] }")
  }
  let mocks = ("0-mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }")
  inspect(
    [
      // Position in the file.
      warnings([mocks, file("a.json", [get_a("first"), get_a("second")])]),
      // File-name order, whatever order the files are given in.
      warnings([
        mocks,
        file("b.json", [get_a("in-b")]),
        file("a.json", [get_a("in-a")]),
      ]),
      // Priority, wherever the Stub is declared.
      warnings([
        mocks,
        file("a.json", [get_a("plain")]),
        file("b.json", [get_a("prioritised", fields="\"priority\": 1")]),
      ]),
    ].join("\n---\n"),
    content=(
      #|a.json: /stubs/1: warning: the Stub "second" can never match: the Stub "first" at a.json: /stubs/0 is tried first and matches every request this one would
      #|---
      #|b.json: /stubs/0: warning: the Stub "in-b" can never match: the Stub "in-a" at a.json: /stubs/0 is tried first and matches every request this one would
      #|---
      #|a.json: /stubs/0: warning: the Stub "plain" can never match: the Stub "prioritised" at b.json: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
test "a Stub is only shadowed by a Stub of its own Mock" {
  inspect(
    warnings([
      (
        "a.json",
        (
          $|{ "mocks": [{ "name": "m", "hosts": ["m.example"] },
          $|    { "name": "n", "hosts": ["n.example"] }],
          $|  "stubs": [\{get_a("of-m")}, \{get_a("of-n", mock="n")}] }
        ),
      ),
    ]),
    content="none",
  )
}

///|
test "each shadowed Stub gets one warning, naming the first Stub in matching order that shadows it" {
  inspect(
    warnings([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "get", "mock": "m", "request": { "method": "GET" }, "response": { "status": 200 } },
          #|    { "id": "any", "mock": "m", "response": { "status": 200 } },
          #|    { "id": "get-a", "mock": "m", "request": { "method": "GET", "path": "/a" },
          #|      "response": { "status": 200 } },
          #|    { "id": "post-a", "mock": "m", "request": { "method": "POST", "path": "/a" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/2: warning: the Stub "get-a" can never match: the Stub "get" at a.json: /stubs/0 is tried first and matches every request this one would
      #|a.json: /stubs/3: warning: the Stub "post-a" can never match: the Stub "any" at a.json: /stubs/1 is tried first and matches every request this one would
    ),
  )
}

///|
test "a warning is one line, whatever the Stub IDs and file names hold" {
  inspect(
    warnings([
      (
        "new\nline.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "a\nb", "mock": "m", "response": { "status": 200 } },
          #|    { "id": "c d", "mock": "m", "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content=(
      #|new\nline.json: /stubs/1: warning: the Stub "c\u{2028}d" can never match: the Stub "a\nb" at new\nline.json: /stubs/0 is tried first and matches every request this one would
    ),
  )
}

///|
test "a valid set without shadowed Stubs has no warnings" {
  inspect(
    warnings([
      (
        "a.json",
        (
          $|{ "mocks": [{ "name": "m" }],
          $|  "stubs": [\{get_a("get-a")},
          $|    { "id": "get-b", "mock": "m", "request": { "method": "GET", "path": "/b" },
          $|      "response": { "status": 200 } }] }
        ),
      ),
    ]),
    content="none",
  )
  inspect(warnings([]), content="none")
}

///|
/// The example of spec #48: `GET /orders/42` answers pending until `POST
/// /orders/42/pay` moves the Scenario `checkout` to `Paid`, and paid after.
let checkout : String =
  #|{ "mocks": [{ "name": "payments" }],
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

///|
test "a Stub gated on one state of a Scenario does not shadow a later Stub with the same request that requires another state: the checkout example has no warnings" {
  inspect(warnings([("payments.json", checkout)]), content="none")
}

///|
/// For each pair of `scenario` clauses, `none` for a Stub without one,
/// whether a Stub `s` with the second is reported as shadowed by a Stub `t`
/// with the first, declared before it in the same Mock, with the same
/// request: one line per pair, `t <clause> / s <clause> -> shadowed` or
/// `-> not reported`.
fn scenario_verdicts(pairs : Array[(String, String)]) -> String raise {
  let stub = (id : String, clause : String) => {
    let clause = if clause == "none" { "" } else { "\"scenario\": \{clause}, " }
    (
      $|{ "id": "\{id}", "mock": "m", "request": { "method": "GET", "path": "/a" },
      $|  \{clause}"response": { "status": 200 } }
    )
  }
  let lines = []
  for pair in pairs {
    let (t, s) = pair
    let file =
      $|{ "mocks": [{ "name": "m" }],
      $|  "stubs": [\{stub("t", t)}, \{stub("s", s)}] }
    let set : @definitions.DefinitionSet = {
      files: [("m.json", @utf8.encode(file))],
      body_files: [],
    }
    let snapshot = match @definitions.load(set) {
      Ok(snapshot) => snapshot
      Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
    }
    // A shadowed Stub's warning points at the Stub itself.
    let shadowed = snapshot.warnings().iter().any(w => w.pointer == "/stubs/1")
    let verdict = if shadowed { "shadowed" } else { "not reported" }
    lines.push("t \{t} / s \{s} -> \{verdict}")
  }
  lines.join("\n")
}

///|
test "with the same request, t shadows s when t has no requires, or when s requires the same state of the same Scenario; moveTo plays no part" {
  inspect(
    scenario_verdicts([
      ("none", "{ \"name\": \"checkout\", \"requires\": \"Paid\" }"),
      (
        "{ \"name\": \"checkout\", \"moveTo\": \"Paid\" }", "{ \"name\": \"checkout\", \"requires\": \"Paid\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "{ \"name\": \"checkout\", \"requires\": \"Paid\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Started\" }", "{ \"name\": \"checkout\", \"requires\": \"Started\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "{ \"name\": \"checkout\", \"requires\": \"Paid\", \"moveTo\": \"Shipped\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\", \"moveTo\": \"Shipped\" }",
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Started\" }", "{ \"name\": \"checkout\", \"requires\": \"Paid\" }",
      ),
      ("{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "none"),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "{ \"name\": \"checkout\", \"moveTo\": \"Paid\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "{ \"name\": \"refund\", \"requires\": \"Paid\" }",
      ),
      (
        "{ \"name\": \"checkout\", \"requires\": \"Paid\" }", "{ \"name\": \"checkout\", \"requires\": \"paid\" }",
      ),
    ]),
    content=(
      #|t none / s { "name": "checkout", "requires": "Paid" } -> shadowed
      #|t { "name": "checkout", "moveTo": "Paid" } / s { "name": "checkout", "requires": "Paid" } -> shadowed
      #|t { "name": "checkout", "requires": "Paid" } / s { "name": "checkout", "requires": "Paid" } -> shadowed
      #|t { "name": "checkout", "requires": "Started" } / s { "name": "checkout", "requires": "Started" } -> shadowed
      #|t { "name": "checkout", "requires": "Paid" } / s { "name": "checkout", "requires": "Paid", "moveTo": "Shipped" } -> shadowed
      #|t { "name": "checkout", "requires": "Paid", "moveTo": "Shipped" } / s { "name": "checkout", "requires": "Paid" } -> shadowed
      #|t { "name": "checkout", "requires": "Started" } / s { "name": "checkout", "requires": "Paid" } -> not reported
      #|t { "name": "checkout", "requires": "Paid" } / s none -> not reported
      #|t { "name": "checkout", "requires": "Paid" } / s { "name": "checkout", "moveTo": "Paid" } -> not reported
      #|t { "name": "checkout", "requires": "Paid" } / s { "name": "refund", "requires": "Paid" } -> not reported
      #|t { "name": "checkout", "requires": "Paid" } / s { "name": "checkout", "requires": "paid" } -> not reported
    ),
  )
}

///|
test "a Stub that requires a state no Stub of its Mock and Scenario moves to gets a warning, as a fact, at its requires" {
  inspect(
    warnings([
      (
        "payments.json",
        checkout.replace(
          old="\"requires\": \"Paid\"",
          new="\"requires\": \"Payed\"",
        ),
      ),
    ]),
    content=(
      #|payments.json: /stubs/2/scenario/requires: warning: the Stub "order-paid" requires the state "Payed" of the Scenario "checkout", but no Stub in the Definition files moves "checkout" to "Payed"; only the Admin API or an Ephemeral Stub can
    ),
  )
}

///|
test "Started, which every Scenario starts in, and states that only moveTo names are never reported" {
  inspect(
    warnings([
      (
        "m.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "start", "mock": "m", "request": { "path": "/start" },
          #|      "scenario": { "name": "visit", "requires": "Started", "moveTo": "Done" },
          #|      "response": { "status": 200 } },
          #|    { "id": "logout", "mock": "m", "request": { "path": "/logout" },
          #|      "scenario": { "name": "visit", "moveTo": "Started" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content="none",
  )
}

///|
test "only a moveTo of a Stub of the same Mock and Scenario counts, in any file and anywhere in matching order, and state names compare byte for byte" {
  inspect(
    warnings([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "payments", "hosts": ["payments.svc"] },
          #|    { "name": "refunds", "hosts": ["refunds.svc"] }],
          #|  "stubs": [
          #|    { "id": "shipped", "mock": "payments", "request": { "path": "/shipped" },
          #|      "scenario": { "name": "checkout", "requires": "Shipped" },
          #|      "response": { "status": 200 } },
          #|    { "id": "refunded", "mock": "payments", "request": { "path": "/refunded" },
          #|      "scenario": { "name": "checkout", "requires": "Refunded" },
          #|      "response": { "status": 200 } },
          #|    { "id": "cancelled", "mock": "payments", "request": { "path": "/cancelled" },
          #|      "scenario": { "name": "checkout", "requires": "cancelled" },
          #|      "response": { "status": 200 } },
          #|    { "id": "retried", "mock": "payments", "request": { "path": "/retried" },
          #|      "scenario": { "name": "checkout", "requires": "Retried", "moveTo": "Retried" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
      (
        "b.json",
        (
          #|{ "stubs": [
          #|    { "id": "ship", "mock": "payments", "request": { "path": "/ship" },
          #|      "scenario": { "name": "checkout", "moveTo": "Shipped" },
          #|      "response": { "status": 200 } },
          #|    { "id": "refund-elsewhere", "mock": "refunds", "request": { "path": "/refund" },
          #|      "scenario": { "name": "checkout", "moveTo": "Refunded" },
          #|      "response": { "status": 200 } },
          #|    { "id": "refund-other-scenario", "mock": "payments", "request": { "path": "/refund" },
          #|      "scenario": { "name": "refund", "moveTo": "Refunded" },
          #|      "response": { "status": 200 } },
          #|    { "id": "cancel", "mock": "payments", "request": { "path": "/cancel" },
          #|      "scenario": { "name": "checkout", "moveTo": "Cancelled" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    // `retried` moves `checkout` to the state it requires, so a Stub in the
    // files does move `checkout` there, once it is there.
    content=(
      #|a.json: /stubs/1/scenario/requires: warning: the Stub "refunded" requires the state "Refunded" of the Scenario "checkout", but no Stub in the Definition files moves "checkout" to "Refunded"; only the Admin API or an Ephemeral Stub can
      #|a.json: /stubs/2/scenario/requires: warning: the Stub "cancelled" requires the state "cancelled" of the Scenario "checkout", but no Stub in the Definition files moves "checkout" to "cancelled"; only the Admin API or an Ephemeral Stub can
    ),
  )
}

///|
test "a shadowed Stub that also requires a state no Stub moves to gets both warnings, the one at the Stub first, and each is one line whatever the names hold" {
  inspect(
    warnings([
      (
        "m.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "any", "mock": "m", "response": { "status": 200 } },
          #|    { "id": "paid", "mock": "m", "request": { "path": "/a" },
          #|      "scenario": { "name": "check\nout", "requires": "Pa id" },
          #|      "response": { "status": 200 } } ] }
        ),
      ),
    ]),
    content=(
      #|m.json: /stubs/1: warning: the Stub "paid" can never match: the Stub "any" at m.json: /stubs/0 is tried first and matches every request this one would
      #|m.json: /stubs/1/scenario/requires: warning: the Stub "paid" requires the state "Pa\u{2028}id" of the Scenario "check\nout", but no Stub in the Definition files moves "check\nout" to "Pa\u{2028}id"; only the Admin API or an Ephemeral Stub can
    ),
  )
}
