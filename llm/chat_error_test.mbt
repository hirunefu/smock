// Tests of the mid-stream error of an openai-chat reply through the
// package's public interface: where the stream is cut, the error data frame
// and its wait slot, and the ordinary reply to a request that does not
// stream. They run on native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one that
/// sets `stream: true`, for an `openai-chat` declaration whose mid-stream
/// error comes after `after` code points, with the type `kind` and the
/// message `message`, and whose strings are `strings`, as `shown` shows it.
fn chat_cut(
  strings : @llm.Strings,
  after~ : Int,
  kind? : String = "server_error",
  request? : Json? = Some({ "model": "test-model", "stream": true }),
  chunk_size? : Int,
) -> String {
  shown(
    @llm.reply(
      @llm.Declaration(
        api=OpenaiChat,
        chunk_size?,
        error=@llm.MidStreamError(after~, kind~),
      ),
      strings,
      request~,
      now=received,
      ids=@llm.ids_generator(7),
    ),
  )
}

///|
/// The message of the errors in these tests.
let overloaded : String = "The server had an error while processing your request. Sorry about that!"

///|
test "an error after 0 code points follows the opening chunk at once, in the first wait slot, and ends the stream with no closing chunk or [DONE]" {
  inspect(
    chat_cut(@llm.Strings(text="Hello!", error_message=overloaded), after=0),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}
      #|
    ),
  )
}

///|
test "an error inside a piece sends the text up to exactly after code points, the piece that holds the cut ending there, and waits as a next piece would" {
  inspect(
    chat_cut(
      @llm.Strings(
        text="Hello! How can I assist you today?",
        error_message=overloaded,
      ),
      after=6,
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"o!"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}
      #|
    ),
  )
}

///|
/// What each event of the stream that `chat_cut` gives carries, after its
/// wait slot, one per line: the opening chunk, a piece of the text, a tool
/// call's opening chunk or a piece of its arguments, the closing chunk, the
/// usage chunk, `[DONE]`, or the error frame as sent.
fn cut_events(
  strings : @llm.Strings,
  after~ : Int,
  chunk_size? : Int,
  request? : Json? = Some({ "model": "test-model", "stream": true }),
) -> String {
  let reply = @llm.reply(
    @llm.Declaration(
      api=OpenaiChat,
      chunk_size?,
      error=@llm.MidStreamError(after~, kind="server_error"),
    ),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { abort("the JSON reply") }
  let out = []
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let carries = match data {
      { "choices": [{ "delta": { "role": _, .. }, .. }], .. } => "opening"
      { "choices": [{ "delta": { "content": String(piece), .. }, .. }], .. } =>
        piece.escape()
      {
        "choices": [
          {
            "delta": {
              "tool_calls": [
                {
                  "index": k,
                  "function": { "arguments": String(piece), .. },
                  ..
                },
              ],
              ..
            },
            ..
          },
        ],
        ..
      } => "tool call \{k.stringify()}: \{piece.escape()}"
      { "choices": [{ "finish_reason": String(reason), .. }], .. } =>
        "closing: \{reason}"
      { "choices": [], "usage": _, .. } => "usage"
      _ => event.data
    }
    out.push("(\{slot(event.wait)}) \{carries}")
  }
  out.join("\n")
}

///|
test "an error at the end of the text follows every piece, in place of the closing chunk and [DONE]" {
  inspect(
    cut_events(@llm.Strings(text="Hello!", error_message="Overloaded"), after=6),
    content=(
      #|(none) opening
      #|(first) "Hell"
      #|(interval) "o!"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
    ),
  )
}

///|
test "an error before the tool calls follows the text, and no tool call is sent" {
  inspect(
    [
      cut_events(
        @llm.Strings(
          text="Let me check.",
          tool_calls=[weather()],
          error_message="Overloaded",
        ),
        after=13,
      ),
      cut_events(
        @llm.Strings(
          tool_calls=[weather(), weather(id="call_2")],
          error_message="Overloaded",
        ),
        after=0,
      ),
    ].join("\n---\n"),
    content=(
      #|(none) opening
      #|(first) "Let "
      #|(interval) "me c"
      #|(interval) "heck"
      #|(interval) "."
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
    ),
  )
}

