// Seam 2 test of the spec's example over real sockets: an agent's
// conversation with two Stubs, driven on one connection as an SDK drives
// it. The first turn is streamed, with its pieces and waits, and asked
// again as one JSON body; the second sends the tool's result back. A second
// run of the server repeats the seeded Stub's ids and waits.

///|
/// The two Stubs of the spec's example. `ask-weather` answers a
/// conversation whose last message is the user's with text and a call of
/// `get_weather`, paced by `timing`, its seed fixing its ids and waits.
/// `answer-weather` answers one whose last message is the tool's result
/// with a text that inserts that result.
let weather_conversation : String =
  #|mocks:
  #|  - name: openai
  #|stubs:
  #|  - id: ask-weather
  #|    mock: openai
  #|    request:
  #|      method: POST
  #|      path: /v1/chat/completions
  #|      body: { json: { messages: { $last: { role: user } } } }
  #|    response:
  #|      status: 200
  #|      llm:
  #|        api: openai-chat
  #|        text: Let me check.
  #|        toolCalls:
  #|          - name: get_weather
  #|            arguments: { city: Paris }
  #|        usage: { input: 31, output: 18 }
  #|        timing:
  #|          first: { lognormal: { median: 400, sigma: 0.5 } }
  #|          interval: { uniform: { min: 15, max: 40 } }
  #|    fault: { seed: 7 }
  #|  - id: answer-weather
  #|    mock: openai
  #|    request:
  #|      method: POST
  #|      path: /v1/chat/completions
  #|      body: { json: { messages: { $last: { role: tool } } } }
  #|    response:
  #|      status: 200
  #|      template: true
  #|      llm:
  #|        api: openai-chat
  #|        text: It is ${last(body.messages).content} in Paris.
  #|        usage: { input: 52, output: 9 }

///|
/// The waits, in milliseconds, of the first request `ask-weather` matches:
/// `first` before its first piece, then `interval` before each later one.
/// They are the waits docs/definition-files.md shows under Timing for the
/// same `timing` with `smock render --seed 7`, since the Stub's seed is 7.
let first_match_waits : Array[Int] = [824, 27, 20, 38, 19, 40, 38, 26]

///|
/// The header fields an SDK sends with each request, after Host.
let sdk_headers : Array[(String, String)] = [
  ("Content-Type", "application/json"),
  ("Authorization", "Bearer sk-test"),
]

///|
/// The user's question to `test-model`: the first turn, whose last message
/// is the user's, with `stream` set to `stream`.
fn weather_question(stream~ : Bool) -> String {
  let json : Json = {
    "model": "test-model",
    "stream": stream,
    "messages": [{ "role": "user", "content": "What is the weather in Paris?" }],
  }
  json.stringify()
}

///|
/// The second turn, streamed: the question, the assistant's reply with its
/// call of `get_weather` as `call_id`, and the tool's result, `18°C`.
fn weather_tool_result(call_id : String) -> String {
  let json : Json = {
    "model": "test-model",
    "stream": true,
    "messages": [
      { "role": "user", "content": "What is the weather in Paris?" },
      {
        "role": "assistant",
        "content": "Let me check.",
        "tool_calls": [
          {
            "id": call_id,
            "type": "function",
            "function": {
              "name": "get_weather",
              "arguments": "{\"city\":\"Paris\"}",
            },
          },
        ],
      },
      { "role": "tool", "tool_call_id": call_id, "content": "18°C" },
    ],
  }
  json.stringify()
}

///|
/// Sends a Chat Completions request with `body` on `conn`, with the header
/// fields an SDK sends.
async fn ask_chat(conn : Conn, body : String) -> Unit {
  conn.write(
    raw_request(
      "POST",
      "/v1/chat/completions",
      host="localhost",
      headers=sdk_headers,
      body~,
    ),
  )
}

///|
/// The `data:` line of `event`, one event of a chunked stream as
/// `read_until("\n\n")` reads it, without the chunk's size line, and the
/// line's JSON, `Null` when it holds none.
fn chat_chunk(event : String) -> (String, Json) {
  let line = event[event.find("data: ").unwrap_or(0):].to_owned()
  let json = @json.parse(line["data: ".length():]) catch { _ => Json::null() }
  (line, json)
}

///|
/// Whether the Chat Completions chunk `json` carries a piece: of the text,
/// or of a tool call's arguments, after the chunk that opens the call.
fn carries_piece(json : Json) -> Bool {
  match json {
    { "choices": [{ "delta": { "role": _, .. }, .. }], .. } => false
    { "choices": [{ "delta": { "content": String(_), .. }, .. }], .. } => true
    {
      "choices": [{ "delta": { "tool_calls": [{ "id": _, .. }], .. }, .. }],
      ..
    } => false
    { "choices": [{ "delta": { "tool_calls": [_], .. }, .. }], .. } => true
    _ => false
  }
}

///|
/// Reads the events of the stream on `conn` until `data: [DONE]`, then the
/// last chunk, and calls `f` with each event's `data:` line, its JSON and
/// how many milliseconds after `since` it arrived.
async fn read_chat_stream(
  conn : Conn,
  since : Int64,
  f : (String, Json, Int64) -> Unit raise,
) -> Unit {
  for ;; {
    let event = @async.with_timeout_opt(patience_ms, () => {
      conn.read_until("\n\n")
    })
    guard event is Some(Some(event)) else { fail("the stream ended early") }
    let (line, json) = chat_chunk(event)
    f(line, json, @async.now() - since)
    if line == "data: [DONE]" {
      break
    }
  }
  guard conn.read_until("\r\n0\r\n\r\n") is Some(_) else {
    fail("the stream did not end with the last chunk")
  }
}

