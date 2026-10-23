// Seam 1 tests of the agent loops in docs/definition-files.md: for each
// API, a first Stub that calls a tool and a second that answers once the
// last message is the tool's result, told apart with `$last` and quoting
// the result with `last()`; Responses follow-ups by `previous_response_id`;
// and a conversation of several turns, followed by a Scenario and counted
// by a Variable. Each Mock is the docs' Definition file as written.

///|
/// The Chat Completions loop of the docs: `ask-weather` calls
/// `get_weather` on any turn but a tool result, and `answer-weather`
/// quotes the tool's result.
let loop_chat : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/chat/completions
    #|      body: { json: { messages: { $not: { $last: { role: tool } } } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/chat/completions
    #|      body: { json: { messages: { $last: { role: tool } } } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: openai-chat
    #|        text: It is ${last(body.messages).content} in Paris.
  ),
)

///|
/// The JSON body of `outcome`'s plan, or a failure when it is not JSON.
fn agent_reply(outcome : @engine.Outcome) -> Json raise {
  guard outcome.plan.body is Bytes(body) else { fail("a stream") }
  @json.parse(@utf8.decode_lossy(body))
}

///|
/// One line for a turn of a conversation: the Stub that answered, or the
/// status and the Near miss when none did, then what the reply says in any
/// of the three APIs, its text quoted and each tool call as its name and
/// arguments.
fn turn_line(outcome : @engine.Outcome) -> String raise {
  guard matched_id(outcome) is Some(id) else {
    let near_miss = []
    for header in outcome.plan.headers {
      if header.0 == "Smock-Near-Miss" {
        near_miss.push(", Smock-Near-Miss: \{header.1}")
      }
    }
    return "no Stub: \{outcome.plan.status}\{near_miss.join("")}"
  }
  let said = []
  fn say_text(text : Json) {
    if text is String(text) && text != "" {
      said.push(Json::string(text).stringify())
    }
  }

  fn say_call(name : Json, arguments : Json) {
    let arguments = match arguments {
      String(text) => text
      other => other.stringify()
    }
    said.push("\{name.stringify()} \{arguments}")
  }

  match agent_reply(outcome) {
    { "choices": [{ "message": message, .. }], .. } => {
      if message is { "content": content, .. } {
        say_text(content)
      }
      if message is { "tool_calls": Array(calls), .. } {
        for call in calls {
          guard call
            is { "function": { "name": name, "arguments": arguments, .. }, .. } else {
            fail("a tool call without a function")
          }
          say_call(name, arguments)
        }
      }
    }
    { "type": "message", "content": Array(blocks), .. } =>
      for block in blocks {
        match block {
          { "type": "text", "text": text, .. } => say_text(text)
          { "type": "tool_use", "name": name, "input": input, .. } =>
            say_call(name, input)
          _ => fail("an unknown block")
        }
      }
    { "object": "response", "output": Array(items), .. } =>
      for item in items {
        match item {
          { "type": "message", "content": [{ "text": text, .. }], .. } =>
            say_text(text)
          { "type": "function_call", "name": name, "arguments": arguments, .. } =>
            say_call(name, arguments)
          _ => fail("an unknown item")
        }
      }
    _ => fail("not an LLM reply")
  }
  "\{id}: \{said.join(", ")}"
}

///|
/// `body` as the compact JSON text of a request.
fn wire(body : Json) -> String {
  body.stringify()
}

///|
/// The question that opens each conversation.
let weather_question : Json = { "role": "user", "content": "Weather in Paris?" }

///|
test "the docs' Chat Completions loop: the question gets the tool call, and the next turn, which sends back the reply's message and the tool's result, gets text that quotes the result" {
  let h = harness([loop_chat])
  let first = h.chat(
    body=wire({ "model": "gpt-6-astra", "messages": [weather_question] }),
  )
  guard agent_reply(first)
    is {
      "choices": [{ "message": { "tool_calls": [call], .. } as message, .. }],
      ..
    } else {
    fail("no tool call")
  }
  guard call is { "id": String(call_id), .. } else { fail("no call id") }
  let tool : Json = {
    "role": "tool",
    "tool_call_id": call_id,
    "content": "18°C",
  }
  let second = h.chat(
    body=wire({
      "model": "gpt-6-astra",
      "messages": [weather_question, message, tool],
    }),
  )
  inspect(
    "\{turn_line(first)}\n\{turn_line(second)}",
    content=(
      #|ask-weather: "get_weather" {"city":"Paris"}
      #|answer-weather: "It is 18°C in Paris."
    ),
  )
}

