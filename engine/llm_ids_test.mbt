// Seam 1 tests of an LLM reply's ids, model and request-id header: a fixed
// id and model, the request-id header smock adds or the Stub's own in its
// place, and the ids the n-th match repeats across Sessions under
// fault.seed.

///|
/// A Mock `openai` with a Stub that answers Chat Completions requests from
/// an LLM response whose text is `Hi there`, with `fields` after its `api`
/// and `text`, such as a fixed `id`, and `headers`, its own seed fixing its
/// generated ids.
fn ids_mock(
  fields? : String = "",
  headers? : String = "{}",
) -> (String, String) {
  (
    "openai.json",
    (
      #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      #|  "stubs": [{ "id": "chat", "mock": "openai",
      #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
      #|    "fault": { "seed": 7 },
      #|    "response": { "status": 200,
    ) +
    "      \"headers\": \{headers},\n" +
    "      \"llm\": { \"api\": \"openai-chat\", \"text\": \"Hi there\"\{fields} } } }] }",
  )
}

///|
/// The member `name` of the event data `data`, as compact JSON, or `data`
/// itself when it is not an object with that member, such as `[DONE]`.
fn data_member(data : String, name : String) -> String {
  let value = @json.parse(data) catch { _ => return data }
  match value {
    Object(members) =>
      members.get(name).map_or(data, value => value.stringify())
    _ => data
  }
}

///|
/// The ids of `outcome`'s plan: each of its request-id header fields, in
/// any case, then the id of its JSON body, or of each of its events, each
/// on a line of its own.
fn ids_of(outcome : @engine.Outcome) -> String {
  let lines = []
  for header in outcome.plan.headers {
    if header.0.to_lower() == "x-request-id" {
      lines.push("\{header.0}: \{header.1}")
    }
  }
  match outcome.plan.body {
    Bytes(_) => lines.push("JSON: \{body_member(outcome, "id")}")
    Events(events) =>
      for event in events {
        lines.push("chunk: \{data_member(event.data, "id")}")
      }
  }
  lines.join("\n")
}

///|
test "id fixes the reply's id in the JSON reply and in every chunk, and the request id stays the one the Stub's seed gives" {
  let generated = harness([ids_mock()])
  let fixed = harness([ids_mock(fields=", \"id\": \"chatcmpl-test-1\"")])
  inspect(
    [
      "generated, JSON:\n\{ids_of(generated.chat())}",
      "fixed, JSON:\n\{ids_of(fixed.chat())}",
      "generated, stream:\n\{ids_of(generated.chat(body=stream_body("true")))}",
      "fixed, stream:\n\{ids_of(fixed.chat(body=stream_body("true")))}",
    ].join("\n"),
    content=(
      #|generated, JSON:
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|fixed, JSON:
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|JSON: "chatcmpl-test-1"
      #|generated, stream:
      #|x-request-id: req_IazsHccliNw545TFSy204aSk
      #|chunk: "chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|chunk: "chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|chunk: "chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|chunk: "chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|chunk: [DONE]
      #|fixed, stream:
      #|x-request-id: req_IazsHccliNw545TFSy204aSk
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: [DONE]
    ),
  )
}

///|
test "the reply's model is the Stub's model when given, otherwise the request's when it is a string, otherwise empty" {
  let h = harness([
    (
      "openai.json",
      (
        #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
        #|  "stubs": [
        #|    { "id": "one-model", "mock": "openai",
        #|      "request": { "method": "POST", "path": "/v1/chat/completions",
        #|        "body": { "json": { "model": "gpt-6-astra" } } },
        #|      "response": { "status": 200,
        #|        "llm": { "api": "openai-chat", "text": "Hi", "model": "gpt-6-astra-2026-10-01" } } },
        #|    { "id": "any-model", "mock": "openai",
        #|      "request": { "method": "POST", "path": "/v1/chat/completions" },
        #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Hi" } } } ] }
      ),
    ),
  ])
  let models = (outcome : @engine.Outcome) => {
    let models = match outcome.plan.body {
      Bytes(_) => [body_member(outcome, "model")]
      Events(events) => {
        let models = []
        for event in events {
          models.push(data_member(event.data, "model"))
        }
        models
      }
    }
    "\{matched_id(outcome).unwrap_or("no Stub")}: \{models.join(" ")}"
  }
  let astra_stream = "{\"model\":\"gpt-6-astra\",\"stream\":true,\"messages\":[]}"
  inspect(
    [
      models(h.chat(body=chat_body(Some("gpt-6-astra")))),
      models(h.chat(body=astra_stream)),
      models(h.chat(body=chat_body(Some("test-model")))),
      models(h.chat(body=stream_body("true"))),
      models(h.chat(body=chat_body(None))),
      models(h.chat(body="{\"model\":4}")),
      models(h.chat(body="not JSON")),
    ].join("\n"),
    content=(
      #|one-model: "gpt-6-astra-2026-10-01"
      #|one-model: "gpt-6-astra-2026-10-01" "gpt-6-astra-2026-10-01" "gpt-6-astra-2026-10-01" [DONE]
      #|any-model: "test-model"
      #|any-model: "test-model" "test-model" "test-model" [DONE]
      #|any-model: ""
      #|any-model: ""
      #|any-model: ""
    ),
  )
}

