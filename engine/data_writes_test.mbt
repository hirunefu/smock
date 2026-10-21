// Seam 1 tests of a Stub's `dataWrites`: writes to whole Data buckets,
// applied at the match decision with the Stub's `variables`, all or
// nothing, to the copies of the request's Session.

///|
/// Mock `shop`, with the buckets `buckets` and the Stubs `stubs`, each
/// given as YAML list items.
fn shop_file(buckets : String, stubs : String) -> (String, String) {
  ("shop.yaml", "mocks:\n  - name: shop\ndata:\n\{buckets}\nstubs:\n\{stubs}")
}

///|
test "set makes the bucket its value: three calls in one Session answer 1, 2 and 3, and another Session starts again from 1" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: visits, json: 0 }
      ),
      (
        #|  - id: visit
        #|    mock: shop
        #|    request: { method: GET, path: /visit }
        #|    dataWrites:
        #|      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
        #|    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
      ),
    ),
  ])
  let out = []
  for session in ["test-a", "test-a", "test-a", "test-b"] {
    out.push("\{session}: \{reply(h.send("GET", "/visit", session~))}")
  }
  out.push("no Session: \{reply(h.send("GET", "/visit"))}")
  inspect(
    out.join("\n"),
    content=(
      #|test-a: 200 {"visits":1}
      #|test-a: 200 {"visits":2}
      #|test-a: 200 {"visits":3}
      #|test-b: 200 {"visits":1}
      #|no Session: 200 {"visits":1}
    ),
  )
}

///|
test "merge merges the members of an object into the bucket: each replaces the member of the same name in its place, or is added at the end" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: profile, json: { name: ann, plan: free, tags: [a] } }
      ),
      (
        #|  - id: upgrade
        #|    mock: shop
        #|    request: { method: POST, path: /profile }
        #|    dataWrites:
        #|      - op: merge
        #|        bucket: profile
        #|        value: { plan: "${body.plan}", since: "${body.since}", tags: null }
        #|    response: { status: 200, template: true, json: "${data.profile}" }
        #|  - id: profile
        #|    mock: shop
        #|    request: { method: GET, path: /profile }
        #|    response: { status: 200, template: true, json: "${data.profile}" }
      ),
    ),
  ])
  let out = []
  let upgrade = (session : String, body : String) => {
    out.push(
      "\{session} POST: \{reply(h.send("POST", "/profile", body~, session~))}",
    )
  }
  upgrade("test-a", "{\"plan\":\"pro\",\"since\":2026}")
  upgrade("test-a", "{\"plan\":\"team\",\"since\":2027}")
  out.push("test-b GET: \{reply(h.send("GET", "/profile", session="test-b"))}")
  upgrade("test-b", "{\"plan\":\"pro\",\"since\":1}")
  out.push("test-a GET: \{reply(h.send("GET", "/profile", session="test-a"))}")
  inspect(
    out.join("\n"),
    content=(
      #|test-a POST: 200 {"name":"ann","plan":"pro","tags":null,"since":2026}
      #|test-a POST: 200 {"name":"ann","plan":"team","tags":null,"since":2027}
      #|test-b GET: 200 {"name":"ann","plan":"free","tags":["a"]}
      #|test-b POST: 200 {"name":"ann","plan":"pro","tags":null,"since":1}
      #|test-a GET: 200 {"name":"ann","plan":"team","tags":null,"since":2027}
    ),
  )
}

///|
test "append appends the value to the bucket, which holds an array, and several writes apply in order, to one bucket or several" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: cart, json: [] }
        #|  - { mock: shop, name: log, json: [start] }
      ),
      (
        #|  - id: add
        #|    mock: shop
        #|    request: { method: POST, path: /cart }
        #|    dataWrites:
        #|      - { op: append, bucket: cart, value: "${body}" }
        #|      - { op: append, bucket: log, value: "added ${body.sku}" }
        #|      - { op: append, bucket: log, value: { count: "${len(data.cart)}" } }
        #|    response: { status: 200, template: true, json: { cart: "${data.cart}", log: "${data.log}" } }
        #|  - id: empty
        #|    mock: shop
        #|    request: { method: DELETE, path: /cart }
        #|    dataWrites:
        #|      - { op: set, bucket: cart, value: [] }
        #|      - { op: append, bucket: cart, value: { sku: none } }
        #|      - { op: set, bucket: log, value: [emptied] }
        #|    response: { status: 200, template: true, json: { cart: "${data.cart}", log: "${data.log}" } }
      ),
    ),
  ])
  let out = []
  out.push(reply(h.send("POST", "/cart", body="{\"sku\":\"a1\"}")))
  out.push(reply(h.send("POST", "/cart", body="{\"sku\":\"b2\"}")))
  out.push(reply(h.send("DELETE", "/cart")))
  out.push(reply(h.send("POST", "/cart", body="{\"sku\":\"c3\"}")))
  out.push(reply(h.send("POST", "/cart", body="{\"sku\":\"x\"}", session="s")))
  inspect(
    out.join("\n"),
    content=(
      #|200 {"cart":[{"sku":"a1"}],"log":["start","added a1",{"count":0}]}
      #|200 {"cart":[{"sku":"a1"},{"sku":"b2"}],"log":["start","added a1",{"count":0},"added b2",{"count":1}]}
      #|200 {"cart":[{"sku":"none"}],"log":["emptied"]}
      #|200 {"cart":[{"sku":"none"},{"sku":"c3"}],"log":["emptied","added c3",{"count":1}]}
      #|200 {"cart":[{"sku":"x"}],"log":["start","added x",{"count":0}]}
    ),
  )
}

