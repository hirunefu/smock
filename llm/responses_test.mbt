// Tests of the openai-responses wire form through the package's public
// interface: the Response object of the JSON reply. They run on native and
// on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, for an
/// `openai-responses` declaration with `text`, the `usage` and
/// `stop_reason` given, and the `id` and `model` given, with ids drawn from
/// the generator of the draw `draw`: the Content-Type smock sets, the
/// request-id header field it adds, then the body.
fn responses(
  text : String,
  request~ : Json? = Some({ "model": "gpt-6-astra", "input": "Hello!" }),
  draw~ : UInt64 = 7,
  id? : String,
  model? : String,
  usage? : @llm.Usage,
  stop_reason? : String,
) -> String {
  let reply = responses_reply(
    text,
    request~,
    draw~,
    id?,
    model?,
    usage?,
    stop_reason?,
  )
  let (name, value) = reply.request_id
  "Content-Type: \{reply.content_type}\n\{name}: \{value}\n\{json_text(reply)}"
}

///|
/// The reply that `responses` shows.
fn responses_reply(
  text : String,
  request~ : Json? = Some({ "model": "gpt-6-astra", "input": "Hello!" }),
  draw~ : UInt64 = 7,
  id? : String,
  model? : String,
  usage? : @llm.Usage,
  stop_reason? : String,
) -> @llm.Reply {
  let stop_reason = match stop_reason {
    Some(word) =>
      Some(@llm.read_stop_reason(OpenaiResponses, Json::string(word)).unwrap())
    None => None
  }
  @llm.reply(
    @llm.Declaration(api=OpenaiResponses, usage?, stop_reason?),
    @llm.Strings(text~, id?, model?),
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
}

///|
test "an openai-responses reply is one Response object, with the text in its message item" {
  inspect(
    responses("Hi there! How can I assist you today?"),
    content=(
      #|Content-Type: application/json
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0},"user":null,"metadata":{}}
    ),
  )
}

///|
/// The member `name` of the Response object `reply` sends, as compact JSON,
/// or `-` when it has none. It is read back from the body, so a number
/// shows as smock writes it after reading it: `1.0` shows as `1`.
fn response_member(reply : @llm.Reply, name : String) -> String raise {
  guard @json.parse(json_text(reply)) is Object(members) else {
    fail("not an object")
  }
  match members.get(name) {
    Some(value) => @template.compact_json(value)
    None => "-"
  }
}

///|
test "empty text without tool calls keeps the message item, with an empty text" {
  inspect(
    response_member(responses_reply(""), "output"),
    content=(
      #|[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"","annotations":[],"logprobs":[]}]}]
    ),
  )
}

///|
test "the text is the output_text's text, in UTF-8 as written" {
  let text = (text : String) => {
    guard @json.parse(response_member(responses_reply(text), "output"))
      is [{ "content": [{ "text": String(text), .. }], .. }] else {
      fail("no text")
    }
    text
  }
  let texts = [
    "天気は晴れです。", "Done 👍🏽 🇫🇷", "𝄞 and 𠀋, outside the Basic Multilingual Plane",
    "a \"quote\", a back\\slash,\na line break and a\ttab",
  ]
  for written in texts {
    guard text(written) == written else { fail("text \{written}") }
  }
  inspect(
    json_text(responses_reply("a \"quote\"\n")).contains(
      "\"text\":\"a \\\"quote\\\"\\n\"",
    ),
    content="true",
  )
}

///|
test "usage gives the declared counts as input_tokens and output_tokens, their sum as total_tokens, and the example's details" {
  let usage = (input : Int64, output : Int64) => {
    response_member(
      responses_reply("Hi", usage=@llm.Usage(input~, output~)),
      "usage",
    )
  }
  inspect(
    [
      usage(37, 11),
      usage(0, 0),
      usage(9_007_199_254_740_991L, 9_007_199_254_740_991L),
    ].join("\n"),
    content=(
      #|{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48}
      #|{"input_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0}
      #|{"input_tokens":9007199254740991,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":9007199254740991,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":18014398509481982}
    ),
  )
}

///|
/// The members of the reply that tell whether it completed: `status`,
/// `completed_at`, `incomplete_details`, and the message item's `status`.
fn completion(reply : @llm.Reply) -> String raise {
  let item = match @json.parse(response_member(reply, "output")) {
    [{ "status": status, .. }] => status.stringify()
    _ => "?"
  }
  [
    "status \{response_member(reply, "status")}",
    "completed_at \{response_member(reply, "completed_at")}",
    "incomplete_details \{response_member(reply, "incomplete_details")}",
    "item \{item}",
  ].join(", ")
}

