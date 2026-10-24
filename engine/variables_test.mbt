// Seam 1 tests of Variables: a Stub's `variables` written at the match
// decision, kept per Mock and Session, and read in templates as
// `vars.NAME`.

///|
/// The example of ticket #87: `POST /login` stores the user it is sent and
/// the one stored before, and echoes both; `GET /me` reads the user back.
let who_logged_in : (String, String) = (
  "shop.yaml",
  (
    #|mocks:
    #|  - name: shop
    #|stubs:
    #|  - id: login
    #|    mock: shop
    #|    request: { method: POST, path: /login }
    #|    variables:
    #|      user: ${body.user}
    #|      previous: ${vars.user ?? null}
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: { user: "${vars.user}", previous: "${vars.previous}" }
    #|  - id: whoami
    #|    mock: shop
    #|    request: { method: GET, path: /me }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: { user: "${vars.user ?? null}" }
  ),
)

///|
/// The status and the body of `outcome`'s response.
fn reply(outcome : @engine.Outcome) -> String {
  let body = match outcome.plan.body {
    Bytes(body) => @utf8.decode_lossy(body)
    Events(_) => "(events)"
  }
  "\{outcome.plan.status} \{body}"
}

///|
test "a POST stores what a later GET of the same Session returns, and another Session sees none of it" {
  let h = harness([who_logged_in])
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push("\{label}: \{reply(outcome)}")
  }
  step("test-a GET /me", h.send("GET", "/me", session="test-a"))
  step(
    "test-a logs in as ann",
    h.send("POST", "/login", body="{\"user\":\"ann\"}", session="test-a"),
  )
  step("test-a GET /me", h.send("GET", "/me", session="test-a"))
  step("test-b GET /me", h.send("GET", "/me", session="test-b"))
  step(
    "test-a logs in as bob",
    h.send("POST", "/login", body="{\"user\":\"bob\"}", session="test-a"),
  )
  step("test-a GET /me", h.send("GET", "/me", session="test-a"))
  step("no Session GET /me", h.send("GET", "/me"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a GET /me: 200 {"user":null}
      #|test-a logs in as ann: 200 {"user":"ann","previous":null}
      #|test-a GET /me: 200 {"user":"ann"}
      #|test-b GET /me: 200 {"user":null}
      #|test-a logs in as bob: 200 {"user":"bob","previous":"ann"}
      #|test-a GET /me: 200 {"user":"bob"}
      #|no Session GET /me: 200 {"user":null}
    ),
  )
}

///|
/// The Journal entry of `outcome`, in short: the status, the index of the
/// response, the Variables written and the template error.
fn journaled(outcome : @engine.Outcome) -> String {
  guard outcome.journal is Some(entry) else { return "no entry" }
  let status = entry.status.map_or("no status", status => status.to_string())
  let index = entry.response_index.map_or("null", index => index.to_string())
  let written = entry.variables_written.iter().collect().join(", ")
  let error = match entry.template_error {
    Some(error) => "\{error.at}: \{error.message}"
    None => "none"
  }
  "status \{status}, responseIndex \{index}, variablesWritten [\{written}], templateError \{error}"
}

///|
/// Mock `m`, with the Stubs given as YAML list items.
fn variables_file(stubs : String) -> (String, String) {
  ("m.yaml", "mocks:\n  - name: m\nstubs:\n\{stubs}")
}

///|
test "every value is rendered against the Variables as they were before the request, then all are written at once, and the response sees the new values" {
  let h = harness([
    variables_file(
      (
        #|  - id: swap
        #|    mock: m
        #|    request: { method: POST, path: /swap }
        #|    variables:
        #|      a: ${vars.b ?? 'no b'}
        #|      b: ${vars.a ?? 'no a'}
        #|      count: ${concat(vars.count ?? '', 'x')}
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { a: "${vars.a}", b: "${vars.b}", count: "${vars.count}" }
      ),
    ),
  ])
  let out = Array::makei(3, _ => reply(h.send("POST", "/swap")))
  inspect(
    out.join("\n"),
    content=(
      #|200 {"a":"no b","b":"no a","count":"x"}
      #|200 {"a":"no a","b":"no b","count":"xx"}
      #|200 {"a":"no b","b":"no a","count":"xxx"}
    ),
  )
}

