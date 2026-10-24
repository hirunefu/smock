// Tests of a reply's ids through the package's public interface: the
// reply's id, generated or fixed, and the request-id header field smock
// adds. They run on native and on wasm-gc with the same output.

///|
/// The ids of the reply to a request whose body is `request`, for an
/// `openai-chat` declaration with the `id` given, and ids drawn from the
/// generator of the draw `draw`: the request-id header field smock adds,
/// then the id of the JSON reply, or of each chunk of the stream, each on a
/// line of its own.
fn reply_ids(request : Json?, id? : String, draw~ : UInt64 = 7) -> String {
  let reply = @llm.reply(
    @llm.Declaration(api=OpenaiChat),
    @llm.Strings(text="Hi there", id?),
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
  let lines = ["\{reply.request_id.0}: \{reply.request_id.1}"]
  match reply.body {
    Json(body) => lines.push("JSON: \{id_member(@utf8.decode_lossy(body))}")
    Events(events) =>
      for event in events {
        lines.push("chunk: \{id_member(event.data)}")
      }
  }
  lines.join("\n")
}

///|
/// The `id` member of the JSON object `text`, as compact JSON, or `text`
/// itself when it is not an object with one, such as `[DONE]`.
fn id_member(text : String) -> String {
  let value = @json.parse(text) catch { _ => return text }
  match value {
    { "id": id, .. } => id.stringify()
    _ => text
  }
}

///|
test "id fixes the reply's id, sent as written in the JSON reply, and the request id stays as it was" {
  inspect(
    [reply_ids(None), reply_ids(None, id="chatcmpl-test-1")].join(
      "\n--- with id: chatcmpl-test-1\n",
    ),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|JSON: "chatcmpl-KCVauEuclT08Mg4CWd55sNbz"
      #|--- with id: chatcmpl-test-1
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|JSON: "chatcmpl-test-1"
    ),
  )
}

///|
test "a fixed id is the id of every chunk of the stream, as written, and the request id stays as it was" {
  let stream : Json? = Some({ "stream": true })
  inspect(
    [reply_ids(stream), reply_ids(stream, id="chatcmpl-test-1")].join(
      "\n--- with id: chatcmpl-test-1\n",
    ),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|chunk: "chatcmpl-KCVauEuclT08Mg4CWd55sNbz"
      #|chunk: "chatcmpl-KCVauEuclT08Mg4CWd55sNbz"
      #|chunk: "chatcmpl-KCVauEuclT08Mg4CWd55sNbz"
      #|chunk: "chatcmpl-KCVauEuclT08Mg4CWd55sNbz"
      #|chunk: [DONE]
      #|--- with id: chatcmpl-test-1
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: "chatcmpl-test-1"
      #|chunk: [DONE]
    ),
  )
}

///|
test "a fixed id takes no prefix and is JSON-escaped on the wire, whatever it holds" {
  inspect(
    [
      reply_ids(None, id=""),
      reply_ids(None, id="a \"quoted\" id, 天気\n"),
      reply_ids(Some({ "stream": true }), id="a \"quoted\" id, 天気\n"),
    ].join("\n"),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|JSON: ""
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|JSON: "a \"quoted\" id, 天気\n"
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|chunk: "a \"quoted\" id, 天気\n"
      #|chunk: "a \"quoted\" id, 天気\n"
      #|chunk: "a \"quoted\" id, 天気\n"
      #|chunk: "a \"quoted\" id, 天気\n"
      #|chunk: [DONE]
    ),
  )
}

///|
/// The slot `n` of the ids the draw `draw` gives, counted from 0, as the
/// spec orders them: each slot is 24 characters from A-Z, a-z and 0-9, each
/// one a draw below 62 from the ids generator, and the slots draw one after
/// another.
fn slot_id(draw : UInt64, n : Int32) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".to_array()
  let ids = @llm.ids_generator(draw)
  let mut id = ""
  for slot in 0..<=n {
    let out = StringBuilder()
    for _ in 0..<24 {
      out.write_char(alphabet[ids.below(62).to_int()])
    }
    if slot == n {
      id = out.to_string()
    }
  }
  id
}

///|
test "the request id is x-request-id: req_ and the last slot, after the reply's and the Responses message item's" {
  for draw in 0UL..<50UL {
    let shown = reply_ids(None, draw~)
    let expected = "x-request-id: req_\{slot_id(draw, 2)}\nJSON: \"chatcmpl-\{slot_id(draw, 0)}\""
    guard shown == expected else { fail("draw \{draw}: \{shown}") }
  }
}

///|
test "the same draw gives the same request id, the JSON reply as the stream, and another draw another one" {
  let header = (request : Json?, draw : UInt64) => {
    let shown = reply_ids(request, draw~)
    shown[:shown.find("\n").unwrap()].to_owned()
  }
  inspect(
    [header(None, 7), header(Some({ "stream": true }), 7), header(None, 8)].join(
      "\n",
    ),
    content=(
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|x-request-id: req_23m4SYY5j0dNweGBYvVJCktv
    ),
  )
}
