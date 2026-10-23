// Seam 1 tests of LLM responses: the plan of a Stub whose response gives
// `llm`, among conditions, `responses`, Faults, Ephemeral Stubs, render and
// the Journal.

///|
/// A Mock `openai` with a Stub that answers Chat Completions requests from
/// an LLM response, its own seed fixing its ids.
let chat_mock : (String, String) = (
  "openai.json",
  (
    #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
    #|  "stubs": [{ "id": "chat", "mock": "openai",
    #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
    #|    "response": { "status": 200,
    #|      "headers": { "x-ratelimit-remaining-requests": "59",
    #|        "Content-Type": "text/plain" },
    #|      "llm": { "api": "openai-chat", "text": "Hello! How can I assist you today?" } },
    #|    "fault": { "seed": 7 } }] }
  ),
)

///|
/// The JSON body of a Chat Completions request for `model`, or for no
/// model, with one user message.
fn chat_body(model : String?) -> String {
  let model = match model {
    Some(model) => "\"model\":\"\{model}\","
    None => ""
  }
  "{\{model}\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
}

///|
/// A Chat Completions request to the Host of `chat_mock`, with the JSON
/// body `body`, by default one for `test-model`, and the header fields
/// `headers` after Host and Content-Type.
fn Harness::chat(
  self : Harness,
  path? : String = "/v1/chat/completions",
  body? : String = chat_body(Some("test-model")),
  headers? : Array[(String, String)] = [],
  session? : String,
) -> @engine.Outcome {
  self.send(
    "POST",
    path,
    headers=[("Host", "api.openai.test"), ("Content-Type", "application/json")] +
      headers,
    body~,
    session?,
  )
}

///|
/// The planned body of `outcome` as text.
fn body_text(outcome : @engine.Outcome) -> String {
  match outcome.plan.body {
    Bytes(body) => @utf8.decode_lossy(body)
    Events(_) => "(events)"
  }
}

///|
/// The JSON body of `outcome`'s plan, or `null` when it is not JSON.
fn body_value(outcome : @engine.Outcome) -> Json {
  @json.parse(body_text(outcome)) catch {
    _ => Json::null()
  }
}

///|
/// The member `name` of the JSON body of `outcome`, as compact JSON.
fn body_member(outcome : @engine.Outcome, name : String) -> String {
  match body_value(outcome) {
    Object(members) => members.get(name).map_or("missing", v => v.stringify())
    _ => "not JSON"
  }
}

///|
/// The text of the reply in the JSON body of `outcome`: its first choice's
/// content.
fn reply_content(outcome : @engine.Outcome) -> String {
  match body_value(outcome) {
    { "choices": [{ "message": { "content": String(content), .. }, .. }], .. } =>
      content
    _ => "no content"
  }
}

///|
test "an llm Stub answers with one chat.completion JSON body, as application/json in place of the Stub's Content-Type, and its other headers as written" {
  let h = harness([chat_mock])
  let outcome = h.chat()
  inspect(
    response(outcome),
    content=(
      #|200
      #|Content-Type: application/json
      #|x-ratelimit-remaining-requests: 59
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! How can I assist you today?","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
    ),
  )
}

///|
test "an llm Stub's Journal entry records the request as any other, with no new field, and responseIndex as today" {
  let h = harness([chat_mock])
  guard h.chat().journal is Some(entry) else { fail("no Journal entry") }
  json_inspect(entry.to_json(), content={
    "seq": 0,
    "receivedAt": "2026-10-12T14:30:05.123Z",
    "durationMs": null,
    "session": null,
    "host": "api.openai.test",
    "mock": "openai",
    "viaDefault": false,
    "digest": "fee2833cb8c4",
    "request": {
      "method": "POST",
      "target": "/v1/chat/completions",
      "version": "HTTP/1.1",
      "headers": [
        { "name": "Host", "value": "api.openai.test" },
        { "name": "Content-Type", "value": "application/json" },
      ],
      "body": {
        "encoding": "utf-8",
        "data": "{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
        "size": 66,
        "truncated": false,
      },
    },
    "stub": "chat",
    "stubSource": "file",
    "scenario": null,
    "responseIndex": null,
    "crud": null,
    "variablesWritten": [],
    "dataWritten": [],
    "dataError": null,
    "nearMiss": null,
    "status": 200,
    "fault": null,
    "templateError": null,
  })
}

