// Tests of the size bound of LLM responses at load: an `llm` as written
// is encoded as the JSON reply and as a stream, and either one over 1 MiB
// is a load error at the `llm` field.

///|
/// A Definition file whose Stubs give, in order, the responses
/// `responses`, each a JSON object.
fn stubs_answering(responses : Array[String]) -> String {
  let stubs = []
  for i, response in responses {
    stubs.push(
      "{ \"id\": \"s\{i}\", \"mock\": \"m\", \"responses\": [{ \"status\": 429 }, \{response}] }",
    )
  }
  "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [\{stubs.join(", ")}] }"
}

///|
test "an llm as written whose JSON reply or stream passes 1 MiB is a load error at llm; a templated one is checked for each request" {
  let text = (length : Int) => Json::string("a".repeat(length)).stringify()
  inspect(
    problems([
      (
        "a.json",
        stubs_answering([
          "{ \"status\": 200, \"llm\": { \"api\": \"openai-chat\", \"text\": \{text(6_000)} } }",
          "{ \"status\": 200, \"llm\": { \"api\": \"openai-chat\", \"text\": \{text(6_000)}, \"chunkSize\": 1 } }",
          "{ \"status\": 200, \"llm\": { \"api\": \"anthropic-messages\", \"text\": \{text(1_048_576)} } }",
          "{ \"status\": 200, \"template\": true, \"llm\": { \"api\": \"openai-chat\", \"text\": \{text(6_000)}, \"chunkSize\": 1 } }",
        ]),
      ),
    ]),
    content=(
      #|a.json: /stubs/1/responses/1/llm: the reply takes more than 1 MiB as a stream
      #|a.json: /stubs/2/responses/1/llm: the reply takes more than 1 MiB as a JSON body and as a stream
    ),
  )
}

///|
test "a declared error ends the stream early, so the JSON reply as written can pass 1 MiB alone and be the load error, and a long stream cut early loads" {
  let text = (length : Int) => Json::string("a".repeat(length)).stringify()
  let error = (after : Int) => {
    "\"error\": { \"after\": \{after}, \"type\": \"server_error\", \"message\": \"Overloaded\" }"
  }
  inspect(
    problems([
      (
        "a.json",
        stubs_answering([
          "{ \"status\": 200, \"llm\": { \"api\": \"openai-chat\", \"text\": \{text(1_048_576)}, \{error(0)} } }",
          "{ \"status\": 200, \"llm\": { \"api\": \"openai-chat\", \"text\": \{text(6_000)}, \"chunkSize\": 1, \{error(10)} } }",
        ]),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/responses/1/llm: the reply takes more than 1 MiB as a JSON body
    ),
  )
}
