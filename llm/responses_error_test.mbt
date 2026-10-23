// Tests of the mid-stream error of an openai-responses reply through the
// package's public interface: where the stream is cut, the `error` event,
// its `sequence_number` and its wait slot, and the ordinary reply to a
// request that does not stream. They run on native and on wasm-gc with the
// same output.

///|
/// The reply to a request whose body is `request`, by default one for
/// `gpt-6-astra` that sets `stream: true`, for an `openai-responses`
/// declaration whose mid-stream error comes after `after` code points, with
/// the code `code`, and whose strings are `strings`, with the chunk size
/// given.
fn responses_cut(
  strings : @llm.Strings,
  after~ : Int,
  code? : String = "server_error",
  request? : Json? = Some({ "model": "gpt-6-astra", "stream": true }),
  chunk_size? : Int,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(
      api=OpenaiResponses,
      chunk_size?,
      error=@llm.MidStreamError(after~, kind=code),
    ),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
test "an error after 0 code points follows response.created and response.in_progress as event: error, numbered next, in the first wait slot, with no item and no closing event" {
  inspect(
    shown(
      responses_cut(
        @llm.Strings(text="Hello!", error_message="Something went wrong"),
        after=0,
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: response.created data: {"type":"response.created","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}
      #|(none) event: response.in_progress data: {"type":"response.in_progress","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":1}
      #|(first) event: error data: {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":2}
      #|
    ),
  )
}

///|
/// The events of `reply`'s stream, one per line: each one's wait slot,
/// `event:` line and `sequence_number`, then the piece a delta carries, the
/// `output_index` and item type an added item carries, or the whole data
/// of an `error` event.
fn cut_outline(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let lines = []
  for event in events {
    let data = @json.parse(event.data)
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "-"
    }
    let carries = match data {
      { "type": "error", .. } => " \{event.data}"
      { "delta": String(piece), .. } => " \{piece.escape()}"
      { "output_index": index, "item": { "type": String(kind), .. }, .. } =>
        " @\{index.stringify()} \{kind}"
      _ => ""
    }
    lines.push(
      "(\{slot(event.wait)}) \{event.event.unwrap_or("-")} #\{number}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "an error inside a piece opens the message item and its part and sends the text up to exactly after code points, the piece that holds the cut ending there, then waits as a next piece would" {
  inspect(
    cut_outline(
      responses_cut(
        @llm.Strings(
          text="Hello! How can I assist you today?",
          error_message="Something went wrong",
        ),
        after=6,
      ),
    ),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Hell"
      #|(interval) response.output_text.delta #5 "o!"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":6}
    ),
  )
}

///|
test "an error at the end of the text follows every piece, with no response.output_text.done, part or item done, and no response.completed" {
  inspect(
    cut_outline(
      responses_cut(
        @llm.Strings(text="Hello!", error_message="Something went wrong"),
        after=6,
      ),
    ),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Hell"
      #|(interval) response.output_text.delta #5 "o!"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":6}
    ),
  )
}

///|
test "an error before the tool calls follows the text, and no function call item is sent; with no text, there is no message item and it follows response.in_progress" {
  inspect(
    [
      cut_outline(
        responses_cut(
          @llm.Strings(
            text="Let me check.",
            tool_calls=[weather()],
            error_message="Something went wrong",
          ),
          after=13,
        ),
      ),
      cut_outline(
        responses_cut(
          @llm.Strings(
            tool_calls=[weather(), weather(id="call_2")],
            error_message="Something went wrong",
          ),
          after=0,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Let "
      #|(interval) response.output_text.delta #5 "me c"
      #|(interval) response.output_text.delta #6 "heck"
      #|(interval) response.output_text.delta #7 "."
      #|(interval) error #8 {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":8}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(first) error #2 {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":2}
    ),
  )
}

///|
/// What openai-python reads of `reply`'s cut stream, or the first rule it
/// breaks: every rule `broken` checks but the closing event, which a cut
/// stream lacks (an `event:` line equal to the `type`, `sequence_number`
/// from 0 without gaps, `response.created` first, one response id, items
/// opened before their content); `response.in_progress` second; the
/// `error` last, once, with its members in the reference's order and a
/// null `param`; and between them only the message item's opening events
/// and its text deltas: nothing done, no function call item. Then the names
/// of its events, in order.
fn cut_checked(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let base = broken(reply)
  guard base == "ends with error" else { return base }
  let names = []
  for event in events {
    guard !event.data.contains("\n") else { return "data on two lines" }
    names.push(event.event.unwrap_or("-"))
  }
  guard names
    is ["response.created", "response.in_progress", .. middle, "error"] else {
    return "not from response.created and response.in_progress to the error"
  }
  for i, name in middle {
    guard name
      is ("response.output_item.added"
      | "response.content_part.added"
      | "response.output_text.delta") else {
      return "\{name} before the error"
    }
    if @json.parse(events[i + 2].data)
      is { "item": { "type": String(kind), .. }, .. } &&
      kind != "message" {
      return "a \{kind} item before the error"
    }
  }
  guard @json.parse(events[events.length() - 1].data) is Object(error) &&
    error.keys().collect() ==
    ["type", "code", "message", "param", "sequence_number"] &&
    error.get("param") is Some(Null) else {
    return "the error's members"
  }
  names.join(" ")
}

///|
test "every event of a cut stream keeps the SDK's invariants, sequence_number counting without a gap through the error event, from response.created to the error" {
  let strings = @llm.Strings(
    text="a \"quote\",\na line break",
    error_message="Something went wrong",
  )
  inspect(
    [
      cut_checked(responses_cut(strings, after=0)),
      cut_checked(responses_cut(strings, after=1)),
      cut_checked(responses_cut(strings, after=5, chunk_size=1)),
      cut_checked(responses_cut(strings, after=23)),
      cut_checked(
        responses_cut(
          @llm.Strings(
            tool_calls=[weather()],
            error_message="Something went wrong",
          ),
          after=0,
        ),
      ),
      cut_checked(
        responses_cut(
          @llm.Strings(
            chunks=["", "天気", "👍🏽"],
            tool_calls=[weather()],
            error_message="Something went wrong",
          ),
          after=4,
        ),
      ),
    ].join("\n"),
    content=(
      #|response.created response.in_progress error
      #|response.created response.in_progress response.output_item.added response.content_part.added response.output_text.delta error
      #|response.created response.in_progress response.output_item.added response.content_part.added response.output_text.delta response.output_text.delta response.output_text.delta response.output_text.delta response.output_text.delta error
      #|response.created response.in_progress response.output_item.added response.content_part.added response.output_text.delta response.output_text.delta response.output_text.delta response.output_text.delta response.output_text.delta response.output_text.delta error
      #|response.created response.in_progress error
      #|response.created response.in_progress response.output_item.added response.content_part.added response.output_text.delta response.output_text.delta response.output_text.delta error
    ),
  )
}

///|
test "a cut stream that breaks a rule is caught: the check is not vacuous" {
  let cut = (text : String, after : Int) => {
    responses_cut(
      @llm.Strings(text~, error_message="Something went wrong"),
      after~,
    )
  }
  let events_of = (reply : @llm.Reply) => {
    guard reply.body is Events(events) else { fail("not a stream") }
    events
  }
  let whole = events_of(responses_stream(text="Hello!"))
  // The error and the delta before it swapped.
  let swapped = cut("Hello!", 6)
  let events = events_of(swapped)
  let error = events[6]
  events[6] = events[5]
  events[5] = error
  // No error: the uncut stream's response.output_text.done in its place.
  let no_error = cut("Hello!", 6)
  events_of(no_error)[6] = whole[6]
  // The text closed before the error: the uncut stream up to its
  // response.output_text.done, numbered 6, then an error numbered 7.
  let closed = responses_stream(text="Hello!")
  let events = events_of(closed)
  while events.length() > 7 {
    ignore(events.pop())
  }
  events.push(events_of(cut("Hello!!!!", 9))[7])
  inspect(
    [cut_checked(swapped), cut_checked(no_error), cut_checked(closed)].join(
      "\n",
    ),
    content=(
      #|#5: sequence_number 6
      #|#6: sequence_number 5
      #|ends with response.output_text.delta
      #|ends with response.output_text.done
      #|response.output_text.done before the error
    ),
  )
}

///|
test "among explicit chunks an empty one counts 0 code points and is a delta of its own, and the cut is counted in code points, so it never splits one" {
  let chunks : ReadOnlyArray[String] = ["", "Hel", "", "lo", "", "!"]
  inspect(
    [
      cut_outline(
        responses_cut(@llm.Strings(chunks~, error_message="Oops"), after=4),
      ),
      cut_outline(
        responses_cut(
          @llm.Strings(text="👍🏽🇫🇷𝄞", error_message="Oops"),
          after=3,
          chunk_size=2,
        ),
      ),
      cut_outline(
        responses_cut(
          @llm.Strings(text="天気は晴れです。", error_message="Oops"),
          after=4,
          chunk_size=3,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 ""
      #|(interval) response.output_text.delta #5 "Hel"
      #|(interval) response.output_text.delta #6 ""
      #|(interval) response.output_text.delta #7 "l"
      #|(interval) error #8 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":8}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "👍🏽"
      #|(interval) response.output_text.delta #5 "🇫"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":6}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "天気は"
      #|(interval) response.output_text.delta #5 "晴"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":6}
    ),
  )
}

///|
test "past the end of the text, which only a templated text can be, the error follows the whole text: the message item as the stream without an error sends it, then every piece" {
  inspect(
    [
      cut_outline(
        responses_cut(@llm.Strings(text="Hi", error_message="Oops"), after=5),
      ),
      cut_outline(
        responses_cut(@llm.Strings(text="", error_message="Oops"), after=5),
      ),
      cut_outline(
        responses_cut(
          @llm.Strings(chunks=["", ""], error_message="Oops"),
          after=5,
        ),
      ),
      cut_outline(
        responses_cut(
          @llm.Strings(tool_calls=[weather()], error_message="Oops"),
          after=5,
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Hi"
      #|(interval) error #5 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":5}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) error #4 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":4}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 ""
      #|(interval) response.output_text.delta #5 ""
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":6}
      #|---
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(first) error #2 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":2}
    ),
  )
}

///|
test "a request that does not stream gets the ordinary JSON reply, whole, with no error: the one it gets without an error" {
  let strings = @llm.Strings(
    text="Hello!",
    tool_calls=[weather()],
    error_message="Oops",
  )
  let request = Some(Json::object({ "model": "gpt-6-astra" }))
  let without = @llm.reply(
    @llm.Declaration(api=OpenaiResponses),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
  let with_error = responses_cut(strings, after=2, request~)
  inspect(
    "the same as without an error: \{shown(with_error) == shown(without)}\n\{shown(with_error)}",
    content=(
      #|the same as without an error: true
      #|Content-Type: application/json
      #|x-request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hello!","annotations":[],"logprobs":[]}]},{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0},"user":null,"metadata":{}}
    ),
  )
}

///|
test "the code and the message are sent as written, JSON-escaped, with a null param" {
  let reply = responses_cut(
    @llm.Strings(text="Hi", error_message="Line 1\nsaid \"no\" é"),
    after=0,
    code="rate_limit_exceeded",
  )
  inspect(
    event_data(reply, "error"),
    content=(
      #|{"type":"error","code":"rate_limit_exceeded","message":"Line 1\nsaid \"no\" é","param":null,"sequence_number":2}
    ),
  )
}

///|
test "a written stop reason does not change the cut: neither response.completed nor response.incomplete is sent, and handing over the waits leaves every event as it was" {
  let stop_reason = @llm.read_stop_reason(OpenaiResponses, "max_output_tokens").unwrap()
  let reply = @llm.reply(
    @llm.Declaration(
      api=OpenaiResponses,
      stop_reason~,
      error=@llm.MidStreamError(after=5, kind="server_error"),
    ),
    @llm.Strings(text="The weather in Paris is", error_message="Oops"),
    request=Some({ "model": "gpt-6-astra", "stream": true }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  let before = shown(reply)
  guard reply.body is Events(events) else { fail("not a stream") }
  // As the engine draws them: none for an event without a slot, and the
  // longest wait a Definition file gives for the others.
  let waits = FixedArray::make(events.length(), 0)
  for i, event in events {
    if !(event.wait is NoWait) {
      waits[i] = 2147483647
    }
  }
  reply.complete(waits)
  inspect(
    "unchanged by the waits: \{shown(reply) == before}\n\{cut_outline(reply)}",
    content=(
      #|unchanged by the waits: true
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "The "
      #|(interval) response.output_text.delta #5 "w"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Oops","param":null,"sequence_number":6}
    ),
  )
}

///|
test "at load, the stream that the error cuts at 0 is short, so only the JSON reply can pass the bound" {
  let size = (text : String, after : Int, chunk_size : Int) => {
    match
      @llm.check_reply_size(
        @llm.Declaration(
          api=OpenaiResponses,
          chunk_size~,
          error=@llm.MidStreamError(after~, kind="server_error"),
        ),
        @llm.Strings(text~, error_message="Oops"),
      ) {
      Ok(_) => "ok"
      Err(message) => message
    }
  }
  inspect(
    [
      "1 MiB, cut at 0: \{size(repeated("a", 1_048_576), 0, 4)}",
      "6,000 characters in pieces of 1, cut at 10: \{size(repeated("a", 6_000), 10, 1)}",
      "6,000 characters in pieces of 1, cut at 6,000: \{size(repeated("a", 6_000), 6_000, 1)}",
    ].join("\n"),
    content=(
      #|1 MiB, cut at 0: the reply takes more than 1 MiB as a JSON body
      #|6,000 characters in pieces of 1, cut at 10: ok
      #|6,000 characters in pieces of 1, cut at 6,000: the reply takes more than 1 MiB as a stream
    ),
  )
}