///|
test "a written stop reason is an incomplete reason: the reply and its message item are incomplete, and completed_at is null" {
  inspect(
    [
      completion(responses_reply("The weather in Paris is")),
      completion(
        responses_reply(
          "The weather in Paris is",
          stop_reason="max_output_tokens",
        ),
      ),
      completion(
        responses_reply("The weather in Paris is", stop_reason="max_messages"),
      ),
      completion(
        responses_reply("The weather in Paris is", stop_reason="content_filter"),
      ),
      completion(
        responses_reply("The weather in Paris is", stop_reason="steered"),
      ),
      completion(responses_reply("", stop_reason="max_output_tokens")),
    ].join("\n"),
    content=(
      #|status "completed", completed_at 1791815405, incomplete_details null, item "completed"
      #|status "incomplete", completed_at null, incomplete_details {"reason":"max_output_tokens"}, item "incomplete"
      #|status "incomplete", completed_at null, incomplete_details {"reason":"max_messages"}, item "incomplete"
      #|status "incomplete", completed_at null, incomplete_details {"reason":"content_filter"}, item "incomplete"
      #|status "incomplete", completed_at null, incomplete_details {"reason":"steered"}, item "incomplete"
      #|status "incomplete", completed_at null, incomplete_details {"reason":"max_output_tokens"}, item "incomplete"
    ),
  )
}

///|
test "an incomplete reply keeps its text, usage and the rest of the object" {
  inspect(
    json_text(
      responses_reply(
        "The weather in Paris is",
        usage=@llm.Usage(input=31, output=5),
        stop_reason="max_output_tokens",
      ),
    ),
    content=(
      #|{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"incomplete","completed_at":null,"error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The weather in Paris is","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":36},"user":null,"metadata":{}}
    ),
  )
}

///|
test "each setting is copied from the request as given; one left out takes the example's value, or is left out when the examples do not show it" {
  let names = [
    "instructions", "previous_response_id", "tools", "tool_choice", "temperature",
    "top_p", "max_output_tokens", "parallel_tool_calls", "metadata", "store", "text",
    "truncation", "reasoning", "user", "safety_identifier", "prompt_cache_key", "top_logprobs",
    "max_tool_calls", "background", "conversation", "service_tier", "model",
  ]
  let lines = []
  for name in names {
    let absent = response_member(responses_reply("Hi", request=Some({})), name)
    let given = response_member(
      responses_reply("Hi", request=Some(Json::object(Map([(name, "given")])))),
      name,
    )
    lines.push("\{name}: \{absent} -> \{given}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|instructions: null -> "given"
      #|previous_response_id: null -> "given"
      #|tools: [] -> "given"
      #|tool_choice: "auto" -> "given"
      #|temperature: 1 -> "given"
      #|top_p: 1 -> "given"
      #|max_output_tokens: null -> "given"
      #|parallel_tool_calls: true -> "given"
      #|metadata: {} -> "given"
      #|store: true -> "given"
      #|text: {"format":{"type":"text"}} -> "given"
      #|truncation: "disabled" -> "given"
      #|reasoning: {"effort":null,"summary":null} -> "given"
      #|user: null -> "given"
      #|safety_identifier: - -> "given"
      #|prompt_cache_key: - -> "given"
      #|top_logprobs: - -> "given"
      #|max_tool_calls: - -> "given"
      #|background: - -> "given"
      #|conversation: - -> -
      #|service_tier: "default" -> "default"
      #|model: "" -> "given"
    ),
  )
}

///|
test "the settings a request gives are copied in the example's order, uninterpreted, and conversation and service_tier are not" {
  let request = @json.parse(
    (
      #|{ "model": "gpt-6-astra", "input": [{ "role": "user", "content": "Hello!" }],
      #|  "instructions": "You are a helpful assistant.", "previous_response_id": "resp_turn_1",
      #|  "tools": [{ "type": "function", "name": "get_weather", "parameters": { "type": "object" } }],
      #|  "tool_choice": { "type": "function", "name": "get_weather" },
      #|  "temperature": 0.20, "top_p": "not a number", "max_output_tokens": 256,
      #|  "parallel_tool_calls": false, "metadata": { "run": "7" }, "store": false,
      #|  "text": { "format": { "type": "json_object" } }, "truncation": "auto",
      #|  "reasoning": { "effort": "low" }, "user": "user-1", "safety_identifier": "safe-1",
      #|  "prompt_cache_key": "cache-1", "top_logprobs": 3, "max_tool_calls": null,
      #|  "background": true, "conversation": "conv_1", "service_tier": "flex",
      #|  "include": ["message.output_text.logprobs"], "stream": false }
    ),
  )
  inspect(
    json_text(responses_reply("Hi", request=Some(request))),
    content=(
      #|{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","background":true,"completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":256,"max_tool_calls":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":false,"previous_response_id":"resp_turn_1","prompt_cache_key":"cache-1","reasoning":{"effort":"low"},"safety_identifier":"safe-1","service_tier":"default","store":false,"temperature":0.2,"text":{"format":{"type":"json_object"}},"tool_choice":{"type":"function","name":"get_weather"},"tools":[{"type":"function","name":"get_weather","parameters":{"type":"object"}}],"top_logprobs":3,"top_p":"not a number","truncation":"auto","usage":{"input_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0},"user":"user-1","metadata":{"run":"7"}}
    ),
  )
}

