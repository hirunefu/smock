// Tests of the hand-off of a stream's waits: the engine draws a wait for
// each event by its wait slot, then hands the waits back to the reply
// before the stream is sent, so that an event whose content depends on
// them can be completed. They run on native and on wasm-gc with the same
// output.

///|
/// The events of `reply`, each with its wait slot and data, one per line,
/// or its JSON body.
fn shown_events(reply : @llm.Reply) -> String {
  match reply.body {
    Json(body) => @utf8.decode_lossy(body)
    Events(events) =>
      events.map(event => "(\{slot(event.wait)}) \{event.data}").join("\n")
  }
}

///|
/// The `openai-chat` reply with `text` to a request whose body is
/// `request`.
fn chat_reply_to(text : String, request : Json) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text~),
    request=Some(request),
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
test "handing a Chat Completions stream its waits leaves every event as it was, since none depends on them" {
  let out = []
  for text in ["Hello! How can I assist you today?", ""] {
    let reply = chat_reply_to(text, { "model": "test-model", "stream": true })
    let before = shown_events(reply)
    guard reply.body is Events(events) else { fail("not a stream") }
    // As the engine draws them: none for an event without a slot, 400 ms
    // for `first` and the longest wait a Definition file gives for each
    // `interval`.
    let waits = FixedArray::make(events.length(), 0)
    for i, event in events {
      waits[i] = match event.wait {
        NoWait => 0
        First => 400
        Interval => 2147483647
      }
    }
    reply.complete(waits)
    out.push("\{text.escape()}: unchanged \{shown_events(reply) == before}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|"Hello! How can I assist you today?": unchanged true
      #|"": unchanged true
    ),
  )
}

///|
test "a JSON reply has no event, and handing it no wait leaves it as it was" {
  let reply = chat_reply_to("Hi!", { "model": "test-model" })
  let before = shown_events(reply)
  reply.complete([])
  inspect(
    "\{reply.content_type}, unchanged \{shown_events(reply) == before}",
    content=(
      #|application/json, unchanged true
    ),
  )
}

///|
/// The waits the engine would draw for the events of `reply`: none for an
/// event without a slot, `first` for the `first` slot and `interval` for
/// each `interval` one.
fn fixed_waits(
  reply : @llm.Reply,
  first : Int,
  interval : Int,
) -> FixedArray[Int] {
  guard reply.body is Events(events) else { return [] }
  let waits = FixedArray::make(events.length(), 0)
  for i, event in events {
    waits[i] = match event.wait {
      NoWait => 0
      First => first
      Interval => interval
    }
  }
  waits
}

///|
/// The `completed_at` of the closing event of the Responses stream of
/// `text`, with the stop reason `stop_reason` written, to a request
/// received at `received`, after the reply is handed the waits `waits`
/// gives for it, and whether every other event stayed as it was.
fn completed_at(
  text : String,
  waits : (@llm.Reply) -> FixedArray[Int],
  stop_reason? : String,
) -> String raise {
  let stop_reason = match stop_reason {
    Some(word) =>
      Some(@llm.read_stop_reason(OpenaiResponses, Json::string(word)).unwrap())
    None => None
  }
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiResponses, stop_reason?),
    @llm.Strings(text~),
    request=Some({ "stream": true }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { fail("not a stream") }
  let before = events.map(event => event.data)
  reply.complete(waits(reply))
  let last = events.length() - 1
  let mut others = true
  for i in 0..<last {
    others = others && events[i].data == before[i]
  }
  guard @json.parse(events[last].data)
    is { "type": String(kind), "response": { "completed_at": at, .. }, .. } else {
    fail("no closing event")
  }
  "\{kind} completed_at \{at.stringify()}, the others unchanged \{others}"
}

///|
test "handing a Responses stream its waits sets the closing event's completed_at: the time received plus the waits, in whole seconds" {
  // The request is received at 1791815405.123 s; three pieces wait first,
  // then interval twice.
  let text = "Hi there!"
  inspect(
    [
      completed_at(text, _ => []),
      completed_at(text, reply => fixed_waits(reply, 0, 0)),
      completed_at(text, reply => fixed_waits(reply, 400, 238)),
      completed_at(text, reply => fixed_waits(reply, 400, 239)),
      completed_at(text, reply => fixed_waits(reply, 1877, 0)),
      completed_at(text, reply => fixed_waits(reply, 2147483647, 2147483647)),
      completed_at("", reply => fixed_waits(reply, 877, 0)),
    ].join("\n"),
    content=(
      #|response.completed completed_at 1791815405, the others unchanged true
      #|response.completed completed_at 1791815405, the others unchanged true
      #|response.completed completed_at 1791815405, the others unchanged true
      #|response.completed completed_at 1791815406, the others unchanged true
      #|response.completed completed_at 1791815407, the others unchanged true
      #|response.completed completed_at 1798257856, the others unchanged true
      #|response.completed completed_at 1791815406, the others unchanged true
    ),
  )
}

///|
test "handing an incomplete Responses stream its waits leaves every event as it was: completed_at stays null" {
  inspect(
    completed_at(
      "The weather in Paris is",
      reply => fixed_waits(reply, 2000, 500),
      stop_reason="max_output_tokens",
    ),
    content=(
      #|response.incomplete completed_at null, the others unchanged true
    ),
  )
}

///|
test "handing an Anthropic Messages stream its waits leaves every event as it was, since none depends on them" {
  let out = []
  for text in ["Hello! How can I assist you today?", ""] {
    let reply = @llm.reply(
      @llm.Declaration(api=AnthropicMessages),
      @llm.Strings(text~),
      request=Some({ "model": "claude-test", "stream": true }),
      now=received,
      ids=@llm.ids_generator(7),
    )
    let before = shown_events(reply)
    guard reply.body is Events(events) else { fail("not a stream") }
    let waits = FixedArray::make(events.length(), 0)
    for i, event in events {
      waits[i] = match event.wait {
        NoWait => 0
        First => 400
        Interval => 2147483647
      }
    }
    reply.complete(waits)
    out.push("\{text.escape()}: unchanged \{shown_events(reply) == before}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|"Hello! How can I assist you today?": unchanged true
      #|"": unchanged true
    ),
  )
}
