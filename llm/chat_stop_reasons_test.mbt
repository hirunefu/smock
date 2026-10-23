// Tests of an openai-chat reply's stop reason through the package's public
// interface: written in the API's word, or derived. They run on native and
// on wasm-gc with the same output.

///|
/// The `finish_reason` of the JSON reply and of the stream's closing chunk
/// for an `openai-chat` declaration with `text` and the stop reason that
/// `written` writes, or none.
fn finish_reasons(written : String?, text? : String = "Hi") -> String {
  let stop_reason = written.map(word => {
    @llm.read_stop_reason(OpenaiChat, Json::string(word)).unwrap()
  })
  let declaration = @llm.Declaration(api=OpenaiChat, stop_reason?)
  let found = []
  let requests : Array[Json?] = [None, Some({ "stream": true })]
  for request in requests {
    let reply = @llm.reply(
      declaration,
      @llm.Strings(text~),
      request~,
      now=received,
      ids=@llm.ids_generator(7),
    )
    let datas = match reply.body {
      Json(body) => [@utf8.decode_lossy(body)]
      Events(events) => events.map(event => event.data)
    }
    let reasons = []
    for data in datas {
      let parsed = @json.parse(data) catch { _ => continue }
      if parsed is { "choices": [{ "finish_reason": String(reason), .. }], .. } {
        reasons.push(reason)
      }
    }
    found.push(reasons.join(" "))
  }
  "\{written.unwrap_or("left out")}: JSON \{found[0]}, stream \{found[1]}"
}

///|
test "a written stop reason is the finish_reason of the JSON reply and of the closing chunk, function_call among them" {
  inspect(
    [
      finish_reasons(Some("stop")),
      finish_reasons(Some("length")),
      finish_reasons(Some("tool_calls")),
      finish_reasons(Some("content_filter")),
      finish_reasons(Some("function_call")),
    ].join("\n"),
    content=(
      #|stop: JSON stop, stream stop
      #|length: JSON length, stream length
      #|tool_calls: JSON tool_calls, stream tool_calls
      #|content_filter: JSON content_filter, stream content_filter
      #|function_call: JSON function_call, stream function_call
    ),
  )
}

///|
test "left out, the stop reason is derived: stop, with text or without" {
  inspect(
    [finish_reasons(None), finish_reasons(None, text="")].join("\n"),
    content=(
      #|left out: JSON stop, stream stop
      #|left out: JSON stop, stream stop
    ),
  )
}
