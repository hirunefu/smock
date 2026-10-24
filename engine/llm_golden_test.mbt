// The golden comparison of LLM responses: a vendor's documented example,
// copied as test data, compared with what smock sends for a Stub that
// declares the example's content, so that a change in shape shows up in
// review. The goldens of every API share it.

///|
/// One event of a stream, or the one JSON body of a reply: its place, from
/// 1, its name, if any, and its data as written and parsed.
priv struct GoldenEvent {
  number : Int32
  name : String?
  text : String
  /// The data parsed, or None when it is not JSON, as `[DONE]`.
  data : Json?
}

///|
/// The JSON body or event `text`, the `number`th, with the name `name`.
fn golden_event(
  text : String,
  number~ : Int32 = 1,
  name? : String,
) -> GoldenEvent {
  let data = @json.parse(text) catch {
    _ => return { number, name, text, data: None, }
  }
  { number, name, text, data: Some(data), }
}

///|
/// A part of a stream as an example prints it: an event, or a comment that
/// stands for events the example leaves out.
priv enum GoldenItem {
  Event(GoldenEvent)
  Gap
}

///|
/// The Server-Sent Events of `text`, numbered from 1. Each event's `event:`
/// line gives its name and its `data:` lines, joined with line feeds, its
/// data; other fields are ignored. A block of comment lines alone is a gap.
/// The last event needs no blank line after it.
fn golden_stream(text : String) -> Array[GoldenItem] {
  let items = []
  let mut number = 0
  let mut name = None
  let data = []
  let mut comment = false
  let dispatch = () => {
    if !data.is_empty() {
      number += 1
      items.push(Event(golden_event(data.join("\n"), number~, name?)))
    } else if comment {
      items.push(Gap)
    }
    name = None
    data.clear()
    comment = false
  }
  for line in text.split("\n") {
    let line = line.trim_end(chars="\r").to_owned()
    if line == "" {
      dispatch()
    } else if line.has_prefix(":") {
      comment = true
    } else {
      let (field, value) = match line.find(":") {
        Some(i) => {
          let value = line[i + 1:]
          (
            line[:i].to_owned(),
            value.strip_prefix(" ").unwrap_or(value).to_owned(),
          )
        }
        None => (line, "")
      }
      if field == "event" {
        name = Some(value)
      } else if field == "data" {
        data.push(value)
      }
    }
  }
  dispatch()
  items
}

///|
/// The events of `text` printed without SSE framing, as a document shows a
/// stream's events: JSON values one after another, each on one line or
/// over several, numbered from 1 and with no name. A run of comment lines,
/// which start with `:`, is a gap. Lines that make no JSON value before a
/// comment line or the end make one event, compared as text. Blank lines
/// are skipped.
fn golden_unframed(text : String) -> Array[GoldenItem] {
  let items = []
  let mut number = 0
  // The lines of the value read so far.
  let lines = []
  let flush = () => {
    if !lines.is_empty() {
      number += 1
      items.push(Event(golden_event(lines.join("\n"), number~)))
      lines.clear()
    }
  }
  for line in text.split("\n") {
    let line = line.trim_end(chars="\r").to_owned()
    if line.has_prefix(":") {
      flush()
      if !(items.last() is Some(Gap)) {
        items.push(Gap)
      }
    } else if line.trim() != "" {
      lines.push(line)
      if golden_event(lines.join("\n")).data is Some(_) {
        flush()
      }
    }
  }
  flush()
  items
}

///|
/// The events smock planned in `outcome`, written as the server writes
/// them and read back as an example's are, or its JSON body as one event.
/// Returns whether they are a stream, and the events.
fn sent_events(outcome : @engine.Outcome) -> (Bool, Array[GoldenEvent]) {
  match outcome.plan.body {
    Bytes(body) => (false, [golden_event(@utf8.decode_lossy(body))])
    Events(events) => {
      let out = StringBuilder()
      for event in events {
        out.write_string(
          @utf8.decode_lossy(
            @http1.encode_sse_event(
              event.data,
              event?=event.event,
              id?=event.id,
            ),
          ),
        )
      }
      let parsed = []
      for item in golden_stream(out.to_string()) {
        if item is Event(event) {
          parsed.push(event)
        }
      }
      (true, parsed)
    }
  }
}

