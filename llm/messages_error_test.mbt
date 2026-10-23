// Tests of the mid-stream error of an anthropic-messages reply through the
// package's public interface: where the stream is cut, the `error` event
// and its wait slot, and the ordinary reply to a request that does not
// stream. They run on native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one for
/// `claude-test` that sets `stream: true`, for an `anthropic-messages`
/// declaration whose mid-stream error comes after `after` code points, with
/// the type `kind`, and whose strings are `strings`, with the chunk size
/// given.
fn messages_cut(
  strings : @llm.Strings,
  after~ : Int,
  kind? : String = "overloaded_error",
  request? : Json? = Some({ "model": "claude-test", "stream": true }),
  chunk_size? : Int,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(
      api=AnthropicMessages,
      chunk_size?,
      error=@llm.MidStreamError(after~, kind~),
    ),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
test "an error after 0 code points follows message_start as event: error, in the first wait slot, with no content_block_* event and no message_delta or message_stop" {
  inspect(
    shown(
      messages_cut(
        @llm.Strings(text="Hello!", error_message="Overloaded"),
        after=0,
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(first) event: error data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      #|
    ),
  )
}

///|
test "an error inside a piece opens the text block and sends the text up to exactly after code points, the piece that holds the cut ending there, then waits as a next piece would" {
  inspect(
    shown(
      messages_cut(
        @llm.Strings(
          text="Hello! How can I assist you today?",
          error_message="Overloaded",
        ),
        after=6,
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(none) event: content_block_start data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      #|(first) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hell"}}
      #|(interval) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"o!"}}
      #|(interval) event: error data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      #|
    ),
  )
}
