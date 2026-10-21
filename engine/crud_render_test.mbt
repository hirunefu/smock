// Seam 1 tests of rendering CRUD Stubs: the answer a CRUD Stub's operation
// would give to a sample request, from the sample's data, and the write it
// would make, as `smock render` and the Admin render operation show them.

///|
/// The rendering of the Stub `id` for the sample request `sample`, given as
/// its JSON, at the harness's time and with the seed 7 unless the Stub has
/// a `fault.seed`: the answer's status, headers and body, then the writes
/// it shows as `dataWrites`; or why it cannot be rendered.
fn Harness::render_answer(self : Harness, id : String, sample : Json) -> String {
  let sample = @engine.SampleRequest::from_json(sample) catch {
    error => return "invalid sample: \{error.message()}"
  }
  let rendering = self.engine.render(id, sample, now=self.now, fresh_seed=() => {
    7
  }) catch {
    error => return "cannot render: \{error.message()}"
  }
  let out = StringBuilder()
  out.write_string("\{rendering.status}\n")
  for header in rendering.headers {
    out.write_string("\{header.0}: \{header.1}\n")
  }
  match rendering.body {
    Bytes(body) => out.write_string(@utf8.decode_lossy(body))
    Events(_) => out.write_string("(events)")
  }
  let writes = rendering.data_writes.map(write => write.to_json())
  out.write_string("\ndataWrites: \{Json::array(writes).stringify()}")
  out.to_string()
}

///|
test "rendering the orders CRUD Stub for a list query shows the list it would answer from the sample's orders, with its count headers" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.render_json("orders", {
      "path": "/api/v1/orders",
      "query": { "status": "pending" },
      "data": {
        "orders": [
          { "id": 1, "status": "pending" },
          { "id": 2, "status": "paid" },
          { "id": 3, "status": "pending" },
        ],
      },
    }),
    content=(
      #|{
      #|  "stub": "orders",
      #|  "mock": "shop",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      },
      #|      {
      #|        "name": "X-Total-Count",
      #|        "value": "3"
      #|      },
      #|      {
      #|        "name": "X-Filtered-Count",
      #|        "value": "2"
      #|      },
      #|      {
      #|        "name": "Access-Control-Allow-Origin",
      #|        "value": "*"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "[{\"id\":1,\"status\":\"pending\"},{\"id\":3,\"status\":\"pending\"}]",
      #|      "size": 57,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
}

///|
test "rendering a create, replace, update or delete shows the answer a request would get and the write it would make, as the op of dataWrites that makes it; a read shows no write" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    case in [
      ("POST", "/api/v1/orders", "{\"customerId\":42,\"status\":\"pending\"}"),
      ("PUT", "/api/v1/orders/1002", "{\"status\":\"shipped\",\"total\":9.90}"),
      ("PATCH", "/api/v1/orders/1002", "{\"status\":\"paid\",\"id\":\"1002\"}"),
      ("DELETE", "/api/v1/orders/1003", "{\"ignored\":true}"),
      ("GET", "/api/v1/orders/1001", ""),
    ] {
    let (meth, path, body) = case
    out.push(
      "\{meth} \{path}: \{h.render_answer("orders", { "method": meth, "path": path, "body": body })}",
    )
  }
  inspect(
    out.join("\n---\n"),
    content=(
      #|POST /api/v1/orders: 201
      #|Content-Type: application/json
      #|Location: /api/v1/orders/1004
      #|Access-Control-Allow-Origin: *
      #|{"customerId":42,"status":"pending","id":1004}
      #|dataWrites: [{"op":"append","bucket":"orders","key":null,"value":{"customerId":42,"status":"pending","id":1004}}]
      #|---
      #|PUT /api/v1/orders/1002: 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"status":"shipped","total":9.9,"id":1002}
      #|dataWrites: [{"op":"set","bucket":"orders","key":"1002","value":{"status":"shipped","total":9.9}}]
      #|---
      #|PATCH /api/v1/orders/1002: 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"id":1002,"customerId":7,"status":"paid","total":9.9}
      #|dataWrites: [{"op":"merge","bucket":"orders","key":"1002","value":{"status":"paid","id":"1002"}}]
      #|---
      #|DELETE /api/v1/orders/1003: 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"id":1003,"customerId":42,"status":"paid","total":3}
      #|dataWrites: [{"op":"remove","bucket":"orders","key":"1003","value":null}]
      #|---
      #|GET /api/v1/orders/1001: 200
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"id":1001,"customerId":42,"status":"paid","total":12.5}
      #|dataWrites: []
    ),
  )
}

