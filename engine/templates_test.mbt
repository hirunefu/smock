// Seam 1 tests of response templates (the decision on "Decide the template
// syntax"): each worked example of the decision, then the grammar, the
// request fields, loops, conditionals, helpers, escaping, missing values
// and the bounds.

///|
/// The first worked example: a JSON body built from the request, with a
/// templated header.
let get_user_example : (String, String) = (
  "users.yaml",
  (
    #|mocks:
    #|  - name: users
    #|stubs:
    #|  - id: get-user
    #|    mock: users
    #|    request: { method: GET, path: { pattern: "/users/[0-9]+" } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      headers:
    #|        X-Request-Id: ${header.x-request-id ?? 'none'}
    #|      json:
    #|        id: ${path[1]}
    #|        lang: ${query.lang ?? 'en'}
    #|        requestId: ${header.x-request-id ?? 'none'}
  ),
)

///|
test "worked example: a JSON body built from the request, with a templated header" {
  let h = harness([get_user_example])
  inspect(
    response(
      h.send("GET", "/users/42?lang=ja", headers=[("X-Request-Id", "req-7")]),
    ),
    content=(
      #|200
      #|X-Request-Id: req-7
      #|Content-Type: application/json
      #|Smock-Mock: users; via=default
      #|{"id":"42","lang":"ja","requestId":"req-7"}
    ),
  )
  inspect(
    response(h.send("GET", "/users/42")),
    content=(
      #|200
      #|X-Request-Id: none
      #|Content-Type: application/json
      #|Smock-Mock: users; via=default
      #|{"id":"42","lang":"en","requestId":"none"}
    ),
  )
}

///|
test "in a JSON Definition file, ${…} sits in an ordinary string, with single quotes for string literals, and means what the YAML file means" {
  let json =
    #|{ "mocks": [{ "name": "users" }],
    #|  "stubs": [{ "id": "get-user", "mock": "users",
    #|    "request": { "method": "GET", "path": { "pattern": "/users/[0-9]+" } },
    #|    "response": { "status": 200, "template": true,
    #|      "headers": { "X-Request-Id": "${header.x-request-id ?? 'none'}" },
    #|      "json": { "id": "${path[1]}", "lang": "${query.lang ?? 'en'}",
    #|        "requestId": "${header.x-request-id ?? 'none'}" } } }] }
  inspect(
    load_one("users.json", json) ==
    load_one(get_user_example.0, get_user_example.1),
    content="true",
  )
}

///|
/// The second worked example: a loop and a conditional.
let create_order_example : (String, String) = (
  "orders.yaml",
  (
    #|mocks:
    #|  - name: orders
    #|stubs:
    #|  - id: create-order
    #|    mock: orders
    #|    request: { method: POST, path: /orders }
    #|    response:
    #|      status: 201
    #|      template: true
    #|      json:
    #|        orderId: ${fake.uuid()}
    #|        customer: ${body.customer.name}
    #|        lines:
    #|          $each: body.items
    #|          as: item
    #|          do:
    #|            sku: ${item.sku}
    #|            qty: ${item.qty}
    #|            status:
    #|              $if: item.qty == 0
    #|              then: backordered
    #|              else: reserved
  ),
)

///|
test "worked example: a loop and a conditional" {
  let h = harness([create_order_example])
  inspect(
    response(
      h.send(
        "POST",
        "/orders",
        body=(
          #|{"customer":{"name":"Ada"},"items":[{"sku":"A-1","qty":2},{"sku":"B-7","qty":0}]}
        ),
      ),
    ),
    content=(
      #|201
      #|Content-Type: application/json
      #|Smock-Mock: orders; via=default
      #|{"orderId":"3f3aa8ab-63c8-44d2-be27-b6134c76381b","customer":"Ada","lines":[{"sku":"A-1","qty":2,"status":"reserved"},{"sku":"B-7","qty":0,"status":"backordered"}]}
    ),
  )
}

