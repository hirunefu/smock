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
/// One body a response answers with: what it sends, the name of the media
/// type's named example it comes from, if it comes from one, and whether
/// it is a sample of the schema cut to its required parts.
priv struct Answer {
  example : String?
  payload : Payload
  cut : Bool
}

///|
/// What a response answers with: the bodies of its one media type, and
/// its headers.
priv struct Answers {
  /// The answer of the response's own Stub.
  first : Answer
  /// The further named examples, in the order the document writes them.
  /// Each gets a Stub of its own, which a request selects with
  /// `Smock-Example: <name>`.
  named : Array[Answer]
  /// The headers the response documents, as (name, value), in the order
  /// the document writes them. Every answer sends them, after its
  /// Content-Type.
  headers : Array[(String, String)]
}

///|
/// No Content-Type, an empty body and no header, and no named example.
fn no_answers() -> Answers {
  {
    first: { example: None, payload: no_payload, cut: false, },
    named: [],
    headers: [],
  }
}

///|
/// A value a body is written from.
priv enum Value {
  /// A sample of the schema, at its pointer.
  Sampled(Place, Json)
  /// Example data, at its pointer: a media type's `example`, or an
  /// Example Object's `dataValue` or `value`.
  Data(Place, Json)
  /// An Example Object's `serializedValue`, at its pointer: the exact text
  /// of the body.
  Serialized(Place, String)
}

///|
/// The largest body an example gives: 1 MiB of compact JSON, or of text.
let max_example_bytes : Int = 1024 * 1024

///|
/// Reads the response `json` at `pointer`, one the operation answers with
/// `status` to the method `meth`, after following its `$ref`, and returns
/// what it answers with: the bodies of its content, and its headers.
fn Conversion::response_parts(
  self : Conversion,
  pointer : Place,
  json : Json,
  status~ : Int,
  meth~ : String,
) -> Answers {
  guard self.followed_object(pointer, json) is Some((pointer, response)) else {
    return no_answers()
  }
  let mut answers = no_answers()
  let mut headers = []
  for field, value in response {
    let field_pointer = pointer.child(field)
    match (field, value) {
      ("content", Object(content)) =>
        answers = self.content(field_pointer, content, status~, meth~)
      ("headers", Object(documented)) =>
        headers = self.headers(field_pointer, documented)
      ("content" | "headers", _) =>
        self.error_at(field_pointer, "must be an object")
      _ => ()
    }
  }
  { ..answers, headers, }
}

///|
/// What the `content` of a response answers with: its one media type,
/// with bodies from that media type's examples or its schema. The
/// response's other media types are left out, with a warning. 204, 205 and
/// 304 responses, and responses to HEAD, send no body and no Content-Type:
/// content that the document gives them is left out, with a warning.
fn Conversion::content(
  self : Conversion,
  pointer : Place,
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
    let at = pointer.child(key)
    if key == chosen {
      answers = self.media_type(at, key, json)
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
/// The Media Type Object `json`, written at `pointer` in a `content` map:
/// where it is, after following its `$ref` in OpenAPI 3.2, and its fields.
/// Only 3.2 allows a Reference Object there. In 3.0 and 3.1 the object is
/// read as written, and a `$ref` member in it is ignored, with a warning.
/// `None` after reporting an error.
fn Conversion::media_type_object(
  self : Conversion,
  pointer : Place,
  json : Json,
) -> (Place, Map[String, Json])? {
  if self.document.openapi.has_prefix("3.2.") {
    return self.followed_object(pointer, json)
  }
  guard json is Object(media_type) else {
    self.error_at(pointer, "must be an object")
    return None
  }
  if media_type.contains("$ref") {
    self.warning_at(
      pointer.child("$ref"),
      "ignored: a Media Type is a reference only from OpenAPI 3.2",
    )
  }
  Some((pointer, media_type))
}

///|
/// What the Media Type Object `json` at `pointer`, of the media type `key`,
/// answers with, after following its `$ref` in 3.2. The first source that
/// gives a value gives the body: its `examples`, whose first is the body
/// and whose others get Stubs of their own; its `example`; then a sample
/// of its `schema`. With none, the body is empty. A media type with both
/// `example` and `examples` uses `examples`, with a warning.
fn Conversion::media_type(
  self : Conversion,
  pointer : Place,
  key : String,
  json : Json,
) -> Answers {
  guard self.media_type_object(pointer, json) is Some((pointer, media_type)) else {
    return no_answers()
  }
  let example_pointer = pointer.child("example")
  let examples_pointer = pointer.child("examples")
  match media_type.get("examples") {
    None => ()
    Some(Object(examples)) =>
      if self.examples(pointer, examples_pointer, key, examples)
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
      pointer,
      key,
      Data(example_pointer, value),
    )
    return {
      first: { example: None, payload, cut: false, },
      named: [],
      headers: [],
    }
  }
  let schema_pointer = pointer.child("schema")
  let mut cut = false
  let value = match media_type.get("schema") {
    None => None
    Some(Object(_) | True | False as json) => {
      let sample = self.body_sample(schema_pointer, json)
      cut = sample.cut
      match sample.value {
        Some(sample) => Some(Sampled(schema_pointer, sample))
        None => None
      }
    }
    Some(_) => {
      self.error_at(schema_pointer, "must be a schema, an object or a boolean")
      None
    }
  }
  {
    first: { example: None, payload: self.payload(pointer, key, value), cut, },
    named: [],
    headers: [],
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
fn Conversion::payload(
  self : Conversion,
  pointer : Place,
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
        _ =>
          match scalar_text(value) {
            Some(text) => Text(text)
            None => {
              self.warning_at(
                at,
                "left out: the body is empty, since a \{key.escape()} body cannot hold \{kind_of(value)}",
              )
              Empty
            }
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
/// The text of `json`, when it is a string, a number or a boolean: a
/// string as it is, a number as smock writes numbers, and a boolean as
/// `true` or `false`. A body and a header write such a value as text.
fn scalar_text(json : Json) -> String? {
  match json {
    String(text) => Some(text)
    Number(n, repr~) => Some(@template.number_text(n, repr))
    True => Some("true")
    False => Some("false")
    _ => None
  }
}

///|
/// What `json`, an object, an array or null, is, as messages name it.
fn kind_of(json : Json) -> String {
  match json {
    Object(_) => "an object"
    Array(_) => "an array"
    _ => "null"
  }
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
    n += char_bytes(c)
  }
  n
}

///|
/// The length of `c` in UTF-8, in bytes.
fn char_bytes(c : Char) -> Int {
  let code = c.to_int()
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else if code < 0x10000 {
    3
  } else {
    4
  }
}
