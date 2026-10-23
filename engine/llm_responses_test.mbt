// Seam 1 tests of OpenAI Responses replies: the plan of a Stub whose `llm`
// names `openai-responses`, with its headers, ids and the settings it
// copies from the request.

///|
/// A Mock `openai` with a Stub that answers Responses requests from an LLM
/// response, with the header fields `headers`, its own seed fixing its ids.
fn responses_mock(headers? : String = "{}") -> (String, String) {
  (
    "openai.json",
    (
      #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      #|  "stubs": [{ "id": "responses", "mock": "openai",
      #|    "request": { "method": "POST", "path": "/v1/responses" },
      #|    "fault": { "seed": 7 },
      #|    "response": { "status": 200,
    ) +
    "      \"headers\": \{headers},\n" +
    (
      #|      "llm": { "api": "openai-responses", "text": "Hi there!",
      #|        "usage": { "input": 37, "output": 11 } } } }] }
    ),
  )
}

///|
/// A Responses request to the Host of `responses_mock`, with the JSON body
/// `body`.
fn Harness::responses(self : Harness, body : String) -> @engine.Outcome {
  self.send(
    "POST",
    "/v1/responses",
    headers=[("Host", "api.openai.test"), ("Content-Type", "application/json")],
    body~,
  )
}

///|
test "an openai-responses Stub answers with the Response object, as application/json in place of the Stub's Content-Type, with an x-request-id after the Stub's fields" {
  let h = harness([
    responses_mock(
      headers="{ \"Content-Type\": \"text/plain\", \"x-ratelimit-remaining-requests\": \"59\" }",
    ),
  ])
  inspect(
    response(
      h.responses(
        "{\"model\":\"gpt-6-astra\",\"instructions\":\"Be brief.\",\"input\":\"Hello!\",\"metadata\":{\"run\":\"7\"}}",
      ),
    ),
    content=(
      #|200
      #|Content-Type: application/json
      #|x-ratelimit-remaining-requests: 59
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":"Be brief.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there!","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{"run":"7"}}
    ),
  )
}

///|
test "a streamed request to an openai-responses Stub gets the JSON reply, for now, and the Stub's own x-request-id replaces smock's" {
  let h = harness([
    responses_mock(headers="{ \"X-Request-Id\": \"req_test_1\" }"),
  ])
  let outcome = h.responses(
    "{\"model\":\"gpt-6-astra\",\"input\":\"Hello!\",\"stream\":true}",
  )
  let headers = outcome.plan.headers.map(header => "\{header.0}: \{header.1}")
  inspect(
    "\{headers.join("\n")}\n\{body_member(outcome, "object")} \{body_member(outcome, "status")}",
    content=(
      #|Content-Type: application/json
      #|X-Request-Id: req_test_1
      #|"response" "completed"
    ),
  )
}
