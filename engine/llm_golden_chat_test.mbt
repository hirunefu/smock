// Goldens of `openai-chat`: the Chat Completions examples of OpenAI's
// OpenAPI document, each compared with what smock sends for a Stub that
// declares the example's content (see llm_golden_test.mbt).
//
// Source of every example below: openapi.yaml of
// https://github.com/openai/openai-openapi at commit
// 762a1df070a80bf73ac85804a4b1a492d9a108a1, the `x-oaiMeta` examples of the
// operation `createChatCompletion`, read on 2026-10-23. That repository's
// licence, under which they are copied:
//
//   The MIT License
//
//   Copyright (c) OpenAI (https://openai.com)
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to
//   the following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//   CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

///|
/// The "Default" example's response, lines 2689 to 2723 of openapi.yaml,
/// copied unchanged: one `chat.completion` with text.
let chat_default_example : String =
  #|{
  #|  "id": "chatcmpl-B9MBs8CjcvOU2jLn4n570S5qMJKcT",
  #|  "object": "chat.completion",
  #|  "created": 1741569952,
  #|  "model": "gpt-6-astra",
  #|  "choices": [
  #|    {
  #|      "index": 0,
  #|      "message": {
  #|        "role": "assistant",
  #|        "content": "Hello! How can I assist you today?",
  #|        "refusal": null,
  #|        "annotations": []
  #|      },
  #|      "logprobs": null,
  #|      "finish_reason": "stop"
  #|    }
  #|  ],
  #|  "usage": {
  #|    "prompt_tokens": 19,
  #|    "completion_tokens": 10,
  #|    "total_tokens": 29,
  #|    "prompt_tokens_details": {
  #|      "cached_tokens": 0,
  #|      "audio_tokens": 0
  #|    },
  #|    "completion_tokens_details": {
  #|      "reasoning_tokens": 0,
  #|      "audio_tokens": 0,
  #|      "accepted_prediction_tokens": 0,
  #|      "rejected_prediction_tokens": 0
  #|    }
  #|  },
  #|  "service_tier": "default"
  #|}

///|
/// A Mock `openai` whose Stub `default` declares the "Default" example's
/// content: its text, its id, its model and its usage.
let chat_default_stub : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: default
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        id: chatcmpl-B9MBs8CjcvOU2jLn4n570S5qMJKcT
    #|        model: gpt-6-astra
    #|        text: Hello! How can I assist you today?
    #|        usage: { input: 19, output: 10 }
  ),
)

///|
/// The request of the Default and Streaming examples, which asks for a
/// stream when `stream` is true.
fn hello_request(stream? : Bool = false) -> String {
  let stream = if stream { ",\"stream\":true" } else { "" }
  "{\"model\":\"gpt-6-astra\",\"messages\":[{\"role\":\"developer\",\"content\":\"You are a helpful assistant.\"},{\"role\":\"user\",\"content\":\"Hello!\"}]\{stream}}"
}

///|
/// Nothing differs.
test "the Chat Completions JSON reply equals the reference's Default example" {
  let h = harness([chat_default_stub])
  h.now = 1_741_569_952_000L
  let outcome = h.chat(body=hello_request())
  inspect(
    compare_golden(chat_default_example, outcome),
    content=(
      #|same
    ),
  )
}

///|
/// The "Streaming" example's response, lines 2977 to 2985 of openapi.yaml,
/// copied unchanged: the opening chunk, the first piece, a comment that
/// stands for the chunks left out, the closing chunk and `[DONE]`.
let chat_streaming_example : String =
  #|data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
  #|
  #|data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}]}
  #|
  #|: Intermediate chat completion chunks omitted.
  #|
  #|data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
  #|
  #|data: [DONE]
  #|

