// Seam 1 tests of the writes of CRUD Stubs: create at the list path, and
// replace, update and delete at an item path. Each is one keyed write,
// applied at the match decision, all or nothing, within the state bound.

///|
test "the ticket's example: a Session creates an order, reads it, and deletes it, which answers it once more; another Session still sees the three orders" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  out.push(
    response(
      h.shop(
        "POST",
        "/api/v1/orders",
        body="{\"customerId\":42,\"status\":\"pending\"}",
        session="test-a",
      ),
    ),
  )
  out.push(response(h.shop("GET", "/api/v1/orders/1004", session="test-a")))
  out.push(response(h.shop("DELETE", "/api/v1/orders/1004", session="test-a")))
  out.push(reply(h.shop("GET", "/api/v1/orders/1004", session="test-a")))
  out.push(reply(h.shop("GET", "/api/v1/orders", session="test-b")))
  inspect(
    out.join("\n---\n"),
    content=(
      #|201
      #|Content-Type: application/json
      #|Location: /api/v1/orders/1004
      #|Access-Control-Allow-Origin: *
      #|{"customerId":42,"status":"pending","id":1004}
      #|---
      #|200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"customerId":42,"status":"pending","id":1004}
      #|---
      #|200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"customerId":42,"status":"pending","id":1004}
      #|---
      #|404 {"error":"no item with this key","stub":"orders","key":"1004"}
      #|---
      #|200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
    ),
  )
}

///|
test "a replace makes the body the item, in its place: a key member that is absent is added last, and one that holds the same key text keeps the stored key value" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    request in [
      ("PUT", "/api/v1/orders/1002", "{\"status\":\"shipped\",\"total\":9.90}"),
      ("PUT", "/api/v1/orders/1003", "{\"id\":\"1003\",\"status\":\"lost\"}"),
      ("PUT", "/api/v1/orders/1001", "{\"total\":1,\"id\":1001.0}"),
      ("GET", "/api/v1/orders", ""),
    ] {
    let (meth, target, body) = request
    out.push("\{meth} \{target}: \{reply(h.shop(meth, target, body~))}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|PUT /api/v1/orders/1002: 200 {"status":"shipped","total":9.9,"id":1002}
      #|PUT /api/v1/orders/1003: 200 {"id":1003,"status":"lost"}
      #|PUT /api/v1/orders/1001: 200 {"total":1,"id":1001}
      #|GET /api/v1/orders: 200 [{"total":1,"id":1001},{"status":"shipped","total":9.9,"id":1002},{"id":1003,"status":"lost"}]
    ),
  )
}

///|
test "an update merges the body into the item shallowly: members replace members of the same name in place, new ones go last in body order, null is stored, and the item keeps its stored key value" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    request in [
      (
        "PATCH", "/api/v1/orders/1002", "{\"note\":{\"a\":1},\"status\":\"shipped\",\"extra\":[1],\"total\":null}",
      ),
      ("PATCH", "/api/v1/orders/1002", "{\"note\":{\"b\":2},\"id\":\"1002\"}"),
      ("PATCH", "/api/v1/orders/1003", "{}"),
      ("GET", "/api/v1/orders", ""),
    ] {
    let (meth, target, body) = request
    out.push("\{meth} \{target}: \{reply(h.shop(meth, target, body~))}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|PATCH /api/v1/orders/1002: 200 {"id":1002,"customerId":7,"status":"shipped","total":null,"note":{"a":1},"extra":[1]}
      #|PATCH /api/v1/orders/1002: 200 {"id":1002,"customerId":7,"status":"shipped","total":null,"note":{"b":2},"extra":[1]}
      #|PATCH /api/v1/orders/1003: 200 {"id":1003,"customerId":42,"status":"paid","total":3}
      #|GET /api/v1/orders: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"shipped","total":null,"note":{"b":2},"extra":[1]},{"id":1003,"customerId":42,"status":"paid","total":3}]
    ),
  )
}

