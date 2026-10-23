// Seam 1 tests of the stream switch of LLM responses: a request whose JSON
// body sets `stream: true` gets the reply as Server-Sent Events, any other
// the JSON reply, with Faults, HEAD, a status without content and render.

///|
/// The JSON body of a Chat Completions request for `test-model` whose
/// `stream` member is `stream`, given as JSON text.
fn stream_body(stream : String) -> String {
  "{\"model\":\"test-model\",\"stream\":\{stream},\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
}

///|
test "a request whose JSON body has stream: true gets the reply as chat.completion.chunk events, as text/event-stream in place of the Stub's Content-Type" {
  let h = harness([chat_mock])
  inspect(
    response(h.chat(body=stream_body("true"))),
    content=(
      #|200
      #|Content-Type: text/event-stream
      #|x-ratelimit-remaining-requests: 59
      #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hell\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o! H\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ow c\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"an I\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" ass\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ist \"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"you \"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"toda\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"y?\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|after 0 ms: event -, id -, data "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1791815405,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"logprobs\":null,\"finish_reason\":\"stop\"}]}"
      #|after 0 ms: event -, id -, data "[DONE]"
      #|
    ),
  )
}

///|
/// The form of `outcome`'s plan: its status and Content-Type, then the
/// number of its events, or the `object` member of its JSON body.
fn form(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let content_type = plan.headers
    .iter()
    .find_first(header => header.0 == "Content-Type")
    .map_or("-", header => header.1)
  let body = match plan.body {
    Events(events) => "\{events.length()} events"
    Bytes(_) => "a body with object \{body_member(outcome, "object")}"
  }
  "\{plan.status} \{content_type}, \{body}"
}

///|
test "any other request gets the JSON reply: stream false, the string \"true\", no stream, and a body that is not JSON" {
  let h = harness([chat_mock])
  inspect(
    [
      "true: \{form(h.chat(body=stream_body("true")))}",
      "false: \{form(h.chat(body=stream_body("false")))}",
      "\"true\": \{form(h.chat(body=stream_body("\"true\"")))}",
      "null: \{form(h.chat(body=stream_body("null")))}",
      "missing: \{form(h.chat(body=chat_body(Some("test-model"))))}",
      "not JSON: \{form(h.chat(body="stream: true"))}",
      "empty: \{form(h.chat(body=""))}",
    ].join("\n"),
    content=(
      #|true: 200 text/event-stream, 12 events
      #|false: 200 application/json, a body with object "chat.completion"
      #|"true": 200 application/json, a body with object "chat.completion"
      #|null: 200 application/json, a body with object "chat.completion"
      #|missing: 200 application/json, a body with object "chat.completion"
      #|not JSON: 200 application/json, a body with object "chat.completion"
      #|empty: 200 application/json, a body with object "chat.completion"
    ),
  )
}

///|
test "with a partial Fault and a delay, the engine plans every event, or the whole JSON body, with the Fault and the delay" {
  let h = harness([
    (
      chat_mock.0,
      chat_mock.1.replace(
        old="\"fault\": { \"seed\": 7 }",
        new="\"fault\": { \"seed\": 7, \"delay\": { \"fixed\": 30 }, \"connection\": { \"kind\": \"partial\" } }",
      ),
    ),
  ])
  let faults = (outcome : @engine.Outcome) => {
    "\{form(outcome)}; delay \{outcome.plan.delay_ms} ms, fault \{@debug.to_string(outcome.plan.fault)}; Journal fault \{@debug.to_string(outcome.journal.map(entry => entry.fault))}"
  }
  inspect(
    [
      "stream: \{faults(h.chat(body=stream_body("true")))}",
      "JSON: \{faults(h.chat(body=stream_body("false")))}",
    ].join("\n"),
    content=(
      #|stream: 200 text/event-stream, 12 events; delay 30 ms, fault Some(Partial); Journal fault Some(Some(Partial))
      #|JSON: 200 application/json, a body with object "chat.completion"; delay 30 ms, fault Some(Partial); Journal fault Some(Some(Partial))
    ),
  )
}

