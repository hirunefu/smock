// Tests of an openai-chat reply's tool calls through the package's public
// interface: the JSON reply's `tool_calls`, the stream's tool-call deltas,
// their ids and the stop reason they derive. They run on native and on
// wasm-gc with the same output.

///|
/// The tool call `get_weather` with the arguments `{"city":"Paris"}`.
fn weather(id? : String) -> @llm.ToolCall {
  @llm.ToolCall(name="get_weather", arguments={ "city": "Paris" }, id?)
}

///|
/// The reply to a request whose body is `request`, by default one without
/// `stream`, for an `openai-chat` declaration with `text`, `tool_calls` and
/// the chunk size and stop reason given, as `shown` shows it.
fn chat_calls(
  text : String,
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  request? : Json? = Some({ "model": "test-model" }),
  chunk_size? : Int,
  stop_reason? : String,
) -> String {
  shown(
    @llm.reply(
      @llm.Declaration(
        api=OpenaiChat,
        chunk_size?,
        stop_reason?=stop_reason.map(word => {
          @llm.read_stop_reason(OpenaiChat, Json::string(word)).unwrap()
        }),
      ),
      @llm.Strings(text~, tool_calls~),
      request~,
      now=received,
      ids=@llm.ids_generator(7),
    ),
  )
}

///|
test "a JSON reply with tool calls and no text has content null, the calls in message.tool_calls, and the finish_reason tool_calls" {
  inspect(
    chat_calls("", [weather()]),
    content=(
      #|Content-Type: application/json
      #|x-request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|{"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}],"refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
    ),
  )
}

///|
/// The message of the JSON reply that `chat_calls` shows: its members'
/// names, its content, then each of its tool calls, each on a line of its
/// own as compact JSON.
fn message_of(shown : String) -> String {
  let body = @json.parse(shown[shown.find("\n{").unwrap() + 1:].to_owned()) catch {
    e => abort("not JSON: \{e}")
  }
  guard body is { "choices": [{ "message": Object(message), .. }], .. } else {
    abort("no message")
  }
  let lines = [
    "members: \{message.keys().collect().join(", ")}",
    "content: \{message.get("content").unwrap().stringify()}",
  ]
  if message.get("tool_calls") is Some(Array(calls)) {
    for call in calls {
      lines.push(call.stringify())
    }
  }
  lines.join("\n")
}

///|
test "text comes first, then each tool call in the order written; object arguments are compact JSON in the order written, and a string is sent as written" {
  let calls : ReadOnlyArray[@llm.ToolCall] = [
    weather(),
    @llm.ToolCall(name="search", arguments={
      "query": "天気 \"Paris\"\n",
      "limit": 10,
      "ratio": Json::number(0.5),
      "tags": ["a", Json::null(), true],
      "nested": { "z": 1, "a": {} },
    }),
    @llm.ToolCall(name="broken", arguments="{\"city\": \"Par"),
    @llm.ToolCall(name="empty", arguments=""),
    @llm.ToolCall(name="no_arguments", arguments={}),
  ]
  inspect(
    message_of(chat_calls("Let me check.", calls)),
    content=(
      #|members: role, content, tool_calls, refusal, annotations
      #|content: "Let me check."
      #|{"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}
      #|{"id":"call_DbhbAGir3qs3o77JKr2BTN9j","type":"function","function":{"name":"search","arguments":"{\"query\":\"天気 \\\"Paris\\\"\\n\",\"limit\":10,\"ratio\":0.5,\"tags\":[\"a\",null,true],\"nested\":{\"z\":1,\"a\":{}}}"}}
      #|{"id":"call_NCf4tMSwK04LkjFxZfMyVls1","type":"function","function":{"name":"broken","arguments":"{\"city\": \"Par"}}
      #|{"id":"call_a0lxsrqPBmPj21seI0h9c0KO","type":"function","function":{"name":"empty","arguments":""}}
      #|{"id":"call_H5mcAqiERyhvYhfaZeN3ojuN","type":"function","function":{"name":"no_arguments","arguments":"{}"}}
    ),
  )
}