///|
test "the count follows each write without measuring the copy again: a first write counts the whole copy, then each change what it adds or replaces" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: cart, json: [] }
        #|  - { mock: shop, name: profile, json: { name: ann } }
      ),
      (
        #|  - id: add
        #|    mock: shop
        #|    request: { method: POST, path: /cart }
        #|    dataWrites: [{ op: append, bucket: cart, value: "${body}" }]
        #|    response: { status: 204 }
        #|  - id: empty
        #|    mock: shop
        #|    request: { method: DELETE, path: /cart }
        #|    dataWrites: [{ op: set, bucket: cart, value: [] }]
        #|    response: { status: 204 }
        #|  - id: update
        #|    mock: shop
        #|    request: { method: PATCH, path: /profile }
        #|    dataWrites: [{ op: merge, bucket: profile, value: "${body}" }]
        #|    response: { status: 204 }
      ),
    ),
  ])
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push(
      "\{label}: \{outcome.plan.status}, \{h.engine.state_stats().bytes} bytes",
    )
  }
  // The space of shop and s: 4 + 1 + 64. The copy of cart: 4 + 64, and
  // [{"sku":"a1"}], 14 bytes and three JSON values.
  step(
    "append to the initial []",
    h.send("POST", "/cart", body="{\"sku\":\"a1\"}", session="s"),
  )
  // [{"sku":"a1"},{"sku":"b2"}]: 27 bytes and five JSON values.
  step(
    "append to the copy",
    h.send("POST", "/cart", body="{\"sku\":\"b2\"}", session="s"),
  )
  // The copy of profile: 7 + 64, and {"name":"ann","plan":"pro"}, 27 bytes
  // and three JSON values.
  step(
    "merge into the initial value",
    h.send("PATCH", "/profile", body="{\"plan\":\"pro\"}", session="s"),
  )
  // {"name":"bo","plan":"team"}: 27 bytes, three JSON values.
  step(
    "merge that replaces both members",
    h.send(
      "PATCH",
      "/profile",
      body="{\"plan\":\"team\",\"name\":\"bo\"}",
      session="s",
    ),
  )
  // {"name":"bo","plan":"team","tags":[],"n":null}: 46 bytes, five JSON
  // values.
  step(
    "merge that adds two members",
    h.send("PATCH", "/profile", body="{\"tags\":[],\"n\":null}", session="s"),
  )
  // An empty merge changes nothing.
  step("an empty merge", h.send("PATCH", "/profile", body="{}", session="s"))
  // []: 2 bytes, one JSON value.
  step("set cart to []", h.send("DELETE", "/cart", session="s"))
  // [{"a":1.5}]: 11 bytes, three JSON values: the body's number is written
  // as smock writes numbers.
  step(
    "append to an empty copy",
    h.send("POST", "/cart", body="{\"a\":1.50}", session="s"),
  )
  // {"é\n":"x"}: the name takes 6 bytes as a JSON string (é is 2, \n is
  // written as 2), then the colon, "x" (3 bytes and one JSON value) and
  // the comma before it.
  step(
    "merge a name that is escaped",
    h.send("PATCH", "/profile", body="{\"é\\n\":\"x\"}", session="s"),
  )
  // Without a Session: the space is 4 + 64.
  step(
    "append without a Session",
    h.send("POST", "/cart", body="{\"sku\":\"a1\"}"),
  )
  // The Admin API measures a value whole when it sets it: the same values
  // in the Session t count what s counts, 420 bytes.
  for bucket in ["cart", "profile"] {
    let value = h.engine.read_data(mock="shop", session=Some("s"), bucket~).value
    h.engine.set_data(mock="shop", session=Some("t"), bucket~, value) |> ignore
  }
  out.push("the same values set in t: \{h.engine.state_stats().bytes} bytes")
  inspect(
    out.join("\n"),
    content=(
      #|append to the initial []: 204, 199 bytes
      #|append to the copy: 204, 244 bytes
      #|merge into the initial value: 204, 390 bytes
      #|merge that replaces both members: 204, 390 bytes
      #|merge that adds two members: 204, 441 bytes
      #|an empty merge: 204, 441 bytes
      #|set cart to []: 204, 352 bytes
      #|append to an empty copy: 204, 393 bytes
      #|merge a name that is escaped: 204, 420 bytes
      #|append without a Session: 204, 618 bytes
      #|the same values set in t: 1038 bytes
    ),
  )
}

