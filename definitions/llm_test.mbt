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
