// Tests of how a reply's text is cut into pieces: by `chunkSize` code
// points, or into the pieces `chunks` gives. They go through the package's
// public interface, with an `openai-chat` declaration, and run on native
// and on wasm-gc with the same output.

///|
/// The reply of an `openai-chat` declaration whose chunk size is
/// `chunk_size`, by default left out, with the strings `strings`, to a
/// request that sets `stream: true` when `streams` holds and to one that
/// does not otherwise.
fn chunked_reply(
  strings : @llm.Strings,
  chunk_size? : Int32,
  streams~ : Bool = true,
) -> @llm.Reply {
  @llm.reply(
    @llm.Declaration(api=OpenaiChat, chunk_size?),
    strings,
    request=Some({ "stream": streams }),
    now=received,
    ids=@llm.ids_generator(7),
  )
}

///|
/// The pieces that the stream of `strings` carries, in order, each with
/// its wait slot: the content of each chunk after the opening one.
fn carried(
  strings : @llm.Strings,
  chunk_size? : Int32,
) -> Array[(String, String)] {
  guard chunked_reply(strings, chunk_size?).body is Events(events) else {
    abort("the JSON reply")
  }
  let pieces = []
  for event in events {
    let chunk = @json.parse(event.data) catch { _ => continue }
    match chunk {
      {
        "choices": [{ "delta": { "content": String(piece), .. } as delta, .. }],
        ..
      } if !(delta is Object(members) && members.contains("role")) =>
        pieces.push((slot(event.wait), piece))
      _ => ()
    }
  }
  pieces
}

///|
/// The pieces of the stream of `text` with the chunk size `chunk_size`, as
/// `"piece"` each, after a check that they join to exactly the text.
fn cut(text : String, chunk_size? : Int32) -> String raise {
  let pieces = carried(@llm.Strings(text~), chunk_size?).map(p => p.1)
  guard pieces.join("") == text else {
    fail("\{@debug.to_string(pieces)} do not join to \{text.escape()}")
  }
  pieces.map(piece => piece.escape()).join(" | ")
}

///|
test "chunkSize 1 sends one code point per piece, an emoji or a code point outside the Basic Multilingual Plane included" {
  inspect(
    [
      cut("Hello!", chunk_size=1),
      cut("天気は晴れ", chunk_size=1),
      cut("👍🏽🇫🇷", chunk_size=1),
      cut("𝄞a𠀋", chunk_size=1),
    ].join("\n"),
    content=(
      #|"H" | "e" | "l" | "l" | "o" | "!"
      #|"天" | "気" | "は" | "晴" | "れ"
      #|"👍" | "🏽" | "🇫" | "🇷"
      #|"𝄞" | "a" | "𠀋"
    ),
  )
}

///|
test "a chunkSize above the text's length sends the text as one piece; other sizes cut every chunkSize code points, the last piece shorter" {
  inspect(
    [
      cut("Hello!", chunk_size=7),
      cut("Hello!", chunk_size=6),
      cut("Hello!", chunk_size=@llm.max_chunk_size),
      cut("天気は晴れです。", chunk_size=3),
      cut("Hello, world", chunk_size=5),
      cut("𝄞𠀋𝄞𠀋𝄞", chunk_size=2),
      cut("Hi 🇫🇷!", chunk_size=2),
    ].join("\n"),
    content=(
      #|"Hello!"
      #|"Hello!"
      #|"Hello!"
      #|"天気は" | "晴れで" | "す。"
      #|"Hello" | ", wor" | "ld"
      #|"𝄞𠀋" | "𝄞𠀋" | "𝄞"
      #|"Hi" | " 🇫" | "🇷!"
    ),
  )
}

///|
test "without chunkSize, pieces hold 4 code points" {
  inspect(
    [
      cut("Hello, world"),
      cut("天気は晴れです。"),
      cut("𝄞𠀋𝄞𠀋𝄞"),
    ].join("\n"),
    content=(
      #|"Hell" | "o, w" | "orld"
      #|"天気は晴" | "れです。"
      #|"𝄞𠀋𝄞𠀋" | "𝄞"
    ),
  )
}

///|
/// The pieces of the stream of `chunks`, each after its wait slot, after a
/// check that each element is one piece, in order.
fn given(chunks : ReadOnlyArray[String], chunk_size? : Int32) -> String raise {
  let pieces = carried(@llm.Strings(chunks~), chunk_size?)
  guard pieces.map(p => p.1) == chunks.iter().collect() else {
    fail("\{@debug.to_string(pieces)} are not \{@debug.to_string(chunks)}")
  }
  pieces.map(p => "(\{p.0}) \{p.1.escape()}").join(" | ")
}

