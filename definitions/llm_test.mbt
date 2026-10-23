// Tests of LLM responses in Definition files and Ephemeral Stubs: how
// `llm` is read and checked.

///|
test "llm is a body kind of a response: api is required, and a response gives at most one of the five" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "ok", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Hi" } } },
          #|    { "id": "no-text", "mock": "m",
          #|      "responses": [{ "status": 200, "llm": { "api": "openai-chat" } }] },
          #|    { "id": "no-api", "mock": "m",
          #|      "response": { "status": 200, "llm": { "text": "Hi" } } },
          #|    { "id": "unknown-api", "mock": "m",
          #|      "responses": [
          #|        { "status": 429, "json": { "error": "slow down" } },
          #|        { "status": 200, "llm": { "api": "gemini" } } ] },
          #|    { "id": "api-not-a-string", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": ["openai-chat"] } } },
          #|    { "id": "unknown-field", "mock": "m",
          #|      "response": { "status": 200,
          #|        "llm": { "api": "openai-chat", "text": "Hi", "stream": true } } },
          #|    { "id": "text-not-a-string", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": 1 } } },
          #|    { "id": "not-an-object", "mock": "m",
          #|      "response": { "status": 200, "llm": "openai-chat" } },
          #|    { "id": "beside-json", "mock": "m",
          #|      "response": { "status": 200, "json": {},
          #|        "llm": { "api": "openai-chat" } } },
          #|    { "id": "beside-events", "mock": "m",
          #|      "responses": [{ "status": 200, "events": [{ "data": "x" }],
          #|        "llm": { "api": "openai-chat" } }] },
          #|    { "id": "no-status", "mock": "m",
          #|      "response": { "llm": { "api": "openai-chat" } } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/2/response/llm: needs "api"
      #|a.json: /stubs/3/responses/1/llm/api: must be "openai-chat"
      #|a.json: /stubs/4/response/llm/api: must be "openai-chat"
      #|a.json: /stubs/5/response/llm/stream: is not a known field
      #|a.json: /stubs/6/response/llm/text: must be a string
      #|a.json: /stubs/7/response/llm: must be an object
      #|a.json: /stubs/8/response: has "json" and "llm"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/9/responses/0: has "events" and "llm"; give at most one of "body", "bodyFile", "json", "events" and "llm"
      #|a.json: /stubs/10/response: needs "status"
    ),
  )
}

///|
test "usage gives two counts, integers from 0 to 2^53-1, and stopReason a word of the Stub's API" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "ok", "mock": "m",
          #|      "responses": [
          #|        { "status": 200, "llm": { "api": "openai-chat",
          #|          "usage": { "input": 9007199254740991, "output": 0 } } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "usage": {} } },
          #|        { "status": 200, "llm": { "stopReason": "stop", "api": "openai-chat" } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": "length" } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": "tool_calls" } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": "content_filter" } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": "function_call" } } ] },
          #|    { "id": "counts", "mock": "m",
          #|      "responses": [
          #|        { "status": 200, "llm": { "api": "openai-chat",
          #|          "usage": { "input": -1, "output": 1.5 } } },
          #|        { "status": 200, "llm": { "api": "openai-chat",
          #|          "usage": { "input": 9007199254740992, "output": "3" } } },
          #|        { "status": 200, "llm": { "api": "openai-chat",
          #|          "usage": { "input": 1, "cached": 0 } } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "usage": [1, 2] } } ] },
          #|    { "id": "reasons", "mock": "m",
          #|      "responses": [
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": "end_turn" } },
          #|        { "status": 200, "llm": { "stopReason": "max_output_tokens", "api": "openai-chat" } },
          #|        { "status": 200, "llm": { "api": "openai-chat", "stopReason": null } },
          #|        { "status": 200, "llm": { "api": "gemini", "stopReason": "STOP" } },
          #|        { "status": 200, "llm": { "stopReason": "stop" } } ] } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/1/responses/0/llm/usage/input: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/1/responses/0/llm/usage/output: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/1/responses/1/llm/usage/input: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/1/responses/1/llm/usage/output: must be an integer from 0 to 9007199254740991
      #|a.json: /stubs/1/responses/2/llm/usage/cached: is not a known field
      #|a.json: /stubs/1/responses/3/llm/usage: must be an object
      #|a.json: /stubs/2/responses/0/llm/stopReason: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|a.json: /stubs/2/responses/1/llm/stopReason: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|a.json: /stubs/2/responses/2/llm/stopReason: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|a.json: /stubs/2/responses/3/llm/api: must be "openai-chat"
      #|a.json: /stubs/2/responses/4/llm: needs "api"
    ),
  )
}

///|
test "the declaration holds the usage, 0 for a count left out, and the stop reason as written, or none to derive it" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [
    #|    { "id": "s", "mock": "m",
    #|      "responses": [
    #|        { "status": 200, "llm": { "api": "openai-chat",
    #|          "usage": { "input": 31, "output": 18 }, "stopReason": "length" } },
    #|        { "status": 200, "llm": { "api": "openai-chat", "usage": { "output": 9 } } },
    #|        { "status": 200, "llm": { "api": "openai-chat" } } ] } ] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  guard snapshot.mocks[0].stubs[0].serves is Ordinary(ordinary) else {
    fail("not an ordinary Stub")
  }
  let out = []
  for weighted in ordinary.responses {
    guard weighted.response.body is Llm(reply) else { fail("not an LLM reply") }
    let declaration = reply.declaration
    let stop_reason = match declaration.stop_reason {
      Some(reason) => reason.word
      None => "derived"
    }
    out.push(
      "input \{declaration.usage.input}, output \{declaration.usage.output}, stop reason \{stop_reason}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|input 31, output 18, stop reason length
      #|input 0, output 9, stop reason derived
      #|input 0, output 0, stop reason derived
    ),
  )
}
