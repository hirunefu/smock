// Tests of templates in LLM responses: with `template: true`, which fields
// of `llm` are templates, how their problems are reported when the
// definitions are loaded, and what the response reads.

///|
/// A Definition file with a Mock `m` and, for each of `llm`, given as YAML
/// flow members, a Stub whose response gives `llm` with `template: true`.
fn templated_llm(llm : Array[String]) -> (String, String) {
  let stubs = StringBuilder()
  for i, members in llm {
    stubs.write_string(
      "  - { id: s\{i}, mock: m, response: { status: 200, template: true, llm: { api: openai-chat, \{members} } } }\n",
    )
  }
  ("a.yaml", "mocks:\n  - name: m\nstubs:\n\{stubs}")
}

///|
test "with template: true, text, each chunk, id, model and each tool call's name, id and arguments are parsed at load, each problem at the field's JSON Pointer" {
  inspect(
    problems([
      templated_llm([
        "text: \"Hi ${\"", "chunks: [Hi, \"${ }\"]", "id: \"${unknown()}\"", "model: \"${body.}\"",
        "toolCalls: [{ name: \"${\", arguments: {} }]", "toolCalls: [{ name: f, arguments: {}, id: \"${fake.int(2, 1)}\" }]",
        "toolCalls: [{ name: f, arguments: \"{\\\"q\\\": ${body.q\" }]", "toolCalls: [{ name: f, arguments: { city: \"${body.city\" } }]",
        "toolCalls: [{ name: f, arguments: { $if: \"body.a\", then: {} } }]", "text: \"${vars.x}\", chunkSize: 4, usage: { input: 1, output: 2 }, stopReason: length",
      ]),
    ]),
    content=(
      #|a.yaml: /stubs/0/response/llm/text: template: column 4: the ${ is not closed
      #|a.yaml: /stubs/1/response/llm/chunks/1: template: column 1: the ${ } is empty
      #|a.yaml: /stubs/2/response/llm/id: template: column 3: unknown helper "unknown": not one of the helpers smock has
      #|a.yaml: /stubs/3/response/llm/model: template: column 8: expected a name after .
      #|a.yaml: /stubs/4/response/llm/toolCalls/0/name: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/5/response/llm/toolCalls/0/id: template: column 3: fake.int(): the minimum 2 exceeds the maximum 1
      #|a.yaml: /stubs/6/response/llm/toolCalls/0/arguments: template: column 7: the ${ is not closed
      #|a.yaml: /stubs/7/response/llm/toolCalls/0/arguments/city: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/8/response/llm/toolCalls/0/arguments: template: a $if at the root of a tool call's arguments needs "else", so that it always gives a value
    ),
  )
}

///|
test "with template: true, the error's message is parsed at load, each problem at its JSON Pointer; after, type and code are never templates" {
  inspect(
    problems([
      templated_llm([
        "text: Hi, error: { type: server_error, message: \"Overloaded ${\" }", "text: Hi, error: { type: server_error, message: \"${unknown()}\" }",
        "text: Hi, error: { type: server_error, message: \"Overloaded ${body.model}\" }",
        "text: Hi, error: { after: \"${body.n}\", type: server_error, message: Overloaded }",
        "text: Hi, error: { type: \"${body.type}\", message: Overloaded }",
      ]),
    ]),
    content=(
      #|a.yaml: /stubs/0/response/llm/error/message: template: column 12: the ${ is not closed
      #|a.yaml: /stubs/1/response/llm/error/message: template: column 3: unknown helper "unknown": not one of the helpers smock has
      #|a.yaml: /stubs/3/response/llm/error/after: must be an integer from 0 to 2147483647
    ),
  )
}

///|
test "with template: true, an error's after past the text as written is no load error, since the text is known once rendered; with template off it is one" {
  inspect(
    problems([
      templated_llm([
        "text: Hi, error: { after: 10, type: server_error, message: Overloaded }",
        "chunks: [Hi, \"${body.name}\"], error: { after: 10, type: server_error, message: Overloaded }",
        "error: { after: 1, type: server_error, message: Overloaded }",
      ]),
      (
        "b.yaml",
        (
          #|stubs:
          #|  - id: plain
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm: { api: openai-chat, text: Hi, error: { after: 10, type: server_error, message: Overloaded } }
          #|  - id: template-last
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm: { api: openai-chat, text: Hi, error: { after: 10, type: server_error, message: Overloaded } }
          #|      template: true
        ),
      ),
    ]),
    content=(
      #|b.yaml: /stubs/0/response/llm/error/after: is past the end of the text, which has 2 code points
    ),
  )
}