///|
/// The Journal entry of `outcome`, in short: the status, the index of the
/// response, the Variables and the Data buckets written, and the data and
/// template errors.
fn data_journaled(outcome : @engine.Outcome) -> String {
  guard outcome.journal is Some(entry) else { return "no entry" }
  let status = entry.status.map_or("no status", status => status.to_string())
  let index = entry.response_index.map_or("null", index => index.to_string())
  let variables = entry.variables_written.iter().collect().join(", ")
  let data = entry.data_written.iter().collect().join(", ")
  let data_error = match entry.data_error {
    Some(error) => "\{error.at}: \{error.message}"
    None => "none"
  }
  let template_error = match entry.template_error {
    Some(error) => "\{error.at}: \{error.message}"
    None => "none"
  }
  "status \{status}, responseIndex \{index}, variablesWritten [\{variables}], dataWritten [\{data}], dataError \{data_error}, templateError \{template_error}"
}

///|
/// The Mock `shop` with the buckets `log`, `profile` and `visits`, Stubs
/// whose writes fail to apply on some requests, and `GET /state`, which
/// shows the Variable `last` and every bucket.
let failing_writes : (String, String) = shop_file(
  (
    #|  - { mock: shop, name: log, json: [] }
    #|  - { mock: shop, name: profile, json: { name: ann } }
    #|  - { mock: shop, name: visits, json: 0 }
  ),
  (
    #|  - id: log
    #|    mock: shop
    #|    request: { method: POST, path: /log }
    #|    variables: { last: "${body}" }
    #|    dataWrites: [{ op: append, bucket: log, value: "${body}" }]
    #|    response: { status: 204 }
    #|  - id: merge-body
    #|    mock: shop
    #|    request: { method: POST, path: /merge }
    #|    scenario: { name: flow, moveTo: Merged }
    #|    variables: { last: "${body}" }
    #|    dataWrites:
    #|      - { op: append, bucket: log, value: merge }
    #|      - { op: merge, bucket: profile, value: "${body}" }
    #|    response: { status: 200 }
    #|    fault: { delay: { fixed: 250 } }
    #|  - id: merge-number
    #|    mock: shop
    #|    request: { method: POST, path: /visits }
    #|    dataWrites:
    #|      - { op: merge, bucket: profile, value: { seen: true } }
    #|      - { op: merge, bucket: visits, value: { count: 1 } }
    #|    responses: [{ status: 200 }, { status: 201 }]
    #|  - id: append-object
    #|    mock: shop
    #|    request: { method: POST, path: /profile }
    #|    dataWrites: [{ op: append, bucket: profile, value: 1 }]
    #|    response: { status: 200 }
    #|    fault: { connection: { kind: reset } }
    #|  - id: state
    #|    mock: shop
    #|    request: { method: GET, path: /state }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: { last: "${vars.last ?? null}", log: "${data.log}", profile: "${data.profile}", visits: "${data.visits}" }
    #|  - id: flow
    #|    mock: shop
    #|    request: { method: GET, path: /flow }
    #|    scenario: { name: flow, requires: Merged }
    #|    response: { status: 200, body: Merged }
  ),
)

///|
test "a write that cannot be applied writes nothing, Variables included, picks no response and answers 500, after the Scenario move and with the Stub's delay" {
  let h = harness([failing_writes])
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push(
      "\{label}: \{data_journaled(outcome)}; \{h.engine.state_stats().bytes} bytes",
    )
  }
  step("log 1", h.send("POST", "/log", body="1", session="s"))
  // The append to log is applied to the copy, then undone when the merge
  // fails.
  let failed = h.send("POST", "/merge", body="[1]", session="s")
  inspect(
    describe(failed),
    content=(
      #|plan:
      #|  status: 500
      #|  header: Content-Type: application/json
      #|  header: Smock-Mock: shop; via=default
      #|  body: "{\"error\":\"data write failed\",\"stub\":\"merge-body\",\"at\":\"/dataWrites/1\",\"message\":\"the value of \\\"merge\\\" must be an object, and it is an array\"}"
      #|  delay_ms: 250
      #|  fault: None
      #|journal:
      #|  session: Some("s")
      #|  host: None
      #|  mock: Some("shop")
      #|  via_default: true
      #|  request: POST /merge HTTP/1.1
      #|  body: "[1]"
      #|  stub: Some("merge-body")
      #|  status: Some(500)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
  step("merge [1]", failed)
  out.push(
    "the Scenario move stands: \{reply(h.send("GET", "/flow", session="s"))}",
  )
  out.push("nothing written: \{reply(h.send("GET", "/state", session="s"))}")
  step(
    "merge an object",
    h.send("POST", "/merge", body="{\"plan\":\"pro\"}", session="s"),
  )
  // The merge into profile is applied to the copy, then undone.
  step("merge into a number", h.send("POST", "/visits", body="{}", session="s"))
  let cut = h.send("POST", "/profile", session="s")
  step("append to an object, with a connection Fault: \{decision(cut)}", cut)
  out.push(
    "nothing more written: \{reply(h.send("GET", "/state", session="s"))}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|log 1: status 204, responseIndex null, variablesWritten [last], dataWritten [log], dataError none, templateError none; 256 bytes
      #|merge [1]: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/1: the value of "merge" must be an object, and it is an array, templateError none; 256 bytes
      #|the Scenario move stands: 200 Merged
      #|nothing written: 200 {"last":1,"log":[1],"profile":{"name":"ann"},"visits":0}
      #|merge an object: status 200, responseIndex null, variablesWritten [last], dataWritten [log, profile], dataError none, templateError none; 455 bytes
      #|merge into a number: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/1: the Data bucket "visits" holds a number, and "merge" needs an object, templateError none; 455 bytes
      #|append to an object, with a connection Fault: delay 0, Reset: status no status, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/0: the Data bucket "profile" holds an object, and "append" needs an array, templateError none; 455 bytes
      #|nothing more written: 200 {"last":{"plan":"pro"},"log":[1,"merge"],"profile":{"name":"ann","plan":"pro"},"visits":0}
    ),
  )
}

