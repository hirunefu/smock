// Tests of the anthropic-messages stream through the package's public
// interface: the reply to a request that sets `stream: true`, its named
// events, their order, the stop members of `message_delta`, the pieces and
// the wait slots. They run on native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one for
/// `claude-test` that sets `stream: true`, for an `anthropic-messages`
/// declaration with the strings `strings`, the `chunk_size`, `usage` and
/// `stop_reason` given, the last written as a word of the API, and ids drawn
/// from the generator of the draw 7.
fn messages_reply_to(
  strings : @llm.Strings,
  request~ : Json? = Some({ "model": "claude-test", "stream": true }),
  chunk_size? : Int32,
  usage? : @llm.Usage,
  stop_reason? : String,
) -> @llm.Reply {
  let stop_reason = stop_reason.map(word => {
    @llm.read_stop_reason(AnthropicMessages, Json::string(word)).unwrap()
  })
  @llm.reply(
    @llm.Declaration(api=AnthropicMessages, chunk_size?, usage?, stop_reason?),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
/// The stream of `messages_reply_to` for a declaration with `text`, as
/// `shown` shows it.
fn messages_stream(
  text : String,
  request~ : Json? = Some({ "model": "claude-test", "stream": true }),
  usage? : @llm.Usage,
  stop_reason? : String,
) -> String {
  shown(messages_reply_to(@llm.Strings(text~), request~, usage?, stop_reason?))
}

///|
test "a request with stream: true gets the text as named events: message_start, the text block's start, a delta per piece of 4 code points and its stop, then message_delta and message_stop" {
  inspect(
    messages_stream("Hello!", usage=@llm.Usage(input=25, output=15)),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":0}}}
      #|(none) event: content_block_start data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      #|(first) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hell"}}
      #|(interval) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"o!"}}
      #|(none) event: content_block_stop data: {"type":"content_block_stop","index":0}
      #|(none) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
    ),
  )
}

///|
test "an empty reply has no content_block_* event, and its message_delta takes the first wait slot" {
  inspect(
    messages_stream("", usage=@llm.Usage(input=25, output=0)),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":0}}}
      #|(first) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
    ),
  )
}

///|
/// The events of `reply`'s stream, or none for a JSON reply.
fn stream_of(reply : @llm.Reply) -> Array[@llm.Event] {
  match reply.body {
    Events(events) => events
    Json(_) => []
  }
}

///|
/// The data of the event named `name` in `reply`'s stream, or `missing`.
fn event_data(reply : @llm.Reply, name : String) -> String {
  for event in stream_of(reply) {
    if event.event == Some(name) {
      return event.data
    }
  }
  "missing"
}

///|
/// The `message_delta` of the stream of a declaration with `text` and the
/// stop reason `written`, or a derived one, to a request with `stream: true`
/// and the stop sequences `\n\nHuman:` and `END`, or `request`.
fn message_delta(
  written? : String,
  text~ : String = "Hi",
  request~ : Json = { "stream": true, "stop_sequences": ["\n\nHuman:", "END"] },
) -> String {
  event_data(
    messages_reply_to(
      @llm.Strings(text~),
      request=Some(request),
      stop_reason?=written,
    ),
    "message_delta",
  )
}

///|
test "message_delta gives each stop reason as written, end_turn when left out, and stop_details with a refusal only" {
  inspect(
    [
      message_delta(),
      message_delta(written="end_turn"),
      message_delta(written="max_tokens"),
      message_delta(written="stop_sequence"),
      message_delta(written="tool_use"),
      message_delta(written="pause_turn"),
      message_delta(written="refusal"),
      message_delta(written="refusal", text=""),
      message_delta(written="model_context_window_exceeded"),
    ].join("\n"),
    content=(
      #|{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"\n\nHuman:"},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"pause_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null}},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null}},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded","stop_sequence":null},"usage":{"output_tokens":0}}
    ),
  )
}

///|
test "a refusal with empty text streams no block, its stop_details in message_delta after the first wait slot" {
  inspect(
    shown(messages_reply_to(@llm.Strings(), stop_reason="refusal")),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(first) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null}},"usage":{"output_tokens":0}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
    ),
  )
}

///|
test "with stop_sequence, message_delta echoes the request's first stop sequence when it is a string, and null otherwise" {
  let echoed = (stop_sequences : Json) => {
    message_delta(written="stop_sequence", request={
      "stream": true,
      "stop_sequences": stop_sequences,
    })
  }
  inspect(
    [
      echoed(["END", "STOP"]),
      echoed(["\"quoted\", 天気\n"]),
      echoed([7, "END"]),
      echoed([]),
      echoed("END"),
      message_delta(written="stop_sequence", request={ "stream": true }),
    ].join("\n"),
    content=(
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"END"},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"\"quoted\", 天気\n"},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":null},"usage":{"output_tokens":0}}
      #|{"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":null},"usage":{"output_tokens":0}}
    ),
  )
}