///|
test "a stream with tool calls and no text opens with content null, then each call opens with its index, id, type and name, and one chunk per piece of its arguments follows with the index alone" {
  inspect(
    chat_calls(
      "",
      [weather()],
      request=Some({ "model": "test-model", "stream": true }),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":null},"logprobs":null,"finish_reason":null}]}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\":"}}]},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Par"}}]},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]},"logprobs":null,"finish_reason":null}]}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}
      #|(none) data: [DONE]
      #|
    ),
  )
}

///|
/// The stream of an `openai-chat` declaration with `text`, or the `chunks`
/// given, `tool_calls` and the chunk size given, to a request that sets
/// `stream: true` and the usage given: each chunk on a line of its own,
/// after its wait slot, as its delta and finish reason, or its usage when
/// it has no choice.
fn deltas(
  text : String,
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  chunks? : ReadOnlyArray[String],
  chunk_size? : Int,
  usage? : Bool = false,
) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat, chunk_size?),
    @llm.Strings(text~, chunks?, tool_calls~),
    request=Some({
      "stream": true,
      "stream_options": { "include_usage": Json::boolean(usage) },
    }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { abort("the JSON reply") }
  let lines = []
  for event in events {
    let chunk = @json.parse(event.data) catch { _ => Json::null() }
    let line = match chunk {
      { "choices": [{ "delta": delta, "finish_reason": reason, .. }], .. } =>
        "\{delta.stringify()} \{reason.stringify()}"
      { "choices": [], "usage": usage, .. } => "usage \{usage.stringify()}"
      _ => event.data
    }
    lines.push("(\{slot(event.wait)}) \{line}")
  }
  lines.join("\n")
}

///|
test "text and several tool calls: the text's pieces, then each call opens and its arguments follow, in the order written, with the text's chunk size" {
  inspect(
    deltas(
      "Let me check.",
      [
        weather(),
        @llm.ToolCall(name="get_time", arguments={ "zone": "CET" }),
        @llm.ToolCall(name="broken", arguments="{\"a\":"),
      ],
      chunk_size=6,
    ),
    content=(
      #|(none) {"role":"assistant","content":""} null
      #|(first) {"content":"Let me"} null
      #|(interval) {"content":" check"} null
      #|(interval) {"content":"."} null
      #|(none) {"tool_calls":[{"index":0,"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"get_weather","arguments":""}}]} null
      #|(interval) {"tool_calls":[{"index":0,"function":{"arguments":"{\"city"}}]} null
      #|(interval) {"tool_calls":[{"index":0,"function":{"arguments":"\":\"Par"}}]} null
      #|(interval) {"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]} null
      #|(none) {"tool_calls":[{"index":1,"id":"call_DbhbAGir3qs3o77JKr2BTN9j","type":"function","function":{"name":"get_time","arguments":""}}]} null
      #|(interval) {"tool_calls":[{"index":1,"function":{"arguments":"{\"zone"}}]} null
      #|(interval) {"tool_calls":[{"index":1,"function":{"arguments":"\":\"CET"}}]} null
      #|(interval) {"tool_calls":[{"index":1,"function":{"arguments":"\"}"}}]} null
      #|(none) {"tool_calls":[{"index":2,"id":"call_NCf4tMSwK04LkjFxZfMyVls1","type":"function","function":{"name":"broken","arguments":""}}]} null
      #|(interval) {"tool_calls":[{"index":2,"function":{"arguments":"{\"a\":"}}]} null
      #|(none) {} "tool_calls"
      #|(none) [DONE]
    ),
  )
}

///|
test "with include_usage, every tool-call chunk carries usage: null, and the usage chunk follows the closing one" {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat, usage=@llm.Usage(input=31, output=18)),
    @llm.Strings(text="", tool_calls=[weather()]),
    request=Some({ "stream": true, "stream_options": { "include_usage": true } }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { fail("the JSON reply") }
  let lines = []
  for event in events {
    let chunk = @json.parse(event.data) catch { _ => Json::null() }
    let line = match chunk {
      { "choices": [{ "delta": delta, .. }], "usage": usage, .. } =>
        "\{delta.stringify()}, usage \{usage.stringify()}"
      {
        "choices": [],
        "usage": { "prompt_tokens": i, "completion_tokens": o, .. },
        ..
      } => "no choice, usage \{i.stringify()} and \{o.stringify()}"
      _ => event.data
    }
    lines.push(line)
  }
  inspect(
    lines.join("\n"),
    content=(
      #|{"role":"assistant","content":null}, usage null
      #|{"tool_calls":[{"index":0,"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"get_weather","arguments":""}}]}, usage null
      #|{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]}, usage null
      #|{"tool_calls":[{"index":0,"function":{"arguments":"ty\":"}}]}, usage null
      #|{"tool_calls":[{"index":0,"function":{"arguments":"\"Par"}}]}, usage null
      #|{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]}, usage null
      #|{}, usage null
      #|no choice, usage 31 and 18
      #|[DONE]
    ),
  )
}