///|
test "a create, replace or update needs a body that is a JSON object, whatever its Content-Type; anything else is 400 and writes nothing, and a delete ignores the body" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    request in [
      ("POST", "/api/v1/orders"),
      ("PUT", "/api/v1/orders/1001"),
      ("PATCH", "/api/v1/orders/1001"),
    ] {
    let (meth, target) = request
    for body in ["", "{not JSON", "[{\"id\":5}]", "42", "\"x\"", "null", "{}x"] {
      out.push(
        "\{meth} \{body.escape()}: \{reply(h.shop(meth, target, body~, session="s"))}",
      )
    }
  }
  out.push(
    "POST an object as text/plain: \{reply(h.shop("POST", "/api/v1/orders", headers=[("Content-Type", "text/plain")], body="{\"total\":1}", session="t"))}",
  )
  out.push(
    "DELETE with a body that is not JSON: \{reply(h.shop("DELETE", "/api/v1/orders/1001", body="{not JSON", session="t"))}",
  )
  out.push(
    "s wrote nothing: \{reply(h.shop("GET", "/api/v1/orders", session="s"))}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|POST "": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "{not JSON": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "[{\"id\":5}]": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "42": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "\"x\"": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "null": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST "{}x": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "{not JSON": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "[{\"id\":5}]": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "42": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "\"x\"": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "null": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PUT "{}x": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "{not JSON": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "[{\"id\":5}]": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "42": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "\"x\"": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "null": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH "{}x": 400 {"error":"body is not a JSON object","stub":"orders"}
      #|POST an object as text/plain: 201 {"total":1,"id":1004}
      #|DELETE with a body that is not JSON: 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|s wrote nothing: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
    ),
  )
}

///|
test "keys on writes: a create's key member that is present but not a key is 400 invalid key, a taken key is 409, and a replace's or update's key member that holds another key is 400; none writes" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    body in [
      "{\"id\":null}", "{\"id\":\"\"}", "{\"id\":\"a/b\"}", "{\"id\":1.5}", "{\"id\":true}",
      "{\"id\":9007199254740992}", "{\"id\":[1]}", "{\"id\":1001}", "{\"id\":\"1002\"}",
      "{\"id\":1003.0}",
    ] {
    out.push(
      "POST \{body}: \{reply(h.shop("POST", "/api/v1/orders", body~, session="s"))}",
    )
  }
  for meth in ["PUT", "PATCH"] {
    for
      body in [
        "{\"id\":1003}", "{\"id\":\"x\"}", "{\"id\":null}", "{\"id\":\"01002\"}",
      ] {
      out.push(
        "\{meth} 1002 \{body}: \{reply(h.shop(meth, "/api/v1/orders/1002", body~, session="s"))}",
      )
    }
  }
  out.push(
    "s wrote nothing: \{reply(h.shop("GET", "/api/v1/orders", session="s"))}",
  )
  out.push("bytes: \{h.engine.state_stats().bytes}")
  inspect(
    out.join("\n"),
    content=(
      #|POST {"id":null}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":""}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":"a/b"}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":1.5}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":true}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":9007199254740992}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":[1]}: 400 {"error":"invalid key","stub":"orders"}
      #|POST {"id":1001}: 409 {"error":"key already exists","stub":"orders","key":"1001"}
      #|POST {"id":"1002"}: 409 {"error":"key already exists","stub":"orders","key":"1002"}
      #|POST {"id":1003.0}: 409 {"error":"key already exists","stub":"orders","key":"1003"}
      #|PUT 1002 {"id":1003}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PUT 1002 {"id":"x"}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PUT 1002 {"id":null}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PUT 1002 {"id":"01002"}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PATCH 1002 {"id":1003}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PATCH 1002 {"id":"x"}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PATCH 1002 {"id":null}: 400 {"error":"key does not match the path","stub":"orders"}
      #|PATCH 1002 {"id":"01002"}: 400 {"error":"key does not match the path","stub":"orders"}
      #|s wrote nothing: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|bytes: 0
    ),
  )
}

///|
test "a replace, update or delete of a missing item is 404, as for a read, and writes nothing; a body that is not an object is 400 first" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for meth in ["PUT", "PATCH", "DELETE"] {
    for target in ["/api/v1/orders/9999", "/api/v1/orders/a%20b"] {
      out.push(
        "\{meth} \{target}: \{reply(h.shop(meth, target, body="{\"id\":1}", session="s"))}",
      )
    }
    out.push(
      "\{meth} 9999 with no body: \{reply(h.shop(meth, "/api/v1/orders/9999", session="s"))}",
    )
  }
  out.push("bytes: \{h.engine.state_stats().bytes}")
  inspect(
    out.join("\n"),
    content=(
      #|PUT /api/v1/orders/9999: 404 {"error":"no item with this key","stub":"orders","key":"9999"}
      #|PUT /api/v1/orders/a%20b: 404 {"error":"no item with this key","stub":"orders","key":"a b"}
      #|PUT 9999 with no body: 400 {"error":"body is not a JSON object","stub":"orders"}
      #|PATCH /api/v1/orders/9999: 404 {"error":"no item with this key","stub":"orders","key":"9999"}
      #|PATCH /api/v1/orders/a%20b: 404 {"error":"no item with this key","stub":"orders","key":"a b"}
      #|PATCH 9999 with no body: 400 {"error":"body is not a JSON object","stub":"orders"}
      #|DELETE /api/v1/orders/9999: 404 {"error":"no item with this key","stub":"orders","key":"9999"}
      #|DELETE /api/v1/orders/a%20b: 404 {"error":"no item with this key","stub":"orders","key":"a b"}
      #|DELETE 9999 with no body: 404 {"error":"no item with this key","stub":"orders","key":"9999"}
      #|bytes: 0
    ),
  )
}

