// Tests of the openai-chat stream through the package's public interface:
// the reply to a request that sets `stream: true`. They run on native and
// on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one that sets
/// `stream: true`, for an `openai-chat` declaration with `text` and the
/// `id` and `model` given, as `shown` shows it.
fn chat_stream(
  text : String,
  request? : Json? = Some({ "model": "test-model", "stream": true }),
  id? : String,
  model? : String,
) -> String {
  shown(
    @llm.reply(
      @llm.Declaration(api=OpenaiChat),
      @llm.Strings(text~, id?, model?),
      request~,
      now=received,
      ids=@llm.ids_generator(7),
    ),
  )
}

///|
/// `reply` as these tests show it: the Content-Type smock sets, the
/// request-id header field it adds, then the body, or each event on a line
/// of its own, after its wait slot, with its `event:` line when it has one.
fn shown(reply : @llm.Reply) -> String {
  let out = StringBuilder()
  out.write_string("Content-Type: \{reply.content_type}\n")
  out.write_string("\{reply.request_id.0}: \{reply.request_id.1}\n")
  match reply.body {
    Json(body) => out.write_string(@utf8.decode_lossy(body))
    Events(events) =>
      for event in events {
        out.write_string("(\{slot(event.wait)}) ")
        if event.event is Some(name) {
          out.write_string("event: \{name} ")
        }
        out.write_string("data: \{event.data}\n")
      }
  }
  out.to_string()
}

///|
/// The name of a wait slot, as the spec gives it.
fn slot(wait : @llm.WaitSlot) -> String {
  match wait {
    NoWait => "none"
    First => "first"
    Interval => "interval"
  }
}

///|
test "a request with stream: true gets the text as chat.completion.chunk events: the opening chunk, a chunk per piece of 4 code points, the closing chunk, then [DONE]" {
  inspect(
    chat_stream("Hello! How can I assist you today?"),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"o! H"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"ow c"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"an I"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":" ass"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"ist "},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"you "},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"toda"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"y?"},"logprobs":null,"finish_reason":null}]}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
      #|(none) data: [DONE]
      #|
    ),
  )
}

///|
test "empty text sends the opening and closing chunks only, the closing one in the first wait slot, then [DONE]" {
  inspect(
    chat_stream(""),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
      #|(none) data: [DONE]
      #|
    ),
  )
}

///|
/// The first line of what `chat_stream` shows for a request whose body is
/// `request`: the Content-Type, which tells the stream from the JSON reply.
fn form(request : Json?) -> String {
  let shown = chat_stream("Hi", request~)
  shown[:shown.find("\n").unwrap()].to_owned()
}

///|
test "only a JSON object with stream exactly true gets the stream; any other request gets the JSON reply" {
  inspect(
    [
      "true: \{form(Some({ "stream": true }))}",
      "false: \{form(Some({ "stream": false }))}",
      "\"true\": \{form(Some({ "stream": "true" }))}",
      "1: \{form(Some({ "stream": 1 }))}",
      "missing: \{form(Some({ "model": "test-model" }))}",
      "nested: \{form(Some({ "stream_options": { "stream": true } }))}",
      "an array: \{form(Some([{ "stream": true }]))}",
      "not JSON: \{form(None)}",
    ].join("\n"),
    content=(
      #|true: Content-Type: text/event-stream
      #|false: Content-Type: application/json
      #|"true": Content-Type: application/json
      #|1: Content-Type: application/json
      #|missing: Content-Type: application/json
      #|nested: Content-Type: application/json
      #|an array: Content-Type: application/json
      #|not JSON: Content-Type: application/json
    ),
  )
}

///|
/// The events of the stream of an `openai-chat` declaration with `text`.
fn stream_events(text : String) -> Array[@llm.Event] {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text~),
    request=Some({ "stream": true }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  match reply.body {
    Events(events) => events
    Json(_) => abort("the JSON reply")
  }
}

///|
/// The pieces that the stream of `text` carries, in order: the content of
/// each chunk after the opening one.
fn stream_pieces(text : String) -> Array[String] {
  let pieces = []
  for event in stream_events(text) {
    let chunk = @json.parse(event.data) catch { _ => continue }
    match chunk {
      {
        "choices": [{ "delta": { "content": String(piece), .. } as delta, .. }],
        ..
      } if !(delta is Object(members) && members.contains("role")) =>
        pieces.push(piece)
      _ => ()
    }
  }
  pieces
}

///|
test "pieces hold 4 code points, the last one shorter, never split a code point, and join to exactly the text" {
  let texts = [
    "Hello!", "天気は晴れです。", "Done 👍🏽 🇫🇷", "𝄞 and 𠀋, outside the Basic Multilingual Plane",
    "Hi 🇫🇷!", "a \"quote\",\na line break", "1234", "12345", "x",
  ]
  let out = []
  for text in texts {
    let pieces = stream_pieces(text)
    guard pieces.join("") == text else {
      fail("\{@debug.to_string(pieces)} do not join to \{text}")
    }
    out.push(pieces.map(piece => piece.escape()).join(" | "))
  }
  inspect(
    out.join("\n"),
    content=(
      #|"Hell" | "o!"
      #|"天気は晴" | "れです。"
      #|"Done" | " 👍🏽 " | "🇫🇷"
      #|"𝄞 an" | "d 𠀋," | " out" | "side" | " the" | " Bas" | "ic M" | "ulti" | "ling" | "ual " | "Plan" | "e"
      #|"Hi 🇫" | "🇷!"
      #|"a \"q" | "uote" | "\",\na" | " lin" | "e br" | "eak"
      #|"1234"
      #|"1234" | "5"
      #|"x"
    ),
  )
}

///|
test "every data: line is one line of valid UTF-8 with no event: line, and [DONE] comes last" {
  for
    text in [
      "", "Hello!", "天気は晴れです。", "Done 👍🏽 🇫🇷", "𝄞𠀋𝄞𠀋𝄞",
      "a\nb\r\nc",
    ] {
    let events = stream_events(text)
    for i, event in events {
      guard event.event is None else {
        fail("an event: line in \{text.escape()}")
      }
      guard !event.data.contains("\n") && !event.data.contains("\r") else {
        fail("a line break in \{event.data.escape()}")
      }
      let decoded = @utf8.decode(@utf8.encode(event.data)) catch {
        _ => fail("not valid UTF-8: \{event.data.escape()}")
      }
      guard decoded == event.data else {
        fail("not valid UTF-8: \{event.data.escape()}")
      }
      guard (event.data == "[DONE]") == (i == events.length() - 1) else {
        fail("[DONE] is not last alone in \{text.escape()}")
      }
    }
  }
}

///|
/// The wait slots of the stream of `text`, in order.
fn slots(text : String) -> String {
  stream_events(text).map(event => slot(event.wait)).join(", ")
}

///|
test "the first piece takes the first wait slot and each later one the interval; opening and closing events take none, unless no piece came before" {
  inspect(
    [
      "empty: \{slots("")}",
      "one piece: \{slots("Hi")}",
      "three pieces: \{slots("Hello, world")}",
    ].join("\n"),
    content=(
      #|empty: none, first, none
      #|one piece: none, first, none, none
      #|three pieces: none, first, interval, interval, none, none
    ),
  )
}

///|
test "model fixes the model of every chunk, whatever the request's model" {
  inspect(
    chat_stream(
      "Hi",
      request=Some({ "model": "gpt-6-astra", "stream": true }),
      model="test-model",
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hi"},"logprobs":null,"finish_reason":null}]}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
      #|(none) data: [DONE]
      #|
    ),
  )
}
