// Seam 1 tests of the operators inside a `json` body condition: `$not`,
// `$exists`, `$includes` and `$last` at any value position, and `$$name`
// for a literal key that starts with `$`.

///|
test "$not in a json condition holds when the inner condition does not, so a missing key meets it" {
  let h = stubs([
    (
      #|{ "id": "not-admin", "mock": "m",
      #|  "request": { "body": { "json": { "role": { "$not": "admin" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "{\"role\":\"admin\"}"),
      ("POST", "/", [], "{\"role\":\"user\"}"),
      ("POST", "/", [], "{\"role\":[\"admin\"]}"),
      ("POST", "/", [], "{\"role\":null}"),
      ("POST", "/", [], "{\"name\":\"a\"}"),
      ("POST", "/", [], "[\"admin\"]"),
      ("POST", "/", [], "not json"),
    ]),
    content=(
      #|POST / "{\"role\":\"admin\"}" -> none
      #|POST / "{\"role\":\"user\"}" -> not-admin
      #|POST / "{\"role\":[\"admin\"]}" -> not-admin
      #|POST / "{\"role\":null}" -> not-admin
      #|POST / "{\"name\":\"a\"}" -> not-admin
      #|POST / "[\"admin\"]" -> none
      #|POST / "not json" -> none
    ),
  )
}

///|
test "$exists in a json condition holds when the key is present, even with null, or absent, as it says; null still means JSON null" {
  let h = stubs([
    (
      #|{ "id": "with-coupon", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "coupon": { "$exists": true } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "without-coupon", "mock": "m", "request": { "path": "/b",
      #|    "body": { "json": { "coupon": { "$exists": false } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "null-coupon", "mock": "m", "request": { "path": "/c",
      #|    "body": { "json": { "coupon": null } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/a", [], "{\"coupon\":\"X1\"}"),
      ("POST", "/a", [], "{\"coupon\":null}"),
      ("POST", "/a", [], "{\"coupon\":{}}"),
      ("POST", "/a", [], "{\"coupons\":[]}"),
      ("POST", "/a", [], "[{\"coupon\":1}]"),
      ("POST", "/b", [], "{\"coupon\":\"X1\"}"),
      ("POST", "/b", [], "{\"coupon\":null}"),
      ("POST", "/b", [], "{\"coupons\":[]}"),
      ("POST", "/b", [], "{}"),
      ("POST", "/b", [], "[]"),
      ("POST", "/c", [], "{\"coupon\":null}"),
      ("POST", "/c", [], "{\"coupon\":\"X1\"}"),
      ("POST", "/c", [], "{}"),
    ]),
    content=(
      #|POST /a "{\"coupon\":\"X1\"}" -> with-coupon
      #|POST /a "{\"coupon\":null}" -> with-coupon
      #|POST /a "{\"coupon\":{}}" -> with-coupon
      #|POST /a "{\"coupons\":[]}" -> none
      #|POST /a "[{\"coupon\":1}]" -> none
      #|POST /b "{\"coupon\":\"X1\"}" -> none
      #|POST /b "{\"coupon\":null}" -> none
      #|POST /b "{\"coupons\":[]}" -> without-coupon
      #|POST /b "{}" -> without-coupon
      #|POST /b "[]" -> none
      #|POST /c "{\"coupon\":null}" -> null-coupon
      #|POST /c "{\"coupon\":\"X1\"}" -> none
      #|POST /c "{}" -> none
    ),
  )
}

///|
test "an operator may be the whole json condition or an array element: $exists true at the root holds for any JSON body" {
  let h = stubs([
    (
      #|{ "id": "any-json", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "$exists": true } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "no-json", "mock": "m", "request": { "path": "/b",
      #|    "body": { "json": { "$exists": false } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "not-null", "mock": "m", "request": { "path": "/c",
      #|    "body": { "json": { "$not": null } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "pair", "mock": "m", "request": { "path": "/d",
      #|    "body": { "json": [{ "$not": 0 }, { "$exists": true }] } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/a", [], "null"),
      ("POST", "/a", [], "[]"),
      ("POST", "/a", [], " 1 "),
      ("POST", "/a", [], ""),
      ("POST", "/a", [], "{"),
      ("POST", "/b", [], "{}"),
      ("POST", "/b", [], ""),
      ("POST", "/b", [], "{"),
      ("POST", "/c", [], "{}"),
      ("POST", "/c", [], "null"),
      ("POST", "/c", [], "x"),
      ("POST", "/d", [], "[1,null]"),
      ("POST", "/d", [], "[0,null]"),
      ("POST", "/d", [], "[1]"),
      ("POST", "/d", [], "[1,2,3]"),
    ]),
    content=(
      #|POST /a "null" -> any-json
      #|POST /a "[]" -> any-json
      #|POST /a " 1 " -> any-json
      #|POST /a -> none
      #|POST /a "{" -> none
      #|POST /b "{}" -> none
      #|POST /b -> none
      #|POST /b "{" -> none
      #|POST /c "{}" -> not-null
      #|POST /c "null" -> none
      #|POST /c "x" -> none
      #|POST /d "[1,null]" -> pair
      #|POST /d "[0,null]" -> none
      #|POST /d "[1]" -> none
      #|POST /d "[1,2,3]" -> none
    ),
  )
}

