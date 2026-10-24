// Seam 1 tests of LLM responses in the Anthropic Messages wire form: the
// plan of a Stub whose `llm` names `anthropic-messages`, its JSON reply and
// its stream with the stream's waits, a mid-stream error's `error` event,
// its request-id header, its stop members read with the request, a Stub
// that moves from `openai-chat` by changing `api` alone, and a templated
// Stub's tool calls as `tool_use` blocks.

///|
/// A Mock `anthropic` with a Stub that answers Messages requests from an
/// LLM response that names `api`, by default `anthropic-messages`, with
/// `fields` after it and the header fields `headers`, its own seed fixing
/// its ids.
fn messages_mock(
  api~ : String = "anthropic-messages",
  fields~ : String = ", \"text\": \"Hello!\", \"usage\": { \"input\": 12, \"output\": 6 }",
  headers~ : String = "{ \"anthropic-ratelimit-requests-remaining\": \"49\", \"Content-Type\": \"text/plain\" }",
) -> (String, String) {
  (
    "anthropic.json",
    (
      #|{ "mocks": [{ "name": "anthropic", "hosts": ["api.anthropic.test"] }],
      #|  "stubs": [{ "id": "messages", "mock": "anthropic",
      #|    "request": { "method": "POST", "path": "/v1/messages" },
      #|    "fault": { "seed": 7 },
      #|    "response": { "status": 200,
    ) +
    "      \"headers\": \{headers},\n" +
    "      \"llm\": { \"api\": \"\{api}\"\{fields} } } }] }",
  )
}

///|
/// The JSON body of a Messages request for `claude-test`, with one user
/// message and the members `extra`, such as `stop_sequences`, after it.
fn messages_body(extra~ : String = "") -> String {
  "{\"model\":\"claude-test\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":\"Hello, Claude\"}]\{extra}}"
}

///|
/// A Messages request to the Host of `messages_mock`, with the JSON body
/// `body`, by default `messages_body()`.
fn Harness::messages(
  self : Harness,
  body~ : String = messages_body(),
) -> @engine.Outcome {
  self.send(
    "POST",
    "/v1/messages",
    headers=[
      ("Host", "api.anthropic.test"),
      ("Content-Type", "application/json"),
    ],
    body~,
  )
}

///|
test "an anthropic-messages Stub answers with one message JSON body, as application/json in place of the Stub's Content-Type, then request-id after the Stub's fields" {
  let h = harness([messages_mock()])
  inspect(
    response(h.messages()),
    content=(
      #|200
      #|Content-Type: application/json
      #|anthropic-ratelimit-requests-remaining: 49
      #|request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":6}}
    ),
  )
}

///|
test "a request with stream: true gets the reply as events named with event: lines, as text/event-stream in place of the Stub's Content-Type, then request-id after the Stub's fields" {
  let h = harness([messages_mock()])
  inspect(
    on_the_wire(
      h.messages(body=messages_body(extra=",\"stream\":true")),
      "POST",
    ),
    content=(
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|anthropic-ratelimit-requests-remaining: 49
      #|request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|Transfer-Encoding: chunked
      #|
      #|102
      #|event: message_start
      #|data: {"type":"message_start","message":{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":0}}}
      #|
      #|
      #|75
      #|event: content_block_start
      #|data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      #|
      #|
      #|77
      #|event: content_block_delta
      #|data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hell"}}
      #|
      #|
      #|75
      #|event: content_block_delta
      #|data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"o!"}}
      #|
      #|
      #|49
      #|event: content_block_stop
      #|data: {"type":"content_block_stop","index":0}
      #|
      #|
      #|89
      #|event: message_delta
      #|data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":6}}
      #|
      #|
      #|33
      #|event: message_stop
      #|data: {"type":"message_stop"}
      #|
      #|
      #|0
      #|
      #|
    ),
  )
}

///|
/// The waits of the events of `outcome`'s plan, in milliseconds, each with
/// its event's name, and the text of a text delta.
fn messages_waits(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "no events" }
  let out = []
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let carries = match data {
      { "delta": { "type": "text_delta", "text": String(piece), .. }, .. } =>
        piece.escape()
      _ => event.event.unwrap_or("-")
    }
    out.push("\{event.delay_ms} \{carries}")
  }
  out.join(", ")
}

