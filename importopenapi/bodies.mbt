///|
/// The response headers that are not imported, without a warning: OpenAPI
/// says to skip `Content-Type`, and smock sets the others itself.
/// Documenting them is common and right.
let headers_smock_sets : Array[String] = [
  "content-type", "content-length", "transfer-encoding", "connection",
]

///|
/// What a response sends besides its status: the Content-Type that the
/// file writes in `headers`, if any, and the body.
priv struct Payload {
  content_type : String?
  body : Body
}

///|
/// A body, as the file writes it.
priv enum Body {
  /// No body field, so the body is empty.
  Empty
  /// `json`, which smock sends as JSON.
  JsonValue(Json)
  /// `body`, which smock sends as it is.
  Text(String)
}

///|
/// No Content-Type and an empty body.
let no_payload : Payload = { content_type: None, body: Empty, }

///|
/// One body a response answers with: what it sends, and the name of the
/// media type's named example it comes from, if it comes from one.
priv struct Answer {
  example : String?
  payload : Payload
}

///|
/// What a response answers with, from its one media type.
priv struct Answers {
  /// The answer of the response's own Stub.
  first : Answer
  /// The further named examples, in the order the document writes them.
  /// Each gets a Stub of its own, which a request selects with
  /// `Smock-Example: <name>`.
  named : Array[Answer]
}

///|
/// No Content-Type and an empty body, and no named example.
fn no_answers() -> Answers {
  { first: { example: None, payload: no_payload, }, named: [], }
}

///|
/// A value a body is written from.
priv enum Value {
  /// A sample of the schema, at its pointer.
  Sampled(String, Json)
  /// Example data, at its pointer: a media type's `example`, or an
  /// Example Object's `dataValue` or `value`.
  Data(String, Json)
  /// An Example Object's `serializedValue`, at its pointer: the exact text
  /// of the body.
  Serialized(String, String)
}

///|
/// The largest body an example gives: 1 MiB of compact JSON, or of text.
let max_example_bytes : Int = 1024 * 1024

///|
/// Reads the response `json` at `pointer`, one the operation answers with
/// `status` to the method `meth`, after following its `$ref`, and returns
/// what it answers with. Until headers are imported, each header it
/// documents is left out, with a warning that names it.
fn Report::response_parts(
  self : Report,
  document : Document,
  pointer : String,
  json : Json,
  status~ : Int,
  meth~ : String,
) -> Answers {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return no_answers()
  }
  guard json is Object(response) else {
    self.error_at(pointer, "must be an object")
    return no_answers()
  }
  let mut answers = no_answers()
  for field, value in response {
    let field_pointer = @definitions.child_pointer(pointer, field)
    match (field, value) {
      ("content", Object(content)) =>
        answers = self.content(document, field_pointer, content, status~, meth~)
      ("headers", Object(headers)) =>
        for name, _ in headers {
          if !headers_smock_sets.contains(name.to_lower()) {
            self.warning_at(
              @definitions.child_pointer(field_pointer, name),
              "left out: response headers are not imported yet",
            )
          }
        }
      ("content" | "headers", _) =>
        self.error_at(field_pointer, "must be an object")
      _ => ()
    }
  }
  answers
}

///|
/// What the `content` of a response answers with: its one media type,
/// with bodies from that media type's examples or its schema. The
/// response's other media types are left out, with a warning. 204, 205 and
/// 304 responses, and responses to HEAD, send no body and no Content-Type:
/// content that the document gives them is left out, with a warning.
fn Report::content(
  self : Report,
  document : Document,
  pointer : String,
  content : Map[String, Json],
  status~ : Int,
  meth~ : String,
) -> Answers {
  guard media_type_of(content) is Some(chosen) else { return no_answers() }
  if meth == "HEAD" {
    self.warning_at(pointer, "left out: a response to HEAD has no body")
    return no_answers()
  }
  if status is (204 | 205 | 304) {
    self.warning_at(pointer, "left out: a \{status} response has no body")
    return no_answers()
  }
  let mut answers = no_answers()
  for key, json in content {
    let at = @definitions.child_pointer(pointer, key)
    if key == chosen {
      answers = self.media_type(document, at, key, json)
    } else {
      self.warning_at(
        at,
        "left out: a response answers with one media type, here \{chosen.escape()}",
      )
    }
  }
  answers
}

///|
/// The media type a response answers with, among the keys of `content`:
/// `application/json`, with any parameters; else the first `+json` type;
/// else the first key. `None` when there is none. Media types are compared
/// case-insensitively, without parameters.
fn media_type_of(content : Map[String, Json]) -> String? {
  let mut first = None
  let mut first_json = None
  for key, _ in content {
    let essence = essence_of(key)
    if essence == "application/json" {
      return Some(key)
    }
    if first is None {
      first = Some(key)
    }
    if first_json is None &&
      essence.find("/") is Some(slash) &&
      essence[slash + 1:].has_suffix("+json") {
      first_json = Some(key)
    }
  }
  match first_json {
    Some(_) => first_json
    None => first
  }
}

///|
/// The media type `key` without its parameters, spaces and tabs around it,
/// in lower case.
fn essence_of(key : String) -> String {
  let essence = match key.find(";") {
    Some(i) => key[:i]
    None => key[:]
  }
  essence.trim(chars=" \t").to_owned().to_lower()
}

