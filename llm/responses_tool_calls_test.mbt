// Tests of an openai-responses reply's tool calls through the package's
// public interface: the function_call items of the JSON reply's `output`,
// the stream's function_call events, their ids and the waits they take.
// They run on native and on wasm-gc with the same output.

///|
/// The reply to a request whose body is `request`, by default one without
/// `stream`, for an `openai-responses` declaration with `text`, or the
/// `chunks` given, `tool_calls`, and the chunk size and stop reason given,
/// with ids drawn from the generator of the draw `draw`.
fn responses_calls(
  text : String,
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  chunks? : ReadOnlyArray[String],
  request~ : Json? = Some({ "model": "gpt-6-astra" }),
  draw~ : UInt64 = 7,
  chunk_size? : Int32,
  stop_reason? : String,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(
      api=OpenaiResponses,
      chunk_size?,
      stop_reason?=stop_reason.map(word => {
        @llm.read_stop_reason(OpenaiResponses, Json::string(word)).unwrap()
      }),
    ),
    @llm.Strings(text~, chunks?, tool_calls~),
    request~,
    now=received,
    ids=@llm.ids_generator(draw),
  )
}

///|
/// The `output` of the Response object that the JSON reply `reply` sends,
/// each item on a line of its own as compact JSON.
fn output_of(reply : @llm.Reply) -> String raise {
  guard @json.parse(json_text(reply)) is { "output": Array(items), .. } else {
    fail("no output")
  }
  items.map(item => @template.compact_json(item)).join("\n")
}

///|
test "a JSON reply with tool calls and no text has no message item: output holds one function_call item per call, completed" {
  inspect(
    output_of(responses_calls("", [weather()])),
    content=(
      #|{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}
    ),
  )
}

///|
test "text comes first in its message item, then each tool call's item in the order written; object arguments are compact JSON and a string is sent as written, broken or not" {
  inspect(
    output_of(
      responses_calls("Let me check.", [
        @llm.ToolCall(name="get_weather", arguments={
          "city": "Paris",
          "days": 1.50,
          "units": ["c", "f"],
        }),
        @llm.ToolCall(name="get_time", arguments="{\"zone\": \"Europe/Par"),
      ]),
    ),
    content=(
      #|{"id":"msg_mGR88Teee4muTOOd2B3UzQJr","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Let me check.","annotations":[],"logprobs":[]}]}
      #|{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\",\"days\":1.5,\"units\":[\"c\",\"f\"]}","status":"completed"}
      #|{"type":"function_call","id":"fc_lXej21FbJgs0WxlXP0AqXTyU","call_id":"call_DbhbAGir3qs3o77JKr2BTN9j","name":"get_time","arguments":"{\"zone\": \"Europe/Par","status":"completed"}
    ),
  )
}

///|
test "a stream with tool calls and no text has no message item: each call's item is added with empty arguments, one arguments delta per piece follows, then the arguments' done and the item's done" {
  inspect(
    shown(
      responses_calls(
        "",
        [weather()],
        request=Some({ "model": "gpt-6-astra", "stream": true }),
      ),
    ),
    content=(
      #|Content-Type: text/event-stream
      #|x-request-id: req_lXej21FbJgs0WxlXP0AqXTyU
      #|(none) event: response.created data: {"type":"response.created","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}
      #|(none) event: response.in_progress data: {"type":"response.in_progress","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":1}
      #|(none) event: response.output_item.added data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"","status":"in_progress"},"sequence_number":2}
      #|(first) event: response.function_call_arguments.delta data: {"type":"response.function_call_arguments.delta","item_id":"fc_5DTBZPrxiMH6i7M92iahxjWk","output_index":0,"delta":"{\"ci","sequence_number":3}
      #|(interval) event: response.function_call_arguments.delta data: {"type":"response.function_call_arguments.delta","item_id":"fc_5DTBZPrxiMH6i7M92iahxjWk","output_index":0,"delta":"ty\":","sequence_number":4}
      #|(interval) event: response.function_call_arguments.delta data: {"type":"response.function_call_arguments.delta","item_id":"fc_5DTBZPrxiMH6i7M92iahxjWk","output_index":0,"delta":"\"Par","sequence_number":5}
      #|(interval) event: response.function_call_arguments.delta data: {"type":"response.function_call_arguments.delta","item_id":"fc_5DTBZPrxiMH6i7M92iahxjWk","output_index":0,"delta":"is\"}","sequence_number":6}
      #|(none) event: response.function_call_arguments.done data: {"type":"response.function_call_arguments.done","item_id":"fc_5DTBZPrxiMH6i7M92iahxjWk","output_index":0,"arguments":"{\"city\":\"Paris\"}","sequence_number":7}
      #|(none) event: response.output_item.done data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"},"sequence_number":8}
      #|(none) event: response.completed data: {"type":"response.completed","response":{"id":"resp_KCVauEuclT08Mg4CWd55sNbz","object":"response","access_programs":null,"created_at":1791815405,"status":"completed","completed_at":1791815405,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":0,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":0},"user":null,"metadata":{}},"sequence_number":9}
      #|
    ),
  )
}

