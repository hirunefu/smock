// Tests of an anthropic-messages reply's tool calls through the package's
// public interface: the JSON reply's `tool_use` blocks and their `input`,
// the stream's `tool_use` blocks with their `input_json_delta` pieces,
// their `toolu_` ids and the stop reason they derive. They run on native
// and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one for
/// `claude-test` without `stream`, for an `anthropic-messages` declaration
/// with the strings `strings` and the chunk size and stop reason given, the
/// last written as a word of the API, and ids drawn from the generator of
/// the draw `draw`.
fn messages_calls_reply(
  strings : @llm.Strings,
  request~ : Json? = Some({ "model": "claude-test" }),
  chunk_size? : Int32,
  stop_reason? : String,
  draw~ : UInt64 = 7,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(
      api=AnthropicMessages,
      chunk_size?,
      stop_reason?=stop_reason.map(word => {
        @llm.read_stop_reason(AnthropicMessages, Json::string(word)).unwrap()
      }),
    ),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
}

///|
/// The request of `messages_calls_reply` with `stream: true`.
let messages_streamed : Json? = Some({ "model": "claude-test", "stream": true })

///|
test "a JSON reply with tool calls and no text has a tool_use block per call and no text block, with a toolu_ id, the input object, and the stop reason tool_use" {
  inspect(
    shown(messages_calls_reply(@llm.Strings(tool_calls=[weather()]))),
    content=(
      #|Content-Type: application/json
      #|request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","input":{"city":"Paris"}}],"model":"claude-test","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}
    ),
  )
}

///|
/// The tool calls of the tests below: arguments as an object, as a string
/// that holds a JSON object, as a string that holds another JSON value, and
/// as broken JSON, empty and not JSON at all.
let mixed_calls : ReadOnlyArray[@llm.ToolCall] = [
  weather(),
  @llm.ToolCall(name="search", arguments={
    "query": "天気 \"Paris\"\n",
    "limit": 10,
    "ratio": Json::number(0.5),
    "tags": ["a", Json::null(), true],
    "nested": { "z": 1, "a": {} },
  }),
  @llm.ToolCall(
    name="as_string",
    arguments="{ \"city\" : \"Paris\", \"days\": [1, 2.50] }",
  ),
  @llm.ToolCall(name="a_list", arguments="[1, 2]"),
  @llm.ToolCall(name="a_number", arguments="42"),
  @llm.ToolCall(name="a_string", arguments="\"Paris\""),
  @llm.ToolCall(name="broken", arguments="{\"city\": \"Par"),
  @llm.ToolCall(name="empty", arguments=""),
  @llm.ToolCall(name="not_json", arguments="not JSON at all"),
  @llm.ToolCall(name="no_arguments", arguments={}),
]

///|
/// The members of the JSON reply `reply` other than its content, then each
/// block of its content on a line of its own, as compact JSON.
fn blocks_of(reply : @llm.Reply) -> String {
  let body = @json.parse(json_text(reply)) catch {
    e => abort("not JSON: \{e}")
  }
  guard body is { "content": Array(blocks), "stop_reason": reason, .. } else {
    abort("no content")
  }
  let lines = ["stop_reason: \{reason.stringify()}"]
  for block in blocks {
    lines.push(block.stringify())
  }
  lines.join("\n")
}