///|
test "with timing, the first text delta waits first and each later one interval; the other events follow at once, and an empty reply waits first before message_delta" {
  let timing = ", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }"
  let paced = (text : String) => {
    let h = harness([messages_mock(fields=", \"text\": \"\{text}\"\{timing}")])
    messages_waits(h.messages(body=messages_body(extra=",\"stream\":true")))
  }
  inspect(
    [paced("Hello, Claude"), paced("")].join("\n"),
    content=(
      #|0 message_start, 0 content_block_start, 400 "Hell", 30 "o, C", 30 "laud", 30 "e", 0 content_block_stop, 0 message_delta, 0 message_stop
      #|0 message_start, 400 message_delta, 0 message_stop
    ),
  )
}

///|
test "a declared error ends the stream with event: error, which waits as a next piece would: first when no piece came before it, interval after one" {
  let cut = (after : Int32, timing : String) => {
    let error = ", \"error\": { \"after\": \{after}, \"type\": \"overloaded_error\", \"message\": \"Overloaded\" }"
    harness([messages_mock(fields=", \"text\": \"Hello!\"\{error}\{timing}")]).messages(
      body=messages_body(extra=",\"stream\":true"),
    )
  }
  inspect(
    [
      messages_waits(cut(0, fixed_timing)),
      messages_waits(cut(6, fixed_timing)),
      on_the_wire(cut(2, ""), "POST"),
    ].join("\n"),
    content=(
      #|0 message_start, 400 error
      #|0 message_start, 0 content_block_start, 400 "Hell", 30 "o!", 30 error
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|anthropic-ratelimit-requests-remaining: 49
      #|request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|Transfer-Encoding: chunked
      #|
      #|101
      #|event: message_start
      #|data: {"type":"message_start","message":{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}
      #|
      #|
      #|75
      #|event: content_block_start
      #|data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
      #|
      #|
      #|75
      #|event: content_block_delta
      #|data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"He"}}
      #|
      #|
      #|60
      #|event: error
      #|data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
      #|
      #|
      #|0
      #|
      #|
    ),
  )
}

///|
/// The head of `outcome`'s plan: its header fields, one per line, without
/// the Content-Type, then the reply's id.
fn messages_head(outcome : @engine.Outcome) -> String {
  let lines = []
  for header in outcome.plan.headers {
    if header.0 != "Content-Type" {
      lines.push("\{header.0}: \{header.1}")
    }
  }
  lines.push("id: \{body_member(outcome, "id")}")
  lines.join("\n")
}

///|
test "a Stub's own request-id, in any case, is sent alone in place of the generated one; an x-request-id is another field" {
  let own = (headers : String) => {
    messages_head(harness([messages_mock(headers~)]).messages())
  }
  inspect(
    [
      "request-id:\n\{own("{ \"request-id\": \"req_from_the_stub\" }")}",
      "Request-Id:\n\{own("{ \"Request-Id\": \"req_from_the_stub\" }")}",
      "REQUEST-ID:\n\{own("{ \"REQUEST-ID\": \"req_from_the_stub\" }")}",
      "x-request-id:\n\{own("{ \"x-request-id\": \"req_from_the_stub\" }")}",
    ].join("\n"),
    content=(
      #|request-id:
      #|request-id: req_from_the_stub
      #|id: "msg_oniRcSDFUU6bnxe66XwQR5pl"
      #|Request-Id:
      #|Request-Id: req_from_the_stub
      #|id: "msg_oniRcSDFUU6bnxe66XwQR5pl"
      #|REQUEST-ID:
      #|REQUEST-ID: req_from_the_stub
      #|id: "msg_oniRcSDFUU6bnxe66XwQR5pl"
      #|x-request-id:
      #|x-request-id: req_from_the_stub
      #|request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|id: "msg_oniRcSDFUU6bnxe66XwQR5pl"
    ),
  )
}

///|
test "stop_sequence echoes the first of the request's stop_sequences when the Stub writes stopReason: stop_sequence, and a refusal carries stop_details" {
  let stop = (stop_reason : String, extra : String) => {
    let h = harness([
      messages_mock(
        fields=", \"text\": \"Hi\", \"stopReason\": \"\{stop_reason}\"",
      ),
    ])
    let outcome = h.messages(body=messages_body(extra~))
    [
      body_member(outcome, "stop_reason"),
      body_member(outcome, "stop_sequence"),
      body_member(outcome, "stop_details"),
    ].join(" ")
  }
  inspect(
    [
      stop("stop_sequence", ",\"stop_sequences\":[\"END\",\"STOP\"]"),
      stop("stop_sequence", ",\"stop_sequences\":[7]"),
      stop("stop_sequence", ""),
      stop("end_turn", ",\"stop_sequences\":[\"END\"]"),
      stop("refusal", ",\"stop_sequences\":[\"END\"]"),
    ].join("\n"),
    content=(
      #|"stop_sequence" "END" missing
      #|"stop_sequence" null missing
      #|"stop_sequence" null missing
      #|"end_turn" null missing
      #|"refusal" null {"type":"refusal","category":null,"explanation":null}
    ),
  )
}