///|
test "the values draw from the request's helper generator first, in the order written, and the response draws on from there" {
  let h = harness([
    variables_file(
      (
        #|  - id: stored
        #|    mock: m
        #|    request: { path: /stored }
        #|    variables:
        #|      first: ${fake.uuid()}
        #|      second: ${fake.uuid()}
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: ["${vars.first}", "${vars.second}", "${fake.uuid()}"]
        #|    fault: { seed: 42 }
        #|  - id: drawn
        #|    mock: m
        #|    request: { path: /drawn }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: ["${fake.uuid()}", "${fake.uuid()}", "${fake.uuid()}"]
        #|    fault: { seed: 42 }
      ),
    ),
  ])
  let stored = Array::makei(3, _ => reply(h.send("GET", "/stored")))
  let drawn = Array::makei(3, _ => reply(h.send("GET", "/drawn")))
  inspect(stored == drawn, content="true")
  // The first uuid of seed 42 is the one weighted_test.mbt and
  // template_rules_test.mbt pin; the others, those `/drawn` gives.
  inspect(
    stored[0],
    content=(
      #|200 ["967d85fe-343d-4cc0-9b49-c024af3b3103","a168a304-0584-4bdd-99da-8adbdc970b94","60f50a30-f8ef-47b0-bcd9-40ec46d73ae7"]
    ),
  )
}

///|
test "values that draw helper output leave the response that a seed picks as it is without them" {
  let responses =
    #|    responses:
    #|      - { weight: 1, status: 200 }
    #|      - { weight: 1, status: 201 }
    #|    fault: { seed: 42 }
  let h = harness([
    variables_file(
      (
        $|  - id: writes
        $|    mock: m
        $|    request: { path: /writes }
        $|    variables:
        $|      id: ${fake.uuid()}
        $|      words: ${fake.words(3)}
        $|\{responses}
        $|  - id: plain
        $|    mock: m
        $|    request: { path: /plain }
        $|\{responses}
      ),
    ),
  ])
  let run = (path : String) => {
    Array::makei(8, _ => h.send("GET", path).plan.status.to_string()).join(" ")
  }
  let writes = run("/writes")
  inspect(writes == run("/plain"), content="true")
  // The statuses the pick gives for seed 42, as weighted_test.mbt pins
  // them.
  inspect(writes, content="200 200 201 200 201 201 201 201")
}

///|
/// Stubs of Mock `m` whose second value fails to render without a `name`
/// in the body: `/fail` with a Scenario clause, a delay and two
/// responses, `/reset` with a connection Fault; and `GET /read`, which
/// reads both Variables.
let failing : (String, String) = variables_file(
  (
    #|  - id: fail
    #|    mock: m
    #|    request: { method: POST, path: /fail }
    #|    scenario: { name: flow, moveTo: Failed }
    #|    variables:
    #|      a: written first
    #|      b: { name: "${body.name}" }
    #|    responses:
    #|      - { status: 200 }
    #|      - { status: 201 }
    #|    fault: { delay: { fixed: 250 } }
    #|  - id: reset
    #|    mock: m
    #|    request: { method: POST, path: /reset }
    #|    variables:
    #|      a: written first
    #|      b: ${body.name}
    #|    response: { status: 200 }
    #|    fault: { connection: { kind: reset } }
    #|  - id: read
    #|    mock: m
    #|    request: { method: GET, path: /read }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: { a: "${vars.a ?? 'unset'}", b: "${vars.b ?? 'unset'}" }
  ),
)

