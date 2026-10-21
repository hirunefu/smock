// Seam 2 tests of response templates: `smock check` and startup report
// template errors, a templated stream and a failed template on the wire,
// and `smock render` and the Admin render operation show templated output.

///|
/// A Mock that streams templated prices, with a seed, and answers
/// `/greeting` from a templated body file.
let templated_definitions : Array[(String, String)] = [
  (
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
      #|        - { delay: 50, data: "${query.note ?? 'line 1'}\nline 2" }
      #|    fault: { seed: 7 }
      #|  - id: greeting
      #|    mock: market
      #|    request: { method: GET, path: /greeting }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      headers: { Content-Type: text/html, X-Name: "${query.name}" }
      #|      bodyFile: greeting.html
    ),
  ),
  ("files/greeting.html", "<p>Hello, ${query.name ?? 'guest'}</p>\n"),
  (
    "samples/stream.json", "{ \"path\": \"/v1/prices/stream\", \"query\": { \"symbol\": \"ABC\" } }",
  ),
]

///|
async test "smock check reports a template syntax error with the file and the JSON Pointer of the field, bodyFile for a body file, and exits 1" {
  with_definitions(
    [
      (
        "users.yaml",
        (
          #|mocks:
          #|  - name: users
          #|stubs:
          #|  - id: get-user
          #|    mock: users
          #|    response:
          #|      status: 200
          #|      template: true
          #|      headers: { X-Id: "${path[1}" }
          #|      json: { id: "${fake.nope()}", lines: { $each: body.items, as: loop, do: 1 } }
          #|  - id: page
          #|    mock: users
          #|    response: { status: 200, template: true, bodyFile: page.html }
        ),
      ),
      ("files/page.html", "<h1>\n  ${query.title\n</h1>\n"),
    ],
    dir => {
      inspect(
        check([dir]),
        content=(
          #|status 1
          #|users.yaml: /stubs/0/response/headers/X-Id: template: column 9: expected ], found "}"
          #|users.yaml: /stubs/0/response/json/id: template: column 3: unknown helper "fake.nope": not one of the helpers smock has
          #|users.yaml: /stubs/0/response/json/lines/as: template: "loop" cannot be a loop variable: it is a request field, env, loop or a reserved word
          #|users.yaml: /stubs/1/response/bodyFile: template: line 3, column 1: expected } to end the ${, found "<"
          #|
        ),
      )
    },
  )
}

///|
async test "smock serve logs a template syntax error with its file and JSON Pointer and exits with status 1 at startup" {
  with_definitions(
    [
      (
        "users.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [{ "id": "get-user", "mock": "users",
          #|    "response": { "status": 200, "template": true, "body": "${for x in body}" } }] }
        ),
      ),
    ],
    dir => {
      let stopped = run_smock(["serve", "--dir", dir, "--port", "0"])
      inspect(
        "status \{stopped.status}\n" + log_entries(stopped.logs),
        content=(
          #|status 1
          #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
          #|{"level":"info","msg":"random seed","seed":"*"}
          #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
          #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
          #|{"level":"error","msg":"invalid definitions","file":"users.json","pointer":"/stubs/0/response/body","error":"template: column 3: for is reserved"}
        ),
      )
    },
  )
}

///|
async test "a templated stream reaches the client with a templated line break as several data lines, and a failed template gets the 500 that the Journal records" {
  with_definitions(templated_definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = @http.Client("http://127.0.0.1:\{smock.port}")
      defer client.close()
      let response = client.get(
        "/v1/prices/stream?symbol=ABC&note=first%0Asecond",
      )
      let out = [render_response(response, "").trim_end(chars="\n").to_owned()]
      for _ in 0..<2 {
        let event = @async.with_timeout_opt(patience_ms, () => {
          client.read_until("\n\n")
        })
        guard event is Some(Some(event)) else {
          fail("the stream ended early:\n\{out.join("\n")}")
        }
        // The time the event was rendered at changes from run to run.
        let event = match event.find("\"at\":\"") {
          Some(i) => "\{event[:i + 6]}<time>\"}"
          None => event
        }
        out.push(event)
      }
      out.push(smock.get("/greeting?name=%3Cb%3EAnn%3C%2Fb%3E"))
      out.push(smock.get("/greeting"))
      let journal = smock.admin(
        "POST",
        "/v1/journal/query",
        body="{ \"filter\": { \"path\": \"/greeting\" } }",
      )
      guard journal.json() is { "entries": Array(entries), .. } else {
        fail("no entries")
      }
      for entry in entries {
        guard entry is { "status": status, "templateError": error, .. } else {
          fail("not an entry")
        }
        out.push(
          "Journal: status \{status.stringify()}, templateError \{error.stringify()}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|200 OK
          #|Content-Type: text/event-stream
          #|Cache-Control: no-cache
          #|Smock-Mock: market; via=default
          #|Transfer-Encoding: chunked
          #|event: price
          #|id: 1
          #|data: {"symbol":"ABC","price":105.49,"at":"<time>"}
          #|data: first
          #|data: second
          #|data: line 2
          #|200 OK
          #|Content-Type: text/html
          #|X-Name: <b>Ann</b>
          #|Smock-Mock: market; via=default
          #|Content-Length: 37
          #|
          #|<p>Hello, &lt;b&gt;Ann&lt;/b&gt;</p>
          #|
          #|500 Internal Server Error
          #|Content-Type: application/json
          #|Smock-Mock: market; via=default
          #|Content-Length: 111
          #|
          #|{"error":"template failed","stub":"greeting","at":"/response/headers/X-Name","message":"query.name is missing"}
          #|Journal: status 200, templateError null
          #|Journal: status 500, templateError {"at":"/response/headers/X-Name","message":"query.name is missing"}
        ),
      )
    })
  })
}

///|
async test "smock render and the Admin render operation show templated events; given a time and a seed, the rendering is the same on every run" {
  with_definitions(templated_definitions, dir => {
    let args = [
      "--dir",
      dir,
      "price-stream",
      "--request",
      "\{dir}/samples/stream.json",
      "--time",
      "2026-10-13T09:00:00Z",
      "--seed",
      "7",
    ]
    let (status, first, _) = render_output(args)
    let (_, second, _) = render_output(args)
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let from_admin = []
      for _ in 0..<2 {
        let response = smock.render(
          "price-stream",
          sample="\{dir}/samples/stream.json",
          query="?time=2026-10-13T09:00:00Z&seed=7",
        )
        from_admin.push(rendered(response.json()))
      }
      let from_cli = rendered(@json.parse(first))
      let same = from_admin.iter().all(r => r == from_cli)
      inspect(
        [
          "status \{status}, the same on every run: \{first == second}",
          "the Admin render operation gives the same: \{same}",
          first,
        ].join("\n"),
        content=(
          #|status 0, the same on every run: true
          #|the Admin render operation gives the same: true
          #|{
          #|  "stub": "price-stream",
          #|  "mock": "market",
          #|  "time": "2026-10-13T09:00:00.000Z",
          #|  "seed": 7,
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
          #|        "delay": 50,
          #|        "data": "line 1\nline 2"
          #|      }
          #|    ]
          #|  },
          #|  "templateError": null,
          #|  "failed": []
          #|}
          #|
        ),
      )
    })
  })
}
