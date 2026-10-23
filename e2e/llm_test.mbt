///|
/// A Mock that answers Chat Completions requests with an LLM response, its
/// seed fixing the reply's id.
let openai_chat : String =
  #|{ "mocks": [{ "name": "openai" }],
  #|  "stubs": [{ "id": "chat", "mock": "openai",
  #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
  #|    "response": { "status": 200,
  #|      "headers": { "x-ratelimit-remaining-requests": "59" },
  #|      "llm": { "api": "openai-chat", "text": "Hello! 天気は晴れ 👍" } },
  #|    "fault": { "seed": 7 } }] }

///|
/// `text` with the value of each of its `"created":` members shown as
/// `<received>` when it is a second from `from` to `to` (milliseconds since
/// the Unix epoch). Any other value stays as it is.
fn mask_created(text : String, from~ : Int64, to~ : Int64) -> String {
  let key = "\"created\":"
  let out = StringBuilder()
  let mut rest = text
  while rest.find(key) is Some(start) {
    let digits = start + key.length()
    let mut end = digits
    while end < rest.length() && rest[end] >= '0' && rest[end] <= '9' {
      end += 1
    }
    let seconds = @string.parse_int64(rest[digits:end]) catch { _ => -1L }
    out.write_string(rest[:digits].to_owned())
    if seconds >= from / 1000L && seconds <= to / 1000L {
      out.write_string("<received>")
    } else {
      out.write_string(rest[digits:end].to_owned())
    }
    rest = rest[end:].to_owned()
  }
  out.write_string(rest)
  out.to_string()
}

///|
async test "POST /v1/chat/completions to an llm Stub gets one chat.completion JSON body over a real socket" {
  with_definitions([("openai.json", openai_chat)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let from = @async.now()
      let reply = smock.send(
        "POST",
        "/v1/chat/completions",
        headers=[
          ("Content-Type", "application/json"),
          ("Authorization", "Bearer sk-test"),
        ],
        body="{\"model\":\"gpt-6-astra\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
      )
      let to = @async.now()
      inspect(
        mask_created(mask_date(reply), from~, to~),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 561
          #|
          #|{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! 天気は晴れ 👍","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
        ),
      )
    })
  })
}

///|
/// The JSON body of a Chat Completions request for `gpt-6-astra` whose
/// `stream` member is `stream`, given as JSON text.
fn chat_request(stream : String) -> String {
  "{\"model\":\"gpt-6-astra\",\"stream\":\{stream},\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}"
}

///|
/// The head of `response`, as `read_response` renders it.
fn head_of(response : String) -> String {
  response[:response.find("\n\n").unwrap_or(response.length())].to_owned()
}

///|
async test "stream: true over HTTP/1.1 gets the chunks as text/event-stream with chunked framing, ending with data: [DONE], and the next request is served on the same connection" {
  with_definitions([("openai.json", openai_chat)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let from = @async.now()
      conn.write(
        raw_request(
          "POST",
          "/v1/chat/completions",
          host="localhost",
          headers=[("Content-Type", "application/json")],
          body=chat_request("true"),
        ),
      )
      // The last chunk, `0`, ends the stream.
      let end = "\r\n0\r\n\r\n"
      let stream = @async.with_timeout_opt(patience_ms, () => {
        conn.read_until(end)
      })
      guard stream is Some(Some(stream)) else { fail("the stream did not end") }
      let to = @async.now()
      conn.write(
        raw_request(
          "POST",
          "/v1/chat/completions",
          host="localhost",
          body=chat_request("false"),
        ),
      )
      let next = head_of(read_response(conn))
      inspect(
        mask_created(
          mask_date((stream + end).replace_all(old="\r\n", new="\n")),
          from~,
          to~,
        ) +
        "--- the next request on the connection:\n" +
        next,
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Transfer-Encoding: chunked
          #|
          #|e5
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|d6
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|d8
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! 天"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|de
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"気は晴れ"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|d7
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":" 👍"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|c8
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
          #|
          #|
          #|e
          #|data: [DONE]
          #|
          #|
          #|0
          #|
          #|--- the next request on the connection:
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_IazsHccliNw545TFSy204aSk
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 561
        ),
      )
    })
  })
}

///|
async test "stream: true over HTTP/1.0 gets the chunks unframed, and smock closes the connection to end the stream" {
  with_definitions([("openai.json", openai_chat)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let from = @async.now()
      let body = chat_request("true")
      // A client that asks to keep the connection open still gets a stream
      // that ends when the connection closes.
      conn.write(
        "POST /v1/chat/completions HTTP/1.0\r\nConnection: keep-alive\r\nContent-Length: \{@utf8.encode(body).length()}\r\n\r\n\{body}",
      )
      // It returns once smock has closed the connection.
      let received = read_to_end(conn)
      let to = @async.now()
      inspect(
        mask_created(received, from~, to~),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Connection: close
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! 天"},"logprobs":null,"finish_reason":null}]}
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"気は晴れ"},"logprobs":null,"finish_reason":null}]}
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":" 👍"},"logprobs":null,"finish_reason":null}]}
          #|
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
          #|
          #|data: [DONE]
          #|
          #|
        ),
      )
    })
  })
}

