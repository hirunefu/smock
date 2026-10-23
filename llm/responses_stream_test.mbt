// Tests of the openai-responses stream through the package's public
// interface: the reply to a request that sets `stream: true`. They run on
// native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one that sets
/// `stream: true`, for an `openai-responses` declaration with `text`, or
/// the `strings` given, and the chunk size `chunk_size`, the usage `usage`
/// and the stop reason `stop_reason` written, with ids drawn from the
/// generator of the draw 7.
fn responses_stream(
  text? : String = "Hi there!",
  strings? : @llm.Strings,
  request? : Json? = Some({ "model": "gpt-6-astra", "stream": true }),
  chunk_size? : Int,
  usage? : @llm.Usage,
  stop_reason? : String,
) -> @llm.Reply {
  let stop_reason = match stop_reason {
    Some(word) =>
      Some(@llm.read_stop_reason(OpenaiResponses, Json::string(word)).unwrap())
    None => None
  }
  @llm.reply(
    @llm.Declaration(api=OpenaiResponses, chunk_size?, usage?, stop_reason?),
    match strings {
      Some(strings) => strings
      None => @llm.Strings(text~)
    },
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
test "a request with stream: true gets the Responses events: the response opened, the message item and its text part opened, a delta per piece, each closed, then response.completed" {
  inspect(
    shown(responses_stream(usage=@llm.Usage(input=37, output=11))),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: response.created data: {"type":"response.created","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}
      #|(none) event: response.in_progress data: {"type":"response.in_progress","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":1}
      #|(none) event: response.output_item.added data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":2}
      #|(none) event: response.content_part.added data: {"type":"response.content_part.added","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]},"sequence_number":3}
      #|(first) event: response.output_text.delta data: {"type":"response.output_text.delta","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"delta":"Hi t","sequence_number":4,"logprobs":[]}
      #|(interval) event: response.output_text.delta data: {"type":"response.output_text.delta","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"delta":"here","sequence_number":5,"logprobs":[]}
      #|(interval) event: response.output_text.delta data: {"type":"response.output_text.delta","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"delta":"!","sequence_number":6,"logprobs":[]}
      #|(none) event: response.output_text.done data: {"type":"response.output_text.done","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"text":"Hi there!","sequence_number":7,"logprobs":[]}
      #|(none) event: response.content_part.done data: {"type":"response.content_part.done","item_id":"msg_mGR88Teee4muTOOd2B3UzQJr","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there!","annotations":[],"logprobs":[]},"sequence_number":8}
      #|(none) event: response.output_item.done data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there!","annotations":[],"logprobs":[]}]},"sequence_number":9}
      #|(none) event: response.completed data: {"type":"response.completed","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there!","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}},"sequence_number":10}
      #|
    ),
  )
}

///|
/// The events of `reply`, one per line: each one's wait slot, `event:`
/// line and `sequence_number`, with the piece a delta carries, or the text
/// a `response.output_text.done` gives, or the status and `completed_at`
/// of the Response a lifecycle event carries.
fn outline(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let lines = []
  for event in events {
    let data = @json.parse(event.data)
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "-"
    }
    let carries = match data {
      { "delta": String(piece), .. } => " \{piece.escape()}"
      { "text": String(text), .. } => " \{text.escape()}"
      {
        "response": {
          "status": String(status),
          "completed_at": completed_at,
          ..
        },
        ..
      } => " \{status} \{completed_at.stringify()}"
      _ => ""
    }
    lines.push(
      "(\{slot(event.wait)}) \{event.event.unwrap_or("-")} #\{number}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "empty text keeps the message item with an empty part and no delta, and its first closing event waits first" {
  inspect(
    outline(responses_stream(text="")),
    content=(
      #|(none) response.created #0 in_progress null
      #|(none) response.in_progress #1 in_progress null
      #|(none) response.output_item.added #2
      #|(none) response.content_part.added #3
      #|(first) response.output_text.done #4 ""
      #|(none) response.content_part.done #5
      #|(none) response.output_item.done #6
      #|(none) response.completed #7 completed 1791815405
    ),
  )
}

///|
test "chunkSize cuts the deltas, and chunks gives them, an empty one included; the done events give the whole text" {
  inspect(
    [
      outline(responses_stream(text="晴れ👍🏽", chunk_size=1)),
      outline(
        responses_stream(
          strings=@llm.Strings(chunks=["Thumbs up: ", "", "👍"]),
        ),
      ),
      outline(responses_stream(text="Hi there!", chunk_size=1_000_000)),
    ].join("\n\n"),
    content=(
      #|(none) response.created #0 in_progress null
      #|(none) response.in_progress #1 in_progress null
      #|(none) response.output_item.added #2
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "晴"
      #|(interval) response.output_text.delta #5 "れ"
      #|(interval) response.output_text.delta #6 "👍"
      #|(interval) response.output_text.delta #7 "🏽"
      #|(none) response.output_text.done #8 "晴れ👍🏽"
      #|(none) response.content_part.done #9
      #|(none) response.output_item.done #10
      #|(none) response.completed #11 completed 1791815405
      #|
      #|(none) response.created #0 in_progress null
      #|(none) response.in_progress #1 in_progress null
      #|(none) response.output_item.added #2
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Thumbs up: "
      #|(interval) response.output_text.delta #5 ""
      #|(interval) response.output_text.delta #6 "👍"
      #|(none) response.output_text.done #7 "Thumbs up: 👍"
      #|(none) response.content_part.done #8
      #|(none) response.output_item.done #9
      #|(none) response.completed #10 completed 1791815405
      #|
      #|(none) response.created #0 in_progress null
      #|(none) response.in_progress #1 in_progress null
      #|(none) response.output_item.added #2
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Hi there!"
      #|(none) response.output_text.done #5 "Hi there!"
      #|(none) response.content_part.done #6
      #|(none) response.output_item.done #7
      #|(none) response.completed #8 completed 1791815405
    ),
  )
}

///|
test "a written stop reason ends the stream with response.incomplete: the item is incomplete, the reason given, and completed_at null" {
  let reply = responses_stream(
    text="The weather in Paris is",
    usage=@llm.Usage(input=31, output=5),
    stop_reason="max_output_tokens",
  )
  guard reply.body is Events(events) else { fail("not a stream") }
  inspect(
    [
      outline(reply),
      events[events.length() - 2].data,
      events[events.length() - 1].data,
    ].join("\n"),
    content=(
      #|(none) response.created #0 in_progress null
      #|(none) response.in_progress #1 in_progress null
      #|(none) response.output_item.added #2
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "The "
      #|(interval) response.output_text.delta #5 "weat"
      #|(interval) response.output_text.delta #6 "her "
      #|(interval) response.output_text.delta #7 "in P"
      #|(interval) response.output_text.delta #8 "aris"
      #|(interval) response.output_text.delta #9 " is"
      #|(none) response.output_text.done #10 "The weather in Paris is"
      #|(none) response.content_part.done #11
      #|(none) response.output_item.done #12
      #|(none) response.incomplete #13 incomplete null
      #|{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The weather in Paris is","annotations":[],"logprobs":[]}]},"sequence_number":12}
      #|{"type":"response.incomplete","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"incomplete","completed_at":null,"error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The weather in Paris is","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":36},"user":null,"metadata":{}},"sequence_number":13}
    ),
  )
}

///|
/// What breaks the checks openai-python's stream helper and the spec make
/// on the Responses stream `reply`, one line each, or `ok`: every event's
/// `event:` line equals its `type`, `sequence_number` counts from 0 by one,
/// `response.created` comes first, every lifecycle event names one id, an
/// item is opened before its content and done with the id of its `added`,
/// every added item is done before the closing event, which comes last,
/// and no `[DONE]` follows.
fn broken(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let out = []
  let mut response_id = None
  let opened : Map[Int, String] = Map([])
  let done : Map[Int, String] = Map([])
  for i, event in events {
    let data = @json.parse(event.data) catch {
      _ => {
        out.push("#\{i}: not JSON: \{event.data}")
        continue
      }
    }
    guard data is { "type": String(kind), .. } else {
      out.push("#\{i}: no type")
      continue
    }
    if event.event != Some(kind) {
      out.push("#\{i}: event: \{event.event.unwrap_or("-")} for \{kind}")
    }
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "missing"
    }
    if number != i.to_string() {
      out.push("#\{i}: sequence_number \{number}")
    }
    if i == 0 && kind != "response.created" {
      out.push("#0: \{kind} first")
    }
    if data is { "response": { "id": String(id), .. }, .. } {
      match response_id {
        None => response_id = Some(id)
        Some(first) if first != id => out.push("#\{i}: response id \{id}")
        _ => ()
      }
    }
    match data {
      {
        "type": "response.output_item.added",
        "output_index": Number(index, ..),
        "item": { "id": String(id), .. },
        ..
      } => opened[index.to_int()] = id
      {
        "type": "response.output_item.done",
        "output_index": Number(index, ..),
        "item": { "id": String(id), .. },
        ..
      } =>
        if opened.get(index.to_int()) == Some(id) {
          done[index.to_int()] = id
        } else {
          out.push("#\{i}: \{id} done, not added")
        }
      { "item_id": String(id), "output_index": Number(index, ..), .. } =>
        if opened.get(index.to_int()) != Some(id) ||
          done.contains(index.to_int()) {
          out.push("#\{i}: \{kind} for an item not open")
        }
      _ => ()
    }
    let closing = kind == "response.completed" || kind == "response.incomplete"
    if closing && i != events.length() - 1 {
      out.push("#\{i}: \{kind} before the last event")
    }
    if closing && opened.length() != done.length() {
      out.push("#\{i}: \{kind} before every item is done")
    }
  }
  if events.last() is Some(last) &&
    !(last.event is Some("response.completed" | "response.incomplete")) {
    out.push("ends with \{last.event.unwrap_or(last.data)}")
  }
  if out.is_empty() {
    "ok"
  } else {
    out.join("\n")
  }
}

///|
test "every stream keeps the SDK's invariants: event: lines equal to type, sequence_number from 0 without gaps, response.created first, one id, items opened before their content and done before the closing event, and no [DONE]" {
  let replies = [
    ("text", responses_stream()),
    ("empty text", responses_stream(text="")),
    ("chunkSize 1", responses_stream(text="晴れ👍🏽", chunk_size=1)),
    (
      "chunks",
      responses_stream(strings=@llm.Strings(chunks=["", "a", "", "𝄞"])),
    ),
    (
      "a fixed id",
      responses_stream(strings=@llm.Strings(text="Hi", id="resp_1")),
    ),
    (
      "incomplete",
      responses_stream(text="The weather in", stop_reason="content_filter"),
    ),
    (
      "a long text",
      responses_stream(text="abcd".repeat(250), stop_reason="steered"),
    ),
  ]
  let lines = []
  for named in replies {
    let (name, reply) = named
    guard reply.body is Events(events) else { fail("\{name}: not a stream") }
    lines.push("\{name}: \{events.length()} events, \{broken(reply)}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|text: 11 events, ok
      #|empty text: 8 events, ok
      #|chunkSize 1: 12 events, ok
      #|chunks: 12 events, ok
      #|a fixed id: 9 events, ok
      #|incomplete: 12 events, ok
      #|a long text: 258 events, ok
    ),
  )
}

///|
test "a broken stream is caught: the check is not vacuous" {
  let reply = responses_stream()
  guard reply.body is Events(events) else { fail("not a stream") }
  // Two events swapped, another response id, and [DONE] after the closing
  // event.
  let swapped = events[2]
  events[2] = events[4]
  events[4] = swapped
  guard responses_stream(
      strings=@llm.Strings(text="Hi there!", id="resp_other"),
    ).body
    is Events(other) else {
    fail("not a stream")
  }
  events[1] = other[1]
  guard chat_reply_to("Hi", { "stream": true }).body is Events(chat) else {
    fail("not a stream")
  }
  events.push(chat[chat.length() - 1])
  inspect(
    broken(reply),
    content=(
      #|#1: response id resp_other
      #|#2: sequence_number 4
      #|#2: response.output_text.delta for an item not open
      #|#3: response.content_part.added for an item not open
      #|#4: sequence_number 2
      #|#10: response.completed before the last event
      #|#11: not JSON: [DONE]
      #|ends with [DONE]
    ),
  )
}

///|
/// The Response objects of the stream to `request`, which sets
/// `stream: true`, as the opening and closing events carry them, beside
/// the JSON reply to the same request without `stream`, each as compact
/// JSON, with the stop reason `stop_reason` written.
fn objects(request : Map[String, Json], stop_reason? : String) -> String raise {
  let streamed = request.copy()
  streamed["stream"] = true
  let reply = responses_stream(
    request=Some(Json::object(streamed)),
    usage=@llm.Usage(input=37, output=11),
    stop_reason?,
  )
  guard reply.body is Events(events) else { fail("not a stream") }
  let response = (event : @llm.Event) => {
    guard @json.parse(event.data) is { "response": response, .. } else {
      fail("no response")
    }
    response
  }
  let json = responses_reply(
    "Hi there!",
    request=Some(Json::object(request)),
    usage=@llm.Usage(input=37, output=11),
    stop_reason?,
  )
  guard json.body is Json(body) else { fail("not JSON") }
  let opening = response(events[0])
  let closing = response(events[events.length() - 1])
  let reply = @json.parse(@utf8.decode_lossy(body))
  // The members in which the opening object differs from the closing one.
  guard (opening, closing) is (Object(opened), Object(closed)) else {
    fail("not objects")
  }
  let differ = []
  for name, value in closed {
    if opened.get(name) != Some(value) {
      differ.push(name)
    }
  }
  [
    "opening: \{@template.compact_json(opening)}",
    "the same in both opening events: \{response(events[1]) == opening}",
    "differs from the closing one in: \{differ.join(", ")}",
    "the closing one is the JSON reply: \{closing == reply}",
  ].join("\n")
}

///|
test "the opening events carry the Response in progress, with the settings the request gave copied, and the closing event the whole Response, which is the JSON reply" {
  let request : Map[String, Json] = {
    "model": "gpt-6-astra",
    "instructions": "You are a helpful assistant.",
    "input": "Hello!",
    "tools": [{ "type": "function", "name": "get_weather" }],
    "metadata": { "run": "7" },
    "background": false,
  }
  inspect(
    objects(request) +
    "\n\n" +
    objects(request, stop_reason="max_output_tokens"),
    content=(
      #|opening: {"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","background":false,"completed_at":null,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[{"type":"function","name":"get_weather"}],"top_p":1,"truncation":"disabled","usage":null,"user":null,"metadata":{"run":"7"}}
      #|the same in both opening events: true
      #|differs from the closing one in: status, completed_at, output, usage
      #|the closing one is the JSON reply: true
      #|
      #|opening: {"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","background":false,"completed_at":null,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[{"type":"function","name":"get_weather"}],"top_p":1,"truncation":"disabled","usage":null,"user":null,"metadata":{"run":"7"}}
      #|the same in both opening events: true
      #|differs from the closing one in: status, incomplete_details, output, usage
      #|the closing one is the JSON reply: true
    ),
  )
}

///|
test "the JSON reply and the stream to the same draw carry the same resp_, msg_ and request ids, the stream in every event" {
  let ids = (stream : Bool) => {
    let reply = @llm.reply(
      @llm.Declaration(api=OpenaiResponses),
      @llm.Strings(text="Hi there!"),
      request=Some({ "stream": stream }),
      now=received,
      ids=@llm.ids_generator(7),
    )
    let found : Map[String, Unit] = Map([])
    let texts = match reply.body {
      Json(body) => [@utf8.decode_lossy(body)]
      Events(events) => events.map(event => event.data)
    }
    for text in texts {
      for prefix in ["\"resp_", "\"msg_"] {
        guard text.find(prefix) is Some(at) else { continue }
        let id = text[at + 1:].to_owned()
        found[id[:id.find("\"").unwrap()].to_owned()] = ()
      }
    }
    let sorted = found.keys().collect()
    sorted.sort()
    "\{sorted.join(" ")} \{reply.request_id.1}"
  }
  inspect(
    "JSON: \{ids(false)}\nstream: \{ids(true)}",
    content=(
      #|JSON: msg_mGR88Teee4muTOOd2B3UzQJr resp_KCVauEuclT08Mg4CWd55sNbz req_5DTBZPrxiMH6i7M92iahxjWk
      #|stream: msg_mGR88Teee4muTOOd2B3UzQJr resp_KCVauEuclT08Mg4CWd55sNbz req_5DTBZPrxiMH6i7M92iahxjWk
    ),
  )
}
