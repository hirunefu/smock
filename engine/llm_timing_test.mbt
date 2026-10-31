// Seam 1 tests of the pacing of LLM streams: the waits the engine draws for
// `timing.first` and `timing.interval`, by the wait slots of the events,
// from the request's waits generator.

///|
/// A Mock `openai` whose Stub answers Chat Completions requests with an LLM
/// response whose text is `text` and whose `llm` has the members `fields`
/// after `api` and `text`, given as JSON text, and whose `fault` is
/// `fault`, by default only the seed 7.
fn paced_mock(
  text~ : String = "Hello! How can I assist you today?",
  fields~ : String = "",
  fault~ : String = "{ \"seed\": 7 }",
) -> (String, String) {
  (
    "openai.json",
    (
      $|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      $|  "stubs": [{ "id": "chat", "mock": "openai",
      $|    "request": { "method": "POST", "path": "/v1/chat/completions" },
      $|    "response": { "status": 200,
      $|      "llm": { "api": "openai-chat", "text": "\{text}"\{fields} } },
      $|    "fault": \{fault} }] }
    ),
  )
}

///|
/// The waits of the events of `outcome`'s plan, in milliseconds, each with
/// what its event carries: the opening chunk, a piece, the closing chunk or
/// the end marker.
fn waits(outcome : @engine.Outcome) -> String {
  guard outcome.plan.body is Events(events) else { return "no events" }
  let out = []
  for event in events {
    let data = @json.parse(event.data) catch { _ => Json::null() }
    let carries = match data {
      { "choices": [{ "delta": { "role": _, .. }, .. }], .. } => "opening"
      { "choices": [{ "delta": { "content": String(piece), .. }, .. }], .. } =>
        piece.escape()
      { "choices": [{ "finish_reason": String(_), .. }], .. } => "closing"
      _ => event.data
    }
    out.push("\{event.delay_ms} \{carries}")
  }
  out.join(", ")
}

///|
test "with fixed waits, the opening chunk follows the head at once, the first piece waits first, each later piece waits interval, and the closing chunk and [DONE] follow at once" {
  let h = harness([
    paced_mock(
      fields=", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }",
    ),
  ])
  inspect(
    waits(h.chat(body=stream_body("true"))),
    content=(
      #|0 opening, 400 "Hell", 30 "o! H", 30 "ow c", 30 "an I", 30 " ass", 30 "ist ", 30 "you ", 30 "toda", 30 "y?", 0 closing, 0 [DONE]
    ),
  )
}

///|
test "a reply with no piece waits first before its closing chunk, and never interval" {
  let h = harness([
    paced_mock(
      text="",
      fields=", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }",
    ),
  ])
  inspect(
    waits(h.chat(body=stream_body("true"))),
    content=(
      #|0 opening, 400 closing, 0 [DONE]
    ),
  )
}

///|
/// The waits of the events of `outcome`'s plan, in milliseconds, in order.
fn wait_list(outcome : @engine.Outcome) -> Array[Int32] {
  guard outcome.plan.body is Events(events) else { return [] }
  events.iter().map(event => event.delay_ms).collect()
}

///|
/// `waits`, separated by spaces.
fn numbers(waits : ArrayView[Int32]) -> String {
  waits.iter().map(wait => wait.to_string()).collect().join(" ")
}

///|
/// A text of 200 code points: 50 pieces of the default size.
let long_text : String = "abcd".repeat(50)

///|
test "each distribution is drawn from the waits generator, one wait per piece, and the draws of seed 7 are pinned on every target" {
  let h = harness([
    paced_mock(
      text=long_text,
      fields=", \"timing\": { \"first\": { \"uniform\": { \"min\": 100, \"max\": 300 } }, \"interval\": { \"uniform\": { \"min\": 15, \"max\": 40 } } }",
    ),
  ])
  let uniform = wait_list(h.chat(body=stream_body("true")))
  let h = harness([
    paced_mock(
      text=long_text,
      fields=", \"timing\": { \"first\": { \"lognormal\": { \"median\": 400, \"sigma\": 0.5 } }, \"interval\": { \"lognormal\": { \"median\": 25, \"sigma\": 0 } } }",
    ),
  ])
  let lognormal = wait_list(h.chat(body=stream_body("true")))
  // The opening chunk, 50 pieces, the closing chunk and [DONE].
  let pieces = (waits : Array[Int32]) => waits[1:51]
  let intervals = (waits : Array[Int32]) => waits[2:51]
  inspect(
    [
      "uniform: \{uniform.length()} events; first \{uniform[1]}, from 100 to 300: \{uniform[1] >= 100 && uniform[1] <= 300}; every interval from 15 to 40: \{intervals(uniform).iter().all(w => w >= 15 && w <= 40)}, not all the same: \{intervals(uniform).iter().any(w => w != uniform[2])}",
      "  pieces: \{numbers(pieces(uniform))}",
      "  the rest: \{numbers([uniform[0], uniform[51], uniform[52]])}",
      "lognormal: first \{lognormal[1]}; sigma 0 gives the median: \{intervals(lognormal).iter().all(w => w == 25)}",
    ].join("\n"),
    content=(
      #|uniform: 53 events; first 121, from 100 to 300: true; every interval from 15 to 40: true, not all the same: true
      #|  pieces: 121 38 27 20 38 19 40 38 26 28 36 27 22 29 15 28 25 35 39 20 17 19 36 27 31 20 40 37 33 31 30 39 15 40 22 38 22 34 22 29 18 31 35 26 19 31 31 33 24 30
      #|  the rest: 0 0 0
      #|lognormal: first 824; sigma 0 gives the median: true
    ),
  )
}

