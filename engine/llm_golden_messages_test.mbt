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