///|
test "changing api alone moves a Stub without a stop reason from openai-chat to anthropic-messages, its ids keeping their 24 characters" {
  let answer = (api : String) => {
    let outcome = harness([messages_mock(api~)]).messages()
    let lines = [api]
    for header in outcome.plan.headers {
      lines.push("\{header.0}: \{header.1}")
    }
    lines.push("id: \{body_member(outcome, "id")}")
    lines.join("\n")
  }
  inspect(
    [answer("openai-chat"), answer("anthropic-messages")].join("\n"),
    content=(
      #|openai-chat
      #|Content-Type: application/json
      #|anthropic-ratelimit-requests-remaining: 49
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|id: "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|anthropic-messages
      #|Content-Type: application/json
      #|anthropic-ratelimit-requests-remaining: 49
      #|request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|id: "msg_oniRcSDFUU6bnxe66XwQR5pl"
    ),
  )
  // A Chat stop reason does not move: it is a load error at stopReason.
  let (name, file) = messages_mock(
    fields=", \"text\": \"Hi\", \"stopReason\": \"stop\"",
  )
  let set : @definitions.DefinitionSet = {
    files: [(name, @utf8.encode(file))],
    body_files: [],
  }
  guard @definitions.load(set) is Err(problems) else { fail("loaded") }
  inspect(
    problems.map(p => p.to_string()).join("\n"),
    content=(
      #|anthropic.json: /stubs/0/response/llm/stopReason: must be a stop reason of anthropic-messages: "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal" or "model_context_window_exceeded"
    ),
  )
}

///|
test "with template: true, each tool call's rendered id, name and arguments make its tool_use block, a string holding an object is sent as that object, and a generated id is toolu_ and the Chat call id's slot" {
  let file = (
    "anthropic.yaml",
    (
      #|mocks:
      #|  - { name: anthropic, hosts: [api.anthropic.test] }
      #|stubs:
      #|  - id: echo
      #|    mock: anthropic
      #|    request: { method: POST, path: /v1/messages }
      #|    response:
      #|      status: 200
      #|      template: true
      #|      llm:
      #|        api: anthropic-messages
      #|        toolCalls:
      #|          - id: toolu_${header.x-trace}
      #|            name: ${body.tool}
      #|            arguments: { city: "${body.city}" }
      #|          - name: forecast
      #|            arguments: '{"days": ${body.days}}'
      #|    fault: { seed: 7 }
    ),
  )
  // Each request is its Stub's first match, so both forms draw the same ids.
  let send = (stream : String) => {
    harness([file]).send(
      "POST",
      "/v1/messages",
      headers=[
        ("Host", "api.anthropic.test"),
        ("Content-Type", "application/json"),
        ("X-Trace", "t1"),
      ],
      body=messages_body(
        extra=",\"tool\":\"search\",\"city\":\"Paris\",\"days\":3\{stream}",
      ),
    )
  }
  let lines = []
  match body_value(send("")) {
    { "content": Array(blocks), "stop_reason": stop_reason, .. } => {
      for block in blocks {
        lines.push(block.stringify())
      }
      lines.push("stop_reason: \{stop_reason.stringify()}")
    }
    other => lines.push(other.stringify())
  }
  // In the stream, each tool_use block's start and its joined partial_json.
  guard send(",\"stream\":true").plan.body is Events(events) else {
    fail("no events")
  }
  let mut joined = ""
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    match data {
      {
        "type": "content_block_start",
        "index": index,
        "content_block": block,
        ..
      } => lines.push("\{index.stringify()} \{block.stringify()}")
      {
        "delta": {
          "type": "input_json_delta",
          "partial_json": String(piece),
          ..
        },
        ..
      } => joined = joined + piece
      { "type": "content_block_stop", .. } => {
        lines.push("  " + joined)
        joined = ""
      }
      _ => ()
    }
  }
  inspect(
    lines.join("\n"),
    content=(
      #|{"type":"tool_use","id":"toolu_t1","name":"search","input":{"city":"Paris"}}
      #|{"type":"tool_use","id":"toolu_YuIrSuD97ENe0H2Ksa1F74QQ","name":"forecast","input":{"days":3}}
      #|stop_reason: "tool_use"
      #|0 {"type":"tool_use","id":"toolu_t1","name":"search","input":{}}
      #|  {"city":"Paris"}
      #|1 {"type":"tool_use","id":"toolu_YuIrSuD97ENe0H2Ksa1F74QQ","name":"forecast","input":{}}
      #|  {"days": 3}
    ),
  )
}
