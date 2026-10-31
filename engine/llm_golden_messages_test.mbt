// Goldens of `anthropic-messages`: examples of Anthropic's documentation,
// each compared with what smock sends for a Stub that declares the
// example's content (see llm_golden_test.mbt).
//
// Source: the pages of https://platform.claude.com/docs/en/ that each
// example names, read on 2026-10-23 as their Markdown exports (the page's
// URL followed by `.md`). Anthropic's documentation grants no licence, so
// each example is a short excerpt, used as test data only, and no longer
// than its comparison needs. It is not part of the smock binary, so NOTICE
// does not name it.

///|
/// A Mock `anthropic` with the one Stub `stub`, given as YAML lines that
/// start with `- id:`, each indented by two spaces.
fn anthropic_golden_mock(stub : String) -> (String, String) {
  (
    "anthropic.yaml",
    (
      #|mocks:
      #|  - name: anthropic
      #|    hosts: [api.anthropic.test]
      #|stubs:
      #|
    ) +
    stub,
  )
}

///|
/// The "Response" of "Basic streaming request" on
/// build-with-claude/streaming, copied unchanged: a text block in two
/// pieces, with a `ping` event after its start.
let anthropic_basic_stream_example : String =
  #|event: message_start
  #|data: {"type": "message_start", "message": {"id": "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}
  #|
  #|event: content_block_start
  #|data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
  #|
  #|event: ping
  #|data: {"type": "ping"}
  #|
  #|event: content_block_delta
  #|data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}
  #|
  #|event: content_block_delta
  #|data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}
  #|
  #|event: content_block_stop
  #|data: {"type": "content_block_stop", "index": 0}
  #|
  #|event: message_delta
  #|data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence":null}, "usage": {"output_tokens": 15}}
  #|
  #|event: message_stop
  #|data: {"type": "message_stop"}
  #|

///|
/// A Mock `anthropic` whose Stub `basic-stream` declares the basic stream's
/// content: its two pieces, its id, its model and its usage.
let anthropic_basic_stream_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: basic-stream
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY
    #|        model: claude-opus-5-5
    #|        chunks: [Hello, "!"]
    #|        usage: { input: 25, output: 15 }
  ),
)

///|
/// smock sends no `ping` event, and its `message_start` counts no output
/// token yet.
test "the Messages stream equals the streaming guide's basic stream, but for the ping event and output_tokens in message_start" {
  let h = harness([anthropic_basic_stream_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5-5\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":256,\"stream\":true}",
  )
  inspect(
    compare_golden(
      anthropic_basic_stream_example,
      outcome,
      differs=["/message/usage/output_tokens"],
      absent=["ping"],
    ),
    content=(
      #|same but for the listed differences
      #|listed: /message/usage/output_tokens: values differ
      #|listed: ping events: only in the example
    ),
  )
}

///|
/// The "Response" of "Streaming request with tool use" on
/// build-with-claude/streaming, shortened: its first four events and its
/// last ten are copied unchanged, and the comment between them, which is
/// not in the example, stands for the twelve text deltas left out. A text
/// block, with a `ping` event after its start, then a `tool_use` block
/// whose arguments come in an empty first piece and five more.
let anthropic_tool_use_stream_example : String =
  #|event: message_start
  #|data: {"type":"message_start","message":{"id":"msg_014p7gG3wDgGV9EUtLvnow3U","type":"message","role":"assistant","model":"claude-opus-5","stop_sequence":null,"usage":{"input_tokens":472,"output_tokens":2},"content":[],"stop_reason":null}}
  #|
  #|event: content_block_start
  #|data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
  #|
  #|event: ping
  #|data: {"type": "ping"}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}
  #|
  #|: twelve text deltas left out of this excerpt
  #|
  #|event: content_block_stop
  #|data: {"type":"content_block_stop","index":0}
  #|
  #|event: content_block_start
  #|data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"San"}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Francisc"}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o,"}}
  #|
  #|event: content_block_delta
  #|data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" CA\"}"}}
  #|
  #|event: content_block_stop
  #|data: {"type":"content_block_stop","index":1}
  #|
  #|event: message_delta
  #|data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}
  #|
  #|event: message_stop
  #|data: {"type":"message_stop"}

///|
/// A Mock `anthropic` whose Stub `tool-use-stream` declares the tool-use
/// stream's content: the thirteen pieces of its text, its tool call with
/// its id and its arguments as the pieces join, its id, its model and its
/// usage.
let anthropic_tool_use_stream_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: tool-use-stream
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_014p7gG3wDgGV9EUtLvnow3U
    #|        model: claude-opus-5
    #|        chunks: [Okay, ",", " let", "'s", " check", " the", " weather", " for", " San", " Francisco", ",", " CA", ":"]
    #|        toolCalls:
    #|          - id: toolu_01T1x1fJ34qAmk2tNTrN7Up6
    #|            name: get_weather
    #|            arguments: '{"location": "San Francisco, CA"}'
    #|        usage: { input: 472, output: 89 }
  ),
)