///|
test "with tool calls, empty text sends no content piece, even when chunks gives empty ones; empty arguments send no piece, and a reply with no piece waits before its closing chunk" {
  let silent = @llm.ToolCall(name="ping", arguments="")
  inspect(
    [
      deltas("", [silent], chunks=["", ""]),
      deltas("", [silent, weather()], chunk_size=100),
      deltas("", [], chunks=[""]),
    ].join("\n---\n"),
    content=(
      #|(none) {"role":"assistant","content":null} null
      #|(none) {"tool_calls":[{"index":0,"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"ping","arguments":""}}]} null
      #|(first) {} "tool_calls"
      #|(none) [DONE]
      #|---
      #|(none) {"role":"assistant","content":null} null
      #|(none) {"tool_calls":[{"index":0,"id":"call_iHzkHTRdWXnW746KnN1UOBYQ","type":"function","function":{"name":"ping","arguments":""}}]} null
      #|(none) {"tool_calls":[{"index":1,"id":"call_DbhbAGir3qs3o77JKr2BTN9j","type":"function","function":{"name":"get_weather","arguments":""}}]} null
      #|(first) {"tool_calls":[{"index":1,"function":{"arguments":"{\"city\":\"Paris\"}"}}]} null
      #|(none) {} "tool_calls"
      #|(none) [DONE]
      #|---
      #|(none) {"role":"assistant","content":""} null
      #|(first) {"content":""} null
      #|(none) {} "stop"
      #|(none) [DONE]
    ),
  )
}

///|
test "every tool-call delta has an integer index, only the first of each call has its id, type and name, and each call's argument pieces join to exactly its arguments" {
  let sources : Array[Json] = [
    { "city": "Paris" },
    "{\"city\": \"Par",
    "",
    "not JSON at all",
    {
      "text": "天気は晴れです。",
      "emoji": "Done 👍🏽 🇫🇷",
      "outside": "𝄞 and 𠀋",
    },
    "𝄞𠀋𝄞",
    {
      "nested": { "list": [1, 2.5, -3, true, Json::null()], "quote": "\"\\\n" },
    },
  ]
  let tool_calls = sources.mapi((i, arguments) => {
    @llm.ToolCall(name="f\{i}", arguments~)
  })
  let expected = tool_calls.map(call => call.arguments)
  for size in [1, 2, 3, 4, 7, 1000] {
    let reply = @llm.reply(
      @llm.Declaration(api=OpenaiChat, chunk_size=size),
      @llm.Strings(text="Hi", tool_calls=ReadOnlyArray::from_array(tool_calls)),
      request=Some({ "stream": true }),
      now=received,
      ids=@llm.ids_generator(7),
    )
    guard reply.body is Events(events) else { fail("the JSON reply") }
    let joined = Array::make(tool_calls.length(), "")
    let opened = Array::make(tool_calls.length(), 0)
    let mut last = -1
    for event in events {
      let chunk = @json.parse(event.data) catch { _ => continue }
      guard chunk
        is { "choices": [{ "delta": { "tool_calls": calls, .. }, .. }], .. } else {
        continue
      }
      guard calls
        is [
          {
            "index": Number(index, ..),
            "function": { "arguments": String(piece), .. } as function,
            ..
          } as call,
        ] &&
        index == index.floor() &&
        index >= 0.0 &&
        index.to_int() < tool_calls.length() else {
        fail("size \{size}: \{event.data}")
      }
      let k = index.to_int()
      guard k >= last else { fail("size \{size}: call \{k} after \{last}") }
      last = k
      let opens = call is { "id": String(_), "type": "function", .. } &&
        function is { "name": String(_), .. }
      if opens {
        guard opened[k] == 0 && piece == "" else {
          fail("size \{size}: \{event.data}")
        }
      } else {
        guard opened[k] == 1 &&
          call is Object(members) &&
          members.length() == 2 &&
          function is Object(inner) &&
          inner.length() == 1 else {
          fail("size \{size}: \{event.data}")
        }
      }
      opened[k] = 1
      joined[k] = joined[k] + piece
    }
    guard opened.iter().all(n => n == 1) && joined == expected else {
      fail("size \{size}: \{@debug.to_string(joined)}")
    }
  }
}

