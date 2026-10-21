// Seam 1 tests of `responses`: the pick among a Stub's weighted responses,
// what it draws, and where its index shows.

///|
/// The status of the response each of `n` requests for `GET path` gets, in
/// order.
fn statuses(h : Harness, path : String, n : Int) -> Array[Int] {
  Array::makei(n, _ => h.send("GET", path).plan.status)
}

///|
/// The Stub of the example: `GET /prices` answers 200 nine times in ten,
/// and 503 with Retry-After once in ten, with its own generator.
let prices : (String, String) = (
  "m.json",
  (
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "get-prices", "mock": "m",
    #|      "request": { "method": "GET", "path": "/prices" },
    #|      "responses": [
    #|        { "weight": 9, "status": 200, "json": { "price": 101 } },
    #|        { "weight": 1, "status": 503, "headers": { "Retry-After": "5" },
    #|          "json": { "error": "unavailable" } } ],
    #|      "fault": { "seed": 7 } } ] }
  ),
)

///|
test "a Stub with responses answers each request with one of them, each with its own status, headers and body" {
  let h = harness([prices])
  let seen = Map([])
  for _ in 0..<200 {
    let outcome = h.send("GET", "/prices")
    seen[outcome.plan.status] = response(outcome)
  }
  inspect(
    seen.get(200).unwrap_or("none") + "---\n" + seen.get(503).unwrap_or("none"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"price":101}---
      #|503
      #|Retry-After: 5
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"unavailable"}
    ),
  )
}

///|
test "with fault.seed, a Stub's picks are pinned and the same on every run, whatever other requests draw" {
  // Each harness is a run, with a process generator seeded differently.
  let alone = statuses(harness([prices], process_seed=1), "/prices", 30)
  let mixed = harness([prices], process_seed=2)
  let interleaved = []
  for _ in 0..<30 {
    ignore(mixed.send("GET", "/nothing"))
    interleaved.push(mixed.send("GET", "/prices").plan.status)
  }
  inspect(alone == interleaved, content="true")
  // The picks of seed 7, as a separate model of the generator and the
  // pick computes them: the 503 at the first, third and fifteenth request.
  inspect(
    alone.map(status => status.to_string()).join(" "),
    content="503 200 503 200 200 200 200 200 200 200 200 200 200 200 503 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200",
  )
}

///|
/// A Definition file with Mock `m` and the Stub `GET /pick`, whose
/// `responses` have `weights`; response `i` answers 200 with the body `i`.
fn weighted_file(weights : Array[Int]) -> (String, String) {
  let responses = weights.mapi((i, weight) => {
    "{ \"weight\": \{weight}, \"status\": 200, \"body\": \"\{i}\" }"
  })
  (
    "m.json",
    "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [{ \"id\": \"pick\", \"mock\": \"m\", \"request\": { \"path\": \"/pick\" }, \"responses\": [\{responses.join(", ")}] }] }",
  )
}

///|
/// The index of the response a request for `GET /pick` gets.
fn picked(h : Harness) -> Int {
  guard h.send("GET", "/pick").plan.body is Bytes(body) else {
    abort("not a body")
  }
  let text = @utf8.decode_lossy(body)
  let json = @json.parse(text) catch { _ => abort("not JSON: \{text}") }
  guard json is Number(i, ..) else { abort("not an index: \{text}") }
  i.to_int()
}

///|
/// How many of `n` requests for `GET /pick` got each of `count` responses,
/// by index.
fn picks(h : Harness, count : Int, n : Int) -> Array[Int] {
  let out = Array::make(count, 0)
  for _ in 0..<n {
    out[picked(h)] += 1
  }
  out
}

///|
test "every one of 100 responses can be picked" {
  let counts = picks(harness([weighted_file(Array::make(100, 1))]), 100, 3000)
  inspect(counts.iter().all(count => count > 0), content="true")
}

///|
test "over many draws, each response is picked about as often as its weight over the sum of the weights" {
  let n = 10000
  let counts = picks(harness([weighted_file([1, 2, 3, 4])]), 4, n)
  inspect(
    counts
    .mapi((i, count) => {
      "\{i}: \{plausible(count, n, (i + 1).to_double() / 10.0)}"
    })
    .join("\n"),
    content=(
      #|0: true
      #|1: true
      #|2: true
      #|3: true
    ),
  )
  // A response of weight 1 beside one of 1,000,000 comes about once in a
  // million: never in a thousand requests.
  let rare = picks(harness([weighted_file([1000000, 1])]), 2, 1000)
  debug_inspect(rare, content="[1000, 0]")
}

///|
test "without fault.seed, the picks come from the process generator, so its seed replays them" {
  let run = (process_seed : UInt64) => {
    let h = harness([weighted_file([1, 1, 1])], process_seed~)
    Array::makei(30, _ => picked(h))
  }
  inspect(
    "same seed, same picks: \{run(5) == run(5)}\nanother seed, other picks: \{run(5) != run(6)}",
    content=(
      #|same seed, same picks: true
      #|another seed, other picks: true
    ),
  )
}