///|
/// The tool's arguments come in smock's pieces of 4 code points, compared
/// by their join after the empty first piece. smock sends no `ping` event,
/// and its `message_start` counts no output token yet.
test "the Messages stream with a tool call equals the streaming guide's tool-use stream, but for the ping event and output_tokens in message_start" {
  let h = harness([anthropic_tool_use_stream_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5\",\"max_tokens\":1024,\"tools\":[{\"name\":\"get_weather\",\"description\":\"Get the current weather in a given location\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}}],\"tool_choice\":{\"type\":\"any\"},\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather like in San Francisco?\"}],\"stream\":true}",
  )
  inspect(
    compare_golden(
      anthropic_tool_use_stream_example,
      outcome,
      differs=["/message/usage/output_tokens"],
      fragments=["/delta/partial_json"],
      absent=["ping"],
    ),
    content=(
      #|same but for the listed differences
      #|listed: /message/usage/output_tokens: values differ
      #|listed: ping events: only in the example
    ),
  )
}

///|
/// The "Output" of "Basic request and response" on
/// build-with-claude/working-with-messages, copied unchanged: the "Hello!"
/// reply.
let anthropic_hello_example : String =
  #|{
  #|  "id": "msg_01XFDUDYJgAACzvnptvVoYEL",
  #|  "type": "message",
  #|  "role": "assistant",
  #|  "content": [
  #|    {
  #|      "type": "text",
  #|      "text": "Hello!"
  #|    }
  #|  ],
  #|  "model": "claude-opus-5-5",
  #|  "stop_reason": "end_turn",
  #|  "stop_sequence": null,
  #|  "usage": {
  #|    "input_tokens": 12,
  #|    "output_tokens": 6
  #|  }
  #|}

///|
/// A Mock `anthropic` whose Stub `hello` declares the "Hello!" reply's
/// content: its text, its id, its model and its usage.
let anthropic_hello_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: hello
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_01XFDUDYJgAACzvnptvVoYEL
    #|        model: claude-opus-5-5
    #|        text: Hello!
    #|        usage: { input: 12, output: 6 }
  ),
)

///|
/// Nothing differs.
test "the Messages JSON reply equals the messages guide's Hello! reply" {
  let h = harness([anthropic_hello_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5-5\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":\"Hello, Claude\"}]}",
  )
  inspect(
    compare_golden(anthropic_hello_example, outcome),
    content=(
      #|same
    ),
  )
}

///|
/// The "Output" of "Prefilling Claude's response" on
/// build-with-claude/working-with-messages, copied unchanged: a reply cut
/// by `max_tokens`.
let anthropic_max_tokens_example : String =
  #|{
  #|  "id": "msg_01Q8Faay6S7QPTvEUUQARt7h",
  #|  "type": "message",
  #|  "role": "assistant",
  #|  "content": [
  #|    {
  #|      "type": "text",
  #|      "text": "C"
  #|    }
  #|  ],
  #|  "model": "claude-sonnet-4-5",
  #|  "stop_reason": "max_tokens",
  #|  "stop_sequence": null,
  #|  "usage": {
  #|    "input_tokens": 42,
  #|    "output_tokens": 1
  #|  }
  #|}

///|
/// A Mock `anthropic` whose Stub `max-tokens` declares the `max_tokens`
/// reply's content: its text, its stop reason, its id, its model and its
/// usage.
let anthropic_max_tokens_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: max-tokens
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_01Q8Faay6S7QPTvEUUQARt7h
    #|        model: claude-sonnet-4-5
    #|        text: C
    #|        stopReason: max_tokens
    #|        usage: { input: 42, output: 1 }
  ),
)

///|
/// Nothing differs.
test "the Messages JSON reply with the stop reason max_tokens equals the messages guide's max_tokens reply" {
  let h = harness([anthropic_max_tokens_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"What is latin for Ant? (A) Apoidea, (B) Rhopalocera, (C) Formicidae\"},{\"role\":\"assistant\",\"content\":\"The answer is (\"}]}",
  )
  inspect(
    compare_golden(anthropic_max_tokens_example, outcome),
    content=(
      #|same
    ),
  )
}

///|
/// The "Example API response with a `tool_use` content block" of "Handling
/// results from client tools" on agents-and-tools/tool-use/handle-tool-calls,
/// copied unchanged but for the indent of the page's accordion: a text block
/// and a `tool_use` block. It shows only some of the reply's members.
let anthropic_tool_use_example : String =
  #|{
  #|  "id": "msg_01Aq9w938a90dw8q",
  #|  "model": "claude-opus-5-5",
  #|  "stop_reason": "tool_use",
  #|  "role": "assistant",
  #|  "content": [
  #|    {
  #|      "type": "text",
  #|      "text": "I'll check the current weather in San Francisco for you."
  #|    },
  #|    {
  #|      "type": "tool_use",
  #|      "id": "toolu_01A09q90qw90lq917835lq9",
  #|      "name": "get_weather",
  #|      "input": { "location": "San Francisco, CA", "unit": "celsius" }
  #|    }
  #|  ]
  #|}

///|
/// A Mock `anthropic` whose Stub `tool-use` declares the tool-use reply's
/// content: its text, its tool call with its id and its arguments, its id
/// and its model. The example shows no usage.
let anthropic_tool_use_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: tool-use
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_01Aq9w938a90dw8q
    #|        model: claude-opus-5-5
    #|        text: "I'll check the current weather in San Francisco for you."
    #|        toolCalls:
    #|          - id: toolu_01A09q90qw90lq917835lq9
    #|            name: get_weather
    #|            arguments: { location: "San Francisco, CA", unit: celsius }
  ),
)