///|
/// What a comparison has found so far.
priv struct Comparison {
  /// Each difference that is not as listed, one line each.
  problems : Array[String]
  /// The JSON Pointers of the listed differences, each with how it has
  /// differed so far.
  listed : Map[String, Array[String]]
  /// The example's ids that the Stub cannot fix.
  unfixed : Array[String]
  /// Each unfixed id of the example compared so far, with smock's id at
  /// the same place.
  ids : Map[String, String]
  /// The same pairs, by smock's id.
  owners : Map[String, String]
}

///|
/// A comparison that lists `differs` as deliberate differences, and
/// `unfixed` as ids the Stub cannot fix.
fn Comparison::new(
  differs : Array[String],
  unfixed : Array[String],
) -> Comparison {
  let listed = Map([])
  for pointer in differs {
    listed[pointer] = []
  }
  { problems: [], listed, unfixed, ids: Map([]), owners: Map([]), }
}

///|
/// A copy of `self` with no problem yet, for a trial that must leave it as
/// it is.
fn Comparison::copy(self : Comparison) -> Comparison {
  let listed = Map([])
  for pointer, kinds in self.listed {
    listed[pointer] = kinds.copy()
  }
  {
    problems: [],
    listed,
    unfixed: self.unfixed,
    ids: self.ids.copy(),
    owners: self.owners.copy(),
  }
}

///|
/// Compares the values `example` and `sent` at the JSON Pointer `path` of
/// the event `event`, either missing, and adds a line for each difference
/// that is not listed. Member order does not count, nor how a number is
/// written.
fn Comparison::diff(
  self : Comparison,
  event : String,
  path : String,
  example : Json?,
  sent : Json?,
) -> Unit {
  if self.listed.get(path) is Some(kinds) {
    let kind = match (example, sent) {
      (Some(_), None) => "only in the example"
      (None, Some(_)) => "only in smock's"
      (Some(example), Some(sent)) if example != sent => "values differ"
      _ => return
    }
    if !kinds.contains(kind) {
      kinds.push(kind)
    }
    return
  }
  match (example, sent) {
    (None, None) => ()
    (Some(example), None) =>
      self.problems.push(
        "\{event} \{path}: only in the example: \{example.stringify()}",
      )
    (None, Some(sent)) =>
      self.problems.push(
        "\{event} \{path}: only in smock's: \{sent.stringify()}",
      )
    (Some(Object(example)), Some(Object(sent))) => {
      for key, value in example {
        self.diff(
          event,
          "\{path}/\{pointer_token(key)}",
          Some(value),
          sent.get(key),
        )
      }
      for key, value in sent {
        if !example.contains(key) {
          self.diff(event, "\{path}/\{pointer_token(key)}", None, Some(value))
        }
      }
    }
    (Some(Array(example)), Some(Array(sent))) => {
      let length = if example.length() > sent.length() {
        example.length()
      } else {
        sent.length()
      }
      for i in 0..<length {
        self.diff(event, "\{path}/\{i}", example.get(i), sent.get(i))
      }
    }
    (Some(String(id)), Some(String(sent))) if self.unfixed.contains(id) =>
      self.id(event, path, id, sent)
    (Some(example), Some(sent)) =>
      if example != sent {
        self.problems.push(
          "\{event} \{path}: the example has \{example.stringify()}, smock \{sent.stringify()}",
        )
      }
  }
}

///|
/// Compares the example's unfixed id `id` with smock's `sent` at `path` of
/// the event `event`: `sent` must start with the same prefix, the part of
/// `id` up to its first `_` or `-`, and be the same wherever `id` is, and
/// only there.
fn Comparison::id(
  self : Comparison,
  event : String,
  path : String,
  id : String,
  sent : String,
) -> Unit {
  let prefix = id_prefix(id)
  if !sent.has_prefix(prefix) {
    self.problems.push(
      "\{event} \{path}: smock's id \{sent.escape()} does not start with \{prefix.escape()}, as the example's \{id.escape()}",
    )
    return
  }
  match (self.ids.get(id), self.owners.get(sent)) {
    (None, None) => {
      self.ids[id] = sent
      self.owners[sent] = id
    }
    (Some(before), _) if before != sent =>
      self.problems.push(
        "\{event} \{path}: smock's id is \{sent.escape()} where the example has \{id.escape()}, which is \{before.escape()} before",
      )
    (_, Some(owner)) if owner != id =>
      self.problems.push(
        "\{event} \{path}: smock's id \{sent.escape()} is both the example's \{owner.escape()} and \{id.escape()}",
      )
    _ => ()
  }
}