///|
test "a value that fails to render writes none of the Stub's Variables, picks no response and gives the template failure, after the Scenario move and with the Stub's delay" {
  let h = harness([failing])
  let failed = h.send("POST", "/fail", body="{}")
  inspect(
    describe(failed),
    content=(
      #|plan:
      #|  status: 500
      #|  header: Content-Type: application/json
      #|  header: Smock-Mock: m; via=default
      #|  body: "{\"error\":\"template failed\",\"stub\":\"fail\",\"at\":\"/variables/b/name\",\"message\":\"body.name is missing\"}"
      #|  delay_ms: 250
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("m")
      #|  via_default: true
      #|  request: POST /fail HTTP/1.1
      #|  body: "{}"
      #|  stub: Some("fail")
      #|  status: Some(500)
      #|  fault: None
      #|  template_error: at /variables/b/name: "body.name is missing"
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
  inspect(
    [
      journaled(failed),
      "scenario: \{@debug.to_string(failed.scenario)}",
      reply(h.send("GET", "/read")),
    ].join("\n"),
    content=(
      #|status 500, responseIndex null, variablesWritten [], templateError /variables/b/name: body.name is missing
      #|scenario: Some({ name: "flow", from: "Started", to: "Failed" })
      #|200 {"a":"unset","b":"unset"}
    ),
  )
  // A connection Fault still replaces the response.
  let reset = h.send("POST", "/reset", body="{}")
  inspect(
    [decision(reset), journaled(reset), reply(h.send("GET", "/read"))].join(
      "\n",
    ),
    content=(
      #|delay 0, Reset
      #|status no status, responseIndex null, variablesWritten [], templateError /variables/b: body.name is missing
      #|200 {"a":"unset","b":"unset"}
    ),
  )
}

///|
test "a delay, a connection Fault or a response that fails to render does not undo the writes" {
  let h = harness([
    variables_file(
      (
        #|  - id: slow
        #|    mock: m
        #|    request: { method: POST, path: /slow }
        #|    variables: { last: slow }
        #|    response: { status: 200 }
        #|    fault: { delay: { fixed: 250 } }
        #|  - id: cut
        #|    mock: m
        #|    request: { method: POST, path: /cut }
        #|    variables: { last: cut }
        #|    response: { status: 200 }
        #|    fault: { connection: { kind: close } }
        #|  - id: render-fails
        #|    mock: m
        #|    request: { method: POST, path: /render-fails }
        #|    variables: { last: render-fails }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { missing: "${body.missing}" }
        #|  - id: read
        #|    mock: m
        #|    request: { method: GET, path: /read }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { last: "${vars.last ?? 'unset'}" }
      ),
    ),
  ])
  let out = []
  for path in ["/slow", "/cut", "/render-fails"] {
    let outcome = h.send("POST", path, body="{}")
    out.push("\{path}: \{decision(outcome)}; \{journaled(outcome)}")
    out.push("  then \{reply(h.send("GET", "/read"))}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|/slow: delay 250; status 200, responseIndex null, variablesWritten [last], templateError none
      #|  then 200 {"last":"slow"}
      #|/cut: delay 0, Close; status no status, responseIndex null, variablesWritten [last], templateError none
      #|  then 200 {"last":"cut"}
      #|/render-fails: delay 0; status 500, responseIndex null, variablesWritten [last], templateError /response/json/missing: body.missing is missing
      #|  then 200 {"last":"render-fails"}
    ),
  )
}

///|
test "each value is bounded as a rendered body is: at most 1 MiB of compact JSON and 10,000 loop iterations" {
  let h = harness([
    variables_file(
      (
        #|  - id: big
        #|    mock: m
        #|    request: { method: POST, path: /big }
        #|    variables:
        #|      big: { $each: "range(1, 1000)", as: i, do: "${bodyText}" }
        #|    response: { status: 200 }
        #|  - id: loops
        #|    mock: m
        #|    request: { method: POST, path: /loops }
        #|    variables:
        #|      many:
        #|        $each: range(1, number(query.n))
        #|        as: i
        #|        do: { $each: "range(1, 1000)", as: j, do: "${j}" }
        #|    response: { status: 200 }
      ),
    ),
  ])
  // A thousand copies of a body of 1,000 bytes fit, of 1,100 do not.
  let out = [
    journaled(h.send("POST", "/big", body="x".repeat(1000))),
    journaled(h.send("POST", "/big", body="x".repeat(1100))),
    // 9 outer iterations and 9,000 inner ones fit; 10 and 10,000 do not.
    journaled(h.send("POST", "/loops?n=9")),
    journaled(h.send("POST", "/loops?n=10")),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|status 200, responseIndex null, variablesWritten [big], templateError none
      #|status 500, responseIndex null, variablesWritten [], templateError /variables/big/do: the rendered value takes more than 1 MiB
      #|status 200, responseIndex null, variablesWritten [many], templateError none
      #|status 500, responseIndex null, variablesWritten [], templateError /variables/many/do/$each: the loops of one value run at most 10000 iterations
    ),
  )
}

///|
test "a value can be any JSON, a template or not; null is stored, and reads take steps into a value in any template" {
  let h = harness([
    variables_file(
      (
        #|  - id: types
        #|    mock: m
        #|    request: { method: POST, path: /types }
        #|    variables:
        #|      string: text
        #|      number: 1.50
        #|      big: 12345678901234567890
        #|      decimal: ${fake.decimal(1, 1, 2)}
        #|      boolean: true
        #|      nothing: null
        #|      object: { a: [1, 2], b: "${body.b}" }
        #|      array: [x, { k: v }]
        #|      escaped: $${not a template}
        #|      body: ${body}
        #|    response: { status: 204 }
        #|  - id: read
        #|    mock: m
        #|    request: { method: GET, path: /read }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json:
        #|        all:
        #|          - ${vars.string}
        #|          - ${vars.number}
        #|          - ${vars.big}
        #|          - ${vars.decimal}
        #|          - ${vars.boolean}
        #|          - ${vars.nothing ?? 'unset'}
        #|          - ${vars.object}
        #|          - ${vars.array}
        #|          - ${vars.escaped}
        #|          - ${vars.body}
        #|        steps: ["${vars.object.a[1]}", "${vars.array[1].k}", "${vars['object'].b}"]
        #|        missing: ["${vars.unset ?? 'unset'}", "${vars.object.c ?? 'no c'}", "${vars.string.x ?? 'no x'}"]
        #|  - id: text
        #|    mock: m
        #|    request: { method: GET, path: /text }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      headers: { X-String: "${vars.string}" }
        #|      body: "${vars.string} ${vars.decimal} ${json(vars.object)}"
      ),
    ),
  ])
  let before = reply(h.send("GET", "/text"))
  let stored = journaled(
    h.send("POST", "/types", body="{\"b\":\"from the body\",\"n\":0.10}"),
  )
  inspect(
    [
      before,
      stored,
      reply(h.send("GET", "/read")),
      response(h.send("GET", "/text")),
    ].join("\n"),
    content=(
      #|500 {"error":"template failed","stub":"text","at":"/response/headers/X-String","message":"vars.string is missing"}
      #|status 204, responseIndex null, variablesWritten [string, number, big, decimal, boolean, nothing, object, array, escaped, body], templateError none
      #|200 {"all":["text",1.5,12345678901234567890,1.00,true,null,{"a":[1,2],"b":"from the body"},["x",{"k":"v"}],"${not a template}",{"b":"from the body","n":0.1}],"steps":[2,"v","from the body"],"missing":["unset","no c","no x"]}
      #|200
      #|X-String: text
      #|Smock-Mock: m; via=default
      #|text 1.00 {"a":[1,2],"b":"from the body"}
    ),
  )
}

///|
test "Variables are kept per Mock: requests without a Session share one space per Mock, apart from every Session's" {
  let stubs = (mock : String) => {
    (
      $|  - id: set-\{mock}
      $|    mock: \{mock}
      $|    request: { method: POST, path: /set }
      $|    variables: { who: "${query.who}" }
      $|    response: { status: 204 }
      $|  - id: get-\{mock}
      $|    mock: \{mock}
      $|    request: { method: GET, path: /get }
      $|    response:
      $|      status: 200
      $|      template: true
      $|      body: "\{mock} ${vars.who ?? 'nobody'}"
    )
  }
  let h = harness([
    (
      "mocks.yaml",
      (
        $|mocks:
        $|  - { name: a, hosts: [a.svc] }
        $|  - { name: b, hosts: [b.svc] }
        $|stubs:
        $|\{stubs("a")}
        $|\{stubs("b")}
      ),
    ),
  ])
  let out = []
  let get = (label : String, host : String, session : String?) => {
    out.push(
      "\{label}: \{reply(h.send("GET", "http://\{host}/get", session?))}",
    )
  }
  ignore(h.send("POST", "http://a.svc/set?who=first"))
  get("a, no Session", "a.svc", None)
  get("a, test-a", "a.svc", Some("test-a"))
  get("b, no Session", "b.svc", None)
  ignore(h.send("POST", "http://a.svc/set?who=second"))
  get("a, another request without a Session", "a.svc", None)
  ignore(h.send("POST", "http://b.svc/set?who=third", session="test-a"))
  get("b, test-a", "b.svc", Some("test-a"))
  get("a, test-a", "a.svc", Some("test-a"))
  get("b, no Session", "b.svc", None)
  inspect(
    out.join("\n"),
    content=(
      #|a, no Session: 200 a first
      #|a, test-a: 200 a nobody
      #|b, no Session: 200 b nobody
      #|a, another request without a Session: 200 a second
      #|b, test-a: 200 b third
      #|a, test-a: 200 a nobody
      #|b, no Session: 200 b nobody
    ),
  )
}

///|
test "with a Variable in another Mock, a response that does not read vars renders as ever, and one that reads them sees its own Mock's" {
  let h = harness([
    (
      "mocks.yaml",
      (
        #|mocks:
        #|  - { name: a, hosts: [a.svc] }
        #|  - { name: b, hosts: [b.svc] }
        #|stubs:
        #|  - id: set
        #|    mock: a
        #|    request: { method: POST, path: /set }
        #|    variables: { who: "${query.who}" }
        #|    response: { status: 204 }
        #|  - id: plain
        #|    mock: b
        #|    request: { method: GET, path: /plain }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      headers: { X-Path: "${path}" }
        #|      body: "${method} $${vars.who}"
        #|  - id: read-a
        #|    mock: a
        #|    request: { method: GET, path: /read }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { who: "${vars.who ?? 'nobody'}" }
        #|  - id: read-b
        #|    mock: b
        #|    request: { method: GET, path: /read }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { who: "${vars.who ?? 'nobody'}" }
      ),
    ),
  ])
  ignore(h.send("POST", "http://a.svc/set?who=ann"))
  inspect(
    [
      response(h.send("GET", "http://b.svc/plain")),
      reply(h.send("GET", "http://a.svc/read")),
      reply(h.send("GET", "http://b.svc/read")),
    ].join("\n"),
    content=(
      #|200
      #|X-Path: /plain
      #|GET ${vars.who}
      #|200 {"who":"ann"}
      #|200 {"who":"nobody"}
    ),
  )
}

///|
test "an Ephemeral Stub takes variables, writes its Session's Variables, and is refused with a value that does not parse or a bad name" {
  let h = harness([failing])
  let out = []
  let added = h.add(
    "m",
    Some("test-a"),
    (
      #|{ "request": { "method": "POST", "path": "/eph" },
      #|  "variables": { "a": "ephemeral ${query.n}", "b": { "n": "${number(query.n)}" } },
      #|  "response": { "status": 201, "template": true, "body": "${vars.a}" } }
    ),
  )
  out.push("added \{added}")
  let outcome = h.send("POST", "/eph?n=7", session="test-a")
  out.push("\{reply(outcome)}; \{journaled(outcome)}")
  out.push("test-a: \{reply(h.send("GET", "/read", session="test-a"))}")
  out.push("no Session: \{reply(h.send("GET", "/read"))}")
  let refused = (stub : String) => {
    try h.add("m", Some("test-a"), stub) catch {
      @engine.AdminError::InvalidStub(problems) =>
        problems.map(problem => problem.to_string()).join("\n")
      error => @debug.to_string(error)
    } noraise {
      id => "added \{id}"
    }
  }
  out.push(
    refused(
      (
        #|{ "request": { "path": "/x" },
        #|  "variables": { "": 1, "a b": 2, "ok": "${nope}" },
        #|  "response": { "status": 200 } }
      ),
    ),
  )
  inspect(
    out.join("\n"),
    content=(
      #|added eph-1
      #|201 ephemeral 7; status 201, responseIndex null, variablesWritten [a, b], templateError none
      #|test-a: 200 {"a":"ephemeral 7","b":{"n":7}}
      #|no Session: 200 {"a":"unset","b":"unset"}
      #|/variables/: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|/variables/a b: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|/variables/ok: template: column 3: unknown name "nope": not a request field, a loop variable or a helper
    ),
  )
}

///|
test "every Journal entry records the names of the Variables written, in the order written, and counts them toward its bytes" {
  let file = variables_file(
    (
      #|  - id: wv
      #|    mock: m
      #|    request: { method: POST, path: /wv }
      #|    variables: { bb: 2, a: 1 }
      #|    response: { status: 200 }
      #|  - id: nv
      #|    mock: m
      #|    request: { method: POST, path: /nv }
      #|    response: { status: 200 }
    ),
  )
  let h = harness([file])
  let out = [
    "/wv: \{journaled(h.send("POST", "/wv"))}",
    "/nv: \{journaled(h.send("POST", "/nv"))}",
    "no Stub: \{journaled(h.send("POST", "/nothing"))}",
  ]
  // The same request line, Stub ID and status: the names bb and a add
  // three code units, six bytes.
  let bytes = (path : String) => {
    let h = harness([file])
    let _ = h.record("POST", path)
    h.stats()
  }
  out.push("/wv: \{bytes("/wv")}")
  out.push("/nv: \{bytes("/nv")}")
  guard ToJson::to_json(h.send("POST", "/wv").journal.unwrap()) is Object(entry) else {
    fail("not an object")
  }
  out.push("as JSON: \{entry.get("variablesWritten").unwrap().stringify()}")
  inspect(
    out.join("\n"),
    content=(
      #|/wv: status 200, responseIndex null, variablesWritten [bb, a], templateError none
      #|/nv: status 200, responseIndex null, variablesWritten [], templateError none
      #|no Stub: status 404, responseIndex null, variablesWritten [], templateError none
      #|/wv: 1 entries, 298 bytes, 0 evicted
      #|/nv: 1 entries, 292 bytes, 0 evicted
      #|as JSON: ["bb","a"]
    ),
  )
}

///|
/// Renders the Stub `id` for the sample request `sample`, given as its
/// JSON, and shows what a rendering says of Variables: the values the Stub
/// would write, the response index, the status, the body and the template
/// error, as one line of JSON.
fn Harness::render_vars(
  self : Harness,
  id : String,
  sample : Json,
  response_index? : Int32,
) -> String raise {
  let rendering = self.engine.render(
    id,
    @engine.SampleRequest::from_json(sample),
    now=self.now,
    response_index?,
    fresh_seed=() => 7,
  )
  guard rendering.to_json()
    is Object(
      {
        "variables": variables,
        "responseIndex": index,
        "response": { "status": status, "body": { "data": body, .. }, .. },
        "templateError": error,
        ..
      }
    ) else {
    fail("not a rendering")
  }
  let shown : Json = {
    "variables": variables,
    "responseIndex": index,
    "status": status,
    "body": body,
    "templateError": error,
  }
  shown.stringify()
}

///|
test "rendering shows the values a Stub would write, rendered against the sample's vars, and the response sees them written over the sample's vars" {
  let h = harness([who_logged_in])
  inspect(
    [
      h.render_vars("login", {
        "method": "POST",
        "path": "/login",
        "body": "{\"user\":\"ann\"}",
        "vars": { "user": "bob" },
      }),
      // Without `vars`, the sample has none.
      h.render_vars("login", {
        "method": "POST",
        "path": "/login",
        "body": "{\"user\":\"ann\"}",
      }),
    ].join("\n"),
    content=(
      #|{"variables":{"user":"ann","previous":"bob"},"responseIndex":null,"status":200,"body":"{\"user\":\"ann\",\"previous\":\"bob\"}","templateError":null}
      #|{"variables":{"user":"ann","previous":null},"responseIndex":null,"status":200,"body":"{\"user\":\"ann\",\"previous\":null}","templateError":null}
    ),
  )
}

///|
test "rendering reads the sample's vars, never the live Variables, and writes none, so a later request sees them as they were" {
  let h = harness([who_logged_in])
  let out = []
  ignore(
    h.send("POST", "/login", body="{\"user\":\"carol\"}", session="test-a"),
  )
  ignore(h.send("POST", "/login", body="{\"user\":\"dave\"}"))
  let samples : Array[Json] = [
    { "method": "POST", "path": "/login", "body": "{\"user\":\"ann\"}" },
    {
      "method": "POST",
      "path": "/login",
      "body": "{\"user\":\"ann\"}",
      "session": "test-a",
    },
    {
      "method": "POST",
      "path": "/login",
      "body": "{\"user\":\"ann\"}",
      "session": "test-a",
      "vars": { "user": "bob" },
    },
    { "path": "/me", "session": "test-a" },
    { "path": "/me", "session": "test-a", "vars": { "user": "bob" } },
  ]
  for sample in samples {
    let id = if sample is { "path": "/me", .. } { "whoami" } else { "login" }
    out.push(h.render_vars(id, sample))
  }
  out.push("test-a GET /me: \{reply(h.send("GET", "/me", session="test-a"))}")
  out.push("no Session GET /me: \{reply(h.send("GET", "/me"))}")
  out.push(
    "test-a logs in as ann: \{reply(h.send("POST", "/login", body="{\"user\":\"ann\"}", session="test-a"))}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|{"variables":{"user":"ann","previous":null},"responseIndex":null,"status":200,"body":"{\"user\":\"ann\",\"previous\":null}","templateError":null}
      #|{"variables":{"user":"ann","previous":null},"responseIndex":null,"status":200,"body":"{\"user\":\"ann\",\"previous\":null}","templateError":null}
      #|{"variables":{"user":"ann","previous":"bob"},"responseIndex":null,"status":200,"body":"{\"user\":\"ann\",\"previous\":\"bob\"}","templateError":null}
      #|{"variables":{},"responseIndex":null,"status":200,"body":"{\"user\":null}","templateError":null}
      #|{"variables":{},"responseIndex":null,"status":200,"body":"{\"user\":\"bob\"}","templateError":null}
      #|test-a GET /me: 200 {"user":"carol"}
      #|no Session GET /me: 200 {"user":"dave"}
      #|test-a logs in as ann: 200 {"user":"ann","previous":"carol"}
    ),
  )
}