///|
/// The `timing` of the spec's example: a log-normal first wait around
/// 400 ms and uniform intervals from 15 to 40 ms, as `llm` members.
let example_timing : String = ", \"timing\": { \"first\": { \"lognormal\": { \"median\": 400, \"sigma\": 0.5 } }, \"interval\": { \"uniform\": { \"min\": 15, \"max\": 40 } } }"

///|
test "the same seed gives the same waits in every run, request by request, and another seed others" {
  // Each harness is a run: a new engine, and a process generator seeded
  // as `process_seed` says.
  let run = (seed : Int32, process_seed : UInt64) => {
    let h = harness(
      [paced_mock(fields=example_timing, fault="{ \"seed\": \{seed} }")],
      process_seed~,
    )
    Array::makei(3, _ => wait_list(h.chat(body=stream_body("true"))))
  }
  let first = run(7, 1)
  inspect(
    [
      "seed 7 again: \{run(7, 2) == first}",
      "seed 8: \{run(8, 1) == first}",
      "each request draws its own: \{first[0] != first[1] && first[1] != first[2]}",
    ].join("\n"),
    content=(
      #|seed 7 again: true
      #|seed 8: false
      #|each request draws its own: true
    ),
  )
}

///|
/// A Mock `openai` whose Stub mixes a 429 and an LLM reply whose
/// header draws a helper value, with a seeded delay and close Fault, and
/// whose `llm` has the members `fields` after `api` and `text`.
fn mixed_mock(fields : String) -> (String, String) {
  (
    "openai.json",
    (
      $|{ "mocks": [{ "name": "openai", "hosts": ["api.openai.test"] }],
      $|  "stubs": [{ "id": "chat", "mock": "openai",
      $|    "request": { "method": "POST", "path": "/v1/chat/completions" },
      $|    "responses": [
      $|      { "status": 429, "json": { "error": { "type": "rate_limit_exceeded" } } },
      $|      { "status": 200, "weight": 3, "template": true,
      $|        "headers": { "x-trace": "${fake.uuid()}" },
      $|        "llm": { "api": "openai-chat", "text": "Hello! How can I assist you today?"\{fields} } } ],
      $|    "fault": { "seed": 7,
      $|      "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
      $|      "connection": { "kind": "close", "probability": 0.25 } } }] }
    ),
  )
}

///|
/// What `outcome` got apart from its waits: the pick, the status, the Fault
/// decisions, the helper value in `x-trace` and the reply's id.
fn all_but_waits(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  let trace = plan.headers
    .iter()
    .find_first(header => header.0 == "x-trace")
    .map_or("-", header => header.1)
  let first = match plan.body {
    Events(events) => @json.parse(events[0].data) catch { _ => Json::null() }
    Bytes(_) => Json::null()
  }
  let id = match first {
    { "id": String(id), .. } => id
    _ => "-"
  }
  let index = outcome.journal.map_or("-", entry => {
    entry.response_index.map_or("-", i => i.to_string())
  })
  "response \{index}, status \{plan.status}, delay \{plan.delay_ms}, fault \{@debug.to_string(plan.fault)}, x-trace \{trace}, id \{id}"
}