///|
test "a create without the key member gets a new key, added last: one more than the highest integer key, skipping the integers that string keys hold, or 1 in an empty bucket; Location encodes each segment and the key" {
  let h = harness([
    (
      "things.yaml",
      (
        #|mocks:
        #|  - name: things
        #|data:
        #|  - { mock: things, name: things, key: code, json: [{ code: "5" }, { code: 3 }, { code: "4" }, { code: "a b" }] }
        #|  - { mock: things, name: empty, key: id, json: [] }
        #|stubs:
        #|  - id: things
        #|    mock: things
        #|    crud: { bucket: things, path: "/my things/ä" }
        #|  - id: empty
        #|    mock: things
        #|    crud: { bucket: empty, path: /empty }
      ),
    ),
  ])
  let out = []
  for
    request in [
      ("/my%20things/%C3%A4", "{\"name\":\"x\"}"),
      ("/my%20things/%C3%A4", "{\"name\":\"y\",\"code\":\"é ü~-._\"}"),
      ("/my%20things/%C3%A4", "{\"code\":-12.0}"),
      ("/empty", "{}"),
      ("/empty", "{\"id\":\"1\",\"n\":1}"),
      ("/empty", "{}"),
    ] {
    let (target, body) = request
    out.push(response(h.send("POST", target, body~)))
  }
  out.push(reply(h.send("GET", "/my%20things/%C3%A4")))
  inspect(
    out.join("\n---\n"),
    content=(
      #|201
      #|Content-Type: application/json
      #|Location: /my%20things/%C3%A4/6
      #|Smock-Mock: things; via=default
      #|{"name":"x","code":6}
      #|---
      #|201
      #|Content-Type: application/json
      #|Location: /my%20things/%C3%A4/%C3%A9%20%C3%BC~-._
      #|Smock-Mock: things; via=default
      #|{"name":"y","code":"é ü~-._"}
      #|---
      #|201
      #|Content-Type: application/json
      #|Location: /my%20things/%C3%A4/-12
      #|Smock-Mock: things; via=default
      #|{"code":-12}
      #|---
      #|201
      #|Content-Type: application/json
      #|Location: /empty/1
      #|Smock-Mock: things; via=default
      #|{"id":1}
      #|---
      #|409
      #|Content-Type: application/json
      #|Smock-Mock: things; via=default
      #|{"error":"key already exists","stub":"empty","key":"1"}
      #|---
      #|201
      #|Content-Type: application/json
      #|Location: /empty/2
      #|Smock-Mock: things; via=default
      #|{"id":2}
      #|---
      #|200 [{"code":"5"},{"code":3},{"code":"4"},{"code":"a b"},{"name":"x","code":6},{"name":"y","code":"é ü~-._"},{"code":-12}]
    ),
  )
}