///|
test "$includes holds when the value is an array with an element that meets the inner json condition, wherever it sits" {
  let h = stubs([
    (
      #|{ "id": "urgent", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "tags": { "$includes": "urgent" } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "sku", "mock": "m", "request": { "path": "/b",
      #|    "body": { "json": { "items": { "$includes": { "sku": "A-1" } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "numbered", "mock": "m", "request": { "path": "/c",
      #|    "body": { "json": { "$includes": { "pattern": "[0-9]+" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/a", [], "{\"tags\":[\"urgent\"]}"),
      ("POST", "/a", [], "{\"tags\":[\"a\",\"b\",\"urgent\"]}"),
      ("POST", "/a", [], "{\"tags\":[\"a\",[\"urgent\"]]}"),
      ("POST", "/a", [], "{\"tags\":[]}"),
      ("POST", "/a", [], "{\"tags\":\"urgent\"}"),
      ("POST", "/a", [], "{\"tags\":{\"0\":\"urgent\"}}"),
      ("POST", "/a", [], "{}"),
      (
        "POST",
        "/b",
        [],
        "{\"items\":[{\"sku\":\"B-2\"},{\"sku\":\"A-1\",\"qty\":2}]}",
      ),
      ("POST", "/b", [], "{\"items\":[{\"sku\":\"B-2\"},{\"qty\":2}]}"),
      ("POST", "/c", [], "[\"a\",42]"),
      ("POST", "/c", [], "[\"a\",\"7\"]"),
      ("POST", "/c", [], "[\"a\",true]"),
      ("POST", "/c", [], "42"),
    ]),
    content=(
      #|POST /a "{\"tags\":[\"urgent\"]}" -> urgent
      #|POST /a "{\"tags\":[\"a\",\"b\",\"urgent\"]}" -> urgent
      #|POST /a "{\"tags\":[\"a\",[\"urgent\"]]}" -> none
      #|POST /a "{\"tags\":[]}" -> none
      #|POST /a "{\"tags\":\"urgent\"}" -> none
      #|POST /a "{\"tags\":{\"0\":\"urgent\"}}" -> none
      #|POST /a "{}" -> none
      #|POST /b "{\"items\":[{\"sku\":\"B-2\"},{\"sku\":\"A-1\",\"qty\":2}]}" -> sku
      #|POST /b "{\"items\":[{\"sku\":\"B-2\"},{\"qty\":2}]}" -> none
      #|POST /c "[\"a\",42]" -> numbered
      #|POST /c "[\"a\",\"7\"]" -> numbered
      #|POST /c "[\"a\",true]" -> none
      #|POST /c "42" -> none
    ),
  )
}