///|
test "a Stub's own x-request-id, in any case, is sent alone in place of the generated one, and the reply's id stays as it was" {
  let own = (name : String, body : String) => {
    let h = harness([ids_mock(headers="{ \"\{name}\": \"req_from_the_stub\" }")])
    ids_of(h.chat(body~))
  }
  let json = chat_body(Some("test-model"))
  let stream = stream_body("true")
  inspect(
    [
      "none:\n\{ids_of(harness([ids_mock()]).chat())}",
      "X-Request-Id:\n\{own("X-Request-Id", json)}",
      "x-request-id:\n\{own("x-request-id", json)}",
      "X-REQUEST-ID:\n\{own("X-REQUEST-ID", json)}",
      "X-Request-Id, stream:\n\{own("X-Request-Id", stream)}",
    ].join("\n"),
    content=(
      #|none:
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|X-Request-Id:
      #|X-Request-Id: req_from_the_stub
      #|JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|x-request-id:
      #|x-request-id: req_from_the_stub
      #|JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|X-REQUEST-ID:
      #|X-REQUEST-ID: req_from_the_stub
      #|JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|X-Request-Id, stream:
      #|X-Request-Id: req_from_the_stub
      #|chunk: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|chunk: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|chunk: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|chunk: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|chunk: [DONE]
    ),
  )
  // The Stub's own field stays where the Stub gives it, and smock adds
  // nothing after the Stub's fields.
  let h = harness([
    ids_mock(
      headers="{ \"X-Request-Id\": \"req_from_the_stub\", \"x-ratelimit-remaining-requests\": \"59\" }",
    ),
  ])
  let response = response(h.chat())
  inspect(
    response[:response.find("\n{").unwrap()],
    content=(
      #|200
      #|Content-Type: application/json
      #|X-Request-Id: req_from_the_stub
      #|x-ratelimit-remaining-requests: 59
    ),
  )
}

///|
test "the request-id header comes after the Stub's own fields, in the JSON reply as in the stream" {
  let h = harness([chat_mock])
  let head = (outcome : @engine.Outcome) => {
    outcome.plan.headers.map(header => "\{header.0}: \{header.1}").join("\n")
  }
  inspect(
    [
      "JSON:\n\{head(h.chat())}",
      "stream:\n\{head(h.chat(body=stream_body("true")))}",
    ].join("\n"),
    content=(
      #|JSON:
      #|Content-Type: application/json
      #|x-ratelimit-remaining-requests: 59
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|stream:
      #|Content-Type: text/event-stream
      #|x-ratelimit-remaining-requests: 59
      #|x-request-id: req_IazsHccliNw545TFSy204aSk
    ),
  )
}

///|
test "with fault.seed, the n-th request a Stub matches repeats its ids from run to run, whatever Session sends it" {
  let ids_across = (sessions : Array[String?]) => {
    let h = harness([ids_mock()])
    sessions.map(session => ids_of(h.chat(session?)).replace(old="\n", new=", "))
  }
  let first = ids_across([Some("test-a"), Some("test-b"), None, Some("test-a")])
  let second = ids_across([None, Some("test-c"), Some("test-c"), Some("test-b")])
  inspect(first == second, content="true")
  inspect(
    first.join("\n"),
    content=(
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8, JSON: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|x-request-id: req_IazsHccliNw545TFSy204aSk, JSON: "chatcmpl-lM10tfraqbMuqY6lc9FjN5n8"
      #|x-request-id: req_810vjSuY0PZszZKp6WgTbKqO, JSON: "chatcmpl-sYbxupdedZuAOye5C75BpQuY"
      #|x-request-id: req_qnlVU2NKv0ovsUB2WrivdLqe, JSON: "chatcmpl-zQLnUu77sZ7eoZollCsu1gWj"
    ),
  )
}