///|
test "api, stopReason, usage, chunkSize and timing are never templates, and with template off nothing in llm is parsed" {
  inspect(
    problems([
      templated_llm([
        "stopReason: \"${body.reason}\"", "usage: { input: \"${body.n}\", output: 0 }",
        "chunkSize: \"${body.n}\"", "timing: { first: { fixed: \"${body.n}\" } }",
      ]),
      (
        "b.yaml",
        (
          #|stubs:
          #|  - id: plain
          #|    mock: m
          #|    response:
          #|      status: 200
          #|      llm: { api: openai-chat, text: "${", id: "${", toolCalls: [{ name: "${", arguments: { a: "${" } }] }
        ),
      ),
    ]),
    content=(
      #|a.yaml: /stubs/0/response/llm/stopReason: must be a stop reason of openai-chat: "stop", "length", "tool_calls", "content_filter" or "function_call"
      #|a.yaml: /stubs/1/response/llm/usage/input: must be an integer from 0 to 9007199254740991
      #|a.yaml: /stubs/2/response/llm/chunkSize: must be an integer from 1 to 1000000
      #|a.yaml: /stubs/3/response/llm/timing/first/fixed: must be an integer from 0 to 2147483647
    ),
  )
}

///|
test "with template: true, two tool calls whose ids insert nothing and are the same are refused at load, and ids that insert a value are left to their rendering" {
  inspect(
    problems([
      templated_llm([
        "toolCalls: [{ name: f, arguments: {}, id: call_1 }, { name: g, arguments: {}, id: call_1 }]",
        "toolCalls: [{ name: f, arguments: {}, id: \"a$${b}\" }, { name: g, arguments: {}, id: \"a$${b}\" }]",
        "toolCalls: [{ name: f, arguments: {}, id: \"${body.id}\" }, { name: g, arguments: {}, id: \"${body.id}\" }]",
        "toolCalls: [{ name: f, arguments: {}, id: call_1 }, { name: g, arguments: {}, id: \"call_${body.n}\" }]",
      ]),
    ]),
    content=(
      #|a.yaml: /stubs/0/response/llm/toolCalls/1/id: the tool call id "call_1" is already used at a.yaml: /stubs/0/response/llm/toolCalls/0/id
      #|a.yaml: /stubs/1/response/llm/toolCalls/1/id: the tool call id "a${b}" is already used at a.yaml: /stubs/1/response/llm/toolCalls/0/id
    ),
  )
}

///|
test "an llm response reads Variables and Data buckets when one of its templates reads them, in any templated field, and not otherwise" {
  let fields = [
    "text: \"${path}\", id: \"$${vars.x} $${data.d}\"", "text: \"${vars.x}\"", "chunks: [a, \"${data.d}\"]",
    "id: \"${vars.x}\"", "model: \"${data.d}\"", "toolCalls: [{ name: \"${vars.x}\", arguments: {} }]",
    "toolCalls: [{ name: f, arguments: {}, id: \"${data.d}\" }]", "toolCalls: [{ name: f, arguments: \"${vars.x}\" }]",
    "toolCalls: [{ name: f, arguments: { a: \"${data.d}\" } }]",
  ]
  let (name, file) = templated_llm(fields)
  let set : @definitions.DefinitionSet = {
    files: [
      (name, @utf8.encode(file + "data:\n  - { mock: m, name: d, json: 1 }\n")),
      (
        "b.yaml",
        @utf8.encode(
          (
            #|stubs:
            #|  - id: plain
            #|    mock: m
            #|    response: { status: 200, llm: { api: openai-chat, text: "${vars.x} ${data.d}" } }
          ),
        ),
      ),
    ],
    body_files: [],
  }
  let snapshot = match @definitions.load(set) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
  let out = []
  for stub in snapshot.mocks[0].stubs {
    guard stub.serves is Ordinary(ordinary) else {
      fail("\{stub.id} is not an ordinary Stub")
    }
    let response = ordinary.responses[0].response
    out.push(
      "\{stub.id}: vars \{response.reads_variables}, data \{response.reads_data}",
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|s0: vars false, data false
      #|s1: vars true, data false
      #|s2: vars false, data true
      #|s3: vars true, data false
      #|s4: vars false, data true
      #|s5: vars true, data false
      #|s6: vars false, data true
      #|s7: vars true, data false
      #|s8: vars false, data true
      #|plain: vars false, data false
    ),
  )
}