///|
test "message_start gives the input tokens with output_tokens 0, and message_delta the output tokens, written exactly up to 2^53-1" {
  let counts = (usage : @llm.Usage) => {
    let reply = messages_reply_to(@llm.Strings(text="Hi"), usage~)
    let start = @json.parse(event_data(reply, "message_start")) catch {
      _ => return "not JSON"
    }
    let delta = @json.parse(event_data(reply, "message_delta")) catch {
      _ => return "not JSON"
    }
    guard start is { "message": { "usage": started, .. }, .. } &&
      delta is { "usage": ended, .. } else {
      return "no usage"
    }
    "\{started.stringify()} \{ended.stringify()}"
  }
  inspect(
    [
      counts(@llm.Usage(input=25, output=15)),
      counts(@llm.Usage(input=0, output=0)),
      counts(
        @llm.Usage(input=@llm.max_token_count, output=@llm.max_token_count),
      ),
    ].join("\n"),
    content=(
      #|{"input_tokens":25,"output_tokens":0} {"output_tokens":15}
      #|{"input_tokens":0,"output_tokens":0} {"output_tokens":0}
      #|{"input_tokens":9007199254740991,"output_tokens":0} {"output_tokens":9007199254740991}
    ),
  )
}

///|
/// The text pieces of `reply`'s stream, each with its wait slot: the text
/// of each `text_delta`, in order.
fn text_deltas(reply : @llm.Reply) -> String {
  let out = []
  for event in stream_of(reply) {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    if data
      is { "delta": { "type": "text_delta", "text": String(piece), .. }, .. } {
      out.push("(\{slot(event.wait)}) \{piece.escape()}")
    }
  }
  out.join(" ")
}

///|
/// The text deltas of the stream of a declaration with the strings
/// `strings` and the `chunk_size` given, as `text_deltas` shows them.
fn text_deltas_of(strings : @llm.Strings, chunk_size? : Int32) -> String {
  text_deltas(messages_reply_to(strings, chunk_size?))
}

///|
test "the text deltas carry the pieces: 4 code points by default, chunkSize of them, the text whole when the size is above its length, or the elements of chunks, an empty one included" {
  inspect(
    [
      text_deltas_of(@llm.Strings(text="Hello, Claude")),
      text_deltas_of(@llm.Strings(text="晴れです。"), chunk_size=1),
      text_deltas_of(
        @llm.Strings(text="Done 👍🏽 🇫🇷, 𝄞 and 𠀋"),
        chunk_size=3,
      ),
      text_deltas_of(@llm.Strings(text="Hello, Claude"), chunk_size=1_000_000),
      text_deltas_of(@llm.Strings(chunks=["Thumbs up: ", "", "👍", "🏽"])),
      text_deltas_of(@llm.Strings(chunks=["", "Hi", ""]), chunk_size=1),
    ].join("\n"),
    content=(
      #|(first) "Hell" (interval) "o, C" (interval) "laud" (interval) "e"
      #|(first) "晴" (interval) "れ" (interval) "で" (interval) "す" (interval) "。"
      #|(first) "Don" (interval) "e 👍" (interval) "🏽 🇫" (interval) "🇷, " (interval) "𝄞 a" (interval) "nd " (interval) "𠀋"
      #|(first) "Hello, Claude"
      #|(first) "Thumbs up: " (interval) "" (interval) "👍" (interval) "🏽"
      #|(first) "" (interval) "Hi" (interval) ""
    ),
  )
}

///|
test "the text deltas join to exactly the text, and so does the JSON reply's text block, whatever the chunk size" {
  let text = "Done 👍🏽 🇫🇷, 𝄞, 𠀋 and 天気は晴れです。\n\"quoted\""
  for size in [1, 2, 3, 4, 5, 7, 16, 1000] {
    let joined = StringBuilder()
    for
      event in stream_of(
        messages_reply_to(@llm.Strings(text~), chunk_size=size),
      ) {
      let data = @json.parse(event.data) catch { _ => Json::null() }
      if data is { "delta": { "text": String(piece), .. }, .. } {
        joined.write_string(piece)
      }
    }
    guard joined.to_string() == text else { fail("size \{size}: \{joined}") }
  }
  let json = messages_reply_to(@llm.Strings(text~), request=Some({}))
  inspect(
    reply_member("\n" + json_text(json), "content") ==
    Json::array([{ "type": "text", "text": Json::string(text) }]).stringify(),
    content="true",
  )
}