///|
test "a value that fails to render shows the 500 a request would get, with no values and no response index, even when a response is asked for" {
  let h = harness([failing])
  let fails : Json = { "method": "POST", "path": "/fail", "body": "{}" }
  let renders : Json = {
    "method": "POST",
    "path": "/fail",
    "body": "{\"name\":\"x\"}",
  }
  inspect(
    [
      h.render_vars("fail", fails),
      h.render_vars("fail", fails, response_index=1),
      h.render_vars("fail", renders),
      h.render_vars("fail", renders, response_index=0),
      // Without a Fault, the template failure is the response as it is.
      h.render_vars("reset", { "method": "POST", "path": "/reset" }),
    ].join("\n"),
    content=(
      #|{"variables":{},"responseIndex":null,"status":500,"body":"{\"error\":\"template failed\",\"stub\":\"fail\",\"at\":\"/variables/b/name\",\"message\":\"body.name is missing\"}","templateError":{"at":"/variables/b/name","message":"body.name is missing"}}
      #|{"variables":{},"responseIndex":null,"status":500,"body":"{\"error\":\"template failed\",\"stub\":\"fail\",\"at\":\"/variables/b/name\",\"message\":\"body.name is missing\"}","templateError":{"at":"/variables/b/name","message":"body.name is missing"}}
      #|{"variables":{"a":"written first","b":{"name":"x"}},"responseIndex":1,"status":201,"body":"","templateError":null}
      #|{"variables":{"a":"written first","b":{"name":"x"}},"responseIndex":0,"status":200,"body":"","templateError":null}
      #|{"variables":{},"responseIndex":null,"status":500,"body":"{\"error\":\"template failed\",\"stub\":\"reset\",\"at\":\"/variables/b\",\"message\":\"body.name is missing\"}","templateError":{"at":"/variables/b","message":"body.name is missing"}}
    ),
  )
}