///|
/// A Mock `openai` whose LLM Stubs answer any method on
/// `/v1/chat/completions`, with 204 on `/no-content` and with 304 on
/// `/not-modified`.
let statuses_mock : (String, String) = (
  "openai.json",
  (
    #|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
    #|  "stubs": [
    #|    { "id": "any-method", "mock": "openai",
    #|      "request": { "path": "/v1/chat/completions" },
    #|      "response": { "status": 200, "llm": { "api": "openai-chat", "text": "Hi!" } } },
    #|    { "id": "no-content", "mock": "openai", "request": { "path": "/no-content" },
    #|      "response": { "status": 204, "llm": { "api": "openai-chat", "text": "Hi!" } } },
    #|    { "id": "not-modified", "mock": "openai", "request": { "path": "/not-modified" },
    #|      "response": { "status": 304, "llm": { "api": "openai-chat", "text": "Hi!" } } } ] }
  ),
)

///|
/// What the HTTP/1.1 codec writes for the plan of `outcome`, as the server
/// writes it in answer to a `meth` request: the head and the body of a JSON
/// reply, or the head, a chunk per event and the end of a stream. Its Date
/// is fixed, and its line ends show as LF.
fn on_the_wire(outcome : @engine.Outcome, meth : String) -> String {
  let request : @http1.Request = {
    meth,
    target: "/",
    version: Http11,
    headers: [],
    body: b"",
    keep_alive: true,
  }
  let plan = outcome.plan
  let date = "Mon, 12 Oct 2026 14:30:05 GMT"
  let bytes = match plan.body {
    Bytes(body) =>
      @http1.encode_response(plan.status, plan.headers, body, request~, date~)
    Events(events) => {
      let stream = @http1.ResponseStream(
        plan.status,
        plan.headers,
        request~,
        date~,
      )
      let out = @buffer.Buffer()
      out.write_bytes(stream.head())
      for event in events {
        out.write_bytes(
          stream.part(
            @http1.encode_sse_event(
              event.data,
              event?=event.event,
              id?=event.id,
            ),
          ),
        )
      }
      out.write_bytes(stream.end())
      out.to_bytes()
    }
  }
  @utf8.decode_lossy(bytes).replace_all(old="\r\n", new="\n")
}

///|
test "a reply to HEAD, or with status 204 or 304, is the head alone, for the stream as for the JSON reply" {
  let h = harness([statuses_mock])
  let send = (meth : String, path : String, stream : String) => {
    let outcome = h.send(
      meth,
      path,
      headers=[("Host", "api.openai.test")],
      body=stream_body(stream),
    )
    "\{meth} \{path}, stream \{stream}:\n\{on_the_wire(outcome, meth)}"
  }
  inspect(
    [
      send("HEAD", "/v1/chat/completions", "true"),
      send("HEAD", "/v1/chat/completions", "false"),
      send("POST", "/no-content", "true"),
      send("POST", "/no-content", "false"),
      send("POST", "/not-modified", "true"),
      send("POST", "/not-modified", "false"),
    ].join("--\n"),
    content=(
      #|HEAD /v1/chat/completions, stream true:
      #|HTTP/1.1 200 OK
      #|Content-Type: text/event-stream
      #|x-request-id: req_sJNCUcA0CWrNZKC6RTXrx2qy
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|Transfer-Encoding: chunked
      #|
      #|--
      #|HEAD /v1/chat/completions, stream false:
      #|HTTP/1.1 200 OK
      #|Content-Type: application/json
      #|x-request-id: req_fK1WtgcCBbTWteWM2iZw2jBF
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|Content-Length: 536
      #|
      #|--
      #|POST /no-content, stream true:
      #|HTTP/1.1 204 No Content
      #|Content-Type: text/event-stream
      #|x-request-id: req_lDj96YCg3g5sUx8DB3OXKUJ3
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|
      #|--
      #|POST /no-content, stream false:
      #|HTTP/1.1 204 No Content
      #|Content-Type: application/json
      #|x-request-id: req_a361XihHfVpqOR0DFxRb8HGj
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|
      #|--
      #|POST /not-modified, stream true:
      #|HTTP/1.1 304 Not Modified
      #|Content-Type: text/event-stream
      #|x-request-id: req_vGCkDAGSq05n3K1ld1QxhFIz
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|
      #|--
      #|POST /not-modified, stream false:
      #|HTTP/1.1 304 Not Modified
      #|Content-Type: application/json
      #|x-request-id: req_q4hAwFeEs9a2NKGhmyjNx29B
      #|Date: Mon, 12 Oct 2026 14:30:05 GMT
      #|
      #|
    ),
  )
}

