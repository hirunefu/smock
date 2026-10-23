// Seam 1 tests of how an LLM response's text is cut into pieces: the plan
// of a Stub whose `llm` gives `chunkSize` or `chunks`.

///|
/// A Mock `openai` whose LLM Stubs answer Chat Completions requests: on
/// `/size-1` with pieces of one code point, on `/chunks` with the pieces
/// `chunks` gives, an empty one among them, and on `/default` with pieces
/// of the default size.
let chunks_mock : (String, String) = (
  "openai.yaml",
  (
    #|mocks: [{ name: openai, hosts: [api.openai.test] }]
    #|stubs:
    #|  - id: size-1
    #|    mock: openai
    #|    request: { path: /size-1 }
    #|    response: { status: 200, llm: { api: openai-chat, text: 天気は👍🏽, chunkSize: 1 } }
    #|  - id: chunks
    #|    mock: openai
    #|    request: { path: /chunks }
    #|    response: { status: 200, llm: { api: openai-chat, chunks: [Hel, "", "lo 👍🏽"], chunkSize: 1 } }
    #|  - id: default
    #|    mock: openai
    #|    request: { path: /default }
    #|    response: { status: 200, llm: { api: openai-chat, text: 天気は晴れです。 } }
  ),
)

///|
/// The content of each chunk after the opening one in the stream that
/// `outcome` plans, in order, each one escaped.
fn streamed_pieces(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "(not a stream)" }
  let pieces = []
  for event in events {
    let chunk = @json.parse(event.data) catch { _ => continue }
    match chunk {
      {
        "choices": [{ "delta": { "content": String(piece), .. } as delta, .. }],
        ..
      } if !(delta is Object(members) && members.contains("role")) =>
        pieces.push(piece.escape())
      _ => ()
    }
  }
  pieces.join(" | ")
}

///|
test "a stream sends the text in pieces of chunkSize code points, or in the pieces chunks gives, an empty one included" {
  let h = harness([chunks_mock])
  let stream = "{\"stream\":true}"
  inspect(
    [
      "size 1: \{streamed_pieces(h.chat(path="/size-1", body=stream))}",
      "chunks: \{streamed_pieces(h.chat(path="/chunks", body=stream))}",
      "default: \{streamed_pieces(h.chat(path="/default", body=stream))}",
    ].join("\n"),
    content=(
      #|size 1: "天" | "気" | "は" | "👍" | "🏽"
      #|chunks: "Hel" | "" | "lo 👍🏽"
      #|default: "天気は晴" | "れです。"
    ),
  )
}

///|
test "the JSON reply carries the whole text, the join of chunks when they give it" {
  let h = harness([chunks_mock])
  inspect(
    [
      "size 1: \{reply_content(h.chat(path="/size-1"))}",
      "chunks: \{reply_content(h.chat(path="/chunks"))}",
    ].join("\n"),
    content=(
      #|size 1: 天気は👍🏽
      #|chunks: Hello 👍🏽
    ),
  )
}