///|
test "rendering a sample that a CRUD Stub refuses shows its own failure answer, a 400, 404, 409 or 500, and no write" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  let full = Json::object({
    "orders": [{ "id": @definitions.max_integer_key.to_double() }],
  })
  for
    case in [
      ("GET", "/api/v1/orders/9999", "", Json::object({})),
      ("DELETE", "/api/v1/orders/9999", "", {}),
      ("POST", "/api/v1/orders", "{\"id\":1001}", {}),
      ("POST", "/api/v1/orders", "[1]", {}),
      ("POST", "/api/v1/orders", "{\"id\":null}", {}),
      ("PUT", "/api/v1/orders/1002", "{\"id\":1003}", {}),
      ("POST", "/api/v1/orders", "{}", full),
    ] {
    let (meth, path, body, data) = case
    out.push(
      "\{meth} \{path} \{body}: \{h.render_answer("orders", { "method": meth, "path": path, "body": body, "data": data })}",
    )
  }
  inspect(
    out.join("\n---\n"),
    content=(
      #|GET /api/v1/orders/9999 : 404
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"no item with this key","stub":"orders","key":"9999"}
      #|dataWrites: []
      #|---
      #|DELETE /api/v1/orders/9999 : 404
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"no item with this key","stub":"orders","key":"9999"}
      #|dataWrites: []
      #|---
      #|POST /api/v1/orders {"id":1001}: 409
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"key already exists","stub":"orders","key":"1001"}
      #|dataWrites: []
      #|---
      #|POST /api/v1/orders [1]: 400
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"body is not a JSON object","stub":"orders"}
      #|dataWrites: []
      #|---
      #|POST /api/v1/orders {"id":null}: 400
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"invalid key","stub":"orders"}
      #|dataWrites: []
      #|---
      #|PUT /api/v1/orders/1002 {"id":1003}: 400
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"key does not match the path","stub":"orders"}
      #|dataWrites: []
      #|---
      #|POST /api/v1/orders {}: 500
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"no new key","stub":"orders"}
      #|dataWrites: []
    ),
  )
}

///|
test "rendering a list shows the answer of its query, a 400 included, from the sample's data or else the initial value" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    case in [
      (
        Json::object({ "customerId": "42", "$sort": "-total" }),
        Json::object({}),
      ),
      ({ "$offset": "1", "$limit": "1" }, {}),
      ({ "$top": "3" }, {}),
      ({}, { "orders": [] }),
    ] {
    let (query, data) = case
    out.push(
      "\{query.stringify()} \{data.stringify()}: \{h.render_answer("orders", { "path": "/api/v1/orders", "query": query, "data": data })}",
    )
  }
  inspect(
    out.join("\n---\n"),
    content=(
      #|{"customerId":"42","$sort":"-total"} {}: 200
      #|Content-Type: application/json
      #|X-Total-Count: 3
      #|X-Filtered-Count: 2
      #|Access-Control-Allow-Origin: *
      #|[{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|dataWrites: []
      #|---
      #|{"$offset":"1","$limit":"1"} {}: 200
      #|Content-Type: application/json
      #|X-Total-Count: 3
      #|X-Filtered-Count: 3
      #|Access-Control-Allow-Origin: *
      #|[{"id":1002,"customerId":7,"status":"pending","total":9.9}]
      #|dataWrites: []
      #|---
      #|{"$top":"3"} {}: 400
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"invalid query parameter","stub":"orders","parameter":"$top"}
      #|dataWrites: []
      #|---
      #|{} {"orders":[]}: 200
      #|Content-Type: application/json
      #|X-Total-Count: 0
      #|X-Filtered-Count: 0
      #|Access-Control-Allow-Origin: *
      #|[]
      #|dataWrites: []
    ),
  )
}

///|
test "rendering a create into a bucket with uuid keys draws the new key from the seed, as the first request matched by a Stub with that fault.seed does" {
  let h = harness([
    (
      "tokens.yaml",
      (
        #|mocks:
        #|  - { name: auth, hosts: [auth.example.com] }
        #|data:
        #|  - { mock: auth, name: tokens, key: token, newKey: uuid, json: [] }
        #|stubs:
        #|  - id: tokens
        #|    mock: auth
        #|    fault: { seed: 5 }
        #|    crud: { bucket: tokens, path: /tokens }
      ),
    ),
  ])
  let sample : Json = {
    "method": "POST",
    "path": "/tokens",
    "body": "{\"user\":\"ann\"}",
  }
  let rendered = h.render_answer("tokens", sample)
  let again = h.render_answer("tokens", sample)
  let sent = response(
    h.send(
      "POST",
      "/tokens",
      headers=[("Host", "auth.example.com")],
      body="{\"user\":\"ann\"}",
    ),
  )
  inspect(
    "\{rendered}\nthe same again: \{rendered == again}\nsent:\n\{sent}",
    content=(
      #|201
      #|Content-Type: application/json
      #|Location: /tokens/27bc579a-af50-4383-8748-7b860f321914
      #|{"user":"ann","token":"27bc579a-af50-4383-8748-7b860f321914"}
      #|dataWrites: [{"op":"append","bucket":"tokens","key":null,"value":{"user":"ann","token":"27bc579a-af50-4383-8748-7b860f321914"}}]
      #|the same again: true
      #|sent:
      #|201
      #|Content-Type: application/json
      #|Location: /tokens/27bc579a-af50-4383-8748-7b860f321914
      #|{"user":"ann","token":"27bc579a-af50-4383-8748-7b860f321914"}
    ),
  )
}