///|
/// The prefix of the id `id`: its part up to its first `_` or `-`, or all
/// of it.
fn id_prefix(id : String) -> String {
  let cut = match (id.find("_"), id.find("-")) {
    (Some(a), Some(b)) => if a < b { a } else { b }
    (Some(at), None) | (None, Some(at)) => at
    (None, None) => return id
  }
  id[:cut + 1].to_owned()
}

///|
/// Compares the event `example` with smock's `sent`: their names, then
/// their data, as JSON when both are, otherwise as text.
fn Comparison::event(
  self : Comparison,
  event : String,
  example : GoldenEvent,
  sent : GoldenEvent,
) -> Unit {
  if example.name != sent.name {
    let name = (name : String?) => name.map_or("none", name => name.escape())
    self.problems.push(
      "\{event} name: the example has \{name(example.name)}, smock \{name(sent.name)}",
    )
  }
  match (example.data, sent.data) {
    (Some(_), Some(_)) => self.diff(event, "", example.data, sent.data)
    _ =>
      if example.text != sent.text {
        self.problems.push(
          "\{event} data: the example has \{example.text.escape()}, smock \{sent.text.escape()}",
        )
      }
  }
}

///|
/// Compares the events `segment` of the example, each with its number,
/// with smock's events from `at` on.
fn Comparison::segment(
  self : Comparison,
  segment : Array[GoldenEvent],
  sent : Array[GoldenEvent],
  at : Int32,
) -> Unit {
  for i, example in segment {
    let event = "event \{example.number}"
    match sent.get(at + i) {
      Some(sent) => self.event(event, example, sent)
      None => self.problems.push("\{event}: smock's stream has ended before it")
    }
  }
}

///|
/// The piece of a tool call's arguments that `event` carries, with its
/// pointer: the first of `fragments` at which its data has a string that
/// is not empty.
fn fragment_of(
  event : GoldenEvent,
  fragments : Array[String],
) -> (String, String)? {
  guard event.data is Some(data) else { return None }
  for pointer in fragments {
    if json_at(data, pointer) is Some(String(piece)) && piece != "" {
      return Some((pointer, piece))
    }
  }
  None
}

///|
/// `events` with each run of fragments joined: consecutive events that
/// carry a piece at the same pointer of `fragments` become the first of
/// them, its piece replaced by the run's pieces joined. The other members
/// of the others are dropped.
fn join_fragments(
  events : Array[GoldenEvent],
  fragments : Array[String],
) -> Array[GoldenEvent] {
  let joined = []
  let mut i = 0
  while i < events.length() {
    let event = events[i]
    i += 1
    joined.push(event)
    guard fragment_of(event, fragments) is Some((pointer, piece)) else {
      continue
    }
    let out = StringBuilder()
    out.write_string(piece)
    while i < events.length() &&
          fragment_of(events[i], fragments) is Some((next_pointer, next)) &&
          next_pointer == pointer {
      out.write_string(next)
      i += 1
    }
    if event.data is Some(data) {
      put_at(data, pointer, Json::string(out.to_string()))
    }
  }
  joined
}

///|
/// The tokens of the JSON Pointer `pointer`.
fn pointer_tokens(pointer : String) -> Array[String] {
  let tokens = []
  for token in pointer.split("/").drop(1) {
    tokens.push(
      token
      .to_owned()
      .replace_all(old="~1", new="/")
      .replace_all(old="~0", new="~"),
    )
  }
  tokens
}

///|
/// The value at the JSON Pointer `pointer` of `data`, if any.
fn json_at(data : Json, pointer : String) -> Json? {
  let mut value = data
  for token in pointer_tokens(pointer) {
    match value {
      Object(members) =>
        match members.get(token) {
          Some(found) => value = found
          None => return None
        }
      Array(elements) =>
        match index_of(elements.length(), token) {
          Some(i) => value = elements[i]
          None => return None
        }
      _ => return None
    }
  }
  Some(value)
}

///|
/// Puts `value` at the JSON Pointer `pointer` of `data`, in place of the
/// value there.
fn put_at(data : Json, pointer : String, value : Json) -> Unit {
  let tokens = pointer_tokens(pointer)
  guard tokens.pop() is Some(last) else { return }
  let parent = tokens
    .map(pointer_token)
    .fold(init="", (path, token) => "\{path}/\{token}")
  match json_at(data, parent) {
    Some(Object(members)) => members[last] = value
    Some(Array(elements)) =>
      if index_of(elements.length(), last) is Some(i) {
        elements[i] = value
      }
    _ => ()
  }
}

