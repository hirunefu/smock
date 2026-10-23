// Tests of the mid-stream error of an openai-responses reply through the
// package's public interface: where the stream is cut, the `error` event,
// its `sequence_number` and its wait slot, and the ordinary reply to a
// request that does not stream. They run on native and on wasm-gc with the
// same output.

///|
/// The reply to a request whose body is `request`, by default one for
/// `gpt-6-astra` that sets `stream: true`, for an `openai-responses`
/// declaration whose mid-stream error comes after `after` code points, with
/// the code `code`, and whose strings are `strings`, with the chunk size
/// given.
fn responses_cut(
  strings : @llm.Strings,
  after~ : Int,
  code? : String = "server_error",
  request? : Json? = Some({ "model": "gpt-6-astra", "stream": true }),
  chunk_size? : Int,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(
      api=OpenaiResponses,
      chunk_size?,
      error=@llm.MidStreamError(after~, kind=code),
    ),
    strings,
    request~,
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
test "an error after 0 code points follows response.created and response.in_progress as event: error, numbered next, in the first wait slot, with no item and no closing event" {
  inspect(
    shown(
      responses_cut(
        @llm.Strings(text="Hello!", error_message="Something went wrong"),
        after=0,
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_5DTBZPrxiMH6i7M92iahxjWk
      #|(none) event: response.created data: {"type":"response.created","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}
      #|(none) event: response.in_progress data: {"type":"response.in_progress","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":1}
      #|(first) event: error data: {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":2}
      #|
    ),
  )
}

///|
/// The events of `reply`'s stream, one per line: each one's wait slot,
/// `event:` line and `sequence_number`, then the piece a delta carries, the
/// `output_index` and item type an added item carries, or the whole data
/// of an `error` event.
fn cut_outline(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let lines = []
  for event in events {
    let data = @json.parse(event.data)
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "-"
    }
    let carries = match data {
      { "type": "error", .. } => " \{event.data}"
      { "delta": String(piece), .. } => " \{piece.escape()}"
      { "output_index": index, "item": { "type": String(kind), .. }, .. } =>
        " @\{index.stringify()} \{kind}"
      _ => ""
    }
    lines.push(
      "(\{slot(event.wait)}) \{event.event.unwrap_or("-")} #\{number}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "an error inside a piece opens the message item and its part and sends the text up to exactly after code points, the piece that holds the cut ending there, then waits as a next piece would" {
  inspect(
    cut_outline(
      responses_cut(
        @llm.Strings(
          text="Hello! How can I assist you today?",
          error_message="Something went wrong",
        ),
        after=6,
      ),
    ),
    content=(
      #|(none) response.created #0
      #|(none) response.in_progress #1
      #|(none) response.output_item.added #2 @0 message
      #|(none) response.content_part.added #3
      #|(first) response.output_text.delta #4 "Hell"
      #|(interval) response.output_text.delta #5 "o!"
      #|(interval) error #6 {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":6}
    ),
  )
}