///|
test "a value that fails to render writes nothing, Variables included, and gives the template failure at the write's value" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: log, json: [] }
      ),
      (
        #|  - id: log
        #|    mock: shop
        #|    request: { method: POST, path: /log }
        #|    variables: { last: "${body}" }
        #|    dataWrites:
        #|      - { op: append, bucket: log, value: first }
        #|      - { op: append, bucket: log, value: { user: "${body.user}" } }
        #|    responses: [{ status: 200 }, { status: 201 }]
        #|  - id: state
        #|    mock: shop
        #|    request: { method: GET, path: /state }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { last: "${vars.last ?? null}", log: "${data.log}" }
      ),
    ),
  ])
  let out = []
  let ok = h.send("POST", "/log", body="{\"user\":\"ann\"}", session="s")
  out.push("ann: \{data_journaled(ok)}")
  let failed = h.send("POST", "/log", body="{}", session="s")
  out.push("no user: \{reply(failed)}")
  out.push("no user: \{data_journaled(failed)}")
  out.push("nothing written: \{reply(h.send("GET", "/state", session="s"))}")
  inspect(
    out.join("\n"),
    content=(
      #|ann: status 201, responseIndex 1, variablesWritten [last], dataWritten [log], dataError none, templateError none
      #|no user: 500 {"error":"template failed","stub":"log","at":"/dataWrites/1/value/user","message":"body.user is missing"}
      #|no user: status 500, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError /dataWrites/1/value/user: body.user is missing
      #|nothing written: 200 {"last":{"user":"ann"},"log":["first",{"user":"ann"}]}
    ),
  )
}

///|
test "each value is bounded as a rendered body is: at most 1 MiB of compact JSON and 10,000 loop iterations" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: log, json: [] }
      ),
      (
        #|  - id: big
        #|    mock: shop
        #|    request: { method: POST, path: /big }
        #|    dataWrites:
        #|      - { op: set, bucket: log, value: "${body}" }
        #|    response: { status: 204 }
        #|  - id: loops
        #|    mock: shop
        #|    request: { method: POST, path: /loops }
        #|    dataWrites:
        #|      - { op: set, bucket: log, value: [] }
        #|      - op: append
        #|        bucket: log
        #|        value:
        #|          $each: range(1, number(query.n))
        #|          as: i
        #|          do: { $each: "range(1, 1000)", as: j, do: 0 }
        #|    response: { status: 204 }
      ),
    ),
  ])
  let mib = 1024 * 1024
  let out = []
  out.push(
    "1 MiB: \{reply(h.send("POST", "/big", body="\"\{"a".repeat(mib - 2)}\""))}",
  )
  out.push(
    "past 1 MiB: \{reply(h.send("POST", "/big", body="\"\{"a".repeat(mib - 1)}\""))}",
  )
  // 9 outer iterations and 9,000 inner ones fit; 10 and 10,000 do not.
  out.push("9,009 iterations: \{reply(h.send("POST", "/loops?n=9"))}")
  out.push("10,010 iterations: \{reply(h.send("POST", "/loops?n=10"))}")
  inspect(
    out.join("\n"),
    content=(
      #|1 MiB: 204 
      #|past 1 MiB: 500 {"error":"template failed","stub":"big","at":"/dataWrites/0/value","message":"the rendered value takes more than 1 MiB"}
      #|9,009 iterations: 204 
      #|10,010 iterations: 500 {"error":"template failed","stub":"loops","at":"/dataWrites/1/value/do/$each","message":"the loops of one value run at most 10000 iterations"}
    ),
  )
}