///|
/// The reply is compared on the members the example shows. smock writes
/// every Messages reply with the members of the messages guide's replies,
/// so it also sends `type`, `stop_sequence` and `usage`.
test "the Messages JSON reply with a tool call equals the tool-use guide's reply on the members it shows" {
  let h = harness([anthropic_tool_use_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5-5\",\"max_tokens\":1024,\"tools\":[{\"name\":\"get_weather\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"},\"unit\":{\"type\":\"string\"}},\"required\":[\"location\"]}}],\"messages\":[{\"role\":\"user\",\"content\":\"What's the weather like in San Francisco?\"}]}",
  )
  inspect(
    compare_golden(anthropic_tool_use_example, outcome, differs=[
      "/type", "/stop_sequence", "/usage",
    ]),
    content=(
      #|same but for the listed differences
      #|listed: /type: only in smock's
      #|listed: /stop_sequence: only in smock's
      #|listed: /usage: only in smock's
    ),
  )
}

///|
/// The "Example error" of "Error events" on build-with-claude/streaming,
/// copied unchanged: the one `error` event of a stream.
let anthropic_error_example : String =
  #|event: error
  #|data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}

///|
/// A Mock `anthropic` whose Stub `error` declares the error event's
/// content: an `overloaded_error` with its message, at once.
let anthropic_error_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: error
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        error: { after: 0, type: overloaded_error, message: Overloaded }
  ),
)

///|
/// The example shows the error event alone, so a gap before it stands for
/// the events smock sends first, its `message_start`. Nothing differs.
test "the Messages mid-stream error equals the streaming guide's error event" {
  let h = harness([anthropic_error_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5-5\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":256,\"stream\":true}",
  )
  inspect(
    compare_golden(
      ": the events before the error, which the example leaves out\n\n" +
      anthropic_error_example,
      outcome,
    ),
    content=(
      #|same
    ),
  )
}

///|
/// The reply of "What a refusal looks like" on
/// build-with-claude/refusals-and-fallback, copied unchanged: a refusal
/// with no block, whose `stop_details` names its category.
let anthropic_refusal_example : String =
  #|{
  #|  "id": "msg_01XFUDYJgAACzvnptvVoYEL",
  #|  "type": "message",
  #|  "role": "assistant",
  #|  "model": "claude-fable-5",
  #|  "content": [],
  #|  "stop_reason": "refusal",
  #|  "stop_details": {
  #|    "type": "refusal",
  #|    "category": "cyber",
  #|    "explanation": "This request was declined because it could enable cyber harm."
  #|  },
  #|  "usage": {
  #|    "input_tokens": 412,
  #|    "output_tokens": 0
  #|  }
  #|}

///|
/// A Mock `anthropic` whose Stub `refusal` declares the refusal's content:
/// no text, its stop reason, its id, its model and its usage.
let anthropic_refusal_stub : (String, String) = anthropic_golden_mock(
  (
    #|  - id: refusal
    #|    mock: anthropic
    #|    request: { method: POST, path: /v1/messages }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: anthropic-messages
    #|        id: msg_01XFUDYJgAACzvnptvVoYEL
    #|        model: claude-fable-5
    #|        stopReason: refusal
    #|        usage: { input: 412, output: 0 }
  ),
)

///|
/// smock writes a refusal's `category` and `explanation` as null, a value
/// the page documents, since no Stub field names them; and it writes
/// `stop_sequence`, null, as in every Messages reply, where the example
/// leaves it out.
test "the Messages JSON reply with the stop reason refusal equals the refusals page's reply, but for category, explanation and stop_sequence" {
  let h = harness([anthropic_refusal_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-fable-5\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":\"Hello, Claude\"}]}",
  )
  inspect(
    compare_golden(anthropic_refusal_example, outcome, differs=[
      "/stop_details/category", "/stop_details/explanation", "/stop_sequence",
    ]),
    content=(
      #|same but for the listed differences
      #|listed: /stop_details/category: values differ
      #|listed: /stop_details/explanation: values differ
      #|listed: /stop_sequence: only in smock's
    ),
  )
}