///|
/// The reply ids of `n` requests that `chat_mock`'s Stub answers, in a run
/// whose process generator is seeded with `process_seed`, with a request
/// that no Stub matches before each one when `interleaved`. `seeded` keeps
/// the Stub's own seed.
fn chat_ids(
  process_seed : UInt64,
  n : Int,
  interleaved? : Bool = false,
  seeded? : Bool = true,
) -> Array[String] {
  let file = if seeded {
    chat_mock
  } else {
    (
      chat_mock.0,
      chat_mock.1.replace(old="\"fault\": { \"seed\": 7 }", new="\"fault\": {}"),
    )
  }
  let h = harness([file], process_seed~)
  Array::makei(n, _ => {
    if interleaved {
      ignore(h.chat(path="/v1/models"))
    }
    body_member(h.chat(), "id")
  })
}

///|
test "with fault.seed, the n-th request a Stub matches gets the same ids in every run, whatever other requests draw" {
  let alone = chat_ids(1, 3)
  inspect(alone == chat_ids(2, 3, interleaved=true), content="true")
  inspect(
    alone.join("\n"),
    content=(
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|"chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|"chatcmpl-sYbxupdedZuAOye5C75BpQuY"
    ),
  )
}

///|
test "without fault.seed, ids draw from the process generator, so --seed replays them" {
  let first = chat_ids(5, 3, seeded=false)
  inspect(first == chat_ids(5, 3, seeded=false), content="true")
  inspect(first == chat_ids(6, 3, seeded=false), content="false")
  // The Stub's seed does not apply: its draws are not those of seed 7.
  inspect(first == chat_ids(5, 3), content="false")
}

///|
/// A Stub that answers one request in four with an ordinary 429 and the
/// others with 200 and `body`, a body field, its header drawing from the
/// helpers, and whose delay and connection Fault are random, with a seed.
fn rate_limited(body : String) -> (String, String) {
  (
    "openai.json",
    (
      #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      #|  "stubs": [{ "id": "chat", "mock": "openai",
      #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
      #|    "responses": [
      #|      { "weight": 1, "status": 429,
      #|        "headers": { "Retry-After": "1", "x-should-retry": "false" },
      #|        "json": { "error": { "message": "Rate limit reached", "type": "requests",
      #|          "param": null, "code": "rate_limit_exceeded" } } },
      #|      { "weight": 3, "status": 200, "template": true,
      #|        "headers": { "X-Trace": "${fake.uuid()}" },
    ) +
    "        \{body} } ],\n" +
    (
      #|    "fault": { "seed": 7,
      #|      "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
      #|      "connection": { "kind": "close", "probability": 0.25 } } }] }
    ),
  )
}

///|
/// What each of `n` requests to `h` gets from `rate_limited`: its status,
/// its trace header, its delay, its connection Fault and its Journal
/// entry's responseIndex.
fn rate_limited_answers(h : Harness, n : Int) -> Array[String] {
  Array::makei(n, _ => {
    let outcome = h.chat()
    let trace = outcome.plan.headers
      .iter()
      .find_first(header => header.0 == "X-Trace")
      .map_or("-", header => header.1)
    let index = outcome.journal.map_or("-", entry => {
      @debug.to_string(entry.response_index)
    })
    "\{outcome.plan.status} \{trace} delay \{outcome.plan.delay_ms} \{@debug.to_string(outcome.plan.fault)} responseIndex \{index}"
  })
}

///|
test "in weighted responses, an llm reply beside an ordinary 429 gets the picks, Fault decisions and helper output that a json body in its place gets" {
  let with_llm = rate_limited_answers(
    harness([
      rate_limited("\"llm\": { \"api\": \"openai-chat\", \"text\": \"Hi\" }"),
    ]),
    40,
  )
  let with_json = rate_limited_answers(
    harness([rate_limited("\"json\": { \"text\": \"Hi\" }")]),
    40,
  )
  inspect(with_llm == with_json, content="true")
  inspect(
    with_llm[:6].iter().collect().join("\n"),
    content=(
      #|200 491faadb-213a-4ae9-b52a-e618828349a6 delay 189 None responseIndex Some(1)
      #|200 1536f6e7-42e4-4013-8961-f70141e4a66e delay 0 None responseIndex Some(1)
      #|200 35f7c125-4a1c-4694-8818-45fb8765ab32 delay 809 Some(Close) responseIndex Some(1)
      #|200 ce737663-bd25-44aa-8901-00b185724762 delay 0 None responseIndex Some(1)
      #|429 - delay 749 None responseIndex Some(0)
      #|200 460bc8e2-3b5e-4309-9ddb-1d40837a14d3 delay 20 None responseIndex Some(1)
    ),
  )
}

