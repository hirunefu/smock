// Seam 1 tests of templates in LLM responses: with `template: true`, the
// text, each element of `chunks`, `id`, `model` and each tool call's `id`,
// `name` and `arguments` are rendered for each request, then the reply is
// cut into pieces; a template that fails gives the 500 `template failed`
// and no stream.

///|
/// A Mock `openai` whose Stub `echo` answers Chat Completions requests with
/// an LLM response with `template: true` and the `llm` members `fields`,
/// given as YAML flow members, with its own seed.
fn echo_mock(fields : String) -> (String, String) {
  (
    "openai.yaml",
    (
      $|mocks:
      $|  - { name: openai, hosts: [api.openai.test] }
      $|stubs:
      $|  - id: echo
      $|    mock: openai
      $|    request: { method: POST, path: /v1/chat/completions }
      $|    response:
      $|      status: 200
      $|      template: true
      $|      llm: { api: openai-chat, \{fields} }
      $|    fault: { seed: 7 }
    ),
  )
}

///|
/// The JSON body of a Chat Completions request whose last message is the
/// user's `content`, streamed when `stream` is true.
fn said(content : String, stream? : Bool = false) -> String {
  let message = Json::string(content).stringify()
  let stream = if stream { ",\"stream\":true" } else { "" }
  "{\"model\":\"test-model\",\"messages\":[{\"role\":\"system\",\"content\":\"Be brief.\"},{\"role\":\"user\",\"content\":\{message}}]\{stream}}"
}

///|
/// The assistant's content in the JSON body of `outcome` as it is on the
/// wire: the JSON text after `"content":`, up to the next member.
fn sent_content(outcome : @engine.Outcome) -> String {
  let body = body_text(outcome)
  guard body.find("\"content\":") is Some(start) else { return "no content" }
  let rest = body[start + 10:]
  match rest.find(",\"refusal\"") {
    Some(end) => rest[:end].to_owned()
    None => "no end"
  }
}

///|
test "a templated text echoes the request, a quote and a line break JSON-escaped in the JSON reply" {
  let h = harness([
    echo_mock("text: \"You said: ${last(body.messages).content}\""),
  ])
  let outcome = h.chat(body=said("Say \"hi\"\nthen stop"))
  inspect(
    sent_content(outcome),
    content=(
      #|"You said: Say \"hi\"\nthen stop"
    ),
  )
  inspect(
    reply_content(outcome).escape(),
    content=(
      #|"You said: Say \"hi\"\nthen stop"
    ),
  )
}

///|
/// The delta of each chunk of the stream that `outcome` plans, in order, as
/// it is on the wire: the JSON text after `"delta":`, up to the next
/// member.
fn deltas_on_the_wire(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "(not a stream)" }
  let deltas = []
  for event in events {
    let data = event.data
    guard data.find("\"delta\":") is Some(start) else { continue }
    let rest = data[start + 8:]
    guard rest.find(",\"logprobs\"") is Some(end) else { continue }
    deltas.push(rest[:end].to_owned())
  }
  deltas.join("\n")
}

///|
test "a templated text is rendered whole, then cut into pieces, and each piece JSON-escaped on the wire" {
  let h = harness([echo_mock("text: \"Echo: ${last(body.messages).content}\"")])
  let outcome = h.chat(body=said("a \"b\"\nc", stream=true))
  inspect(
    streamed_pieces(outcome),
    content=(
      #|"Echo" | ": a " | "\"b\"\n" | "c"
    ),
  )
  inspect(
    deltas_on_the_wire(outcome),
    content=(
      #|{"role":"assistant","content":""}
      #|{"content":"Echo"}
      #|{"content":": a "}
      #|{"content":"\"b\"\n"}
      #|{"content":"c"}
      #|{}
    ),
  )
}

///|
test "each element of a templated chunks is rendered on its own and stays one piece, an empty one included" {
  let h = harness([
    echo_mock(
      "chunks: [\"${last(body.messages).role}: \", \"${last(body.messages).content}\", \"\"]",
    ),
  ])
  inspect(
    streamed_pieces(h.chat(body=said("a \"b\"\nc", stream=true))),
    content=(
      #|"user: " | "a \"b\"\nc" | ""
    ),
  )
  inspect(
    reply_content(h.chat(body=said("a \"b\"\nc"))).escape(),
    content=(
      #|"user: a \"b\"\nc"
    ),
  )
}