///|
test "Location: the key a b under /api/v1/orders gives /api/v1/orders/a%20b, which reads the item back" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let created = h.shop("POST", "/api/v1/orders", body="{\"id\":\"a b\"}")
  let location = created.plan.headers
    .filter(header => header.0 == "Location")
    .map(header => header.1)
  inspect(
    "\{location.join(", ")}: \{reply(h.shop("GET", location[0]))}",
    content=(
      #|/api/v1/orders/a%20b: 200 {"id":"a b"}
    ),
  )
}

///|
test "a create gets 500 no new key when the next integer key would pass 2^53 - 1, and writes nothing; a body with a key of its own is still created" {
  let h = harness([
    (
      "things.yaml",
      (
        #|mocks:
        #|  - name: things
        #|data:
        #|  - { mock: things, name: last, key: id, json: [{ id: 9007199254740990 }] }
        #|stubs:
        #|  - id: last
        #|    mock: things
        #|    crud: { bucket: last, path: /last, headers: { X-A: a } }
      ),
    ),
  ])
  let out = []
  out.push(reply(h.send("POST", "/last", body="{}")))
  out.push(response(h.send("POST", "/last", body="{\"n\":1}")))
  out.push(reply(h.send("POST", "/last", body="{\"id\":\"x\"}")))
  out.push(reply(h.send("GET", "/last")))
  inspect(
    out.join("\n---\n"),
    content=(
      #|201 {"id":9007199254740991}
      #|---
      #|500
      #|Content-Type: application/json
      #|X-A: a
      #|Smock-Mock: things; via=default
      #|{"error":"no new key","stub":"last"}
      #|---
      #|201 {"id":"x"}
      #|---
      #|200 [{"id":9007199254740990},{"id":9007199254740991},{"id":"x"}]
    ),
  )
}

///|
test "a uuid key comes from the helper generator seeded with the request's one draw, as a response's first fake.uuid() does, so fault.seed repeats it with the Fault decisions, and one an item has is drawn again" {
  let h = harness([
    (
      "tokens.yaml",
      (
        #|mocks:
        #|  - name: tokens
        #|data:
        #|  - { mock: tokens, name: tokens, key: token, newKey: uuid, json: [] }
        #|  - { mock: tokens, name: taken, key: token, newKey: uuid, json: [{ token: 967d85fe-343d-4cc0-9b49-c024af3b3103 }] }
        #|stubs:
        #|  - id: tokens
        #|    mock: tokens
        #|    crud: { bucket: tokens, path: /tokens }
        #|    fault: { seed: 42, delay: { uniform: { min: 1, max: 1000 } } }
        #|  - id: taken
        #|    mock: tokens
        #|    crud: { bucket: taken, path: /taken }
        #|    fault: { seed: 42 }
        #|  - id: drawn
        #|    mock: tokens
        #|    request: { path: /drawn }
        #|    response: { status: 200, template: true, json: ["${fake.uuid()}", "${fake.uuid()}"] }
        #|    fault: { seed: 42, delay: { uniform: { min: 1, max: 1000 } } }
      ),
    ),
  ])
  let out = []
  for session in ["s", "t"] {
    let created = h.send("POST", "/tokens", body="{\"n\":1}", session~)
    out.push("\{session}: \{reply(created)}, delay \{created.plan.delay_ms}")
  }
  let drawn = h.send("GET", "/drawn")
  out.push("drawn: \{reply(drawn)}, delay \{drawn.plan.delay_ms}")
  out.push("taken: \{reply(h.send("POST", "/taken", body="{}"))}")
  inspect(
    out.join("\n"),
    content=(
      #|s: 201 {"n":1,"token":"967d85fe-343d-4cc0-9b49-c024af3b3103"}, delay 707
      #|t: 201 {"n":1,"token":"bb468c1b-68bb-4082-8d7b-aae65078e215"}, delay 508
      #|drawn: 200 ["967d85fe-343d-4cc0-9b49-c024af3b3103","a168a304-0584-4bdd-99da-8adbdc970b94"], delay 707
      #|taken: 201 {"token":"a168a304-0584-4bdd-99da-8adbdc970b94"}
    ),
  )
}

