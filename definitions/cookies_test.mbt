// Reading cookie conditions, `request.cookies`, and their part in the
// shadow warning.

///|
test "cookie conditions are read as the Schema defines them: names are literal, and values take every value condition" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "cookies": { "session": "abc", "Session": { "pattern": "sess_.*" },
          #|  "": "", "a b": "\"é\"", "$debug": { "$not": "1" }, "$$x": { "$exists": false } } }
        ),
      ),
      stub_with("empty", "\"request\": { \"cookies\": {} }"),
    ]),
    content="valid",
  )
}

///|
test "a malformed cookie condition is a diagnostic at its JSON Pointer, with the messages of query and header conditions" {
  inspect(
    stub_problems([
      stub_with("not-object", "\"request\": { \"cookies\": [\"session\"] }"),
      stub_with(
        "values",
        (
          #|"request": { "cookies": { "a": 1, "b": null, "c": { "pattern": "(" },
          #|  "d": { "regex": "x" }, "e": { "$nto": "1" }, "f": { "$includes": "x" },
          #|  "g": { "$exists": "yes" }, "h": { "$not": "1", "pattern": "2" } } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/cookies: must be an object
      #|a.json: /stubs/1/request/cookies/a: must be a string or an object
      #|a.json: /stubs/1/request/cookies/b: must be a string or an object
      #|a.json: /stubs/1/request/cookies/c/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/1/request/cookies/d/regex: is not a known field
      #|a.json: /stubs/1/request/cookies/d: needs "pattern"
      #|a.json: /stubs/1/request/cookies/e/$nto: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/1/request/cookies/f/$includes: is allowed only in a json condition
      #|a.json: /stubs/1/request/cookies/g/$exists: must be true or false
      #|a.json: /stubs/1/request/cookies/h/pattern: is not allowed beside "$not": an operator is the only key of its object
    ),
  )
}

///|
test "a cookie condition shadows only the same name with the same condition; one the later Stub lacks gives no warning" {
  inspect(
    verdicts([
      (
        "{ \"cookies\": { \"session\": { \"pattern\": \"sess_.*\" } } }", "{ \"path\": \"/a\", \"cookies\": { \"session\": { \"pattern\": \"sess_.*\" }, \"debug\": \"1\" } }",
      ),
      (
        "{ \"cookies\": { \"debug\": { \"$not\": \"1\" } } }", "{ \"cookies\": { \"debug\": { \"$not\": \"1\" } }, \"headers\": { \"X-A\": \"1\" } }",
      ),
      ("{ \"cookies\": { \"session\": \"a\" } }", "{ \"path\": \"/a\" }"),
      (
        "{ \"cookies\": { \"session\": \"a\" } }", "{ \"cookies\": { \"Session\": \"a\" } }",
      ),
      (
        "{ \"cookies\": { \"session\": \"a\" } }", "{ \"cookies\": { \"session\": \"b\" } }",
      ),
      (
        "{ \"cookies\": { \"session\": \"a\" } }", "{ \"headers\": { \"Cookie\": \"session=a\" } }",
      ),
      (
        "{ \"cookies\": { \"session\": \"a\" } }", "{ \"query\": { \"session\": \"a\" } }",
      ),
    ]),
    content=(
      #|t { "cookies": { "session": { "pattern": "sess_.*" } } } / s { "path": "/a", "cookies": { "session": { "pattern": "sess_.*" }, "debug": "1" } } -> shadowed
      #|t { "cookies": { "debug": { "$not": "1" } } } / s { "cookies": { "debug": { "$not": "1" } }, "headers": { "X-A": "1" } } -> shadowed
      #|t { "cookies": { "session": "a" } } / s { "path": "/a" } -> not reported
      #|t { "cookies": { "session": "a" } } / s { "cookies": { "Session": "a" } } -> not reported
      #|t { "cookies": { "session": "a" } } / s { "cookies": { "session": "b" } } -> not reported
      #|t { "cookies": { "session": "a" } } / s { "headers": { "Cookie": "session=a" } } -> not reported
      #|t { "cookies": { "session": "a" } } / s { "query": { "session": "a" } } -> not reported
    ),
  )
}
