// Seam 1 tests of rendering: a named Stub's response for a sample request,
// with the conditions the sample fails, as `smock render` and the Admin
// render operation show them.

///|
/// A Mock `users` with a Stub that has every kind of condition, one that
/// answers from a body file and one without conditions.
let render_files : Array[(String, String)] = [
  (
    "users.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] }],
      #|  "stubs": [
      #|    { "id": "create-user", "mock": "users",
      #|      "request": { "method": "POST", "path": "/users",
      #|        "query": { "dry": "yes", "page": { "pattern": "[0-9]+" } },
      #|        "headers": { "X-Api-Key": "secret" },
      #|        "body": { "json": { "name": "Zoë" } } },
      #|      "response": { "status": 201,
      #|        "headers": { "Location": "/users/7", "Content-Type": "application/json" },
      #|        "body": "{\"id\":7,\"name\":\"Zoë\"}" } },
      #|    { "id": "get-user", "mock": "users", "request": { "path": "/users/1" },
      #|      "response": { "status": 200,
      #|        "headers": { "Content-Type": "application/json" },
      #|        "bodyFile": "users/1.json" } },
      #|    { "id": "logo", "mock": "users", "request": { "path": "/logo.png" },
      #|      "response": { "status": 200, "bodyFile": "logo.png" } },
      #|    { "id": "anything", "mock": "users", "response": { "status": 204 } } ] }
    ),
  ),
]

///|
/// The body files of `render_files`.
let render_body_files : Array[(String, Bytes)] = [
  ("users/1.json", b"{\"id\":1,\"name\":\"Alice\"}\n"),
  ("logo.png", b"\x89PNG\r\n\x1a\n\x00\xff"),
]

///|
/// Renders the Stub `id` for the sample request `sample`, given as its
/// JSON, at the harness's time and with its generator, and shows the
/// rendering as `smock render` prints it.
fn Harness::render(self : Harness, id : String, sample : Json) -> String raise {
  let rendering = self.engine.render(
    id,
    @engine.SampleRequest::from_json(sample),
    now=self.now,
    fresh_seed=() => 7,
  )
  rendering.to_json().stringify(indent=2)
}