///|
test "at the bound: a write that would take the count above it is 507 with the Stub's headers, writes nothing and counts as refused; a delete meets it too, since a first write copies the bucket" {
  let h = harness(crud_shop(), body_files=data_body_files, state_max_bytes=400)
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push(
      "\{label}: \{response(outcome)}\n\{data_journaled(outcome)}; \{h.engine.state_stats().bytes} bytes",
    )
  }
  // The copy that deleting 1001 leaves, two orders: 6 + 64 + 113 + 16 * 11,
  // and its space, 4 + 64: 427.
  step("delete 1001", h.shop("DELETE", "/api/v1/orders/1001"))
  // A copy of one order, {"id":1}: 6 + 64 + 10 + 16 * 3, and the space:
  // 196.
  h.engine.set_data(mock="shop", session=None, bucket="orders", [{ "id": 1 }])
  |> ignore
  out.push("set: \{h.engine.state_stats().bytes} bytes")
  // {"note":"…","id":2}, after a comma, adds 1 + 18 + 16 * 3 and the
  // note's length: 196 + 67 + 140 passes 400; 196 + 67 + 100 does not.
  let note = "x".repeat(140)
  step(
    "create past the bound",
    h.shop("POST", "/api/v1/orders", body="{\"note\":\"\{note}\"}"),
  )
  out.push("unchanged: \{reply(h.shop("GET", "/api/v1/orders"))}")
  step(
    "create within it",
    h.shop("POST", "/api/v1/orders", body="{\"note\":\"\{"x".repeat(100)}\"}"),
  )
  out.push("refused: \{h.engine.state_stats().writes_refused}")
  inspect(
    out.join("\n"),
    content=(
      #|delete 1001: 507
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"state limit reached","stub":"orders","message":"the writes would take per-Session state from 0 to 427 bytes, above its bound of 400 (--state-max-bytes)"}
      #|status 507, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none; 0 bytes
      #|set: 196 bytes
      #|create past the bound: 507
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"state limit reached","stub":"orders","message":"the writes would take per-Session state from 196 to 403 bytes, above its bound of 400 (--state-max-bytes)"}
      #|status 507, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none; 196 bytes
      #|unchanged: 200 [{"id":1}]
      #|create within it: 201
      #|Content-Type: application/json
      #|Location: /api/v1/orders/2
      #|Access-Control-Allow-Origin: *
      #|{"note":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","id":2}
      #|status 201, responseIndex null, variablesWritten [], dataWritten [orders], dataError none, templateError none; 363 bytes
      #|refused: 2
    ),
  )
}