///|
test "chunks whose pieces are all empty give empty text: no block, as in the JSON reply" {
  inspect(
    [
      shown(messages_reply_to(@llm.Strings(chunks=[""]))),
      shown(messages_reply_to(@llm.Strings(chunks=["", ""]))),
    ].join("\n"),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(first) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
      #|Content-Type: text/event-stream
      #|request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(first) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
    ),
  )
}

///|
/// What anthropic-sdk-python checks of `reply`'s stream, or the first rule
/// it breaks: `message_start` first and `message_stop` last, an `event:`
/// line on every event equal to the `type` of its data, which is one line
/// of compact JSON, no `ping`, and an integer `index` on every
/// `content_block_*` event. Then the names of its events, in order.
fn checked(reply : @llm.Reply) -> String {
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
  guard names is ["message_start", .., "message_stop"] else {
    return "not from message_start to message_stop"
  }
  guard !names.contains("ping") else { return "a ping" }
  names.join(" ")
}

///|
test "every event has an event line equal to its type and one line of compact JSON, from message_start to message_stop, with no ping" {
  inspect(
    [
      checked(messages_reply_to(@llm.Strings(text="Hello!"))),
      checked(messages_reply_to(@llm.Strings(text="Hi"), chunk_size=1)),
      checked(messages_reply_to(@llm.Strings())),
      checked(
        messages_reply_to(
          @llm.Strings(text="a \"quote\",\na line break"),
          stop_reason="refusal",
        ),
      ),
      checked(
        messages_reply_to(
          @llm.Strings(chunks=["", "天気", "👍🏽"]),
          stop_reason="stop_sequence",
          request=Some({ "stream": true, "stop_sequences": ["\n"] }),
        ),
      ),
    ].join("\n"),
    content=(
      #|message_start content_block_start content_block_delta content_block_delta content_block_stop message_delta message_stop
      #|message_start content_block_start content_block_delta content_block_delta content_block_stop message_delta message_stop
      #|message_start message_delta message_stop
      #|message_start content_block_start content_block_delta content_block_delta content_block_delta content_block_delta content_block_delta content_block_delta content_block_stop message_delta message_stop
      #|message_start content_block_start content_block_delta content_block_delta content_block_delta content_block_stop message_delta message_stop
    ),
  )
}

///|
/// The message that anthropic-sdk-python's `messages.stream()` builds from
/// `reply`'s stream: the message of `message_start`, each block that
/// `content_block_start` opens, its text deltas appended at their `index`,
/// the `partial_json` pieces of a `tool_use` block joined and parsed into
/// its `input` when they are not empty, and the members of
/// `message_delta`'s delta and its output tokens. It fails where the SDK
/// raises ValueError: on pieces that do not join to JSON.
fn accumulated(reply : @llm.Reply) -> Json raise {
  let mut message : Map[String, Json] = Map([])
  let content : Array[Map[String, Json]] = []
  let partial_json : Array[String] = []
  for event in stream_of(reply) {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    match data {
      { "type": "message_start", "message": Object(start), .. } =>
        message = start
      { "type": "content_block_start", "content_block": Object(block), .. } => {
        content.push(block)
        partial_json.push("")
      }
      {
        "type": "content_block_delta",
        "index": Number(index, ..),
        "delta": { "type": "text_delta", "text": String(piece), .. },
        ..
      } => {
        let block = content[index.to_int()]
        guard block.get("text") is Some(String(text)) else { abort("no text") }
        block["text"] = Json::string(text + piece)
      }
      {
        "type": "content_block_delta",
        "index": Number(index, ..),
        "delta": {
          "type": "input_json_delta",
          "partial_json": String(piece),
          ..
        },
        ..
      } => {
        let i = index.to_int()
        partial_json[i] = partial_json[i] + piece
      }
      // The SDK parses the pieces so far after each one, as partial JSON;
      // once the block stops, they are whole.
      { "type": "content_block_stop", "index": Number(index, ..), .. } => {
        let i = index.to_int()
        if partial_json[i] != "" {
          content[i]["input"] = @json.parse(partial_json[i]) catch {
            _ => fail("ValueError: \{partial_json[i]}")
          }
        }
      }
      { "type": "message_delta", "delta": Object(delta), "usage": usage, .. } => {
        for name, value in delta {
          message[name] = value
        }
        guard message.get("usage") is Some(Object(counts)) &&
          usage is { "output_tokens": output, .. } else {
          abort("no usage")
        }
        counts["output_tokens"] = output
      }
      _ => ()
    }
  }
  message["content"] = Json::array(content.map(Json::object))
  Json::object(message)
}

