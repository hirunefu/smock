// Goldens of `openai-responses`: the Responses examples of OpenAI's
// OpenAPI document, and the function-call stream of its function-calling
// guide, each compared with what smock sends for a Stub that declares the
// example's content (see llm_golden_test.mbt).
//
// Source of every example below but the guide's: openapi.yaml of
// https://github.com/openai/openai-openapi at commit
// 762a1df070a80bf73ac85804a4b1a492d9a108a1, the `x-oaiMeta` examples of the
// operation `createResponse` and of the events `response.incomplete` and
// `error`, read on 2026-10-24. That repository's licence, under which they
// are copied:
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
//
// Source of the guide's stream: the "Streaming" section of
// https://developers.openai.com/api/docs/guides/function-calling, read on
// 2026-10-24 as its Markdown export (the page's URL followed by `.md`). The
// page grants no licence, so the stream is a short excerpt, used as test
// data only. None of these examples is part of the smock binary, so NOTICE
// does not name them.

///|
/// A Mock `openai` with the one Stub `stub`, given as YAML lines that start
/// with `- id:`, each indented by two spaces.
fn openai_golden_mock(stub : String) -> (String, String) {
  (
    "openai.yaml",
    (
      #|mocks:
      #|  - name: openai
      #|    hosts: [api.openai.test]
      #|stubs:
      #|
    ) +
    stub,
  )
}

///|
/// The "Streaming" example's response, lines 22543 to 22570 of
/// openapi.yaml, copied unchanged: the Response's opening events, the
/// message item's events up to its first piece, a comment that stands for
/// the five pieces left out, then the item's closing events and
/// `response.completed`.
let responses_streaming_example : String =
  #|event: response.created
  #|data: {"type":"response.created","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","access_programs":null,"created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}
  #|
  #|event: response.in_progress
  #|data: {"type":"response.in_progress","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","access_programs":null,"created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":1}
  #|
  #|event: response.output_item.added
  #|data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":2}
  #|
  #|event: response.content_part.added
  #|data: {"type":"response.content_part.added","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]},"sequence_number":3}
  #|
  #|event: response.output_text.delta
  #|data: {"type":"response.output_text.delta","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"delta":"Hi","sequence_number":4,"logprobs":[]}
  #|
  #|: Intermediate response events omitted.
  #|
  #|event: response.output_text.done
  #|data: {"type":"response.output_text.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"text":"Hi there! How can I assist you today?","sequence_number":10,"logprobs":[]}
  #|
  #|event: response.content_part.done
  #|data: {"type":"response.content_part.done","item_id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]},"sequence_number":11}
  #|
  #|event: response.output_item.done
  #|data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]},"sequence_number":12}
  #|
  #|event: response.completed
  #|data: {"type":"response.completed","response":{"id":"resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654","object":"response","access_programs":null,"created_at":1741290958,"status":"completed","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0}},"user":null,"metadata":{}},"sequence_number":13}

///|
/// A Mock `openai` whose Stub `streaming` declares the "Streaming"
/// example's content: its first piece, then five pieces of its own for the
/// events the example leaves out, so that the closing events keep their
/// numbers, its id, its model and its usage.
let responses_streaming_stub : (String, String) = openai_golden_mock(
  (
    #|  - id: streaming
    #|    mock: openai
    #|    request: { method: POST, path: /v1/responses }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        id: resp_67c9fdcecf488190bdd9a0409de3a1ec07b8b0ad4e5eb654
    #|        model: gpt-6-astra
    #|        chunks: [Hi, " there!", " How", " can I", " assist you", " today?"]
    #|        usage: { input: 37, output: 11 }
  ),
)

///|
/// The message item's id is generated. smock's Response objects carry
/// `completed_at`, null until `response.completed`, and `service_tier`,
/// as the reference's JSON replies do; this example's leave both out.
test "the Responses stream equals the reference's Streaming example, but for completed_at and service_tier" {
  let h = harness([responses_streaming_stub])
  h.now = 1_741_290_958_000L
  let outcome = h.responses(
    "{\"model\":\"gpt-6-astra\",\"instructions\":\"You are a helpful assistant.\",\"input\":\"Hello!\",\"stream\":true}",
  )
  inspect(
    compare_golden(
      responses_streaming_example,
      outcome,
      differs=["/response/completed_at", "/response/service_tier"],
      unfixed=["msg_67c9fdcf37fc8190ba82116e33fb28c507b8b0ad4e5eb654"],
    ),
    content=(
      #|same but for the listed differences
      #|listed: /response/completed_at: only in smock's
      #|listed: /response/service_tier: only in smock's
    ),
  )
}