///|
test "text comes first, in its text block, then a tool_use block per call in the order written: an object is the input, a string that holds a JSON object is that object, and any other string is a JSON string" {
  inspect(
    blocks_of(
      messages_calls_reply(
        @llm.Strings(text="Let me check.", tool_calls=mixed_calls),
      ),
    ),
    content=(
      #|stop_reason: "tool_use"
      #|{"type":"text","text":"Let me check."}
      #|{"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","input":{"city":"Paris"}}
      #|{"type":"tool_use","id":"toolu_DbhbAGir3qs3o77JKr2BTN9j","name":"search","input":{"query":"天気 \"Paris\"\n","limit":10,"ratio":0.5,"tags":["a",null,true],"nested":{"z":1,"a":{}}}}
      #|{"type":"tool_use","id":"toolu_NCf4tMSwK04LkjFxZfMyVls1","name":"as_string","input":{"city":"Paris","days":[1,2.5]}}
      #|{"type":"tool_use","id":"toolu_a0lxsrqPBmPj21seI0h9c0KO","name":"a_list","input":"[1, 2]"}
      #|{"type":"tool_use","id":"toolu_H5mcAqiERyhvYhfaZeN3ojuN","name":"a_number","input":"42"}
      #|{"type":"tool_use","id":"toolu_Y15CN9aWeKk9HCJUdv6fHaZI","name":"a_string","input":"\"Paris\""}
      #|{"type":"tool_use","id":"toolu_EdgebdM26s8jpykAg7gfZg9G","name":"broken","input":"{\"city\": \"Par"}
      #|{"type":"tool_use","id":"toolu_nVmMw768IjFXSeWDg1vkIUmC","name":"empty","input":""}
      #|{"type":"tool_use","id":"toolu_3PvnW2wmwDiJKnU6mgP81Sdp","name":"not_json","input":"not JSON at all"}
      #|{"type":"tool_use","id":"toolu_94UevmVZIsdbF2evo7qyksTD","name":"no_arguments","input":{}}
    ),
  )
}

///|
test "a stream with tool calls and no text has no text block: each call is a tool_use block that starts with input {}, then an empty partial_json and one input_json_delta per piece of its arguments" {
  inspect(
    shown(
      messages_calls_reply(
        @llm.Strings(tool_calls=[weather()]),
        request=messages_streamed,
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|(none) event: message_start data: {"type":"message_start","message":{"id":"msg_KCVauEuclT08Mg4CWd55sNbz","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|(none) event: content_block_start data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","input":{}}}
      #|(none) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""}}
      #|(first) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"ci"}}
      #|(interval) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ty\":"}}
      #|(interval) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"Par"}}
      #|(interval) event: content_block_delta data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"is\"}"}}
      #|(none) event: content_block_stop data: {"type":"content_block_stop","index":0}
      #|(none) event: message_delta data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":0}}
      #|(none) event: message_stop data: {"type":"message_stop"}
      #|
    ),
  )
}

///|
/// Each event of `reply`'s stream on a line of its own: its wait slot, its
/// name, then its `index` and its content block or delta for a
/// `content_block_*` event, or its stop reason for `message_delta`.
fn block_events(reply : @llm.Reply) -> String {
  let lines = []
  for event in stream_of(reply) {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let name = event.event.unwrap_or("(no event line)")
    let line = match data {
      { "index": index, "content_block": block, .. } =>
        "\{name} \{index.stringify()} \{block.stringify()}"
      { "index": index, "delta": delta, .. } =>
        "\{name} \{index.stringify()} \{delta.stringify()}"
      { "index": index, .. } => "\{name} \{index.stringify()}"
      { "delta": { "stop_reason": reason, .. }, .. } =>
        "\{name} \{reason.stringify()}"
      _ => name
    }
    lines.push("(\{slot(event.wait)}) \{line}")
  }
  lines.join("\n")
}

///|
test "text and several tool calls: the text block at index 0, then each call's tool_use block at the next index, its arguments cut with the text's chunk size, every piece taking a wait slot" {
  inspect(
    block_events(
      messages_calls_reply(
        @llm.Strings(text="Let me check.", tool_calls=[
          weather(),
          @llm.ToolCall(name="get_time", arguments={ "zone": "CET" }),
          @llm.ToolCall(name="broken", arguments="{\"a\":"),
        ]),
        request=messages_streamed,
        chunk_size=6,
      ),
    ),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0 {"type":"text","text":""}
      #|(first) content_block_delta 0 {"type":"text_delta","text":"Let me"}
      #|(interval) content_block_delta 0 {"type":"text_delta","text":" check"}
      #|(interval) content_block_delta 0 {"type":"text_delta","text":"."}
      #|(none) content_block_stop 0
      #|(none) content_block_start 1 {"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","input":{}}
      #|(none) content_block_delta 1 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 1 {"type":"input_json_delta","partial_json":"{\"city"}
      #|(interval) content_block_delta 1 {"type":"input_json_delta","partial_json":"\":\"Par"}
      #|(interval) content_block_delta 1 {"type":"input_json_delta","partial_json":"is\"}"}
      #|(none) content_block_stop 1
      #|(none) content_block_start 2 {"type":"tool_use","id":"toolu_DbhbAGir3qs3o77JKr2BTN9j","name":"get_time","input":{}}
      #|(none) content_block_delta 2 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 2 {"type":"input_json_delta","partial_json":"{\"zone"}
      #|(interval) content_block_delta 2 {"type":"input_json_delta","partial_json":"\":\"CET"}
      #|(interval) content_block_delta 2 {"type":"input_json_delta","partial_json":"\"}"}
      #|(none) content_block_stop 2
      #|(none) content_block_start 3 {"type":"tool_use","id":"toolu_NCf4tMSwK04LkjFxZfMyVls1","name":"broken","input":{}}
      #|(none) content_block_delta 3 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 3 {"type":"input_json_delta","partial_json":"{\"a\":"}
      #|(none) content_block_stop 3
      #|(none) message_delta "tool_use"
      #|(none) message_stop
    ),
  )
}