///|
test "the message the SDK builds from the stream equals the JSON reply to the same request without stream, tool calls whose arguments are an object included" {
  let cases : Array[(@llm.Strings, String?, Json)] = [
    (@llm.Strings(text="Hello! How can I assist you today?"), None, {}),
    (@llm.Strings(), None, {}),
    (@llm.Strings(chunks=["Thumbs up: ", "", "👍", "🏽"]), None, {}),
    (@llm.Strings(text="I can't help with that."), Some("refusal"), {}),
    (@llm.Strings(), Some("refusal"), {}),
    (@llm.Strings(text="Hi", id="msg_test_1", model="claude-test-1"), None, {}),
    (
      @llm.Strings(text="1, 2, 3"),
      Some("stop_sequence"),
      { "stop_sequences": ["4", "END"] },
    ),
    (@llm.Strings(text="The weather in Paris is"), Some("max_tokens"), {}),
    (@llm.Strings(tool_calls=[weather()]), None, {}),
    (
      @llm.Strings(text="Let me check.", tool_calls=[
        weather(id="toolu_test_1"),
        @llm.ToolCall(name="search", arguments={
          "query": "天気 \"Paris\"\n",
          "limit": 10,
          "ratio": Json::number(0.5),
          "nested": { "z": [1, Json::null(), true], "a": {} },
        }),
        @llm.ToolCall(
          name="as_string",
          arguments="{ \"city\" : \"Paris\", \"days\": [1, 2.50] }",
        ),
        @llm.ToolCall(name="no_arguments", arguments={}),
      ]),
      None,
      {},
    ),
    (
      @llm.Strings(chunks=["", ""], tool_calls=[weather()]),
      Some("max_tokens"),
      {},
    ),
  ]
  for i, case in cases {
    let (strings, stop_reason, extra) = case
    let request = (stream : Bool) => {
      let members : Map[String, Json] = { "model": "claude-test" }
      if stream {
        members["stream"] = true
      }
      guard extra is Object(more) else { abort("not an object") }
      for name, value in more {
        members[name] = value
      }
      Some(Json::object(members))
    }
    let usage = @llm.Usage(input=31, output=5)
    let streamed = accumulated(
      messages_reply_to(strings, request=request(true), usage~, stop_reason?),
    )
    let json = messages_reply_to(
      strings,
      request=request(false),
      usage~,
      stop_reason?,
    )
    let parsed = @json.parse(json_text(json)) catch {
      _ => fail("case \{i}: not JSON")
    }
    guard streamed == parsed else {
      fail("case \{i}:\n\{streamed.stringify()}\n\{parsed.stringify()}")
    }
  }
}

///|
test "the stream carries the fixed id and model in message_start, and its request id in request-id" {
  inspect(
    [
      event_data(
        messages_reply_to(
          @llm.Strings(text="Hi", id="msg_test_1", model="claude-test-1"),
        ),
        "message_start",
      ),
      event_data(
        messages_reply_to(
          @llm.Strings(text="Hi"),
          request=Some({ "stream": true }),
        ),
        "message_start",
      ),
      messages_reply_to(@llm.Strings(text="Hi")).request_id.1,
    ].join("\n"),
    content=(
      #|{"type":"message_start","message":{"id":"msg_test_1","type":"message","role":"assistant","content":[],"model":"claude-test-1","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|{"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|req_5DTBZPrxiMH6i7M92iahxjWk
    ),
  )
}

///|
test "only a JSON object with stream exactly true gets the stream; any other request gets the JSON reply" {
  let form = (request : Json?) => {
    messages_reply_to(@llm.Strings(text="Hi"), request~).content_type
  }
  inspect(
    [
      "true: \{form(Some({ "stream": true }))}",
      "false: \{form(Some({ "stream": false }))}",
      "\"true\": \{form(Some({ "stream": "true" }))}",
      "missing: \{form(Some({ "model": "claude-test" }))}",
      "an array: \{form(Some([{ "stream": true }]))}",
      "not JSON: \{form(None)}",
    ].join("\n"),
    content=(
      #|true: text/event-stream
      #|false: application/json
      #|"true": application/json
      #|missing: application/json
      #|an array: application/json
      #|not JSON: application/json
    ),
  )
}
