// Seam 1 tests of the mid-stream error of an LLM response: the waits of a
// stream that it cuts, its Journal entry and the ordinary reply to a
// request that does not stream.

///|
/// The `llm` members of an error after `after` code points of the text,
/// as JSON text that `paced_mock` adds after `api` and `text`.
fn error_after(after : Int32) -> String {
  ", \"error\": { \"after\": \{after}, \"type\": \"server_error\", \"message\": \"Overloaded\" }"
}

///|
/// Fixed waits, as `llm` members: 400 ms before the first piece and 30 ms
/// before each later one.
let fixed_timing : String = ", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }"

///|
test "with fixed waits, the error waits as a next piece would: first when no piece came before it, interval after one" {
  let cut = (after : Int32) => {
    let h = harness([paced_mock(fields=error_after(after) + fixed_timing)])
    waits(h.chat(body=stream_body("true")))
  }
  inspect(
    [cut(0), cut(6), cut(34)].join("\n"),
    content=(
      #|0 opening, 400 {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|0 opening, 400 "Hell", 30 "o!", 30 {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
      #|0 opening, 400 "Hell", 30 "o! H", 30 "ow c", 30 "an I", 30 " ass", 30 "ist ", 30 "you ", 30 "toda", 30 "y?", 30 {"error":{"message":"Overloaded","type":"server_error","param":null,"code":null}}
    ),
  )
}

///|
test "a stream that ends with a declared error is journaled with status 200, and the error is its last event" {
  let h = harness([paced_mock(fields=error_after(6))])
  inspect(
    describe(h.chat(body=stream_body("true"))),
    content=(
      #|plan:
      #|  status: 200
      #|  header: Content-Type: text/event-stream
      #|  header: x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|  event: after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|  event: after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hell\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|  event: after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o!\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|  event: after 0 ms: event -, id -, data "{\"error\":{\"message\":\"Overloaded\",\"type\":\"server_error\",\"param\":null,\"code\":null}}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: Some("api.openai.test")
      #|  mock: Some("openai")
      #|  via_default: false
      #|  request: POST /v1/chat/completions HTTP/1.1
      #|  header: Host: api.openai.test
      #|  header: Content-Type: application/json
      #|  body: "{\"model\":\"test-model\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
      #|  stub: Some("chat")
      #|  status: Some(200)
      #|  fault: None
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "a request that does not stream gets the ordinary JSON reply of a Stub with an error" {
  let h = harness([paced_mock(fields=error_after(6))])
  let outcome = h.chat(body=stream_body("false"))
  let status = match outcome.journal {
    Some({ status: Some(status), .. }) => status.to_string()
    _ => "none"
  }
  inspect(
    "\{form(outcome)}; content \{reply_content(outcome).escape()}; Journal status \{status}",
    content=(
      #|200 application/json, a body with object "chat.completion"; content "Hello! How can I assist you today?"; Journal status 200
    ),
  )
}
