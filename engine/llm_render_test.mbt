// Seam 1 tests of rendering LLM responses: what `smock render` and the
// Admin render operation show for a streamed and a non-streamed sample,
// with the ids and the waits their seed fixes, and Ephemeral Stubs that
// give `llm`.

///|
/// A Mock `openai` whose Stub `slow-hello`, without a seed of its own,
/// answers Chat Completions requests with "Hello!", paced by the spec's
/// example timing.
let slow_hello : (String, String) = (
  "openai.json",
  (
    #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
    #|  "stubs": [{ "id": "slow-hello", "mock": "openai",
    #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
    #|    "response": { "status": 200,
    #|      "llm": { "api": "openai-chat", "text": "Hello!",
    #|        "timing": {
    #|          "first": { "lognormal": { "median": 400, "sigma": 0.5 } },
    #|          "interval": { "uniform": { "min": 15, "max": 40 } } } } } }] }
  ),
)

///|
/// A sample Chat Completions request whose body is `body`.
fn chat_sample(body : String) -> Json {
  {
    "method": "POST",
    "path": "/v1/chat/completions",
    "headers": { "Host": "api.openai.test" },
    "body": body,
  }
}

///|
/// Renders the Stub `id` for `sample` at the harness's time with the seed
/// `seed`, and shows the rendering as `smock render` prints it.
fn Harness::render_seeded(
  self : Harness,
  id : String,
  sample : Json,
  seed~ : UInt64,
) -> String raise {
  let rendering = self.engine.render(
    id,
    @engine.SampleRequest::from_json(sample),
    now=self.now,
    seed~,
    fresh_seed=() => abort("a fresh seed was drawn"),
  )
  rendering.to_json().stringify(indent=2)
}

