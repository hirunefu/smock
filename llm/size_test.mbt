// Tests of the size bound through the package's public interface: the
// encoded reply, the JSON body or every event of the stream as it is sent,
// measured against 1 MiB, for each request and at load. Each test crosses
// the bound with the smallest input that does, in few events. They run on
// native and on wasm-gc with the same output.

///|
/// The reply of a declaration of `api`, by default `openai-chat`, with the
/// strings `strings`, to a request whose body is `request`, by default a
/// JSON request that does not stream.
fn sized_reply(
  strings : @llm.Strings,
  api? : @llm.Api = OpenaiChat,
  chunk_size? : Int,
  request? : Json? = Some({ "model": "test-model" }),
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(api~, chunk_size?),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
/// What `check_size` says of `reply`: `ok`, or the message.
fn verdict(reply : @llm.Reply) -> String {
  match reply.check_size() {
    Ok(_) => "ok"
    Err(message) => message
  }
}

///|
/// `count` copies of `text`.
fn repeated(text : String, count : Int) -> String {
  let out = StringBuilder(size_hint=text.length() * count)
  for _ in 0..<count {
    out.write_string(text)
  }
  out.to_string()
}

///|
/// Text that takes `bytes` bytes of UTF-8 as a reply carries it: as many
/// two-byte characters (é) as fit, and ASCII after them, so that it takes
/// fewer UTF-16 code units than bytes.
fn text_of_bytes(bytes : Int) -> String {
  repeated("é", bytes / 2) + repeated("a", bytes % 2)
}

///|
/// The bytes of the JSON body of `reply`, or `not written` when it has
/// none.
fn json_bytes(reply : @llm.Reply) -> String {
  match reply.body {
    Json(body) if body.length() > 0 => body.length().to_string()
    _ => "not written"
  }
}

///|
test "a JSON reply of exactly 1 MiB of UTF-8 is within the bound, and one byte more is over it and not written" {
  // The model takes one byte more in the second reply.
  let empty = sized_reply(@llm.Strings(model="m"))
  guard empty.body is Json(overhead) else { abort("not JSON") }
  let text = text_of_bytes(1_048_576 - overhead.length())
  let at_bound = sized_reply(@llm.Strings(text~, model="m"))
  let over = sized_reply(@llm.Strings(text~, model="mm"))
  inspect(
    "\{json_bytes(at_bound)}: \{verdict(at_bound)}\n\{json_bytes(over)}: \{verdict(over)}",
    content=(
      #|1048576: ok
      #|not written: the reply takes more than 1 MiB as a JSON body
    ),
  )
}

///|
/// The bytes `reply` takes on the wire, counted here as a client reads
/// them: the JSON body, or each event as an `event:` line when it has a
/// type, a `data:` line and a blank line, in UTF-8.
fn wire_bytes(reply : @llm.Reply) -> Int {
  match reply.body {
    Json(body) => body.length()
    Events(events) => {
      let mut bytes = 0
      for event in events {
        let lines = match event.event {
          Some(name) => "event: \{name}\ndata: \{event.data}\n\n"
          None => "data: \{event.data}\n\n"
        }
        bytes += @utf8.encode(lines).length()
      }
      bytes
    }
  }
}

///|
/// The strings of one piece, whose stream, the reply of a declaration of
/// `api` to a request whose body is `request`, by default one that sets
/// `stream: true`, takes exactly `bytes` bytes on the wire. The piece is
/// text of two-byte characters and ASCII. The model, the request's when it
/// takes no byte, takes the bytes the text cannot, since a Responses stream
/// carries the text five times and the model three.
fn strings_of_bytes(
  api : @llm.Api,
  bytes : Int,
  request? : Json = { "stream": true },
) -> @llm.Strings {
  let strings = (text : Int, model : Int) => {
    @llm.Strings(
      chunks=[text_of_bytes(text)],
      model?=if model > 0 { Some(repeated("m", model)) } else { None },
    )
  }
  let size = (text : Int, model : Int) => {
    wire_bytes(sized_reply(strings(text, model), api~, request=Some(request)))
  }
  // What one more byte of the text and of the model add, and what the
  // rest takes. The text is never empty, since a Messages stream sends no
  // block for empty text.
  let per_text = size(2, 0) - size(1, 0)
  let per_model = size(1, 1) - size(1, 0)
  let overhead = size(1, 0) - per_text
  let mut model = 0
  while (bytes - overhead - model * per_model) % per_text != 0 {
    model += 1
  }
  strings((bytes - overhead - model * per_model) / per_text, model)
}

///|
test "a stream of exactly 1 MiB is within the bound, and one byte more is over it, counted in UTF-8 as the events are sent, event: lines included" {
  let out = []
  let streamed : Json? = Some({ "stream": true })
  for api in [@llm.Api::OpenaiChat, OpenaiResponses, AnthropicMessages] {
    let at_bound = sized_reply(
      strings_of_bytes(api, 1_048_576),
      api~,
      request=streamed,
    )
    let over = sized_reply(
      strings_of_bytes(api, 1_048_577),
      api~,
      request=streamed,
    )
    out.push(
      "\{api.name()}: \{wire_bytes(at_bound)}: \{verdict(at_bound)}; one byte more: \{verdict(over)}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|openai-chat: 1048576: ok; one byte more: the reply takes more than 1 MiB as a stream
      #|openai-responses: 1048576: ok; one byte more: the reply takes more than 1 MiB as a stream
      #|anthropic-messages: 1048576: ok; one byte more: the reply takes more than 1 MiB as a stream
    ),
  )
}

///|
/// What becomes of `reply`, a stream over the bound, as the test shows it:
/// its verdict, and whether it was cut short once it passed 1 MiB, so that
/// it passes the bound by less than its largest event.
fn cut_short(reply : @llm.Reply) -> String {
  guard reply.body is Events(events) else { return "not a stream" }
  let mut largest = 0
  for event in events {
    let bytes = @utf8.encode(event.data).length() + 64
    if bytes > largest {
      largest = bytes
    }
  }
  let past = wire_bytes(reply) - 1_048_576
  "\{verdict(reply)}; cut short: \{past > 0 && past <= largest}"
}

///|
test "a stream that passes the bound is cut short soon after, so a long text, long arguments or a long model is never encoded whole" {
  let streamed : Json? = Some({ "stream": true })
  // Each one would take 2 MiB or more as a whole stream.
  let long_text = @llm.Strings(text=repeated("a", 20_000))
  let out = []
  for api in [@llm.Api::OpenaiChat, OpenaiResponses, AnthropicMessages] {
    let reply = sized_reply(long_text, api~, chunk_size=1, request=streamed)
    out.push("\{api.name()}, a long text: \{cut_short(reply)}")
  }
  let call = @llm.ToolCall(
    name="f",
    arguments=Json::string(repeated("a", 20_000)),
  )
  let long_arguments = sized_reply(
    @llm.Strings(tool_calls=[call]),
    chunk_size=1,
    request=streamed,
  )
  out.push("openai-chat, long arguments: \{cut_short(long_arguments)}")
  let long_arguments = sized_reply(
    @llm.Strings(tool_calls=[call]),
    api=OpenaiResponses,
    chunk_size=1,
    request=streamed,
  )
  out.push("openai-responses, long arguments: \{cut_short(long_arguments)}")
  let long_model = sized_reply(
    @llm.Strings(text=repeated("a", 400), model=repeated("m", 10_000)),
    chunk_size=1,
    request=streamed,
  )
  out.push("openai-chat, a long model: \{cut_short(long_model)}")
  inspect(
    out.join("\n"),
    content=(
      #|openai-chat, a long text: the reply takes more than 1 MiB as a stream; cut short: true
      #|openai-responses, a long text: the reply takes more than 1 MiB as a stream; cut short: true
      #|anthropic-messages, a long text: the reply takes more than 1 MiB as a stream; cut short: true
      #|openai-chat, long arguments: the reply takes more than 1 MiB as a stream; cut short: true
      #|openai-responses, long arguments: the reply takes more than 1 MiB as a stream; cut short: true
      #|openai-chat, a long model: the reply takes more than 1 MiB as a stream; cut short: true
    ),
  )
}

///|
/// What the load check says of `strings` on a declaration of `api`, by
/// default `openai-chat`, with the chunk size `chunk_size`: `ok`, or the
/// message.
fn at_load(
  strings : @llm.Strings,
  api? : @llm.Api = OpenaiChat,
  chunk_size? : Int,
) -> String {
  match @llm.check_reply_size(@llm.Declaration(api~, chunk_size?), strings) {
    Ok(_) => "ok"
    Err(message) => message
  }
}

///|
test "at load, a reply as written is encoded as the JSON reply and as a stream, and either one over the bound is a load error" {
  let short = @llm.Strings(text=repeated("a", 6_000))
  inspect(
    [
      "6,000 characters: \{at_load(short)}",
      "6,000 characters in pieces of 1: \{at_load(short, chunk_size=1)}",
      "1 MiB: \{at_load(@llm.Strings(text=repeated("a", 1_048_576)))}",
    ].join("\n"),
    content=(
      #|6,000 characters: ok
      #|6,000 characters in pieces of 1: the reply takes more than 1 MiB as a stream
      #|1 MiB: the reply takes more than 1 MiB as a JSON body and as a stream
    ),
  )
}

///|
test "at load, the stream is the one a request with stream and stream_options.include_usage true gets, with no model of its own" {
  let with_usage : Json = {
    "stream": true,
    "stream_options": { "include_usage": true },
  }
  let at_bound = strings_of_bytes(OpenaiChat, 1_048_576, request=with_usage)
  let over = strings_of_bytes(OpenaiChat, 1_048_577, request=with_usage)
  let without_usage = sized_reply(over, request=Some({ "stream": true }))
  let with_model = sized_reply(
    at_bound,
    request=Some({
      "model": "m",
      "stream": true,
      "stream_options": { "include_usage": true },
    }),
  )
  inspect(
    [
      "at the bound: \{at_load(at_bound)}",
      "one byte over: \{at_load(over)}",
      "the same strings, without the usage chunk: \{verdict(without_usage)}",
      "the strings at the bound, to a request that gives a model: \{verdict(with_model)}",
    ].join("\n"),
    content=(
      #|at the bound: ok
      #|one byte over: the reply takes more than 1 MiB as a stream
      #|the same strings, without the usage chunk: ok
      #|the strings at the bound, to a request that gives a model: the reply takes more than 1 MiB as a stream
    ),
  )
}