///|
/// The stream request `responses_calls` sends with `stream: true`.
let streamed : Json? = Some({ "model": "gpt-6-astra", "stream": true })

///|
/// The events of the stream `reply`, one per line: each one's wait slot,
/// `event:` line, `sequence_number` and `output_index`, with the item an
/// item event opens or closes, as its type, id, call id and status, or the
/// piece a delta carries, or the text or arguments a done event gives.
fn call_outline(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let lines = []
  for event in events {
    let data = @json.parse(event.data)
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
          "status": String(status),
          ..
        },
        ..
      } => " function_call \{id} \{call_id} \{status}"
      {
        "item": {
          "type": "message",
          "id": String(id),
          "status": String(status),
          ..
        },
        ..
      } => " message \{id} \{status}"
      { "delta": String(piece), .. } => " \{piece.escape()}"
      { "text": String(text), .. } => " \{text.escape()}"
      { "arguments": String(arguments), .. } => " \{arguments.escape()}"
      { "response": { "status": String(status), .. }, .. } => " \{status}"
      _ => ""
    }
    lines.push(
      "(\{slot(event.wait)}) \{event.event.unwrap_or("-")} #\{number}\{index}\{carries}",
    )
  }
  lines.join("\n")
}

///|
test "a stream with text and two tool calls sends the message item at output_index 0, then each call's item at the next one, its arguments in pieces of the text's chunk size" {
  inspect(
    call_outline(
      responses_calls(
        "Let me check.",
        [
          weather(),
          @llm.ToolCall(name="get_time", arguments="{\"zone\": \"Europe/Par"),
        ],
        request=streamed,
        chunk_size=8,
      ),
    ),
    content=(
      #|(none) response.created #0 in_progress
      #|(none) response.in_progress #1 in_progress
      #|(none) response.output_item.added #2 @0 message msg_mGR88Teee4muTOOd2B3UzQJr in_progress
      #|(none) response.content_part.added #3 @0
      #|(first) response.output_text.delta #4 @0 "Let me c"
      #|(interval) response.output_text.delta #5 @0 "heck."
      #|(none) response.output_text.done #6 @0 "Let me check."
      #|(none) response.content_part.done #7 @0
      #|(none) response.output_item.done #8 @0 message msg_mGR88Teee4muTOOd2B3UzQJr completed
      #|(none) response.output_item.added #9 @1 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ in_progress
      #|(interval) response.function_call_arguments.delta #10 @1 "{\"city\":"
      #|(interval) response.function_call_arguments.delta #11 @1 "\"Paris\"}"
      #|(none) response.function_call_arguments.done #12 @1 "{\"city\":\"Paris\"}"
      #|(none) response.output_item.done #13 @1 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ completed
      #|(none) response.output_item.added #14 @2 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j in_progress
      #|(interval) response.function_call_arguments.delta #15 @2 "{\"zone\":"
      #|(interval) response.function_call_arguments.delta #16 @2 " \"Europe"
      #|(interval) response.function_call_arguments.delta #17 @2 "/Par"
      #|(none) response.function_call_arguments.done #18 @2 "{\"zone\": \"Europe/Par"
      #|(none) response.output_item.done #19 @2 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j completed
      #|(none) response.completed #20 completed
    ),
  )
}