///|
test "operators nest: no element is X, some element is not X, and not empty as $not of an empty array" {
  let h = stubs([
    (
      #|{ "id": "none-urgent", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "tags": { "$not": { "$includes": "urgent" } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "some-not-urgent", "mock": "m", "request": { "path": "/b",
      #|    "body": { "json": { "tags": { "$includes": { "$not": "urgent" } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "not-empty", "mock": "m", "request": { "path": "/c",
      #|    "body": { "json": { "items": { "$not": [] } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "empty", "mock": "m", "request": { "path": "/d",
      #|    "body": { "json": { "items": [] } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "nested", "mock": "m", "request": { "path": "/e",
      #|    "body": { "json": { "orders": { "$includes": {
      #|      "lines": { "$includes": { "sku": { "pattern": "A-.*" } } },
      #|      "coupon": { "$exists": false } } } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/a", [], "{\"tags\":[\"a\",\"b\"]}"),
      ("POST", "/a", [], "{\"tags\":[]}"),
      ("POST", "/a", [], "{\"tags\":[\"a\",\"urgent\"]}"),
      ("POST", "/a", [], "{\"tags\":\"urgent\"}"),
      ("POST", "/a", [], "{}"),
      ("POST", "/b", [], "{\"tags\":[\"urgent\",\"a\"]}"),
      ("POST", "/b", [], "{\"tags\":[\"urgent\",\"urgent\"]}"),
      ("POST", "/b", [], "{\"tags\":[]}"),
      ("POST", "/c", [], "{\"items\":[0]}"),
      ("POST", "/c", [], "{\"items\":[]}"),
      ("POST", "/c", [], "{\"items\":{}}"),
      ("POST", "/c", [], "{}"),
      ("POST", "/d", [], "{\"items\":[]}"),
      ("POST", "/d", [], "{\"items\":[0]}"),
      (
        "POST",
        "/e",
        [],
        "{\"orders\":[{\"lines\":[{\"sku\":\"A-1\"}],\"coupon\":null},{\"lines\":[{\"sku\":\"B-1\"},{\"sku\":\"A-2\"}]}]}",
      ),
      (
        "POST",
        "/e",
        [],
        "{\"orders\":[{\"lines\":[{\"sku\":\"A-1\"}],\"coupon\":null},{\"lines\":[{\"sku\":\"B-1\"}]}]}",
      ),
    ]),
    content=(
      #|POST /a "{\"tags\":[\"a\",\"b\"]}" -> none-urgent
      #|POST /a "{\"tags\":[]}" -> none-urgent
      #|POST /a "{\"tags\":[\"a\",\"urgent\"]}" -> none
      #|POST /a "{\"tags\":\"urgent\"}" -> none-urgent
      #|POST /a "{}" -> none-urgent
      #|POST /b "{\"tags\":[\"urgent\",\"a\"]}" -> some-not-urgent
      #|POST /b "{\"tags\":[\"urgent\",\"urgent\"]}" -> none
      #|POST /b "{\"tags\":[]}" -> none
      #|POST /c "{\"items\":[0]}" -> not-empty
      #|POST /c "{\"items\":[]}" -> none
      #|POST /c "{\"items\":{}}" -> not-empty
      #|POST /c "{}" -> not-empty
      #|POST /d "{\"items\":[]}" -> empty
      #|POST /d "{\"items\":[0]}" -> none
      #|POST /e "{\"orders\":[{\"lines\":[{\"sku\":\"A-1\"}],\"coupon\":null},{\"lines\":[{\"sku\":\"B-1\"},{\"sku\":\"A-2\"}]}]}" -> nested
      #|POST /e "{\"orders\":[{\"lines\":[{\"sku\":\"A-1\"}],\"coupon\":null},{\"lines\":[{\"sku\":\"B-1\"}]}]}" -> none
    ),
  )
}

///|
test "$$name in a json condition matches the literal key $name, and keys without $ stay as written" {
  let h = stubs([
    (
      #|{ "id": "ref", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "$$ref": "#/a", "$$$type": { "$exists": true },
      #|      "$$": [{ "$$not": 1 }], "a$b": 2 } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/a",
        [],
        "{\"$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}",
      ),
      (
        "POST",
        "/a",
        [],
        "{\"$$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}",
      ),
      (
        "POST",
        "/a",
        [],
        "{\"$ref\":\"#/a\",\"$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}",
      ),
      (
        "POST",
        "/a",
        [],
        "{\"$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":2}],\"a$b\":2}",
      ),
    ]),
    content=(
      #|POST /a "{\"$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}" -> ref
      #|POST /a "{\"$$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}" -> none
      #|POST /a "{\"$ref\":\"#/a\",\"$type\":0,\"$\":[{\"$not\":1}],\"a$b\":2}" -> none
      #|POST /a "{\"$ref\":\"#/a\",\"$$type\":0,\"$\":[{\"$not\":2}],\"a$b\":2}" -> none
    ),
  )
}