///|
test "render shows a streamed sample's events, each with its wait, with the ids and the waits the given seed fixes and the rendering's time as created" {
  let h = harness([slow_hello])
  h.now = 1_792_713_600_500L
  inspect(
    h.render_seeded("slow-hello", chat_sample(stream_body("true")), seed=7),
    content=(
      #|{
      #|  "stub": "slow-hello",
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
      #|        "value": "text/event-stream"
      #|      },
      #|      {
      #|        "name": "x-request-id",
      #|        "value": "req_TZp9I060Mzd0w4SDwiWTe2c8"
      #|      }
      #|    ],
      #|    "body": null,
      #|    "events": [
      #|      {
      #|        "delay": 0,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|      },
      #|      {
      #|        "delay": 824,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hell\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|      },
      #|      {
      #|        "delay": 27,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o!\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|      },
      #|      {
      #|        "delay": 0,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"logprobs\":null,\"finish_reason\":\"stop\"}]}"
      #|      },
      #|      {
      #|        "delay": 0,
      #|        "data": "[DONE]"
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
/// The reply's id, the request id and the waits of a rendering as
/// `smock render` prints it, on one line: the wait of each event of a
/// stream, or `a body` for the JSON reply.
fn ids_and_waits(rendering : String) -> String {
  let json = @json.parse(rendering) catch { _ => return rendering }
  guard json
    is {
      "response": {
        "headers": Array(headers),
        "body": body,
        "events": events,
        ..
      },
      ..
    } else {
    return rendering
  }
  let mut request_id = "no request id"
  for header in headers {
    if header is { "name": "x-request-id", "value": String(value), .. } {
      request_id = value
    }
  }
  let (reply, form) = match (body, events) {
    (Null, Array(events)) => {
      guard events is [{ "data": String(first), .. }, ..] else {
        return rendering
      }
      let waits = events.map(event => {
        guard event is { "delay": Number(delay, ..), .. } else { "?" }
        delay.to_int().to_string()
      })
      (first, "waits \{waits.join(" ")}")
    }
    ({ "data": String(data), .. }, Null) => (data, "a body")
    _ => return rendering
  }
  let id = try @json.parse(reply) catch {
    _ => "no id"
  } noraise {
    { "id": String(id), .. } => id
    _ => "no id"
  }
  "\{id}, \{request_id}, \{form}"
}

///|
test "the same seed renders the same ids and waits, for the stream and the JSON body alike, and another seed renders others" {
  let h = harness([slow_hello])
  let stream = chat_sample(stream_body("true"))
  let json = chat_sample(stream_body("false"))
  let first = h.render_seeded("slow-hello", stream, seed=7)
  let again = h.render_seeded("slow-hello", stream, seed=7)
  inspect(
    [
      "seed 7, stream: \{ids_and_waits(first)}",
      "seed 7 again, the same rendering: \{first == again}",
      "seed 7, JSON: \{ids_and_waits(h.render_seeded("slow-hello", json, seed=7))}",
      "seed 8, stream: \{ids_and_waits(h.render_seeded("slow-hello", stream, seed=8))}",
    ].join("\n"),
    content=(
      #|seed 7, stream: chatcmpl-oniRcSDFUU6bnxe66XwQR5pl, req_TZp9I060Mzd0w4SDwiWTe2c8, waits 0 824 27 0 0
      #|seed 7 again, the same rendering: true
      #|seed 7, JSON: chatcmpl-oniRcSDFUU6bnxe66XwQR5pl, req_TZp9I060Mzd0w4SDwiWTe2c8, a body
      #|seed 8, stream: chatcmpl-CBA7sTDZTEis8R77wCWUcHEk, req_sf9l9yK2ZsU4XOkCVtu7lW7D, waits 0 843 36 0 0
    ),
  )
}

///|
test "an Ephemeral Stub takes llm in response and in responses, is listed as it was given, and answers with its reply" {
  let h = harness([slow_hello])
  let given : Array[Json] = [
    {
      "request": {
        "method": "POST",
        "path": "/v1/chat/completions",
        "headers": { "X-Test-Case": "one" },
      },
      "response": {
        "status": 200,
        "llm": {
          "api": "openai-chat",
          "text": "One.",
          "usage": { "input": 3, "output": 1 },
          "timing": { "first": { "fixed": 5 } },
        },
      },
    },
    {
      "request": {
        "method": "POST",
        "path": "/v1/chat/completions",
        "headers": { "X-Test-Case": "two" },
      },
      "responses": [
        {
          "status": 200,
          "llm": {
            "api": "openai-chat",
            "chunks": ["T", "wo."],
            "stopReason": "length",
          },
        },
      ],
    },
  ]
  for stub in given {
    ignore(
      h.engine.add_ephemeral_stub(mock="openai", session=Some("test-a"), stub),
    )
  }
  let listed = h.engine.ephemeral_stubs(mock="openai", session=Some("test-a"))
  let out = []
  for stub in listed {
    out.push(stub.to_json().stringify())
  }
  // The newest is listed first.
  let as_given = match (listed, given) {
    ([newest, oldest], [Object(first), Object(second)]) =>
      newest.added == second && oldest.added == first
    _ => false
  }
  out.push("as given: \{as_given}")
  for case_ in ["one", "two"] {
    let headers = [("X-Test-Case", case_)]
    out.push("\{case_}: \{chosen(h.chat(headers~, session="test-a"))}")
    let stream = h.chat(body=stream_body("true"), headers~, session="test-a")
    out.push("\{case_}, streamed: \{waits(stream)}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|{"id":"eph-2","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"two"}},"responses":[{"status":200,"llm":{"api":"openai-chat","chunks":["T","wo."],"stopReason":"length"}}]}
      #|{"id":"eph-1","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"one"}},"response":{"status":200,"llm":{"api":"openai-chat","text":"One.","usage":{"input":3,"output":1},"timing":{"first":{"fixed":5}}}}}
      #|as given: true
      #|one: eph-1: One. (model "test-model")
      #|one, streamed: 0 opening, 5 "One.", 0 closing, 0 [DONE]
      #|two: eph-2: Two. (model "test-model")
      #|two, streamed: 0 opening, 0 "T", 0 "wo.", 0 closing, 0 [DONE]
    ),
  )
}