///|
test "a sample's vars must be an object that maps Variable names to any JSON, or the sample is invalid, with the pointer of the value" {
  let shown = (sample : Json) => {
    try @engine.SampleRequest::from_json(sample) catch {
      @engine.InvalidSample(_) as err => "invalid sample: \{err.message()}"
    } noraise {
      sample => "vars \{Json::object(sample.vars).stringify()}"
    }
  }
  let samples : Array[Json] = [
    { "vars": [] },
    { "vars": "user=bob" },
    { "vars": Json::null() },
    { "vars": { "": 1 } },
    { "vars": { "a b": 1, "ok": 2 } },
    { "vars": { "a/b~c": 1 } },
    { "vars": { "null": Json::null(), "Az09_-": { "a": [1, true, "s"] } } },
  ]
  let out = samples.map(sample => "\{sample.stringify()} -> \{shown(sample)}")
  // Names of 128 characters at most.
  for length in [128, 129] {
    let vars : Map[String, Json] = Map([])
    vars["x".repeat(length)] = Json::number(1)
    let shown = shown({ "vars": Json::object(vars) })
    out.push(
      "a name of \{length} x: \{shown.replace_all(old="x".repeat(length), new="x…")}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"vars":[]} -> invalid sample: /vars: must be an object
      #|{"vars":"user=bob"} -> invalid sample: /vars: must be an object
      #|{"vars":null} -> invalid sample: /vars: must be an object
      #|{"vars":{"":1}} -> invalid sample: /vars/: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|{"vars":{"a b":1,"ok":2}} -> invalid sample: /vars/a b: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|{"vars":{"a/b~c":1}} -> invalid sample: /vars/a~1b~0c: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|{"vars":{"null":null,"Az09_-":{"a":[1,true,"s"]}}} -> vars {"null":null,"Az09_-":{"a":[1,true,"s"]}}
      #|a name of 128 x: vars {"x…":1}
      #|a name of 129 x: invalid sample: /vars/x…: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
    ),
  )
}