///|
test "the Fault decisions and the helper output for a seed are the same with responses as with response" {
  let fault =
    #|{ "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
    #|  "connection": { "kind": "partial", "probability": 0.5 }, "seed": 42 }
  let body = "\"${fake.uuid()} ${fake.words(3)}\""
  let one = "{ \"status\": 200, \"template\": true, \"body\": \{body} }"
  let other = "{ \"status\": 201, \"template\": true, \"body\": \{body} }"
  let h = harness([
    faults_file([
      "{ \"id\": \"single\", \"mock\": \"m\", \"request\": { \"path\": \"/single\" }, \"response\": \{one}, \"fault\": \{fault} }",
      "{ \"id\": \"several\", \"mock\": \"m\", \"request\": { \"path\": \"/several\" }, \"responses\": [\{one}, \{other}], \"fault\": \{fault} }",
    ]),
  ])
  let run = (path : String) => {
    Array::makei(8, _ => {
      let outcome = h.send("GET", path)
      guard outcome.plan.body is Bytes(body) else { abort("not a body") }
      (outcome.plan.status, decision(outcome), @utf8.decode_lossy(body))
    })
  }
  let single = run("/single")
  let several = run("/several")
  inspect(
    single.map(r => (r.1, r.2)) == several.map(r => (r.1, r.2)),
    content="true",
  )
  // The decisions of seed 42, as every Stub with that seed gets them
  // (faults_test.mbt), the helper output of seed 42 (template_rules_test.mbt),
  // and the statuses the pick gives, as a separate model of it computes them.
  inspect(
    several.map(r => "\{r.0} \{r.1}: \{r.2}").join("\n"),
    content=(
      #|200 delay 0, Partial: 967d85fe-343d-4cc0-9b49-c024af3b3103 socket kernel ocean
      #|200 delay 0: bb468c1b-68bb-4082-8d7b-aae65078e215 chalk honey granite
      #|201 delay 395: 1354aacd-d385-4b03-a0d1-40e5777918b1 carbon cobalt bloom
      #|200 delay 572: ed5bd329-1d71-4b7a-aff8-8cf3ae01b8cc cactus fern blanket
      #|201 delay 818: ebb06a98-c910-49a9-863c-b37abc57b709 acid window desert
      #|201 delay 0, Partial: 1c2e0ff4-a0d5-4aed-b4ad-438075711b4f flint melody wizard
      #|201 delay 594, Partial: 27d6f805-3429-4e50-b862-24edf0b90b0a lagoon castle timber
      #|201 delay 0: d172e82e-c887-4c29-a139-b9a5d46c9e01 anchor agree garlic
    ),
  )
}

///|
test "the Journal records the index of the chosen response, and null for a Stub with response or a request no Stub matched" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "get-prices", "mock": "m", "request": { "path": "/prices" },
        #|      "responses": [{ "weight": 9, "status": 200 }, { "weight": 1, "status": 503 }],
        #|      "fault": { "seed": 7 } },
        #|    { "id": "plain", "mock": "m", "request": { "path": "/plain" },
        #|      "response": { "status": 200 } } ] }
      ),
    ),
  ])
  // Seed 7 picks the 503, then the 200 (see above).
  for target in ["/prices", "/prices", "/plain", "/nothing"] {
    ignore(h.record("GET", target))
  }
  guard h.query(None) is Object({ "entries": Array(entries), .. }) else {
    fail("no entries")
  }
  json_inspect(
    entries.map(entry => {
      guard entry is Object(entry) else { abort("not an object") }
      Json::object({
        "stub": entry["stub"],
        "status": entry["status"],
        "responseIndex": entry.get("responseIndex").unwrap_or("absent"),
      })
    }),
    content=[
      { "stub": "get-prices", "status": 503, "responseIndex": 1 },
      { "stub": "get-prices", "status": 200, "responseIndex": 0 },
      { "stub": "plain", "status": 200, "responseIndex": Json::null() },
      { "stub": Json::null(), "status": 404, "responseIndex": Json::null() },
    ],
  )
}

///|
/// Renders the Stub `id` for `GET /` with `seed`, and the response at
/// `response` when it is given, and shows the rendering's response index
/// and status, or why it cannot be rendered.
fn Harness::render_pick(
  self : Harness,
  id : String,
  seed? : UInt64,
  response? : Int,
) -> String {
  try
    self.engine.render(
      id,
      @engine.SampleRequest::from_json({}),
      now=self.now,
      seed?,
      response?,
      fresh_seed=() => 7,
    )
  catch {
    @engine.RenderFailure::UnknownStub(_) as err =>
      "unknown Stub: \{err.message()}"
    @engine.RenderFailure::UnknownResponse(..) as err =>
      "unknown response: \{err.message()}"
    err => "other error: \{err}"
  } noraise {
    rendering => {
      guard rendering.to_json() is Object(members) else {
        abort("not an object")
      }
      let index = members
        .get("responseIndex")
        .map_or("absent", j => j.stringify())
      "responseIndex \{index}, status \{rendering.status}"
    }
  }
}