///|
test "at the bound: writes that would take the count above it write nothing, Variables included, and answer 507, after the Scenario move and with the Stub's delay" {
  let h = harness(
    [
      shop_file(
        (
          #|  - { mock: shop, name: log, json: [] }
          #|  - { mock: shop, name: profile, json: {} }
        ),
        (
          #|  - id: add
          #|    mock: shop
          #|    request: { method: POST, path: /add }
          #|    scenario: { name: flow, moveTo: Added }
          #|    variables: { last: "${body}" }
          #|    dataWrites:
          #|      - { op: append, bucket: log, value: x }
          #|      - { op: merge, bucket: profile, value: { big: "${body}" } }
          #|    responses: [{ status: 200 }, { status: 201 }]
          #|    fault: { delay: { fixed: 250 } }
          #|  - id: state
          #|    mock: shop
          #|    request: { method: GET, path: /state }
          #|    response:
          #|      status: 200
          #|      template: true
          #|      json: { last: "${vars.last ?? null}", log: "${data.log}", profile: "${data.profile}" }
          #|  - id: flow
          #|    mock: shop
          #|    request: { method: GET, path: /flow }
          #|    scenario: { name: flow, requires: Added }
          #|    response: { status: 200, body: Added }
        ),
      ),
    ],
    state_max_bytes=400,
  )
  let out = []
  let step = (label : String, outcome : @engine.Outcome) => {
    out.push(
      "\{label}: \{data_journaled(outcome)}; \{h.engine.state_stats().bytes} bytes",
    )
  }
  // What the Stub writes for the body "a", set through the Admin API, so
  // that the Scenario has not moved. The space: 4 + 64. last: 4 + 64 + 3 +
  // 16. The copy of log, ["x"]: 3 + 64 + 5 + 32. The copy of profile,
  // {"big":"a"}: 7 + 64 + 11 + 32.
  h.engine.set_variable(mock="shop", session=None, name="last", "a")
  h.engine.set_data(mock="shop", session=None, bucket="log", ["x"]) |> ignore
  h.engine.set_data(mock="shop", session=None, bucket="profile", { "big": "a" })
  |> ignore
  out.push("as if a was sent: \{h.engine.state_stats().bytes} bytes")
  // Ten characters add 9 to last and 9 to profile, and log's second "x"
  // adds 20: 411 in all. The append to the copy of log and the merge into
  // the copy of profile are undone.
  let refused = h.send("POST", "/add", body="\"aaaaaaaaaa\"")
  out.push("ten characters: \{reply(refused)}, delay \{refused.plan.delay_ms}")
  step("ten characters", refused)
  out.push("the Scenario move stands: \{reply(h.send("GET", "/flow"))}")
  out.push("nothing written: \{reply(h.send("GET", "/state"))}")
  step("two characters", h.send("POST", "/add", body="\"aa\""))
  out.push("refused requests: \{h.engine.state_stats().writes_refused}")
  inspect(
    out.join("\n"),
    content=(
      #|as if a was sent: 373 bytes
      #|ten characters: 507 {"error":"state limit reached","stub":"add","message":"the writes would take per-Session state from 373 to 411 bytes, above its bound of 400 (--state-max-bytes)"}, delay 250
      #|ten characters: status 507, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none; 373 bytes
      #|the Scenario move stands: 200 Added
      #|nothing written: 200 {"last":"a","log":["x"],"profile":{"big":"a"}}
      #|two characters: status 200, responseIndex 0, variablesWritten [last], dataWritten [log, profile], dataError none, templateError none; 395 bytes
      #|refused requests: 1
    ),
  )
}

///|
test "the values of variables and of each write read the state from before the request, Variables included; the response reads it after the writes" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: counter, json: 0 }
        #|  - { mock: shop, name: seen, json: [] }
      ),
      (
        #|  - id: count
        #|    mock: shop
        #|    request: { method: POST, path: /count }
        #|    variables:
        #|      before: ${data.counter}
        #|      count: ${add(vars.count ?? 0, 1)}
        #|    dataWrites:
        #|      - { op: set, bucket: counter, value: "${add(data.counter, 1)}" }
        #|      - op: append
        #|        bucket: seen
        #|        value: { counter: "${data.counter}", count: "${vars.count ?? null}", before: "${vars.before ?? null}" }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { counter: "${data.counter}", count: "${vars.count}", before: "${vars.before}", seen: "${data.seen}" }
      ),
    ),
  ])
  let out = Array::makei(2, _ => reply(h.send("POST", "/count")))
  inspect(
    out.join("\n"),
    content=(
      #|200 {"counter":1,"count":1,"before":0,"seen":[{"counter":0,"count":null,"before":null}]}
      #|200 {"counter":2,"count":2,"before":1,"seen":[{"counter":0,"count":null,"before":null},{"counter":1,"count":1,"before":0}]}
    ),
  )
}