///|
/// Whether the media type `essence` is a range, such as `*/*` or
/// `application/*`.
fn is_range(essence : String) -> Bool {
  match essence.find("/") {
    Some(slash) => essence[:slash] == "*" || essence[slash + 1:] == "*"
    None => essence == "*"
  }
}

///|
/// Whether the media type `key` is a JSON media type: `application/json`
/// or `*/*+json`, with any parameters.
fn is_json_media_type(key : String) -> Bool {
  @template.escaping_for(Some(key)) is JsonString
}

///|
/// What the Media Type Object `json` at `pointer`, of the media type `key`,
/// answers with, after following its `$ref`. The first source that gives
/// a value gives the body: its `examples`, whose first is the body and
/// whose others get Stubs of their own; its `example`; then a sample of its
/// `schema`. With none, the body is empty. A media type with both
/// `example` and `examples` uses `examples`, with a warning.
fn Report::media_type(
  self : Report,
  document : Document,
  pointer : String,
  key : String,
  json : Json,
) -> Answers {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return no_answers()
  }
  guard json is Object(media_type) else {
    self.error_at(pointer, "must be an object")
    return no_answers()
  }
  let example_pointer = @definitions.child_pointer(pointer, "example")
  let examples_pointer = @definitions.child_pointer(pointer, "examples")
  match media_type.get("examples") {
    None => ()
    Some(Object(examples)) =>
      if self.examples(document, pointer, examples_pointer, key, examples)
        is Some(answers) {
        if media_type.contains("example") {
          self.warning_at(
            example_pointer, "ignored: the media type has examples, which come first",
          )
        }
        return answers
      }
    Some(_) => self.error_at(examples_pointer, "must be an object")
  }
  if media_type.get("example") is Some(value) {
    let payload = self.example_payload(
      document,
      pointer,
      key,
      Data(example_pointer, value),
    )
    return { first: { example: None, payload, }, named: [], }
  }
  let schema_pointer = @definitions.child_pointer(pointer, "schema")
  let value = match media_type.get("schema") {
    None => None
    Some(Object(_) | True | False as json) =>
      match self.sampler(document).sample(schema_pointer, json, body_nesting) {
        Some(sample) => Some(Sampled(schema_pointer, sample))
        None => None
      }
    Some(_) => {
      self.error_at(schema_pointer, "must be a schema, an object or a boolean")
      None
    }
  }
  {
    first: { example: None, payload: self.payload(pointer, key, value), },
    named: [],
  }
}

///|
/// What a response of the media type `key`, written at `pointer`, sends
/// for `value`, or `None` for an empty body.
///
/// A JSON media type, `application/json` or `*/*+json`, gives `json`.
/// Under a range such as `*/*`, a value that is not a string gives `json`
/// too, so smock sends it as JSON. Otherwise a string is the body as it is,
/// and a number or a boolean as smock writes it; an object, an array or
/// null gives an empty body, with a warning where the value comes from. A
/// `serializedValue` is the body as it is, whatever the media type.
///
/// An example's body above 1 MiB, its compact JSON or its text, is left
/// empty, with a warning where the value comes from.
///
/// The Content-Type is the key as written, except for a range, and for
/// plain `application/json` with a `json` body, which smock sends with
/// that Content-Type itself. A key that a header cannot hold is left out,
/// with a warning.
fn Report::payload(
  self : Report,
  pointer : String,
  key : String,
  value : Value?,
) -> Payload {
  let range = is_range(essence_of(key))
  let body = match value {
    None => Empty
    Some(Serialized(_, text)) => Text(text)
    Some(Sampled(at, value) | Data(at, value)) =>
      match value {
        _ if is_json_media_type(key) => JsonValue(value)
        String(text) => Text(text)
        _ if range => JsonValue(value)
        Number(n, repr~) => Text(@template.number_text(n, repr))
        True => Text("true")
        False => Text("false")
        _ => {
          let kind = match value {
            Object(_) => "an object"
            Array(_) => "an array"
            _ => "null"
          }
          self.warning_at(
            at,
            "left out: the body is empty, since a \{key.escape()} body cannot hold \{kind}",
          )
          Empty
        }
      }
  }
  let body = match value {
    Some(Data(at, _) | Serialized(at, _)) if body_bytes(body) >
      max_example_bytes => {
      self.warning_at(
        at,
        "left out: the body is empty, since the example is more than \{size_text(max_example_bytes)}",
      )
      Empty
    }
    _ => body
  }
  let content_type = if range ||
    (body is JsonValue(_) && key.to_lower() == "application/json") {
    None
  } else if !@http1.is_field_value(key) {
    self.warning_at(
      pointer, "left out: the Content-Type, since a header cannot hold a control character",
    )
    None
  } else {
    Some(key)
  }
  { content_type, body, }
}

///|
/// The length of `body` as smock sends it, in bytes: the compact JSON of a
/// `json` body, or the text of a `body`, in UTF-8.
fn body_bytes(body : Body) -> Int {
  match body {
    Empty => 0
    JsonValue(json) => @template.compact_json_bytes(json).length()
    Text(text) => utf8_length(text)
  }
}

///|
/// The length of `s` in UTF-8, in bytes.
fn utf8_length(s : String) -> Int {
  let mut n = 0
  for c in s {
    let code = c.to_int()
    n += if code < 0x80 {
      1
    } else if code < 0x800 {
      2
    } else if code < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}
