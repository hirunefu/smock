// Reading the operators inside a `json` condition: at any value position,
// an object whose only key starts with `$` is an operator, and `$$name`
// writes a literal key that starts with `$`. What `$last` matches is
// checked here too, on conditions read apart from a Stub.

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
      #|a.json: /stubs/0/request/body/json/a/$nto: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$nto" for the literal key "$nto"
      #|a.json: /stubs/0/request/body/json/b/0/$ref: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$ref" for the literal key "$ref"
      #|a.json: /stubs/0/request/body/json/c/$not/$regex: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$regex" for the literal key "$regex"
      #|a.json: /stubs/1/request/body/json/a/b: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/1/request/body/json/c/pattern: is not allowed beside "$includes": an operator is the only key of its object
      #|a.json: /stubs/1/request/body/json/d/$exists: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/2/request/body/json/a/$exists: must be true or false
      #|a.json: /stubs/2/request/body/json/b/$includes/$exists: must be true or false
      #|a.json: /stubs/3/request/body/json/a/$not/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/3/request/body/json/b/$includes/0/$nope: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$nope" for the literal key "$nope"
      #|a.json: /stubs/4/request/body/json/$schema: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$schema" for the literal key "$schema"
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
      #|a.json: /stubs/0/request/body/json/schema/$id: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$id" for the literal key "$id"
      #|a.json: /stubs/0/request/body/json/schema/$schema: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$schema" for the literal key "$schema"
      #|a.json: /stubs/1/request/query/q/$nto: is not an operator: the operators here are "$not" and "$exists"
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

///|
test "$last in a json condition is read at any value position, takes any condition, and nests with $not and $includes on either side" {
  inspect(
    stub_problems([
      stub_with(
        "chat", "\"request\": { \"body\": { \"json\": { \"messages\": { \"$last\": { \"role\": \"tool\" } } } } }",
      ),
      stub_with(
        "messages",
        (
          #|"request": { "body": { "json": { "messages": { "$last": { "role": "user",
          #|  "content": { "$includes": { "type": "tool_result" } } } } } } }
        ),
      ),
      stub_with(
        "responses",
        (
          #|"request": { "body": { "json": {
          #|  "input": { "$last": { "type": "function_call_output" } } } } }
        ),
      ),
      stub_with(
        "nested",
        (
          #|"request": { "body": { "json": { "a": { "$not": { "$last": 1 } },
          #|  "b": { "$last": { "$not": 1 } }, "c": { "$includes": { "$last": 1 } },
          #|  "d": { "$last": { "$includes": 1 } }, "e": { "$last": { "$last": { "pattern": "x" } } },
          #|  "f": [{ "$last": { "$exists": true } }], "g": { "$last": [] } } } }
        ),
      ),
      stub_with(
        "root", "\"request\": { \"body\": { \"json\": { \"$last\": null } } }",
      ),
      stub_with(
        "literal", "\"request\": { \"body\": { \"json\": { \"$$last\": { \"role\": \"tool\" } } } }",
      ),
    ]),
    content="valid",
  )
}