///|
test "a sample request that meets every condition renders the Stub's status, headers and body, with no failed conditions" {
  let h = harness(render_files, body_files=render_body_files)
  inspect(
    h.render("create-user", {
      "method": "POST",
      "path": "/users",
      "query": { "dry": "yes", "page": ["x", "2"] },
      "headers": { "X-Api-Key": "secret" },
      "body": "{\"name\": \"Zoë\", \"age\": 30}",
    }),
    content=(
      #|{
      #|  "stub": "create-user",
      #|  "mock": "users",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "response": {
      #|    "status": 201,
      #|    "headers": [
      #|      {
      #|        "name": "Location",
      #|        "value": "/users/7"
      #|      },
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"id\":7,\"name\":\"Zoë\"}",
      #|      "size": 22,
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
test "a sample request that fails several conditions still renders the Stub's response, and lists the failed conditions with expected and actual values" {
  let h = harness(render_files, body_files=render_body_files)
  inspect(
    h.render("create-user", {
      "path": "/users",
      "query": { "page": "two" },
      "headers": { "x-api-key": ["wrong", "also wrong"] },
      "body": "not JSON",
    }),
    content=(
      #|{
      #|  "stub": "create-user",
      #|  "mock": "users",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "response": {
      #|    "status": 201,
      #|    "headers": [
      #|      {
      #|        "name": "Location",
      #|        "value": "/users/7"
      #|      },
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"id\":7,\"name\":\"Zoë\"}",
      #|      "size": 22,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": null,
      #|  "failed": [
      #|    {
      #|      "condition": "method",
      #|      "expected": "POST",
      #|      "actual": [
      #|        "GET"
      #|      ]
      #|    },
      #|    {
      #|      "condition": "query:dry",
      #|      "expected": "yes",
      #|      "actual": []
      #|    },
      #|    {
      #|      "condition": "query:page",
      #|      "expected": {
      #|        "pattern": "[0-9]+"
      #|      },
      #|      "actual": [
      #|        "two"
      #|      ]
      #|    },
      #|    {
      #|      "condition": "header:x-api-key",
      #|      "expected": "secret",
      #|      "actual": [
      #|        "wrong",
      #|        "also wrong"
      #|      ]
      #|    },
      #|    {
      #|      "condition": "body",
      #|      "expected": {
      #|        "json": {
      #|          "name": "Zoë"
      #|        }
      #|      },
      #|      "actual": [
      #|        "not JSON"
      #|      ]
      #|    }
      #|  ]
      #|}
    ),
  )
}

///|
test "a Stub that answers from a body file renders the bytes of the file, as text when they are UTF-8 and in base64 otherwise" {
  let h = harness(render_files, body_files=render_body_files)
  inspect(
    h.render("get-user", { "path": "/users/1" }) +
    "\n" +
    h.render("logo", { "path": "/logo.png" }),
    content=(
      #|{
      #|  "stub": "get-user",
      #|  "mock": "users",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "application/json"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"id\":1,\"name\":\"Alice\"}\n",
      #|      "size": 24,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
      #|{
      #|  "stub": "logo",
      #|  "mock": "users",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [],
      #|    "body": {
      #|      "encoding": "base64",
      #|      "data": "iVBORw0KGgoA/w==",
      #|      "size": 10,
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
/// The error rendering the Stub `id` for `sample` gives, or `rendered`.
fn Harness::render_error(self : Harness, id : String, sample : Json) -> String {
  try self.render(id, sample) catch {
    @engine.RenderFailure::UnknownStub(_) as err =>
      "unknown Stub: \{err.message()}"
    @engine.InvalidSample(_) as err => "invalid sample: \{err.message()}"
    err => "other error: \{err}"
  } noraise {
    _ => "rendered"
  }
}

///|
test "rendering a Stub ID that no Stub from the Definition files has fails with an error that names it" {
  let h = harness(render_files, body_files=render_body_files)
  inspect(
    [
      h.render_error("get-user", {}),
      h.render_error("get-users", {}),
      h.render_error("Get-User", {}),
      h.render_error("", {}),
      h.render_error("users", {}),
      h.render_error("no \"such\"\nStub", {}),
    ].join("\n"),
    content=(
      #|rendered
      #|unknown Stub: no Stub from the Definition files has the ID "get-users"
      #|unknown Stub: no Stub from the Definition files has the ID "Get-User"
      #|unknown Stub: no Stub from the Definition files has the ID ""
      #|unknown Stub: no Stub from the Definition files has the ID "users"
      #|unknown Stub: no Stub from the Definition files has the ID "no \"such\"\nStub"
    ),
  )
}

///|
/// The conditions of the Stub `id` that `sample` fails, one per line, as
/// `<condition>: expected <expected>, actual <actual>` in JSON.
fn Harness::failed(self : Harness, id : String, sample : Json) -> String raise {
  let rendering = self.engine.render(
    id,
    @engine.SampleRequest::from_json(sample),
    now=self.now,
    fresh_seed=() => 7,
  )
  rendering.failed
  .map(failed => {
    guard failed.to_json() is Object(json) else { return "not an object" }
    let expected = json.get("expected").unwrap_or(Json::null()).stringify()
    let actual = json.get("actual").unwrap_or(Json::null()).stringify()
    "\{failed.condition.to_string()}: expected \{expected}, actual \{actual}"
  })
  .join("\n")
}

///|
test "an empty sample request is GET / without query, headers, body or Session" {
  let h = harness(render_files, body_files=render_body_files)
  inspect(
    h.failed("create-user", {}),
    content=(
      #|method: expected "POST", actual ["GET"]
      #|path: expected "/users", actual ["/"]
      #|query:dry: expected "yes", actual []
      #|query:page: expected {"pattern":"[0-9]+"}, actual []
      #|header:x-api-key: expected "secret", actual []
      #|body: expected {"json":{"name":"Zoë"}}, actual [""]
    ),
  )
}

///|
test "a sample request that does not have the shape of the SampleRequest schema fails with an error that points at the value" {
  let h = harness(render_files, body_files=render_body_files)
  let samples : Array[Json] = [
    [],
    "GET /",
    Json::null(),
    { "method": "" },
    { "method": 1 },
    { "path": "users" },
    { "path": Json::null() },
    { "query": ["a", "b"] },
    { "query": { "page": 2 } },
    { "query": { "page": ["1", Json::null()] } },
    { "headers": "X-A: 1" },
    { "headers": { "X/A~B": { "value": "1" } } },
    { "body": { "name": "Zoë" } },
    { "session": 7 },
    { "method": "GET", "target": "/users" },
  ]
  inspect(
    samples
    .map(sample => {
      "\{sample.stringify()} -> \{h.render_error("get-user", sample)}"
    })
    .join("\n"),
    content=(
      #|[] -> invalid sample: must be a JSON object
      #|"GET /" -> invalid sample: must be a JSON object
      #|null -> invalid sample: must be a JSON object
      #|{"method":""} -> invalid sample: /method: must be a non-empty string
      #|{"method":1} -> invalid sample: /method: must be a non-empty string
      #|{"path":"users"} -> invalid sample: /path: must be a string that starts with /
      #|{"path":null} -> invalid sample: /path: must be a string that starts with /
      #|{"query":["a","b"]} -> invalid sample: /query: must be an object
      #|{"query":{"page":2}} -> invalid sample: /query/page: must be a string or an array of strings
      #|{"query":{"page":["1",null]}} -> invalid sample: /query/page/1: must be a string
      #|{"headers":"X-A: 1"} -> invalid sample: /headers: must be an object
      #|{"headers":{"X/A~B":{"value":"1"}}} -> invalid sample: /headers/X~1A~0B: must be a string or an array of strings
      #|{"body":{"name":"Zoë"}} -> invalid sample: /body: must be a string
      #|{"session":7} -> invalid sample: /session: must be a string or null
      #|{"method":"GET","target":"/users"} -> invalid sample: /target: is not a known field
    ),
  )
}

///|
test "rendering changes no engine state: neither a Stub's generator nor the random source advances" {
  let file = faults_file([coin_flips("/seeded", seed=42), coin_flips("/a")])
  let rendered = harness([file])
  for _ in 0..<5 {
    ignore(rendered.render("seeded", { "path": "/seeded" }))
    ignore(rendered.render("a", { "path": "/elsewhere" }))
  }
  let untouched = harness([file])
  inspect(
    decisions(untouched, "/a", 8) == decisions(rendered, "/a", 8),
    content="true",
  )
  // The decisions of seed 42 from its first request on, as a seeded Stub
  // that never rendered gives them (faults_test.mbt).
  inspect(
    decisions(rendered, "/seeded", 8).join("\n"),
    content=(
      #|delay 0, Close
      #|delay 0
      #|delay 395
      #|delay 572
      #|delay 818
      #|delay 0, Close
      #|delay 594, Close
      #|delay 0
    ),
  )
}

///|
test "a Stub with Faults renders its plain response: rendering decides no Fault" {
  let h = harness([faults_file([coin_flips("/seeded", seed=42)])])
  inspect(
    h.render("seeded", { "path": "/seeded" }),
    content=(
      #|{
      #|  "stub": "seeded",
      #|  "mock": "m",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 42,
      #|  "responseIndex": null,
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "ok",
      #|      "size": 2,
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
test "a sample request's path and query values are compared as given: percent-decoded, without the query" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "odd", "mock": "m",
        #|    "request": { "path": "/files/50% off/a+b?c#d",
        #|      "query": { "q": "a&b=c+d %41", "naïve name": "Zoë" } },
        #|    "response": { "status": 200 } }] }
      ),
    ),
  ])
  inspect(
    h.failed("odd", {
      "path": "/files/50% off/a+b?c#d",
      "query": { "q": "a&b=c+d %41", "naïve name": "Zoë" },
    }),
    content="",
  )
  inspect(
    h.failed("odd", {
      "path": "/files/50%25 off/a+b",
      "query": { "q": ["a", "b=c d A"], "naïve+name": "Zoë" },
    }),
    content=(
      #|path: expected "/files/50% off/a+b?c#d", actual ["/files/50%25 off/a+b"]
      #|query:q: expected "a&b=c+d %41", actual ["a","b=c d A"]
      #|query:naïve name: expected "Zoë", actual []
    ),
  )
}

///|
test "a json condition with patterns renders like any body condition: met by a sample whose values match, failed as body otherwise" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "create-user", "mock": "m",
        #|    "request": { "body": { "json": {
        #|      "email": { "pattern": ".*@example\\.com" }, "age": { "pattern": "[0-9]+" } } } },
        #|    "response": { "status": 201 } }] }
      ),
    ),
  ])
  inspect(
    h.failed("create-user", {
      "body": "{\"email\": \"zoë@example.com\", \"age\": 30}",
    }),
    content="",
  )
  inspect(
    h.failed("create-user", {
      "body": "{\"email\": \"zoë@example.com\", \"age\": 30.5}",
    }),
    content=(
      #|body: expected {"json":{"email":{"pattern":".*@example\\.com"},"age":{"pattern":"[0-9]+"}}}, actual ["{\"email\": \"zoë@example.com\", \"age\": 30.5}"]
    ),
  )
}