///|
test "a failed json condition with operators counts once as body in the Near miss, and the Near miss and render show it as the Stub writes it, $$ keys included" {
  let h = stubs([
    (
      #|{ "id": "order", "mock": "m",
      #|  "request": { "method": "POST", "path": "/orders",
      #|    "body": { "json": { "tags": { "$includes": "urgent" }, "items": { "$not": [] },
      #|      "coupon": { "$exists": true }, "$$type": "order" } } },
      #|  "response": { "status": 201 } }
    ),
  ])
  inspect(
    near_misses(h, [
      ("POST", "/orders", [], "{\"tags\":[],\"items\":[],\"$type\":\"order\"}"),
    ]),
    content=(
      #|POST /orders "{\"tags\":[],\"items\":[],\"$type\":\"order\"}" -> order; failed=body
    ),
  )
  json_inspect(
    explanation(h, "POST", "/orders", body="{\"tags\":[\"a\"],\"items\":[1]}"),
    content={
      "stub": "order",
      "stubSource": "file",
      "failed": [
        {
          "condition": "body",
          "expected": {
            "json": {
              "tags": { "$includes": "urgent" },
              "items": { "$not": [] },
              "coupon": { "$exists": true },
              "$$type": "order",
            },
          },
          "actual": ["{\"tags\":[\"a\"],\"items\":[1]}"],
        },
      ],
    },
  )
  inspect(
    h.failed("order", {
      "method": "POST",
      "path": "/orders",
      "body": "{\"tags\":[\"urgent\"],\"items\":[1]}",
    }),
    content=(
      #|body: expected {"json":{"tags":{"$includes":"urgent"},"items":{"$not":[]},"coupon":{"$exists":true},"$$type":"order"}}, actual ["{\"tags\":[\"urgent\"],\"items\":[1]}"]
    ),
  )
}

///|
test "an Ephemeral Stub may use json operators, and a malformed one is rejected with the messages a Definition file gets" {
  let h = stubs([])
  let added = h.add(
    "m",
    None,
    (
      #|{ "request": { "body": { "json": { "tags": { "$includes": "urgent" },
      #|    "$$ref": { "$exists": true } } } },
      #|  "response": { "status": 200 } }
    ),
  )
  let rejected = try
    h.engine.add_ephemeral_stub(
      mock="m",
      session=None,
      @json.parse(
        (
          #|{ "request": { "body": { "json": { "a": { "$nto": 1 },
          #|    "b": { "$not": 1, "c": 2 } } } },
          #|  "response": { "status": 200 } }
        ),
      ),
    )
  catch {
    @engine.InvalidStub(problems) =>
      problems.map(problem => problem.to_string())
    error => fail(@debug.to_string(error))
  } noraise {
    stub => [stub.id]
  }
  inspect(
    "\{added}\n\{rejected.join("\n")}\n" +
    winners(h, [
      ("POST", "/", [], "{\"tags\":[\"urgent\"],\"$ref\":null}"),
      ("POST", "/", [], "{\"tags\":[\"urgent\"]}"),
    ]),
    content=(
      #|eph-1
      #|/request/body/json/a/$nto: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$nto" for the literal key "$nto"
      #|/request/body/json/b/c: is not allowed beside "$not": an operator is the only key of its object
      #|POST / "{\"tags\":[\"urgent\"],\"$ref\":null}" -> eph-1
      #|POST / "{\"tags\":[\"urgent\"]}" -> none
    ),
  )
}

