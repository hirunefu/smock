// Tests of the anthropic-messages wire form through the package's public
// interface: the JSON reply, its stop reasons, `stop_sequence`, a
// refusal's `stop_details`, the ids and the request-id header. They run on
// native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, for an
/// `anthropic-messages` declaration with `text`, the `usage` and the
/// `stop_reason` given, written as a word of the API, and ids drawn from the
/// generator of the draw `draw`: the Content-Type smock sets, the
/// request-id header field it adds, then the body.
fn messages(
  text : String,
  request~ : Json? = Some({ "model": "claude-test" }),
  draw~ : UInt64 = 7,
  usage? : @llm.Usage,
  stop_reason? : String,
  id? : String,
  model? : String,
) -> String {
  let stop_reason = stop_reason.map(word => {
    @llm.read_stop_reason(AnthropicMessages, Json::string(word)).unwrap()
  })
  let reply = @llm.reply(
    @llm.Declaration(api=AnthropicMessages, usage?, stop_reason?),
    @llm.Strings(text~, id?, model?),
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
  let (name, value) = reply.request_id
  "Content-Type: \{reply.content_type}\n\{name}: \{value}\n\{json_text(reply)}"
}

///|
test "an anthropic-messages reply is one message body, with the text in a text block, as the messages guide's Hello! reply" {
  inspect(
    messages("Hello!", usage=@llm.Usage(input=12, output=6)),
    content=(
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":6}}
    ),
  )
}

///|
test "a written stop reason goes in stop_reason, as the messages guide's max_tokens reply" {
  inspect(
    messages(
      "Hi! My name is Claude, an AI assistant",
      usage=@llm.Usage(input=10, output=10),
      stop_reason="max_tokens",
    ),
    content=(
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"text","text":"Hi! My name is Claude, an AI assistant"}],"model":"claude-test","stop_reason":"max_tokens","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":10}}
    ),
  )
}

///|
test "empty text gives an empty reply: content holds no block" {
  inspect(
    messages(""),
    content=(
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}
    ),
  )
}

///|
/// The member `name` of the JSON reply `reply`, as compact JSON, or
/// `missing` when it has none.
fn reply_member(reply : String, name : String) -> String {
  let body = reply[reply.find("\n{").unwrap() + 1:].to_owned()
  let value = @json.parse(body) catch { _ => return "not JSON" }
  match value {
    Object(members) => members.get(name).map_or("missing", v => v.stringify())
    _ => "not an object"
  }
}

///|
/// The stop members of the reply to `request` for a declaration with
/// `text` and the stop reason `written`, or a derived one: `stop_reason`,
/// `stop_sequence` and `stop_details`, the last one `missing` when left out.
fn stops(
  written? : String,
  text~ : String = "Hi",
  request~ : Json? = Some({ "stop_sequences": ["\n\nHuman:", "END"] }),
) -> String {
  let reply = messages(text, request~, stop_reason?=written)
  [
    reply_member(reply, "stop_reason"),
    reply_member(reply, "stop_sequence"),
    reply_member(reply, "stop_details"),
  ].join(" ")
}

///|
test "each stop reason is sent as written; left out, it is end_turn; stop_details comes with a refusal only" {
  inspect(
    [
      stops(),
      stops(written="end_turn"),
      stops(written="max_tokens"),
      stops(written="stop_sequence"),
      stops(written="tool_use"),
      stops(written="pause_turn"),
      stops(written="refusal"),
      stops(written="model_context_window_exceeded"),
    ].join("\n"),
    content=(
      #|"end_turn" null missing
      #|"end_turn" null missing
      #|"max_tokens" null missing
      #|"stop_sequence" "\n\nHuman:" missing
      #|"tool_use" null missing
      #|"pause_turn" null missing
      #|"refusal" null {"type":"refusal","category":null,"explanation":null}
      #|"model_context_window_exceeded" null missing
    ),
  )
}

///|
test "with stop_sequence, stop_sequence is the request's first stop sequence when it is a string, and null otherwise" {
  let echoed = (request : Json?) => stops(written="stop_sequence", request~)
  inspect(
    [
      echoed(Some({ "stop_sequences": ["END"] })),
      echoed(Some({ "stop_sequences": ["", "END"] })),
      echoed(Some({ "stop_sequences": ["\"quoted\", 天気\n"] })),
      echoed(Some({ "stop_sequences": [1, "END"] })),
      echoed(Some({ "stop_sequences": [Json::null(), "END"] })),
      echoed(Some({ "stop_sequences": [["END"]] })),
      echoed(Some({ "stop_sequences": [] })),
      echoed(Some({ "stop_sequences": "END" })),
      echoed(Some({ "stop_sequences": { "0": "END" } })),
      echoed(Some({ "stop": ["END"] })),
      echoed(Some(["END"])),
      echoed(None),
    ].join("\n"),
    content=(
      #|"stop_sequence" "END" missing
      #|"stop_sequence" "" missing
      #|"stop_sequence" "\"quoted\", 天気\n" missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
    ),
  )
}