///|
test "among explicit chunks an empty one counts 0 code points: those before the cut are sent, and the text stops at the piece that reaches after" {
  let chunks : ReadOnlyArray[String] = ["", "Hel", "", "lo", "", "!"]
  let strings = @llm.Strings(chunks~, error_message="Overloaded")
  inspect(
    [
      cut_events(strings, after=0),
      cut_events(strings, after=2),
      cut_events(strings, after=3),
      cut_events(strings, after=4),
      cut_events(strings, after=6),
    ].join("\n---\n"),
    content=(
      #|(none) opening
      #|(first) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) ""
      #|(interval) "He"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) ""
      #|(interval) "Hel"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) ""
      #|(interval) "Hel"
      #|(interval) ""
      #|(interval) "l"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) ""
      #|(interval) "Hel"
      #|(interval) ""
      #|(interval) "lo"
      #|(interval) ""
      #|(interval) "!"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
    ),
  )
}

///|
test "the cut is counted in code points, so it never splits one, whatever the chunk size" {
  inspect(
    [
      cut_events(
        @llm.Strings(text="👍🏽🇫🇷𝄞", error_message="Overloaded"),
        after=3,
        chunk_size=2,
      ),
      cut_events(
        @llm.Strings(
          text="天気は晴れです。",
          error_message="Overloaded",
        ),
        after=4,
        chunk_size=3,
      ),
      cut_events(
        @llm.Strings(
          text="天気は晴れです。",
          error_message="Overloaded",
        ),
        after=4,
        chunk_size=1,
      ),
    ].join("\n---\n"),
    content=(
      #|(none) opening
      #|(first) "👍🏽"
      #|(interval) "🇫"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) "天気は"
      #|(interval) "晴"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|---
      #|(none) opening
      #|(first) "天"
      #|(interval) "気"
      #|(interval) "は"
      #|(interval) "晴"
      #|(interval) {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
    ),
  )
}

///|
test "a request that asks for usage gets usage: null on the chunks before the error, and no usage chunk" {
  inspect(
    chat_cut(
      @llm.Strings(text="Hi", error_message="Overloaded"),
      after=2,
      request=Some({
        "model": "test-model",
        "stream": true,
        "stream_options": { "include_usage": true },
      }),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],"usage":null}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hi"},"logprobs":null,"finish_reason":null}],"usage":null}
      #|(interval) data: {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|
    ),
  )
}

///|
test "a request that does not stream gets the ordinary JSON reply, whole, with no error" {
  inspect(
    chat_cut(
      @llm.Strings(text="Hello!", error_message="Overloaded"),
      after=2,
      request=Some({ "model": "test-model" }),
    ),
    content=(
      #|Content-Type: application/json
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|{"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion","created":1791815405,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
    ),
  )
}

///|
test "the message and the type are sent as written, JSON-escaped" {
  inspect(
    chat_cut(
      @llm.Strings(text="Hi", error_message="Line 1\nsaid \"no\" é"),
      after=0,
      kind="rate_limit_exceeded",
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"error":{"message":"Line 1\nsaid \"no\" é","type":"rate_limit_exceeded","param":null,"code":null}}
      #|
    ),
  )
}

///|
test "for now, an openai-responses or anthropic-messages declaration with an error gives the reply it gives without one, streamed or not" {
  let reply_of = (api : @llm.Api, error : @llm.MidStreamError?, stream : Bool) => {
    shown(
      @llm.reply(
        @llm.Declaration(api~, error?),
        @llm.Strings(text="Hello!", error_message="Overloaded"),
        request=Some({ "model": "test-model", "stream": stream }),
        now=received,
        ids=@llm.ids_generator(7),
      ),
    )
  }
  let cut = @llm.MidStreamError(after=2, kind="overloaded_error")
  let apis : Array[@llm.Api] = [OpenaiResponses, AnthropicMessages]
  inspect(
    apis
    .map(api => {
      let same = [true, false].all(stream => {
        reply_of(api, Some(cut), stream) == reply_of(api, None, stream)
      })
      "\{api.name()}: \{same}"
    })
    .join("\n"),
    content=(
      #|openai-responses: true
      #|anthropic-messages: true
    ),
  )
}