///|
test "the helpers draw for the values of variables first, then for each write's value in order, then for the response" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: ids, json: [] }
      ),
      (
        #|  - id: stored
        #|    mock: shop
        #|    request: { path: /stored }
        #|    variables: { first: "${fake.uuid()}" }
        #|    dataWrites:
        #|      - { op: set, bucket: ids, value: ["${vars.first ?? 'none'}", "${fake.uuid()}"] }
        #|      - { op: append, bucket: ids, value: "${fake.uuid()}" }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: ["${vars.first}", "${data.ids[1]}", "${data.ids[2]}", "${fake.uuid()}"]
        #|    fault: { seed: 42 }
        #|  - id: drawn
        #|    mock: shop
        #|    request: { path: /drawn }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: ["${fake.uuid()}", "${fake.uuid()}", "${fake.uuid()}", "${fake.uuid()}"]
        #|    fault: { seed: 42 }
      ),
    ),
  ])
  let stored = Array::makei(3, _ => reply(h.send("GET", "/stored")))
  let drawn = Array::makei(3, _ => reply(h.send("GET", "/drawn")))
  inspect(stored == drawn, content="true")
  // The first three uuids of seed 42 are those variables_test.mbt pins;
  // the fourth, the one `/drawn` gives.
  inspect(
    stored[0],
    content=(
      #|200 ["967d85fe-343d-4cc0-9b49-c024af3b3103","a168a304-0584-4bdd-99da-8adbdc970b94","60f50a30-f8ef-47b0-bcd9-40ec46d73ae7","9231bb03-bc55-41d4-b750-600b462a00f2"]
    ),
  )
}

///|
test "writes stand whatever follows: a delay, a connection Fault, a response that fails to render, or a Journal that is off; and the next request sees them while the delay runs" {
  let h = harness([
    (
      "shop.yaml",
      (
        #|mocks:
        #|  - { name: shop, hosts: [shop.test] }
        #|  - { name: quiet, hosts: [quiet.test], journal: false }
        #|data:
        #|  - { mock: shop, name: log, json: [] }
        #|  - { mock: quiet, name: log, json: [] }
        #|stubs:
        #|  - id: slow
        #|    mock: shop
        #|    request: { path: /slow }
        #|    dataWrites: [{ op: append, bucket: log, value: slow }]
        #|    response: { status: 200 }
        #|    fault: { delay: { fixed: 1000 } }
        #|  - id: cut
        #|    mock: shop
        #|    request: { path: /cut }
        #|    dataWrites: [{ op: append, bucket: log, value: cut }]
        #|    response: { status: 200 }
        #|    fault: { connection: { kind: reset } }
        #|  - id: broken
        #|    mock: shop
        #|    request: { path: /broken }
        #|    dataWrites: [{ op: append, bucket: log, value: broken }]
        #|    response: { status: 200, template: true, json: "${body.missing}" }
        #|  - id: log
        #|    mock: shop
        #|    request: { path: /log }
        #|    response: { status: 200, template: true, json: "${data.log}" }
        #|  - id: quiet
        #|    mock: quiet
        #|    request: { path: /quiet }
        #|    dataWrites: [{ op: append, bucket: log, value: quiet }]
        #|    response: { status: 200, template: true, json: "${data.log}" }
      ),
    ),
  ])
  let shop = [("Host", "shop.test")]
  let out = []
  let slow = h.send("GET", "/slow", headers=shop)
  out.push("slow: \{decision(slow)}; \{data_journaled(slow)}")
  out.push(
    "read while slow's delay runs: \{reply(h.send("GET", "/log", headers=shop))}",
  )
  let cut = h.send("GET", "/cut", headers=shop)
  out.push("cut: \{decision(cut)}; \{data_journaled(cut)}")
  let broken = h.send("GET", "/broken", headers=shop)
  out.push("broken: \{data_journaled(broken)}")
  let quiet = h.send("GET", "/quiet", headers=[("Host", "quiet.test")])
  out.push("quiet: \{reply(quiet)}; \{data_journaled(quiet)}")
  out.push("shop's log: \{reply(h.send("GET", "/log", headers=shop))}")
  out.push(
    "quiet's log: \{reply(h.send("GET", "/quiet", headers=[("Host", "quiet.test")]))}",
  )
  inspect(
    out.join("\n"),
    content=(
      #|slow: delay 1000; status 200, responseIndex null, variablesWritten [], dataWritten [log], dataError none, templateError none
      #|read while slow's delay runs: 200 ["slow"]
      #|cut: delay 0, Reset; status no status, responseIndex null, variablesWritten [], dataWritten [log], dataError none, templateError none
      #|broken: status 500, responseIndex null, variablesWritten [], dataWritten [log], dataError none, templateError /response/json: body.missing is missing
      #|quiet: 200 ["quiet"]; no entry
      #|shop's log: 200 ["slow","cut","broken"]
      #|quiet's log: 200 ["quiet","quiet"]
    ),
  )
}