///|
test "the write happens at the match decision: the delay applies after it, a connection Fault replaces the answer but not the write, partial sends half the body, and two creates whose answers are delayed get different keys" {
  let h = harness(
    [
      (
        "shop.yaml",
        (
          #|mocks:
          #|  - name: shop
          #|data:
          #|  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
          #|stubs:
          #|  - id: slow
          #|    mock: shop
          #|    crud: { bucket: orders, path: /slow }
          #|    fault: { delay: { fixed: 250 } }
          #|  - id: reset
          #|    mock: shop
          #|    crud: { bucket: orders, path: /reset }
          #|    fault: { connection: { kind: reset } }
          #|  - id: partial
          #|    mock: shop
          #|    crud: { bucket: orders, path: /partial }
          #|    fault: { connection: { kind: partial } }
          #|  - id: list
          #|    mock: shop
          #|    request: { method: GET, path: /list }
          #|    response: { status: 200, template: true, json: "${data.orders}" }
        ),
      ),
    ],
    body_files=data_body_files,
  )
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push("\{label}: \{reply(outcome)}; \{decision(outcome)}")
  }
  // Both creates are answered only after their delay, but each was written
  // when it matched.
  step("create", h.send("POST", "/slow", body="{\"n\":1}"))
  step("create again", h.send("POST", "/slow", body="{\"n\":2}"))
  step("delete through a reset", h.send("DELETE", "/reset/1001"))
  step("update through a partial", h.send("PATCH", "/partial/1002", body="{}"))
  out.push("the writes stand: \{reply(h.send("GET", "/list"))}")
  inspect(
    out.join("\n"),
    content=(
      #|create: 201 {"n":1,"id":1004}; delay 250
      #|create again: 201 {"n":2,"id":1005}; delay 250
      #|delete through a reset: 200 {"id":1001,"customerId":42,"status":"paid","total":12.5}; delay 0, Reset
      #|update through a partial: 200 {"id":1002,"customerId":7,"status":"pending","total":9.9}; delay 0, Partial
      #|the writes stand: 200 [{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3},{"n":1,"id":1004},{"n":2,"id":1005}]
    ),
  )
}

///|
test "each Session writes its own copy, and the no-Session space shares one" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let _ = h.shop("POST", "/api/v1/orders", body="{\"by\":\"a\"}", session="a")
  let _ = h.shop("DELETE", "/api/v1/orders/1001", session="b")
  let _ = h.shop("PATCH", "/api/v1/orders/1002", body="{\"by\":\"none\"}")
  let _ = h.shop("PUT", "/api/v1/orders/1003", body="{\"by\":\"none\"}")
  let out = []
  for session in [Some("a"), Some("b"), None, Some("c")] {
    out.push(
      "\{@debug.to_string(session)}: \{reply(h.shop("GET", "/api/v1/orders", session?))}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|Some("a"): 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3},{"by":"a","id":1004}]
      #|Some("b"): 200 [{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|None: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9,"by":"none"},{"by":"none","id":1003}]
      #|Some("c"): 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
    ),
  )
}

