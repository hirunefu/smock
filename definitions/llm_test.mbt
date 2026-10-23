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