///|
test "render shows the events for a sample whose body sets stream: true, through the path a request takes, and the JSON body for any other sample" {
  let h = harness([statuses_mock])
  let sample = (body : String) => {
    let json : Json = {
      "method": "POST",
      "path": "/v1/chat/completions",
      "headers": { "Host": "api.openai.test" },
      "body": body,
    }
    json
  }
  h.now = 1_792_713_600_500L
  inspect(
    h.render("any-method", sample(stream_body("true"))),
    content=(
      #|{
      #|  "stub": "any-method",
      #|  "mock": "openai",
      #|  "time": "2026-10-23T00:00:00.500Z",
      #|  "seed": 7,
      #|  "responseIndex": null,
      #|  "variables": {},
      #|  "dataWrites": [],
      #|  "response": {
      #|    "status": 200,
      #|    "headers": [
      #|      {
      #|        "name": "Content-Type",
      #|        "value": "text/event-stream"
      #|      },
      #|      {
      #|        "name": "x-request-id",
      #|        "value": "req_TZp9I060Mzd0w4SDwiWTe2c8"
      #|      }
      #|    ],
      #|    "body": null,
      #|    "events": [
      #|      {
      #|        "delay": 0,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|      },
      #|      {
      #|        "delay": 0,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi!\"},\"logprobs\":null,\"finish_reason\":null}]}"
      #|      },
      #|      {
      #|        "delay": 0,
      #|        "data": "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"test-model\",\"choices\":[{\"index\":0,\"delta\":{},\"logprobs\":null,\"finish_reason\":\"stop\"}]}"
      #|      },
      #|      {
      #|        "delay": 0,
      #|        "data": "[DONE]"
      #|      }
      #|    ]
      #|  },
      #|  "templateError": null,
      #|  "failed": []
      #|}
    ),
  )
  let brief = (rendering : String) => {
    let json = @json.parse(rendering) catch { _ => Json::null() }
    match json {
      {
        "response": { "body": { "data": String(data), .. }, "events": Null, .. },
        ..
      } => {
        let body = @json.parse(data) catch { _ => Json::null() }
        match body {
          { "object": object, .. } => "a body with object \{object.stringify()}"
          _ => "a body: \{data}"
        }
      }
      { "response": { "body": Null, "events": Array(events), .. }, .. } =>
        "\{events.length()} events"
      _ => rendering
    }
  }
  inspect(
    [
      "false: \{brief(h.render("any-method", sample(stream_body("false"))))}",
      "\"true\": \{brief(h.render("any-method", sample(stream_body("\"true\""))))}",
      "missing: \{brief(h.render("any-method", sample(chat_body(Some("test-model")))))}",
      "not JSON: \{brief(h.render("any-method", sample("stream: true")))}",
    ].join("\n"),
    content=(
      #|false: a body with object "chat.completion"
      #|"true": a body with object "chat.completion"
      #|missing: a body with object "chat.completion"
      #|not JSON: a body with object "chat.completion"
    ),
  )
}
