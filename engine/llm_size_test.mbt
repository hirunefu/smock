// Seam 1 tests of the size bound of LLM responses for each request: a
// reply that a template or a long request value pushes over 1 MiB once
// encoded gets the 500 `template failed`, with `at` at the `llm` field,
// and no stream.

///|
/// The status of `outcome`, and its error body, or the Content-Type of a
/// reply, with the template error the Journal records.
fn bounded(outcome : @engine.Outcome) -> String {
  let journaled = match outcome.journal {
    Some({ template_error: Some(error), .. }) =>
      "; journal: \{error.at}: \{error.message}"
    _ => ""
  }
  let shown = match outcome.plan.body {
    Bytes(body) if outcome.plan.status == 500 => @utf8.decode_lossy(body)
    Bytes(_) => "JSON"
    Events(_) => "stream"
  }
  "\{outcome.plan.status} \{shown}\{journaled}"
}

///|
test "a long echo that pushes the stream over 1 MiB gets the 500 template failed at the llm field and no stream; the JSON reply of the same request is sent" {
  let h = harness([echo_mock("text: \"${last(body.messages).content}\"")])
  // About 1.3 MiB as a stream at 4 code points per piece.
  let long = "a".repeat(30_000)
  inspect(
    [
      bounded(h.chat(body=said(long, stream=true))),
      bounded(h.chat(body=said(long))),
      bounded(h.chat(body=said("a".repeat(5_000), stream=true))),
    ].join("\n"),
    content=(
      #|500 {"error":"template failed","stub":"echo","at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"}; journal: /response/llm: the reply takes more than 1 MiB as a stream
      #|200 JSON
      #|200 stream
    ),
  )
}

///|
test "copied tools that push a Responses stream over 1 MiB, three copies of them, get the 500; the JSON reply, with one copy, is sent" {
  let h = harness([responses_mock()])
  let tools = (stream : Bool) => {
    let description = Json::string("d".repeat(400_000)).stringify()
    "{\"model\":\"gpt-6-astra\",\"input\":\"Hi\",\"stream\":\{stream},\"tools\":[{\"type\":\"function\",\"name\":\"f\",\"description\":\{description},\"parameters\":{}}]}"
  }
  inspect(
    [bounded(h.responses(tools(true))), bounded(h.responses(tools(false)))].join(
      "\n",
    ),
    content=(
      #|500 {"error":"template failed","stub":"responses","at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"}; journal: /response/llm: the reply takes more than 1 MiB as a stream
      #|200 JSON
    ),
  )
}

///|
test "instructions that take a Responses stream's two opening events over 1 MiB get the 500 too; the JSON reply, with one copy, is sent" {
  let h = harness([responses_mock()])
  let body = (stream : Bool) => {
    let instructions = Json::string("i".repeat(600_000)).stringify()
    "{\"model\":\"gpt-6-astra\",\"input\":\"Hi\",\"stream\":\{stream},\"instructions\":\{instructions}}"
  }
  inspect(
    [bounded(h.responses(body(true))), bounded(h.responses(body(false)))].join(
      "\n",
    ),
    content=(
      #|500 {"error":"template failed","stub":"responses","at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"}; journal: /response/llm: the reply takes more than 1 MiB as a stream
      #|200 JSON
    ),
  )
}

///|
test "a long model from the request, in every chunk of a Chat stream, pushes an untemplated reply over 1 MiB and gets the 500" {
  let h = harness([chat_mock])
  let model = "m".repeat(100_000)
  let body = (stream : Bool) => {
    "{\"model\":\"\{model}\",\"stream\":\{stream},\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
  }
  inspect(
    [bounded(h.chat(body=body(true))), bounded(h.chat(body=body(false)))].join(
      "\n",
    ),
    content=(
      #|500 {"error":"template failed","stub":"chat","at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"}; journal: /response/llm: the reply takes more than 1 MiB as a stream
      #|200 JSON
    ),
  )
}

///|
test "a rendered error message that pushes the stream over 1 MiB gets the 500 template failed at the llm field and no stream; the JSON reply, which leaves the error out, is sent" {
  let h = harness([
    echo_mock(
      "text: Hi, error: { after: 2, type: server_error, message: \"${last(body.messages).content}\" }",
    ),
  ])
  // 600,000 quotes render as 600,000 bytes, under the bound of the
  // rendered output, and take twice as many in the error frame's JSON.
  let quotes = "\"".repeat(600_000)
  inspect(
    [
      bounded(h.chat(body=said(quotes, stream=true))),
      bounded(h.chat(body=said(quotes))),
      bounded(h.chat(body=said("\"".repeat(1_000), stream=true))),
    ].join("\n"),
    content=(
      #|500 {"error":"template failed","stub":"echo","at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"}; journal: /response/llm: the reply takes more than 1 MiB as a stream
      #|200 JSON
      #|200 stream
    ),
  )
}