///|
/// The "Text input" example's response, lines 21713 to 21772 of
/// openapi.yaml, copied unchanged: one Response object with text.
let responses_text_example : String =
  #|{
  #|  "id": "resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b",
  #|  "object": "response",
  #|  "access_programs": null,
  #|  "created_at": 1741476542,
  #|  "status": "completed",
  #|  "completed_at": 1741476543,
  #|  "error": null,
  #|  "incomplete_details": null,
  #|  "instructions": null,
  #|  "max_output_tokens": null,
  #|  "model": "gpt-6-astra",
  #|  "output": [
  #|    {
  #|      "type": "message",
  #|      "id": "msg_67ccd2bf17f0819081ff3bb2cf6508e60bb6a6b452d3795b",
  #|      "status": "completed",
  #|      "role": "assistant",
  #|      "content": [
  #|        {
  #|          "type": "output_text",
  #|          "text": "In a peaceful grove beneath a silver moon, a unicorn named Lumina discovered a hidden pool that reflected the stars. As she dipped her horn into the water, the pool began to shimmer, revealing a pathway to a magical realm of endless night skies. Filled with wonder, Lumina whispered a wish for all who dream to find their own hidden magic, and as she glanced back, her hoofprints sparkled like stardust.",
  #|          "annotations": [],
  #|          "logprobs": []
  #|        }
  #|      ]
  #|    }
  #|  ],
  #|  "parallel_tool_calls": true,
  #|  "previous_response_id": null,
  #|  "reasoning": {
  #|    "effort": null,
  #|    "summary": null
  #|  },
  #|  "store": true,
  #|  "temperature": 1.0,
  #|  "text": {
  #|    "format": {
  #|      "type": "text"
  #|    }
  #|  },
  #|  "tool_choice": "auto",
  #|  "tools": [],
  #|  "top_p": 1.0,
  #|  "truncation": "disabled",
  #|  "usage": {
  #|    "input_tokens": 36,
  #|    "input_tokens_details": {
  #|      "cached_tokens": 0,
  #|      "cache_write_tokens": 0
  #|    },
  #|    "output_tokens": 87,
  #|    "output_tokens_details": {
  #|      "reasoning_tokens": 0
  #|    },
  #|    "total_tokens": 123
  #|  },
  #|  "user": null,
  #|  "metadata": {}
  #|}

///|
/// A Mock `openai` whose Stub `text` declares the "Text input" example's
/// content: its text, its id, its model and its usage.
let responses_text_stub : (String, String) = openai_golden_mock(
  (
    #|  - id: text
    #|    mock: openai
    #|    request: { method: POST, path: /v1/responses }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        id: resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b
    #|        model: gpt-6-astra
    #|        text: In a peaceful grove beneath a silver moon, a unicorn named Lumina discovered a hidden pool that reflected the stars. As she dipped her horn into the water, the pool began to shimmer, revealing a pathway to a magical realm of endless night skies. Filled with wonder, Lumina whispered a wish for all who dream to find their own hidden magic, and as she glanced back, her hoofprints sparkled like stardust.
    #|        usage: { input: 36, output: 87 }
  ),
)

///|
/// The message item's id is generated. smock sends a JSON reply at once,
/// so it completes in the second it was created, where the example's took
/// one more; and it writes `service_tier`, the Chat Completions example's
/// default tier, which this example leaves out.
test "the Responses JSON reply equals the reference's Text input example, but for completed_at and service_tier" {
  let h = harness([responses_text_stub])
  h.now = 1_741_476_542_000L
  let outcome = h.responses(
    "{\"model\":\"gpt-6-astra\",\"input\":\"Tell me a three sentence bedtime story about a unicorn.\"}",
  )
  inspect(
    compare_golden(
      responses_text_example,
      outcome,
      differs=["/completed_at", "/service_tier"],
      unfixed=["msg_67ccd2bf17f0819081ff3bb2cf6508e60bb6a6b452d3795b"],
    ),
    content=(
      #|same but for the listed differences
      #|listed: /completed_at: values differ
      #|listed: /service_tier: only in smock's
    ),
  )
}

