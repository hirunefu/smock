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
/// Reads the response `json` at `pointer`, one the operation answers with
/// `status` to the method `meth`, after following its `$ref`, and returns
/// what it sends. Until headers are imported, each header it documents is
/// left out, with a warning that names it.
fn Report::response_parts(
  self : Report,
  document : Document,
  pointer : String,
  json : Json,
  status~ : Int,
  meth~ : String,
) -> Payload {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return no_payload
  }
  guard json is Object(response) else {
    self.root_error(pointer, "must be an object")
    return no_payload
  }
  let mut payload = no_payload
  for field, value in response {
    let field_pointer = @definitions.child_pointer(pointer, field)
    match (field, value) {
      ("content", Object(content)) =>
        payload = self.content(document, field_pointer, content, status~, meth~)
      ("headers", Object(headers)) =>
        for name, _ in headers {
          if !headers_smock_sets.contains(name.to_lower()) {
            self.root_warning(
              @definitions.child_pointer(field_pointer, name),
              "left out: response headers are not imported yet",
            )
          }
        }
      ("content" | "headers", _) =>
        self.root_error(field_pointer, "must be an object")
      _ => ()
    }
  }
  payload
}

///|
/// What the `content` of a response sends: its one media type, with a
/// body sampled from that media type's schema. The response's other media
/// types are left out, with a warning. 204, 205 and 304 responses, and
/// responses to HEAD, send no body and no Content-Type: content that the
/// document gives them is left out, with a warning.
fn Report::content(
  self : Report,
  document : Document,
  pointer : String,
  content : Map[String, Json],
  status~ : Int,
  meth~ : String,
) -> Payload {
  guard media_type_of(content) is Some(chosen) else { return no_payload }
  if meth == "HEAD" {
    self.root_warning(pointer, "left out: a response to HEAD has no body")
    return no_payload
  }
  if status is (204 | 205 | 304) {
    self.root_warning(pointer, "left out: a \{status} response has no body")
    return no_payload
  }
  let mut payload = no_payload
  for key, json in content {
    let at = @definitions.child_pointer(pointer, key)
    if key == chosen {
      payload = self.media_type(document, at, key, json)
    } else {
      self.root_warning(
        at,
        "left out: a response answers with one media type, here \{chosen.escape()}",
      )
    }
  }
  payload
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
/// What the Media Type Object `json` at `pointer`, of the media type `key`,
/// sends, after following its `$ref`: a sample of its `schema`, or an empty
/// body when it has none. Until examples are imported, its `example` and
/// `examples` are left out, with a warning.
fn Report::media_type(
  self : Report,
  document : Document,
  pointer : String,
  key : String,
  json : Json,
) -> Payload {
  guard self.followed(document, pointer, json) is Some({ pointer, json, }) else {
    return no_payload
  }
  guard json is Object(media_type) else {
    self.root_error(pointer, "must be an object")
    return no_payload
  }
  let mut value = None
  for field, json in media_type {
    let at = @definitions.child_pointer(pointer, field)
    match field {
      "schema" =>
        if json is (Object(_) | True | False) {
          if self.sampler(document).sample(at, json, body_nesting)
            is Some(sample) {
            value = Some((at, sample))
          }
        } else {
          self.root_error(at, "must be a schema, an object or a boolean")
        }
      "example" | "examples" =>
        self.root_warning(at, "left out: examples are not imported yet")
      _ => ()
    }
  }
  self.payload(pointer, key, value)
}

///|
/// What a response of the media type `key`, written at `pointer`, sends
/// for `value`, the body's value and the pointer it comes from, or `None`
/// for an empty body.
///
/// A JSON media type, `application/json` or `*/*+json`, gives `json`.
/// Under a range such as `*/*`, a value that is not a string gives `json`
/// too, so smock sends it as JSON. Otherwise a string is the body as it is,
/// and a number or a boolean as smock writes it; an object, an array or
/// null gives an empty body, with a warning where the value comes from.
///
/// The Content-Type is the key as written, except for a range, and for
/// plain `application/json` with a `json` body, which smock sends with
/// that Content-Type itself. A key that a header cannot hold is left out,
/// with a warning.
fn Report::payload(
  self : Report,
  pointer : String,
  key : String,
  value : (String, Json)?,
) -> Payload {
  let range = is_range(essence_of(key))
  let body = match value {
    None => Empty
    Some((_, value)) if @template.escaping_for(Some(key)) is JsonString =>
      JsonValue(value)
    Some((_, String(text))) => Text(text)
    Some((_, value)) if range => JsonValue(value)
    Some((_, Number(n, repr~))) => Text(@template.number_text(n, repr))
    Some((_, True)) => Text("true")
    Some((_, False)) => Text("false")
    Some((at, value)) => {
      let kind = match value {
        Object(_) => "an object"
        Array(_) => "an array"
        _ => "null"
      }
      self.root_warning(
        at,
        "left out: the body is empty, since a \{key.escape()} body cannot hold \{kind}",
      )
      Empty
    }
  }
  let content_type = if range ||
    (body is JsonValue(_) && key.to_lower() == "application/json") {
    None
  } else if !@http1.is_field_value(key) {
    self.root_warning(
      pointer, "left out: the Content-Type, since a header cannot hold a control character",
    )
    None
  } else {
    Some(key)
  }
  { content_type, body, }
}