///|
test "chunks gives the pieces: each element is one piece in its wait slot, an empty one included, whatever chunkSize says" {
  inspect(
    [
      given(["Hel", "", "lo", "!"]),
      given(["", "Hi"]),
      given(["Hi", ""]),
      given([""]),
      given(["", ""]),
      given(
        ["天気は晴れです。", "👍🏽", "🇫", "🇷", "𝄞𠀋"],
        chunk_size=1,
      ),
    ].join("\n"),
    content=(
      #|(first) "Hel" | (interval) "" | (interval) "lo" | (interval) "!"
      #|(first) "" | (interval) "Hi"
      #|(first) "Hi" | (interval) ""
      #|(first) ""
      #|(first) "" | (interval) ""
      #|(first) "天気は晴れです。" | (interval) "👍🏽" | (interval) "🇫" | (interval) "🇷" | (interval) "𝄞𠀋"
    ),
  )
}

///|
test "a stream of chunks: the opening chunk, a chunk per element, an empty one in its own event, the closing chunk with no wait, then [DONE]" {
  guard chunked_reply(@llm.Strings(chunks=["", "Hi", ""])).body
    is Events(events) else {
    fail("the JSON reply")
  }
  inspect(
    events.map(e => "(\{slot(e.wait)}) data: \{e.data}").join("\n"),
    content=(
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}
      #|(first) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"","choices":[{"index":0,"delta":{"content":""},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"","choices":[{"index":0,"delta":{"content":"Hi"},"logprobs":null,"finish_reason":null}]}
      #|(interval) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"","choices":[{"index":0,"delta":{"content":""},"logprobs":null,"finish_reason":null}]}
      #|(none) data: {"id":"chatcmpl-KCVauEuclT08Mg4CWd55sNbz","object":"chat.completion.chunk","created":1791815405,"model":"","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}
      #|(none) data: [DONE]
    ),
  )
}

///|
/// The `content` of the JSON reply with the strings `strings`, as compact
/// JSON writes it.
fn json_content(strings : @llm.Strings) -> String {
  let body = json_text(chunked_reply(strings, streams=false))
  let start = body.find("\"content\":").unwrap() + "\"content\":".length()
  body[start:body.find(",\"refusal\"").unwrap()].to_owned()
}

///|
test "the JSON reply carries the join of chunks as its content" {
  inspect(
    [
      json_content(@llm.Strings(chunks=["Hel", "", "lo", "!"])),
      json_content(@llm.Strings(chunks=[""])),
      json_content(
        @llm.Strings(chunks=[
          "天気は", "晴れ", "👍🏽", "🇫", "🇷", "𝄞𠀋",
        ]),
      ),
    ].join("\n"),
    content=(
      #|"Hello!"
      #|""
      #|"天気は晴れ👍🏽🇫🇷𝄞𠀋"
    ),
  )
}

///|
test "for every size, each piece holds chunkSize code points but the last, which holds 1 to chunkSize, each is valid UTF-8, and they join to exactly the text" {
  let texts = [
    "Hello! How can I assist you today?", "天気は晴れです。", "Done 👍🏽 🇫🇷",
    "𝄞 and 𠀋, outside the Basic Multilingual Plane", "a \"quote\",\na line break",
    "x",
  ]
  let mut checked = 0
  for text in texts {
    for size in 1..<=12 {
      let pieces = carried(@llm.Strings(text~), chunk_size=size).map(p => p.1)
      guard pieces.join("") == text else {
        fail("size \{size}: \{@debug.to_string(pieces)} do not join to \{text}")
      }
      for i, piece in pieces {
        let mut count = 0
        for _ in piece {
          count += 1
        }
        let last = i == pieces.length() - 1
        guard count == size || (last && count >= 1 && count < size) else {
          fail("size \{size}: piece \{piece.escape()} holds \{count}")
        }
        let decoded = @utf8.decode(@utf8.encode(piece)) catch {
          _ => fail("size \{size}: not valid UTF-8: \{piece.escape()}")
        }
        guard decoded == piece else {
          fail("size \{size}: not valid UTF-8: \{piece.escape()}")
        }
      }
      checked += 1
    }
  }
  inspect(checked, content="72")
}