///|
/// A Mock `openai` whose LLM Stubs on one path are told apart by a header
/// and a body condition, the last one by none: no condition on the model.
let chosen_by_conditions : (String, String) = (
  "openai.json",
  (
    #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
    #|  "stubs": [
    #|    { "id": "by-header", "mock": "openai",
    #|      "request": { "method": "POST", "path": "/v1/chat/completions",
    #|        "headers": { "X-Test-Case": "weather" } },
    #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Sunny." } } },
    #|    { "id": "by-body", "mock": "openai",
    #|      "request": { "method": "POST", "path": "/v1/chat/completions",
    #|        "body": { "json": { "messages": { "$includes": { "role": "system" } } } } },
    #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "As instructed." } } },
    #|    { "id": "any-model", "mock": "openai",
    #|      "request": { "method": "POST", "path": "/v1/chat/completions" },
    #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Hello." } } },
    #|    { "id": "other-path", "mock": "openai",
    #|      "request": { "method": "POST", "path": "/openai/v1/chat/completions" },
    #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Proxied." } } } ] }
  ),
)

///|
/// The Stub that answers `outcome`, with the reply's text and model.
fn chosen(outcome : @engine.Outcome) -> String {
  "\{matched_id(outcome).unwrap_or("no Stub")}: \{reply_content(outcome)} (model \{body_member(outcome, "model")})"
}

///|
test "path, header and body conditions choose an llm Stub, and one with no condition on the model answers any model" {
  let h = harness([chosen_by_conditions])
  let system = "{\"model\":\"m-1\",\"messages\":[{\"role\":\"system\",\"content\":\"Be brief.\"},{\"role\":\"user\",\"content\":\"Hi\"}]}"
  inspect(
    [
      chosen(h.chat(headers=[("X-Test-Case", "weather")])),
      chosen(h.chat(body=system)),
      chosen(h.chat(body=chat_body(Some("gpt-6-astra")))),
      chosen(h.chat(body=chat_body(Some("claude-opus-5-5")))),
      chosen(h.chat(body=chat_body(None))),
      chosen(h.chat(body="not JSON")),
      chosen(h.chat(path="/openai/v1/chat/completions")),
    ].join("\n"),
    content=(
      #|by-header: Sunny. (model "test-model")
      #|by-body: As instructed. (model "m-1")
      #|any-model: Hello. (model "gpt-6-astra")
      #|any-model: Hello. (model "claude-opus-5-5")
      #|any-model: Hello. (model "")
      #|any-model: Hello. (model "")
      #|other-path: Proxied. (model "test-model")
    ),
  )
}

///|
test "a request that no llm Stub matches gets smock's usual noMatch reply and Near miss" {
  let h = harness([chat_mock])
  let outcome = h.chat(path="/v1/chat/completion")
  inspect(
    response(outcome),
    content=(
      #|404
      #|Content-Type: application/json
      #|Smock-Near-Miss: chat; failed=path
      #|{"error":"no Stub matched"}
    ),
  )
}

///|
test "an Ephemeral Stub with llm answers its own Session only" {
  let h = harness([chat_mock])
  let added = h.engine.add_ephemeral_stub(
    mock="openai",
    session=Some("test-a"),
    @json.parse(
      (
        #|{ "request": { "method": "POST", "path": "/v1/chat/completions" },
        #|  "responses": [{ "status": 200, "headers": { "X-Session": "test-a" },
        #|    "llm": { "api": "openai-chat", "text": "Only for test-a." } }] }
      ),
    ),
  )
  inspect(
    [
      "test-a: \{chosen(h.chat(session="test-a"))}",
      "test-b: \{chosen(h.chat(session="test-b"))}",
      "no Session: \{chosen(h.chat())}",
    ].join("\n"),
    content=(
      #|test-a: eph-1: Only for test-a. (model "test-model")
      #|test-b: chat: Hello! How can I assist you today? (model "test-model")
      #|no Session: chat: Hello! How can I assist you today? (model "test-model")
    ),
  )
  inspect(added.id, content="eph-1")
}