///|
/// Drives the conversation on one connection to `smock`, as an SDK does,
/// and renders what it received, with the Date and `created` masked:
///
/// - the first turn, streamed, which `ask-weather` matches first: its head
///   and each event, with when it arrived against the waits of
///   `first_match_waits`;
/// - the same request without `stream`, its second match: the response;
/// - the second turn, with the call id of the stream and the tool's result,
///   streamed: what each event carries, and the pieces joined.
async fn converse(smock : Smock) -> String {
  let conn = smock.connect()
  defer conn.close()
  let from = @async.now()
  ask_chat(conn, weather_question(stream=true))
  let head = read_head(conn)
  let head_at = @async.now()
  let first = first_match_waits[0]
  let out = [
    "streamed, head \{head_arrival(head_at - from, first)}:",
    head.trim_end(chars="\n").to_owned(),
  ]
  // When each event is due, in milliseconds after the head: each piece
  // after its wait, every other event at once after the one before it.
  let mut due = 0
  let mut pieces = 0
  let mut call_id = ""
  read_chat_stream(conn, head_at, (line, json, elapsed) => {
    if carries_piece(json) {
      guard pieces < first_match_waits.length() else {
        fail("more pieces than waits:\n\{out.join("\n")}")
      }
      due += first_match_waits[pieces]
      pieces += 1
    }
    if json
      is {
        "choices": [
          { "delta": { "tool_calls": [{ "id": String(id), .. }], .. }, .. },
        ],
        ..
      } {
      call_id = id
    }
    let when = if pieces == 0 {
      head_arrival(elapsed, first)
    } else {
      arrival(elapsed, due)
    }
    out.push("\{when}: \{line}")
  })
  ask_chat(conn, weather_question(stream=false))
  out.push("one JSON body:")
  out.push(read_response(conn))
  ask_chat(conn, weather_tool_result(call_id))
  out.push("the tool's result, streamed: \{status_line(read_head(conn))}")
  let joined = StringBuilder()
  read_chat_stream(conn, head_at, (line, json, _) => {
    out.push("  \{chunk_carries(line)}")
    if json
      is { "choices": [{ "delta": { "content": String(piece), .. }, .. }], .. } {
      joined.write_string(piece)
    }
  })
  out.push("  joined: \{joined.to_string()}")
  mask_created(out.join("\n"), from~, to=@async.now())
}

///|
async test "the spec's example over real sockets: the streamed tool call with its pieces and waits, the same request as one JSON body, the templated answer to the tool's result, and the same ids and waits on a second run of the server" {
  with_definitions([("openai.yaml", weather_conversation)], dir => {
    let runs = []
    for _ in 0..<2 {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        runs.push(converse(smock))
      })
    }
    inspect(
      runs[0],
      content=(
        #|streamed, head before 824 ms:
        #|HTTP/1.1 200 OK
        #|Content-Type: text/event-stream
        #|x-request-id: req_r2yjBtWWwsQd6LgmRvpu3TbN
        #|Smock-Mock: openai; via=default
        #|Date: <now>
        #|Transfer-Encoding: chunked
        #|before 824 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
        #|at 824 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"content":"Let "},"logprobs":null,"finish_reason":null}]}
        #|at 851 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"content":"me c"},"logprobs":null,"finish_reason":null}]}
        #|at 871 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"content":"heck"},"logprobs":null,"finish_reason":null}]}
        #|at 909 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"content":"."},"logprobs":null,"finish_reason":null}]}
        #|at 909 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}
        #|at 928 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]},"logprobs":null,"finish_reason":null}]}
        #|at 968 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\":"}}]},"logprobs":null,"finish_reason":null}]}
        #|at 1006 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Par"}}]},"logprobs":null,"finish_reason":null}]}
        #|at 1032 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]},"logprobs":null,"finish_reason":null}]}
        #|at 1032 ms: data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"test-model","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}
        #|at 1032 ms: data: [DONE]
        #|one JSON body:
        #|HTTP/1.1 200 OK
        #|Content-Type: application/json
        #|x-request-id: req_FB0CAqFQ4sZE7d0hqW728I27
        #|Smock-Mock: openai; via=default
        #|Date: <now>
        #|Content-Length: 696
        #|
        #|{"id":"chatcmpl-lM10tfraqbMuqY6lc9FjN5n8","object":"chat.completion","created":<received>,"model":"test-model","choices":[{"index":0,"message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call_U5Q1aczj2BojP9KXBkAtB3d9","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}],"refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
        #|the tool's result, streamed: HTTP/1.1 200 OK
        #|  opening chunk
        #|  piece "It i"
        #|  piece "s 18"
        #|  piece "°C i"
        #|  piece "n Pa"
        #|  piece "ris."
        #|  closing chunk
        #|  [DONE]
        #|  joined: It is 18°C in Paris.
      ),
    )
    inspect(
      if runs[1] == runs[0] {
        "the second run: the same"
      } else {
        "the second run:\n\{runs[1]}"
      },
      content=(
        #|the second run: the same
      ),
    )
  })
}