///|
test "a Stub that streams Server-Sent Events renders its events, with the Content-Type smock sends, and no body" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "stream", "mock": "m",
        #|    "response": { "status": 200,
        #|      "headers": { "Cache-Control": "no-cache" },
        #|      "events": [
        #|        { "data": "first" },
        #|        { "delay": 250, "event": "update", "id": "2", "data": "line 1\nline 2" } ] } }] }
      ),
    ),
  ])
  inspect(
    h.render("stream", {}),
    content=(
      #|{
      #|  "stub": "stream",
      #|  "mock": "m",
      #|  "time": "2026-10-12T14:30:05.123Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
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
      #|        "data": "first"
      #|      },
      #|      {
      #|        "delay": 250,
      #|        "event": "update",
      #|        "id": "2",
      #|        "data": "line 1\nline 2"
      #|      }
      #|    ]
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
}

///|
test "a header given an array renders as one name and value per value, in order, each value rendered on its own" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [{ "id": "login", "mock": "m",
        #|    "response": { "status": 200, "template": true,
        #|      "headers": { "Set-Cookie": ["session=${query.s}", "theme=dark"], "X-A": "1" } } }] }
      ),
    ),
  ])
  let rendering = @json.parse(h.render("login", { "query": { "s": "abc" } }))
  guard rendering is { "response": { "headers": headers, .. }, .. } else {
    fail("no headers")
  }
  inspect(
    headers.stringify(),
    content=(
      #|[{"name":"Set-Cookie","value":"session=abc"},{"name":"Set-Cookie","value":"theme=dark"},{"name":"X-A","value":"1"}]
    ),
  )
}

///|
test "a sample request's Session is a string or null, and is no Session when null or absent" {
  let session = (sample : Json) => {
    @engine.SampleRequest::from_json(sample).session
  }
  debug_inspect(
    [
      session({}),
      session({ "session": Json::null() }),
      session({ "session": "checkout-test-42" }),
    ],
    content=(
      #|[None, None, Some("checkout-test-42")]
    ),
  )
}
