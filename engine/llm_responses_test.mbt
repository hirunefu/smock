// Seam 1 tests of OpenAI Responses replies: the plan of a Stub whose `llm`
// names `openai-responses`, with its headers, ids and the settings it
// copies from the request, its stream with the stream's waits, and a
// mid-stream error's `error` event.

///|
/// A Mock `openai` with a Stub that answers Responses requests from an LLM
/// response, with the header fields `headers`, its own seed fixing its ids.
fn responses_mock(headers~ : String = "{}") -> (String, String) {
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
/// Each event of `outcome`'s plan, one per line: its wait, its type and
/// `sequence_number`, with the piece a delta carries, or the status and
/// `completed_at` of the Response a lifecycle event carries.
fn responses_events(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "no events" }
  let lines = []
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "-"
    }
    let carries = match data {
      { "delta": String(piece), .. } => " \{piece.escape()}"
      {
        "response": {
          "status": String(status),
          "completed_at": completed_at,
          ..
        },
        ..
      } => " \{status} \{completed_at.stringify()}"
      _ => ""
    }
    lines.push(
      "\{event.delay_ms} \{event.event.unwrap_or("-")} #\{number}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "a streamed request to an openai-responses Stub gets the Responses events as text/event-stream, and the Stub's own x-request-id replaces smock's" {
  let h = harness([
    responses_mock(headers="{ \"X-Request-Id\": \"req_test_1\" }"),
  ])
  let outcome = h.responses(
    "{\"model\":\"gpt-6-astra\",\"input\":\"Hello!\",\"stream\":true}",
  )
  let headers = outcome.plan.headers.map(header => "\{header.0}: \{header.1}")
  inspect(
    "\{headers.join("\n")}\n\{responses_events(outcome)}",
    content=(
      #|Content-Type: text/event-stream
      #|X-Request-Id: req_test_1
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|0 response.output_text.delta #4 "Hi t"
      #|0 response.output_text.delta #5 "here"
      #|0 response.output_text.delta #6 "!"
      #|0 response.output_text.done #7
      #|0 response.content_part.done #8
      #|0 response.output_item.done #9
      #|0 response.completed #10 completed 1791815405
    ),
  )
}

///|
/// A Mock `openai` with a Stub that answers Responses requests from an LLM
/// response whose text is `text` and whose `llm` has the members `fields`
/// after `api` and `text`, given as JSON text, its own seed fixing its ids
/// and waits.
fn paced_responses(text : String, fields : String) -> (String, String) {
  (
    "openai.json",
    (
      $|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      $|  "stubs": [{ "id": "responses", "mock": "openai",
      $|    "request": { "method": "POST", "path": "/v1/responses" },
      $|    "fault": { "seed": 7 },
      $|    "response": { "status": 200,
      $|      "llm": { "api": "openai-responses", "text": "\{text}"\{fields} } } }] }
    ),
  )
}

///|
test "with fixed waits, the closing event's completed_at is the time received plus the waits, in whole seconds, crossing a second; created_at stays the time received" {
  // The request is received at 1791815405.123 s.
  let streamed = (text : String, fields : String) => {
    let h = harness([paced_responses(text, fields)])
    responses_events(h.responses("{\"input\":\"Hello!\",\"stream\":true}"))
  }
  inspect(
    [
      streamed(
        "Hi there!", ", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 238 } }",
      ),
      streamed(
        "Hi there!", ", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 239 } }",
      ),
      streamed("", ", \"timing\": { \"first\": { \"fixed\": 877 } }"),
      streamed(
        "Hi there!", ", \"timing\": { \"first\": { \"fixed\": 2000 } }, \"stopReason\": \"max_output_tokens\"",
      ),
    ].join("\n\n"),
    content=(
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|400 response.output_text.delta #4 "Hi t"
      #|238 response.output_text.delta #5 "here"
      #|238 response.output_text.delta #6 "!"
      #|0 response.output_text.done #7
      #|0 response.content_part.done #8
      #|0 response.output_item.done #9
      #|0 response.completed #10 completed 1791815405
      #|
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|400 response.output_text.delta #4 "Hi t"
      #|239 response.output_text.delta #5 "here"
      #|239 response.output_text.delta #6 "!"
      #|0 response.output_text.done #7
      #|0 response.content_part.done #8
      #|0 response.output_item.done #9
      #|0 response.completed #10 completed 1791815406
      #|
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|877 response.output_text.done #4
      #|0 response.content_part.done #5
      #|0 response.output_item.done #6
      #|0 response.completed #7 completed 1791815406
      #|
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|2000 response.output_text.delta #4 "Hi t"
      #|0 response.output_text.delta #5 "here"
      #|0 response.output_text.delta #6 "!"
      #|0 response.output_text.done #7
      #|0 response.content_part.done #8
      #|0 response.output_item.done #9
      #|0 response.incomplete #10 incomplete null
    ),
  )
}