///|
/// The Messages loop of the docs: `ask-weather` calls `get_weather` on any
/// turn but a tool result, and `answer-weather` quotes the result of the
/// tool_result block of the last message.
let loop_messages : (String, String) = (
  "anthropic.yaml",
  (
    #|mocks:
    #|  - name: anthropic
    #|stubs:
    #|  - id: ask-weather
    #|    mock: anthropic
    #|    request:
    #|      method: POST
    #|      path: /v1/messages
    #|      body:
    #|        json:
    #|          messages:
    #|            $not:
    #|              $last: { role: user, content: { $includes: { type: tool_result } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|  - id: answer-weather
    #|    mock: anthropic
    #|    request:
    #|      method: POST
    #|      path: /v1/messages
    #|      body:
    #|        json:
    #|          messages:
    #|            $last: { role: user, content: { $includes: { type: tool_result } } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: anthropic-messages
    #|        text: "It is ${find(last(body.messages).content, 'type', 'tool_result').content} in Paris."
  ),
)

///|
test "the docs' Messages loop: the question gets the tool_use block, and the next turn, whose last user message holds the tool_result, gets text that quotes it, with or without text after it" {
  let h = harness([loop_messages])
  let first = h.messages(
    body=wire({
      "model": "claude-test",
      "max_tokens": 1024,
      "messages": [weather_question],
    }),
  )
  guard agent_reply(first)
    is { "content": [{ "id": String(id), .. }] as content, .. } else {
    fail("no tool_use block")
  }
  let assistant : Json = { "role": "assistant", "content": content }
  let result : Json = {
    "type": "tool_result",
    "tool_use_id": id,
    "content": "18°C",
  }
  let then : Json = { "type": "text", "text": "Thanks." }
  let next_turn = fn(blocks : Array[Json]) {
    h.messages(
      body=wire({
        "model": "claude-test",
        "max_tokens": 1024,
        "messages": [
          weather_question,
          assistant,
          { "role": "user", "content": Json::array(blocks) },
        ],
      }),
    )
  }
  inspect(
    [
      turn_line(first),
      turn_line(next_turn([result])),
      turn_line(next_turn([result, then])),
    ].join("\n"),
    content=(
      #|ask-weather: "get_weather" {"city":"Paris"}
      #|answer-weather: "It is 18°C in Paris."
      #|answer-weather: "It is 18°C in Paris."
    ),
  )
}

///|
/// The Responses loop of the docs: `ask-weather` calls `get_weather` on any
/// turn but a function call's output, and `answer-weather` quotes the
/// output.
let loop_responses : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { input: { $not: { $last: { type: function_call_output } } } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { input: { $last: { type: function_call_output } } } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: openai-responses
    #|        text: It is ${last(body.input).output} in Paris.
  ),
)

///|
test "the docs' Responses loop: the question, given as a string, gets the function_call item, and the next turn, which sends back the reply's output and the call's output, gets text that quotes it" {
  let h = harness([loop_responses])
  let first = h.responses(
    wire({ "model": "gpt-6-astra", "input": "Weather in Paris?" }),
  )
  guard agent_reply(first)
    is { "output": [{ "call_id": String(call_id), .. } as call], .. } else {
    fail("not one function_call item")
  }
  let output : Json = {
    "type": "function_call_output",
    "call_id": call_id,
    "output": "18°C",
  }
  let second = h.responses(
    wire({ "model": "gpt-6-astra", "input": [weather_question, call, output] }),
  )
  inspect(
    "\{turn_line(first)}\n\{turn_line(second)}",
    content=(
      #|ask-weather: "get_weather" {"city":"Paris"}
      #|answer-weather: "It is 18°C in Paris."
    ),
  )
}

///|
/// The Responses follow-ups of the docs, by the first reply's fixed id:
/// `ask-weather` answers a request without `previous_response_id` as
/// `resp_weather`, `answer-weather` a follow-up of that id, and
/// `get-weather` the retrieval of it.
let follow_ups_by_id : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { previous_response_id: { $exists: false } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        id: resp_weather
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { previous_response_id: resp_weather } }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: openai-responses
    #|        text: It is ${last(body.input).output} in Paris.
    #|  - id: get-weather
    #|    mock: openai
    #|    request: { method: GET, path: /v1/responses/resp_weather }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        id: resp_weather
    #|        model: gpt-6-astra
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
  ),
)