///|
test "$last holds when the value is a non-empty array whose last element meets the condition, so each API's tool result can be matched" {
  let h = stubs([
    (
      #|{ "id": "chat-tool", "mock": "m",
      #|  "request": { "path": "/v1/chat/completions",
      #|    "body": { "json": { "messages": { "$last": { "role": "tool" } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "messages-tool", "mock": "m",
      #|  "request": { "path": "/v1/messages",
      #|    "body": { "json": { "messages": { "$last": { "role": "user",
      #|      "content": { "$includes": { "type": "tool_result" } } } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "responses-tool", "mock": "m",
      #|  "request": { "path": "/v1/responses",
      #|    "body": { "json": { "input": { "$last": { "type": "function_call_output" } } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/v1/chat/completions",
        [],
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"role\":\"assistant\",\"tool_calls\":[]},{\"role\":\"tool\",\"content\":\"18C\"}]}",
      ),
      (
        "POST",
        "/v1/chat/completions",
        [],
        "{\"messages\":[{\"role\":\"tool\",\"content\":\"18C\"},{\"role\":\"user\",\"content\":\"Thanks\"}]}",
      ),
      ("POST", "/v1/chat/completions", [], "{\"messages\":[]}"),
      ("POST", "/v1/chat/completions", [], "{\"messages\":{\"role\":\"tool\"}}"),
      ("POST", "/v1/chat/completions", [], "{\"model\":\"m\"}"),
      (
        "POST",
        "/v1/messages",
        [],
        "{\"messages\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\"}]}]}",
      ),
      (
        "POST",
        "/v1/messages",
        [],
        "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]},{\"role\":\"user\",\"content\":\"Thanks\"}]}",
      ),
      (
        "POST",
        "/v1/responses",
        [],
        "{\"input\":[{\"type\":\"function_call\",\"call_id\":\"c1\"},{\"type\":\"function_call_output\",\"call_id\":\"c1\"}]}",
      ),
      (
        "POST",
        "/v1/responses",
        [],
        "{\"input\":[{\"type\":\"function_call_output\"},{\"role\":\"user\",\"content\":\"Thanks\"}]}",
      ),
      ("POST", "/v1/responses", [], "{\"input\":\"function_call_output\"}"),
      ("POST", "/v1/responses", [], "{\"input\":[]}"),
    ]),
    content=(
      #|POST /v1/chat/completions "{\"messages\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"role\":\"assistant\",\"tool_calls\":[]},{\"role\":\"tool\",\"content\":\"18C\"}]}" -> chat-tool
      #|POST /v1/chat/completions "{\"messages\":[{\"role\":\"tool\",\"content\":\"18C\"},{\"role\":\"user\",\"content\":\"Thanks\"}]}" -> none
      #|POST /v1/chat/completions "{\"messages\":[]}" -> none
      #|POST /v1/chat/completions "{\"messages\":{\"role\":\"tool\"}}" -> none
      #|POST /v1/chat/completions "{\"model\":\"m\"}" -> none
      #|POST /v1/messages "{\"messages\":[{\"role\":\"user\",\"content\":\"Weather?\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\"}]}]}" -> messages-tool
      #|POST /v1/messages "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]},{\"role\":\"user\",\"content\":\"Thanks\"}]}" -> none
      #|POST /v1/responses "{\"input\":[{\"type\":\"function_call\",\"call_id\":\"c1\"},{\"type\":\"function_call_output\",\"call_id\":\"c1\"}]}" -> responses-tool
      #|POST /v1/responses "{\"input\":[{\"type\":\"function_call_output\"},{\"role\":\"user\",\"content\":\"Thanks\"}]}" -> none
      #|POST /v1/responses "{\"input\":\"function_call_output\"}" -> none
      #|POST /v1/responses "{\"input\":[]}" -> none
    ),
  )
}

///|
test "$last nests with $not and $includes on either side, and $$last matches the literal key $last" {
  let h = stubs([
    (
      #|{ "id": "last-not-tool", "mock": "m", "request": { "path": "/a",
      #|    "body": { "json": { "messages": { "$not": { "$last": { "role": "tool" } } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "last-not-user", "mock": "m", "request": { "path": "/b",
      #|    "body": { "json": { "messages": { "$last": { "role": { "$not": "user" } } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "a-turn-ends-with-a-tool", "mock": "m", "request": { "path": "/c",
      #|    "body": { "json": { "turns": { "$includes": { "$last": { "role": "tool" } } } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "literal", "mock": "m", "request": { "path": "/d",
      #|    "body": { "json": { "$$last": { "role": "tool" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/a",
        [],
        "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}",
      ),
      (
        "POST",
        "/a",
        [],
        "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}",
      ),
      ("POST", "/a", [], "{\"messages\":[]}"),
      ("POST", "/a", [], "{}"),
      (
        "POST",
        "/b",
        [],
        "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}",
      ),
      (
        "POST",
        "/b",
        [],
        "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}",
      ),
      ("POST", "/b", [], "{\"messages\":[{\"content\":\"x\"}]}"),
      ("POST", "/b", [], "{\"messages\":[]}"),
      (
        "POST",
        "/c",
        [],
        "{\"turns\":[[{\"role\":\"user\"}],[{\"role\":\"user\"},{\"role\":\"tool\"}]]}",
      ),
      (
        "POST",
        "/c",
        [],
        "{\"turns\":[[{\"role\":\"tool\"},{\"role\":\"user\"}],[]]}",
      ),
      ("POST", "/d", [], "{\"$last\":{\"role\":\"tool\"}}"),
      ("POST", "/d", [], "{\"$$last\":{\"role\":\"tool\"}}"),
      ("POST", "/d", [], "[{\"role\":\"tool\"}]"),
    ]),
    content=(
      #|POST /a "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}" -> last-not-tool
      #|POST /a "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}" -> none
      #|POST /a "{\"messages\":[]}" -> last-not-tool
      #|POST /a "{}" -> last-not-tool
      #|POST /b "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}" -> last-not-user
      #|POST /b "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}" -> none
      #|POST /b "{\"messages\":[{\"content\":\"x\"}]}" -> last-not-user
      #|POST /b "{\"messages\":[]}" -> none
      #|POST /c "{\"turns\":[[{\"role\":\"user\"}],[{\"role\":\"user\"},{\"role\":\"tool\"}]]}" -> a-turn-ends-with-a-tool
      #|POST /c "{\"turns\":[[{\"role\":\"tool\"},{\"role\":\"user\"}],[]]}" -> none
      #|POST /d "{\"$last\":{\"role\":\"tool\"}}" -> literal
      #|POST /d "{\"$$last\":{\"role\":\"tool\"}}" -> none
      #|POST /d "[{\"role\":\"tool\"}]" -> none
    ),
  )
}