///|
test "a Stub with responses writes once, whichever response is picked" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: visits, json: 0 }
      ),
      (
        #|  - id: visit
        #|    mock: shop
        #|    request: { path: /visit }
        #|    dataWrites:
        #|      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
        #|    responses:
        #|      - { status: 200, template: true, body: "a ${data.visits}" }
        #|      - { status: 201, template: true, body: "b ${data.visits}" }
        #|      - { status: 202, body: c }
        #|    fault: { seed: 42 }
      ),
    ),
  ])
  let out = Array::makei(6, _ => reply(h.send("GET", "/visit")))
  inspect(
    out.join("\n"),
    content=(
      #|200 a 1
      #|201 b 2
      #|201 b 3
      #|202 c
      #|200 a 5
      #|200 a 6
    ),
  )
}

///|
test "an Ephemeral Stub writes its Session's copies; after a reload removes its bucket, or gives it a key, the write fails to apply and nothing is written" {
  let files = (data : String) => {
    [
      shop_file(
        data,
        (
          #|  - id: other
          #|    mock: shop
          #|    request: { path: /other }
          #|    response: { status: 200 }
        ),
      ),
    ]
  }
  let h = harness(
    files(
      (
        #|  - { mock: shop, name: visits, json: 0 }
        #|  - { mock: shop, name: log, json: [] }
      ),
    ),
  )
  let out = []
  out.push(
    h.add_to_shop(
      (
        #|{ "request": { "path": "/visit" },
        #|  "variables": { "calls": "${add(vars.calls ?? 0, 1)}" },
        #|  "dataWrites": [
        #|    { "op": "set", "bucket": "visits", "value": "${add(data.visits ?? 0, 1)}" },
        #|    { "op": "append", "bucket": "log", "value": "visit" } ],
        #|  "response": { "status": 200, "template": true, "body": "${data.visits ?? 'none'}" } }
      ),
    ),
  )
  let visit = () => {
    let outcome = h.send("GET", "/visit", session="test-a")
    "\{reply(outcome)}; \{data_journaled(outcome)}"
  }
  let state = () => {
    let calls = h.engine.list_variables(mock="shop", session=Some("test-a"))
    let visits = try
      h.engine.read_data(mock="shop", session=Some("test-a"), bucket="visits")
    catch {
      UnknownBucket(..) => "gone"
      err => @debug.to_string(err)
    } noraise {
      bucket => bucket.value.stringify()
    }
    "calls \{Json::object(calls).stringify()}, visits \{visits}"
  }
  out.push("visit: \{visit()}")
  out.push("visit: \{visit()}")
  let other = h.engine.read_data(
    mock="shop",
    session=Some("test-b"),
    bucket="visits",
  )
  out.push(
    "another Session reads the initial value: \{other.value.stringify()}",
  )
  out.push("state: \{state()}")
  let reload = (data : String) => {
    let result = h.engine.reload(
      { files: files(data).map(f => (f.0, @utf8.encode(f.1))), body_files: [], },
      at=fixed_now,
    )
    @debug.to_string(result.result)
  }
  let log_keyed = reload(
    (
      #|  - { mock: shop, name: visits, json: 0 }
      #|  - { mock: shop, name: log, key: id, json: [] }
    ),
  )
  out.push("log keyed: \{log_keyed}")
  out.push("visit: \{visit()}")
  out.push("state: \{state()}")
  let visits_removed = reload(
    (
      #|  - { mock: shop, name: log, json: [] }
    ),
  )
  out.push("visits removed: \{visits_removed}")
  out.push("visit: \{visit()}")
  out.push("state: \{state()}")
  inspect(
    out.join("\n"),
    content=(
      #|eph-1
      #|visit: 200 1; status 200, responseIndex null, variablesWritten [calls], dataWritten [visits, log], dataError none, templateError none
      #|visit: 200 2; status 200, responseIndex null, variablesWritten [calls], dataWritten [visits, log], dataError none, templateError none
      #|another Session reads the initial value: 0
      #|state: calls {"calls":2}, visits 2
      #|log keyed: Swapped
      #|visit: 500 {"error":"data write failed","stub":"eph-1","at":"/dataWrites/1","message":"the Data bucket \"log\" has \"key\" since a reload, and dataWrites cannot write to a keyed bucket yet"}; status 500, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/1: the Data bucket "log" has "key" since a reload, and dataWrites cannot write to a keyed bucket yet, templateError none
      #|state: calls {"calls":2}, visits 2
      #|visits removed: Swapped
      #|visit: 500 {"error":"data write failed","stub":"eph-1","at":"/dataWrites/0","message":"the Mock has no Data bucket \"visits\" since a reload"}; status 500, responseIndex null, variablesWritten [], dataWritten [], dataError /dataWrites/0: the Mock has no Data bucket "visits" since a reload, templateError none
      #|state: calls {"calls":2}, visits gone
    ),
  )
}