///|
test "a sample whose method and path fit no operation of the CRUD Stub cannot be rendered, nor can a response index" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  for
    case in [
      ("HEAD", "/api/v1/orders"),
      ("DELETE", "/api/v1/orders"),
      ("POST", "/api/v1/orders/1001"),
      ("GET", "/api/v1/orders/1001/items"),
      ("GET", "/api/v1/orders/"),
      ("GET", "/API/v1/orders"),
      ("get", "/api/v1/orders"),
    ] {
    let (meth, path) = case
    out.push(h.render_answer("orders", { "method": meth, "path": path }))
  }
  let sample = @engine.SampleRequest::from_json({ "path": "/api/v1/orders" })
  out.push(
    try
      h.engine.render("orders", sample, now=h.now, response_index=0, fresh_seed=() => {
        7
      })
    catch {
      error => "cannot render: \{error.message()}"
    } noraise {
      _ => "rendered"
    },
  )
  inspect(
    out.join("\n"),
    content=(
      #|cannot render: the CRUD Stub "orders" serves no operation for "HEAD" at "/api/v1/orders": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "DELETE" at "/api/v1/orders": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "POST" at "/api/v1/orders/1001": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "GET" at "/api/v1/orders/1001/items": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "GET" at "/api/v1/orders/": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "GET" at "/API/v1/orders": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the CRUD Stub "orders" serves no operation for "get" at "/api/v1/orders": it serves GET and POST at "/api/v1/orders", and GET, PUT, PATCH and DELETE at "/api/v1/orders/<key>"
      #|cannot render: the Stub "orders" has no response 0: it is a CRUD Stub, which answers by its operation and has no responses
    ),
  )
}

///|
test "rendering a CRUD Stub neither reads nor writes a Session's copy, leaves the sample's data as it was, and applies no bound" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let out = []
  // A request of the Session s makes its copy.
  out.push(
    "s creates: \{reply(h.shop("POST", "/api/v1/orders", body="{\"note\":\"live\"}", session="s"))}",
  )
  let sample = @engine.SampleRequest::from_json({
    "method": "DELETE",
    "path": "/api/v1/orders/1",
    "session": "s",
    "data": { "orders": [{ "id": 1 }, { "id": 2 }] },
  })
  let render = (sample : @engine.SampleRequest) => {
    let rendering = h.engine.render("orders", sample, now=h.now, fresh_seed=() => {
      7
    })
    guard rendering.body is Bytes(body) else { "events" }
    "\{rendering.status} \{@utf8.decode_lossy(body)}"
  }
  out.push("render the delete: \{render(sample)}")
  out.push("render it again: \{render(sample)}")
  out.push("the sample's data: \{Json::object(sample.data).stringify()}")
  out.push(
    "render the list of s: \{render(@engine.SampleRequest::from_json({ "path": "/api/v1/orders", "session": "s" }))}",
  )
  out.push("s lists: \{reply(h.shop("GET", "/api/v1/orders", session="s"))}")
  // With a bound that the orders alone pass, a request gets 507, and a
  // rendering is as before.
  let bounded = harness(
    crud_shop(),
    body_files=data_body_files,
    state_max_bytes=100,
  )
  let create = "{\"note\":\"new\"}"
  out.push(
    "bounded, s creates: \{reply(bounded.shop("POST", "/api/v1/orders", body=create, session="s"))}",
  )
  out.push(
    "bounded, render the create: \{bounded.render_answer("orders", { "method": "POST", "path": "/api/v1/orders", "body": create })}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|s creates: 201 {"note":"live","id":1004}
      #|render the delete: 200 {"id":1}
      #|render it again: 200 {"id":1}
      #|the sample's data: {"orders":[{"id":1},{"id":2}]}
      #|render the list of s: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|s lists: 200 [{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3},{"note":"live","id":1004}]
      #|bounded, s creates: 507 {"error":"state limit reached","stub":"orders","message":"the writes would take per-Session state from 0 to 638 bytes, above its bound of 100 (--state-max-bytes)"}
      #|bounded, render the create: 201
      #|Content-Type: application/json
      #|Location: /api/v1/orders/1004
      #|Access-Control-Allow-Origin: *
      #|{"note":"new","id":1004}
      #|dataWrites: [{"op":"append","bucket":"orders","key":null,"value":{"note":"new","id":1004}}]
    ),
  )
}