///|
test "a malformed $last is a diagnostic at its JSON Pointer: beside another key, with a malformed condition inside, or outside a json condition" {
  inspect(
    stub_problems([
      stub_with(
        "beside",
        (
          #|"request": { "body": { "json": { "a": { "$last": 1, "length": 2 },
          #|  "b": { "$includes": 1, "$last": 2 }, "c": { "$last": 1, "$$last": 2 } } } }
        ),
      ),
      stub_with(
        "inside",
        (
          #|"request": { "body": { "json": { "a": { "$last": { "$nto": 1 } },
          #|  "b": { "$last": { "$exists": 1 } }, "c": { "$last": { "pattern": "(" } } } } }
        ),
      ),
      stub_with(
        "query", "\"request\": { \"query\": { \"q\": { \"$last\": \"1\" } } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/json/a/length: is not allowed beside "$last": an operator is the only key of its object
      #|a.json: /stubs/0/request/body/json/b/$last: is not allowed beside "$includes": an operator is the only key of its object
      #|a.json: /stubs/0/request/body/json/c/$$last: is not allowed beside "$last": an operator is the only key of its object
      #|a.json: /stubs/1/request/body/json/a/$last/$nto: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$nto" for the literal key "$nto"
      #|a.json: /stubs/1/request/body/json/b/$last/$exists: must be true or false
      #|a.json: /stubs/1/request/body/json/c/$last/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/2/request/query/q/$last: is allowed only in a json condition
    ),
  )
}

///|
/// `condition` read as the `json` body condition of conditions given apart
/// from a Stub, with `request_conditions`, which reads a Stub's too.
fn json_condition(condition : Json) -> @definitions.JsonCondition raise {
  guard @definitions.request_conditions({ "body": { "json": condition } })
    is Ok({ body: Some(Json(condition)), .. }) else {
    fail("not a valid json condition")
  }
  condition
}

///|
/// Says for each of `bodies` whether it meets the `json` condition
/// `condition`: one line per body, `<body> -> true` or `-> false`.
fn json_verdicts(condition : Json, bodies : Array[String]) -> String raise {
  let condition = json_condition(condition)
  let lines = []
  for body in bodies {
    lines.push("\{body} -> \{condition.matches(@json.parse(body))}")
  }
  lines.join("\n")
}

///|
test "$last holds when the value is a non-empty array whose last element meets the condition: each API's tool result" {
  inspect(
    json_verdicts({ "messages": { "$last": { "role": "tool" } } }, [
      "{\"messages\":[{\"role\":\"user\"},{\"role\":\"assistant\"},{\"role\":\"tool\",\"content\":\"18C\"}]}",
      "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"assistant\"}]}", "{\"messages\":[{\"role\":\"tool\"}]}",
      "{\"messages\":[]}", "{\"messages\":{\"role\":\"tool\"}}", "{}",
    ]),
    content=(
      #|{"messages":[{"role":"user"},{"role":"assistant"},{"role":"tool","content":"18C"}]} -> true
      #|{"messages":[{"role":"tool"},{"role":"assistant"}]} -> false
      #|{"messages":[{"role":"tool"}]} -> true
      #|{"messages":[]} -> false
      #|{"messages":{"role":"tool"}} -> false
      #|{} -> false
    ),
  )
  inspect(
    json_verdicts(
      {
        "messages": {
          "$last": {
            "role": "user",
            "content": { "$includes": { "type": "tool_result" } },
          },
        },
      },
      [
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\"}]}]}",
        "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]},{\"role\":\"user\",\"content\":\"Thanks\"}]}",
        "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\"}]}]}",
      ],
    ),
    content=(
      #|{"messages":[{"role":"user","content":"Weather?"},{"role":"assistant","content":[{"type":"tool_use","id":"t1"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}]} -> true
      #|{"messages":[{"role":"user","content":[{"type":"tool_result"}]},{"role":"user","content":"Thanks"}]} -> false
      #|{"messages":[{"role":"user","content":[{"type":"text"}]}]} -> false
    ),
  )
  inspect(
    json_verdicts(
      { "input": { "$last": { "type": "function_call_output" } } },
      [
        "{\"input\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"type\":\"function_call\",\"call_id\":\"c1\"},{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"18C\"}]}",
        "{\"input\":[{\"type\":\"function_call_output\"},{\"role\":\"user\",\"content\":\"Thanks\"}]}",
        "{\"input\":\"Weather?\"}",
      ],
    ),
    content=(
      #|{"input":[{"role":"user","content":"Weather?"},{"type":"function_call","call_id":"c1"},{"type":"function_call_output","call_id":"c1","output":"18C"}]} -> true
      #|{"input":[{"type":"function_call_output"},{"role":"user","content":"Thanks"}]} -> false
      #|{"input":"Weather?"} -> false
    ),
  )
}

///|
test "$last nests with $not and $includes on either side, never holds for a value that is not a non-empty array, and $$last is the literal key $last" {
  let bodies = [
    "{\"a\":[1,2]}", "{\"a\":[2,1]}", "{\"a\":[[1],[2]]}", "{\"a\":[[2],[1,2]]}",
    "{\"a\":[]}", "{\"a\":2}", "{\"a\":{\"0\":2}}", "{}", "[1,2]", "{\"$last\":2}",
    "{\"$$last\":2}",
  ]
  let conditions : Array[Json] = [
    { "a": { "$last": 2 } },
    { "a": { "$not": { "$last": 2 } } },
    { "a": { "$last": { "$not": 2 } } },
    { "a": { "$includes": { "$last": 2 } } },
    { "a": { "$last": { "$includes": 1 } } },
    { "a": { "$last": { "$exists": true } } },
    { "$last": 2 },
    { "$$last": 2 },
  ]
  let out = []
  for condition in conditions {
    let met = []
    for body in bodies {
      if json_condition(condition).matches(@json.parse(body)) {
        met.push(body)
      }
    }
    out.push("\{condition.stringify()} -> \{met.join(" ")}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"a":{"$last":2}} -> {"a":[1,2]}
      #|{"a":{"$not":{"$last":2}}} -> {"a":[2,1]} {"a":[[1],[2]]} {"a":[[2],[1,2]]} {"a":[]} {"a":2} {"a":{"0":2}} {} {"$last":2} {"$$last":2}
      #|{"a":{"$last":{"$not":2}}} -> {"a":[2,1]} {"a":[[1],[2]]} {"a":[[2],[1,2]]}
      #|{"a":{"$includes":{"$last":2}}} -> {"a":[[1],[2]]} {"a":[[2],[1,2]]}
      #|{"a":{"$last":{"$includes":1}}} -> {"a":[[2],[1,2]]}
      #|{"a":{"$last":{"$exists":true}}} -> {"a":[1,2]} {"a":[2,1]} {"a":[[1],[2]]} {"a":[[2],[1,2]]}
      #|{"$last":2} -> [1,2]
      #|{"$$last":2} -> {"$last":2}
    ),
  )
}

///|
test "a json condition with $last shadows only one written the same way" {
  inspect(
    verdicts([
      (
        (
          #|{ "body": { "json": { "messages": { "$last": { "role": "user", "content": { "$includes": { "type": "tool_result" } } } } } } }
        ),
        (
          #|{ "path": "/v1/messages", "body": { "json": { "messages": { "$last": { "content": { "$includes": { "type": "tool_result" } }, "role": "user" } } } } }
        ),
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$last\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$last\": 1.0 } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$last\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$last\": 2 } } } }",
      ),
      // t holds for every body s meets, but operators are not reasoned about.
      (
        "{ \"body\": { \"json\": { \"n\": { \"$last\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": [1] } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$includes\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$last\": 1 } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"n\": { \"$last\": 1 } } } }", "{ \"body\": { \"json\": { \"n\": { \"$includes\": 1 } } } }",
      ),
      (
        "{ \"body\": { \"json\": { \"$$last\": 1 } } }", "{ \"body\": { \"json\": { \"$last\": 1 } } }",
      ),
    ]),
    content=(
      #|t { "body": { "json": { "messages": { "$last": { "role": "user", "content": { "$includes": { "type": "tool_result" } } } } } } } / s { "path": "/v1/messages", "body": { "json": { "messages": { "$last": { "content": { "$includes": { "type": "tool_result" } }, "role": "user" } } } } } -> shadowed
      #|t { "body": { "json": { "n": { "$last": 1 } } } } / s { "body": { "json": { "n": { "$last": 1.0 } } } } -> shadowed
      #|t { "body": { "json": { "n": { "$last": 1 } } } } / s { "body": { "json": { "n": { "$last": 2 } } } } -> not reported
      #|t { "body": { "json": { "n": { "$last": 1 } } } } / s { "body": { "json": { "n": [1] } } } -> not reported
      #|t { "body": { "json": { "n": { "$includes": 1 } } } } / s { "body": { "json": { "n": { "$last": 1 } } } } -> not reported
      #|t { "body": { "json": { "n": { "$last": 1 } } } } / s { "body": { "json": { "n": { "$includes": 1 } } } } -> not reported
      #|t { "body": { "json": { "$$last": 1 } } } / s { "body": { "json": { "$last": 1 } } } -> not reported
    ),
  )
}