///|
/// A Mock `openai` whose Stub `fields` renders every templated field of an
/// LLM response from the request: `id` and a tool call's `id` from a
/// header, `model`, the text, a tool call's `name` and a string
/// `arguments` from the body, and an object `arguments`, a structured
/// template, whose members keep the types of what they insert.
let fields_mock : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - { name: openai, hosts: [api.openai.test] }
    #|stubs:
    #|  - id: fields
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      llm:
    #|        api: openai-chat
    #|        id: chatcmpl-${header.x-trace}
    #|        model: ${body.model}-echo
    #|        text: Looking up ${body.city}.
    #|        toolCalls:
    #|          - id: call_${header.x-trace}
    #|            name: ${body.tool}
    #|            arguments: '{"q":${json(last(body.messages).content)}}'
    #|          - name: forecast
    #|            arguments: { city: "${body.city}", days: "${body.days}", tags: "${body.tags}" }
    #|    fault: { seed: 7 }
  ),
)

///|
/// A request to `fields_mock`, streamed when `stream` is true.
fn fields_request(h : Harness, stream? : Bool = false) -> @engine.Outcome {
  let stream = if stream { ",\"stream\":true" } else { "" }
  h.chat(
    body="{\"model\":\"test-model\",\"tool\":\"search\",\"city\":\"Paris\",\"days\":3,\"tags\":[\"a\",\"b\"],\"messages\":[{\"role\":\"user\",\"content\":\"Say \\\"hi\\\"\"}]\{stream}}",
    headers=[("X-Trace", "t1")],
  )
}

///|
test "id, model, the text, and each tool call's id, name and arguments are templates, a string arguments a text template and an object one a structured template" {
  let h = harness([fields_mock])
  let outcome = fields_request(h)
  inspect(
    [
      body_member(outcome, "id"),
      body_member(outcome, "model"),
      reply_content(outcome),
    ].join("\n"),
    content=(
      #|"chatcmpl-t1"
      #|"test-model-echo"
      #|Looking up Paris.
    ),
  )
  guard body_value(outcome)
    is { "choices": [{ "message": { "tool_calls": calls, .. }, .. }], .. } else {
    fail("no tool calls")
  }
  inspect(
    calls.stringify(),
    content=(
      #|[{"id":"call_t1","type":"function","function":{"name":"search","arguments":"{\"q\":\"Say \\\"hi\\\"\"}"}},{"id":"call_YuIrSuD97ENe0H2Ksa1F74QQ","type":"function","function":{"name":"forecast","arguments":"{\"city\":\"Paris\",\"days\":3,\"tags\":[\"a\",\"b\"]}"}}]
    ),
  )
}

///|
test "a template that fails gives the 500 template failed with at under the llm field, and no stream, for a streamed request too" {
  let failed = (fields : String) => {
    let outcome = harness([echo_mock(fields)]).chat(
      body=said("Hi", stream=true),
    )
    let journaled = match outcome.journal {
      Some({ template_error: Some(error), .. }) =>
        "journal: \{error.at}: \{error.message}"
      _ => "journal: no template error"
    }
    "\{response(outcome)}\n\{journaled}"
  }
  inspect(
    failed("text: \"Hello ${body.name}\""),
    content=(
      #|500
      #|Content-Type: application/json
      #|{"error":"template failed","stub":"echo","at":"/response/llm/text","message":"body.name is missing"}
      #|journal: /response/llm/text: body.name is missing
    ),
  )
  inspect(
    [
      failed("chunks: [Hi, \"${body.name}\"]"),
      failed("id: \"${body.id}\""),
      failed("model: \"${body.messages}\""),
      failed("toolCalls: [{ name: \"${body.tool}\", arguments: {} }]"),
      failed("toolCalls: [{ name: f, arguments: { city: \"${body.city}\" } }]"),
      failed("toolCalls: [{ name: f, arguments: \"${body.args}\", id: a }]"),
      failed("toolCalls: [{ name: f, arguments: {}, id: \"${body.id}\" }]"),
    ]
    .map(text => text.split("\n").collect()[3].to_owned())
    .join("\n"),
    content=(
      #|journal: /response/llm/chunks/1: body.name is missing
      #|journal: /response/llm/id: body.id is missing
      #|journal: /response/llm/model: an object or an array cannot be written as text; write it with json(…)
      #|journal: /response/llm/toolCalls/0/name: body.tool is missing
      #|journal: /response/llm/toolCalls/0/arguments/city: body.city is missing
      #|journal: /response/llm/toolCalls/0/arguments: body.args is missing
      #|journal: /response/llm/toolCalls/0/id: body.id is missing
    ),
  )
}