///|
/// A Mock `openai` whose Stub `streaming` declares the "Streaming"
/// example's content: its first piece, then pieces of its own for the
/// chunks the example leaves out, its id and its model. The example shows
/// no usage, since its request does not ask for it.
let chat_streaming_stub : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: streaming
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        id: chatcmpl-123
    #|        model: gpt-6-astra
    #|        chunks: [Hello, "! How can I", " assist you today?"]
  ),
)

///|
/// smock sends no `system_fingerprint`.
test "the Chat Completions stream equals the reference's Streaming example, but for system_fingerprint" {
  let h = harness([chat_streaming_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  inspect(
    compare_golden(chat_streaming_example, outcome, differs=[
      "/system_fingerprint",
    ]),
    content=(
      #|same but for the listed differences
      #|listed: /system_fingerprint: only in the example
    ),
  )
}

///|
/// The "Functions" example's response, lines 3168 to 3204 of openapi.yaml,
/// copied unchanged: one `chat.completion` with a tool call and no text.
let chat_functions_example : String =
  #|{
  #|  "id": "chatcmpl-abc123",
  #|  "object": "chat.completion",
  #|  "created": 1699896916,
  #|  "model": "gpt-6-astra",
  #|  "choices": [
  #|    {
  #|      "index": 0,
  #|      "message": {
  #|        "role": "assistant",
  #|        "content": null,
  #|        "tool_calls": [
  #|          {
  #|            "id": "call_abc123",
  #|            "type": "function",
  #|            "function": {
  #|              "name": "get_current_weather",
  #|              "arguments": "{\n\"location\": \"Boston, MA\"\n}"
  #|            }
  #|          }
  #|        ]
  #|      },
  #|      "logprobs": null,
  #|      "finish_reason": "tool_calls"
  #|    }
  #|  ],
  #|  "usage": {
  #|    "prompt_tokens": 82,
  #|    "completion_tokens": 17,
  #|    "total_tokens": 99,
  #|    "completion_tokens_details": {
  #|      "reasoning_tokens": 0,
  #|      "accepted_prediction_tokens": 0,
  #|      "rejected_prediction_tokens": 0
  #|    }
  #|  }
  #|}

///|
/// A Mock `openai` whose Stub `functions` declares the "Functions"
/// example's content: no text, its tool call with its id and its arguments
/// as the example writes them, its id, its model and its usage.
let chat_functions_stub : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: functions
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        id: chatcmpl-abc123
    #|        model: gpt-6-astra
    #|        toolCalls:
    #|          - id: call_abc123
    #|            name: get_current_weather
    #|            arguments: "{\n\"location\": \"Boston, MA\"\n}"
    #|        usage: { input: 82, output: 17 }
  ),
)

///|
/// smock writes every Chat Completions reply with the members of the
/// Default example, which this one leaves out:
///
/// - `refusal` and `annotations` of the message;
/// - `prompt_tokens_details`, and `audio_tokens` in
///   `completion_tokens_details`, of the usage;
/// - `service_tier`.
test "the Chat Completions JSON reply with a tool call equals the reference's Functions example, but for the members smock writes in every reply" {
  let h = harness([chat_functions_stub])
  h.now = 1_699_896_916_000L
  let outcome = h.chat(
    body="{\"model\":\"gpt-6-astra\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather like in Boston today?\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_current_weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}},\"required\":[\"location\"]}}}],\"tool_choice\":\"auto\"}",
  )
  inspect(
    compare_golden(chat_functions_example, outcome, differs=[
      "/choices/0/message/refusal", "/choices/0/message/annotations", "/usage/prompt_tokens_details",
      "/usage/completion_tokens_details/audio_tokens", "/service_tier",
    ]),
    content=(
      #|same but for the listed differences
      #|listed: /choices/0/message/refusal: only in smock's
      #|listed: /choices/0/message/annotations: only in smock's
      #|listed: /usage/prompt_tokens_details: only in smock's
      #|listed: /usage/completion_tokens_details/audio_tokens: only in smock's
      #|listed: /service_tier: only in smock's
    ),
  )
}
