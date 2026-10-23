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
