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
/// `text` with the value of its `"created":` member shown as `<received>`
/// when it is a second from `from` to `to` (milliseconds since the Unix
/// epoch). Any other value stays as it is.
fn mask_created(text : String, from~ : Int64, to~ : Int64) -> String {
  let key = "\"created\":"
  guard text.find(key) is Some(start) else { return text }
  let digits = start + key.length()
  let mut end = digits
  while end < text.length() && text[end] >= '0' && text[end] <= '9' {
    end += 1
  }
  let seconds = @string.parse_int64(text[digits:end]) catch { _ => -1L }
  if seconds >= from / 1000L && seconds <= to / 1000L {
    text[:digits].to_owned() + "<received>" + text[end:].to_owned()
  } else {
    text
  }
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