///|
/// What breaks the checks on the function calls of the Responses stream
/// `reply`, beside those of `broken`, one line each, or `ok`: each
/// `response.output_item.done` carries the `id` and `call_id` of its
/// `added`, the call ids differ, each call's argument deltas join to the
/// arguments its done events give, and the closing Response holds the items
/// the done events gave, in order. Then each call's joined arguments, one
/// per line.
fn call_checks(reply : @llm.Reply) -> String raise {
  guard reply.body is Events(events) else { fail("not a stream") }
  let out = []
  let base = broken(reply)
  if base != "ok" {
    out.push(base)
  }
  let added : Map[Int32, (String, String)] = Map([])
  let joined : Map[Int32, String] = Map([])
  let done_items : Array[Json] = []
  let call_ids : Array[String] = []
  let arguments = []
  for i, event in events {
    let data = @json.parse(event.data)
    match data {
      {
        "type": "response.output_item.added",
        "output_index": Number(index, ..),
        "item": {
          "type": "function_call",
          "id": String(id),
          "call_id": String(call_id),
          "arguments": "",
          ..
        },
        ..
      } => {
        added[index.to_int()] = (id, call_id)
        joined[index.to_int()] = ""
      }
      {
        "type": "response.function_call_arguments.delta",
        "output_index": Number(index, ..),
        "delta": String(piece),
        ..
      } =>
        joined[index.to_int()] = joined.get(index.to_int()).unwrap_or("") +
          piece
      {
        "type": "response.function_call_arguments.done",
        "output_index": Number(index, ..),
        "arguments": String(text),
        ..
      } =>
        if joined.get(index.to_int()) != Some(text) {
          out.push("#\{i}: deltas do not join to \{text.escape()}")
        }
      {
        "type": "response.output_item.done",
        "output_index": Number(index, ..),
        "item": {
          "type": "function_call",
          "id": String(id),
          "call_id": String(call_id),
          "arguments": String(text),
          ..
        } as item,
        ..
      } => {
        if added.get(index.to_int()) != Some((id, call_id)) {
          out.push("#\{i}: \{id} \{call_id} done, not as added")
        }
        if joined.get(index.to_int()) != Some(text) {
          out.push("#\{i}: the item's arguments are not the deltas'")
        }
        if call_ids.contains(call_id) {
          out.push("#\{i}: call id \{call_id} twice")
        }
        call_ids.push(call_id)
        done_items.push(item)
        arguments.push(text.escape())
      }
      {
        "type": "response.output_item.done",
        "item": { "type": "message", .. } as item,
        ..
      } => done_items.push(item)
      {
        "type": "response.completed"
        | "response.incomplete",
        "response": { "output": Array(output), .. },
        ..
      } =>
        if output != done_items {
          out.push("#\{i}: the Response's output is not the done items")
        }
      _ => ()
    }
  }
  if out.is_empty() {
    out.push("ok")
  }
  out.append(arguments)
  out.join("\n")
}

///|
test "every stream with tool calls keeps the SDK's invariants: items added before their deltas and done with the id and call_id of their added, distinct call ids, and argument deltas that join to exactly their arguments" {
  let calls : ReadOnlyArray[@llm.ToolCall] = [
    @llm.ToolCall(name="get_weather", arguments={
      "city": "東京",
      "note": "👍🏽 𝄞",
      "days": 1000.0,
    }),
    @llm.ToolCall(name="get_time", arguments="{\"zone\": \"Europe/Par"),
    @llm.ToolCall(name="ping", arguments=""),
    @llm.ToolCall(name="noop", arguments={}),
  ]
  let lines = []
  for size in [1, 3, 4, 1_000_000] {
    let shown = call_checks(
      responses_calls("Hi", calls, request=streamed, chunk_size=size),
    )
    lines.push("chunkSize \{size}: \{shown}")
  }
  lines.push(
    "no text: " + call_checks(responses_calls("", calls, request=streamed)),
  )
  lines.push(
    "empty chunks: " +
    call_checks(responses_calls("", calls, chunks=["", ""], request=streamed)),
  )
  lines.push(
    "incomplete: " +
    call_checks(
      responses_calls(
        "Hi",
        calls,
        request=streamed,
        stop_reason="max_output_tokens",
      ),
    ),
  )
  inspect(
    lines.join("\n\n"),
    content=(
      #|chunkSize 1: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|chunkSize 3: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|chunkSize 4: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|chunkSize 1000000: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|no text: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|empty chunks: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
      #|
      #|incomplete: ok
      #|"{\"city\":\"東京\",\"note\":\"👍🏽 𝄞\",\"days\":1000}"
      #|"{\"zone\": \"Europe/Par"
      #|""
      #|"{}"
    ),
  )
}