///|
test "a rendering with seed S shows the values and the response the first request of a Stub with fault.seed S gets, helper output included" {
  let h = harness([
    variables_file(
      (
        #|  - id: stored
        #|    mock: m
        #|    request: { path: /stored }
        #|    variables:
        #|      first: ${fake.uuid()}
        #|      second: ${fake.uuid()}
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: ["${vars.first}", "${vars.second}", "${fake.uuid()}"]
        #|    fault: { seed: 42 }
      ),
    ),
  ])
  // The rendering uses the Stub's seed, 42. The three uuids are those
  // the first request of seed 42 gets (see above).
  inspect(
    [
      h.render_vars("stored", { "path": "/stored" }),
      reply(h.send("GET", "/stored")),
    ].join("\n"),
    content=(
      #|{"variables":{"first":"967d85fe-343d-4cc0-9b49-c024af3b3103","second":"a168a304-0584-4bdd-99da-8adbdc970b94"},"responseIndex":null,"status":200,"body":"[\"967d85fe-343d-4cc0-9b49-c024af3b3103\",\"a168a304-0584-4bdd-99da-8adbdc970b94\",\"60f50a30-f8ef-47b0-bcd9-40ec46d73ae7\"]","templateError":null}
      #|200 ["967d85fe-343d-4cc0-9b49-c024af3b3103","a168a304-0584-4bdd-99da-8adbdc970b94","60f50a30-f8ef-47b0-bcd9-40ec46d73ae7"]
    ),
  )
}

///|
test "a rendering of a Stub with variables and a body file shows the values and the 206 or the 416 the sample's Range field gets" {
  let h = harness(
    [
      variables_file(
        (
          #|  - id: letters
          #|    mock: m
          #|    request: { path: /letters }
          #|    variables:
          #|      hits: ${add(vars.hits ?? 0, 1)}
          #|    response: { status: 200, bodyFile: letters.txt }
        ),
      ),
    ],
    body_files=[("letters.txt", b"abcdefghijklmnopqrstuvwxyz")],
  )
  inspect(
    [
      h.render_vars("letters", {
        "path": "/letters",
        "headers": { "Range": "bytes=2-4" },
        "vars": { "hits": 1 },
      }),
      h.render_vars("letters", {
        "path": "/letters",
        "headers": { "Range": "bytes=40-" },
      }),
    ].join("\n"),
    content=(
      #|{"variables":{"hits":2},"responseIndex":null,"status":206,"body":"cde","templateError":null}
      #|{"variables":{"hits":1},"responseIndex":null,"status":416,"body":"","templateError":null}
    ),
  )
}
