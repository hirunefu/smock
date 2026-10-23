// Tests of last(array) through the template package's public interface:
// the last element with its own type, steps after the call, what is
// missing, and the render errors and load errors of its argument. They run
// on native and on wasm-gc, and give the same output on both.

///|
/// A request whose body holds a conversation, as an LLM API takes it, and
/// arrays of other kinds.
let conversation : @template.Input = {
  meth: "POST",
  path: "/v1/chat/completions",
  query: [("q", "Paris")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "messages": [
      #|    { "role": "user", "content": "What is the weather in Paris?" },
      #|    { "role": "assistant", "content": null },
      #|    { "role": "tool", "content": "18 °C, sunny" } ],
      #|  "numbers": [1, 2.50, 3],
      #|  "nested": [["a"], ["b", "c"]],
      #|  "one": ["only"],
      #|  "nulls": [1, null],
      #|  "empty": [] }
    ),
  ),
}

///|
test "last gives the last element of an array, which steps can follow" {
  inspect(
    [
      rendered(
        "It is ${last(body.messages).content} in Paris.",
        input=conversation,
      ),
      rendered("${last(body.messages).role}", input=conversation),
      rendered("${last(body.messages)['role']}", input=conversation),
      rendered("${last(body.nested)[1]}", input=conversation),
      rendered("${last(body.one)}", input=conversation),
      rendered("${last(body.numbers)}", input=conversation),
    ].join("\n"),
    content=(
      #|It is 18 °C, sunny in Paris.
      #|tool
      #|tool
      #|c
      #|only
      #|3
    ),
  )
}

///|
test "in a structured template, last gives the element with its own type" {
  inspect(
    rendered_json(
      (
        #|{ "message": "${last(body.messages)}", "number": "${last(body.numbers)}",
        #|  "array": "${last(body.nested)}", "null": "${last(body.nulls)}",
        #|  "text": "${last(body.one)}", "role": "${last(body.messages).role}",
        #|  "each": { "$each": "body.nested", "as": "xs", "do": "${last(xs)}" } }
      ),
      input=conversation,
    ),
    content=(
      #|{"message":{"role":"tool","content":"18 °C, sunny"},"number":3,"array":["b","c"],"null":null,"text":"only","role":"tool","each":["a","c"]}
    ),
  )
}

///|
test "last of an empty array, a step past what it gives, or a missing argument, is missing, so ?? applies" {
  inspect(
    [
      rendered("${last(body.empty) ?? 'no message'}", input=conversation),
      rendered(
        "${last(body.empty).content ?? 'no content'}",
        input=conversation,
      ),
      rendered(
        "${last(body.one).content ?? 'not an object'}",
        input=conversation,
      ),
      rendered("${last(body.missing) ?? 'no messages'}", input=conversation),
      rendered(
        "${last(query.missing ?? body.missing) ?? 'none'}",
        input=conversation,
      ),
      rendered_json(
        "{ \"last\": \"${last(body.empty) ?? null}\" }",
        input=conversation,
      ),
      rendered("${last(body.empty)}", input=conversation),
      rendered("${last(body.empty).content}", input=conversation),
      rendered("${last(body.missing)}", input=conversation),
    ].join("\n"),
    content=(
      #|no message
      #|no content
      #|not an object
      #|no messages
      #|none
      #|{"last":null}
      #|error at /response/body: last(body.empty) is missing
      #|error at /response/body: last(body.empty) is missing
      #|error at /response/body: body.missing is missing
    ),
  )
}

///|
test "an argument that is not an array is a render error, which a fallback does not catch" {
  inspect(
    [
      rendered("${last(body.messages[0])}", input=conversation),
      rendered("${last(body.messages[0].content)}", input=conversation),
      rendered("${last(body.messages[1].content)}", input=conversation),
      rendered("${last(body.numbers[0])}", input=conversation),
      rendered("${last(query.q)}", input=conversation),
      rendered("${last(path)}", input=conversation),
      rendered("${last(body.messages[0]) ?? 'not caught'}", input=conversation),
      rendered_json(
        "{ \"last\": \"${last(body.messages[0]).role}\" }",
        input=conversation,
      ),
    ].join("\n"),
    content=(
      #|error at /response/body: last(): argument 1 must be an array, not an object
      #|error at /response/body: last(): argument 1 must be an array, not "What is the weather in Paris?"
      #|error at /response/body: last(): argument 1 must be an array, not null
      #|error at /response/body: last(): argument 1 must be an array, not 1
      #|error at /response/body: last(): argument 1 must be an array, not "Paris"
      #|error at /response/body: last(): argument 1 must be an array, not "/v1/chat/completions"
      #|error at /response/body: last(): argument 1 must be an array, not an object
      #|error at /response/json/last: last(): argument 1 must be an array, not an object
    ),
  )
}

///|
test "a literal argument that is not an array, or a call without one argument, is a load error" {
  inspect(
    [
      rendered("${last('messages')}", input=conversation),
      rendered("${last(1)}", input=conversation),
      rendered("${last(true)}", input=conversation),
      rendered("${last(null)}", input=conversation),
      rendered("${last(body.messages ?? 'none')}", input=conversation),
      rendered("${last()}", input=conversation),
      rendered("${last(body.one, body.nested)}", input=conversation),
      rendered_json("{ \"last\": \"${last(0).x}\" }", input=conversation),
    ].join("\n"),
    content=(
      #|problem at /response/body: template: column 8: last(): argument 1 must be an array, not "messages"
      #|problem at /response/body: template: column 8: last(): argument 1 must be an array, not 1
      #|problem at /response/body: template: column 8: last(): argument 1 must be an array, not true
      #|problem at /response/body: template: column 8: last(): argument 1 must be an array, not null
      #|problem at /response/body: template: column 8: last(): argument 1 must be an array, not "none"
      #|problem at /response/body: template: column 3: last() takes 1 argument, not 0
      #|problem at /response/body: template: column 3: last() takes 1 argument, not 2
      #|problem at /response/json/last: template: column 8: last(): argument 1 must be an array, not 0
    ),
  )
}

///|
test "last draws nothing, so the helpers around it give what they give without it" {
  inspect(
    [
      rendered("${fake.hex(8)} ${fake.hex(8)}", input=conversation),
      rendered(
        "${fake.hex(8)} ${last(body.one)} ${last(body.empty) ?? '-'} ${fake.hex(8)}",
        input=conversation,
      ),
    ].join("\n"),
    content=(
      #|55c4f5c9 07679344
      #|55c4f5c9 only - 07679344
    ),
  )
}