///|
test "argument pieces wait as text pieces do; a reply with no piece waits first before its last item's done events, and an earlier item's done events wait for none" {
  let ping = (arguments : String) => {
    @llm.ToolCall(name="ping", arguments=Json::string(arguments))
  }
  inspect(
    [
      call_outline(responses_calls("", [ping("")], request=streamed)),
      call_outline(responses_calls("", [ping(""), ping("")], request=streamed)),
      call_outline(
        responses_calls("", [ping(""), ping("{}")], request=streamed),
      ),
    ].join("\n\n"),
    content=(
      #|(none) response.created #0 in_progress
      #|(none) response.in_progress #1 in_progress
      #|(none) response.output_item.added #2 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ in_progress
      #|(first) response.function_call_arguments.done #3 @0 ""
      #|(none) response.output_item.done #4 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ completed
      #|(none) response.completed #5 completed
      #|
      #|(none) response.created #0 in_progress
      #|(none) response.in_progress #1 in_progress
      #|(none) response.output_item.added #2 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ in_progress
      #|(none) response.function_call_arguments.done #3 @0 ""
      #|(none) response.output_item.done #4 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ completed
      #|(none) response.output_item.added #5 @1 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j in_progress
      #|(first) response.function_call_arguments.done #6 @1 ""
      #|(none) response.output_item.done #7 @1 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j completed
      #|(none) response.completed #8 completed
      #|
      #|(none) response.created #0 in_progress
      #|(none) response.in_progress #1 in_progress
      #|(none) response.output_item.added #2 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ in_progress
      #|(none) response.function_call_arguments.done #3 @0 ""
      #|(none) response.output_item.done #4 @0 function_call fc_5DTBZPrxiMH6i7M92iahxjWk call_iHzkHTRdWXnW746KnN1UOBYQ completed
      #|(none) response.output_item.added #5 @1 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j in_progress
      #|(first) response.function_call_arguments.delta #6 @1 "{}"
      #|(none) response.function_call_arguments.done #7 @1 "{}"
      #|(none) response.output_item.done #8 @1 function_call fc_lXej21FbJgs0WxlXP0AqXTyU call_DbhbAGir3qs3o77JKr2BTN9j completed
      #|(none) response.completed #9 completed
    ),
  )
}

///|
/// The ids of the Responses JSON reply and stream for `tool_calls` after
/// the text "Hi", with ids drawn from the generator of the draw `draw`: the
/// request id, the reply's id, then each tool call's item id and call id,
/// from the JSON reply's `output` and from the stream's
/// `response.output_item.done` events, which must agree.
fn responses_call_ids(
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  draw : UInt64,
) -> Array[String] {
  let found = []
  let requests : Array[Json?] = [Some({ "model": "gpt-6-astra" }), streamed]
  for request in requests {
    let reply = responses_calls("Hi", tool_calls, request~, draw~)
    let ids = [reply.request_id.1, "no reply id"]
    let bodies = match reply.body {
      Json(body) => [@utf8.decode_lossy(body)]
      Events(events) => events.map(event => event.data)
    }
    for body in bodies {
      let data = @json.parse(body) catch { _ => abort("not JSON") }
      // The JSON reply's own members, or the closing event's Response; the
      // stream's items come from their done events.
      let items = match data {
        {
          "type": "response.completed",
          "response": { "id": String(id), .. },
          ..
        } => {
          ids[1] = id
          [][:]
        }
        { "type": "response.output_item.done", "item": item, .. } => [item][:]
        { "id": String(id), "output": Array(items), .. } => {
          ids[1] = id
          items[:]
        }
        _ => [][:]
      }
      for item in items {
        if item
          is {
            "type": "function_call",
            "id": String(id),
            "call_id": String(call_id),
            ..
          } {
          ids.push(id)
          ids.push(call_id)
        }
      }
    }
    found.push(ids)
  }
  guard found[0] == found[1] else {
    abort(
      "the JSON reply's ids \{@debug.to_string(found[0])} and the stream's \{@debug.to_string(found[1])}",
    )
  }
  found[0]
}

