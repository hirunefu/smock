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