///|
/// `openai_chat` with a partial Fault on its Stub.
let openai_chat_partial : String = openai_chat.replace(
  old="\"fault\": { \"seed\": 7 }",
  new="\"fault\": { \"seed\": 7, \"connection\": { \"kind\": \"partial\" } }",
)

///|
async test "a partial Fault sends the first half of the stream's events, without the end of the stream, and the first half of a JSON reply, then a FIN" {
  with_definitions([("openai.json", openai_chat_partial)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for stream in ["true", "false"] {
        let conn = smock.connect()
        defer conn.close()
        let from = @async.now()
        conn.write(
          raw_request(
            "POST",
            "/v1/chat/completions",
            host="localhost",
            body=chat_request(stream),
          ),
        )
        let received = read_to_end(conn)
        let to = @async.now()
        out.push("stream \{stream}:\n\{mask_created(received, from~, to~)}")
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|stream true:
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Transfer-Encoding: chunked
          #|
          #|e5
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|d6
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|d8
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! 天"},"logprobs":null,"finish_reason":null}]}
          #|
          #|
          #|
          #|---
          #|stream false:
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|x-ratelimit-remaining-requests: 59
          #|x-request-id: req_IazsHccliNw545TFSy204aSk
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 561
          #|
          #|{"id":"chatcmpl-lM10tfraqbMuqY6lc9FjN5n8","object":"chat.completion","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! 天気は晴れ 👍","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"u
        ),
      )
    })
  })
}

///|
/// `openai_chat` without a seed of its own, its stream paced by `timing`.
let openai_chat_paced : String =
  #|{ "mocks": [{ "name": "openai" }],
  #|  "stubs": [{ "id": "chat", "mock": "openai",
  #|    "request": { "method": "POST", "path": "/v1/chat/completions" },
  #|    "response": { "status": 200,
  #|      "headers": { "x-ratelimit-remaining-requests": "59" },
  #|      "llm": { "api": "openai-chat", "text": "Hello! 天気は晴れ 👍",
  #|        "timing": {
  #|          "first": { "lognormal": { "median": 400, "sigma": 0.5 } },
  #|          "interval": { "uniform": { "min": 15, "max": 40 } } } } } }] }

///|
async test "smock render and the Admin render operation show the same events, each with its wait, for a sample whose body sets stream: true, and the JSON body for one that does not, with the ids and the waits the seed fixes" {
  let sample = (stream : String) => {
    let json : Json = {
      "method": "POST",
      "path": "/v1/chat/completions",
      "body": chat_request(stream),
    }
    json.stringify()
  }
  let files = [
    ("openai.json", openai_chat_paced),
    ("samples/stream.json", sample("true")),
    ("samples/json.json", sample("false")),
  ]
  with_definitions(files, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for name in ["stream", "json"] {
        let file = "\{dir}/samples/\{name}.json"
        let (status, stdout, _) = render_output([
          "--dir", dir, "chat", "--request", file, "--time", "2026-10-23T00:00:00Z",
          "--seed", "7",
        ])
        let response = smock.render(
          "chat",
          sample=file,
          query="?time=2026-10-23T00:00:00Z&seed=7",
        )
        let from_cli = rendered(@json.parse(stdout))
        let from_admin = rendered(response.json())
        let used = time_and_seed(
          response.json(),
          time_given=true,
          seed_given=true,
        )
        out.push(
          "\{name}: render \{status}, admin \{response.status}, same: \{from_cli == from_admin}, \{used}",
        )
        guard @json.parse(stdout)
          is { "response": { "body": body, "events": events, .. }, .. } else {
          fail("no response in \{stdout}")
        }
        match (body, events) {
          (Null, Array(events)) =>
            for event in events {
              out.push("  \{event.stringify()}")
            }
          (Object(body), Null) =>
            out.push(
              "  body: \{body.get("data").unwrap_or(Json::null()).stringify()}",
            )
          _ => fail("neither a body nor events in \{stdout}")
        }
      }
      inspect(
        out.join("\n"),
        content=(
          #|stream: render 0, admin 200, same: true, time 2026-10-23T00:00:00.000Z, seed 7
          #|  {"delay":0,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"logprobs\":null,\"finish_reason\":null}]}"}
          #|  {"delay":824,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hell\"},\"logprobs\":null,\"finish_reason\":null}]}"}
          #|  {"delay":27,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"o! 天\"},\"logprobs\":null,\"finish_reason\":null}]}"}
          #|  {"delay":20,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"気は晴れ\"},\"logprobs\":null,\"finish_reason\":null}]}"}
          #|  {"delay":38,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" 👍\"},\"logprobs\":null,\"finish_reason\":null}]}"}
          #|  {"delay":0,"data":"{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion.chunk\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{},\"logprobs\":null,\"finish_reason\":\"stop\"}]}"}
          #|  {"delay":0,"data":"[DONE]"}
          #|json: render 0, admin 200, same: true, time 2026-10-23T00:00:00.000Z, seed 7
          #|  body: "{\"id\":\"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl\",\"object\":\"chat.completion\",\"created\":1792713600,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello! 天気は晴れ 👍\",\"refusal\":null,\"annotations\":[]},\"logprobs\":null,\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0,\"prompt_tokens_details\":{\"cached_tokens\":0,\"audio_tokens\":0},\"completion_tokens_details\":{\"reasoning_tokens\":0,\"audio_tokens\":0,\"accepted_prediction_tokens\":0,\"rejected_prediction_tokens\":0}},\"service_tier\":\"default\"}"
        ),
      )
    })
  })
}