///|
test "each tool call's function_call item id is fc_ and its first slot, its call_id call_ and its second, after the reply's and the message item's slots; the request id's comes last" {
  for draw in 0UL..<50UL {
    for n in 0..<4 {
      let tool_calls = ReadOnlyArray::from_array(
        Array::makei(n, _ => weather()),
      )
      let expected = [
        "req_\{slot_id(draw, 2 + 2 * n)}",
        "resp_\{slot_id(draw, 0)}",
      ]
      for k in 0..<n {
        expected.push("fc_\{slot_id(draw, 2 + 2 * k)}")
        expected.push("call_\{slot_id(draw, 3 + 2 * k)}")
      }
      let ids = responses_call_ids(tool_calls, draw)
      guard ids == expected else {
        fail(
          "draw \{draw}, \{n} tool calls: \{@debug.to_string(ids)}, not \{@debug.to_string(expected)}",
        )
      }
    }
  }
}

///|
/// The call ids among the ids `responses_call_ids` gives.
fn call_ids_of(ids : Array[String]) -> Array[String] {
  let out = []
  for i in 3..<ids.length() {
    if i % 2 == 1 {
      out.push(ids[i])
    }
  }
  out
}

///|
test "a call_id has the 24 characters of the Chat call id of the same declaration and draw, and the call ids of one reply are distinct" {
  let tool_calls : ReadOnlyArray[@llm.ToolCall] = [
    weather(),
    weather(),
    weather(),
    weather(),
  ]
  for draw in 0UL..<200UL {
    let calls = call_ids_of(responses_call_ids(tool_calls, draw))
    let chat = ids_of(tool_calls, draw)[2:].to_owned()
    guard calls == chat else {
      fail(
        "draw \{draw}: \{@debug.to_string(calls)}, not Chat's \{@debug.to_string(chat)}",
      )
    }
    for i in 0..<calls.length() {
      for j in 0..<i {
        guard calls[i] != calls[j] else {
          fail("draw \{draw}: \{calls[i]} twice")
        }
      }
    }
  }
}

///|
test "a tool call's id fixes its call_id, sent as written; its fc_ id is still generated, and every other id stays as it was" {
  inspect(
    [
      responses_call_ids([weather(), weather()], 7).join("\n"),
      responses_call_ids([weather(id="call_test_0"), weather()], 7).join("\n"),
      responses_call_ids([weather(), weather(id="a \"quoted\" id, 天気")], 7).join(
        "\n",
      ),
    ].join("\n---\n"),
    content=(
      #|req_NCUifvyxkaNvRkMCKLDmHTwH
      #|resp_KCVauEuclT08Mg4CWd55sNbz
      #|fc_5DTBZPrxiMH6i7M92iahxjWk
      #|call_iHzkHTRdWXnW746KnN1UOBYQ
      #|fc_lXej21FbJgs0WxlXP0AqXTyU
      #|call_DbhbAGir3qs3o77JKr2BTN9j
      #|---
      #|req_NCUifvyxkaNvRkMCKLDmHTwH
      #|resp_KCVauEuclT08Mg4CWd55sNbz
      #|fc_5DTBZPrxiMH6i7M92iahxjWk
      #|call_test_0
      #|fc_lXej21FbJgs0WxlXP0AqXTyU
      #|call_DbhbAGir3qs3o77JKr2BTN9j
      #|---
      #|req_NCUifvyxkaNvRkMCKLDmHTwH
      #|resp_KCVauEuclT08Mg4CWd55sNbz
      #|fc_5DTBZPrxiMH6i7M92iahxjWk
      #|call_iHzkHTRdWXnW746KnN1UOBYQ
      #|fc_lXej21FbJgs0WxlXP0AqXTyU
      #|a "quoted" id, 天気
    ),
  )
}

