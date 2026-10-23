// Seam 1 tests of an OpenAI Responses reply's tool calls: a Stub that
// declares them in a Definition file, its function_call items in the JSON
// reply and in the stream, their ids under fault.seed and their waits, and
// the next turn of an agent loop, told apart by `$last`.

///|
/// A Mock `openai` with the two Stubs of a Responses agent loop:
/// `ask-weather` answers an input whose last item is the user's message with
/// text and a tool call, its own seed fixing its ids, and `answer-weather`
/// one whose last item is the function call's output with text.
let functions_mock : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: ask-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { input: { $last: { role: user } } } }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        text: Let me check.
    #|        toolCalls:
    #|          - name: get_weather
    #|            arguments: { city: Paris }
    #|        usage: { input: 31, output: 18 }
    #|    fault: { seed: 7 }
    #|  - id: answer-weather
    #|    mock: openai
    #|    request:
    #|      method: POST
    #|      path: /v1/responses
    #|      body: { json: { input: { $last: { type: function_call_output } } } }
    #|    response:
    #|      status: 200
    #|      llm: { api: openai-responses, text: It is 18°C in Paris. }
  ),
)

///|
/// The first turn of the Responses conversation: the user's question, with
/// `stream: true` when `stream` is true.
fn first_input(stream? : Bool = false) -> String {
  let stream = if stream { ",\"stream\":true" } else { "" }
  "{\"model\":\"gpt-6-astra\"\{stream},\"input\":[{\"role\":\"user\",\"content\":\"Weather in Paris?\"}]}"
}

///|
/// The `output` of the Response object `outcome`'s plan sends as its JSON
/// reply, each item on a line of its own as compact JSON.
fn output_items(outcome : @engine.Outcome) -> String raise {
  guard outcome.plan.body is Bytes(body) &&
    @json.parse(@utf8.decode_lossy(body)) is { "output": Array(items), .. } else {
    fail("no output")
  }
  items.map(item => @template.compact_json(item)).join("\n")
}

///|
test "a Stub's tool calls answer as function_call items after the message item, with an fc_ id and a call_id the Stub's seed gives, the call_id with the characters of the Chat call id" {
  let h = harness([functions_mock])
  let outcome = h.responses(first_input())
  inspect(
    "\{outcome.plan.headers[1].0}: \{outcome.plan.headers[1].1}\n\{output_items(outcome)}",
    content=(
      #|x-request-id: req_r2yjBtWWwsQd6LgmRvpu3TbN
      #|{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Let me check.","annotations":[],"logprobs":[]}]}
      #|{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}
    ),
  )
}

///|
/// Each event of `outcome`'s plan, one per line: its wait, its type and
/// `sequence_number`, its `output_index`, then the item an item event opens
/// or closes, as its type and id, with a function call's call id, or the
/// piece a delta carries, or the arguments a done event gives.
fn item_events(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "no events" }
  let lines = []
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let number = match data {
      { "sequence_number": number, .. } => number.stringify()
      _ => "-"
    }
    let index = match data {
      { "output_index": index, .. } => " @\{index.stringify()}"
      _ => ""
    }
    let carries = match data {
      {
        "item": {
          "type": "function_call",
          "id": String(id),
          "call_id": String(call_id),
          ..
        },
        ..
      } => " \{id} \{call_id}"
      { "item": { "type": "message", "id": String(id), .. }, .. } => " \{id}"
      { "delta": String(piece), .. } => " \{piece.escape()}"
      { "arguments": String(arguments), .. } => " \{arguments.escape()}"
      _ => ""
    }
    lines.push(
      "\{event.delay_ms} \{event.event.unwrap_or("-")} #\{number}\{index}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "a stream sends the message item, then the function_call item with its argument pieces, each piece waiting as a text piece does, with the ids of the JSON reply" {
  let h = harness([
    paced_responses(
      "Let me check.", ", \"toolCalls\": [{ \"name\": \"get_weather\", \"arguments\": { \"city\": \"Paris\" } }], \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }",
    ),
  ])
  let outcome = h.responses(first_input(stream=true))
  inspect(
    "\{outcome.plan.headers[1].0}: \{outcome.plan.headers[1].1}\n\{item_events(outcome)}",
    content=(
      #|x-request-id: req_r2yjBtWWwsQd6LgmRvpu3TbN
      #|0 response.created #0
      #|0 response.in_progress #1
      #|0 response.output_item.added #2 @0 msg_VV1jhq1oCsnGeHaAUIiFpgab
      #|0 response.content_part.added #3 @0
      #|400 response.output_text.delta #4 @0 "Let "
      #|30 response.output_text.delta #5 @0 "me c"
      #|30 response.output_text.delta #6 @0 "heck"
      #|30 response.output_text.delta #7 @0 "."
      #|0 response.output_text.done #8 @0
      #|0 response.content_part.done #9 @0
      #|0 response.output_item.done #10 @0 msg_VV1jhq1oCsnGeHaAUIiFpgab
      #|0 response.output_item.added #11 @1 fc_TZp9I060Mzd0w4SDwiWTe2c8 call_oLxN2ar43pJJV6rqKHXsG45M
      #|30 response.function_call_arguments.delta #12 @1 "{\"ci"
      #|30 response.function_call_arguments.delta #13 @1 "ty\":"
      #|30 response.function_call_arguments.delta #14 @1 "\"Par"
      #|30 response.function_call_arguments.delta #15 @1 "is\"}"
      #|0 response.function_call_arguments.done #16 @1 "{\"city\":\"Paris\"}"
      #|0 response.output_item.done #17 @1 fc_TZp9I060Mzd0w4SDwiWTe2c8 call_oLxN2ar43pJJV6rqKHXsG45M
      #|0 response.completed #18
    ),
  )
}

///|
test "the next turn, whose last input item is the function call's output, matches the Stub that answers it with text" {
  let h = harness([functions_mock])
  let outcome = h.responses(
    (
      #|{"model":"gpt-6-astra","input":[
      #|  {"role":"user","content":"Weather in Paris?"},
      #|  {"type":"function_call","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}"},
      #|  {"type":"function_call_output","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","output":"18°C"}]}
    ),
  )
  guard outcome.plan.body is Bytes(body) &&
    @json.parse(@utf8.decode_lossy(body))
    is {
      "output": [{ "type": "message", "content": [{ "text": text, .. }], .. }],
      ..
    } else {
    fail("not one message item")
  }
  inspect(
    "\{matched_id(outcome).unwrap_or("no Stub")}: \{text.stringify()}",
    content=(
      #|answer-weather: "It is 18°C in Paris."
    ),
  )
}
