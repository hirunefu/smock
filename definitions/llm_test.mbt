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

///|
test "id and model are text, the empty string included; any other value is refused" {
  inspect(
    problems([
      (
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [
          #|    { "id": "ok", "mock": "m",
          #|      "response": { "status": 200,
          #|        "llm": { "api": "openai-chat", "id": "chatcmpl-test-1", "model": "test-model" } } },
          #|    { "id": "empty", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "id": "", "model": "" } } },
          #|    { "id": "id-not-text", "mock": "m",
          #|      "response": { "status": 200, "llm": { "api": "openai-chat", "id": 1 } } },
          #|    { "id": "model-not-text", "mock": "m",
          #|      "responses": [{ "status": 200, "llm": { "api": "openai-chat", "model": null } }] },
          #|    { "id": "both-not-text", "mock": "m",
          #|      "response": { "status": 200,
          #|        "llm": { "api": "openai-chat", "id": ["chatcmpl-test-1"], "model": { "name": "m" } } } } ] }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/2/response/llm/id: must be a string
      #|a.json: /stubs/3/responses/0/llm/model: must be a string
      #|a.json: /stubs/4/response/llm/id: must be a string
      #|a.json: /stubs/4/response/llm/model: must be a string
    ),
  )
}

///|
test "chunkSize is an integer from 1 to 1,000,000, and chunks a list of at least one text in place of text" {
  inspect(
    problems([
      (
        "a.yaml",
        (
          #|mocks: [{ name: m }]
          #|stubs:
          #|  - { id: size-1, mock: m, response: { status: 200, llm: { api: openai-chat, text: Hi, chunkSize: 1 } } }
          #|  - { id: size-max, mock: m, response: { status: 200, llm: { api: openai-chat, chunkSize: 1000000 } } }
          #|  - { id: chunks, mock: m, response: { status: 200, llm: { api: openai-chat, chunks: [Hel, "", lo] } } }
          #|  - { id: one-empty-chunk, mock: m, response: { status: 200, llm: { api: openai-chat, chunks: [""], chunkSize: 2 } } }
          #|  - { id: size-0, mock: m, response: { status: 200, llm: { api: openai-chat, chunkSize: 0 } } }
          #|  - { id: size-above, mock: m, response: { status: 200, llm: { api: openai-chat, chunkSize: 1000001 } } }
          #|  - { id: size-fraction, mock: m, response: { status: 200, llm: { api: openai-chat, chunkSize: 2.5 } } }
          #|  - { id: size-string, mock: m, response: { status: 200, llm: { api: openai-chat, chunkSize: "4" } } }
          #|  - { id: text-and-chunks, mock: m, response: { status: 200, llm: { api: openai-chat, text: Hi, chunks: [H, i] } } }
          #|  - { id: empty-text-and-chunks, mock: m, responses: [{ status: 200, llm: { api: openai-chat, text: "", chunks: [Hi] } }] }
          #|  - { id: no-chunk, mock: m, response: { status: 200, llm: { api: openai-chat, chunks: [] } } }
          #|  - { id: chunks-a-string, mock: m, response: { status: 200, llm: { api: openai-chat, chunks: Hi } } }
          #|  - { id: chunk-not-a-string, mock: m, response: { status: 200, llm: { api: openai-chat, chunks: [Hi, 1, null] } } }
        ),
      ),
    ]),
    content=(
      #|a.yaml: /stubs/4/response/llm/chunkSize: must be an integer from 1 to 1000000
      #|a.yaml: /stubs/5/response/llm/chunkSize: must be an integer from 1 to 1000000
      #|a.yaml: /stubs/6/response/llm/chunkSize: must be an integer from 1 to 1000000
      #|a.yaml: /stubs/7/response/llm/chunkSize: must be an integer from 1 to 1000000
      #|a.yaml: /stubs/8/response/llm: has "text" and "chunks"; give at most one of them
      #|a.yaml: /stubs/9/responses/0/llm: has "text" and "chunks"; give at most one of them
      #|a.yaml: /stubs/10/response/llm/chunks: must not be an empty array
      #|a.yaml: /stubs/11/response/llm/chunks: must be an array
      #|a.yaml: /stubs/12/response/llm/chunks/1: must be a string
      #|a.yaml: /stubs/12/response/llm/chunks/2: must be a string
    ),
  )
}

///|
test "the snapshot holds chunkSize, 4 when left out, and the chunks as written, with their join as the text" {
  let file =
    #|mocks: [{ name: m }]
    #|stubs:
    #|  - id: s
    #|    mock: m
    #|    responses:
    #|      - { status: 200, llm: { api: openai-chat, text: Hello } }
    #|      - { status: 200, llm: { api: openai-chat, text: Hello, chunkSize: 1 } }
    #|      - { status: 200, llm: { api: openai-chat, chunks: [Hel, "", lo], chunkSize: 9 } }
    #|      - { status: 200, llm: { api: openai-chat, chunks: [""] } }
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  guard snapshot.mocks[0].stubs[0].serves is Ordinary(ordinary) else {
    fail("not an ordinary Stub")
  }
  let out = []
  for weighted in ordinary.responses {
    guard weighted.response.body is Llm(reply) else { fail("not an LLM reply") }
    let chunks = match reply.strings.chunks {
      Some(chunks) => "[\{chunks.map(chunk => chunk.escape()).join(", ")}]"
      None => "none"
    }
    out.push(
      "chunkSize \{reply.declaration.chunk_size}, text \{reply.strings.text.escape()}, chunks \{chunks}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|chunkSize 4, text "Hello", chunks none
      #|chunkSize 1, text "Hello", chunks none
      #|chunkSize 9, text "Hello", chunks ["Hel", "", "lo"]
      #|chunkSize 4, text "", chunks [""]
    ),
  )
}

///|
test "toolCalls is a list of calls, each with a non-empty name and arguments that are an object or a string, and an id that is text; two calls with one id are refused" {
  inspect(
    problems([
      (
        "a.yaml",
        (
          #|mocks: [{ name: m }]
          #|stubs:
          #|  - id: ok
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm:
          #|        api: openai-chat
          #|        toolCalls:
          #|          - { name: get_weather, arguments: { city: Paris } }
          #|          - { name: broken, arguments: '{"city": "Par', id: call_1 }
          #|          - { name: "名前 with spaces/and.dots", arguments: "", id: "" }
          #|          - { name: get_weather, arguments: {}, id: call_2 }
          #|  - { id: none, mock: m, response: { status: 200, llm: { api: openai-chat, toolCalls: [] } } }
          #|  - id: missing
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm: { api: openai-chat, toolCalls: [{ id: call_1 }, { name: f }, { arguments: {} }] }
          #|  - id: wrong-kinds
          #|    mock: m
          #|    responses:
          #|      - status: 200
          #|        llm:
          #|          api: openai-chat
          #|          toolCalls:
          #|            - { name: "", arguments: 1 }
          #|            - { name: 1, arguments: [1], id: 2 }
          #|            - { name: f, arguments: null, id: null }
          #|            - { name: f, arguments: true, type: function }
          #|            - f
          #|  - { id: not-a-list, mock: m, response: { status: 200, llm: { api: openai-chat, toolCalls: { name: f, arguments: {} } } } }
          #|  - id: same-id
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm:
          #|        api: openai-chat
          #|        toolCalls:
          #|          - { name: f, arguments: {}, id: call_1 }
          #|          - { name: g, arguments: {} }
          #|          - { name: h, arguments: {}, id: call_1 }
          #|          - { name: i, arguments: {}, id: call_1 }
          #|          - { name: j, arguments: {}, id: "" }
          #|          - { name: k, arguments: {}, id: "" }
          #|  - id: same-id-in-two-replies
          #|    mock: m
          #|    responses:
          #|      - { status: 200, llm: { api: openai-chat, toolCalls: [{ name: f, arguments: {}, id: call_1 }] } }
          #|      - { status: 200, llm: { api: openai-chat, toolCalls: [{ name: f, arguments: {}, id: call_1 }] } }
        ),
      ),
    ]),
    content=(
      #|a.yaml: /stubs/2/response/llm/toolCalls/0: needs "name"
      #|a.yaml: /stubs/2/response/llm/toolCalls/0: needs "arguments"
      #|a.yaml: /stubs/2/response/llm/toolCalls/1: needs "arguments"
      #|a.yaml: /stubs/2/response/llm/toolCalls/2: needs "name"
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/0/name: must be a non-empty string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/0/arguments: must be an object or a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/1/name: must be a non-empty string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/1/arguments: must be an object or a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/1/id: must be a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/2/arguments: must be an object or a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/2/id: must be a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/3/arguments: must be an object or a string
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/3/type: is not a known field
      #|a.yaml: /stubs/3/responses/0/llm/toolCalls/4: must be an object
      #|a.yaml: /stubs/4/response/llm/toolCalls: must be an array
      #|a.yaml: /stubs/5/response/llm/toolCalls/2/id: the tool call id "call_1" is already used at a.yaml: /stubs/5/response/llm/toolCalls/0/id
      #|a.yaml: /stubs/5/response/llm/toolCalls/3/id: the tool call id "call_1" is already used at a.yaml: /stubs/5/response/llm/toolCalls/0/id
      #|a.yaml: /stubs/5/response/llm/toolCalls/5/id: the tool call id "" is already used at a.yaml: /stubs/5/response/llm/toolCalls/4/id
    ),
  )
}

///|
test "the snapshot holds each tool call in the order written, its arguments' object as compact JSON with members in the order written, and a string as written" {
  let reply_of = (name : String, file : String) => {
    let set : @definitions.DefinitionSet = {
      files: [(name, @utf8.encode(file))],
      body_files: [],
    }
    let snapshot = match @definitions.load(set) {
      Ok(snapshot) => snapshot
      Err(diagnostics) => return diagnostics.map(d => d.to_string()).join("\n")
    }
    guard snapshot.mocks[0].stubs[0].serves is Ordinary(ordinary) else {
      abort("not an ordinary Stub")
    }
    guard ordinary.responses[0].response.body is Llm(reply) else {
      abort("not an LLM reply")
    }
    reply.strings.tool_calls
    .iter()
    .map(call => {
      let id = match call.id {
        Some(id) => id.escape()
        None => "generated"
      }
      "\{call.name.escape()}, id \{id}: \{call.arguments.escape()}"
    })
    .collect()
    .join("\n")
  }
  inspect(
    [
      reply_of(
        "a.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [{ "id": "s", "mock": "m", "response": { "status": 200,
          #|    "llm": { "api": "openai-chat", "toolCalls": [
          #|      { "name": "f", "arguments": { "z": 1.50, "a": [1e3, -0, 12345678901234567890, "é\n"], "m": {} } },
          #|      { "id": "call_1", "name": "g", "arguments": "{ \"z\": 1.50 }" } ] } } }] }
        ),
      ),
      reply_of(
        "a.yaml",
        (
          #|mocks: [{ name: m }]
          #|stubs:
          #|  - id: s
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm:
          #|        api: openai-chat
          #|        toolCalls:
          #|          - name: f
          #|            arguments: { z: 1.50, a: [1e3, 12, true, null], s: "é\n" }
          #|          - { name: g, arguments: "not JSON", id: "" }
        ),
      ),
    ].join("\n---\n"),
    content=(
      #|"f", id generated: "{\"z\":1.5,\"a\":[1000,0,12345678901234567890,\"é\\n\"],\"m\":{}}"
      #|"g", id "call_1": "{ \"z\": 1.50 }"
      #|---
      #|"f", id generated: "{\"z\":1.5,\"a\":[1000,12,true,null],\"s\":\"é\\n\"}"
      #|"g", id "": "not JSON"
    ),
  )
}