///|
test "the Journal records each write's operation and key: a create the stored item's key, or the body's on a 409, else null; the others the item path's key, whatever the outcome; dataWritten names the bucket after a write only, and dataError stays null" {
  // The bound lets every write through but the create of a big item.
  let h = harness(crud_shop(), body_files=data_body_files, state_max_bytes=700)
  let out = []
  for
    request in [
      ("POST", "/api/v1/orders", "{\"id\":\"a b\"}"),
      ("POST", "/api/v1/orders", "{\"id\":1001}"),
      ("POST", "/api/v1/orders", "{\"id\":null}"),
      ("POST", "/api/v1/orders", "[]"),
      ("POST", "/api/v1/orders", "{\"big\":\"\{"x".repeat(200)}\"}"),
      ("PUT", "/api/v1/orders/a%20b", "{\"n\":1}"),
      ("PUT", "/api/v1/orders/9999", "{}"),
      ("PATCH", "/api/v1/orders/1002", "{\"id\":7}"),
      ("PATCH", "/api/v1/orders/1002", "{\"n\":2}"),
      ("DELETE", "/api/v1/orders/1003", ""),
      ("DELETE", "/api/v1/orders/1003", ""),
    ] {
    let (meth, target, body) = request
    out.push(answered(h.shop(meth, target, body~)))
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"stub":"orders","stubSource":"file","status":201,"responseIndex":null,"crud":{"op":"create","key":"a b"},"variablesWritten":[],"dataWritten":["orders"],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":409,"responseIndex":null,"crud":{"op":"create","key":"1001"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":400,"responseIndex":null,"crud":{"op":"create","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":400,"responseIndex":null,"crud":{"op":"create","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":507,"responseIndex":null,"crud":{"op":"create","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":200,"responseIndex":null,"crud":{"op":"replace","key":"a b"},"variablesWritten":[],"dataWritten":["orders"],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":404,"responseIndex":null,"crud":{"op":"replace","key":"9999"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":400,"responseIndex":null,"crud":{"op":"update","key":"1002"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":200,"responseIndex":null,"crud":{"op":"update","key":"1002"},"variablesWritten":[],"dataWritten":["orders"],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":200,"responseIndex":null,"crud":{"op":"delete","key":"1003"},"variablesWritten":[],"dataWritten":["orders"],"dataError":null,"nearMiss":null}
      #|{"stub":"orders","stubSource":"file","status":404,"responseIndex":null,"crud":{"op":"delete","key":"1003"},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
    ),
  )
}

///|
test "an Ephemeral CRUD Stub writes the copies of its Session; after a reload removes its bucket or takes its key away, its writes answer 500 and write nothing" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  out.push(
    h.add_to_shop(
      (
        #|{ "crud": { "bucket": "orders", "path": "/mine", "headers": { "X-Mine": "yes" } } }
      ),
    ),
  )
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push("\{label}: \{@debug.to_string(outcome.matched)} \{reply(outcome)}")
  }
  step(
    "create",
    h.shop("POST", "/mine", body="{\"mine\":true}", session="test-a"),
  )
  step(
    "the file Stub sees it",
    h.shop("GET", "/api/v1/orders/1004", session="test-a"),
  )
  step(
    "another Session",
    h.shop("GET", "/api/v1/orders/1004", session="test-b"),
  )
  let reload = (shop : String) => {
    let result = h.engine.reload(
      {
        files: [("shop.yaml", @utf8.encode(shop))],
        body_files: data_body_files,
      },
      at=fixed_now,
    )
    out.push("reload: \{@debug.to_string(result.result)}")
  }
  reload(
    (
      #|mocks: [{ name: shop, hosts: [shop.example.com] }]
      #|data: [{ mock: shop, name: orders, json: [] }]
    ),
  )
  let before = h.engine.state_stats().bytes
  for
    request in [
      ("POST", "/mine", "{}"),
      ("PUT", "/mine/1", "{}"),
      ("PATCH", "/mine/1", "{}"),
      ("DELETE", "/mine/1", ""),
    ] {
    let (meth, target, body) = request
    let outcome = h.shop(meth, target, body~, session="test-a")
    out.push(
      "without key, \{meth}: \{response(outcome)}\n\{data_journaled(outcome)}",
    )
  }
  reload(
    (
      #|mocks: [{ name: shop, hosts: [shop.example.com] }]
    ),
  )
  step(
    "without the bucket",
    h.shop("POST", "/mine", body="{}", session="test-a"),
  )
  out.push("nothing written: \{h.engine.state_stats().bytes == before}")
  inspect(
    out.join("\n"),
    content=(
      #|eph-1
      #|create: Some(Ephemeral("eph-1")) 201 {"mine":true,"id":1004}
      #|the file Stub sees it: Some(FromFile("orders")) 200 {"mine":true,"id":1004}
      #|another Session: Some(FromFile("orders")) 404 {"error":"no item with this key","stub":"orders","key":"1004"}
      #|reload: Swapped
      #|without key, POST: 500
      #|Content-Type: application/json
      #|X-Mine: yes
      #|{"error":"data bucket changed","stub":"eph-1","bucket":"orders"}
      #|status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|without key, PUT: 500
      #|Content-Type: application/json
      #|X-Mine: yes
      #|{"error":"data bucket changed","stub":"eph-1","bucket":"orders"}
      #|status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|without key, PATCH: 500
      #|Content-Type: application/json
      #|X-Mine: yes
      #|{"error":"data bucket changed","stub":"eph-1","bucket":"orders"}
      #|status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|without key, DELETE: 500
      #|Content-Type: application/json
      #|X-Mine: yes
      #|{"error":"data bucket changed","stub":"eph-1","bucket":"orders"}
      #|status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|reload: Swapped
      #|without the bucket: Some(Ephemeral("eph-1")) 500 {"error":"unknown data bucket","stub":"eph-1","bucket":"orders"}
      #|nothing written: true
    ),
  )
}
