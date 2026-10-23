// Tests of the openai-chat wire form through the package's public
// interface. They run on native and on wasm-gc with the same output.

///|
/// 2026-10-12T14:30:05.123Z, the time every request in these tests is
/// received at.
let received : Int64 = 1_791_815_405_123L

///|
/// The reply to a request whose body is `request`, for an `openai-chat`
/// declaration with `text`, and ids drawn from the generator of the draw
/// `draw`: the Content-Type smock sets, then the body.
fn chat(
  text : String,
  request? : Json? = Some({ "model": "test-model" }),
  draw? : UInt64 = 7,
) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text~),
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
  "Content-Type: \{reply.content_type}\n\{json_text(reply)}"
}

///|
/// The JSON reply of `reply` as text, or `(events)` for the stream.
fn json_text(reply : @llm.Reply) -> String {
  match reply.body {
    Json(body) => @utf8.decode_lossy(body)
    Events(_) => "(events)"
  }
}

///|
test "an openai-chat reply is one chat.completion body, with the text as the assistant's content" {
  inspect(
    chat("Hello! How can I assist you today?"),
    content=(
      #|Content-Type: application/json
      #|{"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! How can I assist you today?","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
    ),
  )
}

///|
/// The `content` of the reply to an `openai-chat` declaration with `text`,
/// as compact JSON writes it.
fn content(text : String) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text~),
    request=None,
    now=received,
    ids=@llm.ids_generator(7),
  )
  let body = json_text(reply)
  let start = body.find("\"content\":").unwrap() + "\"content\":".length()
  let end = body.find(",\"refusal\"").unwrap()
  body[start:end].to_owned()
}

///|
test "the content is the text, in UTF-8 as written, and the empty string when the text is empty" {
  inspect(
    [
      content(""),
      content("天気は晴れです。"),
      content("Done 👍🏽 🇫🇷"),
      content("𝄞 and 𠀋, outside the Basic Multilingual Plane"),
      content("a \"quote\", a back\\slash,\na line break and a\ttab"),
    ].join("\n"),
    content=(
      #|""
      #|"天気は晴れです。"
      #|"Done 👍🏽 🇫🇷"
      #|"𝄞 and 𠀋, outside the Basic Multilingual Plane"
      #|"a \"quote\", a back\\slash,\na line break and a\ttab"
    ),
  )
}

///|
/// The reply's id to a request whose one draw is `draw`.
fn reply_id(draw : UInt64) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text=""),
    request=None,
    now=received,
    ids=@llm.ids_generator(draw),
  )
  let body = json_text(reply)
  let start = "{\"id\":\"".length()
  body[start:body.find("\",\"object\"").unwrap()].to_owned()
}

///|
test "the reply's id is chatcmpl- and 24 characters from A-Z, a-z and 0-9" {
  let seen = Map([])
  for draw in 0UL..<200UL {
    let id = reply_id(draw)
    guard id.has_prefix("chatcmpl-") && id.length() == 9 + 24 else {
      fail("id \{id}")
    }
    for c in id[9:] {
      guard (c >= 'A' && c <= 'Z') ||
        (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') else {
        fail("id \{id}")
      }
      seen[c] = true
    }
  }
  // 4,800 characters drawn: every one of the 62 shows up.
  inspect(seen.length(), content="62")
}

///|
test "the same draw gives the same id, and another draw another one" {
  inspect(
    [reply_id(7), reply_id(7), reply_id(8)].join("\n"),
    content=(
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|chatcmpl-KCVauEuclT08Mg4CWd55sNbz
      #|chatcmpl-u76DvnZi1R3iOEH1RcaznueA
    ),
  )
}

///|
/// The reply's `model` and `created` for a request whose body is `request`,
/// received at `now`.
fn model_and_created(request : Json?, now? : Int64 = received) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text=""),
    request~,
    now~,
    ids=@llm.ids_generator(7),
  )
  let body = json_text(reply)
  let start = body.find(",\"created\"").unwrap() + 1
  body[start:body.find(",\"choices\"").unwrap()].to_owned()
}

///|
test "the model is the request's model when it is a string, otherwise the empty string" {
  inspect(
    [
      model_and_created(Some({ "model": "gpt-6-astra", "messages": [] })),
      model_and_created(Some({ "model": "" })),
      model_and_created(Some({ "model": 4 })),
      model_and_created(Some({ "model": ["a"] })),
      model_and_created(Some({ "messages": [] })),
      model_and_created(Some(["model"])),
      model_and_created(None),
    ].join("\n"),
    content=(
      #|"created":1791815405,"model":"gpt-6-astra"
      #|"created":1791815405,"model":""
      #|"created":1791815405,"model":""
      #|"created":1791815405,"model":""
      #|"created":1791815405,"model":""
      #|"created":1791815405,"model":""
      #|"created":1791815405,"model":""
    ),
  )
}

///|
test "created is the time the request was received, in whole seconds" {
  inspect(
    [
      model_and_created(None, now=0L),
      model_and_created(None, now=999L),
      model_and_created(None, now=1_000L),
      model_and_created(None, now=1_792_713_600_999L),
    ].join("\n"),
    content=(
      #|"created":0,"model":""
      #|"created":0,"model":""
      #|"created":1,"model":""
      #|"created":1792713600,"model":""
    ),
  )
}