///|
/// The "Functions" example's response, lines 22727 to 22807 of
/// openapi.yaml, copied unchanged: one Response object with a function
/// call and no text.
let responses_functions_example : String =
  #|{
  #|  "id": "resp_67ca09c5efe0819096d0511c92b8c890096610f474011cc0",
  #|  "object": "response",
  #|  "access_programs": null,
  #|  "created_at": 1741294021,
  #|  "status": "completed",
  #|  "completed_at": 1741294022,
  #|  "error": null,
  #|  "incomplete_details": null,
  #|  "instructions": null,
  #|  "max_output_tokens": null,
  #|  "model": "gpt-6-astra",
  #|  "output": [
  #|    {
  #|      "type": "function_call",
  #|      "id": "fc_67ca09c6bedc8190a7abfec07b1a1332096610f474011cc0",
  #|      "call_id": "call_unLAR8MvFNptuiZK6K6HCy5k",
  #|      "name": "get_current_weather",
  #|      "arguments": "{\"location\":\"Boston, MA\",\"unit\":\"celsius\"}",
  #|      "status": "completed"
  #|    }
  #|  ],
  #|  "parallel_tool_calls": true,
  #|  "previous_response_id": null,
  #|  "reasoning": {
  #|    "effort": null,
  #|    "summary": null
  #|  },
  #|  "store": true,
  #|  "temperature": 1.0,
  #|  "text": {
  #|    "format": {
  #|      "type": "text"
  #|    }
  #|  },
  #|  "tool_choice": "auto",
  #|  "tools": [
  #|    {
  #|      "type": "function",
  #|      "description": "Get the current weather in a given location",
  #|      "name": "get_current_weather",
  #|      "parameters": {
  #|        "type": "object",
  #|        "properties": {
  #|          "location": {
  #|            "type": "string",
  #|            "description": "The city and state, e.g. San Francisco, CA"
  #|          },
  #|          "unit": {
  #|            "type": "string",
  #|            "enum": [
  #|              "celsius",
  #|              "fahrenheit"
  #|            ]
  #|          }
  #|        },
  #|        "required": [
  #|          "location",
  #|          "unit"
  #|        ]
  #|      },
  #|      "strict": true
  #|    }
  #|  ],
  #|  "top_p": 1.0,
  #|  "truncation": "disabled",
  #|  "usage": {
  #|    "input_tokens": 291,
  #|    "output_tokens": 23,
  #|    "output_tokens_details": {
  #|      "reasoning_tokens": 0
  #|    },
  #|    "total_tokens": 314,
  #|    "input_tokens_details": {
  #|      "cached_tokens": 0,
  #|      "cache_write_tokens": 0
  #|    }
  #|  },
  #|  "user": null,
  #|  "metadata": {}
  #|}

///|
/// A Mock `openai` whose Stub `functions` declares the "Functions"
/// example's content: no text, its tool call with its call id and its
/// arguments, its id, its model and its usage.
let responses_functions_stub : (String, String) = openai_golden_mock(
  (
    #|  - id: functions
    #|    mock: openai
    #|    request: { method: POST, path: /v1/responses }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-responses
    #|        id: resp_67ca09c5efe0819096d0511c92b8c890096610f474011cc0
    #|        model: gpt-6-astra
    #|        toolCalls:
    #|          - id: call_unLAR8MvFNptuiZK6K6HCy5k
    #|            name: get_current_weather
    #|            arguments: { location: "Boston, MA", unit: celsius }
    #|        usage: { input: 291, output: 23 }
  ),
)

///|
/// The request is the example's. The function call item's id is
/// generated. smock completes the reply at once and writes `service_tier`,
/// as with the Text input example. It copies `tools` as the request gives
/// them, without interpreting them, where the API made the tool strict and
/// shows `strict: true`.
test "the Responses JSON reply with a function call equals the reference's Functions example, but for completed_at, service_tier and the tool's strict" {
  let h = harness([responses_functions_stub])
  h.now = 1_741_294_021_000L
  let outcome = h.responses(
    (
      #|{
      #|  "model": "gpt-6-astra",
      #|  "input": "What is the weather like in Boston today?",
      #|  "tools": [
      #|    {
      #|      "type": "function",
      #|      "name": "get_current_weather",
      #|      "description": "Get the current weather in a given location",
      #|      "parameters": {
      #|        "type": "object",
      #|        "properties": {
      #|          "location": {
      #|            "type": "string",
      #|            "description": "The city and state, e.g. San Francisco, CA"
      #|          },
      #|          "unit": {
      #|            "type": "string",
      #|            "enum": ["celsius", "fahrenheit"]
      #|          }
      #|        },
      #|        "required": ["location", "unit"]
      #|      }
      #|    }
      #|  ],
      #|  "tool_choice": "auto"
      #|}
    ),
  )
  inspect(
    compare_golden(
      responses_functions_example,
      outcome,
      differs=["/completed_at", "/service_tier", "/tools/0/strict"],
      unfixed=["fc_67ca09c6bedc8190a7abfec07b1a1332096610f474011cc0"],
    ),
    content=(
      #|same but for the listed differences
      #|listed: /completed_at: values differ
      #|listed: /service_tier: only in smock's
      #|listed: /tools/0/strict: only in the example
    ),
  )
}