///|
/// A follow-up of the Response `previous`, which sends only the output of
/// the call `call_id`.
fn follow_up(previous : String, call_id : String) -> String {
  wire({
    "model": "gpt-6-astra",
    "previous_response_id": previous,
    "input": [
      { "type": "function_call_output", "call_id": call_id, "output": "18°C" },
    ],
  })
}

///|
/// The reply's `id` and `previous_response_id` members of `outcome`'s
/// Response object, a generated id as `resp_…`, or nothing when no Stub
/// answered.
fn response_ids(outcome : @engine.Outcome) -> String raise {
  guard matched_id(outcome) is Some(_) else { return "" }
  guard agent_reply(outcome)
    is { "id": String(id), "previous_response_id": previous, .. } else {
    fail("no ids")
  }
  let id = if id.has_prefix("resp_") && id.length() == 29 {
    "resp_…"
  } else {
    id
  }
  " (id \{id}, previous_response_id \{previous.stringify()})"
}

///|
test "the docs' Responses follow-ups by a fixed id: the follow-up of resp_weather, which sends only the call's output, gets text that quotes it and names the Response it follows; GET retrieves it; a follow-up of another id matches nothing" {
  let h = harness([follow_ups_by_id])
  let first = h.responses(
    wire({ "model": "gpt-6-astra", "input": "Weather in Paris?" }),
  )
  guard agent_reply(first)
    is { "output": [{ "call_id": String(call_id), .. }], .. } else {
    fail("not one function_call item")
  }
  let turns = [
    first,
    h.responses(follow_up("resp_weather", call_id)),
    h.send("GET", "/v1/responses/resp_weather", headers=[
      ("Host", "api.openai.test"),
    ]),
    h.responses(follow_up("resp_other", call_id)),
  ]
  let lines = []
  for outcome in turns {
    lines.push(turn_line(outcome) + response_ids(outcome))
  }
  inspect(
    lines.join("\n"),
    content=(
      #|ask-weather: "get_weather" {"city":"Paris"} (id resp_weather, previous_response_id null)
      #|answer-weather: "It is 18°C in Paris." (id resp_…, previous_response_id "resp_weather")
      #|get-weather: "get_weather" {"city":"Paris"} (id resp_weather, previous_response_id null)
      #|no Stub: 404, Smock-Near-Miss: ask-weather; failed=body
    ),
  )
}

///|
/// The Responses follow-ups of the docs, by a Scenario: `ask-weather`
/// answers a request without `previous_response_id` and moves `weather` to
/// `Asked`, and `answer-weather` answers a follow-up of any id in that
/// state.
let follow_ups_by_scenario : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { previous_response_id: { $exists: false } } }
    #|    scenario: { name: weather, moveTo: Asked }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { previous_response_id: { $exists: true } } }
    #|    scenario: { name: weather, requires: Asked, moveTo: Answered }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: openai-responses
    #|        text: It is ${last(body.input).output} in Paris.
  ),
)

///|
test "the docs' Responses follow-ups by a Scenario: a follow-up of the generated id gets text once the question has moved the Scenario, and none before it or after the answer" {
  let h = harness([follow_ups_by_scenario])
  let early = h.responses(follow_up("resp_early", "call_early"))
  let first = h.responses(
    wire({ "model": "gpt-6-astra", "input": "Weather in Paris?" }),
  )
  guard agent_reply(first)
    is { "id": String(id), "output": [{ "call_id": String(call_id), .. }], .. } else {
    fail("not one function_call item")
  }
  let lines = []
  for
    outcome in [
      early,
      first,
      h.responses(follow_up(id, call_id)),
      h.responses(follow_up(id, call_id)),
    ] {
    lines.push(turn_line(outcome) + response_ids(outcome))
  }
  inspect(
    lines.join("\n").replace_all(old=id, new="<the first id>"),
    content=(
      #|no Stub: 404, Smock-Near-Miss: ask-weather; failed=body
      #|ask-weather: "get_weather" {"city":"Paris"} (id resp_…, previous_response_id null)
      #|answer-weather: "It is 18°C in Paris." (id resp_…, previous_response_id "<the first id>")
      #|no Stub: 404, Smock-Near-Miss: ask-weather; failed=body
    ),
  )
}