///|
test "rendered with fixed waits, the Responses stream's completed_at follows the waits from the rendering's time" {
  let h = harness([
    paced_responses(
      "Hi there!", ", \"timing\": { \"first\": { \"fixed\": 1500 }, \"interval\": { \"fixed\": 250 } }",
    ),
  ])
  h.now = 1_792_713_600_500L
  let sample : Json = {
    "method": "POST",
    "path": "/v1/responses",
    "headers": { "Host": "api.openai.test" },
    "body": "{\"input\":\"Hello!\",\"stream\":true}",
  }
  guard @json.parse(h.render("responses", sample))
    is { "response": { "events": Array(events), .. }, .. } else {
    fail("no events")
  }
  let delays = []
  let mut closing = Json::null()
  for event in events {
    guard event is { "delay": delay, "data": String(data), .. } else {
      fail("not an event")
    }
    delays.push(delay.stringify())
    closing = @json.parse(data)
  }
  guard closing
    is {
      "type": String(kind),
      "response": { "created_at": created_at, "completed_at": completed_at, .. },
      ..
    } else {
    fail("no closing event")
  }
  inspect(
    "delays \{delays.join(" ")}\n\{kind}: created_at \{created_at.stringify()}, completed_at \{completed_at.stringify()}",
    content=(
      #|delays 0 0 0 0 1500 250 250 0 0 0 0
      #|response.completed: created_at 1792713600, completed_at 1792713602
    ),
  )
}

///|
test "a declared error ends the Responses stream with event: error, numbered next, which waits as a next piece would: first when no piece came before it, interval after one" {
  let cut = (after : Int32, timing : String) => {
    let error = ", \"error\": { \"after\": \{after}, \"code\": \"server_error\", \"message\": \"Something went wrong\" }"
    harness([paced_responses("Hi there!", error + timing)]).responses(
      "{\"input\":\"Hello!\",\"stream\":true}",
    )
  }
  // The head on the wire, then the last chunk before the end of the
  // chunked stream: the error's.
  let wire = on_the_wire(cut(2, ""), "POST").split("\n").collect()
  let head_end = wire.search("").unwrap()
  let error_at = wire.search("event: error").unwrap()
  let shown = []
  for i, line in wire {
    if i <= head_end || i >= error_at - 1 {
      shown.push(line.to_owned())
    } else if i == head_end + 1 {
      shown.push("…")
    }
  }
  inspect(
    [
      responses_events(cut(0, fixed_timing)),
      responses_events(cut(6, fixed_timing)),
      shown.join("\n"),
    ].join("\n---\n"),
    content=(
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|400 error #2
      #|---
      #|0 response.created #0 in_progress null
      #|0 response.in_progress #1 in_progress null
      #|0 response.output_item.added #2
      #|0 response.content_part.added #3
      #|400 response.output_text.delta #4 "Hi t"
      #|30 response.output_text.delta #5 "he"
      #|30 error #6
      #|---
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|Transfer-Encoding: chunked
      #|
      #|…
      #|7d
      #|event: error
      #|data: {"type":"error","code":"server_error","message":"Something went wrong","param":null,"sequence_number":5}
      #|
      #|
      #|0
      #|
      #|
    ),
  )
}