///|
test "with tool calls, empty text has no text block even when chunks gives empty pieces; empty arguments send the empty first partial_json alone, and a reply with no piece waits before message_delta" {
  let silent = @llm.ToolCall(name="ping", arguments="")
  inspect(
    [
      block_events(
        messages_calls_reply(
          @llm.Strings(chunks=["", ""], tool_calls=[silent]),
          request=messages_streamed,
        ),
      ),
      block_events(
        messages_calls_reply(
          @llm.Strings(tool_calls=[silent, weather()]),
          request=messages_streamed,
          chunk_size=100,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0 {"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"ping","input":{}}
      #|(none) content_block_delta 0 {"type":"input_json_delta","partial_json":""}
      #|(none) content_block_stop 0
      #|(first) message_delta "tool_use"
      #|(none) message_stop
      #|---
      #|(none) message_start
      #|(none) content_block_start 0 {"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"ping","input":{}}
      #|(none) content_block_delta 0 {"type":"input_json_delta","partial_json":""}
      #|(none) content_block_stop 0
      #|(none) content_block_start 1 {"type":"tool_use","id":"toolu_DbhbAGir3qs3o77JKr2BTN9j","name":"get_weather","input":{}}
      #|(none) content_block_delta 1 {"type":"input_json_delta","partial_json":""}
      #|(first) content_block_delta 1 {"type":"input_json_delta","partial_json":"{\"city\":\"Paris\"}"}
      #|(none) content_block_stop 1
      #|(none) message_delta "tool_use"
      #|(none) message_stop
    ),
  )
}

///|
test "each tool_use block opens with an empty partial_json, its later pieces join to exactly its arguments, and every event keeps the SDK's checks, whatever the chunk size" {
  let expected = []
  for call in mixed_calls {
    expected.push(call.arguments)
  }
  for size in [1, 2, 3, 4, 7, 1000] {
    let reply = messages_calls_reply(
      @llm.Strings(text="Hi", tool_calls=mixed_calls),
      request=messages_streamed,
      chunk_size=size,
    )
    let names = checked(reply)
    guard !names.has_prefix("event ") && names.has_prefix("message_start") else {
      fail("size \{size}: \{names}")
    }
    // The text block is at index 0, so call k is at index k + 1.
    let joined = Array::make(mixed_calls.length(), "")
    let deltas = Array::make(mixed_calls.length(), 0)
    let stopped = Array::make(mixed_calls.length(), false)
    for event in stream_of(reply) {
      let data = @json.parse(event.data) catch { _ => fail("not JSON") }
      match data {
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
          let k = index.to_int() - 1
          guard !stopped[k] else {
            fail("size \{size}: a piece after the stop")
          }
          if deltas[k] == 0 {
            guard piece == "" else {
              fail("size \{size}: call \{k} opens with \{piece}")
            }
          } else {
            joined[k] = joined[k] + piece
          }
          deltas[k] += 1
        }
        { "type": "content_block_stop", "index": Number(index, ..), .. } if index >
          0.0 => stopped[index.to_int() - 1] = true
        _ => ()
      }
    }
    guard joined == expected &&
      deltas.iter().all(n => n >= 1) &&
      stopped.iter().all(stop => stop) else {
      fail("size \{size}: \{@debug.to_string(joined)}")
    }
  }
}

///|
/// The ids of the JSON reply and of the stream of an `anthropic-messages`
/// declaration with `tool_calls`, with ids drawn from the generator of the
/// draw `draw`: the request id, the reply's id, then each `tool_use` id,
/// from the JSON reply's blocks and from the stream's `message_start` and
/// `content_block_start` events, which must agree.
fn tool_use_ids(
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  draw : UInt64,
) -> Array[String] {
  let found = []
  let requests : Array[Json?] = [
    Some({ "model": "claude-test" }),
    messages_streamed,
  ]
  for request in requests {
    let reply = messages_calls_reply(
      @llm.Strings(text="Hi", tool_calls~),
      request~,
      draw~,
    )
    let ids = [reply.request_id.1]
    match reply.body {
      Json(body) => {
        let body = @json.parse(@utf8.decode_lossy(body)) catch {
          _ => abort("not JSON")
        }
        guard body is { "id": String(id), "content": Array(blocks), .. } else {
          abort("no content")
        }
        ids.push(id)
        for block in blocks {
          if block is { "type": "tool_use", "id": String(id), .. } {
            ids.push(id)
          }
        }
      }
      Events(events) =>
        for event in events {
          let data = @json.parse(event.data) catch { _ => continue }
          match data {
            { "message": { "id": String(id), .. }, .. } => ids.push(id)
            {
              "content_block": { "type": "tool_use", "id": String(id), .. },
              ..
            } => ids.push(id)
            _ => ()
          }
        }
    }
    found.push(ids)
  }
  guard found[0] == found[1] else {
    abort(
      "the JSON reply's ids \{@debug.to_string(found[0])} and the stream's \{@debug.to_string(found[1])}",
    )
  }
  found[0]
}

///|
test "a tool_use id is toolu_ and the 24 characters of the call id openai-chat sends for the same declaration and draw, and the reply's id and the request id keep theirs" {
  for draw in 0UL..<50UL {
    for n in 0..<4 {
      let tool_calls = ReadOnlyArray::from_array(
        Array::makei(n, _ => weather()),
      )
      let chat = ids_of(tool_calls, draw)
      let expected = [
        chat[0],
        "msg_" + chat[1].strip_prefix("chatcmpl-").unwrap().to_owned(),
      ]
      for id in chat[2:] {
        expected.push("toolu_" + id.strip_prefix("call_").unwrap().to_owned())
      }
      let ids = tool_use_ids(tool_calls, draw)
      guard ids == expected else {
        fail(
          "draw \{draw}, \{n} tool calls: \{@debug.to_string(ids)}, not \{@debug.to_string(expected)}",
        )
      }
    }
  }
}

///|
test "a tool call's id fixes its tool_use id, sent as written, every other id stays as it was, and the ids of one reply are distinct" {
  inspect(
    [
      tool_use_ids([weather(), weather(), weather()], 7).join("\n"),
      tool_use_ids([weather(), weather(id="toolu_test_1"), weather()], 7).join(
        "\n",
      ),
    ].join("\n---\n"),
    content=(
      #|req_RESVurpTQO6pgD32uiBlPjw0
      #|msg_KCVauEuclT08Mg4CWd55sNbz
      #|toolu_iHzkHTRdWXnW746KnN1UOBYQ
      #|toolu_DbhbAGir3qs3o77JKr2BTN9j
      #|toolu_NCf4tMSwK04LkjFxZfMyVls1
      #|---
      #|req_RESVurpTQO6pgD32uiBlPjw0
      #|msg_KCVauEuclT08Mg4CWd55sNbz
      #|toolu_iHzkHTRdWXnW746KnN1UOBYQ
      #|toolu_test_1
      #|toolu_NCf4tMSwK04LkjFxZfMyVls1
    ),
  )
  let five : ReadOnlyArray[@llm.ToolCall] = [
    weather(),
    weather(),
    weather(),
    weather(),
    weather(),
  ]
  for draw in 0UL..<200UL {
    let calls = tool_use_ids(five, draw)[2:]
    for i in 0..<calls.length() {
      for j in 0..<i {
        guard calls[i] != calls[j] else {
          fail("draw \{draw}: \{calls[i]} twice")
        }
      }
    }
  }
}

///|
test "left out, the stop reason of a reply with tool calls is derived as tool_use, with text or without, in both forms; a written word stays, whatever the content" {
  let stop_of = (text : String, stop_reason : String?, form : Json?) => {
    let reply = messages_calls_reply(
      @llm.Strings(text~, tool_calls=[weather()]),
      request=form,
      stop_reason?,
    )
    let data = match reply.body {
      Json(_) => json_text(reply)
      Events(_) => event_data(reply, "message_delta")
    }
    let value = @json.parse(data) catch { _ => return "not JSON" }
    match value {
      { "delta": delta, .. } => delta.stringify()
      { "stop_reason": reason, "stop_sequence": sequence, .. } as body =>
        match body {
          { "stop_details": details, .. } =>
            "\{reason.stringify()} \{sequence.stringify()} \{details.stringify()}"
          _ => "\{reason.stringify()} \{sequence.stringify()}"
        }
      _ => "no stop reason"
    }
  }
  let lines = []
  for
    case in [
      ("Let me check.", None),
      ("", None),
      ("Let me check.", Some("end_turn")),
      ("", Some("max_tokens")),
      ("Let me check.", Some("refusal")),
      ("", Some("tool_use")),
    ] {
    let (text, written) = case
    lines.push(
      "\{written.unwrap_or("left out")}, text \{text.escape()}: JSON \{stop_of(text, written, Some({}))}, stream \{stop_of(text, written, messages_streamed)}",
    )
  }
  inspect(
    lines.join("\n"),
    content=(
      #|left out, text "Let me check.": JSON "tool_use" null, stream {"stop_reason":"tool_use","stop_sequence":null}
      #|left out, text "": JSON "tool_use" null, stream {"stop_reason":"tool_use","stop_sequence":null}
      #|end_turn, text "Let me check.": JSON "end_turn" null, stream {"stop_reason":"end_turn","stop_sequence":null}
      #|max_tokens, text "": JSON "max_tokens" null, stream {"stop_reason":"max_tokens","stop_sequence":null}
      #|refusal, text "Let me check.": JSON "refusal" null {"type":"refusal","category":null,"explanation":null}, stream {"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null}}
      #|tool_use, text "": JSON "tool_use" null, stream {"stop_reason":"tool_use","stop_sequence":null}
    ),
  )
}

///|
test "in a stream, a string is sent as written in partial_json, whatever it holds, so broken JSON reaches readers of raw events as it is" {
  inspect(
    block_events(
      messages_calls_reply(
        @llm.Strings(tool_calls=[
          mixed_calls[2],
          mixed_calls[3],
          mixed_calls[6],
          mixed_calls[8],
        ]),
        request=messages_streamed,
        chunk_size=1000,
      ),
    ),
    content=(
      #|(none) message_start
      #|(none) content_block_start 0 {"type":"tool_use","id":"toolu_iHzkHTRdWXnW746KnN1UOBYQ","name":"as_string","input":{}}
      #|(none) content_block_delta 0 {"type":"input_json_delta","partial_json":""}
      #|(first) content_block_delta 0 {"type":"input_json_delta","partial_json":"{ \"city\" : \"Paris\", \"days\": [1, 2.50] }"}
      #|(none) content_block_stop 0
      #|(none) content_block_start 1 {"type":"tool_use","id":"toolu_DbhbAGir3qs3o77JKr2BTN9j","name":"a_list","input":{}}
      #|(none) content_block_delta 1 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 1 {"type":"input_json_delta","partial_json":"[1, 2]"}
      #|(none) content_block_stop 1
      #|(none) content_block_start 2 {"type":"tool_use","id":"toolu_NCf4tMSwK04LkjFxZfMyVls1","name":"broken","input":{}}
      #|(none) content_block_delta 2 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 2 {"type":"input_json_delta","partial_json":"{\"city\": \"Par"}
      #|(none) content_block_stop 2
      #|(none) content_block_start 3 {"type":"tool_use","id":"toolu_a0lxsrqPBmPj21seI0h9c0KO","name":"not_json","input":{}}
      #|(none) content_block_delta 3 {"type":"input_json_delta","partial_json":""}
      #|(interval) content_block_delta 3 {"type":"input_json_delta","partial_json":"not JSON at all"}
      #|(none) content_block_stop 3
      #|(none) message_delta "tool_use"
      #|(none) message_stop
    ),
  )
}