///|
/// The ids of the JSON reply and of the stream for `tool_calls`, with ids
/// drawn from the generator of the draw `draw`: the request id, the reply's
/// id, then each tool call's id, from the JSON reply's `tool_calls` and
/// from the stream's opening deltas, which must agree.
fn ids_of(
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  draw : UInt64,
) -> Array[String] {
  let found = []
  let requests : Array[Json?] = [None, Some({ "stream": true })]
  for request in requests {
    let reply = @llm.reply(
      @llm.Declaration(api=OpenaiChat),
      @llm.Strings(text="Hi", tool_calls~),
      request~,
      now=received,
      ids=@llm.ids_generator(draw),
    )
    let ids = [reply.request_id.1]
    match reply.body {
      Json(body) => {
        let body = @json.parse(@utf8.decode_lossy(body)) catch {
          _ => abort("not JSON")
        }
        guard body
          is { "id": String(id), "choices": [{ "message": message, .. }], .. } else {
          abort("no message")
        }
        ids.push(id)
        if message is { "tool_calls": Array(calls), .. } {
          for call in calls {
            guard call is { "id": String(id), .. } else { abort("no call id") }
            ids.push(id)
          }
        }
      }
      Events(events) =>
        for i, event in events {
          let chunk = @json.parse(event.data) catch { _ => continue }
          if i == 0 && chunk is { "id": String(id), .. } {
            ids.push(id)
          }
          if chunk
            is {
              "choices": [
                {
                  "delta": { "tool_calls": [{ "id": String(id), .. }], .. },
                  ..
                },
              ],
              ..
            } {
            ids.push(id)
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
test "each tool call takes two slots after the reply's and the Responses message item's, its function call item's and then its call id's; the request id's comes last" {
  for draw in 0UL..<50UL {
    for n in 0..<4 {
      let tool_calls = ReadOnlyArray::from_array(
        Array::makei(n, _ => weather()),
      )
      let expected = [
        "req_\{slot_id(draw, 2 + 2 * n)}",
        "chatcmpl-\{slot_id(draw, 0)}",
      ]
      for k in 0..<n {
        expected.push("call_\{slot_id(draw, 3 + 2 * k)}")
      }
      let ids = ids_of(tool_calls, draw)
      guard ids == expected else {
        fail(
          "draw \{draw}, \{n} tool calls: \{@debug.to_string(ids)}, not \{@debug.to_string(expected)}",
        )
      }
    }
  }
}

///|
test "a tool call's id fixes its call id, sent as written, and every other id stays as it was" {
  let fixed = (k : Int) => {
    let tool_calls : Array[@llm.ToolCall] = [weather(), weather(), weather()]
    tool_calls[k] = weather(id="call_test_\{k}")
    ids_of(ReadOnlyArray::from_array(tool_calls), 7).join("\n")
  }
  inspect(
    [
      ids_of([weather(), weather(), weather()], 7).join("\n"),
      fixed(0),
      fixed(1),
      ids_of([weather(id=""), weather(id="a \"quoted\" id, 天気")], 7).join(
        "\n",
      ),
    ].join("\n---\n"),
    content=(
      #|req_RESVurpTQO6pgD32uiBlPjw0
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|call_iHzkHTRdWXnW746KnN1UOBYQ
      #|call_DbhbAGir3qs3o77JKr2BTN9j
      #|call_NCf4tMSwK04LkjFxZfMyVls1
      #|---
      #|req_RESVurpTQO6pgD32uiBlPjw0
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|call_test_0
      #|call_DbhbAGir3qs3o77JKr2BTN9j
      #|call_NCf4tMSwK04LkjFxZfMyVls1
      #|---
      #|req_RESVurpTQO6pgD32uiBlPjw0
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|call_iHzkHTRdWXnW746KnN1UOBYQ
      #|call_test_1
      #|call_NCf4tMSwK04LkjFxZfMyVls1
      #|---
      #|req_NCUifvyxkaNvRkMCKLDmHTwH
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|
      #|a "quoted" id, 天気
    ),
  )
}

///|
test "the call ids of one reply are distinct, and the same draw gives the same ones" {
  let tool_calls : ReadOnlyArray[@llm.ToolCall] = [
    weather(),
    weather(),
    weather(),
    weather(),
    weather(),
  ]
  for draw in 0UL..<200UL {
    let ids = ids_of(tool_calls, draw)
    let calls = ids[2:]
    for i in 0..<calls.length() {
      for j in 0..<i {
        guard calls[i] != calls[j] else {
          fail("draw \{draw}: \{calls[i]} twice")
        }
      }
    }
    guard ids == ids_of(tool_calls, draw) else {
      fail("draw \{draw}: not the same")
    }
  }
}

///|
test "left out, the stop reason of a reply with tool calls is derived as tool_calls, with text or without; a written word stays, whatever the content" {
  let calls : ReadOnlyArray[@llm.ToolCall] = [weather()]
  inspect(
    [
      finish_reasons(None, tool_calls=calls),
      finish_reasons(None, text="", tool_calls=calls),
      finish_reasons(Some("stop"), tool_calls=calls),
      finish_reasons(Some("length"), text="", tool_calls=calls),
      finish_reasons(Some("content_filter"), tool_calls=calls),
      finish_reasons(Some("function_call"), tool_calls=calls),
      finish_reasons(Some("tool_calls")),
    ].join("\n"),
    content=(
      #|left out: JSON tool_calls, stream tool_calls
      #|left out: JSON tool_calls, stream tool_calls
      #|stop: JSON stop, stream stop
      #|length: JSON length, stream length
      #|content_filter: JSON content_filter, stream content_filter
      #|function_call: JSON function_call, stream function_call
      #|tool_calls: JSON tool_calls, stream tool_calls
    ),
  )
}

///|
test "tool calls draw their slots under every API, so the reply's id and the request id keep their characters when api changes" {
  let tool_calls : ReadOnlyArray[@llm.ToolCall] = [weather(), weather()]
  let lines = []
  for api in [@llm.Api::OpenaiChat, OpenaiResponses, AnthropicMessages] {
    let reply = @llm.reply(
      @llm.Declaration(api~),
      @llm.Strings(text="Hi", tool_calls~),
      request=None,
      now=received,
      ids=@llm.ids_generator(7),
    )
    guard reply.body is Json(body) else { fail("not the JSON reply") }
    let body = @json.parse(@utf8.decode_lossy(body)) catch {
      _ => fail("not JSON")
    }
    guard body is { "id": String(id), .. } else { fail("no id") }
    lines.push(
      "\{api.name()}: \{id}, \{reply.request_id.0}: \{reply.request_id.1}",
    )
    if body is { "output": [{ "id": String(message), .. }, ..], .. } {
      lines.push("  message item: \{message}")
    }
  }
  lines.push(
    "slots 0, 1 and 6: \{slot_id(7, 0)}, \{slot_id(7, 1)}, \{slot_id(7, 6)}",
  )
  inspect(
    lines.join("\n"),
    content=(
      #|openai-chat: chatcmpl-KCVauEuclT08Mg4CWd55sNbz, x-request-id: req_NCUifvyxkaNvRkMCKLDmHTwH
      #|openai-responses: resp_KCVauEuclT08Mg4CWd55sNbz, x-request-id: req_NCUifvyxkaNvRkMCKLDmHTwH
      #|  message item: msg_mGR88Teee4muTOOd2B3UzQJr
      #|anthropic-messages: msg_KCVauEuclT08Mg4CWd55sNbz, request-id: req_NCUifvyxkaNvRkMCKLDmHTwH
      #|slots 0, 1 and 6: KCVauEuclT08Mg4CWd55sNbz, mGR88Teee4muTOOd2B3UzQJr, NCUifvyxkaNvRkMCKLDmHTwH
    ),
  )
}