///|
/// An Ephemeral Stub whose `response` gives `llm`: a reply cut short by the
/// token limit, with a fixed id and request id, for requests with
/// `X-Test-Case: short`.
let ephemeral_short : String =
  #|{"request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"short"}},
  #| "response":{"status":200,"headers":{"x-request-id":"req_short_1"},
  #|  "llm":{"api":"openai-chat","text":"The weather in Paris is","id":"chatcmpl-short-1",
  #|   "usage":{"input":31,"output":5},"stopReason":"length"}}}

///|
/// An Ephemeral Stub whose `responses` give `llm`, paced, with the seed 7,
/// for requests with `X-Test-Case: paced`.
let ephemeral_paced : String =
  #|{"request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"paced"}},
  #| "responses":[{"status":200,
  #|  "llm":{"api":"openai-chat","chunks":["Hi","","!"],
  #|   "timing":{"first":{"fixed":40},"interval":{"uniform":{"min":15,"max":40}}}}}],
  #| "fault":{"seed":7}}

///|
async test "over the Admin API, an Ephemeral Stub takes llm in response and in responses, is listed as it was given, and answers its Session's requests" {
  with_definitions([("openai.json", openai_chat)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let stubs = "/v1/mocks/openai/stubs"
      let session = session_headers(Some("test-a"))
      let out = []
      for stub in [ephemeral_short, ephemeral_paced] {
        let added = smock.admin("POST", stubs, headers=session, body=stub)
        out.push("added: \{added.status} \{added.body}")
        guard added.json() is { "stub": Object(listed), .. } else {
          fail("no Stub in \{added.body}")
        }
        // The Stub as given, with its id, Mock and Session before it.
        let given = @json.parse(stub)
        listed.remove("id")
        listed.remove("mock")
        listed.remove("session")
        out.push("  as given: \{Json::object(listed) == given}")
      }
      let listing = smock.admin("GET", stubs, headers=session)
      out.push("listed: \{listing.status} \{listing.body}")
      for case_ in ["short", "paced"] {
        let from = @async.now()
        let reply = smock.send(
          "POST",
          "/v1/chat/completions",
          headers=[("X-Test-Case", case_), ..session],
          body=chat_request("false"),
        )
        let to = @async.now()
        out.push("\{case_}:\n\{mask_created(reply, from~, to~)}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|added: 201 {"stub":{"id":"eph-1","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"short"}},"response":{"status":200,"headers":{"x-request-id":"req_short_1"},"llm":{"api":"openai-chat","text":"The weather in Paris is","id":"chatcmpl-short-1","usage":{"input":31,"output":5},"stopReason":"length"}}},"warnings":[]}
          #|  as given: true
          #|added: 201 {"stub":{"id":"eph-2","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"paced"}},"responses":[{"status":200,"llm":{"api":"openai-chat","chunks":["Hi","","!"],"timing":{"first":{"fixed":40},"interval":{"uniform":{"min":15,"max":40}}}}}],"fault":{"seed":7}},"warnings":[]}
          #|  as given: true
          #|listed: 200 {"stubs":[{"id":"eph-2","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"paced"}},"responses":[{"status":200,"llm":{"api":"openai-chat","chunks":["Hi","","!"],"timing":{"first":{"fixed":40},"interval":{"uniform":{"min":15,"max":40}}}}}],"fault":{"seed":7}},{"id":"eph-1","mock":"openai","session":"test-a","request":{"method":"POST","path":"/v1/chat/completions","headers":{"X-Test-Case":"short"}},"response":{"status":200,"headers":{"x-request-id":"req_short_1"},"llm":{"api":"openai-chat","text":"The weather in Paris is","id":"chatcmpl-short-1","usage":{"input":31,"output":5},"stopReason":"length"}}}],"warnings":[]}
          #|short:
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|x-request-id: req_short_1
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 544
          #|
          #|{"id":"chatcmpl-short-1","object":"chat.completion","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in Paris is","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"length"}],"usage":{"prompt_tokens":31,"completion_tokens":5,"total_tokens":36,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
          #|paced:
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 537
          #|
          #|{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Hi!","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
        ),
      )
    })
  })
}