///|
test "templated tool-call ids that render the same give the 500 template failed at the later id, and ids that render apart are sent" {
  let h = harness([
    echo_mock(
      "toolCalls: [{ name: f, arguments: {}, id: call_1 }, { name: g, arguments: {}, id: \"call_${body.n}\" }, { name: h, arguments: {}, id: \"${body.id}\" }]",
    ),
  ])
  let ids = (body : String) => {
    let outcome = h.chat(body~)
    match body_value(outcome) {
      { "choices": [{ "message": { "tool_calls": Array(calls), .. }, .. }], .. } =>
        calls
        .map(call => {
          match call {
            { "id": String(id), .. } => id
            _ => "?"
          }
        })
        .join(" ")
      _ => "\{outcome.plan.status} \{body_text(outcome)}"
    }
  }
  inspect(
    [
      ids("{\"n\":2,\"id\":\"call_3\"}"),
      ids("{\"n\":1,\"id\":\"call_3\"}"),
      ids("{\"n\":2,\"id\":\"call_2\"}"),
      ids("{\"n\":2,\"id\":\"call_1\",\"stream\":true}"),
    ].join("\n"),
    content=(
      #|call_1 call_2 call_3
      #|500 {"error":"template failed","stub":"echo","at":"/response/llm/toolCalls/1/id","message":"the tool call id \"call_1\" is already used at /response/llm/toolCalls/0/id"}
      #|500 {"error":"template failed","stub":"echo","at":"/response/llm/toolCalls/2/id","message":"the tool call id \"call_2\" is already used at /response/llm/toolCalls/1/id"}
      #|500 {"error":"template failed","stub":"echo","at":"/response/llm/toolCalls/2/id","message":"the tool call id \"call_1\" is already used at /response/llm/toolCalls/0/id"}
    ),
  )
}

///|
/// A Mock `openai` whose Stub, seeded with 7, answers with `response`, its
/// header `X-Draw` drawn from a helper.
fn drawing_mock(response : String) -> (String, String) {
  (
    "openai.yaml",
    (
      $|mocks:
      $|  - { name: openai, hosts: [api.openai.test] }
      $|stubs:
      $|  - id: draws
      $|    mock: openai
      $|    request: { method: POST, path: /v1/chat/completions }
      $|    response:
      $|      status: 200
      $|      template: true
      $|      headers: { X-Draw: "${fake.int(1, 999999)}" }
      $|      \{response}
      $|    fault: { seed: 7 }
    ),
  )
}

///|
test "helpers draw in render order: the header values, then id, model, each chunk in order, then each tool call's id, name and arguments, as a json body that draws them in that order" {
  let draw = "${fake.int(1, 999999)}"
  let llm = harness([
    drawing_mock(
      "llm: { api: openai-chat, id: \"\{draw}\", model: \"\{draw}\", chunks: [\"\{draw} \", \"\{draw}\"], toolCalls: [{ id: \"\{draw}\", name: \"\{draw}\", arguments: \"\{draw}\" }, { id: \"\{draw}\", name: \"\{draw}\", arguments: { k: \"\{draw}\" } }] }",
    ),
  ]).chat()
  let header = (outcome : @engine.Outcome) => {
    outcome.plan.headers
    .iter()
    .find_first(field => field.0 == "X-Draw")
    .map_or("-", field => field.1)
  }
  guard body_value(llm)
    is {
      "id": String(id),
      "model": String(model),
      "choices": [
        {
          "message": {
            "content": String(content),
            "tool_calls": [
              {
                "id": String(id_0),
                "function": {
                  "name": String(name_0),
                  "arguments": String(arguments_0),
                  ..
                },
                ..
              },
              {
                "id": String(id_1),
                "function": {
                  "name": String(name_1),
                  "arguments": String(arguments_1),
                  ..
                },
                ..
              },
            ],
            ..
          },
          ..
        },
      ],
      ..
    } else {
    fail("not the reply: \{body_text(llm)}")
  }
  let from_llm = [
    header(llm),
    id,
    model,
    content,
    id_0,
    name_0,
    arguments_0,
    id_1,
    name_1,
    arguments_1,
  ].join(" ")
  let json = harness([
    drawing_mock(
      "json: \"\{draw} \{draw} \{draw} \{draw} \{draw} \{draw} \{draw} \{draw} \{draw} {\\\"k\\\":\{draw}}\"",
    ),
  ]).chat()
  let from_json = "\{header(json)} \{reply_text(json)}"
  inspect(from_llm == from_json, content="true")
  inspect(
    from_llm,
    content="55064 531001 185415 287175 754583 305739 835530 906526 329600 535814 {\"k\":508409}",
  )
}

///|
/// The JSON string of the body of `outcome`, or its text when it is not
/// one.
fn reply_text(outcome : @engine.Outcome) -> String {
  match body_value(outcome) {
    String(text) => text
    _ => body_text(outcome)
  }
}

///|
test "a templated header under the request-id name, in any case, replaces the generated one, as a header as written does" {
  let h = harness([
    (
      "openai.yaml",
      (
        #|mocks:
        #|  - { name: openai, hosts: [api.openai.test] }
        #|stubs:
        #|  - id: traced
        #|    mock: openai
        #|    request: { method: POST, path: /v1/chat/completions }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      headers: { X-Request-Id: "req_${header.x-trace}" }
        #|      llm: { api: openai-chat, text: "${header.x-trace}" }
      ),
    ),
  ])
  let outcome = h.chat(headers=[("X-Trace", "t1")])
  inspect(
    outcome.plan.headers.map(field => "\{field.0}: \{field.1}").join("\n"),
    content=(
      #|Content-Type: application/json
      #|X-Request-Id: req_t1
    ),
  )
  inspect(reply_content(outcome), content="t1")
}