///|
/// The Response that the JSON reply for `text` and `tool_calls` gives, with
/// the stop reason `stop_reason` written, in brief: its status,
/// `completed_at`, `incomplete_details` and each output item's type and
/// status; then whether the stream's closing event carries the same
/// Response, and its type.
fn ending(
  text : String,
  tool_calls : ReadOnlyArray[@llm.ToolCall],
  stop_reason? : String,
) -> String raise {
  let json = responses_calls(text, tool_calls, stop_reason?)
  let stream = responses_calls(text, tool_calls, request=streamed, stop_reason?)
  guard json.body is Json(body) else { fail("not JSON") }
  let reply = @json.parse(@utf8.decode_lossy(body))
  guard reply
    is {
      "status": String(status),
      "completed_at": completed_at,
      "incomplete_details": details,
      "output": Array(items),
      ..
    } else {
    fail("not a Response")
  }
  let shown = items.map(item => {
    guard item is { "type": String(kind), "status": String(status), .. } else {
      abort("not an item")
    }
    "\{kind} \{status}"
  })
  guard stream.body is Events(events) else { fail("not a stream") }
  guard @json.parse(events[events.length() - 1].data)
    is { "type": String(closing), "response": response, .. } else {
    fail("no closing Response")
  }
  "\{status}, completed_at \{completed_at.stringify()}, incomplete_details \{details.stringify()}: \{shown.join(", ")}; the stream ends with \{closing}, the same Response: \{response == reply}"
}

///|
test "a written stop reason makes a reply with tool calls incomplete, in both forms: the message item is incomplete and each function_call item stays completed" {
  let calls : ReadOnlyArray[@llm.ToolCall] = [weather(), weather()]
  inspect(
    [
      ending("Let me check.", calls),
      ending("Let me check.", calls, stop_reason="max_output_tokens"),
      ending("", calls, stop_reason="content_filter"),
    ].join("\n"),
    content=(
      #|completed, completed_at 1791815405, incomplete_details null: message completed, function_call completed, function_call completed; the stream ends with response.completed, the same Response: true
      #|incomplete, completed_at null, incomplete_details {"reason":"max_output_tokens"}: message incomplete, function_call completed, function_call completed; the stream ends with response.incomplete, the same Response: true
      #|incomplete, completed_at null, incomplete_details {"reason":"content_filter"}: function_call completed, function_call completed; the stream ends with response.incomplete, the same Response: true
    ),
  )
}

///|
test "with tool calls, empty text gives no message item, no content and no text event, even when chunks gives empty pieces" {
  let kinds = (reply : @llm.Reply) => {
    guard reply.body is Events(events) else { abort("not a stream") }
    events.map(event => event.event.unwrap_or("-")).join(" ")
  }
  let chunks : ReadOnlyArray[String] = ["", ""]
  inspect(
    [
      output_of(responses_calls("", [weather()], chunks~)),
      kinds(responses_calls("", [weather()], chunks~, request=streamed)),
    ].join("\n"),
    content=(
      #|{"type":"function_call","id":"fc_5DTBZPrxiMH6i7M92iahxjWk","call_id":"call_iHzkHTRdWXnW746KnN1UOBYQ","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}
      #|response.created response.in_progress response.output_item.added response.function_call_arguments.delta response.function_call_arguments.delta response.function_call_arguments.delta response.function_call_arguments.delta response.function_call_arguments.done response.output_item.done response.completed
    ),
  )
}

///|
test "a broken function call is caught: the call checks are not vacuous" {
  let reply = responses_calls("", [weather(), weather()], request=streamed)
  guard reply.body is Events(events) else { fail("not a stream") }
  let rome = @llm.ToolCall(name="get_weather", arguments={ "city": "Rome!" })
  guard responses_calls("", [rome, weather()], request=streamed, draw=8).body
    is Events(other) else {
    fail("not a stream")
  }
  // A piece of the first call's arguments, and the second call's done
  // item, from another reply.
  events[5] = other[5]
  events[events.length() - 2] = other[events.length() - 2]
  inspect(
    call_checks(reply),
    content=(
      #|#5: response.function_call_arguments.delta for an item not open
      #|#15: fc_9T6PinRrV374i9VQ2iAFrfid done, not added
      #|#16: response.completed before every item is done
      #|#7: deltas do not join to "{\"city\":\"Paris\"}"
      #|#8: the item's arguments are not the deltas'
      #|#15: fc_9T6PinRrV374i9VQ2iAFrfid call_YLZT0RFhIo3nY9SvaPEmLt5x done, not as added
      #|#16: the Response's output is not the done items
      #|"{\"city\":\"Paris\"}"
      #|"{\"city\":\"Paris\"}"
    ),
  )
}