///|
test "a refusal carries stop_details beside its text block, and no block when its text is empty" {
  inspect(
    [
      messages("I can't help with that.", stop_reason="refusal"),
      messages("", stop_reason="refusal"),
    ].join("\n"),
    content=(
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"text","text":"I can't help with that."}],"model":"claude-test","stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null},"usage":{"input_tokens":0,"output_tokens":0}}
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null},"usage":{"input_tokens":0,"output_tokens":0}}
    ),
  )
}

///|
test "usage gives input_tokens and output_tokens only, written exactly up to 2^53-1" {
  inspect(
    [
      reply_member(
        messages("Hi", usage=@llm.Usage(input=25, output=15)),
        "usage",
      ),
      reply_member(messages("Hi", usage=@llm.Usage(input=0, output=0)), "usage"),
      reply_member(
        messages(
          "Hi",
          usage=@llm.Usage(
            input=@llm.max_token_count,
            output=@llm.max_token_count,
          ),
        ),
        "usage",
      ),
    ].join("\n"),
    content=(
      #|{"input_tokens":25,"output_tokens":15}
      #|{"input_tokens":0,"output_tokens":0}
      #|{"input_tokens":9007199254740991,"output_tokens":9007199254740991}
    ),
  )
}

///|
test "the text is the text block's text, in UTF-8 as written and JSON-escaped" {
  let text = (text : String) => reply_member(messages(text), "content")
  inspect(
    [
      text("天気は晴れです。"),
      text("Done 👍🏽 🇫🇷, 𝄞 and 𠀋"),
      text("a \"quote\", a back\\slash,\na line break and a\ttab"),
    ].join("\n"),
    content=(
      #|[{"type":"text","text":"天気は晴れです。"}]
      #|[{"type":"text","text":"Done 👍🏽 🇫🇷, 𝄞 and 𠀋"}]
      #|[{"type":"text","text":"a \"quote\", a back\\slash,\na line break and a\ttab"}]
    ),
  )
}

///|
test "the model is the Stub's when given, otherwise the request's when it is a string, otherwise empty" {
  inspect(
    [
      reply_member(
        messages("Hi", request=Some({ "model": "claude-opus-9" })),
        "model",
      ),
      reply_member(
        messages(
          "Hi",
          request=Some({ "model": "claude-opus-9" }),
          model="claude-test-1",
        ),
        "model",
      ),
      reply_member(messages("Hi", request=Some({ "model": 4 })), "model"),
      reply_member(messages("Hi", request=None), "model"),
    ].join("\n"),
    content=(
      #|"claude-opus-9"
      #|"claude-test-1"
      #|""
      #|""
    ),
  )
}

///|
/// The request-id header field and the reply's id that `messages` shows in
/// `reply`, on one line.
fn ids_line(reply : String) -> String {
  let header = reply.split("\n").nth(1).unwrap()
  "\{header} \{reply_member(reply, "id")}"
}

///|
test "the reply's id is msg_ and the reply's slot, the request id request-id: req_ and the last slot" {
  for draw in 0UL..<50UL {
    let shown = ids_line(messages("Hi", draw~))
    let expected = "request-id: req_\{slot_id(draw, 2)} \"msg_\{slot_id(draw, 0)}\""
    guard shown == expected else { fail("draw \{draw}: \{shown}") }
  }
}

///|
test "id fixes the reply's id, sent as written, and the request id stays as it was" {
  inspect(
    [
      ids_line(messages("Hi")),
      ids_line(messages("Hi", id="msg_test_1")),
      ids_line(messages("Hi", id="a \"quoted\" id, 天気\n")),
      ids_line(messages("Hi", draw=8)),
    ].join("\n"),
    content=(
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk "msg_KCVauEuclT08Mg4CWd55sNbz"
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk "msg_test_1"
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk "a \"quoted\" id, 天気\n"
      #|request-id: req_23m4SYY5j0dNweGBYvVJCktv "msg_u76DvnZi1R3iOEH1RcaznueA"
    ),
  )
}

///|
test "the same declaration answers under openai-chat and anthropic-messages, its ids keeping their 24 characters" {
  let under = (api : @llm.Api) => {
    let reply = @llm.reply(
      @llm.Declaration(api~, usage=@llm.Usage(input=12, output=6)),
      @llm.Strings(text="Hello!"),
      request=Some({ "model": "test-model" }),
      now=received,
      ids=@llm.ids_generator(7),
    )
    let (name, value) = reply.request_id
    "\{api.name()}:\n\{name}: \{value}\n\{json_text(reply)}"
  }
  inspect(
    [under(OpenaiChat), under(AnthropicMessages)].join("\n"),
    content=(
      #|openai-chat:
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":6,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
      #|anthropic-messages:
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"test-model","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":6}}
    ),
  )
}
