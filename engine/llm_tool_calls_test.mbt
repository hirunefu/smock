// Seam 1 tests of an LLM reply's tool calls: a Stub that declares them in a
// Definition file, its JSON reply and its stream, their ids under
// fault.seed, and the next turn of an agent loop, told apart by `$last`.

///|
/// A Mock `openai` with the two Stubs of an agent loop: `ask-weather`
/// answers a conversation whose last message is the user's with text and
/// a tool call, its own seed fixing its ids, and `answer-weather` one whose
/// last message is the tool's result with text.
let weather_mock : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/chat/completions
    #|      body: { json: { messages: { $last: { role: user } } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        text: Let me check.
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|        usage: { input: 31, output: 18 }
    #|    fault: { seed: 7 }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/chat/completions
    #|      body: { json: { messages: { $last: { role: tool } } } }
    #|    response:
    #|      status: 200
    #|      llm: { api: openai-chat, text: It is 18°C in Paris. }
  ),
)

///|
/// The first turn of the conversation: the user's question, with the
/// `stream` member `stream` when given.
fn first_turn(stream? : String) -> String {
  let stream = match stream {
    Some(stream) => ",\"stream\":\{stream}"
    None => ""
  }
  "{\"model\":\"test-model\"\{stream},\"messages\":[{\"role\":\"user\",\"content\":\"Weather in Paris?\"}]}"
}

///|
test "a Stub's tool calls answer in the JSON reply's message after its text, with a call id the Stub's seed gives, and the finish_reason tool_calls" {
  let h = harness([weather_mock])
  inspect(
    response(h.chat(body=first_turn())),
    content=(
      #|200
      #|Content-Type: application/json
      #|x-request-id: req_r2yjBtWWwsQd6LgmRvpu3TbN
      #|{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}],"refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
    ),
  )
}

///|
test "a stream sends the text's pieces, then the tool call's opening chunk and its argument pieces, with the ids of the JSON reply" {
  let h = harness([weather_mock])
  let outcome = h.chat(body=first_turn(stream="true"))
  guard outcome.plan.body is Events(events) else { fail("the JSON reply") }
  let lines = []
  for header in outcome.plan.headers {
    lines.push("\{header.0}: \{header.1}")
  }
  for event in events {
    let line = match (@json.parse(event.data) catch { _ => Json::null() }) {
      {
        "id": id,
        "choices": [{ "delta": delta, "finish_reason": reason, .. }],
        ..
      } => "\{id.stringify()} \{delta.stringify()} \{reason.stringify()}"
      _ => event.data
    }
    lines.push(line)
  }
  inspect(
    lines.join("\n"),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_r2yjBtWWwsQd6LgmRvpu3TbN
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"role":"assistant","content":""} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"content":"Let "} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"content":"me c"} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"content":"heck"} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"content":"."} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"tool_calls":[{"index":0,"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":""}}]} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"tool_calls":[{"index":0,"function":{"arguments":"ty\":"}}]} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"tool_calls":[{"index":0,"function":{"arguments":"\"Par"}}]} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]} null
      #|"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" {} "tool_calls"
      #|[DONE]
    ),
  )
}

///|
test "the next turn, whose last message is the tool's result, matches the Stub that answers it with text" {
  let h = harness([weather_mock])
  let next_turn =
    #|{"model":"test-model","messages":[
    #|  {"role":"user","content":"Weather in Paris?"},
    #|  {"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},
    #|  {"role":"tool","tool_call_id":"call_1","content":"18°C"}]}
  inspect(
    [
      "first turn: \{chosen(h.chat(body=first_turn()))}",
      "next turn: \{chosen(h.chat(body=next_turn))}",
    ].join("\n"),
    content=(
      #|first turn: ask-weather: Let me check. (model "test-model")
      #|next turn: answer-weather: It is 18°C in Paris. (model "test-model")
    ),
  )
}
