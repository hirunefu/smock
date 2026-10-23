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