///|
test "worked example: a body without customer.name gets the 500 that names the field, and the Journal records the error" {
  let h = harness([create_order_example])
  inspect(
    describe(h.send("POST", "/orders", body="{\"items\":[]}")),
    content=(
      #|plan:
      #|  status: 500
      #|  header: Content-Type: application/json
      #|  header: Smock-Mock: orders; via=default
      #|  body: "{\"error\":\"template failed\",\"stub\":\"create-order\",\"at\":\"/response/json/customer\",\"message\":\"body.customer.name is missing\"}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("orders")
      #|  via_default: true
      #|  request: POST /orders HTTP/1.1
      #|  body: "{\"items\":[]}"
      #|  stub: Some("create-order")
      #|  status: Some(500)
      #|  fault: None
      #|  template_error: at /response/json/customer: "body.customer.name is missing"
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
/// The third worked example: templated Server-Sent Events, with a seed.
let price_stream_example : (String, String) = (
  "market.yaml",
  (
    #|mocks:
    #|  - name: market
    #|stubs:
    #|  - id: price-stream
    #|    mock: market
    #|    request: { method: GET, path: /v1/prices/stream, query: { symbol: { pattern: "[A-Z]{1,5}" } } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      headers: { Cache-Control: no-cache }
    #|      events:
    #|        - { event: price, id: "1", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    #|        - { delay: 500, event: price, id: "2", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    #|        - { delay: 500, event: done, data: "[DONE]" }
    #|    fault: { seed: 7 }
  ),
)

///|
/// 2026-10-13T09:00:00Z, in milliseconds since the Unix epoch.
let nine_o_clock : Int64 = 1_791_882_000_000L

///|
test "worked example: templated Server-Sent Events, the same on every run from the Stub's seed" {
  let first_run = harness([price_stream_example])
  first_run.now = nine_o_clock
  let stream = response(first_run.send("GET", "/v1/prices/stream?symbol=ABC"))
  inspect(
    stream,
    content=(
      #|200
      #|Content-Type: text/event-stream
      #|Cache-Control: no-cache
      #|Smock-Mock: market; via=default
      #|after 0 ms: event "price", id "1", data "{\"symbol\":\"ABC\",\"price\":105.49,\"at\":\"2026-10-13T09:00:00.000Z\"}"
      #|after 500 ms: event "price", id "2", data "{\"symbol\":\"ABC\",\"price\":101.49,\"at\":\"2026-10-13T09:00:00.500Z\"}"
      #|after 500 ms: event "done", id -, data "[DONE]"
      #|
    ),
  )
  // Another run, with another process seed, gets the same stream.
  let second_run = harness([price_stream_example], process_seed=99)
  second_run.now = nine_o_clock
  inspect(
    response(second_run.send("GET", "/v1/prices/stream?symbol=ABC")) == stream,
    content="true",
  )
}

///|
test "worked example: a templated body file, escaped for its text/html Content-Type" {
  let h = harness(
    [
      (
        "web.yaml",
        (
          #|mocks:
          #|  - name: web
          #|stubs:
          #|  - id: greeting
          #|    mock: web
          #|    request: { method: GET, path: /greeting }
          #|    response:
          #|      status: 200
          #|      template: true
          #|      headers: { Content-Type: text/html }
          #|      bodyFile: greeting.html
        ),
      ),
    ],
    body_files=[("greeting.html", b"<p>Hello, ${query.name ?? 'guest'}</p>")],
  )
  inspect(
    response(h.send("GET", "/greeting?name=<b>Ann</b>")),
    content=(
      #|200
      #|Content-Type: text/html
      #|Smock-Mock: web; via=default
      #|<p>Hello, &lt;b&gt;Ann&lt;/b&gt;</p>
    ),
  )
  inspect(
    response(h.send("GET", "/greeting")),
    content=(
      #|200
      #|Content-Type: text/html
      #|Smock-Mock: web; via=default
      #|<p>Hello, guest</p>
    ),
  )
}

///|
/// Renders the Stub `id` of `h` for `sample` at `now`, with `seed` if
/// given and `fresh` as the fresh seed, as `smock render` prints it.
fn render_with(
  h : Harness,
  id : String,
  sample : Json,
  now~ : Int64,
  seed? : UInt64,
  fresh? : UInt64 = 1234,
) -> String raise {
  let fresh_seed = () => fresh
  let rendering = h.engine.render(
    id,
    @engine.SampleRequest::from_json(sample),
    now~,
    seed?,
    fresh_seed~,
  )
  rendering.to_json().stringify(indent=2)
}

///|
test "rendering a templated Stub shows its rendered events, with the time and the seed it used; given both, it is the same on every run" {
  let render = () => {
    render_with(
      harness([price_stream_example]),
      "price-stream",
      { "path": "/v1/prices/stream", "query": { "symbol": "ABC" } },
      now=nine_o_clock,
      seed=7,
    )
  }
  let first = render()
  inspect(
    first,
    content=(
      #|{
      #|  "stub": "price-stream",
      #|  "mock": "market",
      #|  "time": "2026-10-13T09:00:00.000Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "text/event-stream"
      #|      },
      #|      {
      #|        "name": "Cache-Control",
      #|        "value": "no-cache"
      #|      }
      #|    ],
      #|    "body": null,
      #|    "events": [
      #|      {
      #|        "delay": 0,
      #|        "event": "price",
      #|        "id": "1",
      #|        "data": "{\"symbol\":\"ABC\",\"price\":105.49,\"at\":\"2026-10-13T09:00:00.000Z\"}"
      #|      },
      #|      {
      #|        "delay": 500,
      #|        "event": "price",
      #|        "id": "2",
      #|        "data": "{\"symbol\":\"ABC\",\"price\":101.49,\"at\":\"2026-10-13T09:00:00.500Z\"}"
      #|      },
      #|      {
      #|        "delay": 500,
      #|        "event": "done",
      #|        "data": "[DONE]"
      #|      }
      #|    ]
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
  inspect(render() == first, content="true")
}

///|
test "rendering with seed S shows what the first matched request of a Stub with fault.seed S gets; without a seed it uses the Stub's, or a fresh one" {
  let sample : Json = {
    "path": "/v1/prices/stream",
    "query": { "symbol": "ABC" },
  }
  let h = harness([price_stream_example])
  h.now = nine_o_clock
  let events = (rendering : String) => {
    guard @json.parse(rendering) is { "response": { "events": events, .. }, .. } else {
      return "no events"
    }
    events.stringify()
  }
  let with_seed_7 = events(
    render_with(h, "price-stream", sample, now=nine_o_clock, seed=7),
  )
  // The Stub has fault.seed 7.
  let with_stub_seed = render_with(h, "price-stream", sample, now=nine_o_clock)
  inspect(events(with_stub_seed) == with_seed_7, content="true")
  inspect(with_stub_seed.contains("\"seed\": 7,"), content="true")
  // The first request the Stub matches gets the same events.
  guard h.send("GET", "/v1/prices/stream?symbol=ABC").plan.body is Events(sent) else {
    fail("no events")
  }
  inspect(
    sent.iter().map(event => event.data).collect().join("\n"),
    content=(
      #|{"symbol":"ABC","price":105.49,"at":"2026-10-13T09:00:00.000Z"}
      #|{"symbol":"ABC","price":101.49,"at":"2026-10-13T09:00:00.500Z"}
      #|[DONE]
    ),
  )
  inspect(
    with_seed_7.contains("105.49") && with_seed_7.contains("101.49"),
    content="true",
  )
  // A Stub without a seed renders with the fresh seed, and shows it.
  let unseeded = harness([create_order_example])
  let fresh = render_with(
    unseeded,
    "create-order",
    {
      "method": "POST",
      "path": "/orders",
      "body": "{\"customer\":{\"name\":\"Ada\"},\"items\":[]}",
    },
    now=nine_o_clock,
    fresh=99,
  )
  inspect(
    fresh,
    content=(
      #|{
      #|  "stub": "create-order",
      #|  "mock": "orders",
      #|  "time": "2026-10-13T09:00:00.000Z",
      #|  "seed": 99,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "response": {
      #|    "status": 201,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"orderId\":\"15e7a3e5-e429-4e85-a58e-1144d766ec08\",\"customer\":\"Ada\",\"lines\":[]}",
      #|      "size": 78,
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
test "rendering a template that fails for the sample shows the 500 the request would get, and the error" {
  let h = harness([create_order_example])
  inspect(
    render_with(
      h,
      "create-order",
      { "method": "POST", "path": "/orders", "body": "{}" },
      now=nine_o_clock,
      seed=3,
    ),
    content=(
      #|{
      #|  "stub": "create-order",
      #|  "mock": "orders",
      #|  "time": "2026-10-13T09:00:00.000Z",
      #|  "seed": 3,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "response": {
      #|    "status": 500,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"error\":\"template failed\",\"stub\":\"create-order\",\"at\":\"/response/json/customer\",\"message\":\"body.customer.name is missing\"}",
      #|      "size": 122,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": {
      #|    "at": "/response/json/customer",
      #|    "message": "body.customer.name is missing"
      #|  },
      #|  "failed": []
      #|}
    ),
  )
}