///|
/// The text of the reply in `outcome`, then each tool call's name and
/// arguments, or its status and body when it is not a reply.
fn said_and_called(outcome : @engine.Outcome) -> String {
  match body_value(outcome) {
    {
      "choices": [
        { "message": { "content": content, "tool_calls"? : calls, .. }, .. },
      ],
      ..
    } => {
      let out = [content.stringify()]
      if calls is Some(Array(calls)) {
        for call in calls {
          if call
            is {
              "function": {
                "name": String(name),
                "arguments": String(arguments),
                ..
              },
              ..
            } {
            out.push("\{name}(\{arguments})")
          }
        }
      }
      out.join(" ")
    }
    _ => "\{outcome.plan.status} \{body_text(outcome)}"
  }
}

///|
test "an llm reply's templates read the Variables and the Data bucket that its Stub's variables and dataWrites have just written, in each Session" {
  let h = harness([
    (
      "openai.yaml",
      (
        #|mocks:
        #|  - { name: openai, hosts: [api.openai.test] }
        #|data:
        #|  - { mock: openai, name: turns, json: [] }
        #|stubs:
        #|  - id: chat
        #|    mock: openai
        #|    request: { method: POST, path: /v1/chat/completions }
        #|    variables:
        #|      user: ${body.user ?? vars.user ?? 'nobody'}
        #|    dataWrites:
        #|      - { op: append, bucket: turns, value: "${last(body.messages).content}" }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      llm:
        #|        api: openai-chat
        #|        model: ${vars.user}-model
        #|        text: Turn ${len(data.turns)} for ${vars.user}, after ${data.turns[0]}.
        #|        toolCalls:
        #|          - name: remember
        #|            arguments: { said: "${last(data.turns)}", turns: "${data.turns}" }
      ),
    ),
  ])
  let turn = (body : String, session : String) => {
    let outcome = h.chat(body~, session~)
    "\{session}: \{body_member(outcome, "model")} \{said_and_called(outcome)}"
  }
  inspect(
    [
      turn(
        "{\"user\":\"ann\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
        "s",
      ),
      turn("{\"messages\":[{\"role\":\"user\",\"content\":\"Bye\"}]}", "s"),
      turn("{\"messages\":[{\"role\":\"user\",\"content\":\"Yo\"}]}", "t"),
    ].join("\n"),
    content=(
      #|s: "ann-model" "Turn 1 for ann, after Hi." remember({"said":"Hi","turns":["Hi"]})
      #|s: "ann-model" "Turn 2 for ann, after Hi." remember({"said":"Bye","turns":["Hi","Bye"]})
      #|t: "nobody-model" "Turn 1 for nobody, after Yo." remember({"said":"Yo","turns":["Yo"]})
    ),
  )
}

///|
test "a Scenario moves on an llm Stub: its first turn asks for a tool, and the next, in the state it moved to, answers from a template" {
  let h = harness([
    (
      "openai.yaml",
      (
        #|mocks:
        #|  - { name: openai, hosts: [api.openai.test] }
        #|stubs:
        #|  - id: ask
        #|    mock: openai
        #|    request: { method: POST, path: /v1/chat/completions }
        #|    scenario: { name: weather, requires: Started, moveTo: Asked }
        #|    response:
        #|      status: 200
        #|      llm: { api: openai-chat, toolCalls: [{ name: get_weather, arguments: { city: Paris } }] }
        #|  - id: answer
        #|    mock: openai
        #|    request: { method: POST, path: /v1/chat/completions }
        #|    scenario: { name: weather, requires: Asked }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      llm: { api: openai-chat, text: "It is ${last(body.messages).content} in Paris." }
      ),
    ),
  ])
  let turn = (content : String, session : String) => {
    let outcome = h.chat(
      body="{\"messages\":[{\"role\":\"tool\",\"content\":\"\{content}\"}]}",
      session~,
    )
    "\{session}: \{matched_id(outcome).unwrap_or("-")} \{said_and_called(outcome)}"
  }
  inspect(
    [turn("-", "s"), turn("18°C", "s"), turn("19°C", "s"), turn("-", "t")].join(
      "\n",
    ),
    content=(
      #|s: ask null get_weather({"city":"Paris"})
      #|s: answer "It is 18°C in Paris."
      #|s: answer "It is 19°C in Paris."
      #|t: ask null get_weather({"city":"Paris"})
    ),
  )
}
