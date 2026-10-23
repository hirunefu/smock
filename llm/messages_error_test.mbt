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

///|
/// Each event of `reply`'s stream on a line of its own: its wait slot, its
/// name, then the piece of a text delta, the `index` of another
/// `content_block_*` event, or the `error` object of an error.
fn cut_stream(reply : @llm.Reply) -> String {
  let lines = []
  for event in stream_of(reply) {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let name = event.event.unwrap_or("(no event line)")
    let line = match data {
      { "delta": { "type": "text_delta", "text": String(piece), .. }, .. } =>
        "\{name} \{piece.escape()}"
      { "index": index, .. } => "\{name} \{index.stringify()}"
      { "type": "error", "error": error, .. } => "\{name} \{error.stringify()}"
      _ => name
    }
    lines.push("(\{slot(event.wait)}) \{line}")
  }
  lines.join("\n")
}

///|
test "an error at the end of the text follows every piece, with no content_block_stop, message_delta or message_stop" {
  inspect(
    cut_stream(
      messages_cut(
        @llm.Strings(text="Hello!", error_message="Overloaded"),
        after=6,
      ),
    ),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta "Hell"
      #|(interval) content_block_delta "o!"
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
    ),
  )
}

///|
test "an error before the tool calls follows the text, and no tool_use block is sent; with no text, it follows message_start" {
  inspect(
    [
      cut_stream(
        messages_cut(
          @llm.Strings(
            text="Let me check.",
            tool_calls=[weather()],
            error_message="Overloaded",
          ),
          after=13,
        ),
      ),
      cut_stream(
        messages_cut(
          @llm.Strings(
            tool_calls=[weather(), weather(id="toolu_2")],
            error_message="Overloaded",
          ),
          after=0,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta "Let "
      #|(interval) content_block_delta "me c"
      #|(interval) content_block_delta "heck"
      #|(interval) content_block_delta "."
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
      #|---
      #|(none) message_start
      #|(first) error {"type":"overloaded_error","message":"Overloaded"}
    ),
  )
}

///|
/// What anthropic-sdk-python reads of `reply`'s cut stream, or the first
/// rule it breaks: an `event:` line on every event equal to the `type` of
/// its data, which is one line of compact JSON, an integer `index` on every
/// `content_block_*` event, `message_start` first and the `error` last,
/// once, with no `content_block_stop`, `message_delta`, `message_stop` or
/// `ping`. Then the names of its events, in order.
fn error_checked(reply : @llm.Reply) -> String {
  let events = stream_of(reply)
  let names = []
  for i, event in events {
    guard event.event is Some(name) else { return "event \{i}: no event line" }
    let data = @json.parse(event.data) catch {
      _ => return "event \{i}: not JSON"
    }
    guard data is { "type": String(kind), .. } && kind == name else {
      return "event \{i}: event \{name}, data \{event.data}"
    }
    guard data.stringify() == event.data else {
      return "event \{i}: not compact"
    }
    if name.has_prefix("content_block_") &&
      !(data is { "index": Number(index, ..), .. } && index == index.floor()) {
      return "event \{i}: no integer index"
    }
    names.push(name)
  }
  guard names is ["message_start", .. middle, "error"] else {
    return "not from message_start to error"
  }
  for name in middle {
    guard name is ("content_block_start" | "content_block_delta") else {
      return "\{name} before the error"
    }
  }
  names.join(" ")
}

///|
test "every event of a cut stream has an event line equal to its type and one line of compact JSON, from message_start to the error" {
  let strings = @llm.Strings(
    text="a \"quote\",\na line break",
    error_message="Overloaded",
  )
  inspect(
    [
      error_checked(messages_cut(strings, after=0)),
      error_checked(messages_cut(strings, after=1)),
      error_checked(messages_cut(strings, after=5, chunk_size=1)),
      error_checked(messages_cut(strings, after=23)),
      error_checked(
        messages_cut(
          @llm.Strings(tool_calls=[weather()], error_message="Overloaded"),
          after=0,
        ),
      ),
      error_checked(
        messages_cut(
          @llm.Strings(
            chunks=["", "天気", "👍🏽"],
            tool_calls=[weather()],
            error_message="Overloaded",
          ),
          after=4,
        ),
      ),
    ].join("\n"),
    content=(
      #|message_start error
      #|message_start content_block_start content_block_delta error
      #|message_start content_block_start content_block_delta content_block_delta content_block_delta content_block_delta content_block_delta error
      #|message_start content_block_start content_block_delta content_block_delta content_block_delta content_block_delta content_block_delta content_block_delta error
      #|message_start error
      #|message_start content_block_start content_block_delta content_block_delta content_block_delta error
    ),
  )
}

///|
test "among explicit chunks an empty one counts 0 code points and is a delta of its own, and the cut is counted in code points, so it never splits one" {
  let chunks : ReadOnlyArray[String] = ["", "Hel", "", "lo", "", "!"]
  inspect(
    [
      cut_stream(
        messages_cut(@llm.Strings(chunks~, error_message="Overloaded"), after=4),
      ),
      cut_stream(
        messages_cut(
          @llm.Strings(text="👍🏽🇫🇷𝄞", error_message="Overloaded"),
          after=3,
          chunk_size=2,
        ),
      ),
      cut_stream(
        messages_cut(
          @llm.Strings(
            text="天気は晴れです。",
            error_message="Overloaded",
          ),
          after=4,
          chunk_size=3,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta ""
      #|(interval) content_block_delta "Hel"
      #|(interval) content_block_delta ""
      #|(interval) content_block_delta "l"
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
      #|---
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta "👍🏽"
      #|(interval) content_block_delta "🇫"
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
      #|---
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta "天気は"
      #|(interval) content_block_delta "晴"
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
    ),
  )
}

///|
test "past the end of the text, which only a templated text can be, the error follows the whole text, or message_start when the text is empty" {
  inspect(
    [
      cut_stream(
        messages_cut(
          @llm.Strings(text="Hi", error_message="Overloaded"),
          after=5,
        ),
      ),
      cut_stream(
        messages_cut(@llm.Strings(text="", error_message="Overloaded"), after=5),
      ),
      cut_stream(
        messages_cut(
          @llm.Strings(chunks=["", ""], error_message="Overloaded"),
          after=5,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0
      #|(first) content_block_delta "Hi"
      #|(interval) error {"type":"overloaded_error","message":"Overloaded"}
      #|---
      #|(none) message_start
      #|(first) error {"type":"overloaded_error","message":"Overloaded"}
      #|---
      #|(none) message_start
      #|(first) error {"type":"overloaded_error","message":"Overloaded"}
    ),
  )
}

///|
test "a request that does not stream gets the ordinary JSON reply, whole, with no error" {
  inspect(
    shown(
      messages_cut(
        @llm.Strings(text="Hello!", error_message="Overloaded"),
        after=2,
        request=Some({ "model": "claude-test" }),
      ),
    ),
    content=(
      #|Content-Type: application/json
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}
    ),
  )
}

///|
test "the message is sent as written, JSON-escaped, with the type" {
  inspect(
    event_data(
      messages_cut(
        @llm.Strings(text="Hi", error_message="Line 1\nsaid \"no\" é"),
        after=0,
        kind="rate_limit_error",
      ),
      "error",
    ),
    content=(
      #|{"type":"error","error":{"type":"rate_limit_error","message":"Line 1\nsaid \"no\" é"}}
    ),
  )
}