///|
test "a failed $last counts as body in the Near miss, and the Near miss, render and the Journal show it as the Stub writes it" {
  let h = stubs([
    (
      #|{ "id": "after-tool", "mock": "m",
      #|  "request": { "method": "POST", "path": "/v1/chat/completions",
      #|    "body": { "json": { "messages": { "$last": { "role": "tool" } } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let body = "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}"
  inspect(
    near_misses(h, [("POST", "/v1/chat/completions", [], body)]),
    content=(
      #|POST /v1/chat/completions "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}" -> after-tool; failed=body
    ),
  )
  json_inspect(explanation(h, "POST", "/v1/chat/completions", body~), content={
    "stub": "after-tool",
    "stubSource": "file",
    "failed": [
      {
        "condition": "body",
        "expected": { "json": { "messages": { "$last": { "role": "tool" } } } },
        "actual": ["{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}"],
      },
    ],
  })
  inspect(
    h.failed("after-tool", {
      "method": "POST",
      "path": "/v1/chat/completions",
      "body": "{\"messages\":[]}",
    }),
    content=(
      #|body: expected {"json":{"messages":{"$last":{"role":"tool"}}}}, actual ["{\"messages\":[]}"]
    ),
  )
  let _ = h.record("POST", "/v1/chat/completions", body~, session="s")
  json_inspect(h.answered(Some("s")), content={
    "host": null,
    "mock": "m",
    "viaDefault": true,
    "stub": null,
    "nearMiss": {
      "stub": "after-tool",
      "stubSource": "file",
      "failed": [
        {
          "condition": "body",
          "expected": {
            "json": { "messages": { "$last": { "role": "tool" } } },
          },
          "actual": ["{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}"],
        },
      ],
    },
    "status": 404,
    "fault": null,
  })
}

///|
test "an Ephemeral Stub may use $last, and one with $last beside another key is rejected with the message a Definition file gets" {
  let h = stubs([])
  let added = h.add(
    "m",
    None,
    (
      #|{ "request": { "body": { "json": { "messages": { "$last": { "role": "tool" } } } } },
      #|  "response": { "status": 200 } }
    ),
  )
  let rejected = try
    h.engine.add_ephemeral_stub(
      mock="m",
      session=None,
      @json.parse(
        (
          #|{ "request": { "body": { "json": { "messages": { "$last": { "role": "tool" },
          #|    "length": 2 } } } },
          #|  "response": { "status": 200 } }
        ),
      ),
    )
  catch {
    @engine.InvalidStub(problems) =>
      problems.map(problem => problem.to_string())
    error => fail(@debug.to_string(error))
  } noraise {
    stub => [stub.id]
  }
  inspect(
    "\{added}\n\{rejected.join("\n")}\n" +
    winners(h, [
      (
        "POST",
        "/",
        [],
        "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}",
      ),
      (
        "POST",
        "/",
        [],
        "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}",
      ),
    ]),
    content=(
      #|eph-1
      #|/request/body/json/messages/length: is not allowed beside "$last": an operator is the only key of its object
      #|POST / "{\"messages\":[{\"role\":\"user\"},{\"role\":\"tool\"}]}" -> eph-1
      #|POST / "{\"messages\":[{\"role\":\"tool\"},{\"role\":\"user\"}]}" -> none
    ),
  )
}