///|
test "an Ephemeral Stub whose llm breaks the rules is refused with the problems a Definition file gets" {
  let h = harness([chat_mock])
  let stub = @json.parse(
    (
      #|{ "responses": [
      #|    { "status": 200, "llm": { "text": "Hi", "stream": true } },
      #|    { "status": 200, "llm": { "api": "openai" }, "body": "Hi" } ] }
    ),
  )
  let problems = try
    h.engine.add_ephemeral_stub(mock="openai", session=None, stub)
  catch {
    InvalidStub(problems) => problems.map(p => p.to_string()).join("\n")
    error => fail(@debug.to_string(error))
  } noraise {
    _ => "added"
  }
  inspect(
    problems,
    content=(
      #|/responses/0/llm/stream: is not a known field
      #|/responses/0/llm: needs "api"
      #|/responses/1/llm/api: must be "openai-chat" or "openai-responses"
      #|/responses/1: has "body" and "llm"; give at most one of "body", "bodyFile", "json", "events" and "llm"
    ),
  )
}

///|
test "render shows an llm Stub's JSON reply through the path a request takes, with the ids its seed fixes and the rendering's time as created" {
  let h = harness([chat_mock])
  let sample : Json = {
    "method": "POST",
    "path": "/v1/chat/completions",
    "headers": { "Host": "api.openai.test" },
    "body": chat_body(Some("test-model")),
  }
  h.now = 1_792_713_600_500L
  inspect(
    h.render("chat", sample),
    content=(
      #|{
      #|  "stub": "chat",
      #|  "mock": "openai",
      #|  "time": "2026-10-23T00:00:00.500Z",
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
      #|        "name": "x-ratelimit-remaining-requests",
      #|        "value": "59"
      #|      },
      #|      {
      #|        "name": "x-request-id",
      #|        "value": "req_TZp9I060Mzd0w4SDwiWTe2c8"
      #|      }
      #|    ],
      #|    "body": {
      #|      "encoding": "utf-8",
      #|      "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello! How can I assist you today?\",\"refusal\":null,\"annotations\":[]},\"logprobs\":null,\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0,\"prompt_tokens_details\":{\"cached_tokens\":0,\"audio_tokens\":0},\"completion_tokens_details\":{\"reasoning_tokens\":0,\"audio_tokens\":0,\"accepted_prediction_tokens\":0,\"rejected_prediction_tokens\":0}},\"service_tier\":\"default\"}",
      #|      "size": 567,
      #|      "truncated": false
      #|    },
      #|    "events": null
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
  // The Stub's seed is 7: the rendering's ids are those of the first
  // request the Stub matches.
  let rendering = h.engine.render(
    "chat",
    @engine.SampleRequest::from_json(sample),
    now=h.now,
    fresh_seed=() => 1,
  )
  guard rendering.body is Bytes(rendered) else { fail("not a body") }
  inspect(@utf8.decode_lossy(rendered) == body_text(h.chat()), content="true")
  // Another seed gives other ids.
  let reseeded = h.engine.render(
    "chat",
    @engine.SampleRequest::from_json(sample),
    now=h.now,
    seed=8,
    fresh_seed=() => 1,
  )
  guard reseeded.body is Bytes(reseeded) else { fail("not a body") }
  inspect(
    @utf8.decode_lossy(reseeded).contains("chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"),
    content="false",
  )
}

///|
test "a reload with an llm that breaks the rules keeps the current set serving" {
  let h = harness([chat_mock])
  let result = h.reload([
    (
      chat_mock.0,
      chat_mock.1.replace(old="\"openai-chat\"", new="\"openai-chats\""),
    ),
  ])
  inspect(
    reload_summary(result).replace_all(
      old=h.engine.status().digest,
      new="<digest>",
    ),
    content=(
      #|Failed at 1791815460000: <digest> -> <digest>
      #|openai.json: /stubs/0/response/llm/api: must be "openai-chat" or "openai-responses"
    ),
  )
  inspect(reply_content(h.chat()), content="Hello! How can I assist you today?")
}