///|
test "adding timing changes no id, no Fault decision, no pick and no helper output" {
  let run = (fields : String) => {
    let h = harness([mixed_mock(fields)])
    let got = []
    let waits = []
    for _ in 0..<8 {
      let outcome = h.chat(body=stream_body("true"))
      got.push(all_but_waits(outcome))
      waits.push(wait_list(outcome).fold(init=0, (sum, wait) => sum + wait))
    }
    (got, waits)
  }
  let (without, no_waits) = run("")
  let (with_timing, waits) = run(example_timing)
  inspect(
    [
      "the same without and with timing: \{without == with_timing}",
      "the waits of each request, in all, without timing: \{numbers(no_waits)}",
      "with timing: \{numbers(waits)}",
      ..without,
    ].join("\n"),
    content=(
      #|the same without and with timing: true
      #|the waits of each request, in all, without timing: 0 0 0 0 0 0 0 0
      #|with timing: 1060 686 550 354 0 699 938 838
      #|response 1, status 200, delay 189, fault None, x-trace 491faadb-213a-4ae9-b52a-e618828349a6, id chatcmpl-oniRcSDFUU6bnxe66XwQR5pl
      #|response 1, status 200, delay 0, fault None, x-trace 1536f6e7-42e4-4013-8961-f70141e4a66e, id chatcmpl-lM10tfraqbMuqY6lc9FjN5n8
      #|response 1, status 200, delay 809, fault Some(Close), x-trace 35f7c125-4a1c-4694-8818-45fb8765ab32, id chatcmpl-sYbxupdedZuAOye5C75BpQuY
      #|response 1, status 200, delay 0, fault None, x-trace ce737663-bd25-44aa-8901-00b185724762, id chatcmpl-zQLnUu77sZ7eoZollCsu1gWj
      #|response 0, status 429, delay 749, fault None, x-trace -, id -
      #|response 1, status 200, delay 20, fault None, x-trace 460bc8e2-3b5e-4309-9ddb-1d40837a14d3, id chatcmpl-VxAi9muUoZONR8GEkiSVPY6L
      #|response 1, status 200, delay 0, fault None, x-trace a053458a-d9aa-4f61-a505-d699322d7ee5, id chatcmpl-IIT264zYa005LKjNK19EL5Ye
      #|response 1, status 200, delay 0, fault Some(Close), x-trace b8e492b5-98f6-457e-aa68-c77b6841d335, id chatcmpl-ALNvBd5EOcAF4T2eToYBs1VP
    ),
  )
}

///|
test "a JSON reply is planned whole, with no wait, whatever timing gives" {
  let h = harness([paced_mock(fields=example_timing)])
  let outcome = h.chat(body=stream_body("false"))
  inspect(
    "\{form(outcome)}; delay \{outcome.plan.delay_ms} ms",
    content=(
      #|200 application/json, a body with object "chat.completion"; delay 0 ms
    ),
  )
}

///|
test "a delay Fault holds back the status line of a stream, before the stream's own waits, and of a JSON reply" {
  let h = harness([
    paced_mock(
      fields=", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }",
      fault="{ \"seed\": 7, \"delay\": { \"fixed\": 250 } }",
    ),
  ])
  let stream = h.chat(body=stream_body("true"))
  let json = h.chat(body=stream_body("false"))
  inspect(
    [
      "stream: status line after \{stream.plan.delay_ms} ms, then the events with their waits: \{waits(stream)}",
      "JSON: status line after \{json.plan.delay_ms} ms, \{form(json)}",
    ].join("\n"),
    content=(
      #|stream: status line after 250 ms, then the events with their waits: 0 opening, 400 "Hell", 30 "o! H", 30 "ow c", 30 "an I", 30 " ass", 30 "ist ", 30 "you ", 30 "toda", 30 "y?", 0 closing, 0 [DONE]
      #|JSON: status line after 250 ms, 200 application/json, a body with object "chat.completion"
    ),
  )
}

///|
test "render shows each event with the wait that the first request of the Stub's seed gets" {
  let h = harness([paced_mock(fields=example_timing)])
  let sample : Json = {
    "method": "POST",
    "path": "/v1/chat/completions",
    "headers": { "Host": "api.openai.test" },
    "body": stream_body("true"),
  }
  let rendering = @json.parse(h.render("chat", sample))
  guard rendering is { "response": { "events": Array(events), .. }, .. } else {
    fail("no events in \{rendering.stringify()}")
  }
  let rendered = events.map(event => {
    guard event is { "delay": Number(delay, ..), .. } else { -1 }
    delay.to_int()
  })
  let requested = wait_list(h.chat(body=stream_body("true")))
  inspect(
    "the same: \{rendered == requested}\n\{numbers(rendered)}",
    content=(
      #|the same: true
      #|0 824 27 20 38 19 40 38 26 28 0 0
    ),
  )
}

///|
test "each element of chunks waits as a piece, an empty one included, and so does each piece that chunkSize cuts" {
  let timing = ", \"timing\": { \"first\": { \"fixed\": 400 }, \"interval\": { \"fixed\": 30 } }"
  let chunks = harness([
    (
      "openai.json",
      paced_mock().1.replace(
        old="\"text\": \"Hello! How can I assist you today?\"",
        new="\"chunks\": [\"Hi\", \"\", \"!\"]\{timing}",
      ),
    ),
  ])
  let sized = harness([
    paced_mock(text="Hello!", fields=", \"chunkSize\": 2\{timing}"),
  ])
  inspect(
    [
      "chunks: \{waits(chunks.chat(body=stream_body("true")))}",
      "chunkSize 2: \{waits(sized.chat(body=stream_body("true")))}",
    ].join("\n"),
    content=(
      #|chunks: 0 opening, 400 "Hi", 30 "", 30 "!", 0 closing, 0 [DONE]
      #|chunkSize 2: 0 opening, 400 "He", 30 "ll", 30 "o!", 0 closing, 0 [DONE]
    ),
  )
}
