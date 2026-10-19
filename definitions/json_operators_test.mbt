// Reading the operators inside a `json` condition: at any value position,
// an object whose only key starts with `$` is an operator, and `$$name`
// writes a literal key that starts with `$`.

///|
test "$not, $exists and $includes in a json condition are read at any value position, and nest" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "body": { "json": {
          #|  "tags": { "$includes": "urgent" }, "items": { "$not": [] },
          #|  "coupon": { "$exists": true }, "gift": { "$exists": false },
          #|  "lines": [{ "$not": { "$includes": { "sku": { "pattern": "A-.*" } } } }],
          #|  "notes": { "$includes": { "$not": null } } } } }
        ),
      ),
      stub_with(
        "root", "\"request\": { \"body\": { \"json\": { \"$exists\": true } } }",
      ),
      stub_with(
        "literal",
        (
          #|"request": { "body": { "json": { "$$ref": "#/a", "$$": { "$$not": 1 },
          #|  "a$": "b", "pattern": { "$$x": 1 } } } }
        ),
      ),
    ]),
    content="valid",
  )
}

///|
test "a malformed operator in a json condition is a diagnostic at its JSON Pointer, and an unknown $ key suggests $$ for a literal key" {
  inspect(
    stub_problems([
      stub_with(
        "unknown",
        (
          #|"request": { "body": { "json": { "a": { "$nto": 1 },
          #|  "b": [{ "$ref": "#/x" }], "c": { "$not": { "$regex": "x" } } } } }
        ),
      ),
      stub_with(
        "beside",
        (
          #|"request": { "body": { "json": { "a": { "$not": 1, "b": 2 },
          #|  "c": { "pattern": "x", "$includes": "y" },
          #|  "d": { "$exists": true, "$not": 1 } } } }
        ),
      ),
      stub_with(
        "exists",
        (
          #|"request": { "body": { "json": { "a": { "$exists": "true" },
          #|  "b": { "$includes": { "$exists": null } } } } }
        ),
      ),
      stub_with(
        "operand",
        (
          #|"request": { "body": { "json": { "a": { "$not": { "pattern": "(" } },
          #|  "b": { "$includes": [{ "$nope": 1 }] } } } }
        ),
      ),
      stub_with(
        "root", "\"request\": { \"body\": { \"json\": { \"$schema\": \"x\" } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/json/a/$nto: is not an operator: the operators here are $not, $exists, $includes; write $$nto for a literal key that starts with $
      #|a.json: /stubs/0/request/body/json/b/0/$ref: is not an operator: the operators here are $not, $exists, $includes; write $$ref for a literal key that starts with $
      #|a.json: /stubs/0/request/body/json/c/$not/$regex: is not an operator: the operators here are $not, $exists, $includes; write $$regex for a literal key that starts with $
      #|a.json: /stubs/1/request/body/json/a/b: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/1/request/body/json/c/pattern: is not allowed beside "$includes": an operator is the only key of its object
      #|a.json: /stubs/1/request/body/json/d/$not: is not allowed beside "$exists": an operator is the only key of its object
      #|a.json: /stubs/2/request/body/json/a/$exists: must be true or false
      #|a.json: /stubs/2/request/body/json/b/$includes/$exists: must be true or false
      #|a.json: /stubs/3/request/body/json/a/$not/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/3/request/body/json/b/$includes/0/$nope: is not an operator: the operators here are $not, $exists, $includes; write $$nope for a literal key that starts with $
      #|a.json: /stubs/4/request/body/json/$schema: is not an operator: the operators here are $not, $exists, $includes; write $$schema for a literal key that starts with $
    ),
  )
}

///|
test "unknown $ keys beside literal keys are each reported, and nothing else, as in a v1 literal object such as a JSON Schema" {
  inspect(
    stub_problems([
      stub_with(
        "v1",
        (
          #|"request": { "body": { "json": {
          #|  "schema": { "$id": "x", "type": "object", "$schema": "y", "$$z": 1 } } } }
        ),
      ),
      stub_with(
        "query", "\"request\": { \"query\": { \"q\": { \"$nto\": \"1\", \"pattern\": \"x\" } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/json/schema/$id: is not an operator: the operators here are $not, $exists, $includes; write $$id for a literal key that starts with $
      #|a.json: /stubs/0/request/body/json/schema/$schema: is not an operator: the operators here are $not, $exists, $includes; write $$schema for a literal key that starts with $
      #|a.json: /stubs/1/request/query/q/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
    ),
  )
}

///|
test "a json condition with operators shadows only one written the same way, operators and $$ keys included" {
  inspect(
    verdicts([
      (
        (
          #|{ "body": { "json": { "tags": { "$includes": { "$not": "a" } }, "items": { "$not": [] }, "$$ref": { "$exists": true } } } }
        ),
        (
          #|{ "path": "/a", "body": { "json": { "$$ref": { "$exists": true }, "items": { "$not": [] }, "tags": { "$includes": { "$not": "a" } } } } }
        ),
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$not\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$not\": 1.0 } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$not\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$not\": 2 } } } }",
      ),
      // t holds for every body s meets, but operators are not reasoned about.
      (
        "{ \"body\": { \"json\": { \"n\": { \"$exists\": true } } } }", "{ \"body\": { \"json\": { \"n\": 1 } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$includes\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": [1] } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$exists\": true } } } }", "{ \"body\": { \"json\": { \"n\": { \"$exists\": false } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"$$n\": 1 } } }", "{ \"body\": { \"json\": { \"$$n\": 1, \"m\": 2 } } }",
      ),
    ]),
    content=(
      #|t { "body": { "json": { "tags": { "$includes": { "$not": "a" } }, "items": { "$not": [] }, "$$ref": { "$exists": true } } } } / s { "path": "/a", "body": { "json": { "$$ref": { "$exists": true }, "items": { "$not": [] }, "tags": { "$includes": { "$not": "a" } } } } } -> shadowed
      #|t { "body": { "json": { "n": { "$not": 1 } } } } / s { "body": { "json": { "n": { "$not": 1.0 } } } } -> shadowed
      #|t { "body": { "json": { "n": { "$not": 1 } } } } / s { "body": { "json": { "n": { "$not": 2 } } } } -> not reported
      #|t { "body": { "json": { "n": { "$exists": true } } } } / s { "body": { "json": { "n": 1 } } } -> not reported
      #|t { "body": { "json": { "n": { "$includes": 1 } } } } / s { "body": { "json": { "n": [1] } } } -> not reported
      #|t { "body": { "json": { "n": { "$exists": true } } } } / s { "body": { "json": { "n": { "$exists": false } } } } -> not reported
      #|t { "body": { "json": { "$$n": 1 } } } / s { "body": { "json": { "$$n": 1, "m": 2 } } } -> not reported
    ),
  )
}