///|
/// The index of an array of `length` elements that the token `token`
/// names, if any.
fn index_of(length : Int32, token : String) -> Int32? {
  for i in 0..<length {
    if i.to_string() == token {
      return Some(i)
    }
  }
  None
}

///|
/// The key `key` as a token of a JSON Pointer.
fn pointer_token(key : String) -> String {
  key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
/// Compares the vendor's example `example` with what smock planned in
/// `outcome`, and returns the verdict: `same`, `same but for the listed
/// differences`, or `not as listed` and one line per problem; then a line
/// per listed difference saying how it differed.
///
/// `example` is one JSON document, compared with the JSON body, or a
/// stream of Server-Sent Events, compared with smock's events, as the
/// server writes them, by name and data. Data is compared as JSON, member
/// order ignored, or as text when it is not JSON. A comment between events
/// stands for events left out: it matches any number of smock's events, so
/// the events before it are compared from smock's first event on and the
/// last ones up to its last event. Between two such gaps, the events go
/// where they first match.
///
/// `differs` holds the JSON Pointers of the fields smock deliberately
/// differs on, in any event: they are not compared, and each must differ
/// in at least one.
///
/// `unfixed` holds the example's ids that the Stub cannot fix. Each matches
/// smock's id at the same place when that has the same prefix, the part up
/// to the first `_` or `-`, and is the same wherever the example's is, and
/// only there. Each must be compared at least once.
///
/// `fragments` holds the JSON Pointers of tool-call argument fragments.
/// An event whose data has a string that is not empty at one of them
/// carries a fragment, and each run of such events, in the example and in
/// smock's stream, is compared as one event whose fragment is their join,
/// so their number does not count. An empty first piece is no fragment and
/// is compared on its own.
///
/// `absent` holds the names of events that the example has and smock
/// deliberately never sends, such as Anthropic's `ping`. They are left out
/// of the example before it is compared, and each must be in it at least
/// once.
///
/// With `unframed`, `example` prints its events without SSE framing, as a
/// document may show a stream: JSON values one after another, a comment
/// line standing for events left out. They are compared with smock's
/// events as a sequence of data alone, names not compared.
fn compare_golden(
  example : String,
  outcome : @engine.Outcome,
  differs~ : Array[String] = [],
  unfixed~ : Array[String] = [],
  fragments~ : Array[String] = [],
  absent~ : Array[String] = [],
  unframed~ : Bool = false,
) -> String {
  let comparison = Comparison::new(differs, unfixed)
  // The names of `absent` that the example has.
  let left_out = []
  let (streams, sent) = sent_events(outcome)
  let sent = if unframed {
    sent.map(event => { ..event, name: None, })
  } else {
    sent
  }
  let sent = join_fragments(sent, fragments)
  if !unframed && example.trim_start().has_prefix("{") {
    if streams {
      comparison.problems.push(
        "the example is a JSON body, smock sends a stream",
      )
    } else {
      comparison.event("body", golden_event(example), sent[0])
    }
  } else if !streams {
    comparison.problems.push("the example is a stream, smock sends a JSON body")
  } else {
    let segments = [[]]
    // The number of the example's events that are compared.
    let mut number = 0
    let items = if unframed {
      golden_unframed(example)
    } else {
      golden_stream(example)
    }
    for item in items {
      match item {
        Event({ name: Some(name), .. }) if absent.contains(name) =>
          if !left_out.contains(name) {
            left_out.push(name)
          }
        Event(event) => {
          number += 1
          segments[segments.length() - 1].push(event)
        }
        Gap => segments.push([])
      }
    }
    for i, segment in segments {
      segments[i] = join_fragments(segment, fragments)
    }
    let last = segments.length() - 1
    if last == 0 {
      comparison.segment(segments[0], sent, 0)
      if sent.length() > number {
        comparison.problems.push(
          "smock sends \{sent.length()} events, the example \{number}",
        )
      }
    } else {
      comparison.segment(segments[0], sent, 0)
      let mut at = segments[0].length()
      for segment in segments[1:last] {
        let mut found = None
        for start in at..<=(sent.length() - segment.length()) {
          let trial = comparison.copy()
          trial.segment(segment, sent, start)
          if trial.problems.is_empty() {
            found = Some(start)
            break
          }
        }
        match found {
          Some(start) => {
            comparison.segment(segment, sent, start)
            at = start + segment.length()
          }
          None => {
            let first = segment[0].number
            let last = segment[segment.length() - 1].number
            comparison.problems.push(
              if first == last {
                "event \{first} is not in smock's stream after event \{first - 1}"
              } else {
                "events \{first} to \{last} are not in smock's stream after event \{first - 1}"
              },
            )
          }
        }
      }
      let start = sent.length() - segments[last].length()
      if start < at {
        comparison.problems.push(
          "smock sends \{sent.length()} events, fewer than the example's \{number}",
        )
      } else {
        comparison.segment(segments[last], sent, start)
      }
    }
  }
  let listed = []
  for pointer in differs {
    match comparison.listed.get(pointer) {
      Some([]) | None =>
        comparison.problems.push("listed but the same: \{pointer}")
      Some(kinds) => listed.push("listed: \{pointer}: \{kinds.join(", ")}")
    }
  }
  for name in absent {
    if left_out.contains(name) {
      listed.push("listed: \{name} events: only in the example")
    } else {
      comparison.problems.push("listed but the same: \{name} events")
    }
  }
  for id in unfixed {
    if !comparison.ids.contains(id) {
      comparison.problems.push("unfixed but not compared: \{id.escape()}")
    }
  }
  let verdict = if !comparison.problems.is_empty() {
    "not as listed"
  } else if differs.is_empty() && absent.is_empty() {
    "same"
  } else {
    "same but for the listed differences"
  }
  [verdict, ..comparison.problems, ..listed].join("\n")
}

///|
test "the comparison reports each difference that is not listed, with its event and pointer, and a listed one that does not differ" {
  let h = harness([chat_streaming_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  inspect(
    compare_golden(chat_streaming_example, outcome, differs=["/obfuscation"]),
    content=(
      #|not as listed
      #|event 1 /system_fingerprint: only in the example: "fp_44709d6fcb"
      #|event 2 /system_fingerprint: only in the example: "fp_44709d6fcb"
      #|event 3 /system_fingerprint: only in the example: "fp_44709d6fcb"
      #|listed but the same: /obfuscation
    ),
  )
}

///|
test "the comparison reports a value that differs, and a JSON body where the example is a stream or the other way round" {
  let h = harness([chat_default_stub])
  inspect(
    [
      compare_golden(chat_default_example, h.chat(body=hello_request())),
      compare_golden(
        chat_default_example,
        h.chat(body=hello_request(stream=true)),
      ),
      compare_golden(chat_streaming_example, h.chat(body=hello_request())),
    ].join("\n--\n"),
    content=(
      #|not as listed
      #|body /created: the example has 1741569952, smock 1791815405
      #|--
      #|not as listed
      #|the example is a JSON body, smock sends a stream
      #|--
      #|not as listed
      #|the example is a stream, smock sends a JSON body
    ),
  )
}

///|
/// A Chat Completions chunk as an example prints it, with the id `id`, the
/// time and model of the Streaming example, the delta `delta` and the
/// finish reason `finish`, both as JSON text.
fn chat_chunk(
  delta : String,
  finish~ : String = "null",
  id~ : String = "chatcmpl-123",
) -> String {
  "data: {\"id\":\"\{id}\",\"object\":\"chat.completion.chunk\",\"created\":1694268190,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":\{delta},\"logprobs\":null,\"finish_reason\":\{finish}}]}\n\n"
}

///|
/// The Streaming example with a gap before and after a piece of its own,
/// `piece`.
fn two_gaps(piece : String) -> String {
  chat_chunk("{\"role\":\"assistant\",\"content\":\"\"}") +
  ": omitted\n\n" +
  chat_chunk("{\"content\":\{piece.to_json().stringify()}}") +
  ": omitted\n: and more\n\n" +
  chat_chunk("{}", finish="\"stop\"") +
  "data: [DONE]\n\n"
}

///|
test "a gap matches any number of smock's events, none included, and events between two gaps go where they first match" {
  let h = harness([chat_streaming_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  inspect(
    [
      compare_golden(two_gaps("Hello"), outcome),
      compare_golden(two_gaps(" assist you today?"), outcome),
      compare_golden(two_gaps("Goodbye"), outcome),
    ].join("\n--\n"),
    content=(
      #|same
      #|--
      #|same
      #|--
      #|not as listed
      #|event 2 is not in smock's stream after event 1
    ),
  )
}

///|
test "an event listed as absent by its name is left out of the example, and must be in it" {
  let h = harness([chat_streaming_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  let with_ping = chat_chunk("{\"role\":\"assistant\",\"content\":\"\"}") +
    "event: ping\ndata: {\"type\": \"ping\"}\n\n" +
    ": omitted\n\n" +
    chat_chunk("{}", finish="\"stop\"") +
    "data: [DONE]\n\n"
  inspect(
    [
      compare_golden(with_ping, outcome, absent=["ping"]),
      compare_golden(with_ping, outcome),
      compare_golden(two_gaps("Hello"), outcome, absent=["ping"]),
    ].join("\n--\n"),
    content=(
      #|same but for the listed differences
      #|listed: ping events: only in the example
      #|--
      #|not as listed
      #|event 2 name: the example has "ping", smock none
      #|event 2 /type: only in the example: "ping"
      #|event 2 /id: only in smock's: "chatcmpl-123"
      #|event 2 /object: only in smock's: "chat.completion.chunk"
      #|event 2 /created: only in smock's: 1694268190
      #|event 2 /model: only in smock's: "gpt-6-astra"
      #|event 2 /choices: only in smock's: [{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}]
      #|--
      #|not as listed
      #|listed but the same: ping events
    ),
  )
}

///|
/// The basic stream's two deltas, printed without framing on one line and
/// over several, match smock's. Printed as `data:` lines, they are framed
/// and their names are compared. A value that never parses is compared as
/// text.
test "an example printed without SSE framing is read as JSON values one after another and compared by their data alone, a comment line being a gap" {
  let h = harness([anthropic_basic_stream_stub])
  let outcome = h.messages(
    body="{\"model\":\"claude-opus-5-5\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":256,\"stream\":true}",
  )
  let deltas =
    #|{"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}
    #|{
    #|  "type": "content_block_delta",
    #|  "index": 0,
    #|  "delta": {"type": "text_delta", "text": "!"}
    #|}
  let framed =
    #|data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}
    #|
    #|data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}
    #|
  inspect(
    [
      compare_golden(
        ": the opening events\n" + deltas + "\n: the closing events\n",
        outcome,
        unframed=true,
      ),
      compare_golden(
        ": the opening events\n\n" + framed + "\n: the closing events\n",
        outcome,
      ),
      compare_golden(
        ": the opening events\n{\"type\": \"message_stop\"\n",
        outcome,
        unframed=true,
      ),
    ].join("\n--\n"),
    content=(
      #|same
      #|--
      #|not as listed
      #|events 1 to 2 are not in smock's stream after event 0
      #|--
      #|not as listed
      #|event 1 data: the example has "{\"type\": \"message_stop\"", smock "{\"type\":\"message_stop\"}"
    ),
  )
}

///|
/// A Mock `openai` whose Stub `unfixed` is the Streaming example's but
/// fixes no id, so its seed gives them.
let unfixed_stub : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: unfixed
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        model: gpt-6-astra
    #|        chunks: [Hello, "! How can I", " assist you today?"]
    #|    fault: { seed: 7 }
  ),
)

///|
test "an id listed as unfixed matches smock's when it has the same prefix and is the same in every event where it appears" {
  let h = harness([unfixed_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  let closing = "\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"created\":1694268190,\"model\":\"gpt-6-astra\", \"system_fingerprint\": \"fp_44709d6fcb\", \"choices\":[{\"index\":0,\"delta\":{}"
  let differs = ["/system_fingerprint"]
  inspect(
    [
      compare_golden(chat_streaming_example, outcome, differs~, unfixed=[
        "chatcmpl-123",
      ]),
      compare_golden(chat_streaming_example, outcome, differs~),
      compare_golden(
        chat_streaming_example.replace(
          old=closing,
          new=closing.replace(old="chatcmpl-123", new="chatcmpl-456"),
        ),
        outcome,
        differs~,
        unfixed=["chatcmpl-123", "chatcmpl-456"],
      ),
      compare_golden(
        chat_streaming_example.replace_all(old="chatcmpl-123", new="resp_123"),
        outcome,
        differs~,
        unfixed=["resp_123", "chatcmpl-9"],
      ),
    ].join("\n--\n"),
    content=(
      #|same but for the listed differences
      #|listed: /system_fingerprint: only in the example
      #|--
      #|not as listed
      #|event 1 /id: the example has "chatcmpl-123", smock "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|event 2 /id: the example has "chatcmpl-123", smock "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|event 3 /id: the example has "chatcmpl-123", smock "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl"
      #|listed: /system_fingerprint: only in the example
      #|--
      #|not as listed
      #|event 3 /id: smock's id "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" is both the example's "chatcmpl-123" and "chatcmpl-456"
      #|unfixed but not compared: "chatcmpl-456"
      #|listed: /system_fingerprint: only in the example
      #|--
      #|not as listed
      #|event 1 /id: smock's id "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" does not start with "resp_", as the example's "resp_123"
      #|event 2 /id: smock's id "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" does not start with "resp_", as the example's "resp_123"
      #|event 3 /id: smock's id "chatcmpl-oniRcSDFUU6bnxe66XwQR5pl" does not start with "resp_", as the example's "resp_123"
      #|unfixed but not compared: "resp_123"
      #|unfixed but not compared: "chatcmpl-9"
      #|listed: /system_fingerprint: only in the example
    ),
  )
}

///|
/// A Mock `openai` whose Stub `call` answers with one tool call and no
/// text, its ids fixed.
let call_stub : (String, String) = (
  "openai.yaml",
  (
    #|mocks:
    #|  - name: openai
    #|    hosts: [api.openai.test]
    #|stubs:
    #|  - id: call
    #|    mock: openai
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      llm:
    #|        api: openai-chat
    #|        id: chatcmpl-123
    #|        model: gpt-6-astra
    #|        toolCalls:
    #|          - { id: call_1, name: get_weather, arguments: { city: Paris } }
  ),
)

///|
/// A stream of `call_stub`'s reply as an example could print it, with the
/// call's arguments in the pieces `pieces`.
fn call_stream(pieces : Array[String]) -> String {
  let out = StringBuilder()
  out.write_string(chat_chunk("{\"role\":\"assistant\",\"content\":null}"))
  out.write_string(
    chat_chunk(
      "{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}",
    ),
  )
  for piece in pieces {
    out.write_string(
      chat_chunk(
        "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\{piece.to_json().stringify()}}}]}",
      ),
    )
  }
  out.write_string(chat_chunk("{}", finish="\"tool_calls\""))
  out.write_string("data: [DONE]\n\n")
  out.to_string()
}

///|
test "argument fragments listed by pointer are compared by their join, whatever their number, and an empty first piece on its own" {
  let h = harness([call_stub])
  h.now = 1_694_268_190_000L
  let outcome = h.chat(body=hello_request(stream=true))
  let fragments = ["/choices/0/delta/tool_calls/0/function/arguments"]
  inspect(
    [
      compare_golden(
        call_stream(["{\"city\":", "\"Paris\"}"]),
        outcome,
        fragments~,
      ),
      compare_golden(call_stream(["{\"city\":\"Paris\"}"]), outcome, fragments~),
      compare_golden(
        call_stream(["{\"city\":", "\"Lyon\"}"]),
        outcome,
        fragments~,
      ),
      compare_golden(call_stream(["{\"city\":", "\"Paris\"}"]), outcome),
    ].join("\n--\n"),
    content=(
      #|same
      #|--
      #|same
      #|--
      #|not as listed
      #|event 3 /choices/0/delta/tool_calls/0/function/arguments: the example has "{\"city\":\"Lyon\"}", smock "{\"city\":\"Paris\"}"
      #|--
      #|not as listed
      #|event 3 /choices/0/delta/tool_calls/0/function/arguments: the example has "{\"city\":", smock "{\"ci"
      #|event 4 /choices/0/delta/tool_calls/0/function/arguments: the example has "\"Paris\"}", smock "ty\":"
      #|event 5 /choices/0/delta/tool_calls: only in smock's: [{"index":0,"function":{"arguments":"\"Par"}}]
      #|event 5 /choices/0/finish_reason: the example has "tool_calls", smock null
      #|event 6 data: the example has "[DONE]", smock "{\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"created\":1694268190,\"model\":\"gpt-6-astra\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"is\\\"}\"}}]},\"logprobs\":null,\"finish_reason\":null}]}"
      #|smock sends 8 events, the example 6
    ),
  )
}