///|
test "a body that is not a JSON object copies nothing: every setting takes the example's value" {
  let settings = (request : Json?) => {
    let reply = responses_reply("Hi", request~)
    [
      response_member(reply, "model"),
      response_member(reply, "instructions"),
      response_member(reply, "tools"),
      response_member(reply, "background"),
    ].join(" ")
  }
  inspect(
    [settings(None), settings(Some(["instructions"])), settings(Some("tools"))].join(
      "\n",
    ),
    content=(
      #|"" null [] -
      #|"" null [] -
      #|"" null [] -
    ),
  )
}

///|
test "background: true gets the ordinary reply, not a queued one: the JSON reply, or with stream: true the stream, which copies it" {
  let shown = (request : Json) => {
    let reply = responses_reply("Hi", request=Some(request))
    match reply.body {
      Json(_) =>
        "\{reply.content_type}: status \{response_member(reply, "status")}, background \{response_member(reply, "background")}"
      Events(events) => {
        guard @json.parse(events[events.length() - 1].data)
          is { "response": { "status": status, .. } as response, .. } else {
          fail("no closing event")
        }
        let background = match response {
          { "background": background, .. } => background.stringify()
          _ => "-"
        }
        "\{reply.content_type}: \{events[0].event.unwrap_or("-")} first, status \{status.stringify()}, background \{background}"
      }
    }
  }
  inspect(
    [
      shown({ "background": true }),
      shown({ "stream": true }),
      shown({ "stream": true, "background": true }),
    ].join("\n"),
    content=(
      #|application/json: status "completed", background true
      #|text/event-stream: response.created first, status "completed", background -
      #|text/event-stream: response.created first, status "completed", background true
    ),
  )
}

///|
/// The times of the reply to a request received at `now`, with the stop
/// reason `stop_reason` written: `created_at` and `completed_at`.
fn times(now : Int64, stop_reason? : String) -> String raise {
  let stop_reason = match stop_reason {
    Some(word) =>
      Some(@llm.read_stop_reason(OpenaiResponses, Json::string(word)).unwrap())
    None => None
  }
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiResponses, stop_reason?),
    @llm.Strings(text="Hi"),
    request=None,
    now~,
    ids=@llm.ids_generator(7),
  )
  "created_at \{response_member(reply, "created_at")}, completed_at \{response_member(reply, "completed_at")}"
}

///|
test "created_at is the time the request was received, in whole seconds, and so is completed_at in a JSON reply" {
  inspect(
    [
      times(0L),
      times(999L),
      times(1_000L),
      times(1_792_713_600_999L),
      times(1_792_713_600_999L, stop_reason="max_output_tokens"),
    ].join("\n"),
    content=(
      #|created_at 0, completed_at 0
      #|created_at 0, completed_at 0
      #|created_at 1, completed_at 1
      #|created_at 1792713600, completed_at 1792713600
      #|created_at 1792713600, completed_at null
    ),
  )
}

///|
/// The ids of the reply to a request with the draw `draw`, for an
/// `openai-responses` declaration with the `id` given: the request-id header
/// field, the reply's id and the message item's id.
fn responses_ids(draw : UInt64, id? : String) -> String raise {
  let reply = responses_reply("Hi", request=None, draw~, id?)
  guard @json.parse(json_text(reply))
    is { "id": String(id), "output": [{ "id": String(item), .. }], .. } else {
    fail("no ids")
  }
  "\{reply.request_id.0}: \{reply.request_id.1}, \{id}, \{item}"
}

