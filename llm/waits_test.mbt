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