///|
test "rendering shows the index of the response the seed picks, or renders the one asked for, and null for a Stub with response" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "get-prices", "mock": "m", "request": { "path": "/prices" },
        #|      "responses": [
        #|        { "weight": 9, "status": 200 },
        #|        { "weight": 1, "status": 503, "template": true, "body": "${fake.uuid()}" } ],
        #|      "fault": { "seed": 7 } },
        #|    { "id": "plain", "mock": "m", "request": { "path": "/plain" },
        #|      "response": { "status": 204 } } ] }
      ),
    ),
  ])
  inspect(
    [
      // The seed is the Stub's own, 7, unless one is given. A rendering
      // shows what the first request of a Stub with that seed gets: with
      // seed 7, the 503 (see above).
      h.render_pick("get-prices"),
      h.render_pick("get-prices", seed=7),
      h.render_pick("get-prices", response=0),
      h.render_pick("get-prices", response=1),
      h.render_pick("get-prices", response=2),
      h.render_pick("get-prices", response=-1),
      h.render_pick("plain"),
      h.render_pick("plain", response=0),
      h.render_pick("plain", response=1),
      h.render_pick("none", response=0),
    ].join("\n"),
    content=(
      #|responseIndex 1, status 503
      #|responseIndex 1, status 503
      #|responseIndex 0, status 200
      #|responseIndex 1, status 503
      #|unknown response: the Stub "get-prices" has no response 2: its responses run from 0 to 1
      #|unknown response: the Stub "get-prices" has no response -1: its responses run from 0 to 1
      #|responseIndex null, status 204
      #|responseIndex null, status 204
      #|unknown response: the Stub "plain" has no response 1: it has one response, whose index is 0
      #|unknown Stub: no Stub from the Definition files has the ID "none"
    ),
  )
}

///|
test "an Ephemeral Stub may give responses, with inline bodies only, and picks as a Stub from a file does" {
  let h = harness(shop)
  let id = h.add(
    "users",
    Some("test-a"),
    (
      #|{ "request": { "path": "/prices" },
      #|  "responses": [
      #|    { "weight": 9, "status": 200, "json": { "price": 101 } },
      #|    { "weight": 1, "status": 503, "template": true, "body": "${method} unavailable" } ],
      #|  "fault": { "seed": 7 } }
    ),
  )
  let answered = Array::makei(3, _ => {
    let outcome = h.send("GET", "/prices", session="test-a")
    guard outcome.journal is Some(entry) else { abort("no entry") }
    "\{response(outcome).replace_all(old="\n", new=" | ")} index \{@debug.to_string(entry.response_index)}"
  })
  inspect(
    "\{id}\n\{answered.join("\n")}",
    content=(
      #|eph-1
      #|503 | Smock-Mock: users; via=default | GET unavailable index Some(1)
      #|200 | Content-Type: application/json | Smock-Mock: users; via=default | {"price":101} index Some(0)
      #|503 | Smock-Mock: users; via=default | GET unavailable index Some(1)
    ),
  )
  inspect(
    [
      h.problems(
        (
          #|{ "responses": [{ "status": 200, "body": "x" },
          #|  { "status": 200, "bodyFile": "users/1.json" }] }
        ),
      ),
      h.problems(
        "{ \"response\": { \"status\": 200 }, \"responses\": [{ \"status\": 200 }] }",
      ),
      h.problems("{ \"responses\": [{ \"weight\": 0, \"status\": 200 }] }"),
    ].join("\n"),
    content=(
      #|/responses/1/bodyFile: is not allowed in an Ephemeral Stub, whose body must be inline: give "body" instead
      #|has "response" and "responses"; give exactly one of them
      #|/responses/0/weight: must be an integer from 1 to 1000000
    ),
  )
}

///|
test "the Near miss of a request that a Stub with responses nearly matched names only its request conditions" {
  let h = harness([prices])
  let outcome = h.send("POST", "/prices")
  guard outcome.near_miss is Some(near_miss) else { fail("no Near miss") }
  inspect(
    ToJson::to_json(near_miss).stringify(),
    content=(
      #|{"stub":"get-prices","stubSource":"file","failed":[{"condition":"method","expected":"GET","actual":["POST"]}]}
    ),
  )
}

///|
test "a template that fails in one of responses gives the 500 that points at it within the Stub, and the Journal records its index" {
  let h = harness([
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m" }],
        #|  "stubs": [
        #|    { "id": "get-user", "mock": "m", "request": { "path": "/users" },
        #|      "responses": [
        #|        { "weight": 1, "status": 200 },
        #|        { "weight": 1000000, "status": 200, "template": true,
        #|          "json": { "id": "${query.id}" } } ] } ] }
      ),
    ),
  ])
  let outcome = h.send("GET", "/users")
  guard outcome.journal is Some(entry) else { fail("no entry") }
  inspect(
    "\{response(outcome)}\nindex \{@debug.to_string(entry.response_index)}, \{@debug.to_string(entry.template_error)}",
    content=(
      #|500
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"error":"template failed","stub":"get-user","at":"/responses/1/json/id","message":"query.id is missing"}
      #|index Some(1), Some({ at: "/responses/1/json/id", message: "query.id is missing" })
    ),
  )
}
