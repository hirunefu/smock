// Tests of an openai-chat reply's usage through the package's public
// interface: the counts in the JSON reply, and the usage chunk of a stream
// whose request sets `stream_options.include_usage`. They run on native and
// on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, for an `openai-chat`
/// declaration with `text` and the usage `usage`: what `chat_stream` shows.
fn chat_with_usage(
  text : String,
  usage : @llm.Usage,
  request~ : Json?,
) -> String {
  shown(
    @llm.reply(
      @llm.Declaration(api=OpenaiChat, usage~),
      @llm.Strings(text~),
      request~,
      now=received,
      ids=@llm.ids_generator(7),
    ),
  )
}

///|
/// The `usage` of the JSON reply to an `openai-chat` declaration with the
/// usage `usage`, as compact JSON writes it.
fn usage_member(usage : @llm.Usage) -> String {
  let body = chat_with_usage("Hi", usage, request=None)
  let start = body.find("\"usage\":").unwrap() + "\"usage\":".length()
  let end = body.find(",\"service_tier\"").unwrap()
  body[start:end].to_owned()
}

///|
test "the JSON reply's usage gives the declared counts as prompt and completion tokens, their total, and the example's detail objects with zero counts" {
  inspect(
    usage_member(@llm.Usage(input=31, output=18)),
    content=(
      #|{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}
    ),
  )
}

///|
/// The counts of the JSON reply's usage for the usage `usage`: prompt,
/// completion and total tokens.
fn counts(usage : @llm.Usage) -> String {
  let text = usage_member(usage)
  text[:text.find(",\"prompt_tokens_details\"").unwrap()].to_owned() + "}"
}

///|
test "the total is the sum of the counts, written exactly up to twice the largest count" {
  let max = @llm.max_token_count
  inspect(
    [
      counts(@llm.Usage(input=0, output=0)),
      counts(@llm.Usage(input=1, output=0)),
      counts(@llm.Usage(input=0, output=1)),
      counts(@llm.Usage(input=max, output=0)),
      counts(@llm.Usage(input=max, output=2)),
      counts(@llm.Usage(input=max, output=max)),
    ].join("\n"),
    content=(
      #|{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}
      #|{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}
      #|{"prompt_tokens":0,"completion_tokens":1,"total_tokens":1}
      #|{"prompt_tokens":9007199254740991,"completion_tokens":0,"total_tokens":9007199254740991}
      #|{"prompt_tokens":9007199254740991,"completion_tokens":2,"total_tokens":9007199254740993}
      #|{"prompt_tokens":9007199254740991,"completion_tokens":9007199254740991,"total_tokens":18014398509481982}
    ),
  )
}

///|
test "a stream whose request sets stream_options.include_usage to true gets usage: null on every chunk, then a usage chunk with no choice after the closing one, then [DONE]" {
  inspect(
    chat_with_usage(
      "Hello!",
      @llm.Usage(input=31, output=18),
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
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}],"usage":null}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{"content":"o!"},"logprobs":null,"finish_reason":null}],"usage":null}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}],"usage":null}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"test-model","choices":[],"usage":{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}
      #|(none) data: [DONE]
      #|
    ),
  )
}

///|
/// How the stream to a request whose body is `request` places the usage:
/// how many of its chunks carry a `usage` member, and of those, how many
/// give `null`, and whether a chunk with no choice comes before `[DONE]`.
fn usage_places(request : Json) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat, usage=@llm.Usage(input=3, output=5)),
    @llm.Strings(text="Hello!"),
    request=Some(request),
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { return "the JSON reply" }
  let mut chunks = 0
  let mut with_usage = 0
  let mut nulls = 0
  let mut usage_chunk = "none"
  for event in events {
    let chunk = @json.parse(event.data) catch { _ => continue }
    chunks += 1
    guard chunk is Object(members) else { continue }
    match members.get("usage") {
      Some(Null) => {
        with_usage += 1
        nulls += 1
      }
      Some(usage) => {
        with_usage += 1
        if members.get("choices") is Some(Array([])) {
          usage_chunk = usage.stringify()
        }
      }
      None => ()
    }
  }
  "\{with_usage} of \{chunks} chunks with usage, \{nulls} null; usage chunk: \{usage_chunk}"
}

///|
test "only stream_options.include_usage exactly true asks for usage; any other streamed request gets no usage member and no usage chunk" {
  inspect(
    [
      "true: " +
      usage_places({
        "stream": true,
        "stream_options": { "include_usage": true },
      }),
      "false: " +
      usage_places({
        "stream": true,
        "stream_options": { "include_usage": false },
      }),
      "\"true\": " +
      usage_places({
        "stream": true,
        "stream_options": { "include_usage": "true" },
      }),
      "no include_usage: " +
      usage_places({ "stream": true, "stream_options": {} }),
      "no stream_options: " + usage_places({ "stream": true }),
      "stream_options not an object: " +
      usage_places({ "stream": true, "stream_options": [true] }),
      "include_usage beside stream_options: " +
      usage_places({ "stream": true, "include_usage": true }),
      "no stream: " +
      usage_places({ "stream_options": { "include_usage": true } }),
    ].join("\n"),
    content=(
      #|true: 5 of 5 chunks with usage, 4 null; usage chunk: {"prompt_tokens":3,"completion_tokens":5,"total_tokens":8,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}
      #|false: 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|"true": 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|no include_usage: 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|no stream_options: 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|stream_options not an object: 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|include_usage beside stream_options: 0 of 4 chunks with usage, 0 null; usage chunk: none
      #|no stream: the JSON reply
    ),
  )
}

///|
/// The wait slots of the stream of `text` to a request that asks for usage,
/// in order.
fn usage_slots(text : String) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text~),
    request=Some({ "stream": true, "stream_options": { "include_usage": true } }),
    now=received,
    ids=@llm.ids_generator(7),
  )
  guard reply.body is Events(events) else { return "the JSON reply" }
  events.map(event => slot(event.wait)).join(", ")
}

///|
test "the usage chunk takes no wait, even in a reply with no piece, whose closing chunk takes the first wait slot" {
  inspect(
    [
      "empty: \{usage_slots("")}",
      "one piece: \{usage_slots("Hi")}",
      "three pieces: \{usage_slots("Hello, world")}",
    ].join("\n"),
    content=(
      #|empty: none, first, none, none
      #|one piece: none, first, none, none, none
      #|three pieces: none, first, interval, interval, none, none, none
    ),
  )
}