///|
test "the reply's id is resp_ and the message item's msg_, each with the 24 characters of its slot, and the request id comes last" {
  for draw in 0UL..<50UL {
    let shown = responses_ids(draw)
    let expected = "x-request-id: req_\{slot_id(draw, 2)}, resp_\{slot_id(draw, 0)}, msg_\{slot_id(draw, 1)}"
    guard shown == expected else { fail("draw \{draw}: \{shown}") }
  }
  inspect(
    [responses_ids(7), responses_ids(7), responses_ids(8)].join("\n"),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, resp_KCVauEuclT08Mg4CWd55sNbz, msg_mGR88Teee4muTOOd2B3UzQJr
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, resp_KCVauEuclT08Mg4CWd55sNbz, msg_mGR88Teee4muTOOd2B3UzQJr
      #|x-request-id: req_23m4SYY5j0dNweGBYvVJCktv, resp_u76DvnZi1R3iOEH1RcaznueA, msg_TnKujUj5UEKdZwNgEFMFG6p9
    ),
  )
}

///|
test "id fixes the resp_ id, sent as written; the message item's id and the request id stay as they were" {
  inspect(
    [
      responses_ids(7),
      responses_ids(7, id="resp_test_1"),
      responses_ids(7, id=""),
      responses_ids(7, id="a \"quoted\" id, 天気\n"),
    ].join("\n"),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, resp_KCVauEuclT08Mg4CWd55sNbz, msg_mGR88Teee4muTOOd2B3UzQJr
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, resp_test_1, msg_mGR88Teee4muTOOd2B3UzQJr
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, , msg_mGR88Teee4muTOOd2B3UzQJr
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk, a "quoted" id, 天気
      #|, msg_mGR88Teee4muTOOd2B3UzQJr
    ),
  )
}

///|
/// The reply's `model` for a request whose body is `request`, from a
/// declaration with the `model` given.
fn response_model(request : Json?, model? : String) -> String raise {
  response_member(responses_reply("Hi", request~, model?), "model")
}

///|
test "the model is the Stub's model, or else the request's when it is a string, or else the empty string" {
  inspect(
    [
      response_model(Some({ "model": "gpt-6-astra" })),
      response_model(Some({ "model": "gpt-6-astra" }), model="test-model"),
      response_model(Some({ "model": 4 })),
      response_model(None),
      response_model(None, model="test-model"),
    ].join("\n"),
    content=(
      #|"gpt-6-astra"
      #|"test-model"
      #|""
      #|""
      #|"test-model"
    ),
  )
}

///|
test "the same declaration answers under both OpenAI APIs, with the same 24 characters in the reply's id and the same request id" {
  let both = (draw : UInt64) => {
    let answer = (api : @llm.Api) => {
      let reply = @llm.reply(
        @llm.Declaration(api~, usage=@llm.Usage(input=31, output=9)),
        @llm.Strings(text="It is 18°C in Paris."),
        request=Some({ "model": "gpt-6-astra" }),
        now=received,
        ids=@llm.ids_generator(draw),
      )
      guard @json.parse(json_text(reply)) is { "id": String(id), .. } else {
        fail("no id")
      }
      "\{api.name()}: \{id}, \{reply.request_id.0}: \{reply.request_id.1}"
    }
    "\{answer(OpenaiChat)}\n\{answer(OpenaiResponses)}"
  }
  for draw in 0UL..<50UL {
    let shown = both(draw)
    let expected = "openai-chat: chatcmpl-\{slot_id(draw, 0)}, x-request-id: req_\{slot_id(draw, 2)}\nopenai-responses: resp_\{slot_id(draw, 0)}, x-request-id: req_\{slot_id(draw, 2)}"
    guard shown == expected else { fail("draw \{draw}: \{shown}") }
  }
  inspect(
    both(7),
    content=(
      #|openai-chat: chatcmpl-KCVauEuclT08Mg4CWd55sNbz, x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|openai-responses: resp_KCVauEuclT08Mg4CWd55sNbz, x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
    ),
  )
}

///|
test "with chunks, the message item's text is their join, and chunkSize changes nothing in the JSON reply" {
  let text = (strings : @llm.Strings, chunk_size : Int32) => {
    let reply = @llm.reply(
      @llm.Declaration(api=OpenaiResponses, chunk_size~),
      strings,
      request=Some({ "model": "gpt-6-astra" }),
      now=received,
      ids=@llm.ids_generator(7),
    )
    guard @json.parse(response_member(reply, "output"))
      is [{ "content": [{ "text": text, .. }], .. }] else {
      fail("no text")
    }
    text.stringify()
  }
  inspect(
    [
      text(@llm.Strings(chunks=["Thumbs up: ", "", "👍", "🏽"]), 4),
      text(@llm.Strings(chunks=[""]), 4),
      text(@llm.Strings(text="Hello there"), 1),
    ].join("\n"),
    content=(
      #|"Thumbs up: 👍🏽"
      #|""
      #|"Hello there"
    ),
  )
}
