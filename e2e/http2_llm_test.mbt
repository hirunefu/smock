// Seam 2 tests of LLM responses over h2c: an `llm` stream travels as the
// events of an `events` response do, as DATA of its own HTTP/2 stream, and
// the JSON reply as an ordinary body, with nothing special per protocol.

///|
/// The frames of a POST of the JSON text `body` to `path` on `stream`:
/// HEADERS, then one DATA frame that carries the body and ends the stream.
fn RawH2::post_json(
  self : RawH2,
  stream : Int32,
  path : String,
  body : String,
) -> Array[@http2.Frame] {
  [
    headers_frame(
      stream,
      self.block(
        [
          ..request_fields("POST", path, "localhost"),
          ("content-type", "application/json"),
        ],
      ),
      end_stream=false,
    ),
    Data(stream_id=stream, data=@utf8.encode(body), end_stream=true, padding=0),
  ]
}

///|
/// Reads frames until one ends `stream`, or smock ends the connection, and
/// shows each as `render_frame` does, a line each, except the DATA frames
/// of `stream`: each shows as its flags on a line, then its octets as text,
/// as they came, so that the empty line that ends an event shows.
async fn RawH2::texts_until_end_of(self : RawH2, stream : Int32) -> String {
  let out = StringBuilder()
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.write_string("closed\n")
      break
    }
    match frame {
      Data(stream_id~, data~, end_stream~, ..) if stream_id == stream =>
        out.write_string(
          "DATA \{stream}\{flag(end_stream, " END_STREAM")}:\n\{@utf8.decode_lossy(data)}",
        )
      _ => out.write_string("\{self.render_frame(frame)}\n")
    }
    if ends_stream(frame, stream) {
      break
    }
  }
  out.to_string()
}

///|
async test "h2c: a streamed request to an openai-chat Stub gets HEADERS with text/event-stream and no content-length, then each chunk as DATA, and the DATA of data: [DONE] ends the stream, its entry committed by then" {
  with_definitions([("openai.json", openai_chat)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2()
      defer raw.close()
      let from = @async.now()
      raw.send(raw.post_json(1, "/v1/chat/completions", chat_request("true")))
      let frames = raw.texts_until_end_of(1)
      let to = @async.now()
      // Read right after the last event.
      let entries = smock.journal_once(1, within=0)
      inspect(
        mask_created(frames + "---\n" + entries.join("\n"), from~, to~),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, content-type: text/event-stream, x-ratelimit-remaining-requests: 59, x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8, smock-mock: openai; via=default, date: <now>]
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
          #|
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}
          #|
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! 天"},"logprobs":null,"finish_reason":null}]}
          #|
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"気は晴れ"},"logprobs":null,"finish_reason":null}]}
          #|
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":" 👍"},"logprobs":null,"finish_reason":null}]}
          #|
          #|DATA 1:
          #|data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":<received>,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
          #|
          #|DATA 1 END_STREAM:
          #|data: [DONE]
          #|
          #|---
          #|/v1/chat/completions: stub "chat", status 200
        ),
      )
    })
  })
}