///|
test "every Journal entry records the Data buckets written, in the order first written, each once, and why a write failed, and counts them toward its bytes" {
  let file = shop_file(
    (
      #|  - { mock: shop, name: a, json: [] }
      #|  - { mock: shop, name: bb, json: 0 }
    ),
    (
      #|  - id: wd
      #|    mock: shop
      #|    request: { method: POST, path: /wd }
      #|    dataWrites:
      #|      - { op: set, bucket: bb, value: 1 }
      #|      - { op: append, bucket: a, value: 1 }
      #|      - { op: set, bucket: bb, value: 2 }
      #|    response: { status: 200 }
      #|  - id: nd
      #|    mock: shop
      #|    request: { method: POST, path: /nd }
      #|    response: { status: 200 }
      #|  - id: fd
      #|    mock: shop
      #|    request: { method: POST, path: /fd }
      #|    dataWrites: [{ op: append, bucket: bb, value: 1 }]
      #|    response: { status: 200 }
    ),
  )
  let h = harness([file])
  let out = [
    "/wd: \{data_journaled(h.send("POST", "/wd"))}",
    "/nd: \{data_journaled(h.send("POST", "/nd"))}",
    "no Stub: \{data_journaled(h.send("POST", "/nothing"))}",
  ]
  // The same request line, Stub ID and status: the names bb and a add
  // three code units, six bytes; the failure's at and message 13 and 64,
  // 154 bytes.
  let bytes = (path : String) => {
    let h = harness([file])
    let _ = h.record("POST", path)
    h.stats()
  }
  out.push("/wd: \{bytes("/wd")}")
  out.push("/nd: \{bytes("/nd")}")
  out.push("/fd: \{bytes("/fd")}")
  let json = (path : String) => {
    guard ToJson::to_json(h.send("POST", path).journal.unwrap())
      is Object(entry) else {
      fail("not an object")
    }
    "dataWritten \{entry["dataWritten"].stringify()}, dataError \{entry["dataError"].stringify()}"
  }
  out.push("/wd as JSON: \{json("/wd")}")
  out.push("/fd as JSON: \{json("/fd")}")
  inspect(
    out.join("\n"),
    content=(
      #|/wd: status 200, responseIndex null, variablesWritten [], dataWritten [bb, a], dataError none, templateError none
      #|/nd: status 200, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|no Stub: status 404, responseIndex null, variablesWritten [], dataWritten [], dataError none, templateError none
      #|/wd: 1 entries, 304 bytes, 0 evicted
      #|/nd: 1 entries, 298 bytes, 0 evicted
      #|/fd: 1 entries, 452 bytes, 0 evicted
      #|/wd as JSON: dataWritten ["bb","a"], dataError null
      #|/fd as JSON: dataWritten [], dataError {"at":"/dataWrites/0","message":"the Data bucket \"bb\" holds a number, and \"append\" needs an array"}
    ),
  )
}

///|
test "rendering a Stub with dataWrites writes nothing, and renders the response against the data as it is" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: visits, json: 0 }
      ),
      (
        #|  - id: visit
        #|    mock: shop
        #|    request: { method: GET, path: /visit }
        #|    dataWrites:
        #|      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
        #|    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
      ),
    ),
  ])
  let render = () => {
    let rendering = h.engine.render(
      "visit",
      @engine.SampleRequest::from_json({ "path": "/visit" }),
      now=h.now,
      fresh_seed=() => 7,
    )
    match rendering.body {
      Bytes(body) => "\{rendering.status} \{@utf8.decode_lossy(body)}"
      Events(_) => "events"
    }
  }
  let out = [render(), render()]
  out.push(reply(h.send("GET", "/visit")))
  out.push(render())
  inspect(
    out.join("\n"),
    content=(
      #|200 {"visits":0}
      #|200 {"visits":0}
      #|200 {"visits":1}
      #|200 {"visits":0}
    ),
  )
}

///|
test "an Ephemeral Stub whose writes would not load is refused, with the problems a file Stub's get" {
  let h = harness([
    shop_file(
      (
        #|  - { mock: shop, name: visits, json: 0 }
        #|  - { mock: shop, name: orders, key: id, json: [] }
      ),
      (
        #|  - id: other
        #|    mock: shop
        #|    request: { path: /other }
        #|    response: { status: 200 }
      ),
    ),
  ])
  inspect(
    h.add_to_shop(
      (
        #|{ "request": { "path": "/visit" },
        #|  "dataWrites": [
        #|    { "op": "set", "bucket": "visit", "value": 1 },
        #|    { "op": "set", "bucket": "visits", "key": "1", "value": 1 },
        #|    { "op": "merge", "bucket": "visits", "value": [] },
        #|    { "op": "append", "bucket": "orders", "value": { "id": 1 } },
        #|    { "op": "remove", "bucket": "visits" } ],
        #|  "response": { "status": 200 } }
      ),
    ),
    content=(
      #|/dataWrites/0/bucket: the Mock has no Data bucket "visit"
      #|/dataWrites/1/key: is allowed only on a keyed bucket, and the Data bucket "visits" has no "key"
      #|/dataWrites/2/value: must be an object: "merge" merges the members of an object into the bucket
      #|/dataWrites/3/bucket: the Data bucket "orders" is keyed, and dataWrites cannot write to a keyed bucket yet
      #|/dataWrites/4: needs "key"
    ),
  )
}
